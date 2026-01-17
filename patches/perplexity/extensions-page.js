/**
 * Meteor - Auto-enable incognito for extensions
 * ============================================
 * Runs on chrome://extensions to trigger incognito enablement.
 *
 * Content scripts don't have access to chrome.management or chrome.developerPrivate,
 * so this script sends a message to the service worker which has those APIs.
 *
 * @license MIT
 */

(() => {
  'use strict';

  console.log('[Meteor] Extension page content script loaded');

  // Send message to service worker to enable incognito for extensions
  chrome.runtime.sendMessage({ type: 'METEOR_ENABLE_INCOGNITO' }, (response) => {
    if (chrome.runtime.lastError) {
      console.warn('[Meteor] Failed to send message to service worker:', chrome.runtime.lastError.message);
    } else if (response?.success) {
      console.log('[Meteor] Incognito enablement triggered via service worker');
    }
  });

  console.log('[Meteor] Extension auto-incognito enabler active on chrome://extensions');
})();
