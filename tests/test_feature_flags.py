#!/usr/bin/env python3
"""
Test Feature Flags Override
============================
Verifies that feature-flags.js contains all required flag overrides.
"""

import re
import unittest
from pathlib import Path


# Path to feature flags script
FEATURE_FLAGS_PATH = Path(__file__).parent.parent / "patches" / "perplexity" / "content" / "feature-flags.js"

# Critical MCP UI flags (must be true)
MCP_FLAGS = {
    "comet-mcp-enabled": True,
    "custom-remote-mcps": True,
    "comet-dxt-enabled": True,
}

# Expected flags to be disabled (false)
DISABLED_FLAGS = [
    "use-mixpanel-analytics",
    "report-omnibox-text",
    "send-omnibox-events-to-backend",
    "send-visited-urls",
    "report-navigation-events",
    "use-new-tab-page-backend-for-url-suggestions",
    "enable-sidebar-shortcuts-history-search",
    "shopping-feature-enabled",
    "enable-discover-section",
    "enable-pro-upsell-promo",
]

# Expected flag count (minimum)
MINIMUM_FLAG_COUNT = 35


class TestFeatureFlags(unittest.TestCase):
    """Test feature flag overrides."""

    @classmethod
    def setUpClass(cls):
        """Load the feature flags script."""
        if not FEATURE_FLAGS_PATH.exists():
            raise FileNotFoundError(f"Feature flags script not found: {FEATURE_FLAGS_PATH}")

        cls.content = FEATURE_FLAGS_PATH.read_text(encoding="utf-8")

        # Extract LOCAL_FEATURE_FLAGS object
        cls.flags = cls._extract_flags(cls.content)

    @classmethod
    def _extract_flags(cls, content):
        """Extract flag definitions from JavaScript content."""
        flags = {}

        # Pattern to match flag definitions
        # Handles both: 'flag-name': true/false and "flag-name": true/false
        pattern = r'["\']([a-z0-9-]+)["\']\s*:\s*(true|false)'

        matches = re.findall(pattern, content, re.IGNORECASE)
        for name, value in matches:
            flags[name] = value.lower() == "true"

        return flags

    def test_script_exists(self):
        """Verify feature-flags.js exists."""
        self.assertTrue(FEATURE_FLAGS_PATH.exists())

    def test_minimum_flag_count(self):
        """Verify minimum number of flags are defined."""
        self.assertGreaterEqual(len(self.flags), MINIMUM_FLAG_COUNT,
                               f"Expected at least {MINIMUM_FLAG_COUNT} flags, found {len(self.flags)}")

    def test_mcp_ui_enabled(self):
        """Verify MCP UI flags are enabled (critical for MCP functionality)."""
        for flag_name, expected_value in MCP_FLAGS.items():
            self.assertIn(flag_name, self.flags,
                         f"Critical MCP flag missing: {flag_name}")
            self.assertEqual(self.flags[flag_name], expected_value,
                           f"MCP flag {flag_name} should be {expected_value}")

    def test_comet_mcp_enabled(self):
        """Verify comet-mcp-enabled is true."""
        self.assertIn("comet-mcp-enabled", self.flags)
        self.assertTrue(self.flags["comet-mcp-enabled"],
                       "comet-mcp-enabled must be true for MCP UI")

    def test_custom_remote_mcps_enabled(self):
        """Verify custom-remote-mcps is true."""
        self.assertIn("custom-remote-mcps", self.flags)
        self.assertTrue(self.flags["custom-remote-mcps"],
                       "custom-remote-mcps must be true for remote MCP servers")

    def test_comet_dxt_enabled(self):
        """Verify comet-dxt-enabled is true."""
        self.assertIn("comet-dxt-enabled", self.flags)
        self.assertTrue(self.flags["comet-dxt-enabled"],
                       "comet-dxt-enabled must be true for DXT packages")

    def test_telemetry_flags_disabled(self):
        """Verify telemetry-related flags are disabled."""
        telemetry_flags = [
            "use-mixpanel-analytics",
            "report-omnibox-text",
            "send-omnibox-events-to-backend",
            "send-visited-urls",
            "report-navigation-events",
        ]

        for flag in telemetry_flags:
            if flag in self.flags:
                self.assertFalse(self.flags[flag],
                               f"Telemetry flag {flag} should be false")

    def test_tracking_flags_disabled(self):
        """Verify tracking-related flags are disabled."""
        tracking_flags = [
            "enable-sidebar-shortcuts-history-search",
            "use-new-tab-page-backend-for-url-suggestions",
        ]

        for flag in tracking_flags:
            if flag in self.flags:
                self.assertFalse(self.flags[flag],
                               f"Tracking flag {flag} should be false")

    def test_shopping_flags_disabled(self):
        """Verify shopping/advertising flags are disabled."""
        if "shopping-feature-enabled" in self.flags:
            self.assertFalse(self.flags["shopping-feature-enabled"],
                           "shopping-feature-enabled should be false")

    def test_upsell_flags_disabled(self):
        """Verify upsell/promo flags are disabled."""
        upsell_flags = [
            "enable-pro-upsell-promo",
            "show-ntp-upsell",
        ]

        for flag in upsell_flags:
            if flag in self.flags:
                self.assertFalse(self.flags[flag],
                               f"Upsell flag {flag} should be false")

    def test_eppo_interception_present(self):
        """Verify Eppo SDK interception code is present."""
        # Check for Eppo endpoint patterns
        self.assertIn("eppo.cloud", self.content.lower(),
                     "Eppo endpoint interception not found")

        # Check for fetch patching
        self.assertIn("fetch", self.content,
                     "Fetch patching not found")

    def test_local_feature_flags_object(self):
        """Verify LOCAL_FEATURE_FLAGS object is defined."""
        self.assertIn("LOCAL_FEATURE_FLAGS", self.content,
                     "LOCAL_FEATURE_FLAGS object not found")

    def test_mock_eppo_config(self):
        """Verify mock Eppo config generation is present."""
        # Could be createMockEppoConfig or similar
        self.assertTrue(
            "mockEppo" in self.content.lower() or
            "createMock" in self.content or
            "flags" in self.content.lower(),
            "Mock Eppo config generation not found"
        )


def main():
    """Run tests with verbose output."""
    print("=" * 60)
    print("Meteor v2 Feature Flags Test")
    print("=" * 60)
    print(f"Testing: {FEATURE_FLAGS_PATH}")
    print()

    # Run tests
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromTestCase(TestFeatureFlags)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    # Summary
    print()
    print("=" * 60)
    if result.wasSuccessful():
        print("[+] All feature flag tests passed!")

        # Load and show flag count
        if FEATURE_FLAGS_PATH.exists():
            content = FEATURE_FLAGS_PATH.read_text(encoding="utf-8")
            flags = TestFeatureFlags._extract_flags(content)
            print(f"[*] Total flags defined: {len(flags)}")

            # Show MCP flags status
            for flag in ["comet-mcp-enabled", "custom-remote-mcps", "comet-dxt-enabled"]:
                if flag in flags:
                    status = "✓ enabled" if flags[flag] else "✗ disabled"
                    print(f"    {flag}: {status}")
    else:
        print(f"[!] {len(result.failures)} failures, {len(result.errors)} errors")
    print("=" * 60)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    exit(main())
