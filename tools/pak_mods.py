#!/usr/bin/env python3
"""
Meteor v2 PAK Modifications
===========================
Apply privacy modifications to extracted resources.pak files.

This script modifies embedded JavaScript in the PAK file to:
1. Disable omnibox text reporting
2. Disable URL visit reporting
3. Null analytics endpoints
4. Empty Sentry DSN

Usage:
    python pak_mods.py [--editable-dir DIR] [--dry-run]
"""

import argparse
import re
from pathlib import Path


# Default path to editable resources
DEFAULT_EDITABLE_DIR = Path(__file__).parent.parent.parent / "Extracted" / "resources_pak" / "editable"

# Modifications to apply
# Format: {relative_path: [(pattern, replacement), ...]}
MODIFICATIONS = {
    "js/51127.js": [
        # Disable omnibox text reporting
        (r'REPORT_OMNIBOX_TEXT:\s*true', 'REPORT_OMNIBOX_TEXT: false'),
        # Disable URL visit reporting interval (set to 0 = disabled)
        (r'SEND_VISITED_URLS_EVENT_INTERVAL_MINS:\s*\d+', 'SEND_VISITED_URLS_EVENT_INTERVAL_MINS: 0'),
    ],
    "js/51101.js": [
        # Null analytics endpoint URL
        (r'https://www\.perplexity\.ai/rest/event/analytics', ''),
    ],
    "js/51120.js": [
        # Empty Sentry DSN
        (r'window\.PERPLEXITY_JS_SENTRY_DSN', '""'),
    ],
}


def apply_modifications(editable_dir: Path, dry_run: bool = False) -> dict:
    """
    Apply modifications to files in the editable directory.

    Returns:
        dict: Summary of modifications made
    """
    results = {
        "modified": [],
        "not_found": [],
        "unchanged": [],
        "errors": []
    }

    print(f"[*] Scanning: {editable_dir}")
    print()

    for relative_path, patterns in MODIFICATIONS.items():
        full_path = editable_dir / relative_path

        if not full_path.exists():
            print(f"[!] Not found: {relative_path}")
            results["not_found"].append(relative_path)
            continue

        try:
            content = full_path.read_text(encoding="utf-8")
            original_content = content
            modifications_applied = []

            for pattern, replacement in patterns:
                new_content, count = re.subn(pattern, replacement, content, flags=re.IGNORECASE)

                if count > 0:
                    content = new_content
                    modifications_applied.append({
                        "pattern": pattern[:50] + "..." if len(pattern) > 50 else pattern,
                        "count": count
                    })

            if modifications_applied:
                print(f"[+] Modified: {relative_path}")
                for mod in modifications_applied:
                    print(f"    -> {mod['pattern']} ({mod['count']} occurrences)")

                if not dry_run:
                    full_path.write_text(content, encoding="utf-8")
                    print(f"    -> Saved")

                results["modified"].append({
                    "path": relative_path,
                    "modifications": modifications_applied
                })
            else:
                print(f"[-] Unchanged: {relative_path} (patterns not found)")
                results["unchanged"].append(relative_path)

        except Exception as e:
            print(f"[!] Error processing {relative_path}: {e}")
            results["errors"].append({"path": relative_path, "error": str(e)})

    return results


def print_summary(results: dict) -> None:
    """Print summary of modifications."""
    print()
    print("=" * 60)
    print("Summary")
    print("=" * 60)

    print(f"Modified:  {len(results['modified'])}")
    for item in results["modified"]:
        print(f"  - {item['path']}")

    if results["not_found"]:
        print(f"Not found: {len(results['not_found'])}")
        for path in results["not_found"]:
            print(f"  - {path}")

    if results["unchanged"]:
        print(f"Unchanged: {len(results['unchanged'])}")
        for path in results["unchanged"]:
            print(f"  - {path}")

    if results["errors"]:
        print(f"Errors:    {len(results['errors'])}")
        for item in results["errors"]:
            print(f"  - {item['path']}: {item['error']}")


def main():
    parser = argparse.ArgumentParser(
        description="Apply Meteor privacy modifications to PAK resources"
    )
    parser.add_argument(
        "-d", "--editable-dir",
        type=Path,
        default=DEFAULT_EDITABLE_DIR,
        help=f"Path to editable resources directory (default: {DEFAULT_EDITABLE_DIR})"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be modified without making changes"
    )
    args = parser.parse_args()

    if not args.editable_dir.exists():
        print(f"[!] Editable directory not found: {args.editable_dir}")
        print("[*] Please extract resources.pak first:")
        print("    python tools/extract_all.py")
        return 1

    if args.dry_run:
        print("[*] DRY RUN - No files will be modified")
        print()

    results = apply_modifications(args.editable_dir, args.dry_run)
    print_summary(results)

    if results["modified"] and not args.dry_run:
        print()
        print("[*] To repack resources.pak, run:")
        print("    python tools/edit_and_repack.py -o output/resources.pak")

    return 0 if not results["errors"] else 1


if __name__ == "__main__":
    exit(main())
