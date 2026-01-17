# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Meteor v2 is a privacy-focused enhancement system for the Comet browser (Chromium-based by Perplexity). It implements an 8-layer defense-in-depth architecture (layers 0-7) to block telemetry, enable uBlock Origin MV2, and force-enable the MCP (Model Context Protocol) UI.

**Platform**: Windows only (PowerShell 5.1+)

## Common Commands

### Running Meteor
```powershell
.\meteor.ps1                  # Full automated workflow: setup, patch, launch
.\meteor.ps1 -DryRun          # Show what would be done without making changes
.\meteor.ps1 -Force           # Force re-setup (stops running Comet, clears CRX caches)
.\meteor.ps1 -NoLaunch        # Run setup only, don't launch browser
.\meteor.ps1 -Config path.json # Use alternate configuration file
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

1. **Step 0: Comet Installation** - Downloads and installs Comet if not found
2. **Step 1: Comet Update Check** - Checks for and downloads browser updates
3. **Step 2: Extension Update Check** - Queries extension update URLs and downloads newer versions
4. **Step 3: Change Detection** - Compares file hashes to detect if re-patching is needed
5. **Step 4: Extract & Patch** - Extracts CRX files and applies Meteor modifications
6. **Step 5: uBlock Origin** - Downloads uBlock Origin MV2 if not present
7. **Step 6: Launch Browser** - Starts Comet with all privacy enhancements

### Key Files

| File | Purpose |
|------|---------|
| `meteor.ps1` | Main script - handles entire workflow |
| `config.json` | All configuration (browser flags, patches, uBlock) |
| `.meteor/state.json` | Runtime state (file hashes, versions) - auto-generated |
| `patches/perplexity/telemetry.json` | 15 DNR rules for telemetry blocking |
| `patches/perplexity/meteor-prefs.js` | Service worker preference enforcement |
| `patches/perplexity/content-script.js` | SDK stubs + feature flag interception |

### Key Components

**meteor.ps1**: Consolidated PowerShell script that:
- Auto-detects or downloads Comet browser
- Extracts and patches CRX extensions (handles both `.crx` and `.crx.disabled` files)
- Reads/writes Chromium PAK files (v4/v5 format)
- Manages uBlock Origin MV2 download
- Builds command line with 155 disabled features and 10 enabled features
- Tracks file changes via SHA256 hashes
- Clears Comet's CRX caches during re-patching to ensure changes take effect
- Stops running Comet processes when `-Force` is used

**patches/perplexity/meteor-prefs.js**: Service worker module that:
- Enforces 38 privacy preferences via `chrome.settingsPrivate` (disables adblock, metrics, telemetry, AI features, sync, etc. - sign-in is allowed)
- Exposes `globalThis.MeteorMCP` API wrapping `chrome.perplexity.mcp.*`
- Redirects local URLs (chrome://, comet://) to perplexity.ai via `chrome.tabs` API

**patches/perplexity/content-script.js**: Content script that:
- Pre-defines telemetry SDK globals as no-ops (DataDog, Sentry, Mixpanel, Singular)
- Intercepts Eppo SDK fetch requests and responds with mock config containing local feature flag overrides
- Force-enables MCP UI flags (`comet-mcp-enabled`, `custom-remote-mcps`, `comet-dxt-enabled`)
- Patches fetch/XHR/sendBeacon as backup telemetry blocking layer

**patches/perplexity/telemetry.json**: 15 DNR rules blocking:
- DataDog RUM, Singular, Eppo, Mixpanel, Sentry, Intercom
- Perplexity internal telemetry (irontail, analytics endpoints)

## Configuration

All settings are in `config.json`. Key sections:
- `browser.flags/enable_features/disable_features`: Chromium launch configuration (21 flags, 10 enabled features, 155 disabled features)
- `extensions.sources`: Extensions to patch (`perplexity`, `comet_web_resources`, `agents`)
- `extensions.patch_config.perplexity`: Patching rules for the perplexity extension
- `pak_modifications`: Regex replacements for resources.pak
- `ublock.defaults`: Filter lists and settings (41 lists + custom telemetry rules)

## Critical Rules for Changes

1. **DNR Rules**: Must maintain exactly 15 rules with sequential IDs 1-15
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
