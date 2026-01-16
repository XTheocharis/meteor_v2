#!/usr/bin/env python3
"""
Meteor v2 PAK Build Script
==========================
Applies PAK modifications and repacks resources.pak.

This is a convenience wrapper that:
1. Runs pak_mods.py to apply privacy modifications
2. Runs edit_and_repack.py to create the modified resources.pak

Usage:
    python build_pak.py [-o OUTPUT] [--dry-run]
"""

import argparse
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(
        description="Apply Meteor modifications and repack resources.pak"
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        default=Path("output/resources.pak"),
        help="Output path for modified resources.pak"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes"
    )
    parser.add_argument(
        "--skip-mods",
        action="store_true",
        help="Skip running pak_mods.py (assume already applied)"
    )
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    meteor_root = script_dir.parent.parent

    # Step 1: Apply PAK modifications
    if not args.skip_mods:
        print("=" * 60)
        print("Step 1: Applying PAK Modifications")
        print("=" * 60)
        print()

        pak_mods = script_dir / "pak_mods.py"
        cmd = [sys.executable, str(pak_mods)]

        if args.dry_run:
            cmd.append("--dry-run")

        result = subprocess.run(cmd)

        if result.returncode != 0:
            print("\n[!] PAK modifications failed")
            return 1

    # Step 2: Repack resources.pak
    print()
    print("=" * 60)
    print("Step 2: Repacking resources.pak")
    print("=" * 60)
    print()

    edit_and_repack = meteor_root / "tools" / "edit_and_repack.py"

    if not edit_and_repack.exists():
        print(f"[!] edit_and_repack.py not found: {edit_and_repack}")
        print("[*] This tool is part of the main Meteor repository")
        return 1

    if args.dry_run:
        print(f"[*] Would create: {args.output}")
        print(f"[*] Using tool: {edit_and_repack}")
        return 0

    # Ensure output directory exists
    args.output.parent.mkdir(parents=True, exist_ok=True)

    cmd = [sys.executable, str(edit_and_repack), "-o", str(args.output)]
    result = subprocess.run(cmd)

    if result.returncode != 0:
        print("\n[!] Repacking failed")
        return 1

    print()
    print("=" * 60)
    print("[+] Build complete!")
    print("=" * 60)
    print(f"\n[*] Modified resources.pak: {args.output.absolute()}")
    print("\n[*] To install:")
    print(f"    1. Close Comet browser")
    print(f"    2. Copy {args.output} to your Comet installation directory")
    print(f"    3. Launch with: python launcher/launcher.py")

    return 0


if __name__ == "__main__":
    exit(main())
