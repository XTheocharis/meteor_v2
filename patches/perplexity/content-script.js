/**
 * Meteor Content Script
 * =====================
 * Runs at document_start in MAIN world before any CDN scripts.
 *
 * Functionality:
 * 1. SDK Neutralization - Pre-defines telemetry SDK globals as no-ops
 * 2. Feature Flag Interception - Overrides Eppo SDK to force-enable MCP UI
 * 3. Network Blocking - Patches fetch/XHR/sendBeacon as backup layer
 *
 * @license MIT
 */
(() => {
  'use strict';

  // ============================================================================
  // SECTION 1: TELEMETRY SDK STUBS
  // ============================================================================

  // --------------------------------------------------------------------------
  // DATADOG RUM STUB
  // --------------------------------------------------------------------------

  window.DD_RUM = {
    init: () => {},
    addAction: () => {},
    addError: () => {},
    addTiming: () => {},
    addFeatureFlagEvaluation: () => {},
    setUser: () => {},
    setUserProperty: () => {},
    removeUserProperty: () => {},
    clearUser: () => {},
    startView: () => {},
    stopSession: () => {},
    getInternalContext: () => ({}),
    getInitConfiguration: () => ({}),
    onReady: (cb) => cb?.()
  };
  window.datadogRum = window.DD_RUM;

  // --------------------------------------------------------------------------
  // DATADOG LOGS STUB
  // --------------------------------------------------------------------------

  window.DD_LOGS = {
    init: () => {},
    logger: {
      debug: () => {},
      info: () => {},
      warn: () => {},
      error: () => {},
      log: () => {},
      setContext: () => {},
      setContextProperty: () => {},
      removeContextProperty: () => {},
      clearContext: () => {},
      setHandler: () => {},
      setLevel: () => {},
      getContext: () => ({}),
      getHandler: () => 'http',
      getLevel: () => 'debug'
    },
    setUser: () => {},
    setUserProperty: () => {},
    clearUser: () => {},
    onReady: (cb) => cb?.()
  };
  window.datadogLogs = window.DD_LOGS;

  // --------------------------------------------------------------------------
  // SINGULAR ANALYTICS STUB
  // --------------------------------------------------------------------------

  window.singularSdk = {
    init: () => {},
    event: () => {},
    revenue: () => {},
    setCustomUserId: () => {},
    unsetCustomUserId: () => {},
    setDeviceCustomUserId: () => {},
    unsetDeviceCustomUserId: () => {},
    setGlobalProperty: () => {},
    unsetGlobalProperty: () => {},
    clearGlobalProperties: () => {},
    buildWebToAppLink: () => '',
    openApp: () => {}
  };

  // --------------------------------------------------------------------------
  // SENTRY STUB
  // --------------------------------------------------------------------------

  const sentryNoOp = () => {};
  const sentryHub = {
    bindClient: sentryNoOp,
    getClient: () => undefined,
    getScope: () => ({}),
    getIsolationScope: () => ({}),
    captureException: sentryNoOp,
    captureMessage: sentryNoOp,
    captureEvent: sentryNoOp,
    addBreadcrumb: sentryNoOp,
    setUser: sentryNoOp,
    setTags: sentryNoOp,
    setExtras: sentryNoOp,
    setContext: sentryNoOp,
    run: (cb) => cb?.({}),
    withScope: (cb) => cb?.({}),
    startTransaction: () => ({ finish: sentryNoOp, setTag: sentryNoOp }),
    traceHeaders: () => ({})
  };

  window.Sentry = {
    init: sentryNoOp,
    captureException: sentryNoOp,
    captureMessage: sentryNoOp,
    captureEvent: sentryNoOp,
    addBreadcrumb: sentryNoOp,
    setUser: sentryNoOp,
    setTag: sentryNoOp,
    setTags: sentryNoOp,
    setExtra: sentryNoOp,
    setExtras: sentryNoOp,
    setContext: sentryNoOp,
    configureScope: sentryNoOp,
    withScope: sentryHub.withScope,
    getCurrentHub: () => sentryHub,
    getCurrentScope: () => ({}),
    getIsolationScope: () => ({}),
    startTransaction: sentryHub.startTransaction,
    startSpan: (opts, cb) => cb?.({}),
    startInactiveSpan: () => ({ finish: sentryNoOp }),
    setMeasurement: sentryNoOp,
    close: () => Promise.resolve(true),
    flush: () => Promise.resolve(true),
    lastEventId: () => undefined,
    onLoad: (cb) => cb?.(),
    forceLoad: sentryNoOp,
    showReportDialog: sentryNoOp,
    Integrations: {},
    Handlers: {},
    SDK_VERSION: '0.0.0-meteor-stub'
  };

  // --------------------------------------------------------------------------
  // MIXPANEL STUB
  // --------------------------------------------------------------------------

  window.mixpanel = {
    init: () => {},
    track: () => {},
    track_pageview: () => {},
    identify: () => {},
    alias: () => {},
    people: {
      set: () => {},
      set_once: () => {},
      increment: () => {},
      append: () => {},
      union: () => {},
      track_charge: () => {},
      clear_charges: () => {},
      delete_user: () => {}
    },
    register: () => {},
    register_once: () => {},
    unregister: () => {},
    get_distinct_id: () => 'meteor-stub',
    reset: () => {},
    opt_in_tracking: () => {},
    opt_out_tracking: () => {},
    has_opted_in_tracking: () => false,
    has_opted_out_tracking: () => true,
    get_property: () => undefined,
    set_config: () => {},
    get_config: () => ({})
  };

  // ============================================================================
  // SECTION 2: LOCAL FEATURE FLAG OVERRIDES
  // ============================================================================

  const LOCAL_FEATURE_FLAGS = {
    // MCP UI FORCE-ENABLE (Windows disabled by default)
    'comet-mcp-enabled': true,
    'custom-remote-mcps': true,
    'comet-dxt-enabled': true,

    // DIRECT TELEMETRY (DISABLE)
    'use-mixpanel-analytics': false,
    'report-omnibox-text': false,
    'http-error-monitor': false,
    'upload-client-context-async': false,
    'cf-ping': false,

    // URL/NAVIGATION TRACKING (DISABLE)
    'send-visited-urls-event-interval-minutes': 999999,
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
    'show-perplexity-nav-suggestions': false,
    'nav-intent-classifier': false,

    // EXTERNAL SEARCH (ENABLE with privacy settings)
    'enable-external-search': true,
    'external-search-anonymity': { cookies: ['NID', 'AEC', '__Secure-ENID'] },
    'enable-external-search-sapi-navigation': false,

    // AI CONTEXT - History (DISABLE)
    'browser-history-summary-settings': false,
    'history-summary-cache-ttl-minutes': 0,
    'memory-search-history': false,

    // SHOPPING/ADVERTISING (DISABLE)
    'shopping-enabled': false,
    'shopping-comparison': false,
    'shopping-try-on-enabled': false,
    'enable-sidecar-nudge-for-shopping-assistant': false,
    'paypal-cashback-promo-config': false,
    'visa-config': false,
    'hotel-discounts-config': false,
    'can-book-hotels': false,
    'get-opentable-enabled': false,

    // UPSELL/PROMO TRACKING (DISABLE)
    'onboarding-comet-upsell': false,
    'onboarding-pro-upsell': false,
    'full-screen-comet-upsell': false,
    'max-upsell': false,
    'pro-free-trial-side-upsell': false,
    'power-user-recruitment-banner': false,
    'spring-2025-referrals-promo': false,
    'assistant-promo-deeplinks': false,

    // YOUTUBE/ADBLOCK (DISABLE auto-whitelist)
    'adblock-youtube-autowhitelist-enabled': false,

    // DISCOVERY/SUGGESTIONS (DISABLE tracking)
    'discover-early-fetch': false,
    'discover-ui-test-2': false,
    'discovery-sidebar-widgets': false,
    'sidecar-personalized-query-suggestions': false,

    // ENTERPRISE TELEMETRY (DISABLE)
    'enterprise-insights': false,
    'enterprise-insights-special-access': false
  };

  // ============================================================================
  // SECTION 3: NETWORK REQUEST INTERCEPTION
  // ============================================================================

  const BLOCKED_PATTERNS = [
    'browser-intake-datadoghq.com',
    'sdk-api-v1.singular.net',
    'ingest.sentry.io',
    'api.mixpanel.com',
    'irontail.perplexity.ai',
    '/rest/event/analytics',
    '/rest/attribution/',
    '/cdn-cgi/trace',
    '/api/intercom',
    '/rest/homepage-widgets/upsell/interacted',
    '/rest/ntp/upsell/interacted',
    '/rest/autosuggest/track-query-clicked',
    '/rest/live-events/subscription'
  ];

  const EPPO_ENDPOINTS = [
    'fscdn.eppo.cloud',
    'fs-edge-assignment.eppo.cloud'
  ];

  function getUrlString(input) {
    if (typeof input === 'string') return input;
    if (input instanceof URL) return input.href;
    if (input instanceof Request) return input.url;
    return '';
  }

  function shouldBlock(url) {
    if (!url) return false;
    const urlStr = url.toLowerCase();
    return BLOCKED_PATTERNS.some(pattern => urlStr.includes(pattern.toLowerCase()));
  }

  function isEppoEndpoint(url) {
    if (!url) return false;
    return EPPO_ENDPOINTS.some(endpoint => url.includes(endpoint));
  }

  function getVariationType(value) {
    if (typeof value === 'boolean') return 'BOOLEAN';
    if (typeof value === 'number') return Number.isInteger(value) ? 'INTEGER' : 'NUMERIC';
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
        variations: { 'local-override': { key: 'local-override', value: value } },
        allocations: [{
          key: 'default',
          rules: [],
          startAt: null,
          endAt: null,
          splits: [{ variationKey: 'local-override', shards: [] }],
          doLog: false
        }],
        totalShards: 10000
      };
    }
    return {
      flags: flags,
      bandits: {},
      createdAt: new Date().toISOString(),
      format: 'SERVER',
      environment: { name: 'local-override' }
    };
  }

  // --------------------------------------------------------------------------
  // PATCH FETCH
  // --------------------------------------------------------------------------

  const originalFetch = window.fetch;
  window.fetch = function(input, init) {
    const url = getUrlString(input);

    // Intercept Eppo SDK requests with mock config
    if (isEppoEndpoint(url)) {
      return Promise.resolve(new Response(JSON.stringify(createMockEppoConfig()), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'X-Meteor-Intercepted': 'eppo' }
      }));
    }

    // Block telemetry requests
    if (shouldBlock(url)) {
      return Promise.resolve(new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'X-Meteor-Blocked': 'true' }
      }));
    }

    return originalFetch.apply(this, arguments);
  };

  // --------------------------------------------------------------------------
  // PATCH XMLHTTPREQUEST
  // --------------------------------------------------------------------------

  const originalXHROpen = XMLHttpRequest.prototype.open;
  const originalXHRSend = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    this._meteorUrl = url;
    return originalXHROpen.apply(this, [method, url, ...rest]);
  };

  XMLHttpRequest.prototype.send = function(body) {
    if (shouldBlock(this._meteorUrl)) {
      Object.defineProperty(this, 'status', { value: 200, writable: false });
      Object.defineProperty(this, 'responseText', { value: '{}', writable: false });
      Object.defineProperty(this, 'response', { value: '{}', writable: false });
      Object.defineProperty(this, 'readyState', { value: 4, writable: false });
      setTimeout(() => {
        this.dispatchEvent(new Event('load'));
        this.dispatchEvent(new Event('loadend'));
      }, 0);
      return;
    }
    return originalXHRSend.apply(this, arguments);
  };

  // --------------------------------------------------------------------------
  // PATCH SENDBEACON
  // --------------------------------------------------------------------------

  const originalSendBeacon = navigator.sendBeacon?.bind(navigator);
  if (originalSendBeacon) {
    navigator.sendBeacon = function(url, data) {
      if (shouldBlock(url)) return true;
      return originalSendBeacon(url, data);
    };
  }

  // ============================================================================
  // SECTION 4: EPPO CLIENT DIRECT PATCHING (Backup)
  // ============================================================================

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

  function patchEppoClient() {
    const windowKeys = ['eppoClient', 'EppoClient', '__eppo__', '_eppo'];
    for (const key of windowKeys) {
      if (window[key]) patchClientMethods(window[key]);
    }

    try {
      if (window.EppoSdk?.getInstance) {
        const originalGetInstance = window.EppoSdk.getInstance;
        window.EppoSdk.getInstance = function() {
          const client = originalGetInstance.apply(this, arguments);
          patchClientMethods(client);
          return client;
        };
      }
    } catch (e) { /* ignore */ }
  }

  patchEppoClient();
  setTimeout(patchEppoClient, 100);
  setTimeout(patchEppoClient, 1000);
  setTimeout(patchEppoClient, 5000);

  // ============================================================================
  // SECTION 5: CSS STYLE ENFORCEMENT
  // ============================================================================

  // Enforce Meteor color theme (purple/magenta accent)
  // Equivalent to uBlock rule: www.perplexity.ai##*:style(--max-color: 55% .25 295 !important; --super-color: 55% .25 295 !important;)
  function injectMeteorStyles() {
    if (document.getElementById('meteor-styles')) return;

    const style = document.createElement('style');
    style.id = 'meteor-styles';
    style.textContent = `
      * {
        --max-color: 55% .25 295 !important;
        --super-color: 55% .25 295 !important;
      }
    `;

    // Insert as early as possible
    if (document.head) {
      document.head.appendChild(style);
    } else if (document.documentElement) {
      document.documentElement.appendChild(style);
    } else {
      // Fallback: wait for head to exist
      const observer = new MutationObserver(() => {
        if (document.head) {
          document.head.appendChild(style);
          observer.disconnect();
        }
      });
      observer.observe(document.documentElement || document, { childList: true, subtree: true });
    }
  }

  injectMeteorStyles();

  // ============================================================================
  // SECTION 6: EXPORTED UTILITIES
  // ============================================================================

  window.__meteorFeatureFlags = {
    get: (flagKey) => LOCAL_FEATURE_FLAGS[flagKey],
    set: (flagKey, value) => { LOCAL_FEATURE_FLAGS[flagKey] = value; },
    getAll: () => ({ ...LOCAL_FEATURE_FLAGS })
  };

  console.log('[Meteor] Content script active - SDK stubs + feature flag interception + styles enabled');
})();
