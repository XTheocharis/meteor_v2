/**
 * Meteor Preference Enforcement
 * =============================
 * Runs in the perplexity extension's service worker context.
 * Has direct access to chrome.perplexity.* and chrome.settingsPrivate APIs.
 *
 * @license MIT
 */

(() => {
  "use strict";

  // ============================================================================
  // FEATURE FLAG OVERRIDES (chrome.perplexity.features interception)
  // ============================================================================
  // Single source of truth: Injected from config.json by meteor.ps1 during patching.
  // This runs in the service worker context BEFORE the extension's background
  // script can use the API, ensuring our overrides take effect.

  // Placeholder replaced by meteor.ps1 with flags from config.json
  const FEATURE_FLAG_OVERRIDES = __METEOR_FEATURE_FLAGS__;

  /**
   * Get the flag type string for a given value.
   */
  function getFlagType(value) {
    if (typeof value === "boolean") return "BOOLEAN";
    if (typeof value === "number") return "NUMBER";
    if (typeof value === "string") return "STRING";
    if (Array.isArray(value)) return "LIST";
    return "DICTIONARY";
  }

  /**
   * Patch chrome.perplexity.features.getFlagValue to return our overrides.
   */
  function patchGetFlagValue() {
    if (!chrome?.perplexity?.features?.getFlagValue) {
      console.warn("[Meteor] chrome.perplexity.features.getFlagValue not available");
      return false;
    }

    const originalGetFlagValue = chrome.perplexity.features.getFlagValue.bind(
      chrome.perplexity.features,
    );

    chrome.perplexity.features.getFlagValue = function (flagName, callback) {
      // Check if we have an override for this flag
      if (flagName in FEATURE_FLAG_OVERRIDES) {
        const value = FEATURE_FLAG_OVERRIDES[flagName];
        const result = {
          name: flagName,
          type: getFlagType(value),
          value: value,
        };

        // Handle both callback and promise styles
        if (typeof callback === "function") {
          callback(result);
          return;
        }
        return Promise.resolve(result);
      }

      // Fall back to original for non-overridden flags
      return originalGetFlagValue(flagName, callback);
    };

    return true;
  }

  /**
   * Patch chrome.perplexity.features.getRegisteredBrowserFlags to include our overrides.
   * This ensures analytics payloads and any code iterating over flags sees our values.
   */
  function patchGetRegisteredBrowserFlags() {
    if (!chrome?.perplexity?.features?.getRegisteredBrowserFlags) {
      console.warn("[Meteor] chrome.perplexity.features.getRegisteredBrowserFlags not available");
      return false;
    }

    const originalGetRegisteredBrowserFlags =
      chrome.perplexity.features.getRegisteredBrowserFlags.bind(chrome.perplexity.features);

    chrome.perplexity.features.getRegisteredBrowserFlags = function (callback) {
      // Wrap the original call to modify the result
      const wrappedCallback = (flags) => {
        // flags is an array of {name, type, value} objects
        const modifiedFlags = flags.map((flag) => {
          if (flag.name in FEATURE_FLAG_OVERRIDES) {
            const value = FEATURE_FLAG_OVERRIDES[flag.name];
            return {
              name: flag.name,
              type: getFlagType(value),
              value: value,
            };
          }
          return flag;
        });

        if (typeof callback === "function") {
          callback(modifiedFlags);
        }
      };

      // Call original with our wrapped callback
      originalGetRegisteredBrowserFlags(wrappedCallback);
    };

    return true;
  }

  /**
   * Patch all feature flag APIs.
   */
  function patchFeatureFlagsAPI() {
    const getFlagValuePatched = patchGetFlagValue();
    const getRegisteredPatched = patchGetRegisteredBrowserFlags();

    if (getFlagValuePatched || getRegisteredPatched) {
      console.log("[Meteor] Feature flags API patched");
    }
  }

  // Patch immediately
  patchFeatureFlagsAPI();

  // ============================================================================
  // CONFIGURATION
  // ============================================================================

  // Only includes preferences that exist in Comet's settingsPrivate API
  // Verified via chrome.settingsPrivate.getAllPrefs() - 210 prefs available
  const ENFORCED_PREFERENCES = {
    // ========================================================================
    // Perplexity-Specific Settings (37 available)
    // ========================================================================

    // Disable built-in adblock (use uBlock instead)
    "perplexity.adblock.enabled": false,
    "perplexity.adblock.fb_embed_default": false,
    "perplexity.adblock.linkedin_embed_default": false,
    "perplexity.adblock.twitter_embed_default": false,
    "perplexity.adblock.whitelist": [],
    "perplexity.adblock.hidden_whitelisted_dst": [],
    "perplexity.adblock.hidden_whitelisted_src": [],

    // Disable telemetry and analytics
    "perplexity.metrics_allowed": false,
    "perplexity.analytics_observer_initialised": false,
    // NOTE: perplexity.feature.* prefs are NOT settingsPrivate prefs.
    // They're managed via chrome.perplexity.features API (no setter available).

    // Disable data collection features
    "perplexity.history_search_enabled": false,
    "perplexity.external_search_enabled": false,
    "perplexity.help_me_with_text.enabled": false,
    "perplexity.proactive_scraping.enabled": false,
    "perplexity.always_allow_browser_agent": false,

    // Disable proactive notifications
    "perplexity.notifications.proactive_assistance.enabled": false,

    // Skip setup/onboarding
    "perplexity.onboarding_completed": true,
    "perplexity.was_site_onboarding_started": true,

    // ========================================================================
    // Chromium Privacy Settings (available in Comet)
    // ========================================================================

    // Search & Omnibox
    "search.suggest_enabled": false,
    "omnibox.prevent_url_elisions": true,

    // Safe Browsing - disable extended reporting
    "safebrowsing.scout_reporting_enabled": false,

    // Disable URL-keyed data collection
    "url_keyed_anonymized_data_collection.enabled": false,

    // Disable feedback
    feedback_allowed: false,

    // UI Preferences
    "browser.show_home_button": true,
  };

  // ============================================================================
  // PREFERENCE ENFORCEMENT
  // ============================================================================

  let isApplying = false;

  async function applyPreferences() {
    if (isApplying || !chrome?.settingsPrivate?.setPref) return;
    isApplying = true;

    try {
      for (const [name, value] of Object.entries(ENFORCED_PREFERENCES)) {
        await new Promise((resolve) => {
          chrome.settingsPrivate.setPref(name, value, "", () => {
            if (chrome.runtime.lastError) {
              console.warn(
                `[Meteor] Failed to set ${name}:`,
                chrome.runtime.lastError.message,
              );
            }
            resolve();
          });
        });
      }
      console.log("[Meteor] Preferences enforced");
    } finally {
      isApplying = false;
    }
  }

  function setupPreferenceMonitor() {
    if (!chrome?.settingsPrivate?.onPrefsChanged) return;

    chrome.settingsPrivate.onPrefsChanged.addListener((prefs) => {
      const changed = prefs.some((p) => p.key in ENFORCED_PREFERENCES);
      if (changed && !isApplying) {
        setTimeout(applyPreferences, 100);
      }
    });
  }

  // ============================================================================
  // MCP CONVENIENCE WRAPPER (Optional - for external access)
  // ============================================================================

  // Direct access to chrome.perplexity.mcp is already available in this context.
  // This wrapper provides a cleaner async/await interface.

  // Helper to promisify chrome.perplexity.mcp methods
  const promisifyMcp =
    (method, defaultValue = undefined) =>
    (...args) =>
      new Promise((resolve, reject) => {
        chrome.perplexity.mcp[method](...args, (result) => {
          chrome.runtime.lastError
            ? reject(new Error(chrome.runtime.lastError.message))
            : resolve(result ?? defaultValue);
        });
      });

  globalThis.MeteorMCP = {
    getServers: promisifyMcp("getStdioServers", []),
    addServer: (name, command, args = [], env = {}) =>
      promisifyMcp("addStdioServer")(name, command, args, env),
    removeServer: promisifyMcp("removeStdioServer"),
    getTools: promisifyMcp("getTools", []),
    callTool: promisifyMcp("callTool"),
  };

  // ============================================================================
  // AUTO-ENABLE INCOGNITO FOR EXTENSIONS
  // ============================================================================

  // Extension IDs to auto-enable in incognito
  const METEOR_EXTENSIONS = {
    cjpalhdlnbpafiamejdnhcphjbkeiagm: "uBlock Origin",
    gkeojjjcdcopjkbelgbcpckplegclfeg: "AdGuard Extra",
  };

  /**
   * Check extension status and log results.
   * Note: Incognito is pre-configured by meteor.ps1 in Secure Preferences.
   * The chrome.management API's incognitoAccess property is unreliable for
   * unpacked extensions, so we just log that extensions are loaded.
   */
  function checkExtensionStatus() {
    if (!chrome?.management?.getAll) return;

    chrome.management.getAll((extensions) => {
      if (chrome.runtime.lastError) return;

      const meteorExts = extensions.filter(
        (e) => METEOR_EXTENSIONS[e.id] && e.enabled,
      );
      if (meteorExts.length > 0) {
        const names = meteorExts.map((e) => METEOR_EXTENSIONS[e.id]).join(", ");
        console.log(`[Meteor] Extensions loaded: ${names}`);
      }
    });
  }

  // ============================================================================
  // INITIALIZATION
  // ============================================================================

  // Apply preferences immediately on service worker startup
  applyPreferences();
  setupPreferenceMonitor();

  // Check extension incognito status
  checkExtensionStatus();

  // Re-apply periodically (catch edge cases)
  setInterval(applyPreferences, 60000);

  console.log("[Meteor] Preference enforcement initialized");
  console.log(
    "[Meteor] Feature flags overridden:",
    Object.keys(FEATURE_FLAG_OVERRIDES).length,
    "flags"
  );
})();
