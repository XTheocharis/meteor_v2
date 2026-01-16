#!/usr/bin/env python3
"""
Test DNR (Declarative Net Request) Rules
=========================================
Verifies that telemetry.json contains all required blocking rules.
"""

import json
import unittest
from pathlib import Path


# Path to telemetry rules
TELEMETRY_RULES_PATH = Path(__file__).parent.parent / "patches" / "perplexity" / "rules" / "telemetry.json"

# Expected rule patterns (16 total)
EXPECTED_PATTERNS = [
    # Rule 1: DataDog RUM
    "browser-intake-datadoghq.com",
    # Rule 2: Singular Analytics
    "sdk-api-v1.singular.net",
    # Rule 3: Eppo Feature Flags (CDN)
    "fscdn.eppo.cloud",
    # Rule 4: Eppo Assignment
    "fs-edge-assignment.eppo.cloud",
    # Rule 5: Perplexity internal telemetry
    "irontail.perplexity.ai",
    # Rule 6: Analytics endpoint
    "/rest/event/analytics",
    # Rule 7: Cloudflare trace
    "/cdn-cgi/trace",
    # Rule 8: Intercom
    "/api/intercom",
    # Rule 9: Mixpanel
    "api.mixpanel.com",
    # Rule 10: Sentry
    ".ingest.sentry.io",
    # Rule 11: Singular SDK script
    "singular-sdk",
    # Rule 12: Attribution tracking
    "/rest/attribution/",
    # Rule 13: Homepage upsell tracking
    "/rest/homepage-widgets/upsell/interacted",
    # Rule 14: NTP upsell tracking
    "/rest/ntp/upsell/interacted",
    # Rule 15: Autosuggest tracking
    "/rest/autosuggest/track-query-clicked",
    # Rule 16: Live events
    "/rest/live-events/subscription",
]


class TestDNRRules(unittest.TestCase):
    """Test DNR blocking rules."""

    @classmethod
    def setUpClass(cls):
        """Load the telemetry rules file."""
        if not TELEMETRY_RULES_PATH.exists():
            raise FileNotFoundError(f"Telemetry rules not found: {TELEMETRY_RULES_PATH}")

        with open(TELEMETRY_RULES_PATH, "r", encoding="utf-8") as f:
            cls.rules = json.load(f)

    def test_rules_file_exists(self):
        """Verify telemetry.json exists."""
        self.assertTrue(TELEMETRY_RULES_PATH.exists())

    def test_rules_is_list(self):
        """Verify rules is a list."""
        self.assertIsInstance(self.rules, list)

    def test_rule_count(self):
        """Verify exactly 16 rules are defined."""
        self.assertEqual(len(self.rules), 16, f"Expected 16 rules, found {len(self.rules)}")

    def test_rule_ids_sequential(self):
        """Verify rule IDs are sequential 1-16."""
        ids = [rule.get("id") for rule in self.rules]
        expected_ids = list(range(1, 17))
        self.assertEqual(ids, expected_ids, f"Rule IDs not sequential: {ids}")

    def test_all_rules_have_required_fields(self):
        """Verify each rule has required fields."""
        required_fields = ["id", "priority", "action", "condition"]

        for rule in self.rules:
            for field in required_fields:
                self.assertIn(field, rule, f"Rule {rule.get('id')} missing field: {field}")

    def test_all_rules_are_block_actions(self):
        """Verify all rules have 'block' action type."""
        for rule in self.rules:
            action_type = rule.get("action", {}).get("type")
            self.assertEqual(action_type, "block",
                           f"Rule {rule.get('id')} has action type '{action_type}', expected 'block'")

    def test_expected_patterns_present(self):
        """Verify all expected blocking patterns are present."""
        # Extract all patterns from rules
        all_patterns = []
        for rule in self.rules:
            condition = rule.get("condition", {})

            # Check urlFilter
            if "urlFilter" in condition:
                all_patterns.append(condition["urlFilter"])

            # Check regexFilter
            if "regexFilter" in condition:
                all_patterns.append(condition["regexFilter"])

        # Verify each expected pattern is present
        for expected in EXPECTED_PATTERNS:
            found = any(expected in pattern for pattern in all_patterns)
            self.assertTrue(found, f"Expected pattern not found: {expected}")

    def test_datadog_rule(self):
        """Verify DataDog RUM blocking rule (ID 1)."""
        rule = self.rules[0]
        self.assertEqual(rule["id"], 1)
        self.assertIn("browser-intake-datadoghq.com",
                     rule.get("condition", {}).get("urlFilter", ""))

    def test_singular_rule(self):
        """Verify Singular Analytics blocking rule (ID 2)."""
        rule = self.rules[1]
        self.assertEqual(rule["id"], 2)
        self.assertIn("sdk-api-v1.singular.net",
                     rule.get("condition", {}).get("urlFilter", ""))

    def test_eppo_cdn_rule(self):
        """Verify Eppo CDN blocking rule (ID 3)."""
        rule = self.rules[2]
        self.assertEqual(rule["id"], 3)
        self.assertIn("fscdn.eppo.cloud",
                     rule.get("condition", {}).get("urlFilter", ""))

    def test_eppo_assignment_rule(self):
        """Verify Eppo Assignment blocking rule (ID 4)."""
        rule = self.rules[3]
        self.assertEqual(rule["id"], 4)
        self.assertIn("fs-edge-assignment.eppo.cloud",
                     rule.get("condition", {}).get("urlFilter", ""))

    def test_irontail_rule(self):
        """Verify irontail telemetry blocking rule (ID 5)."""
        rule = self.rules[4]
        self.assertEqual(rule["id"], 5)
        self.assertIn("irontail.perplexity.ai",
                     rule.get("condition", {}).get("urlFilter", ""))

    def test_sentry_rule(self):
        """Verify Sentry blocking rule (ID 10)."""
        rule = self.rules[9]
        self.assertEqual(rule["id"], 10)
        condition = rule.get("condition", {})
        # Could be urlFilter or regexFilter
        pattern = condition.get("urlFilter", "") or condition.get("regexFilter", "")
        self.assertTrue("sentry" in pattern.lower(),
                       f"Sentry pattern not found in rule 10: {pattern}")

    def test_mixpanel_rule(self):
        """Verify Mixpanel blocking rule (ID 9)."""
        rule = self.rules[8]
        self.assertEqual(rule["id"], 9)
        self.assertIn("api.mixpanel.com",
                     rule.get("condition", {}).get("urlFilter", ""))


def main():
    """Run tests with verbose output."""
    print("=" * 60)
    print("Meteor v2 DNR Rules Test")
    print("=" * 60)
    print(f"Testing: {TELEMETRY_RULES_PATH}")
    print()

    # Run tests
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromTestCase(TestDNRRules)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    # Summary
    print()
    print("=" * 60)
    if result.wasSuccessful():
        print("[+] All DNR rule tests passed!")
    else:
        print(f"[!] {len(result.failures)} failures, {len(result.errors)} errors")
    print("=" * 60)

    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    exit(main())
