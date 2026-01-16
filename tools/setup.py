#!/usr/bin/env python3
"""
Meteor v2 Setup Script
======================
Sets up patched extensions from extracted Comet extensions.

This script:
1. Extracts CRX extensions from Comet's default_apps (if needed)
2. Copies extensions to patched_extensions/ directory
3. Applies Meteor modifications (DNR rules, content scripts, manifest changes)
4. Modifies service-worker-loader.js to import meteor-prefs.js

Usage:
    python setup.py [--comet-dir DIR] [--output DIR] [--extracted DIR]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def find_comet_directory() -> Path:
    """Find the Comet installation directory."""
    # Common locations
    candidates = []

    if sys.platform == "win32":
        local_app_data = os.environ.get("LOCALAPPDATA", "")
        if local_app_data:
            candidates.append(Path(local_app_data) / "Comet" / "Application")
        program_files = os.environ.get("PROGRAMFILES", "")
        if program_files:
            candidates.append(Path(program_files) / "Comet" / "Application")
    elif sys.platform == "darwin":
        candidates.append(Path("/Applications/Comet.app/Contents/Resources"))
    else:
        candidates.append(Path("/opt/comet"))
        candidates.append(Path.home() / ".local" / "share" / "comet")

    for candidate in candidates:
        if candidate.exists():
            # Look for default_apps directory
            default_apps = candidate / "default_apps"
            if default_apps.exists():
                return candidate

            # Look for version subdirectory
            for subdir in candidate.iterdir():
                if subdir.is_dir() and (subdir / "default_apps").exists():
                    return subdir

    return None


def extract_crx_extensions(comet_dir: Path, extracted_dir: Path) -> bool:
    """Extract CRX extensions from Comet's default_apps."""
    default_apps = comet_dir / "default_apps"

    if not default_apps.exists():
        print(f"[!] default_apps not found in: {comet_dir}")
        return False

    # Find extract_crx.py tool
    script_dir = Path(__file__).parent
    meteor_root = script_dir.parent.parent
    extract_tool = meteor_root / "tools" / "extract_crx.py"

    if not extract_tool.exists():
        print(f"[!] extract_crx.py not found: {extract_tool}")
        return False

    # Extract each CRX
    crx_files = list(default_apps.glob("*.crx"))

    if not crx_files:
        print(f"[!] No CRX files found in: {default_apps}")
        return False

    for crx in crx_files:
        print(f"[*] Extracting: {crx.name}")
        result = subprocess.run([
            sys.executable, str(extract_tool),
            str(crx),
            "-o", str(extracted_dir)
        ], capture_output=True, text=True)

        if result.returncode != 0:
            print(f"    [!] Failed: {result.stderr}")
            return False

    return True


def copy_extension(src: Path, dst: Path) -> None:
    """Copy extension directory."""
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def apply_manifest_patch(manifest_path: Path, patch_path: Path) -> None:
    """Apply manifest.patch.json modifications to manifest.json."""
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)

    with open(patch_path, "r", encoding="utf-8") as f:
        patch = json.load(f)

    add_section = patch.get("add", {})

    # Add declarative_net_request
    if "declarative_net_request" in add_section:
        if "declarative_net_request" not in manifest:
            manifest["declarative_net_request"] = {}

        dnr = add_section["declarative_net_request"]
        if "rule_resources" in dnr:
            if "rule_resources" not in manifest["declarative_net_request"]:
                manifest["declarative_net_request"]["rule_resources"] = []
            manifest["declarative_net_request"]["rule_resources"].extend(dnr["rule_resources"])

    # Add content_scripts
    if "content_scripts" in add_section:
        if "content_scripts" not in manifest:
            manifest["content_scripts"] = []
        manifest["content_scripts"].extend(add_section["content_scripts"])

    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)


def modify_service_worker_loader(loader_path: Path) -> None:
    """Modify service-worker-loader.js to import meteor-prefs.js."""
    if not loader_path.exists():
        print(f"[!] service-worker-loader.js not found: {loader_path}")
        return

    content = loader_path.read_text(encoding="utf-8")

    # Check if already modified
    if "meteor-prefs.js" in content:
        print("    -> Already modified")
        return

    # Prepend import
    modified = f"import './meteor-prefs.js';  // Meteor preference enforcement\n{content}"
    loader_path.write_text(modified, encoding="utf-8")


def setup_perplexity_extension(extracted_dir: Path, output_dir: Path, patches_dir: Path) -> None:
    """Set up the modified perplexity extension."""
    src = extracted_dir / "perplexity"
    dst = output_dir / "perplexity"

    if not src.exists():
        print(f"[!] perplexity extension not found: {src}")
        return

    print("[*] Setting up perplexity extension...")

    # Copy base extension
    copy_extension(src, dst)
    print(f"    -> Copied to: {dst}")

    # Copy meteor-prefs.js
    meteor_prefs = patches_dir / "perplexity" / "meteor-prefs.js"
    if meteor_prefs.exists():
        shutil.copy(meteor_prefs, dst / "meteor-prefs.js")
        print("    -> Added: meteor-prefs.js")

    # Create rules directory and copy telemetry.json
    rules_dir = dst / "rules"
    rules_dir.mkdir(exist_ok=True)
    telemetry_rules = patches_dir / "perplexity" / "rules" / "telemetry.json"
    if telemetry_rules.exists():
        shutil.copy(telemetry_rules, rules_dir / "telemetry.json")
        print("    -> Added: rules/telemetry.json")

    # Create content directory and copy scripts
    content_dir = dst / "content"
    content_dir.mkdir(exist_ok=True)

    sdk_neutralizer = patches_dir / "perplexity" / "content" / "sdk-neutralizer.js"
    if sdk_neutralizer.exists():
        shutil.copy(sdk_neutralizer, content_dir / "sdk-neutralizer.js")
        print("    -> Added: content/sdk-neutralizer.js")

    feature_flags = patches_dir / "perplexity" / "content" / "feature-flags.js"
    if feature_flags.exists():
        shutil.copy(feature_flags, content_dir / "feature-flags.js")
        print("    -> Added: content/feature-flags.js")

    # Apply manifest patch
    manifest_patch = patches_dir / "perplexity" / "manifest.patch.json"
    if manifest_patch.exists():
        apply_manifest_patch(dst / "manifest.json", manifest_patch)
        print("    -> Applied: manifest.patch.json")

    # Modify service-worker-loader.js
    modify_service_worker_loader(dst / "service-worker-loader.js")
    print("    -> Modified: service-worker-loader.js")


def setup_comet_web_resources(extracted_dir: Path, output_dir: Path) -> None:
    """Copy comet_web_resources extension (unmodified)."""
    src = extracted_dir / "comet_web_resources"
    dst = output_dir / "comet_web_resources"

    if not src.exists():
        print(f"[*] comet_web_resources not found: {src}")
        return

    print("[*] Setting up comet_web_resources extension...")
    copy_extension(src, dst)
    print(f"    -> Copied to: {dst}")


def setup_agents(extracted_dir: Path, output_dir: Path) -> None:
    """Copy agents extension (unmodified)."""
    src = extracted_dir / "agents"
    dst = output_dir / "agents"

    if not src.exists():
        print(f"[*] agents extension not found: {src}")
        return

    print("[*] Setting up agents extension...")
    copy_extension(src, dst)
    print(f"    -> Copied to: {dst}")


def main():
    parser = argparse.ArgumentParser(description="Meteor v2 Setup Script")
    parser.add_argument("--comet-dir", type=Path, default=None,
                        help="Comet installation directory")
    parser.add_argument("--extracted", type=Path, default=None,
                        help="Directory with extracted extensions")
    parser.add_argument("--output", type=Path, default=None,
                        help="Output directory for patched extensions")
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    meteor_v2_dir = script_dir.parent

    # Find/create directories
    if args.extracted:
        extracted_dir = args.extracted
    else:
        # Check for Extracted in meteor root
        meteor_root = meteor_v2_dir.parent
        extracted_dir = meteor_root / "Extracted"

        if not extracted_dir.exists():
            print("[*] Extracted directory not found, looking for Comet installation...")

            comet_dir = args.comet_dir or find_comet_directory()
            if not comet_dir:
                print("[!] Could not find Comet installation")
                print("[*] Please specify with --comet-dir")
                sys.exit(1)

            print(f"[*] Found Comet at: {comet_dir}")
            extracted_dir = meteor_v2_dir / "extracted"
            extracted_dir.mkdir(exist_ok=True)

            if not extract_crx_extensions(comet_dir, extracted_dir):
                sys.exit(1)

    output_dir = args.output or meteor_v2_dir / "patched_extensions"
    output_dir.mkdir(parents=True, exist_ok=True)

    patches_dir = meteor_v2_dir / "patches"

    print(f"\n[*] Extracted extensions: {extracted_dir}")
    print(f"[*] Output directory: {output_dir}")
    print(f"[*] Patches directory: {patches_dir}")
    print()

    # Set up each extension
    setup_perplexity_extension(extracted_dir, output_dir, patches_dir)
    setup_comet_web_resources(extracted_dir, output_dir)
    setup_agents(extracted_dir, output_dir)

    print(f"\n[+] Setup complete!")
    print(f"[*] Patched extensions ready at: {output_dir}")
    print("[*] Launch browser with: python launcher/launcher.py")


if __name__ == "__main__":
    main()
