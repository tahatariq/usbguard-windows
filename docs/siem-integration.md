# SIEM Integration Guide

This guide describes how to forward USBGuard events to a Security Information and Event Management (SIEM) system for centralized monitoring, alerting, and compliance reporting.

---

## Windows Event Log

USBGuard writes events to the **Application** log with source **USBGuard**. The source is auto-created on first write by `Write-EventLogEntry` in USBGuard.ps1.

### Event ID Mapping

| Event ID | Level | Description |
|----------|-------|-------------|
| 1001 | Information | Full block applied (all 7 layers enabled) |
| 1002 | Information | Full unblock applied (all 7 layers disabled) |
| 1003 | Information | Storage block applied (L1+L2+L3+L4+L5+L6) |
| 1004 | Information | Storage unblock applied |
| 1005 | Information | Phone/MTP/PTP block applied (L7) |
| 1006 | Information | Phone/MTP/PTP unblock applied |
| 1007 | Information | Printer block applied |
| 1008 | Information | Printer unblock applied |
| 1009 | Warning | Tamper detected and remediated |

All events include the acting user (`DOMAIN\username` or `SYSTEM`) in the event message body.

### Future Enhancement

A dedicated `USBGuard/Operational` Event Log channel is planned for a future version. This will:
- Separate USBGuard events from the noisy Application log
- Enable targeted Windows Event Forwarding subscriptions
- Support structured event data (XML) for richer SIEM parsing
- Add additional event IDs for allowlist changes, watcher events, and exception grant/expiry

Until then, filter on `Source = "USBGuard"` in the Application log.

---

## Windows Event Forwarding (WEF)

Windows Event Forwarding is a built-in mechanism to collect events from multiple endpoints to a central Windows Event Collector (WEC) server. This is the recommended approach for Microsoft-centric environments.

### Subscription Setup

1. **Configure the collector server:**
   ```powershell
   # On the WEC server, enable the Windows Event Collector service
   wecutil qc /q
   ```

2. **Create a subscription XML file** (`USBGuard-Subscription.xml`):
   ```xml
   <Subscription xmlns="http://schemas.microsoft.com/2006/03/windows/events/subscription">
     <SubscriptionId>USBGuard-Events</SubscriptionId>
     <SubscriptionType>SourceInitiated</SubscriptionType>
     <Description>Collects all USBGuard events from managed endpoints</Description>
     <Enabled>true</Enabled>
     <Uri>http://schemas.microsoft.com/wbem/wsman/1/windows/EventLog</Uri>
     <ConfigurationMode>Normal</ConfigurationMode>
     <Delivery Mode="Push">
       <Batching>
         <MaxLatencyTime>900000</MaxLatencyTime>
       </Batching>
     </Delivery>
     <Query>
       <![CDATA[
         <QueryList>
           <Query Id="0" Path="Application">
             <Select Path="Application">
               *[System[Provider[@Name='USBGuard']]]
             </Select>
           </Query>
         </QueryList>
       ]]>
     </Query>
     <ReadExistingEvents>true</ReadExistingEvents>
     <TransportName>HTTP</TransportName>
     <ContentFormat>RenderedText</ContentFormat>
     <Locale Language="en-US"/>
     <LogFile>ForwardedEvents</LogFile>
     <AllowedSourceNonDomainComputers/>
     <AllowedSourceDomainComputers>
       O:NSG:BAD:P(A;;GA;;;DC)(A;;GA;;;DD)S:
     </AllowedSourceDomainComputers>
   </Subscription>
   ```

3. **Import the subscription:**
   ```powershell
   wecutil cs USBGuard-Subscription.xml
   ```

4. **Configure source endpoints via GPO:**
   - Computer Configuration > Administrative Templates > Windows Components > Event Forwarding
   - Set "Configure target Subscription Manager" to the WEC server URL:
     ```
     Server=http://<WEC-SERVER>:5985/wsman/SubscriptionManager/WEC,Refresh=60
     ```

---

## Splunk Universal Forwarder

### inputs.conf

Add the following stanza to `%SPLUNK_HOME%\etc\system\local\inputs.conf` (or deploy via a Splunk deployment server app):

```ini
[WinEventLog://Application]
disabled = 0
index = endpoint_security
sourcetype = WinEventLog:Application
whitelist = USBGuard
renderXml = true
# Collect all USBGuard events (1001-1009)
# The whitelist above filters by source name

# Optional: if you only want specific event IDs
# whitelist1 = EventCode="1001" OR EventCode="1002" OR EventCode="1003" OR EventCode="1004" OR EventCode="1005" OR EventCode="1006" OR EventCode="1007" OR EventCode="1008" OR EventCode="1009"
```

### props.conf (optional, on indexer/search head)

```ini
[WinEventLog:Application]
SHOULD_LINEMERGE = false
TIME_FORMAT = %Y-%m-%dT%H:%M:%S
TRUNCATE = 8192
```

### Example Splunk Search

```spl
index=endpoint_security sourcetype="WinEventLog:Application" source="USBGuard"
| eval action=case(
    EventCode=1001, "full_block",
    EventCode=1002, "full_unblock",
    EventCode=1003, "storage_block",
    EventCode=1004, "storage_unblock",
    EventCode=1005, "phone_block",
    EventCode=1006, "phone_unblock",
    EventCode=1007, "printer_block",
    EventCode=1008, "printer_unblock",
    EventCode=1009, "tamper_detected"
  )
| stats count by host, action
| sort -count
```

---

## Elastic Winlogbeat

### winlogbeat.yml

```yaml
winlogbeat.event_logs:
  - name: Application
    event_id: 1001-1009
    providers:
      - USBGuard
    processors:
      - add_fields:
          target: ''
          fields:
            security.product: USBGuard
            security.category: endpoint
            event.kind: event

output.elasticsearch:
  hosts: ["https://elasticsearch:9200"]
  index: "usbguard-events-%{+yyyy.MM.dd}"
  username: "${ES_USERNAME}"
  password: "${ES_PASSWORD}"

# Alternative: output to Logstash
# output.logstash:
#   hosts: ["logstash:5044"]

setup.template.name: "usbguard-events"
setup.template.pattern: "usbguard-events-*"
setup.ilm.enabled: true
setup.ilm.rollover_alias: "usbguard-events"
setup.ilm.pattern: "{now/d}-000001"
```

### Kibana Index Pattern

After Winlogbeat ships events, create an index pattern `usbguard-events-*` in Kibana. Key fields for filtering and dashboards:

- `winlog.event_id` -- the USBGuard event ID (1001-1009)
- `winlog.provider_name` -- "USBGuard"
- `winlog.computer_name` -- source endpoint hostname
- `message` -- full event message including user and action details

---

## Syslog Forwarding via NXLog

For SIEM platforms that ingest syslog (QRadar, ArcSight, Graylog, etc.), use NXLog to forward USBGuard events as syslog messages.

### nxlog.conf

```xml
<Extension _syslog>
    Module      xm_syslog
</Extension>

<Extension _json>
    Module      xm_json
</Extension>

<Input usbguard_eventlog>
    Module      im_msvistalog
    <QueryXML>
        <QueryList>
            <Query Id="0" Path="Application">
                <Select Path="Application">
                    *[System[Provider[@Name='USBGuard']]]
                </Select>
            </Query>
        </QueryList>
    </QueryXML>
</Input>

<Output siem_syslog>
    Module      om_tcp
    Host        siem.example.com
    Port        514
    <Exec>
        $Message = to_json();
        to_syslog_bsd();
    </Exec>
</Output>

<Route usbguard_to_siem>
    Path        usbguard_eventlog => siem_syslog
</Route>
```

### NXLog CE vs EE

- **NXLog Community Edition** (free) supports the above configuration.
- **NXLog Enterprise Edition** adds TLS transport (`om_ssl`), buffering, and guaranteed delivery. Recommended for production SIEM pipelines.

### Syslog Format

The NXLog configuration above sends events as JSON over BSD syslog. Each message contains:

```json
{
  "EventTime": "2026-03-21T14:30:00Z",
  "SourceName": "USBGuard",
  "EventID": 1001,
  "Computer": "DESKTOP-ABC123",
  "Message": "Full block applied. USER=CORP\\jsmith"
}
```

---

## Alert Rules (Examples)

Regardless of SIEM platform, consider creating alerts for:

| Alert | Condition | Severity | Response |
|-------|-----------|----------|----------|
| Tamper detected | EventID = 1009 | High | Investigate endpoint immediately |
| Unexpected unblock | EventID = 1002, 1004, or 1006 outside change window | High | Verify exception was authorized |
| Mass unblock | EventID 1002 from >5 endpoints in 10 minutes | Critical | Possible policy rollback attack |
| No heartbeat | No USBGuard events from endpoint in 7 days | Medium | Verify BigFix agent and policy |

---

## Audit Log File (Supplementary)

In addition to Windows Event Log, USBGuard writes a plaintext audit log at:

```
%ProgramData%\USBGuard\audit.log
```

Format:
```
[2026-03-21 14:30:00] ACTION=block USER=CORP\jsmith
[2026-03-21 22:30:00] ACTION=unblock USER=SYSTEM
```

This file can be collected by any SIEM agent that supports file monitoring (Splunk UF `monitor://`, Filebeat, NXLog `im_file`). However, the Windows Event Log is the preferred source because it includes structured event IDs and is more reliable than file-based collection.
