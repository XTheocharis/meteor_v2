/**
 * Meteor SDK Neutralizer
 * =======================
 * Runs at document_start in MAIN world before any CDN scripts.
 * Pre-defines telemetry SDK globals as no-ops so real SDKs don't initialize.
 *
 * @license MIT
 */
(() => {
  'use strict';

  // ============================================================================
  // DATADOG RUM STUB
  // ============================================================================

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

  // ============================================================================
  // DATADOG LOGS STUB
  // ============================================================================

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

  // ============================================================================
  // SINGULAR ANALYTICS STUB
  // ============================================================================

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

  // ============================================================================
  // SENTRY STUB
  // ============================================================================

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

  // ============================================================================
  // MIXPANEL STUB
  // ============================================================================

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
  // FETCH/XHR/SENDBEACON PATCHING (Backup Layer)
  // ============================================================================

  const BLOCKED_PATTERNS = [
    'browser-intake-datadoghq.com',
    'sdk-api-v1.singular.net',
    'ingest.sentry.io',
    'api.mixpanel.com',
    'fscdn.eppo.cloud',
    'fs-edge-assignment.eppo.cloud',
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

  function shouldBlock(url) {
    if (!url) return false;
    const urlStr = url.toString().toLowerCase();
    return BLOCKED_PATTERNS.some(pattern => urlStr.includes(pattern.toLowerCase()));
  }

  // Patch fetch
  const originalFetch = window.fetch;
  window.fetch = function(input, init) {
    const url = typeof input === 'string' ? input :
                input instanceof URL ? input.href :
                input instanceof Request ? input.url : '';

    if (shouldBlock(url)) {
      return Promise.resolve(new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'X-Meteor-Blocked': 'true' }
      }));
    }
    return originalFetch.apply(this, arguments);
  };

  // Patch XMLHttpRequest
  const originalXHROpen = XMLHttpRequest.prototype.open;
  const originalXHRSend = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    this._meteorUrl = url;
    return originalXHROpen.apply(this, [method, url, ...rest]);
  };

  XMLHttpRequest.prototype.send = function(body) {
    if (shouldBlock(this._meteorUrl)) {
      // Simulate successful empty response
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

  // Patch sendBeacon
  const originalSendBeacon = navigator.sendBeacon?.bind(navigator);
  if (originalSendBeacon) {
    navigator.sendBeacon = function(url, data) {
      if (shouldBlock(url)) return true;
      return originalSendBeacon(url, data);
    };
  }

  console.log('[Meteor] SDK neutralizer active - telemetry stubs in place');
})();
