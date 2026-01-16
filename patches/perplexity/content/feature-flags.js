/**
 * Meteor Feature Flags Interceptor
 * =================================
 * Runs at document_start in MAIN world.
 * Intercepts Eppo SDK requests to override feature flags locally.
 * Key functionality: Force-enables MCP UI on Windows (disabled by default).
 *
 * @license MIT
 */
(() => {
  'use strict';

  // ============================================================================
  // LOCAL FEATURE FLAG OVERRIDES (42 flags)
  // ============================================================================

  const LOCAL_FEATURE_FLAGS = {
    // =========================================================================
    // MCP UI FORCE-ENABLE (Windows disabled by default)
    // =========================================================================
    'comet-mcp-enabled': true,        // Main MCP toggle - enables MCP server management UI
    'custom-remote-mcps': true,       // Remote HTTP/HTTPS MCP endpoints with OAuth/API key auth
    'comet-dxt-enabled': true,        // Desktop Extension packages (can bundle MCP servers)

    // =========================================================================
    // DIRECT TELEMETRY (DISABLE)
    // =========================================================================
    'use-mixpanel-analytics': false,        // Mixpanel tracking
    'report-omnibox-text': false,           // Address bar query reporting
    'http-error-monitor': false,            // HTTP error reporting
    'upload-client-context-async': false,   // Context upload to Perplexity
    'cf-ping': false,                       // Cloudflare analytics/heartbeat

    // =========================================================================
    // URL/NAVIGATION TRACKING (DISABLE)
    // =========================================================================
    'send-visited-urls-event-interval-minutes': 999999,  // Effectively disabled
    'browser-analytics-event-blacklist': [
      'page navigation',
      'omnibox navigation completed',
      'urls visited',
      'app entered background',
      'app entered foreground',
      'session start',
      'session end',
      'bookmark actions',
      'comet plus pageview',
      'memory usage',
      'cpu usage',
      'tab count',
      'system log'
    ],
    'show-perplexity-nav-suggestions': false,   // Navigation suggestions
    'nav-intent-classifier': false,             // Navigation intent analysis

    // =========================================================================
    // EXTERNAL SEARCH (ENABLE with privacy settings)
    // =========================================================================
    'enable-external-search': true,             // Enable SERP enhancement
    'external-search-anonymity': { cookies: ['NID', 'AEC', '__Secure-ENID'] },  // Strip tracking cookies
    'enable-external-search-sapi-navigation': false,   // Disable SAPI data sharing

    // =========================================================================
    // AI CONTEXT - History Only (DISABLE history, leave rest as default)
    // =========================================================================
    'browser-history-summary-settings': false,  // Disable history summaries
    'history-summary-cache-ttl-minutes': 0,     // No history caching
    'memory-search-history': false,             // Disable memory search history

    // =========================================================================
    // SHOPPING/ADVERTISING (DISABLE)
    // =========================================================================
    'shopping-enabled': false,
    'shopping-comparison': false,
    'shopping-try-on-enabled': false,
    'enable-sidecar-nudge-for-shopping-assistant': false,
    'paypal-cashback-promo-config': false,      // Disable PayPal promo tracking
    'visa-config': false,                        // Disable Visa integration tracking
    'hotel-discounts-config': false,            // Disable hotel affiliate tracking
    'can-book-hotels': false,
    'get-opentable-enabled': false,

    // =========================================================================
    // UPSELL/PROMO TRACKING (DISABLE)
    // =========================================================================
    'onboarding-comet-upsell': false,
    'onboarding-pro-upsell': false,
    'full-screen-comet-upsell': false,
    'max-upsell': false,
    'pro-free-trial-side-upsell': false,
    'power-user-recruitment-banner': false,
    'spring-2025-referrals-promo': false,
    'assistant-promo-deeplinks': false,

    // =========================================================================
    // YOUTUBE/ADBLOCK (DISABLE auto-whitelist)
    // =========================================================================
    'adblock-youtube-autowhitelist-enabled': false,

    // =========================================================================
    // DISCOVERY/SUGGESTIONS (DISABLE tracking)
    // =========================================================================
    'discover-early-fetch': false,
    'discover-ui-test-2': false,
    'discovery-sidebar-widgets': false,
    'sidecar-personalized-query-suggestions': false,

    // =========================================================================
    // ENTERPRISE TELEMETRY (DISABLE)
    // =========================================================================
    'enterprise-insights': false,
    'enterprise-insights-special-access': false
  };

  // ============================================================================
  // EPPO SDK INTERCEPTION
  // ============================================================================

  const EPPO_ENDPOINTS = [
    'fscdn.eppo.cloud',
    'fs-edge-assignment.eppo.cloud'
  ];

  const originalFetch = window.fetch;

  function isEppoEndpoint(url) {
    if (!url) return false;
    return EPPO_ENDPOINTS.some(endpoint => url.includes(endpoint));
  }

  function getVariationType(value) {
    if (typeof value === 'boolean') return 'BOOLEAN';
    if (typeof value === 'number') {
      return Number.isInteger(value) ? 'INTEGER' : 'NUMERIC';
    }
    if (typeof value === 'string') return 'STRING';
    if (Array.isArray(value) || typeof value === 'object') return 'JSON';
    return 'STRING';
  }

  function createMockEppoConfig() {
    const flags = {};

    for (const [key, value] of Object.entries(LOCAL_FEATURE_FLAGS)) {
      flags[key] = {
        key: key,
        enabled: true,
        variationType: getVariationType(value),
        variations: {
          'local-override': {
            key: 'local-override',
            value: value
          }
        },
        allocations: [
          {
            key: 'default',
            rules: [],
            startAt: null,
            endAt: null,
            splits: [
              {
                variationKey: 'local-override',
                shards: []
              }
            ],
            doLog: false
          }
        ],
        totalShards: 10000
      };
    }

    return {
      flags: flags,
      bandits: {},
      createdAt: new Date().toISOString(),
      format: 'SERVER',
      environment: {
        name: 'local-override'
      }
    };
  }

  // Patch fetch to intercept Eppo requests
  window.fetch = function patchedFetch(input, init) {
    let url = '';

    if (typeof input === 'string') {
      url = input;
    } else if (input instanceof URL) {
      url = input.href;
    } else if (input instanceof Request) {
      url = input.url;
    }

    if (isEppoEndpoint(url)) {
      const mockConfig = createMockEppoConfig();
      return Promise.resolve(new Response(JSON.stringify(mockConfig), {
        status: 200,
        statusText: 'OK',
        headers: {
          'Content-Type': 'application/json',
          'X-Meteor-Intercepted': 'true'
        }
      }));
    }

    return originalFetch.apply(this, arguments);
  };

  // ============================================================================
  // DIRECT EPPO CLIENT PATCHING (Backup)
  // ============================================================================

  function patchEppoClient() {
    const windowKeys = ['eppoClient', 'EppoClient', '__eppo__', '_eppo'];

    for (const key of windowKeys) {
      if (window[key]) {
        patchClientMethods(window[key]);
      }
    }

    // Hook getInstance if available
    try {
      if (window.EppoSdk?.getInstance) {
        const originalGetInstance = window.EppoSdk.getInstance;
        window.EppoSdk.getInstance = function() {
          const client = originalGetInstance.apply(this, arguments);
          patchClientMethods(client);
          return client;
        };
      }
    } catch (e) {
      // Ignore errors
    }
  }

  function patchClientMethods(client) {
    if (!client || client.__meteorPatched) return;

    const methods = [
      'getBooleanAssignment',
      'getStringAssignment',
      'getNumericAssignment',
      'getIntegerAssignment',
      'getJSONAssignment'
    ];

    for (const method of methods) {
      if (typeof client[method] === 'function') {
        const original = client[method].bind(client);
        client[method] = function(flagKey, subjectKey, subjectAttributes, defaultValue) {
          if (LOCAL_FEATURE_FLAGS.hasOwnProperty(flagKey)) {
            return LOCAL_FEATURE_FLAGS[flagKey];
          }
          return original(flagKey, subjectKey, subjectAttributes, defaultValue);
        };
      }
    }

    client.__meteorPatched = true;
  }

  // Run patching attempts
  patchEppoClient();
  setTimeout(patchEppoClient, 100);
  setTimeout(patchEppoClient, 1000);
  setTimeout(patchEppoClient, 5000);

  // ============================================================================
  // EXPORTED UTILITIES
  // ============================================================================

  window.__meteorFeatureFlags = {
    get: (flagKey) => LOCAL_FEATURE_FLAGS[flagKey],
    set: (flagKey, value) => { LOCAL_FEATURE_FLAGS[flagKey] = value; },
    getAll: () => ({ ...LOCAL_FEATURE_FLAGS })
  };

  console.log('[Meteor] Feature flag interceptor active - MCP UI force-enabled');
})();
