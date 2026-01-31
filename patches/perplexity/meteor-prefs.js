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
  // CONSOLE LOG FILTERING (suppress noisy extension logs)
  // ============================================================================
  // Must run FIRST before any extension code loads.

  const SUPPRESSED_LOG_PREFIXES = [
    "[SerpAnalyticsService] [SerpAnalyticsService] Analytics are not allowed by user",
    "[PerplexityMetricSender] [PerplexityMetricSender] Metrics are not allowed by user",
    "[AnalyticsService] Sending batch of events",
    "[AnalyticsService] Event",
    "[AnalyticsService] Start interval for sending events",
    "[PerplexityWebService] Response on request GET_PRIVACY_INFO",
    "[PerplexityWebService] Response on request GET_PERSONAL_SUGGESTIONS",
    "[PerplexityWebService] Response on request GET_TOP_MOST_VISITED_URLS",
    "ir: Network error",
  ];

  function shouldSuppressLog(args) {
    if (args.length === 0) return false;
    const first = args[0];
    if (typeof first !== "string") return false;
    return SUPPRESSED_LOG_PREFIXES.some((prefix) => first.startsWith(prefix));
  }

  const originalConsoleLog = console.log.bind(console);
  const originalConsoleInfo = console.info.bind(console);
  const originalConsoleWarn = console.warn.bind(console);

  console.log = function (...args) {
    if (!shouldSuppressLog(args)) {
      originalConsoleLog(...args);
    }
  };

  console.info = function (...args) {
    if (!shouldSuppressLog(args)) {
      originalConsoleInfo(...args);
    }
  };

  console.warn = function (...args) {
    if (!shouldSuppressLog(args)) {
      originalConsoleWarn(...args);
    }
  };

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
      // Helper to modify flags array with our overrides
      const modifyFlags = (flags) => {
        // flags is an array of {name, type, value} objects
        return flags.map((flag) => {
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
      };

      // If callback provided, use callback style
      if (typeof callback === "function") {
        originalGetRegisteredBrowserFlags((flags) => {
          callback(modifyFlags(flags));
        });
        return;
      }

      // Otherwise return a Promise for async/await support
      return new Promise((resolve) => {
        originalGetRegisteredBrowserFlags((flags) => {
          resolve(modifyFlags(flags));
        });
      });
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

  // Enforced preferences via chrome.settingsPrivate API
  // Placeholder replaced by meteor.ps1 with values from config.json enforced_preferences
  const ENFORCED_PREFERENCES = __METEOR_ENFORCED_PREFERENCES__;

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

  // Extension IDs managed by Meteor
  // Placeholder replaced by meteor.ps1 with values from config.json meteor_extensions
  const METEOR_EXTENSIONS = __METEOR_EXTENSIONS__;

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
  // COORDINATED STARTUP (wait for uBlock before navigating)
  // ============================================================================

  // Homepage URL - placeholder replaced by meteor.ps1
  const HOMEPAGE_URL = __METEOR_HOMEPAGE_URL__;

  // Initialization state tracking
  const initState = {
    meteorReady: false,
    ublockReady: false,
    navigationDone: false,
  };

  /**
   * Navigate to homepage once both Meteor and uBlock are ready.
   * Only runs once per browser session (tracked via chrome.storage.session).
   */
  async function maybeNavigateToHomepage() {
    if (!initState.meteorReady || !initState.ublockReady || initState.navigationDone) {
      return;
    }

    // Check session flag to avoid re-navigation on service worker restarts
    try {
      const { meteorHomepageOpened } = await chrome.storage.session.get("meteorHomepageOpened");
      if (meteorHomepageOpened) {
        console.log("[Meteor] Homepage already opened this session");
        return;
      }
    } catch (e) {
      // chrome.storage.session might not be available in all contexts
    }

    initState.navigationDone = true;

    try {
      await chrome.storage.session.set({ meteorHomepageOpened: true });
    } catch (e) {
      // Ignore if session storage not available
    }

    // Find about:blank tabs (from launch) and navigate to homepage
    // Comet uses both chrome:// and comet:// URL schemes
    const tabs = await chrome.tabs.query({});
    const blankTabs = tabs.filter(
      (t) =>
        t.url === "about:blank" ||
        t.url === "chrome://newtab/" ||
        t.url === "comet://newtab/"
    );

    if (blankTabs.length > 0) {
      console.log(`[Meteor] Navigating ${blankTabs.length} tab(s) to homepage`);
      for (const tab of blankTabs) {
        chrome.tabs.update(tab.id, { url: HOMEPAGE_URL });
      }
    } else {
      console.log("[Meteor] No blank tabs to navigate");
    }
  }

  /**
   * Listen for ready signal from uBlock Origin.
   * uBlock sends { type: 'ublock-ready' } after filter lists are loaded.
   * We debounce the signal because uBlock may briefly report ready, then
   * go back to loading for filter updates, then report ready again.
   */
  let ublockReadyTimeout = null;
  const UBLOCK_READY_DEBOUNCE_MS = 500;

  if (chrome?.runtime?.onMessageExternal) {
    chrome.runtime.onMessageExternal.addListener((message, sender) => {
      if (message?.type === "ublock-ready") {
        console.log("[Meteor] uBlock Origin ready signal received, debouncing...");

        // Clear any pending timeout
        if (ublockReadyTimeout) {
          clearTimeout(ublockReadyTimeout);
        }

        // Wait for signals to settle before marking ready
        ublockReadyTimeout = setTimeout(() => {
          console.log("[Meteor] uBlock Origin ready (debounced)");
          initState.ublockReady = true;
          maybeNavigateToHomepage();
        }, UBLOCK_READY_DEBOUNCE_MS);
      }
    });
    console.log("[Meteor] onMessageExternal listener registered");
  } else {
    console.warn("[Meteor] chrome.runtime.onMessageExternal not available");
  }

  /**
   * Mark Meteor as ready after a short delay to ensure all patches are applied.
   */
  function markMeteorReady() {
    initState.meteorReady = true;
    console.log("[Meteor] Service worker ready");
    maybeNavigateToHomepage();
  }

  // ============================================================================
  // INITIALIZATION
  // ============================================================================

  // Enable BrowserService debug mode via chrome.storage.local
  if (chrome?.storage?.local?.set) {
    chrome.storage.local.set({ "is-debug-mode-enabled": true });
  }

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

  // Mark Meteor ready after initialization completes
  // Small delay ensures all patches have been applied
  setTimeout(markMeteorReady, 100);
})();
