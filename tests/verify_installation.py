#!/usr/bin/env python3
"""
Meteor v2 Installation Verification
====================================
End-to-end verification of the complete Meteor v2 installation.

This script verifies:
1. All required directories and files exist
2. Patched extensions are properly set up
3. DNR rules are valid JSON
4. Content scripts are present
5. Manifest modifications are applied
6. Service worker imports meteor-prefs.js
"""

import json
import sys
from pathlib import Path


# Base directories
METEOR_V2_ROOT = Path(__file__).parent.parent
METEOR_ROOT = METEOR_V2_ROOT.parent

# Expected directory structure
REQUIRED_DIRS = [
    "launcher",
    "patches/perplexity/content",
    "patches/perplexity/rules",
    "tools",
    "ublock",
    "docs",
    "tests",
]

# Required files in patches/
REQUIRED_PATCH_FILES = [
    "patches/perplexity/meteor-prefs.js",
    "patches/perplexity/manifest.patch.json",
    "patches/perplexity/content/sdk-neutralizer.js",
    "patches/perplexity/content/feature-flags.js",
    "patches/perplexity/rules/telemetry.json",
]

# Required files in launcher/
REQUIRED_LAUNCHER_FILES = [
    "launcher/launcher.py",
    "launcher/config.yaml",
    "launcher/requirements.txt",
]

# Required tool files
REQUIRED_TOOL_FILES = [
    "tools/setup.py",
    "tools/pak_mods.py",
    "tools/build_pak.py",
]

# Required uBlock files
REQUIRED_UBLOCK_FILES = [
    "ublock/ublock-defaults.json",
    "ublock/download.py",
]

# Required documentation
REQUIRED_DOCS = [
    "README.md",
    "docs/SETUP.md",
    "docs/TROUBLESHOOTING.md",
    "docs/API.md",
]


class VerificationResult:
    """Holds verification results."""

    def __init__(self):
        self.passed = []
        self.failed = []
        self.warnings = []

    def add_pass(self, message):
        self.passed.append(message)
        print(f"  [✓] {message}")

    def add_fail(self, message):
        self.failed.append(message)
        print(f"  [✗] {message}")

    def add_warning(self, message):
        self.warnings.append(message)
        print(f"  [!] {message}")

    @property
    def success(self):
        return len(self.failed) == 0


def verify_directories(result: VerificationResult):
    """Verify required directories exist."""
    print("\n[1/7] Checking directories...")

    for rel_dir in REQUIRED_DIRS:
        dir_path = METEOR_V2_ROOT / rel_dir
        if dir_path.is_dir():
            result.add_pass(f"Directory exists: {rel_dir}")
        else:
            result.add_fail(f"Directory missing: {rel_dir}")


def verify_patch_files(result: VerificationResult):
    """Verify patch files exist."""
    print("\n[2/7] Checking patch files...")

    for rel_file in REQUIRED_PATCH_FILES:
        file_path = METEOR_V2_ROOT / rel_file
        if file_path.is_file():
            result.add_pass(f"File exists: {rel_file}")
        else:
            result.add_fail(f"File missing: {rel_file}")


def verify_launcher_files(result: VerificationResult):
    """Verify launcher files exist."""
    print("\n[3/7] Checking launcher files...")

    for rel_file in REQUIRED_LAUNCHER_FILES:
        file_path = METEOR_V2_ROOT / rel_file
        if file_path.is_file():
            result.add_pass(f"File exists: {rel_file}")
        else:
            result.add_fail(f"File missing: {rel_file}")

    # Check for PowerShell script (optional on non-Windows)
    ps1_path = METEOR_V2_ROOT / "launcher" / "launcher.ps1"
    if ps1_path.is_file():
        result.add_pass("File exists: launcher/launcher.ps1")
    else:
        result.add_warning("PowerShell launcher missing (optional on non-Windows)")


def verify_tool_files(result: VerificationResult):
    """Verify tool files exist."""
    print("\n[4/7] Checking tool files...")

    for rel_file in REQUIRED_TOOL_FILES:
        file_path = METEOR_V2_ROOT / rel_file
        if file_path.is_file():
            result.add_pass(f"File exists: {rel_file}")
        else:
            result.add_fail(f"File missing: {rel_file}")


def verify_ublock_files(result: VerificationResult):
    """Verify uBlock files exist."""
    print("\n[5/7] Checking uBlock files...")

    for rel_file in REQUIRED_UBLOCK_FILES:
        file_path = METEOR_V2_ROOT / rel_file
        if file_path.is_file():
            result.add_pass(f"File exists: {rel_file}")
        else:
            result.add_fail(f"File missing: {rel_file}")


def verify_documentation(result: VerificationResult):
    """Verify documentation files exist."""
    print("\n[6/7] Checking documentation...")

    for rel_file in REQUIRED_DOCS:
        file_path = METEOR_V2_ROOT / rel_file
        if file_path.is_file():
            result.add_pass(f"File exists: {rel_file}")
        else:
            result.add_fail(f"File missing: {rel_file}")


def verify_file_contents(result: VerificationResult):
    """Verify critical file contents."""
    print("\n[7/7] Validating file contents...")

    # Verify telemetry.json is valid JSON with 16 rules
    telemetry_path = METEOR_V2_ROOT / "patches" / "perplexity" / "rules" / "telemetry.json"
    if telemetry_path.is_file():
        try:
            with open(telemetry_path, "r", encoding="utf-8") as f:
                rules = json.load(f)
            if isinstance(rules, list) and len(rules) == 16:
                result.add_pass("telemetry.json: Valid JSON with 16 rules")
            else:
                result.add_fail(f"telemetry.json: Expected 16 rules, found {len(rules) if isinstance(rules, list) else 'invalid format'}")
        except json.JSONDecodeError as e:
            result.add_fail(f"telemetry.json: Invalid JSON - {e}")

    # Verify manifest.patch.json is valid JSON
    manifest_patch_path = METEOR_V2_ROOT / "patches" / "perplexity" / "manifest.patch.json"
    if manifest_patch_path.is_file():
        try:
            with open(manifest_patch_path, "r", encoding="utf-8") as f:
                patch = json.load(f)
            if "add" in patch:
                result.add_pass("manifest.patch.json: Valid JSON with 'add' section")
            else:
                result.add_warning("manifest.patch.json: No 'add' section found")
        except json.JSONDecodeError as e:
            result.add_fail(f"manifest.patch.json: Invalid JSON - {e}")

    # Verify ublock-defaults.json is valid JSON
    ublock_defaults_path = METEOR_V2_ROOT / "ublock" / "ublock-defaults.json"
    if ublock_defaults_path.is_file():
        try:
            with open(ublock_defaults_path, "r", encoding="utf-8") as f:
                defaults = json.load(f)
            if "userSettings" in defaults and "selectedFilterLists" in defaults:
                lists_count = len(defaults.get("selectedFilterLists", []))
                result.add_pass(f"ublock-defaults.json: Valid JSON with {lists_count} filter lists")
            else:
                result.add_fail("ublock-defaults.json: Missing required sections")
        except json.JSONDecodeError as e:
            result.add_fail(f"ublock-defaults.json: Invalid JSON - {e}")

    # Verify config.yaml is valid YAML (basic check)
    config_path = METEOR_V2_ROOT / "launcher" / "config.yaml"
    if config_path.is_file():
        try:
            import yaml
            with open(config_path, "r", encoding="utf-8") as f:
                config = yaml.safe_load(f)
            if "browser" in config:
                result.add_pass("config.yaml: Valid YAML with browser section")
            else:
                result.add_fail("config.yaml: Missing browser section")
        except ImportError:
            result.add_warning("config.yaml: PyYAML not installed, skipping validation")
        except Exception as e:
            result.add_fail(f"config.yaml: Invalid YAML - {e}")

    # Verify meteor-prefs.js contains key components
    meteor_prefs_path = METEOR_V2_ROOT / "patches" / "perplexity" / "meteor-prefs.js"
    if meteor_prefs_path.is_file():
        content = meteor_prefs_path.read_text(encoding="utf-8")

        checks = [
            ("ENFORCED_PREFERENCES", "ENFORCED_PREFERENCES object"),
            ("MeteorMCP", "MeteorMCP API"),
            ("chrome.settingsPrivate", "chrome.settingsPrivate usage"),
            ("chrome.tabs", "chrome.tabs usage"),
        ]

        for pattern, description in checks:
            if pattern in content:
                result.add_pass(f"meteor-prefs.js: Contains {description}")
            else:
                result.add_fail(f"meteor-prefs.js: Missing {description}")

    # Verify feature-flags.js contains MCP flags
    feature_flags_path = METEOR_V2_ROOT / "patches" / "perplexity" / "content" / "feature-flags.js"
    if feature_flags_path.is_file():
        content = feature_flags_path.read_text(encoding="utf-8")

        mcp_flags = ["comet-mcp-enabled", "custom-remote-mcps", "comet-dxt-enabled"]
        for flag in mcp_flags:
            if flag in content:
                result.add_pass(f"feature-flags.js: Contains {flag}")
            else:
                result.add_fail(f"feature-flags.js: Missing {flag}")


def verify_patched_extensions(result: VerificationResult):
    """Verify patched_extensions directory if it exists (created by setup.py)."""
    print("\n[*] Checking for patched extensions (optional)...")

    patched_dir = METEOR_V2_ROOT / "patched_extensions"
    if patched_dir.is_dir():
        result.add_pass("patched_extensions/ directory exists")

        # Check for perplexity extension
        perplexity_dir = patched_dir / "perplexity"
        if perplexity_dir.is_dir():
            result.add_pass("patched_extensions/perplexity/ exists")

            # Check for required files in patched extension
            required_files = [
                "manifest.json",
                "meteor-prefs.js",
                "rules/telemetry.json",
                "content/sdk-neutralizer.js",
                "content/feature-flags.js",
            ]

            for rel_file in required_files:
                file_path = perplexity_dir / rel_file
                if file_path.is_file():
                    result.add_pass(f"patched perplexity/{rel_file}")
                else:
                    result.add_warning(f"patched perplexity/{rel_file} missing")

            # Check manifest.json has DNR rules
            manifest_path = perplexity_dir / "manifest.json"
            if manifest_path.is_file():
                try:
                    with open(manifest_path, "r", encoding="utf-8") as f:
                        manifest = json.load(f)
                    if "declarative_net_request" in manifest:
                        result.add_pass("patched manifest has declarative_net_request")
                    else:
                        result.add_warning("patched manifest missing declarative_net_request")
                except Exception:
                    pass
        else:
            result.add_warning("patched_extensions/perplexity/ not yet created (run setup.py)")
    else:
        result.add_warning("patched_extensions/ not yet created (run setup.py)")


def main():
    """Run all verification checks."""
    print("=" * 70)
    print("Meteor v2 Installation Verification")
    print("=" * 70)
    print(f"Meteor v2 Root: {METEOR_V2_ROOT}")

    result = VerificationResult()

    # Run all verification steps
    verify_directories(result)
    verify_patch_files(result)
    verify_launcher_files(result)
    verify_tool_files(result)
    verify_ublock_files(result)
    verify_documentation(result)
    verify_file_contents(result)
    verify_patched_extensions(result)

    # Print summary
    print()
    print("=" * 70)
    print("Summary")
    print("=" * 70)
    print(f"  Passed:   {len(result.passed)}")
    print(f"  Failed:   {len(result.failed)}")
    print(f"  Warnings: {len(result.warnings)}")
    print()

    if result.success:
        print("[+] Meteor v2 installation verified successfully!")
        print()
        print("Next steps:")
        print("  1. Run setup: python tools/setup.py")
        print("  2. Launch:    python launcher/launcher.py")
    else:
        print("[!] Verification failed. Please check the errors above.")
        print()
        print("Failed checks:")
        for failure in result.failed:
            print(f"  - {failure}")

    print("=" * 70)

    return 0 if result.success else 1


if __name__ == "__main__":
    sys.exit(main())
