# Meteor v2 Troubleshooting Guide

## Common Issues

### Browser Won't Launch

**Symptom:** `launcher.py` reports "Could not find Comet browser"

**Solutions:**

1. Specify the browser path explicitly:
   ```bash
   python launcher/launcher.py --browser "C:\Path\To\comet.exe"
   ```

2. Or edit `launcher/config.yaml`:
   ```yaml
   browser:
     executable: "C:\\Path\\To\\comet.exe"
   ```

3. Common installation paths:
   - Windows: `%LOCALAPPDATA%\Comet\Application\comet.exe`
   - macOS: `/Applications/Comet.app/Contents/MacOS/Comet`
   - Linux: `/opt/comet/comet` or `/usr/bin/comet`

---

### Patched Extensions Not Found

**Symptom:** `setup.py` reports extensions not found

**Solutions:**

1. Run extraction first:
   ```bash
   python tools/extract_all.py
   ```

2. Specify the Comet directory:
   ```bash
   python tools/setup.py --comet-dir "C:\Path\To\Comet\Application\143.1.7499.35382"
   ```

3. Verify `Extracted/perplexity/` exists

---

### MCP UI Not Visible

**Symptom:** No "Custom Connector" button in Settings > Connectors

**Possible Causes:**

1. **Feature flags not intercepted**
   - Open DevTools Console
   - Look for: `[Meteor] Feature flag interceptor active`
   - If missing, content scripts may not be injected

2. **Content scripts not running**
   - Check `chrome://extensions`
   - Verify perplexity extension shows Meteor modifications

3. **Clear browser cache**
   - The SPA may be using cached feature flags
   - Clear cache and restart browser

**Debug:**
```javascript
// In DevTools console
window.__meteorFeatureFlags?.getAll()
// Should show comet-mcp-enabled: true
```

---

### uBlock Origin MV2 Deprecation Warning

**Symptom:** Browser shows "This extension may soon be unsupported"

**Solutions:**

1. Verify `disable_features` in config.yaml includes:
   ```yaml
   - "ExtensionManifestV2DeprecationWarning"
   - "ExtensionManifestV2Disabled"
   - "ExtensionManifestV2Unsupported"
   ```

2. Re-launch with full flags:
   ```bash
   python launcher/launcher.py
   ```

---

### Telemetry Still Getting Through

**Symptom:** Network tab shows requests to telemetry endpoints

**Diagnosis:**

1. **Check DNR rules loaded:**
   - Open `chrome://extensions`
   - Click on perplexity extension
   - Check for declarativeNetRequest rules

2. **Check content scripts running:**
   - Open DevTools Console
   - Look for: `[Meteor] SDK neutralizer active`

3. **Check uBlock filters:**
   - Click uBlock icon
   - Open dashboard
   - Verify "My filters" contains Meteor rules

**Manual Verification:**
```javascript
// Should return stubs, not real objects
console.log(window.DD_RUM);
console.log(window.Sentry);
console.log(window.mixpanel);
```

---

### New Tab Opens Local Page Instead of Remote

**Symptom:** New tab shows `chrome://newtab` instead of `perplexity.ai/b/home`

**Solutions:**

1. **Check meteor-prefs.js is loaded:**
   - Look in console for: `[Meteor] Remote URL redirection active`

2. **Check service-worker-loader.js modification:**
   ```bash
   cat patched_extensions/perplexity/service-worker-loader.js
   ```
   Should start with: `import './meteor-prefs.js';`

3. **Restart browser completely** (service worker may be cached)

---

### Preferences Not Being Enforced

**Symptom:** Settings keep reverting to defaults

**Debug:**

1. Check console for preference errors:
   ```
   [Meteor] Failed to set perplexity.adblock.enabled: ...
   ```

2. Verify `chrome.settingsPrivate` is available:
   ```javascript
   // In extension service worker console
   console.log(chrome.settingsPrivate);
   ```

---

### Extension Fails to Load

**Symptom:** `chrome://extensions` shows error for perplexity extension

**Common Errors:**

1. **Manifest parse error:**
   - Run: `python -m json.tool patched_extensions/perplexity/manifest.json`
   - Fix any JSON syntax errors

2. **Missing files:**
   - Verify `rules/telemetry.json` exists
   - Verify `content/sdk-neutralizer.js` exists
   - Verify `content/feature-flags.js` exists

3. **Re-run setup:**
   ```bash
   rm -rf patched_extensions
   python tools/setup.py
   ```

---

## Debug Mode

### Enable Verbose Logging

1. Edit content scripts to add debug output
2. Check browser console (F12) for `[Meteor]` messages
3. Check extension service worker console

### Verify Installation

```bash
# Check all files present
ls -la patched_extensions/perplexity/
ls -la patched_extensions/perplexity/rules/
ls -la patched_extensions/perplexity/content/
```

### Test DNR Rules Manually

1. Open `chrome://extensions`
2. Enable Developer mode
3. Click on perplexity extension
4. Check "Declarative net request rules" section

---

## Getting Help

1. Check console logs for `[Meteor]` prefixed messages
2. Review extension errors at `chrome://extensions`
3. Verify network blocking in DevTools Network tab
4. Report issues with logs at the project repository
