# MAC Calculation Test Data

This directory contains browser-captured test data for verifying MAC calculations.

## Files

| File | Description |
|------|-------------|
| `browser-state.json` | Core test data: Device ID, seeds, and browser-generated MACs |
| `secure-preferences.json` | Complete Secure Preferences file from browser |
| `preferences.json` | Complete regular Preferences file from browser |
| `verify-macs.ps1` | PowerShell script to verify MAC calculations |

## Usage

Run from the `meteor_v2` directory:

```powershell
# Basic verification
.\test-data\verify-macs.ps1

# Verbose output (show JSON values for all)
.\test-data\verify-macs.ps1 -Verbose

# Show full JSON values for failed MACs
.\test-data\verify-macs.ps1 -ShowValues

# Filter to specific paths
.\test-data\verify-macs.ps1 -FilterPath "extensions.settings"
.\test-data\verify-macs.ps1 -FilterPath "pinned_tabs"
```

## Key Information

- **Device ID**: `S-1-5-21-2625391329-1236784108-3013698973`
- **File MAC Seed**: Empty string (Comet/non-Chrome branded)
- **Registry MAC Seed**: `ChromeRegistryHashStoreValidationSeed`

## MAC Calculation Formula

```
MAC = HMAC-SHA256(key=seed, message=device_id + path + value_json)
```

## Value Serialization Rules

| Type | Serialization |
|------|--------------|
| null | `""` (empty string, NOT "null") |
| boolean | `"true"` or `"false"` (lowercase) |
| empty array | `"[]"` |
| object | JSON with keys sorted alphabetically |
| string | JSON-quoted |
| number | String representation |

## CRITICAL: Empty Container Pruning

**Chromium's PrefHashCalculator prunes empty containers before MAC calculation!**

When computing MACs for dict/object values:
1. Recursively process all nested structures
2. **Remove** any dict entry whose value is an empty dict `{}` or empty array `[]`
3. Sort remaining keys alphabetically
4. Serialize to compact JSON

Example:
```json
// Original value
{"active_permissions": {"api": [], "host": []}, "location": 8}

// After pruning (for MAC calculation)
{"location": 8}
```

The empty `active_permissions` dict (which contained only empty arrays) is completely removed.

**Note**: List items are NOT pruned, only dict entries. An empty array `[]` as a list item remains.

## Captured State

The data was captured after browser reset the following preferences:
- `pinned_tabs`
- `extensions.settings.ahfgeienlihckogmohjhadlkjgocpleb`
- `extensions.settings.cjpalhdlnbpafiamejdnhcphjbkeiagm`
- `extensions.settings.gkeojjjcdcopjkbelgbcpckplegclfeg`
- `extensions.settings.mcjlamohcooanphmebaiigheeeoplihb`
- `extensions.settings.mhjfbmdgcfjbbpaeojofohoefgiehjai`
- `extensions.settings.mjdcklhepheaaemphcopihnmjlmjpcnh`
- `extensions.settings.npclhjbddhklpbnacpjloidibaggcgon`

The MACs in `browser-state.json` are what the browser considers correct for the
values in `secure-preferences.json`. Use this data to verify our MAC calculation
matches the browser's.

## Verification Results

With the empty container pruning fix, **31 of 33 MACs pass verification**.

### Known Failing MACs (2)

| Extension ID | Name | Status |
|--------------|------|--------|
| `cjpalhdlnbpafiamejdnhcphjbkeiagm` | uBlock Origin | **FAIL** |
| `npclhjbddhklpbnacpjloidibaggcgon` | Agents | **FAIL** |

These 2 extension settings MACs don't match our calculation despite having the
pruning fix. Possible causes:
- Test data capture timing issue
- Additional Chromium serialization quirks for specific extensions
- Extensions may have been in a transitional state during capture

**Recommendation**: Re-capture test data with a fresh browser profile after the
pruning fix is implemented in the main meteor.ps1 script to verify the fix works
for these extensions in practice.
