#!/usr/bin/env python3
"""
Debug extension settings JSON serialization.

PURPOSE:
    Deep dive analysis of a specific extension's JSON serialization to understand
    why MAC calculations might fail. Focuses on the comet_web_resources extension
    (mjdcklhepheaaemphcopihnmjlmjpcnh) as a simpler test case.

ANALYSIS PERFORMED:
    1. Raw value inspection - shows the Python dict structure
    2. JSON serialization experiments - tests different options (ASCII, sorting, etc.)
    3. Key order analysis - checks if Chromium stores keys in sorted order
    4. Detailed JSON output - shows first/last 500 chars for comparison

PREREQUISITES:
    - browser-state.json: Contains device_id and expected MACs
    - secure-preferences.json: Copy of Secure Preferences file from browser

USAGE:
    python debug-extension.py

NOTE:
    This script tests a single extension to simplify debugging. If the calculated
    MAC matches for this simpler extension, the core algorithm is correct.
"""

import json
import hashlib
import hmac
from collections import OrderedDict

# Load test data
with open('browser-state.json') as f:
    browser_state = json.load(f)

with open('secure-preferences.json') as f:
    secure_prefs = json.load(f)

DEVICE_ID = browser_state['device_id']
FILE_SEED = browser_state['file_mac_seed']

# Pick the simplest extension - comet_web_resources
EXT_ID = 'mjdcklhepheaaemphcopihnmjlmjpcnh'
PATH = f'extensions.settings.{EXT_ID}'
EXPECTED_MAC = browser_state['file_macs'][PATH]

print(f"Analyzing: {PATH}")
print(f"Expected MAC: {EXPECTED_MAC}")
print()

# Get the value
value = secure_prefs['extensions']['settings'][EXT_ID]

print("=" * 80)
print("RAW VALUE (Python dict)")
print("=" * 80)
print(json.dumps(value, indent=2))
print()

def sort_dict_recursive(obj):
    """Recursively sort dictionary keys alphabetically."""
    if isinstance(obj, dict):
        return OrderedDict(sorted((k, sort_dict_recursive(v)) for k, v in obj.items()))
    elif isinstance(obj, list):
        return [sort_dict_recursive(item) for item in obj]
    else:
        return obj

def hmac_sha256(key: str, message: str) -> str:
    """Calculate HMAC-SHA256."""
    key_bytes = key.encode('utf-8')
    message_bytes = message.encode('utf-8')
    return hmac.new(key_bytes, message_bytes, hashlib.sha256).hexdigest().upper()

# Different JSON serialization approaches
print("=" * 80)
print("JSON SERIALIZATION EXPERIMENTS")
print("=" * 80)
print()

sorted_val = sort_dict_recursive(value)

# Approach 1: Standard with sorted keys
json1 = json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=False)
mac1 = hmac_sha256(FILE_SEED, DEVICE_ID + PATH + json1)
print(f"1. Standard (ensure_ascii=False):")
print(f"   MAC: {mac1}")
print(f"   Match: {mac1 == EXPECTED_MAC}")
print()

# Approach 2: With ASCII escaping
json2 = json.dumps(sorted_val, separators=(',', ':'), ensure_ascii=True)
mac2 = hmac_sha256(FILE_SEED, DEVICE_ID + PATH + json2)
print(f"2. ASCII escaping (ensure_ascii=True):")
print(f"   MAC: {mac2}")
print(f"   Match: {mac2 == EXPECTED_MAC}")
print()

# Approach 3: Without key sorting
json3 = json.dumps(value, separators=(',', ':'), ensure_ascii=False)
mac3 = hmac_sha256(FILE_SEED, DEVICE_ID + PATH + json3)
print(f"3. No sorting (original order):")
print(f"   MAC: {mac3}")
print(f"   Match: {mac3 == EXPECTED_MAC}")
print()

# Check for specific differences in key order
print("=" * 80)
print("KEY ORDER ANALYSIS")
print("=" * 80)
print()

print("Top-level keys in original order:")
for k in value.keys():
    print(f"  {k}")
print()

print("Top-level keys in sorted order:")
for k in sorted(value.keys()):
    print(f"  {k}")
print()

# Check if there's any difference
original_keys = list(value.keys())
sorted_keys = sorted(value.keys())
if original_keys == sorted_keys:
    print("=> Keys are ALREADY in sorted order!")
else:
    print("=> Keys differ from sorted order")
    for i, (o, s) in enumerate(zip(original_keys, sorted_keys)):
        if o != s:
            print(f"   Position {i}: original='{o}', sorted='{s}'")

print()
print("=" * 80)
print("DETAILED JSON OUTPUT")
print("=" * 80)
print()
print(f"JSON length: {len(json1)} chars")
print()
print("First 500 chars:")
print(json1[:500])
print()
print("Last 500 chars:")
print(json1[-500:])
