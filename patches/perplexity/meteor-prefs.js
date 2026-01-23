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

  // Only includes preferences that exist in Comet's settingsPrivate API
  // Verified via chrome.settingsPrivate.getAllPrefs() - 210 prefs available
  const ENFORCED_PREFERENCES = {
    // ========================================================================
    // Perplexity-Specific Settings (37 available)
    // ========================================================================

    // Disable built-in adblock (use uBlock instead)
    'perplexity.adblock.enabled': false,
    'perplexity.adblock.fb_embed_default': false,
    'perplexity.adblock.linkedin_embed_default': false,
    'perplexity.adblock.twitter_embed_default': false,
    'perplexity.adblock.whitelist': [],
    'perplexity.adblock.hidden_whitelisted_dst': [],
    'perplexity.adblock.hidden_whitelisted_src': [],

    // Disable telemetry and analytics
    'perplexity.metrics_allowed': false,
    'perplexity.analytics_observer_initialised': false,

    // Disable data collection features
    'perplexity.history_search_enabled': false,
    'perplexity.external_search_enabled': false,
    'perplexity.help_me_with_text.enabled': false,
    'perplexity.proactive_scraping.enabled': false,
    'perplexity.always_allow_browser_agent': false,

    // Disable proactive notifications
    'perplexity.notifications.proactive_assistance.enabled': false,

    // Skip setup/onboarding
    'perplexity.onboarding_completed': true,
    'perplexity.was_site_onboarding_started': true,

    // ========================================================================
    // Chromium Privacy Settings (available in Comet)
    // ========================================================================

    // Search & Omnibox
    'search.suggest_enabled': false,
    'omnibox.prevent_url_elisions': true,

    // Safe Browsing - disable telemetry but keep protection
    'safebrowsing.scout_reporting_enabled': false,

    // Disable URL-keyed data collection
    'url_keyed_anonymized_data_collection.enabled': false,

    // Disable feedback
    'feedback_allowed': false,

    // UI Preferences
    'browser.show_home_button': true
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
  // AUTO-ENABLE INCOGNITO FOR EXTENSIONS
  // ============================================================================

  // Extension IDs to auto-enable in incognito
  const METEOR_EXTENSIONS = {
    'cjpalhdlnbpafiamejdnhcphjbkeiagm': 'uBlock Origin',
    'gkeojjjcdcopjkbelgbcpckplegclfeg': 'AdGuard Extra'
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

      const meteorExts = extensions.filter(e => METEOR_EXTENSIONS[e.id] && e.enabled);
      if (meteorExts.length > 0) {
        const names = meteorExts.map(e => METEOR_EXTENSIONS[e.id]).join(', ');
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

  console.log('[Meteor] Preference enforcement initialized');
  console.log('[Meteor] Remote URL redirection active');
})();
