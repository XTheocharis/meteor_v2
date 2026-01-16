# Meteor v2

A privacy-focused enhancement system for the Comet browser (Chromium-based by Perplexity).

## Features

- **Complete Telemetry Elimination** - Blocks DataDog, Sentry, Singular, Mixpanel, and Perplexity analytics at multiple layers
- **Full uBlock Origin Support** - MV2 extension with webRequest API for comprehensive ad blocking on all domains
- **MCP Server Management** - Force-enabled MCP UI for local stdio server management (disabled by default on Windows)
- **Native API Access** - Direct access to `chrome.perplexity.*` APIs without CDP/puppeteer complexity

## Architecture

7-layer defense-in-depth system:

```
LAYER 0: STATIC (PAK)     - Modified resources.pak with disabled telemetry defaults
LAYER 1: LAUNCH (FLAGS)   - Privacy-focused Chromium flags + registry policies
LAYER 2: SOURCE (EXT)     - Modified perplexity extension with DNR rules
LAYER 3: CONTENT (STUBS)  - SDK stubs injected before CDN scripts load
LAYER 4: NETWORK (DNR)    - 16 declarative net request blocking rules
LAYER 5: ADBLOCK (UBLOCK) - uBlock Origin MV2 with 41 filter lists
LAYER 6: RUNTIME (PREFS)  - Preference enforcement via chrome.settingsPrivate
LAYER 7: REDIRECT (URLs)  - Force remote perplexity.ai URLs instead of chrome-extension://
```

## Quick Start

### Prerequisites

- Comet browser installed
- Python 3.10+
- Windows/macOS/Linux

### Installation

```bash
# 1. Install Python dependencies
pip install -r launcher/requirements.txt

# 2. Run one-time setup (extracts and patches extensions)
python tools/setup.py

# 3. (Optional) Apply PAK modifications for Layer 0
python tools/build_pak.py

# 4. Launch Comet with Meteor enhancements
python launcher/launcher.py
```

### First Run Verification

After launching, verify the layers are working:

1. **MCP UI**: Navigate to Settings > Connectors - you should see "Custom Connector" button
2. **uBlock**: Check the uBlock Origin popup shows blocking statistics
3. **Telemetry**: Open DevTools Network tab - no requests to datadoghq.com, sentry.io, etc.
4. **New Tab**: Opens https://www.perplexity.ai/b/home instead of chrome://newtab

## Directory Structure

```
meteor_v2/
├── launcher/           # Browser launcher scripts
│   ├── launcher.py     # Cross-platform Python launcher
│   ├── launcher.ps1    # Windows PowerShell variant
│   └── config.yaml     # Configuration file
├── patches/            # Extension modifications
│   └── perplexity/     # Perplexity extension patches
│       ├── meteor-prefs.js          # Preference enforcement + MCP API
│       ├── manifest.patch.json      # Manifest modifications
│       ├── rules/telemetry.json     # 16 DNR blocking rules
│       └── content/                 # Content scripts
│           ├── sdk-neutralizer.js   # SDK stubs
│           └── feature-flags.js     # Eppo flag interceptor
├── ublock/             # uBlock Origin configuration
│   ├── ublock-defaults.json   # Filter list configuration
│   └── download.py            # Download uBlock MV2
├── tools/              # Setup and build tools
│   ├── setup.py        # One-time extension setup
│   ├── pak_mods.py     # PAK resource modifications
│   └── build_pak.py    # Build modified resources.pak
├── tests/              # Verification tests
└── docs/               # Documentation
```

## Configuration

Edit `launcher/config.yaml` to customize:

- Browser executable path
- Feature flags (103 disabled, 10 enabled)
- Registry policies (Windows)
- Extension paths

## MCP API

Meteor exposes `globalThis.MeteorMCP` in the perplexity extension's service worker:

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

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues.

## License

MIT

## References

- [METEOR_SPEC.md](../METEOR_SPEC.md) - Technical specification
- [Perplexity Extension API](../perplexity_extension_api.md) - Chrome API documentation
- [Browser Settings](../perplexity_browser_settings.md) - Preference documentation
