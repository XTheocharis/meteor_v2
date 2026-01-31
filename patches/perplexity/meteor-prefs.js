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
    "DetailedError: Unhandled external message",
  ];

  function shouldSuppressLog(args) {
    if (args.length === 0) return false;
    const first = args[0];

    // Check string prefixes
    if (typeof first === "string") {
      if (SUPPRESSED_LOG_PREFIXES.some((prefix) => first.startsWith(prefix))) {
        return true;
      }
    }

    // Check for DetailedError objects (Zod validation errors for our messages)
    if (first && typeof first === "object" && first.constructor?.name === "DetailedError") {
      const errorStr = String(first);
      if (errorStr.includes("ublock-ready")) {
        return true;
      }
    }

    return false;
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

  // Debug mode: when true, disables Eppo interception to observe real SDK traffic
  const EPPO_PASSTHROUGH = __METEOR_EPPO_PASSTHROUGH__;

  if (EPPO_PASSTHROUGH) {
    console.log("%c[Meteor SW] EPPO PASSTHROUGH MODE - Eppo overrides disabled for debugging", "color: #f59e0b; font-weight: bold;");
  }

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
   * Patch chrome.perplexity.features.getFlagValue to return our overrides (or just log in passthrough mode).
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
      // In passthrough mode, just log and call original
      if (EPPO_PASSTHROUGH) {
        const wrapCallback = callback ? (result) => {
          console.log(
            `%c[EPPO SW] %cgetFlagValue(%c"${flagName}"%c) = %c${JSON.stringify(result?.value)}`,
            "color: #a855f7; font-weight: bold;",
            "color: #fff",
            "color: #00ffff",
            "color: #fff",
            "color: #22c55e",
          );
          callback(result);
        } : null;
        return originalGetFlagValue(flagName, wrapCallback);
      }

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
      // Helper to modify flags array with our overrides (skipped in passthrough mode)
      const modifyFlags = (flags) => {
        if (EPPO_PASSTHROUGH) {
          console.log(
            `%c[EPPO SW] %cgetRegisteredBrowserFlags() returned %c${flags.length} flags`,
            "color: #a855f7; font-weight: bold;",
            "color: #fff",
            "color: #22c55e",
          );
          return flags;
        }
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
  // EPPO SDK PROBING (Service Worker Context)
  // ============================================================================
  // Intercepts Eppo SDK in the extension's service worker to log flag lookups.

  // Global debug storage for service worker context
  globalThis.__EPPO_DEBUG__ = {
    hashes: {},
    assignments: [],
    log: function (plaintext, hash) {
      if (!plaintext || typeof plaintext !== "string" || this.hashes[hash])
        return;
      this.hashes[hash] = plaintext;
      console.log(
        `%c[EPPO HASH] %c"${plaintext}" %c=> %c${hash}`,
        "color: #a855f7; font-weight: bold;",
        "color: #fff",
        "color: #aaa",
        "color: #00ffff",
      );
    },
  };

  // Detect MD5 hashing logic by checking for MD5 initialization constant
  function isMD5Logic(fn) {
    try {
      return fn.toString().includes("1732584193");
    } catch (e) {
      return false;
    }
  }

  // Apply probes to an object's methods
  function applyEppoProbes(obj, name = "obj") {
    if (!obj || obj.__meteorProbed) return;
    obj.__meteorProbed = true;

    for (const key in obj) {
      try {
        const val = obj[key];
        if (typeof val !== "function") continue;

        // Hook MD5 hashing logic
        if (isMD5Logic(val)) {
          console.log(`%c[Meteor SW] Hooked hasher: ${name}.${key}`, "color: #a855f7");
          const originalHasher = val;
          obj[key] = function (input) {
            const result = originalHasher.apply(this, arguments);
            globalThis.__EPPO_DEBUG__.log(input, result);
            return result;
          };
        }
        // Hook evaluateFlag to see plaintext attributes
        else if (key === "evaluateFlag") {
          console.log(`%c[Meteor SW] Hooked evaluator: ${name}.${key}`, "color: #a855f7");
          const originalEval = val;
          obj[key] = function (flag, env, subject, attrs) {
            console.groupCollapsed(
              `%c[EPPO SW] %cFlag: ${flag?.key || "unknown"}`,
              "color: #a855f7; font-weight: bold;",
              "color: #fff",
            );
            console.log("Attributes:", attrs);
            console.log("Subject:", subject);
            console.groupEnd();

            const result = originalEval.apply(this, arguments);
            globalThis.__EPPO_DEBUG__.assignments.push({ flag, attrs, result });
            return result;
          };
        }
      } catch (e) {
        /* ignore */
      }
    }
  }

  // Patch Eppo client methods for override and logging (or just log in passthrough mode)
  function patchEppoClientMethods(client) {
    if (!client || client.__meteorPatched) return;

    const methods = [
      "getBooleanAssignment",
      "getStringAssignment",
      "getNumericAssignment",
      "getIntegerAssignment",
      "getJSONAssignment",
    ];

    for (const method of methods) {
      if (typeof client[method] === "function") {
        const original = client[method].bind(client);
        client[method] = function (
          flagKey,
          subjectKey,
          subjectAttributes,
          defaultValue,
        ) {
          // In passthrough mode, just log and return original result
          const hasOverride = !EPPO_PASSTHROUGH && flagKey in FEATURE_FLAG_OVERRIDES;
          const result = hasOverride
            ? FEATURE_FLAG_OVERRIDES[flagKey]
            : original(flagKey, subjectKey, subjectAttributes, defaultValue);

          console.log(
            `%c[EPPO SW] %c${method}(%c"${flagKey}"%c) = %c${JSON.stringify(result)}%c${hasOverride ? " (Meteor override)" : ""}`,
            "color: #a855f7; font-weight: bold;",
            "color: #fff",
            "color: #00ffff",
            "color: #fff",
            "color: #22c55e",
            "color: #888",
          );

          return result;
        };
      }
    }

    applyEppoProbes(client, "client");
    if (client.evaluator) applyEppoProbes(client.evaluator, "evaluator");

    client.__meteorPatched = true;
  }

  // Hook into EppoSdk singleton
  function patchEppoSdk(sdk, name = "EppoSdk") {
    if (!sdk || sdk.__meteorHooked) return;
    sdk.__meteorHooked = true;

    applyEppoProbes(sdk, name);

    if (typeof sdk.init === "function") {
      const originalInit = sdk.init;
      sdk.init = async function () {
        console.log(`%c[Meteor SW] Eppo SDK init() intercepted`, "color: #a855f7");
        const client = await originalInit.apply(this, arguments);
        patchEppoClientMethods(client);
        return client;
      };
    }

    if (typeof sdk.getInstance === "function") {
      const originalGetInstance = sdk.getInstance;
      sdk.getInstance = function () {
        const client = originalGetInstance.apply(this, arguments);
        if (client) patchEppoClientMethods(client);
        return client;
      };
    }
  }

  // Try to patch Eppo globals in service worker context
  function patchEppoInServiceWorker() {
    const clientKeys = ["eppoClient", "EppoClient", "__eppo__", "_eppo"];
    for (const key of clientKeys) {
      if (globalThis[key]) patchEppoClientMethods(globalThis[key]);
    }

    const sdkKeys = ["EppoSdk", "eppoSdk", "__eppoSdk__"];
    for (const key of sdkKeys) {
      if (globalThis[key]) patchEppoSdk(globalThis[key], key);
    }
  }

  patchEppoInServiceWorker();
  setTimeout(patchEppoInServiceWorker, 100);
  setTimeout(patchEppoInServiceWorker, 1000);
  setTimeout(patchEppoInServiceWorker, 5000);

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

  // Dynamic DNR rule ID for allow-all (overrides static block-all when uBlock ready)
  const ALLOW_ALL_RULE_ID = 999999;

  // Initialization state tracking
  const initState = {
    meteorReady: false,
    ublockReady: false,
    reloadDone: false,
  };

  /**
   * Add dynamic DNR rule to allow all traffic once uBlock is ready.
   * This overrides the static block-all rule (priority 100) with an allow-all (priority 200).
   * Telemetry rules (priority 300) still take precedence and block telemetry.
   */
  async function enableTrafficFlow() {
    if (!chrome?.declarativeNetRequest?.updateDynamicRules) {
      console.warn("[Meteor] declarativeNetRequest.updateDynamicRules not available");
      return;
    }

    try {
      // Check if already enabled this session
      const { meteorTrafficEnabled } = await chrome.storage.session.get("meteorTrafficEnabled");
      if (meteorTrafficEnabled) {
        console.log("[Meteor] Traffic already enabled this session");
        initState.ublockReady = true;
        return;
      }

      // Allow all subresources - overrides static block-all rule (priority 100)
      const allowRule = {
        id: ALLOW_ALL_RULE_ID,
        priority: 200,
        action: { type: "allow" },
        condition: {
          resourceTypes: [
            "sub_frame", "stylesheet", "script", "image", "font",
            "object", "xmlhttprequest", "ping", "csp_report", "media",
            "websocket", "webtransport", "webbundle", "other"
          ]
        }
      };

      await chrome.declarativeNetRequest.updateDynamicRules({
        removeRuleIds: [ALLOW_ALL_RULE_ID],
        addRules: [allowRule]
      });

      await chrome.storage.session.set({ meteorTrafficEnabled: true });
      console.log("[Meteor] Traffic flow enabled - uBlock is protecting");
    } catch (e) {
      console.error("[Meteor] Failed to enable traffic flow:", e);
    }
  }

  /**
   * Reload tabs once both Meteor and uBlock are ready.
   * Only runs once per browser session (tracked via chrome.storage.session).
   */
  async function maybeReloadTabs() {
    if (!initState.meteorReady || !initState.ublockReady || initState.reloadDone) {
      return;
    }

    // Check session flag to avoid re-reload on service worker restarts
    try {
      const { meteorTabsReloaded } = await chrome.storage.session.get("meteorTabsReloaded");
      if (meteorTabsReloaded) {
        console.log("[Meteor] Tabs already reloaded this session");
        return;
      }
    } catch (e) {
      // chrome.storage.session might not be available in all contexts
    }

    initState.reloadDone = true;

    try {
      await chrome.storage.session.set({ meteorTabsReloaded: true });
    } catch (e) {
      // Ignore if session storage not available
    }

    // Reload all tabs so they load with uBlock protection
    // Include chrome:// and comet:// for NTP which loads perplexity.ai content
    const tabs = await chrome.tabs.query({});
    const reloadableTabs = tabs.filter(
      (t) => t.url && (
        t.url.startsWith("http://") ||
        t.url.startsWith("https://") ||
        t.url.startsWith("chrome://newtab") ||
        t.url.startsWith("comet://newtab")
      )
    );

    if (reloadableTabs.length > 0) {
      console.log(`[Meteor] Reloading ${reloadableTabs.length} tab(s) with uBlock protection`);
      for (const tab of reloadableTabs) {
        chrome.tabs.reload(tab.id);
      }
    } else {
      console.log("[Meteor] No tabs to reload");
    }
  }

  /**
   * Listen for ready signal from uBlock Origin.
   * uBlock sends { type: 'ublock-ready' } after import check completes.
   */
  if (chrome?.runtime?.onMessageExternal) {
    chrome.runtime.onMessageExternal.addListener((message, sender) => {
      if (message?.type === "ublock-ready") {
        console.log("[Meteor] uBlock Origin ready signal received");
        initState.ublockReady = true;
        enableTrafficFlow();
        maybeReloadTabs();
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
    maybeReloadTabs();
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
