# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Meteor v2 is a privacy-focused enhancement system for the Comet browser (Chromium-based by Perplexity). It implements an 8-layer defense-in-depth architecture (layers 0-7) to block telemetry, enable uBlock Origin MV2, and force-enable the MCP (Model Context Protocol) UI.

**Platform**: Windows only (PowerShell 5.1+)

## Common Commands

### Running Meteor
```powershell
.\meteor.ps1                  # Full automated workflow: setup, patch, launch (portable mode by default)
.\meteor.ps1 -DryRun          # Show what would be done without making changes
.\meteor.ps1 -Force           # Force re-setup (stops Comet, clears CRX caches, re-downloads browser)
.\meteor.ps1 -NoLaunch        # Run setup only, don't launch browser
.\meteor.ps1 -Config path.json # Use alternate configuration file
.\meteor.ps1 -DataPath "D:\MyComet"  # Use custom directory for browser + user data
.\meteor.ps1 -VerifyPak       # Verify PAK patches are applied (auto-detects PAK location)
.\meteor.ps1 -VerifyPak -PakPath "C:\path\to\resources.pak"  # Verify specific PAK file
.\meteor.ps1 -SkipPak         # Skip PAK processing for faster preference/extension testing
.\meteor.ps1 -Verbose         # Enable verbose output (PowerShell common parameter)
```

### Linting & Formatting
```powershell
# Lint with PS 5.1 compatibility checking (uses PSScriptAnalyzerSettings.psd1)
Invoke-ScriptAnalyzer -Path .\meteor.ps1 -Settings .\PSScriptAnalyzerSettings.psd1

# Format code
$content = Get-Content .\meteor.ps1 -Raw
Invoke-Formatter -ScriptDefinition $content | Set-Content .\meteor.ps1

# Fix missing UTF-8 BOM (if PSUseBOMForUnicodeEncodedFile warning appears)
$content = Get-Content .\meteor.ps1 -Raw
[System.IO.File]::WriteAllText(".\meteor.ps1", $content, [System.Text.UTF8Encoding]::new($true))
```

### Manual Verification (after launch)
1. **MCP UI**: Settings > Connectors should show "Custom Connector" button
2. **uBlock**: Popup should show blocking statistics
3. **Telemetry**: DevTools Network tab should show no requests to datadoghq.com, sentry.io, etc.
4. **New Tab**: Should open https://www.perplexity.ai/b/home

### Browser DevTools Debugging
```javascript
// Check feature flags
window.__meteorFeatureFlags?.getAll()

// Verify SDK stubs are active (should return stub objects, not real SDKs)
window.DD_RUM   // DataDog RUM stub
window.Sentry   // Sentry stub
window.mixpanel // Mixpanel stub

// Access MCP API from service worker context (background page DevTools)
await MeteorMCP.getServers()
```

## Architecture

The system uses 8 layers (0-7), all managed by `meteor.ps1` and configured in `config.json`:

| Layer | Name | Configuration Section |
|-------|------|----------------------|
| 0 | STATIC (PAK) | `pak_modifications` |
| 1 | LAUNCH (FLAGS) | `browser.flags`, `browser.enable_features`, `browser.disable_features` |
| 2 | SOURCE (EXT) | `extensions.patch_config.*.manifest_additions` |
| 3 | CONTENT (STUBS) | `extensions.patch_config.*.copy_files` |
| 4 | NETWORK (DNR) | `patches/perplexity/telemetry.json` |
| 5 | ADBLOCK | `ublock` |
| 6 | RUNTIME (PREFS) | `patches/perplexity/meteor-prefs.js` |
| 7 | REDIRECT (URLs) | `patches/perplexity/meteor-prefs.js` (tabs API) |

### Automated Workflow

When you run `.\meteor.ps1`, it performs these steps automatically:

1. **Step 0: Comet Installation** - Downloads and extracts Comet in portable mode (no system installation required)
2. **Step 1: Comet Update Check** - Checks for and downloads browser updates
3. **Step 2: Extension Update Check** - Queries extension update URLs and downloads newer versions
4. **Step 3: Change Detection** - Compares file hashes to detect if re-patching is needed
5. **Step 4: Extract & Patch** - Extracts CRX files and applies Meteor modifications
6. **Step 5: uBlock Origin** - Downloads uBlock Origin MV2 from Chrome Web Store if not present
7. **Step 5.5: AdGuard Extra** - Downloads AdGuard Extra from Chrome Web Store if not present
8. **Step 6: Launch Browser** - Starts Comet with all privacy enhancements and `--user-data-dir` pointing to the data directory

### Key Files

| File | Purpose |
|------|---------|
| `meteor.ps1` | Main script - handles entire workflow |
| `config.json` | All configuration (browser flags, patches, uBlock) |
| `.meteor/state.json` | Runtime state (file hashes, versions) - auto-generated |
| `.meteor/comet/` | Portable Comet browser (extracted, no install) |
| `.meteor/User Data/` | Browser profile data (bookmarks, cache, extensions) |
| `.meteor/patched_extensions/` | Extracted and patched browser extensions |
| `.meteor/patched_resources/` | Extracted PAK resources (editable text/binary files + manifest.json) |
| `patches/perplexity/telemetry.json` | 26 DNR rules for telemetry blocking + Eppo config fetch blocking |
| `patches/perplexity/meteor-prefs.js` | Service worker preference enforcement |
| `patches/perplexity/content-script.js` | SDK stubs + feature flag interception |

### Portable Mode

By default, Meteor runs in **portable mode** (`config.json: comet.portable = true`):

- **No system installation**: Browser is extracted directly to `.meteor/comet/` using 7-Zip
- **Isolated user data**: All browser data stored in `.meteor/User Data/` via `--user-data-dir`
- **Fully portable**: Copy the entire directory to a USB drive or another machine
- **Custom data path**: Use `-DataPath "D:\CustomPath"` to specify an alternate location

**Requirements for portable mode:**
- 7-Zip must be installed (download from https://7-zip.org)
- Uses the dev channel from Perplexity's download API

**Extraction process** (nested archives):
1. Downloads `comet_latest_intel.exe` (NSIS installer)
2. Extracts `updater.7z` from the installer
3. Navigates `bin\Offline\{GUID}\{GUID}\mini_installer.exe` (GUIDs vary)
4. Extracts `chrome.7z` from mini_installer
5. Copies `Chrome-bin\` contents to `.meteor/comet/`

### Key Components

**meteor.ps1**: Consolidated PowerShell script that:
- Downloads and extracts Comet browser for portable operation (requires 7-Zip)
- Extracts and patches CRX extensions (handles both `.crx` and `.crx.meteor-backup` files)
- Reads/writes Chromium PAK files (v4/v5 format)
- Downloads uBlock Origin MV2 and AdGuard Extra from Chrome Web Store
- Preserves original extension public keys and update URLs for Chrome Web Store updates
- Builds command line with 155 disabled features and 10 enabled features
- Uses `--user-data-dir` to redirect all browser data to the data directory
- Tracks file changes via SHA256 hashes
- Clears Comet's CRX caches during re-patching to ensure changes take effect
- Stops running Comet processes when `-Force` is used

**patches/perplexity/meteor-prefs.js**: Service worker module that:
- Enforces 38 privacy preferences via `chrome.settingsPrivate` (disables adblock, metrics, telemetry, AI features, sync, etc. - sign-in is allowed)
- Exposes `globalThis.MeteorMCP` API wrapping `chrome.perplexity.mcp.*`
- Redirects local URLs (chrome://, comet://) to perplexity.ai via `chrome.tabs` API

**patches/perplexity/content-script.js**: Content script that:
- Pre-defines telemetry SDK globals as no-ops for error prevention (DataDog, Sentry, Mixpanel, Singular) - prevents runtime errors when application code calls SDK methods
- Intercepts Singular SDK script requests and returns stub module - unique defense not covered by DNR since it requires serving replacement JavaScript
- Intercepts Eppo SDK fetch requests (backup for web context - primary mechanism is blob injection in Local State)
- Force-enables MCP UI flags (`comet-mcp-enabled`, `custom-remote-mcps`, `comet-dxt-enabled`)
- Provides backup blocking for internal API endpoints with fake success responses

**patches/perplexity/telemetry.json**: 26 DNR rules (telemetry + Eppo blocking):
- Scripts use `block` action for immediate rejection (avoids 600ms+ ERR_UNSAFE_REDIRECT delays from Chrome rejecting HTTPS→data: URL redirects)
- XHR/fetch/other use `redirect` to `data:application/json,{}` to suppress console errors
- Content-script stubs prevent runtime errors from blocked SDK scripts
- Covers: DataDog RUM, Singular, Mixpanel, Sentry, Intercom, Cloudflare (insights, RUM, challenge-platform)
- **Eppo endpoints ARE blocked** to prevent browser from fetching fresh config that would overwrite our injected blob
- Perplexity internal telemetry (irontail, analytics endpoints)

## Configuration

All settings are in `config.json`. Key sections:
- `comet.download_url`: Download URL for Comet browser (dev channel by default)
- `comet.portable`: Enable portable mode - extract browser directly instead of running installer (default: `true`)
- `browser.flags/enable_features/disable_features`: Chromium launch configuration (21 flags, 10 enabled features, 155 disabled features)
- `extensions.sources`: Extensions to patch (`perplexity`, `comet_web_resources`, `agents`)
- `extensions.patch_config.perplexity`: Patching rules for the perplexity extension
- `pak_modifications`: Regex replacements for resources.pak (currently empty, infrastructure ready)
- `ublock.extension_id` & `ublock.defaults`: Chrome Web Store ID (cjpalhdlnbpafiamejdnhcphjbkeiagm) and filter lists (41 lists + custom telemetry rules)
- `adguard_extra.extension_id`: Chrome Web Store ID (gkeojjjcdcopjkbelgbcpckplegclfeg) for anti-adblock circumvention

## PAK Modifications (Layer 0)

The PAK patching infrastructure allows binary-level modifications to `resources.pak` before the browser loads. This is the most fundamental layer - patches here cannot be circumvented by JavaScript.

### Current Status
The `pak_modifications.modifications` array is currently **empty**. The infrastructure is fully functional and ready to use.

### How to Add PAK Patches

1. **Find the target string** in resources.pak using the browser's DevTools or by extracting the PAK
2. **Create a regex pattern** that uniquely matches the target (escape special regex chars with `\\`)
3. **Define the replacement** - must be the same byte length or the PAK will be rebuilt
4. **Add to config.json**:

```json
"pak_modifications": {
  "enabled": true,
  "modifications": [
    {
      "pattern": "\\[BooleanFlags\\.EXAMPLE\\]:\\s*true",
      "replacement": "[BooleanFlags.EXAMPLE]: false",
      "description": "Human-readable description of what this does"
    }
  ]
}
```

### Patch Entry Fields
| Field | Required | Description |
|-------|----------|-------------|
| `pattern` | Yes | Regex pattern to find in PAK resources (use `\\` to escape) |
| `replacement` | Yes | Literal string to replace matches with |
| `description` | Yes | Human-readable description (shown in logs and verification) |

### Verification
```powershell
# Verify patches are applied to the installed browser
.\meteor.ps1 -VerifyPak

# Verify a specific PAK file
.\meteor.ps1 -VerifyPak -PakPath "C:\path\to\resources.pak"
```

### Technical Details
- Supports PAK format v4 and v5 (little-endian)
- Automatically handles gzip-compressed resources within the PAK
- Creates `.meteor-backup` of original PAK before modification
- Restores from backup when `-Force` is used to ensure clean state
- Patterns are applied to UTF-8 text resources only (binary resources are skipped)

## Local State Management

Meteor enforces chrome://flags settings via the Local State file rather than command-line switches for features that have chrome://flags equivalents.

### Three-Tier Feature Classification

| Category | Enforcement | Example Features |
|----------|-------------|------------------|
| **Local State Features** (~75) | `browser.enabled_labs_experiments` | `ExtensionsOnChromeURLs`, `AutofillUpstream`, `HistoryEmbeddings` |
| **Command-Line Only** (~70+) | `--enable/disable-features` | AI*API, Glic*, Lens*, PerplexityAutoupdate |
| **Comet-Specific** (~5) | `--enable/disable-features` | `PerplexityAutoupdate`, `AllowLegacyMV2Extensions` |

### Why Local State?

1. **User Visibility**: Settings appear correctly in `chrome://flags` UI
2. **No Dual Enforcement**: Avoids conflicts between command-line and Local State
3. **Persistence**: Browser respects Local State after restarts
4. **Reduced Command Line**: Shorter launch command, easier debugging

### Non-Algorithmic Feature-to-Flag Mapping

The mapping from feature names to chrome://flags names is **NOT algorithmic**:

| Feature Name | Flag Name |
|--------------|-----------|
| `ExtensionsOnChromeURLs` | `extensions-on-chrome-urls` (simple kebab) |
| `IsolatedWebApps` | `enable-isolated-web-apps` (added prefix) |
| `UiaProvider` | `enable-ui-automation` (completely different) |
| `ReadAnythingWithReadability` | `enable-reading-mode-experimental-webpage-distilation` |

The complete mapping is in `$script:FeatureToFlagMapping` in the Constants region of `meteor.ps1`.

### Local State File Format

**Path**: `{UserDataPath}/Local State` (User Data root, NOT profile directory)

```json
{
  "browser": {
    "first_run_finished": true,
    "enabled_labs_experiments": [
      "extensions-on-chrome-urls@1",
      "autofill-upstream@2"
    ]
  }
}
```

- `@1` suffix = Enabled
- `@2` suffix = Disabled
- `@0` suffix = Default (not used by Meteor)

### Key Functions

| Function | Purpose |
|----------|---------|
| `Build-EnabledLabsExperiments` | Converts config features to `flag@N` array |
| `Get-CommandLineOnlyFeatures` | Filters features without Local State mappings |
| `Write-LocalState` | Creates new Local State file |
| `Update-LocalStateExperiments` | Merges Meteor experiments with user flags |

### Verification

After launching the browser:
1. Open `chrome://flags`
2. Search for a managed flag (e.g., `extensions-on-chrome-urls`)
3. Should show "Enabled" (blue highlight)
4. Search for `autofill-upstream` - should show "Disabled"

## Chromium Source Reference

The complete Chromium source code is available at `~/chromium/src` for reference during development. Use the Explore subagent to search this codebase when you need to understand Chromium internals such as:
- Preference HMAC calculation (`services/preferences/tracked/pref_hash_calculator.cc`)
- PAK file format (`ui/base/resource/data_pack.cc`)
- Extension loading and CRX format (`extensions/browser/`)
- Feature flags and command-line switches (`chrome/common/chrome_switches.cc`)

## Script Organization

`meteor.ps1` (~5800 lines) is organized into regions (collapsible in PowerShell ISE/VS Code):

| Region | Lines | Key Functions |
|--------|-------|---------------|
| **Constants** | ~200 | `$script:MeteorVersion`, `$script:FeatureToFlagMapping` (157 mappings) |
| **Helper Functions** | ~100 | `Write-Status`, `Compare-Versions`, byte conversion utilities |
| **Configuration** | ~150 | `Get-MeteorConfig`, `Resolve-MeteorPath`, path resolution |
| **State Management** | ~80 | `Get-MeteorState`, `Save-MeteorState`, `Test-FileChanged`, SHA256 tracking |
| **CRX Processing** | ~300 | `Get-CrxManifest`, `Export-CrxToDirectory`, `Get-ChromeExtensionCrx` |
| **PAK Processing** | ~400 | `Read-PakFile`, `Write-PakFile`, `Get-PakResource`, `Set-PakResource`, `Export-PakResources` |
| **Browser Installation** | ~350 | `Get-CometInstallation`, `Install-CometPortable`, `Test-CometUpdate`, `Get-7ZipPath` |
| **uBlock Origin** | ~200 | `Get-UBlockOrigin`, auto-import.js generation, start.js patching |
| **Extension Patching** | ~200 | `Initialize-PatchedExtensions`, manifest additions, service worker injection |
| **Preferences Pre-seeding** | ~900 | HMAC calculation, MAC synchronization, Local State management |
| **Local State Management** | ~250 | `Build-EnabledLabsExperiments`, `Write-LocalState`, `Update-LocalStateExperiments` |
| **Browser Launch** | ~120 | `Build-BrowserCommand`, `Start-Browser`, feature filtering |
| **Main** | ~400 | 6-step orchestration workflow |

### Debug/Test Scripts

**Root level:**
- `test-mac-calculation.ps1` - Standalone HMAC calculation test with known values

**In `test-data/`:**
- `Test-Utilities.ps1` - Shared utility functions for MAC calculation tests (dot-source in other scripts)
- `debug-registry-mac.ps1` - Inspects Windows Registry MAC entries at `HKCU:\SOFTWARE\Perplexity\Comet\PreferenceMACs`
- `debug-mac.ps1` - Dumps MAC structures from Secure Preferences file
- `verify-macs.ps1` - Compares calculated vs stored MACs to find mismatches
- `compare-serialization.ps1` - Tests JSON serialization differences between PowerShell and Chromium
- `debug-types.ps1` - PowerShell type inspection utilities for debugging
- `debug-pdf-viewer.ps1` - PDF viewer extension debugging

## CRX Processing

CRX files are Chrome extension packages. Key operations:

| Function | Purpose |
|----------|---------|
| `Get-CrxManifest` | Reads manifest.json from CRX without full extraction |
| `Export-CrxToDirectory` | Extracts CRX to directory with optional key injection |
| `Get-ChromeExtensionCrx` | Downloads CRX from Chrome Web Store update API |

### CRX Format (v2/v3)
```
[4 bytes] Magic: "Cr24"
[4 bytes] Version (2 or 3)
[4 bytes] Public key length (v2) or header length (v3)
[4 bytes] Signature length (v2 only)
[...] Header/key/signature data
[...] ZIP archive (extension files)
```

### Key Injection

When extracting extensions, `-InjectKey` adds the original public key to `manifest.json`:
```json
{ "key": "BASE64_PUBLIC_KEY", ... }
```

This ensures consistent extension IDs across extractions (ID = first 16 bytes of SHA256(public_key), encoded as a-p).

## HMAC-Based Secure Preferences

Chromium protects certain preferences with HMAC-SHA256 signatures. Meteor must calculate valid MACs when modifying tracked preferences or the browser resets them.

### Dual MAC Synchronization

Comet uses **two independent MAC stores** that must stay synchronized:
1. **Secure Preferences file** (`protection.macs` + `protection.super_mac`)
2. **Windows Registry** (`HKCU:\SOFTWARE\Perplexity\Comet\PreferenceMACs\Default`)

Each store uses a **different HMAC key**:
- **File MACs**: Empty seed for non-Chrome builds (Comet is not `GOOGLE_CHROME_BRANDING`)
- **Registry MACs**: Literal ASCII string `"ChromeRegistryHashStoreValidationSeed"`

### MAC Calculation Formula

```
MAC = HMAC-SHA256(key, device_id + path + value_json)
```

Where:
- `device_id` = Windows SID without RID (e.g., `S-1-5-21-123456789-987654321-555555555`)
- `path` = Preference path (e.g., `extensions.ui.developer_mode`)
- `value_json` = JSON-serialized value matching Chromium's format

### Key Functions

| Function | Purpose |
|----------|---------|
| `Get-WindowsSidWithoutRid` | Extracts machine SID for device ID |
| `Get-PreferenceHmac` | Calculates file MAC (empty seed) |
| `Get-RegistryPreferenceHmac` | Calculates registry MAC (literal seed) |
| `Get-SuperMac` | Calculates global integrity MAC over all MACs |
| `Update-AllMacs` | Recalculates all MACs after preference changes |
| `Set-RegistryPreferenceMacs` | Writes MACs to Windows Registry |
| `ConvertTo-ChromiumJson` | Normalizes JSON to match Chromium's format |
| `ConvertTo-SortedObject` | Sorts keys alphabetically + prunes empty containers |

### Split vs Atomic MACs

Registry stores MACs in two modes:
- **Atomic**: Direct values in `Default` key (e.g., `browser.show_home_button`)
- **Split**: Hierarchical subkeys (e.g., `Default\extensions.settings\{extId}`)

The `extensions.settings` prefix triggers split mode.

### References

- Paper: https://www.cse.chalmers.se/~andrei/cans20.pdf
- Chromium source: `services/preferences/tracked/pref_hash_calculator.cc`
- Device ID: `services/preferences/tracked/device_id_win.cc`

## Preference Storage Locations

Chromium stores preferences in three different locations based on their scope and tracking requirements. Meteor organizes preferences accordingly:

### Storage Location Summary

| Storage | File | Scope | MAC Required |
|---------|------|-------|--------------|
| Secure Preferences | `{Profile}/Secure Preferences` | Profile | Yes (tracked prefs) |
| Regular Preferences | `{Profile}/Preferences` | Profile | No |
| Local State | `{User Data}/Local State` | Machine-wide | No |

### Tracked Preferences (Secure Preferences with MAC)

These require valid HMACs. Verified against `services/preferences/tracked/` in Chromium source:
- `extensions.ui.developer_mode`
- `browser.show_home_button`
- `bookmark_bar.show_apps_shortcut`
- `safebrowsing.enabled` (pref ID 162 in tracked prefs list)

### Profile Preferences (Regular Preferences file)

Registered via `RegisterProfilePrefs()` - stored in profile's Preferences file:
- `enable_a_ping`, `devtools.availability`, `devtools.gen_ai_settings`
- `browser.gemini_settings`, `glic.actuation_on_web`
- `lens.policy.lens_overlay_settings`, `omnibox.ai_mode_settings`
- `net.quic_allowed`
- `safebrowsing.enhanced`, `safebrowsing.password_protection_warning_trigger`, `safebrowsing.scout_reporting_enabled`
- `omnibox.prevent_url_elisions`, `search.suggest_enabled`
- `url_keyed_anonymized_data_collection.enabled`
- `feedback_allowed`, `mv2_deprecation_warning_ack_globally`

### Local State Preferences (Local State file)

Registered via `RegisterLocalStatePrefs()` or policy prefs - machine-wide:
- `policy.lens_desktop_ntp_search_enabled`, `policy.lens_region_search_enabled`
- `browser.default_browser_setting_enabled`
- `domain_reliability.allowed_by_policy`
- `background_mode.enabled`
- `tracking_protection.ip_protection_enabled`
- `update.component_updates_enabled`
- `variations.restrictions_by_policy`
- `worker.service_worker_auto_preload_enabled`

### How to Verify Preference Location

When adding new preferences, check Chromium source:
1. Search for the pref name in `chrome/browser/prefs/` and `components/*/prefs/`
2. Look for `RegisterProfilePrefs()` → Profile Preferences file
3. Look for `RegisterLocalStatePrefs()` → Local State file
4. Check `services/preferences/tracked/` for tracked prefs requiring MAC

## PowerShell 5.1 Compatibility

The script must run on PowerShell 5.1 (Windows default). Key quirks:

| Issue | Workaround |
|-------|-----------|
| `ConvertFrom-Json` converts `[]` to `$null` | Detect empty arrays in raw JSON before parsing |
| Empty arrays unroll to `$null` in pipelines | Use comma operator: `return ,$result` |
| Files without BOM read as ANSI | Ensure UTF-8 BOM (see linting commands) |
| `PSCustomObject` not easily modifiable | Convert to hashtable with `Convert-PSObjectToHashtable` |
| JSON key order not preserved | Use `[ordered]@{}` and `ConvertTo-SortedObject` |

## Critical Rules for Changes

1. **DNR Rules**: Must maintain sequential rule IDs starting from 1 (currently 28 rules, IDs 1-28)
2. **MCP Flags**: These flags MUST be `true` for MCP UI to work:
   - `comet-mcp-enabled`
   - `custom-remote-mcps`
   - `comet-dxt-enabled`
3. **Content Scripts**: Run in `MAIN` world at `document_start` to intercept before CDN scripts
4. **MV2 Flags**: These disable features must remain to allow uBlock MV2:
   - `ExtensionManifestV2DeprecationWarning`
   - `ExtensionManifestV2Disabled`
   - `ExtensionManifestV2Unsupported`
5. **UTF-8 BOM Required**: `meteor.ps1` must have a UTF-8 BOM (byte order mark). PowerShell 5.1 reads files without BOM as ANSI, which corrupts the µ character in embedded uBlock JavaScript and causes parse errors. PSScriptAnalyzer warns via `PSUseBOMForUnicodeEncodedFile` if missing.
6. **7-Zip Required**: Portable mode requires 7-Zip to be installed for extracting nested archives. The script checks standard installation paths and PATH.
7. **Feature Flag System (Two-Tier Architecture)**:
   - **Browser-level (C++)**: `chrome.perplexity.features.getFlagValue()` is a native browser API that fetches from Eppo servers. This is controlled by `--perplexity-eppo-sdk=false` command-line switch. Flags like `nav-logging` and `test-migration-feature` are managed here.
   - **JavaScript-level**: The Eppo JavaScript SDK in resources.pak reads from localStorage/cookies. Content-script sets `eppo_overrides` cookie/localStorage with flag values from `LOCAL_FEATURE_FLAGS`.
   - **Critical**: The `test-migration-feature` flag controls whether the extension uses browser's native API (true) or its own JS SDK (false). Set `--perplexity-eppo-sdk=false` to disable browser's Eppo SDK.
   - **Source of truth**: `LOCAL_FEATURE_FLAGS` in content-script.js for JS-layer flags; `--perplexity-eppo-sdk=false` flag for browser-layer control.
8. **MAC Synchronization**: When modifying tracked preferences, both file MACs AND registry MACs must be updated. Mismatches cause browser crashes or preference resets.
9. **JSON Serialization**: Chromium uses specific JSON formatting (sorted keys, uppercase unicode escapes like `\u003C`, no escaping of `>` or `'`). Use `ConvertTo-ChromiumJson` for MAC calculation.
