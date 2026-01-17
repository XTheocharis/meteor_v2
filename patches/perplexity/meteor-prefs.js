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
    'perplexity.onboarding_completed': true,

    // ========================================================================
    // Chromium Privacy Settings
    // ========================================================================

    // Search & Omnibox
    'search.suggest_enabled': false,

    // Safe Browsing & Security
    'safebrowsing.scout_reporting_enabled': false,
    'safebrowsing.password_protection_warning_trigger': 0,
    'profile.password_dismiss_compromised_alert': false,

    // UI Preferences
    'browser.show_home_button': true,
    'omnibox.prevent_url_elisions': true,
    'bookmark_bar.show_apps_shortcut': false,

    // Sign-in & Profile
    // Note: signin.allowed is NOT set - allow sign-in but disable sync via sync.managed
    'profile.browser_guest_enforced': false,
    'profile.add_person_enabled': false,

    // AI & Lens Features
    'devtools.gen_ai_settings': 2,
    'browser.gemini_settings': 1,
    'lens.policy.lens_overlay_settings': 1,
    'policy.lens_desktop_ntp_search_enabled': false,
    'policy.lens_region_search_enabled': false,

    // ========================================================================
    // Additional Settings
    // ========================================================================

    // Profile & Startup
    'profile.picker_availability_on_startup': 1,  // 1 = disabled

    // Cloud & Auth
    'auth.cloud_ap_auth.enabled': false,

    // Developer Tools
    'devtools.availability': 1,  // 1 = always available

    // Extensions
    'extensions.ui.developer_mode': true,
    'extensions.unpublished_availability': 1,  // 1 = enabled
    'extensions.block_external_extensions': false

    // Feedback & Sync
    'feedback_allowed': false,
    'sync.managed': true  // true = sync disabled/managed
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

  // Intercept new tab creation - but only if there's no pending navigation
  // (browser menus create tabs briefly with empty URL before navigating)
  chrome.tabs.onCreated.addListener((tab) => {
    // Skip if there's a pending navigation (e.g., from browser menu action)
    if (tab.pendingUrl && tab.pendingUrl !== 'chrome://newtab/' && tab.pendingUrl !== 'comet://newtab/') {
      return;
    }
    if (!tab.url || tab.url === 'chrome://newtab/' || tab.url === 'comet://newtab/' || tab.url === '') {
      chrome.tabs.update(tab.id, { url: REMOTE_URLS.home });
    }
  });

  // ============================================================================
  // AUTO-ENABLE INCOGNITO FOR EXTENSIONS
  // ============================================================================

  // Extension IDs to auto-enable in incognito
  const METEOR_EXTENSIONS = {
    'cjpalhdlnbpafiamejdnhcphjbkeiagm': 'uBlock Origin',
    'gkeojjjcdcopjkbelgbcpckplegclfeg': 'AdGuard Extra'
  };

  // Track tabs we've already injected into
  const injectedTabs = new Set();

  /**
   * Check if URL is an extensions page
   */
  function isExtensionsPage(url) {
    if (!url) return false;
    return url.startsWith('chrome://extensions') || url.startsWith('comet://extensions');
  }

  /**
   * Enable incognito access for a specific extension using developerPrivate API
   */
  function enableIncognito(extensionId, extensionName) {
    if (!chrome?.developerPrivate?.updateExtensionConfiguration) {
      console.warn('[Meteor] chrome.developerPrivate API not available');
      return;
    }

    chrome.developerPrivate.updateExtensionConfiguration({
      extensionId: extensionId,
      incognitoAccess: true
    }, () => {
      if (chrome.runtime.lastError) {
        console.warn(`[Meteor] Failed to enable incognito for ${extensionName}:`, chrome.runtime.lastError.message);
      } else {
        console.log(`[Meteor] Enabled incognito for ${extensionName}`);
      }
    });
  }

  /**
   * Check current extension states and enable incognito where needed
   */
  function autoEnableIncognito() {
    if (!chrome?.management?.getAll) {
      console.warn('[Meteor] chrome.management API not available');
      return;
    }

    chrome.management.getAll((extensions) => {
      if (chrome.runtime.lastError) {
        console.warn('[Meteor] Failed to get extensions:', chrome.runtime.lastError.message);
        return;
      }

      for (const extension of extensions) {
        if (METEOR_EXTENSIONS[extension.id]) {
          const extensionName = METEOR_EXTENSIONS[extension.id];
          if (extension.enabled && !extension.incognitoAccess) {
            console.log(`[Meteor] Auto-enabling incognito for ${extensionName}...`);
            enableIncognito(extension.id, extensionName);
          } else if (extension.incognitoAccess) {
            console.log(`[Meteor] ${extensionName} already has incognito access`);
          }
        }
      }
    });
  }

  /**
   * Inject script into chrome://extensions page to enable developerPrivate access
   * Uses programmatic injection since manifest content scripts can't target chrome:// URLs
   */
  async function injectExtensionsPageScript(tabId) {
    if (injectedTabs.has(tabId)) return;
    injectedTabs.add(tabId);

    try {
      // Try to inject using chrome.scripting API
      if (chrome?.scripting?.executeScript) {
        await chrome.scripting.executeScript({
          target: { tabId: tabId },
          files: ['content/extensions-page.js']
        });
        console.log(`[Meteor] Injected extensions-page.js into tab ${tabId}`);
      }
    } catch (err) {
      console.warn(`[Meteor] Failed to inject into extensions page:`, err.message);
      // Remove from set so we can retry
      injectedTabs.delete(tabId);
    }
  }

  // Listen for navigation to extensions page (injection only - redirects handled above)
  chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    // Inject into extensions page when it's loaded
    if (changeInfo.status === 'complete' && tab.url && isExtensionsPage(tab.url)) {
      injectExtensionsPageScript(tabId);
    }
  });

  // Clean up tracking when tabs are closed
  chrome.tabs.onRemoved.addListener((tabId) => {
    injectedTabs.delete(tabId);
  });

  // Also monitor for extension installations/updates
  if (chrome?.management?.onInstalled) {
    chrome.management.onInstalled.addListener((extensionInfo) => {
      if (METEOR_EXTENSIONS[extensionInfo.id]) {
        const extensionName = METEOR_EXTENSIONS[extensionInfo.id];
        console.log(`[Meteor] ${extensionName} installed, enabling incognito...`);
        // Small delay to ensure extension is fully registered
        setTimeout(() => enableIncognito(extensionInfo.id, extensionName), 500);
      }
    });
  }

  // ============================================================================
  // INITIALIZATION
  // ============================================================================

  // Apply preferences immediately on service worker startup
  applyPreferences();
  setupPreferenceMonitor();

  // Try to enable incognito for extensions on startup
  autoEnableIncognito();

  // Re-apply periodically (catch edge cases)
  setInterval(applyPreferences, 60000);

  console.log('[Meteor] Preference enforcement initialized');
  console.log('[Meteor] Remote URL redirection active');
  console.log('[Meteor] Auto-incognito enablement active');
})();
