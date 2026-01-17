/**
 * Meteor - Auto-enable incognito for extensions
 * ============================================
 * Runs on chrome://extensions to automatically enable incognito mode
 * for uBlock Origin and AdGuard Extra.
 *
 * This works because we enable --extensions-on-chrome-urls which allows
 * content scripts to run on chrome:// pages and access chrome.developerPrivate.
 *
 * @license MIT
 */

(() => {
  'use strict';

  // Extension IDs to auto-enable in incognito
  const METEOR_EXTENSIONS = {
    'cjpalhdlnbpafiamejdnhcphjbkeiagm': 'uBlock Origin',
    'gkeojjjcdcopjkbelgbcpckplegclfeg': 'AdGuard Extra'
  };

  /**
   * Enable incognito access for a specific extension
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

          // Check if already enabled in incognito
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

  // Run on page load
  autoEnableIncognito();

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

  console.log('[Meteor] Extension auto-incognito enabler active on chrome://extensions');
})();
