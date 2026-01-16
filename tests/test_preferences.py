#!/usr/bin/env python3
"""
Test Preference Enforcement
===========================
Verifies that meteor-prefs.js contains all required preference settings.
"""

import re
import unittest
from pathlib import Path


# Path to meteor-prefs.js
METEOR_PREFS_PATH = Path(__file__).parent.parent / "patches" / "perplexity" / "meteor-prefs.js"

# Required preferences and their expected values
REQUIRED_PREFERENCES = {
    # Critical privacy settings
    "perplexity.adblock.enabled": False,
    "perplexity.metrics_allowed": False,

    # Analytics disable
    "perplexity.analytics_observer_initialised": False,

    # Privacy features
    "perplexity.history_search_enabled": False,
    "perplexity.help_me_with_text.enabled": False,
    "perplexity.proactive_scraping.enabled": False,
}

# Minimum preference count
MINIMUM_PREFERENCE_COUNT = 10


class TestPreferences(unittest.TestCase):
    """Test preference enforcement."""

    @classmethod
    def setUpClass(cls):
        """Load the meteor-prefs.js script."""
        if not METEOR_PREFS_PATH.exists():
            raise FileNotFoundError(f"Meteor prefs script not found: {METEOR_PREFS_PATH}")

        cls.content = METEOR_PREFS_PATH.read_text(encoding="utf-8")
        cls.preferences = cls._extract_preferences(cls.content)

    @classmethod
    def _extract_preferences(cls, content):
        """Extract preference definitions from JavaScript content."""
        prefs = {}

        # Pattern for preference definitions in ENFORCED_PREFERENCES object
        # Matches: 'pref.name': value or "pref.name": value
        pattern = r'["\']([a-z0-9_.]+)["\']\s*:\s*([^,\n}]+)'

        matches = re.findall(pattern, content, re.IGNORECASE)
        for name, value in matches:
            value = value.strip()
            # Parse boolean/number values
            if value.lower() == 'true':
                prefs[name] = True
            elif value.lower() == 'false':
                prefs[name] = False
            elif value.isdigit():
                prefs[name] = int(value)
            else:
                prefs[name] = value

        return prefs

    def test_script_exists(self):
        """Verify meteor-prefs.js exists."""
        self.assertTrue(METEOR_PREFS_PATH.exists())

    def test_minimum_preference_count(self):
        """Verify minimum number of preferences are defined."""
        # Count preferences that look like perplexity.* settings
        plex_prefs = [k for k in self.preferences if k.startswith("perplexity.")]
        self.assertGreaterEqual(len(plex_prefs), MINIMUM_PREFERENCE_COUNT,
                               f"Expected at least {MINIMUM_PREFERENCE_COUNT} preferences, found {len(plex_prefs)}")

    def test_enforced_preferences_object(self):
        """Verify ENFORCED_PREFERENCES object is defined."""
        self.assertIn("ENFORCED_PREFERENCES", self.content,
                     "ENFORCED_PREFERENCES object not found")

    def test_adblock_disabled(self):
        """Verify adblock is disabled (we use uBlock instead)."""
        self.assertIn("perplexity.adblock.enabled", self.preferences)
        self.assertFalse(self.preferences["perplexity.adblock.enabled"],
                        "perplexity.adblock.enabled should be false")

    def test_metrics_disabled(self):
        """Verify metrics collection is disabled."""
        self.assertIn("perplexity.metrics_allowed", self.preferences)
        self.assertFalse(self.preferences["perplexity.metrics_allowed"],
                        "perplexity.metrics_allowed should be false")

    def test_analytics_observer_disabled(self):
        """Verify analytics observer is disabled."""
        self.assertIn("perplexity.analytics_observer_initialised", self.preferences)
        self.assertFalse(self.preferences["perplexity.analytics_observer_initialised"],
                        "perplexity.analytics_observer_initialised should be false")

    def test_history_search_disabled(self):
        """Verify history search is disabled."""
        self.assertIn("perplexity.history_search_enabled", self.preferences)
        self.assertFalse(self.preferences["perplexity.history_search_enabled"],
                        "perplexity.history_search_enabled should be false")

    def test_chrome_settings_private_usage(self):
        """Verify chrome.settingsPrivate API is used."""
        self.assertIn("chrome.settingsPrivate", self.content,
                     "chrome.settingsPrivate API not used")

    def test_set_pref_usage(self):
        """Verify setPref method is called."""
        self.assertIn("setPref", self.content,
                     "setPref method not found")

    def test_preference_monitor(self):
        """Verify preference change monitoring is implemented."""
        # Could be onPrefsChanged or similar
        monitor_patterns = [
            "onPrefsChanged",
            "addEventListener",
            "setInterval",
        ]
        found = any(pattern in self.content for pattern in monitor_patterns)
        self.assertTrue(found, "Preference monitoring not found")

    def test_apply_preferences_function(self):
        """Verify applyPreferences function exists."""
        self.assertIn("applyPreferences", self.content,
                     "applyPreferences function not found")


class TestMeteorMCPAPI(unittest.TestCase):
    """Test MeteorMCP API implementation."""

    @classmethod
    def setUpClass(cls):
        """Load the meteor-prefs.js script."""
        if not METEOR_PREFS_PATH.exists():
            raise FileNotFoundError(f"Meteor prefs script not found: {METEOR_PREFS_PATH}")

        cls.content = METEOR_PREFS_PATH.read_text(encoding="utf-8")

    def test_meteor_mcp_object(self):
        """Verify MeteorMCP global object is defined."""
        self.assertIn("MeteorMCP", self.content,
                     "MeteorMCP object not found")

    def test_get_servers_method(self):
        """Verify getServers method is defined."""
        self.assertIn("getServers", self.content,
                     "getServers method not found")

    def test_add_server_method(self):
        """Verify addServer method is defined."""
        self.assertIn("addServer", self.content,
                     "addServer method not found")

    def test_remove_server_method(self):
        """Verify removeServer method is defined."""
        self.assertIn("removeServer", self.content,
                     "removeServer method not found")

    def test_get_tools_method(self):
        """Verify getTools method is defined."""
        self.assertIn("getTools", self.content,
                     "getTools method not found")

    def test_call_tool_method(self):
        """Verify callTool method is defined."""
        self.assertIn("callTool", self.content,
                     "callTool method not found")

    def test_chrome_perplexity_mcp_usage(self):
        """Verify native chrome.perplexity.mcp API is used."""
        self.assertIn("chrome.perplexity.mcp", self.content,
                     "chrome.perplexity.mcp API not used")


class TestURLRedirection(unittest.TestCase):
    """Test URL redirection functionality."""

    @classmethod
    def setUpClass(cls):
        """Load the meteor-prefs.js script."""
        if not METEOR_PREFS_PATH.exists():
            raise FileNotFoundError(f"Meteor prefs script not found: {METEOR_PREFS_PATH}")

        cls.content = METEOR_PREFS_PATH.read_text(encoding="utf-8")

    def test_local_url_patterns(self):
        """Verify local URL patterns are defined."""
        patterns_present = any(pattern in self.content.lower() for pattern in [
            "chrome://",
            "comet://",
            "chrome-extension://",
        ])
        self.assertTrue(patterns_present, "Local URL patterns not found")

    def test_remote_url_target(self):
        """Verify remote URL target is defined."""
        self.assertIn("perplexity.ai", self.content,
                     "Remote URL target (perplexity.ai) not found")

    def test_tabs_api_usage(self):
        """Verify chrome.tabs API is used for redirection."""
        self.assertIn("chrome.tabs", self.content,
                     "chrome.tabs API not used")

    def test_on_updated_listener(self):
        """Verify tabs.onUpdated listener is set up."""
        self.assertIn("onUpdated", self.content,
                     "tabs.onUpdated listener not found")


def main():
    """Run tests with verbose output."""
    print("=" * 60)
    print("Meteor v2 Preferences Test")
    print("=" * 60)
    print(f"Testing: {METEOR_PREFS_PATH}")
    print()

    # Run all test classes
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    suite.addTests(loader.loadTestsFromTestCase(TestPreferences))
    suite.addTests(loader.loadTestsFromTestCase(TestMeteorMCPAPI))
    suite.addTests(loader.loadTestsFromTestCase(TestURLRedirection))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    # Summary
    print()
    print("=" * 60)
    if result.wasSuccessful():
        print("[+] All preference tests passed!")
    else:
        print(f"[!] {len(result.failures)} failures, {len(result.errors)} errors")
    print("=" * 60)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    exit(main())
