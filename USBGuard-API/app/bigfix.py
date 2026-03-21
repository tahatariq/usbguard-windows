"""
IBM BigFix REST API client for the USBGuard API.

Handles computer existence checks, action deployment (grant/revoke USB
exceptions), and registry-based status queries — all over the BigFix REST
API using async httpx requests with configurable SSL verification.
"""

import base64
import logging
import re
import urllib.parse
from datetime import date, datetime, timedelta
from typing import Optional, Union
from xml.etree import ElementTree as ET

import httpx

from app.models import ExceptionStatus

logger = logging.getLogger("usbguard.bigfix")


# ---------------------------------------------------------------------------
# PowerShell script templates
# ---------------------------------------------------------------------------

_GRANT_SCRIPT_TEMPLATE = """\
$guardPath = 'HKLM:\\SOFTWARE\\USBGuard'
if (-not (Test-Path $guardPath)) {{ New-Item -Path $guardPath -Force | Out-Null }}
Set-ItemProperty -Path $guardPath -Name 'ExceptionExpiry' -Value '{expiry_str}'
Set-ItemProperty -Path $guardPath -Name 'ExceptionUser'   -Value '{username}'
Set-ItemProperty -Path $guardPath -Name 'ExceptionRITM'   -Value '{ritm}'
Set-ItemProperty -Path $guardPath -Name 'ExceptionDays'   -Value {number_of_days}
Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\USBSTOR' -Name 'Start' -Value 3
Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\StorageDevicePolicies' -Name 'WriteProtect' -Value 0
"""

_REVOKE_SCRIPT_TEMPLATE = """\
Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\USBSTOR' -Name 'Start' -Value 4
Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\StorageDevicePolicies' -Name 'WriteProtect' -Value 1
$guardPath = 'HKLM:\\SOFTWARE\\USBGuard'
@('ExceptionExpiry','ExceptionUser','ExceptionRITM','ExceptionDays') | ForEach-Object {{
    Remove-ItemProperty -Path $guardPath -Name $_ -ErrorAction SilentlyContinue
}}
"""

# ---------------------------------------------------------------------------
# BES XML template
# ---------------------------------------------------------------------------

# start_offset / end_offset use BigFix format: +DD:HH:MM:SS (relative to action creation).
# HasStartTime=true means BigFix holds the action and only executes it on/after start_offset.
# HasEndTime=true means BigFix discards the action if the PC hasn't checked in by end_offset.
# This ensures offline PCs still receive the action when they come back online (within the window).
_BES_XML_TEMPLATE = """\
<?xml version="1.0" encoding="UTF-8"?>
<BES xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
     xsi:noNamespaceSchemaLocation="BES.xsd">
  <SingleAction>
    <Title><![CDATA[{title}]]></Title>
    <Relevance>true</Relevance>
    <ActionScript MIMEType="application/x-Fixlet-Windows-Shell"><![CDATA[
waithidden powershell.exe -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {encoded_script}
    ]]></ActionScript>
    <Target>
      <ComputerName><![CDATA[{pc_name}]]></ComputerName>
    </Target>
    <Settings>
      <ActionUITitle><![CDATA[{title}]]></ActionUITitle>
      <HasStartTime>true</HasStartTime>
      <HasEndTime>true</HasEndTime>
      <StartDateTimeOffset>{start_offset}</StartDateTimeOffset>
      <EndDateTimeOffset>{end_offset}</EndDateTimeOffset>
    </Settings>
    <SuccessCriteria Option="OriginalRelevance"></SuccessCriteria>
  </SingleAction>
</BES>
"""


def _compute_offsets(start_date: date, number_of_days: int) -> tuple[str, str]:
    """
    Compute BigFix action time offsets in ``+DD:HH:MM:SS`` format.

    BigFix holds a scheduled action until ``start_offset`` has elapsed since
    the action was created, then executes it on the endpoint.  ``end_offset``
    is the deadline — if the PC has not checked in by then, BigFix discards
    the pending action (prevents stale exceptions being applied much later).

    Args:
        start_date: The date from which the exception should become active.
        number_of_days: Duration of the exception in days.

    Returns:
        A ``(start_offset, end_offset)`` tuple, both in ``+DD:HH:MM:SS`` format.
    """
    days_until_start = max(0, (start_date - date.today()).days)
    # End window = start + duration + 14-day buffer so offline PCs that come
    # back within two weeks still receive the grant/revoke action.
    days_end = days_until_start + number_of_days + 14
    return f"+{days_until_start:02d}:00:00:00", f"+{days_end:02d}:00:00:00"


def _encode_powershell(script: str) -> str:
    """Encode a PowerShell script as UTF-16-LE base64 for -EncodedCommand."""
    encoded_bytes = script.encode("utf-16-le")
    return base64.b64encode(encoded_bytes).decode("ascii")


class BigFixClient:
    """
    Async client for the IBM BigFix REST API.

    Uses httpx.AsyncClient with configurable SSL verification.  Pass a CA
    certificate path via *ca_cert* for production; omit or pass empty string
    to disable verification (for development / self-signed BigFix certs).
    """

    def __init__(
        self,
        server: str,
        port: int,
        username: str,
        password: str,
        ca_cert: str = "",
    ) -> None:
        self._auth = (username, password)
        self._base_url = f"https://{server}:{port}"
        self._verify: Union[bool, str] = ca_cert if ca_cert else False
        self._client: Optional[httpx.AsyncClient] = None

    async def start(self) -> None:
        """Create the shared async HTTP client (call during app lifespan)."""
        self._client = httpx.AsyncClient(
            verify=self._verify,
            auth=self._auth,
            timeout=30.0,
        )

    async def close(self) -> None:
        """Close the shared async HTTP client."""
        if self._client:
            await self._client.aclose()
            self._client = None

    @property
    def _http(self) -> httpx.AsyncClient:
        if self._client is None:
            raise RuntimeError("BigFixClient not started — call start() first.")
        return self._client

    # ------------------------------------------------------------------
    # Public methods
    # ------------------------------------------------------------------

    async def health_check(self) -> dict:
        """
        Probe the BigFix server to verify connectivity.

        Returns a dict with ``status`` ("healthy", "degraded", or "unhealthy")
        and optional ``detail`` message.
        """
        try:
            response = await self._http.get(f"{self._base_url}/api/login")
            if response.status_code in (200, 401, 403):
                return {"status": "healthy", "detail": "BigFix server reachable."}
            return {
                "status": "degraded",
                "detail": f"BigFix returned HTTP {response.status_code}.",
            }
        except httpx.HTTPError as exc:
            return {
                "status": "unhealthy",
                "detail": f"BigFix unreachable: {exc}",
            }

    async def computer_exists(self, pc_name: str) -> bool:
        """
        Check whether a computer with the given name is enrolled in BigFix.

        Args:
            pc_name: The exact computer name to look up.

        Returns:
            ``True`` if exactly one computer with that name is found.
        """
        encoded_name = urllib.parse.quote(pc_name, safe="")
        relevance = (
            f"number+of+bes+computers+whose+(name+of+it+%3D+%22{encoded_name}%22)"
        )
        url = f"{self._base_url}/api/query?relevance={relevance}"

        response = await self._http.get(url)
        response.raise_for_status()

        root = ET.fromstring(response.text)
        answer_el = root.find(".//Answer")
        if answer_el is None or answer_el.text is None:
            return False
        return answer_el.text.strip() == "1"

    async def create_exception_action(
        self,
        pc_name: str,
        username: str,
        ritm: str,
        start_date: date,
        number_of_days: int,
    ) -> str:
        """
        Deploy a BigFix action that grants USB access on the target PC.

        Args:
            pc_name: Target computer name.
            username: The user being granted access.
            ritm: ServiceNow RITM number authorising the exception.
            start_date: Date from which the exception is active.
            number_of_days: How many days the exception lasts.

        Returns:
            The BigFix action ID string.
        """
        expiry = start_date + timedelta(days=number_of_days)
        expiry_str = expiry.strftime("%Y-%m-%d")

        script = _GRANT_SCRIPT_TEMPLATE.format(
            expiry_str=expiry_str,
            username=username,
            ritm=ritm,
            number_of_days=number_of_days,
        )
        encoded_script = _encode_powershell(script)

        title = f"USBGuard - Grant Exception - {pc_name} - {ritm}"
        start_offset, end_offset = _compute_offsets(start_date, number_of_days)
        bes_xml = _BES_XML_TEMPLATE.format(
            title=title,
            encoded_script=encoded_script,
            pc_name=pc_name,
            start_offset=start_offset,
            end_offset=end_offset,
        )

        return await self._post_action(bes_xml)

    async def revoke_exception_action(self, pc_name: str) -> str:
        """
        Deploy a BigFix action that revokes USB access on the target PC.

        The action is scheduled for immediate execution (no start delay).
        The 7-day end window ensures offline PCs are revoked when they
        come back online within the week.

        Args:
            pc_name: Target computer name.

        Returns:
            The BigFix action ID string.
        """
        script = _REVOKE_SCRIPT_TEMPLATE.format()
        encoded_script = _encode_powershell(script)

        title = f"USBGuard - Revoke Exception - {pc_name}"
        bes_xml = _BES_XML_TEMPLATE.format(
            title=title,
            encoded_script=encoded_script,
            pc_name=pc_name,
            start_offset="+00:00:00:00",   # immediate
            end_offset="+07:00:00:00",      # 7-day window for offline PCs
        )

        return await self._post_action(bes_xml)

    async def get_exception_status(self, pc_name: str) -> ExceptionStatus:
        """
        Query the current USB exception status from the PC's registry via BigFix.

        Args:
            pc_name: Target computer name.

        Returns:
            An :class:`~app.models.ExceptionStatus` populated from registry values.
        """
        expiry_raw = await self._query_registry_value(pc_name, "ExceptionExpiry")
        user_raw = await self._query_registry_value(pc_name, "ExceptionUser")
        ritm_raw = await self._query_registry_value(pc_name, "ExceptionRITM")

        has_active = False
        expiry_dt = None

        if expiry_raw:
            try:
                expiry_dt = datetime.strptime(expiry_raw.strip(), "%Y-%m-%d")
                has_active = expiry_dt.date() >= date.today()
            except ValueError:
                expiry_dt = None
                has_active = False

        return ExceptionStatus(
            pc_name=pc_name,
            has_active_exception=has_active,
            expiry_time=expiry_dt,
            granted_to_user=user_raw or None,
            ritm=ritm_raw or None,
        )

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    async def _query_registry_value(self, pc_name: str, value_name: str) -> Optional[str]:
        """
        Query a single registry value from HKLM\\SOFTWARE\\USBGuard on a
        specific computer via the BigFix relevance API.

        Args:
            pc_name: Target computer name.
            value_name: Registry value name to retrieve.

        Returns:
            The string value if present, otherwise ``None``.
        """
        relevance = (
            f'(value of it as string) of '
            f'(registry key "{value_name}" of '
            f'key "HKEY_LOCAL_MACHINE\\\\SOFTWARE\\\\USBGuard" of registry) of '
            f'bes computers whose (name of it = "{pc_name}")'
        )
        encoded_relevance = urllib.parse.quote(relevance, safe="")
        url = f"{self._base_url}/api/query?relevance={encoded_relevance}"

        try:
            response = await self._http.get(url)
            response.raise_for_status()
        except httpx.HTTPStatusError:
            return None

        root = ET.fromstring(response.text)
        answer_el = root.find(".//Answer")
        if answer_el is None or answer_el.text is None:
            return None

        text = answer_el.text.strip()
        if not text:
            return None

        return text

    async def _post_action(self, bes_xml: str) -> str:
        """
        POST a BES XML action document to BigFix and return the new action ID.

        Args:
            bes_xml: Complete BES XML document string.

        Returns:
            The action ID extracted from the response XML Resource attribute.

        Raises:
            httpx.HTTPStatusError: If BigFix returns a non-2xx status.
            ValueError: If the response cannot be parsed or lacks an ID.
        """
        url = f"{self._base_url}/api/actions"
        headers = {"Content-Type": "application/xml"}

        response = await self._http.post(url, content=bes_xml.encode("utf-8"), headers=headers)
        response.raise_for_status()

        root = ET.fromstring(response.text)

        action_el = root.find(".//Action")
        if action_el is not None:
            resource = action_el.get("Resource", "")
            if resource:
                match = re.search(r"/(\d+)$", resource)
                if match:
                    return match.group(1)

        id_el = root.find(".//ID")
        if id_el is not None and id_el.text:
            return id_el.text.strip()

        raise ValueError(
            f"Could not extract action ID from BigFix response: {response.text[:500]}"
        )
