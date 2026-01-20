#!/usr/bin/env python3
"""
Analyze JSON serialization differences between our output and Chromium's.

This script helps debug why MAC calculations differ by:
1. Loading the browser-captured test data
2. Serializing values the way we think Chromium does
3. Calculating MACs and comparing to browser's MACs
"""

import json
import hashlib
import hmac
import sys
from collections import OrderedDict

# Load test data
with open('browser-state.json') as f:
    browser_state = json.load(f)

with open('secure-preferences.json') as f:
    secure_prefs = json.load(f)

DEVICE_ID = browser_state['device_id']
FILE_SEED = browser_state['file_mac_seed']
REGISTRY_SEED = browser_state['registry_mac_seed']


def hmac_sha256(key: str, message: str) -> str:
    """Calculate HMAC-SHA256."""
    key_bytes = key.encode('utf-8')
    message_bytes = message.encode('utf-8')
    return hmac.new(key_bytes, message_bytes, hashlib.sha256).hexdigest().upper()


def prune_empty_recursive(obj):
    """
    Recursively sort dictionary keys and PRUNE empty containers.

    Chromium's PrefHashCalculator removes empty dict {} and list [] values
    from dict entries before computing MACs.
    """
    if isinstance(obj, dict):
        result = OrderedDict()
        for k in sorted(obj.keys()):
            v = prune_empty_recursive(obj[k])
            # PRUNE: Skip empty dicts and empty arrays
            if isinstance(v, dict) and len(v) == 0:
                continue
            if isinstance(v, list) and len(v) == 0:
                continue
            result[k] = v
        return result
    elif isinstance(obj, list):
        # Process list items but don't prune items from lists
        return [prune_empty_recursive(item) for item in obj]
    else:
        return obj


def value_to_json_chromium(value):
    """
    Serialize value to JSON string the way Chromium does it.

    Rules:
    - null -> "" (empty string)
    - boolean -> "true" or "false"
    - array -> "[]" or JSON with sorted keys
    - object -> JSON with keys sorted alphabetically
    - string -> JSON quoted
    - number -> string representation
    """
    if value is None:
        return ""
    elif isinstance(value, bool):
        return "true" if value else "false"
    elif isinstance(value, list):
        if len(value) == 0:
            return "[]"
        sorted_val = prune_empty_recursive(value)
        return json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=False)
    elif isinstance(value, dict):
        sorted_val = prune_empty_recursive(value)
        return json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=False)
    elif isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    elif isinstance(value, (int, float)):
        return str(value)
    else:
        sorted_val = prune_empty_recursive(value)
        return json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=False)


def get_value_at_path(obj, path):
    """Navigate to a value at a dotted path."""
    parts = path.split('.')
    current = obj
    for part in parts:
        if current is None:
            return None
        if isinstance(current, dict):
            current = current.get(part)
        else:
            return None
    return current


def calculate_mac(seed, device_id, path, value):
    """Calculate MAC for a preference."""
    value_json = value_to_json_chromium(value)
    message = device_id + path + value_json
    return hmac_sha256(seed, message)


def main():
    # Filter argument
    filter_path = sys.argv[1] if len(sys.argv) > 1 else ""

    print("=" * 80)
    print("MAC CALCULATION ANALYSIS (Python)")
    print("=" * 80)
    print()
    print(f"Device ID: {DEVICE_ID}")
    print(f"File Seed: '{FILE_SEED}' (empty)")
    print(f"Registry Seed: '{REGISTRY_SEED}'")
    print()

    # Analyze file MACs
    print("=" * 80)
    print("FILE MACs")
    print("=" * 80)
    print()

    passed = 0
    failed = 0
    failed_items = []

    for path, expected_mac in browser_state['file_macs'].items():
        if path == '_description':
            continue
        if filter_path and filter_path not in path:
            continue

        value = get_value_at_path(secure_prefs, path)
        calculated_mac = calculate_mac(FILE_SEED, DEVICE_ID, path, value)

        if calculated_mac == expected_mac:
            print(f"[PASS] {path}")
            passed += 1
        else:
            print(f"[FAIL] {path}")
            failed += 1
            failed_items.append({
                'path': path,
                'expected': expected_mac,
                'calculated': calculated_mac,
                'value': value
            })

    print()
    print(f"Results: {passed} passed, {failed} failed")
    print()

    # Show failed items with details
    if failed_items:
        print("=" * 80)
        print("FAILED ITEMS - DETAILED ANALYSIS")
        print("=" * 80)
        print()

        for item in failed_items[:3]:  # Limit to first 3
            print(f"Path: {item['path']}")
            print(f"Expected MAC:   {item['expected']}")
            print(f"Calculated MAC: {item['calculated']}")
            print()

            value_json = value_to_json_chromium(item['value'])
            message = DEVICE_ID + item['path'] + value_json

            print(f"Message components:")
            print(f"  Device ID: {DEVICE_ID}")
            print(f"  Path:      {item['path']}")
            print(f"  Value JSON length: {len(value_json)}")
            print()

            # Show first/last 200 chars of value JSON
            if len(value_json) > 400:
                print(f"  Value JSON (first 200): {value_json[:200]}...")
                print(f"  Value JSON (last 200):  ...{value_json[-200:]}")
            else:
                print(f"  Value JSON: {value_json}")
            print()
            print("-" * 40)
            print()


if __name__ == '__main__':
    main()
