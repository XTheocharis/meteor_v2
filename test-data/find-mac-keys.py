#!/usr/bin/env python3
"""
Try to find which subset of keys Chromium uses for MAC calculation.

The hypothesis is that Chromium might:
1. Exclude certain runtime-only keys from MAC calculation
2. Use a different set of keys than what's stored in the JSON

This script tests various key combinations to find the one that matches.
"""

import json
import hashlib
import hmac
import itertools
from collections import OrderedDict

# Load test data
with open('browser-state.json') as f:
    browser_state = json.load(f)

with open('secure-preferences.json') as f:
    secure_prefs = json.load(f)

DEVICE_ID = browser_state['device_id']
FILE_SEED = browser_state['file_mac_seed']

# Target: simplest extension
EXT_ID = 'mjdcklhepheaaemphcopihnmjlmjpcnh'
PATH = f'extensions.settings.{EXT_ID}'
EXPECTED_MAC = browser_state['file_macs'][PATH]

value = secure_prefs['extensions']['settings'][EXT_ID]

print(f"Target: {PATH}")
print(f"Expected MAC: {EXPECTED_MAC}")
print(f"Current keys: {sorted(value.keys())}")
print()


def hmac_sha256(key: str, message: str) -> str:
    key_bytes = key.encode('utf-8')
    message_bytes = message.encode('utf-8')
    return hmac.new(key_bytes, message_bytes, hashlib.sha256).hexdigest().upper()


def sort_dict_recursive(obj):
    if isinstance(obj, dict):
        return OrderedDict(sorted((k, sort_dict_recursive(v)) for k, v in obj.items()))
    elif isinstance(obj, list):
        return [sort_dict_recursive(item) for item in obj]
    else:
        return obj


def calc_mac(val):
    sorted_val = sort_dict_recursive(val)
    json_str = json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=False)
    return hmac_sha256(FILE_SEED, DEVICE_ID + PATH + json_str)


# Test 1: Check if any SINGLE key removal produces the correct MAC
print("=" * 60)
print("TEST 1: Removing single keys")
print("=" * 60)

for key in sorted(value.keys()):
    test_val = {k: v for k, v in value.items() if k != key}
    mac = calc_mac(test_val)
    if mac == EXPECTED_MAC:
        print(f"MATCH! Removing '{key}' gives correct MAC")
        break
else:
    print("No single key removal matches")

print()

# Test 2: Check common runtime-only keys that Chromium might exclude
print("=" * 60)
print("TEST 2: Removing common runtime keys")
print("=" * 60)

# Keys that might be runtime-only
runtime_keys = [
    'active_permissions',
    'commands',
    'events',
    'last_update_time',
    'disable_reasons',
    'state',
    'first_install_time',
]

for exclude_list in [
    ['active_permissions'],
    ['commands'],
    ['events'],
    ['disable_reasons'],
    ['active_permissions', 'commands', 'events'],
    runtime_keys,
]:
    test_val = {k: v for k, v in value.items() if k not in exclude_list}
    mac = calc_mac(test_val)
    match = "MATCH!" if mac == EXPECTED_MAC else ""
    print(f"Excluding {exclude_list}: {match or 'no match'}")

print()

# Test 3: Check if maybe ONLY certain keys are included
print("=" * 60)
print("TEST 3: Checking core-only keys")
print("=" * 60)

# Keys that are likely always needed for extension identification
core_keys = [
    'path',
    'location',
    'from_webstore',
    'creation_flags',
    'was_installed_by_default',
    'was_installed_by_oem',
]

test_val = {k: v for k, v in value.items() if k in core_keys}
mac = calc_mac(test_val)
match = "MATCH!" if mac == EXPECTED_MAC else ""
print(f"Core keys only: {match or 'no match'}")

# Try adding keys one by one
print()
print("Building up from core keys:")
current_keys = set(core_keys)
for key in sorted(value.keys()):
    if key not in current_keys:
        test_keys = current_keys | {key}
        test_val = {k: v for k, v in value.items() if k in test_keys}
        mac = calc_mac(test_val)
        match = "MATCH!" if mac == EXPECTED_MAC else ""
        if match:
            print(f"  Adding '{key}': {match}")

print()

# Test 4: Check different JSON formats
print("=" * 60)
print("TEST 4: Different JSON serialization formats")
print("=" * 60)

sorted_val = sort_dict_recursive(value)

# Try with different options
formats = [
    ("Standard", json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=False)),
    ("ASCII", json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=True)),
    ("Spaced ': '", json.dumps(sorted_val, separators=(',', ': '), ensure_ascii=False)),
    ("Spaced ', '", json.dumps(sorted_val, separators=(', ', ':'), ensure_ascii=False)),
    ("Both spaced", json.dumps(sorted_val, separators=(', ', ': '), ensure_ascii=False)),
]

for name, json_str in formats:
    mac = hmac_sha256(FILE_SEED, DEVICE_ID + PATH + json_str)
    match = "MATCH!" if mac == EXPECTED_MAC else ""
    print(f"{name}: {match or 'no match'}")

print()

# Test 5: Check if path separators matter
print("=" * 60)
print("TEST 5: Path separator variations")
print("=" * 60)

# The path has backslashes - test forward slashes
test_val = dict(value)
original_path = test_val['path']
variations = [
    ("Original", original_path),
    ("Forward slashes", original_path.replace('\\', '/')),
    ("Double backslash", original_path.replace('\\', '\\\\')),
]

for name, path_val in variations:
    test_val['path'] = path_val
    mac = calc_mac(test_val)
    match = "MATCH!" if mac == EXPECTED_MAC else ""
    print(f"{name}: {match or 'no match'}")

print()
print("=" * 60)
print("COMPUTED JSON SAMPLE")
print("=" * 60)
sorted_val = sort_dict_recursive(value)
json_str = json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=False)
print(f"Length: {len(json_str)}")
print(f"First 300: {json_str[:300]}")
