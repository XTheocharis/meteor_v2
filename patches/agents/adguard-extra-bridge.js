/**
 * AdGuard Extra Bridge (ISOLATED World)
 * =====================================
 * Relays GM_xmlhttpRequest calls from MAIN world to the extension background.
 *
 * Communication flow:
 * 1. MAIN world posts message to window
 * 2. This script receives it and makes fetch request (ISOLATED world has CORS bypass)
 * 3. This script posts the response back to MAIN world
 */
(() => {
  'use strict';

  // ==========================================================================
  // URL Exclusion Check (dynamic, no manifest rebuild needed)
  // ==========================================================================

  const EXCLUDED_PATTERNS = [
    /^https?:\/\/captcha-api\.yandex\.ru\//i,
    /^https?:\/\/ya\.ru\/showcaptcha/i,
    /^https?:\/\/[^/]*mil\.ru\//i,
    /^https?:\/\/[^/]*\.wikipedia\.org\//i,
    /^https?:\/\/[^/]*\.icloud\.com\//i,
    /^https?:\/\/hangouts\.google\.com\//i,
    /^https?:\/\/www\.facebook\.com\/plugins\//i,
    /^https?:\/\/www\.facebook\.com\/v[^/]*\/plugins/i,
    /^https?:\/\/disqus\.com\/embed\/comments/i,
    /^https?:\/\/vk\.com\/widget/i,
    /^https?:\/\/twitter\.com\/intent\//i,
    /^https?:\/\/www\.youtube\.com\/embed\//i,
    /^https?:\/\/player\.vimeo\.com\//i,
    /^https?:\/\/coub\.com\/embed/i,
    /^https?:\/\/staticxx\.facebook\.com\/connect\/xd_arbiter\//i,
    /^https?:\/\/vk\.com\/q_frame/i,
    /^https?:\/\/tpc\.googlesyndication\.com\//i,
    /^https?:\/\/syndication\.twitter\.com\//i,
    /^https?:\/\/platform\.twitter\.com\//i,
    /^https?:\/\/notifications\.google\.com\//i,
    /^https?:\/\/[^/]*google\.com\/recaptcha\//i,
    /^https?:\/\/[^/]*\.perplexity\.ai\/sidecar\//i
  ];

  function isExcluded(url) {
    return EXCLUDED_PATTERNS.some(pattern => pattern.test(url));
  }

  // Check if current URL should be excluded
  if (isExcluded(window.location.href)) {
    return; // Exit early, don't set up bridge on excluded URLs
  }

  // ==========================================================================
  // GM_xmlhttpRequest Bridge
  // ==========================================================================

  const CHANNEL = 'meteor-gm-xmlhttprequest';

  // Listen for requests from MAIN world
  window.addEventListener('message', async (event) => {
    if (event.source !== window) return;
    if (event.data?.channel !== CHANNEL) return;
    if (event.data?.type !== 'request') return;

    const { id, details } = event.data;

    try {
      // Make the request using fetch (we're in ISOLATED world with extension permissions)
      const fetchOptions = {
        method: details.method || 'GET',
        headers: details.headers || {},
        credentials: 'omit',
        mode: 'cors'
      };

      if (details.data && details.method !== 'GET') {
        fetchOptions.body = details.data;
      }

      const response = await fetch(details.url, fetchOptions);
      const responseText = await response.text();

      // Build response object similar to GM_xmlhttpRequest
      const gmResponse = {
        finalUrl: response.url,
        readyState: 4,
        status: response.status,
        statusText: response.statusText,
        responseHeaders: [...response.headers.entries()]
          .map(([k, v]) => `${k}: ${v}`)
          .join('\r\n'),
        responseText: responseText,
        response: responseText
      };

      // Send response back to MAIN world
      window.postMessage({
        channel: CHANNEL,
        type: 'response',
        id: id,
        success: true,
        response: gmResponse
      }, '*');

    } catch (error) {
      // Send error back to MAIN world
      window.postMessage({
        channel: CHANNEL,
        type: 'response',
        id: id,
        success: false,
        error: error.message
      }, '*');
    }
  });

  // Signal that bridge is ready
  window.postMessage({
    channel: CHANNEL,
    type: 'bridge-ready'
  }, '*');
})();
