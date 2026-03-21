#!/usr/bin/env python3
"""
Generate a cryptographically secure API key for the USBGuard API.

Usage:
    python generate_api_key.py

The key is printed to stdout. Add it to the api_keys list in appsettings.json.

Key rotation workflow (zero downtime):
    1. Run this script to generate a NEW key.
    2. Add the new key to api_keys alongside the existing key(s).
    3. Restart the service (or wait — the new key works immediately after restart).
    4. Update all callers to use the new key.
    5. Remove the old key from api_keys and restart the service.
"""
import secrets

key = secrets.token_urlsafe(32)

print(f"Generated API key:\n\n  {key}\n")
print("Add this to appsettings.json:")
print(f'  "api_keys": ["{key}"]')
print()
print("For rolling rotation (add alongside existing key first):")
print('  "api_keys": [')
print('    "existing-key-here",')
print(f'    "{key}"')
print('  ]')
