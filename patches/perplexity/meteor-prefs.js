/**
 * Meteor Preference Enforcement
 * =============================
 * Runs in the perplexity extension's service worker context.
 * Has direct access to chrome.perplexity.* and chrome.settingsPrivate APIs.
 *
 * @license MIT
 */

(() => {
  'use strict';

  // ============================================================================
  // CONFIGURATION
  // ============================================================================

  const ENFORCED_PREFERENCES = {
    // Disable built-in adblock (use uBlock instead)
    'perplexity.adblock.enabled': false,
    'perplexity.adblock.fb_embed_default': false,
    'perplexity.adblock.linkedin_embed_default': false,
    'perplexity.adblock.twitter_embed_default': false,
    'perplexity.adblock.whitelist': [],

    // Disable telemetry
    'perplexity.metrics_allowed': false,
    'perplexity.analytics_observer_initialised': false,
    'perplexity.feature.nav-logging': false,

    // Disable data collection features
    'perplexity.history_search_enabled': false,
    'perplexity.external_search_enabled': false,
    'perplexity.help_me_with_text.enabled': false,
    'perplexity.proactive_scraping.enabled': false,

    // Feature flags
    'perplexity.feature.adblock-whitelist': {
      whitelist_destinations: [],
      whitelist_sources: []
    },
    'perplexity.feature.Allow-external-extensions-scripting-on-NTP': true,
    'perplexity.feature.navigate-to-perplexity-search-same-doc': false,

    // Skip setup
    'perplexity.onboarding_completed': true
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
          chrome.settingsPrivate.setPref(name, value, '', () => {
            if (chrome.runtime.lastError) {
              console.warn(`[Meteor] Failed to set ${name}:`, chrome.runtime.lastError.message);
            }
            resolve();
          });
        });
      }
      console.log('[Meteor] Preferences enforced');
    } finally {
      isApplying = false;
    }
  }

  function setupPreferenceMonitor() {
    if (!chrome?.settingsPrivate?.onPrefsChanged) return;

    chrome.settingsPrivate.onPrefsChanged.addListener((prefs) => {
      const changed = prefs.some(p => p.key in ENFORCED_PREFERENCES);
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

  globalThis.MeteorMCP = {
    async getServers() {
      return new Promise((resolve, reject) => {
        chrome.perplexity.mcp.getStdioServers((servers) => {
          chrome.runtime.lastError
            ? reject(new Error(chrome.runtime.lastError.message))
            : resolve(servers || []);
        });
      });
    },

    async addServer(name, command, args = [], env = {}) {
      return new Promise((resolve, reject) => {
        chrome.perplexity.mcp.addStdioServer(name, command, args, env, (server) => {
          chrome.runtime.lastError
            ? reject(new Error(chrome.runtime.lastError.message))
            : resolve(server);
        });
      });
    },

    async removeServer(name) {
      return new Promise((resolve, reject) => {
        chrome.perplexity.mcp.removeStdioServer(name, () => {
          chrome.runtime.lastError
            ? reject(new Error(chrome.runtime.lastError.message))
            : resolve();
        });
      });
    },

    async getTools(serverName) {
      return new Promise((resolve, reject) => {
        chrome.perplexity.mcp.getTools(serverName, (tools) => {
          chrome.runtime.lastError
            ? reject(new Error(chrome.runtime.lastError.message))
            : resolve(tools || []);
        });
      });
    },

    async callTool(serverName, toolName, args) {
      return new Promise((resolve, reject) => {
        chrome.perplexity.mcp.callTool(serverName, toolName, args, (result) => {
          chrome.runtime.lastError
            ? reject(new Error(chrome.runtime.lastError.message))
            : resolve(result);
        });
      });
    }
  };

  // ============================================================================
  // REMOTE URL REDIRECTION
  // ============================================================================

  // Force remote perplexity.ai URLs instead of local chrome-extension:// pages
  const REMOTE_URLS = {
    home: 'https://www.perplexity.ai/b/home',
    sidecar: 'https://www.perplexity.ai/sidecar?copilot=true'
  };

  const LOCAL_URL_PATTERNS = [
    // Chrome protocol variants
    'chrome://newtab',
    'chrome://new-tab-page',
    'chrome-extension://mjdcklhepheaaemphcopihnmjlmjpcnh/spa/index.html',
    'chrome-extension://mjdcklhepheaaemphcopihnmjlmjpcnh/spa/ntp.html',
    // Comet protocol variants (aliases)
    'comet://newtab',
    'comet://new-tab-page',
    'comet-extension://mjdcklhepheaaemphcopihnmjlmjpcnh/spa/index.html',
    'comet-extension://mjdcklhepheaaemphcopihnmjlmjpcnh/spa/ntp.html'
  ];

  const SIDECAR_LOCAL_PATTERNS = [
    'chrome-extension://mjdcklhepheaaemphcopihnmjlmjpcnh/sidecar/index.html',
    'comet-extension://mjdcklhepheaaemphcopihnmjlmjpcnh/sidecar/index.html'
  ];

  function shouldRedirectToHome(url) {
    if (!url) return false;
    return LOCAL_URL_PATTERNS.some(pattern => url.startsWith(pattern));
  }

  function shouldRedirectToSidecar(url) {
    if (!url) return false;
    return SIDECAR_LOCAL_PATTERNS.some(pattern => url.startsWith(pattern));
  }

  // Redirect local NTP/homepage URLs to remote
  chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.url) {
      if (shouldRedirectToHome(changeInfo.url)) {
        chrome.tabs.update(tabId, { url: REMOTE_URLS.home });
      } else if (shouldRedirectToSidecar(changeInfo.url)) {
        chrome.tabs.update(tabId, { url: REMOTE_URLS.sidecar });
      }
    }
  });

  // Intercept new tab creation
  chrome.tabs.onCreated.addListener((tab) => {
    if (!tab.url || tab.url === 'chrome://newtab/' || tab.url === 'comet://newtab/' || tab.url === '') {
      chrome.tabs.update(tab.id, { url: REMOTE_URLS.home });
    }
  });

  // ============================================================================
  // INITIALIZATION
  // ============================================================================

  // Apply preferences immediately on service worker startup
  applyPreferences();
  setupPreferenceMonitor();

  // Re-apply periodically (catch edge cases)
  setInterval(applyPreferences, 60000);

  console.log('[Meteor] Preference enforcement initialized');
  console.log('[Meteor] Remote URL redirection active');
})();
