#!/usr/bin/env python3
"""
Meteor uBlock Origin MV2 Downloader
====================================
Downloads uBlock Origin MV2 from GitHub releases and applies Meteor defaults.

Usage:
    python download.py [--output DIR] [--version VERSION]
"""

import argparse
import json
import os
import shutil
import sys
import zipfile
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError

GITHUB_API = "https://api.github.com/repos/gorhill/uBlock/releases/latest"
RELEASE_PATTERN = "uBlock0_{version}.chromium.zip"
USER_AGENT = "Meteor/2.0"


def get_latest_release() -> dict:
    """Fetch latest uBlock Origin release info from GitHub API."""
    print("[*] Fetching latest uBlock Origin release...")

    req = Request(GITHUB_API, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode())
    except HTTPError as e:
        print(f"[!] GitHub API error: {e.code} {e.reason}")
        sys.exit(1)
    except URLError as e:
        print(f"[!] Network error: {e.reason}")
        sys.exit(1)


def find_chromium_asset(release: dict) -> tuple[str, str]:
    """Find the Chromium extension zip from release assets."""
    version = release["tag_name"]
    expected_name = RELEASE_PATTERN.format(version=version)

    for asset in release.get("assets", []):
        name = asset["name"]
        if name.endswith(".chromium.zip") and "uBlock0" in name:
            return asset["browser_download_url"], name

    # Fallback: construct expected URL
    fallback_url = f"https://github.com/gorhill/uBlock/releases/download/{version}/{expected_name}"
    return fallback_url, expected_name


def download_file(url: str, output_path: Path) -> None:
    """Download a file from URL to the specified path."""
    print(f"[*] Downloading from: {url}")

    req = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(req, timeout=120) as response:
            total = int(response.headers.get("Content-Length", 0))
            downloaded = 0

            with open(output_path, "wb") as f:
                while True:
                    chunk = response.read(8192)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)

                    if total > 0:
                        percent = (downloaded / total) * 100
                        print(f"\r[*] Progress: {percent:.1f}%", end="", flush=True)

            print()  # Newline after progress

    except HTTPError as e:
        print(f"\n[!] Download failed: {e.code} {e.reason}")
        sys.exit(1)
    except URLError as e:
        print(f"\n[!] Network error: {e.reason}")
        sys.exit(1)


def extract_extension(zip_path: Path, output_dir: Path) -> Path:
    """Extract the extension zip to output directory."""
    print(f"[*] Extracting to: {output_dir}")

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    with zipfile.ZipFile(zip_path, "r") as zf:
        # Check if contents are in a subdirectory
        names = zf.namelist()
        if names and "/" in names[0]:
            prefix = names[0].split("/")[0]
            # Extract with subdirectory handling
            zf.extractall(output_dir)
            inner_dir = output_dir / prefix
            if inner_dir.exists() and inner_dir.is_dir():
                # Move contents up one level
                for item in inner_dir.iterdir():
                    shutil.move(str(item), str(output_dir))
                inner_dir.rmdir()
        else:
            zf.extractall(output_dir)

    # Verify manifest.json exists
    manifest = output_dir / "manifest.json"
    if not manifest.exists():
        print("[!] Warning: manifest.json not found in extracted files")

    return output_dir


def inject_defaults(ublock_dir: Path, defaults_path: Path) -> None:
    """Inject Meteor defaults into uBlock Origin configuration."""
    if not defaults_path.exists():
        print(f"[!] Defaults file not found: {defaults_path}")
        return

    print(f"[*] Injecting Meteor defaults from: {defaults_path}")

    # Read defaults
    with open(defaults_path, "r", encoding="utf-8") as f:
        defaults = json.load(f)

    # uBlock Origin stores defaults in assets/user/
    assets_user = ublock_dir / "assets" / "user"
    assets_user.mkdir(parents=True, exist_ok=True)

    # Write user filters if present
    if "userFilters" in defaults:
        user_filters = assets_user / "filters.txt"
        with open(user_filters, "w", encoding="utf-8") as f:
            f.write(defaults["userFilters"])
        print(f"    -> Written: {user_filters}")

    # Copy the full defaults for reference
    full_defaults = ublock_dir / "meteor-defaults.json"
    shutil.copy(defaults_path, full_defaults)
    print(f"    -> Copied: {full_defaults}")


def main():
    parser = argparse.ArgumentParser(description="Download uBlock Origin MV2 for Meteor")
    parser.add_argument("-o", "--output", type=Path, default=Path("./ublock-origin"),
                        help="Output directory for extracted extension")
    parser.add_argument("-v", "--version", type=str, default=None,
                        help="Specific version to download (default: latest)")
    parser.add_argument("-d", "--defaults", type=Path, default=None,
                        help="Path to ublock-defaults.json")
    args = parser.parse_args()

    # Get release info
    if args.version:
        # Construct URL for specific version
        url = f"https://github.com/gorhill/uBlock/releases/download/{args.version}/uBlock0_{args.version}.chromium.zip"
        filename = f"uBlock0_{args.version}.chromium.zip"
    else:
        release = get_latest_release()
        url, filename = find_chromium_asset(release)
        print(f"[*] Latest version: {release['tag_name']}")

    # Download
    zip_path = Path(f"/tmp/{filename}")
    download_file(url, zip_path)

    # Extract
    extract_extension(zip_path, args.output)

    # Inject defaults
    if args.defaults:
        inject_defaults(args.output, args.defaults)
    else:
        # Try default location
        script_dir = Path(__file__).parent
        default_defaults = script_dir / "ublock-defaults.json"
        if default_defaults.exists():
            inject_defaults(args.output, default_defaults)

    # Cleanup
    if zip_path.exists():
        zip_path.unlink()

    print(f"\n[+] uBlock Origin MV2 ready at: {args.output.absolute()}")
    print("[*] Load in browser with: --load-extension=" + str(args.output.absolute()))


if __name__ == "__main__":
    main()
