# Meteor v2

A privacy-focused enhancement system for the Comet browser (Chromium-based by Perplexity).

## Features

- **Complete Telemetry Elimination** - Blocks DataDog, Sentry, Singular, Mixpanel, and Perplexity analytics at multiple layers
- **Full uBlock Origin Support** - MV2 extension with webRequest API for comprehensive ad blocking on all domains
- **MCP Server Management** - Force-enabled MCP UI for local stdio server management (disabled by default on Windows)
- **Native API Access** - Direct access to `chrome.perplexity.*` APIs without CDP/puppeteer complexity
- **Fully Automated** - Single script handles download, setup, patching, and launch

## Architecture

8-layer defense-in-depth system (layers 0-7):

```
LAYER 0: STATIC (PAK)     - Modified resources.pak with disabled telemetry defaults
LAYER 1: LAUNCH (FLAGS)   - Privacy-focused Chromium flags (155 disabled, 10 enabled features)
LAYER 2: SOURCE (EXT)     - Modified perplexity extension with DNR rules
LAYER 3: CONTENT (STUBS)  - SDK stubs injected before CDN scripts load
LAYER 4: NETWORK (DNR)    - 15 declarative net request blocking rules
LAYER 5: ADBLOCK          - uBlock Origin MV2 (41 filter lists) + AdGuard Extra (anti-adblock)
LAYER 6: RUNTIME (PREFS)  - Preference enforcement via chrome.settingsPrivate
LAYER 7: REDIRECT (URLs)  - Force remote perplexity.ai URLs instead of chrome-extension://
```

## Quick Start

### Prerequisites

- Windows 10/11
- PowerShell 5.1+ (included with Windows)

### Installation & Launch

```powershell
# Just run Meteor - it handles everything automatically:
# - Downloads Comet browser if not installed
# - Extracts and patches extensions
# - Downloads uBlock Origin MV2 and AdGuard Extra from Chrome Web Store
# - Launches browser with all enhancements
.\meteor.ps1
```

That's it. Meteor automatically:
1. Detects or downloads Comet browser
2. Checks for updates
3. Extracts CRX extensions from Comet's `default_apps/`
4. Applies Meteor patches (DNR rules, content scripts, preferences)
5. Downloads uBlock Origin MV2 and AdGuard Extra from Chrome Web Store
6. Launches browser with 155 disabled Chromium features

### Options

```powershell
.\meteor.ps1                  # Full automated workflow
.\meteor.ps1 -DryRun          # Show what would be done without making changes
.\meteor.ps1 -Force           # Force re-setup (stops running Comet, clears CRX caches)
.\meteor.ps1 -NoLaunch        # Run setup only, don't launch browser
.\meteor.ps1 -Verbose         # Enable verbose output (PowerShell common parameter)
.\meteor.ps1 -Config path.json # Use alternate configuration file
```

### First Run Verification

After launching, verify the layers are working:

1. **MCP UI**: Navigate to Settings > Connectors - you should see "Custom Connector" button
2. **uBlock**: Check the uBlock Origin popup shows blocking statistics
3. **Telemetry**: Open DevTools Network tab - no requests to datadoghq.com, sentry.io, etc.
4. **New Tab**: Opens https://www.perplexity.ai/b/home instead of chrome://newtab

### Manual Extension Setup for Incognito Mode

**Chrome does not allow programmatically enabling extensions in incognito mode** due to security restrictions. You must manually enable uBlock Origin and AdGuard Extra for incognito/inPrivate windows:

1. Open Comet and go to `chrome://extensions`
2. Find **uBlock Origin**, click **Details**
3. Turn on **Allow in incognito**
4. Find **AdGuard Extra**, click **Details**
5. Turn on **Allow in incognito**

This is a one-time setup. The settings persist across browser restarts.

**Why this is required:** Per [Chrome Enterprise documentation](https://support.google.com/chrome/a/answer/13130396), "As an admin, you can't automatically install extensions in Incognito mode." This is enforced by Chrome's HMAC protection mechanism in the Secure Preferences file. Any attempt to programmatically set incognito permissions is rejected and logged in `tracked_preferences_reset`.

## Directory Structure

```
meteor_v2/
├── meteor.ps1                     # Main script - handles entire workflow
├── config.json                    # All configuration
├── .meteor/                       # Runtime state (auto-generated, gitignored)
│   └── state.json                 # File hashes for change detection
├── patches/perplexity/            # Extension modifications
│   ├── meteor-prefs.js            # Preference enforcement + MCP API
│   ├── telemetry.json             # 15 DNR blocking rules
│   └── content-script.js          # SDK stubs + feature flag interception
└── patched_extensions/            # Generated at runtime (gitignored)
    ├── perplexity/                # Patched Comet extension
    ├── comet_web_resources/       # Patched web resources
    ├── agents/                    # Agents extension (extracted, not patched)
    ├── ublock-origin/             # uBlock Origin MV2 from Chrome Web Store
    └── adguard-extra/             # AdGuard Extra from Chrome Web Store
```

## Configuration

Edit `config.json` to customize:

### Browser Settings
```json
{
  "browser": {
    "profile": "Default",
    "flags": ["--homepage=https://www.perplexity.ai/b/home", "--no-pings"],
    "enable_features": ["AllowLegacyMV2Extensions"],
    "disable_features": ["ExtensionManifestV2DeprecationWarning"]
  }
}
```
- `profile`: Browser profile to use (default: "Default")

### Comet Download
```json
{
  "comet": {
    "download_url": "https://www.perplexity.ai/rest/browser/download?platform=win_x64&channel=stable",
    "install_path": "",
    "auto_update": true
  }
}
```
- `install_path`: Custom path to Comet executable (leave empty for auto-detection)

### Paths
```json
{
  "paths": {
    "patched_extensions": "./patched_extensions",
    "ublock": "./patched_extensions/ublock-origin",
    "adguard_extra": "./patched_extensions/adguard-extra",
    "state_file": "./.meteor/state.json",
    "patches": "./patches"
  }
}
```
- `patched_extensions`: Output directory for all extracted/patched extensions
- `ublock`: Output directory for uBlock Origin MV2 (Chrome Web Store)
- `adguard_extra`: Output directory for AdGuard Extra (Chrome Web Store)
- `state_file`: Path to Meteor state file (tracks file hashes for change detection)
- `patches`: Source directory for Meteor patch files

### Extensions
```json
{
  "extensions": {
    "check_updates": true,
    "sources": ["perplexity", "comet_web_resources", "agents"]
  }
}
```
- `check_updates`: Auto-check for extension updates from their update URLs
- `sources`: Extensions to extract and patch from Comet's `default_apps/` (supports `.crx` and `.crx.disabled`)

## MCP API

Meteor exposes `globalThis.MeteorMCP` in the perplexity extension's service worker:

### Quick Reference

```javascript
// List configured MCP servers
const servers = await MeteorMCP.getServers();

// Add a new stdio server
await MeteorMCP.addServer('my-server', 'npx', ['-y', 'mcp-server'], { ENV_VAR: 'value' });

// Get available tools from a server
const tools = await MeteorMCP.getTools('my-server');

// Call a tool
const result = await MeteorMCP.callTool('my-server', 'tool-name', { arg: 'value' });

// Remove a server
await MeteorMCP.removeServer('my-server');
```

### API Reference

#### `MeteorMCP.getServers()`

Get all configured MCP stdio servers.

**Returns:** `Promise<McpServer[]>`

```typescript
interface McpServer {
  name: string;
  command: string;
  args: string[];
  env: Record<string, string>;
  status: 'pending' | 'running' | 'stopped' | 'error';
}
```

#### `MeteorMCP.addServer(name, command, args?, env?)`

Add a new stdio MCP server.

**Parameters:**
- `name` (string): Unique server identifier
- `command` (string): Command to execute (e.g., 'npx', 'python', 'node')
- `args` (string[], optional): Command arguments
- `env` (object, optional): Environment variables

**Returns:** `Promise<McpServer>`

#### `MeteorMCP.removeServer(name)`

Remove an MCP server by name.

**Returns:** `Promise<void>`

#### `MeteorMCP.getTools(serverName)`

Get available tools from an MCP server.

**Returns:** `Promise<McpTool[]>`

```typescript
interface McpTool {
  name: string;
  description: string;
  inputSchema: object;
}
```

#### `MeteorMCP.callTool(serverName, toolName, args)`

Call a tool on an MCP server.

**Returns:** `Promise<McpToolResult>`

```typescript
interface McpToolResult {
  content: Array<{ type: string; text?: string; data?: string }>;
  isError?: boolean;
}
```

### Usage Example

```javascript
// Set up a complete MCP server
await MeteorMCP.addServer(
  'filesystem',
  'npx',
  ['-y', '@anthropic/mcp-server-filesystem', '/home/user'],
  { DEBUG: 'true' }
);

// Wait for server to initialize
await new Promise(resolve => setTimeout(resolve, 2000));

// Get and use tools
const tools = await MeteorMCP.getTools('filesystem');
const result = await MeteorMCP.callTool('filesystem', 'read_file', {
  path: '/home/user/document.txt'
});
console.log(result.content[0].text);
```

### Feature Flags

Meteor force-enables these MCP-related feature flags:

| Flag | Value | Effect |
|------|-------|--------|
| `comet-mcp-enabled` | `true` | Enables MCP server management UI |
| `custom-remote-mcps` | `true` | Enables remote HTTP/HTTPS MCP servers |
| `comet-dxt-enabled` | `true` | Enables Desktop Extension packages |

## Troubleshooting

### Browser Won't Launch

**Symptom:** "Could not find Comet browser"

**Solutions:**
1. Let Meteor download it automatically (just run `.\meteor.ps1`)
2. Or install Comet manually from https://perplexity.ai/comet
3. Common installation paths (searched in order):
   - `%LOCALAPPDATA%\Perplexity\Comet\Application\comet.exe`
   - `%LOCALAPPDATA%\Comet\Application\comet.exe`
   - `%PROGRAMFILES%\Comet\Application\comet.exe`
   - `%PROGRAMFILES(x86)%\Comet\Application\comet.exe`

### MCP UI Not Visible

**Symptom:** No "Custom Connector" button in Settings > Connectors

**Solutions:**
1. Check DevTools Console for: `[Meteor] Content script active`
2. Clear browser cache (SPA may cache old feature flags)
3. Restart browser completely

**Debug:**
```javascript
// In DevTools console
window.__meteorFeatureFlags?.getAll()
// Should show comet-mcp-enabled: true
```

### uBlock Origin MV2 Deprecation Warning

**Symptom:** Browser shows "This extension may soon be unsupported"

**Solution:** Verify `config.json` includes these disabled features:
```json
{
  "browser": {
    "disable_features": [
      "ExtensionManifestV2DeprecationWarning",
      "ExtensionManifestV2Disabled",
      "ExtensionManifestV2Unsupported"
    ]
  }
}
```

### Telemetry Still Getting Through

**Symptom:** Network tab shows requests to telemetry endpoints

**Diagnosis:**
1. Check DNR rules: `chrome://extensions` > perplexity extension > declarativeNetRequest rules
2. Check content scripts: Look for `[Meteor] Content script active` in console
3. Check uBlock filters: uBlock dashboard > "My filters" should contain Meteor rules

**Manual verification:**
```javascript
// Should return stubs, not real objects
console.log(window.DD_RUM);
console.log(window.Sentry);
console.log(window.mixpanel);
```

### New Tab Opens Local Page

**Symptom:** New tab shows `chrome://newtab` instead of `perplexity.ai/b/home`

**Solutions:**
1. Check console for: `[Meteor] Remote URL redirection active`
2. Restart browser completely (service worker may be cached)
3. Force re-setup: `.\meteor.ps1 -Force`

### Extension Fails to Load

**Symptom:** `chrome://extensions` shows error for perplexity extension

**Solutions:**
1. Validate JSON: `Get-Content patched_extensions\perplexity\manifest.json | ConvertFrom-Json`
2. Force re-setup: `.\meteor.ps1 -Force`
3. Check for missing files in patched extension

### Getting Help

1. Check console logs for `[Meteor]` prefixed messages
2. Review extension errors at `chrome://extensions`
3. Verify network blocking in DevTools Network tab

## License

MIT
