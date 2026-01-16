#!/usr/bin/env python3
"""
Meteor v2 Launcher
==================
Cross-platform Python launcher for Comet browser with privacy enhancements.

Usage:
    python launcher.py [--config CONFIG] [--profile PROFILE] [--setup]
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

try:
    import yaml
except ImportError:
    print("[!] PyYAML not installed. Run: pip install pyyaml")
    sys.exit(1)


# Default paths by platform
DEFAULT_PATHS = {
    "Windows": [
        Path(os.environ.get("LOCALAPPDATA", "")) / "Comet" / "Application" / "comet.exe",
        Path(os.environ.get("PROGRAMFILES", "")) / "Comet" / "Application" / "comet.exe",
        Path(os.environ.get("PROGRAMFILES(X86)", "")) / "Comet" / "Application" / "comet.exe",
    ],
    "Darwin": [
        Path("/Applications/Comet.app/Contents/MacOS/Comet"),
        Path.home() / "Applications" / "Comet.app" / "Contents" / "MacOS" / "Comet",
    ],
    "Linux": [
        Path("/usr/bin/comet"),
        Path("/usr/local/bin/comet"),
        Path.home() / ".local" / "bin" / "comet",
        Path("/opt/comet/comet"),
    ],
}


def load_config(config_path: Path) -> dict:
    """Load configuration from YAML file."""
    if not config_path.exists():
        print(f"[!] Config not found: {config_path}")
        sys.exit(1)

    with open(config_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def detect_browser_executable() -> Optional[Path]:
    """Auto-detect Comet browser installation."""
    system = platform.system()
    paths = DEFAULT_PATHS.get(system, [])

    for path in paths:
        if path.exists():
            return path

    # Try which/where command
    cmd = "where" if system == "Windows" else "which"
    try:
        result = subprocess.run([cmd, "comet"], capture_output=True, text=True)
        if result.returncode == 0:
            return Path(result.stdout.strip().split("\n")[0])
    except Exception:
        pass

    return None


def resolve_path(base_dir: Path, path_str: str, variables: dict) -> Path:
    """Resolve path with variable substitution."""
    # Replace ${var} patterns
    for key, value in variables.items():
        path_str = path_str.replace(f"${{{key}}}", str(value))

    path = Path(path_str)
    if not path.is_absolute():
        path = base_dir / path

    return path.resolve()


def setup_patched_extensions(config: dict, base_dir: Path) -> Path:
    """Set up patched extensions directory. Returns the path."""
    paths = config.get("paths", {})
    variables = {"patched_extensions": paths.get("patched_extensions", "./patched_extensions")}

    ext_path = resolve_path(base_dir, paths.get("patched_extensions", "./patched_extensions"), variables)

    if not ext_path.exists():
        print(f"[!] Patched extensions not found: {ext_path}")
        print("[*] Run: python tools/setup.py first")
        sys.exit(1)

    return ext_path


def download_ublock_if_needed(config: dict, base_dir: Path) -> Optional[Path]:
    """Download uBlock Origin MV2 if not present. Returns the path."""
    paths = config.get("paths", {})
    ublock_path = resolve_path(base_dir, paths.get("ublock", "./ublock-origin"), {})

    if ublock_path.exists() and (ublock_path / "manifest.json").exists():
        return ublock_path

    print("[*] uBlock Origin not found. Downloading...")

    # Try to run the download script
    download_script = base_dir / "ublock" / "download.py"
    defaults_path = base_dir / "ublock" / "ublock-defaults.json"

    if download_script.exists():
        cmd = [sys.executable, str(download_script), "-o", str(ublock_path)]
        if defaults_path.exists():
            cmd.extend(["-d", str(defaults_path)])

        result = subprocess.run(cmd)
        if result.returncode == 0 and ublock_path.exists():
            return ublock_path

    print("[!] Failed to download uBlock Origin")
    print(f"[*] Please manually download and extract to: {ublock_path}")
    return None


def build_command_line(config: dict, ext_path: Path, ublock_path: Optional[Path],
                       browser_exe: Path, user_data_dir: Optional[Path] = None) -> list:
    """Build the browser command line with all flags."""
    cmd = [str(browser_exe)]

    browser_config = config.get("browser", {})

    # Add explicit flags
    for flag in browser_config.get("flags", []):
        # Substitute ${UBLOCK_PATH}
        if ublock_path:
            flag = flag.replace("${UBLOCK_PATH}", str(ublock_path))
        cmd.append(flag)

    # Build --enable-features
    enable_features = browser_config.get("enable_features", [])
    if enable_features:
        cmd.append(f"--enable-features={','.join(enable_features)}")

    # Build --disable-features
    disable_features = browser_config.get("disable_features", [])
    if disable_features:
        cmd.append(f"--disable-features={','.join(disable_features)}")

    # Add load-extension for patched extensions and uBlock
    extensions = [str(ext_path / "perplexity")]

    # Add comet_web_resources if exists
    cwr = ext_path / "comet_web_resources"
    if cwr.exists():
        extensions.append(str(cwr))

    # Add agents if exists
    agents = ext_path / "agents"
    if agents.exists():
        extensions.append(str(agents))

    # Add uBlock Origin
    if ublock_path and ublock_path.exists():
        extensions.append(str(ublock_path))

    cmd.append(f"--load-extension={','.join(extensions)}")

    # User data directory
    if user_data_dir:
        cmd.append(f"--user-data-dir={user_data_dir}")

    return cmd


def apply_registry_policies(config: dict) -> None:
    """Apply Windows registry policies (Windows only)."""
    if platform.system() != "Windows":
        return

    registry_config = config.get("registry", {})
    if not registry_config:
        return

    print("[*] Applying Windows registry policies...")

    try:
        import winreg
    except ImportError:
        print("[!] winreg not available")
        return

    reg_path = registry_config.get("path", "").replace("HKCU:\\", "")
    policies = registry_config.get("policies", {})

    try:
        # Create/open key
        key = winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, reg_path, 0, winreg.KEY_WRITE)

        for name, value in policies.items():
            if isinstance(value, bool):
                winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, 1 if value else 0)
            elif isinstance(value, int):
                winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, value)
            elif isinstance(value, str):
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)

        winreg.CloseKey(key)

        # Apply sub-keys
        for subkey_name in ["ExtensionInstallForcelist", "MandatoryExtensionsForIncognitoNavigation", "PrinterTypeDenyList"]:
            subkey_values = registry_config.get(subkey_name, [])
            if subkey_values:
                subkey_path = f"{reg_path}\\{subkey_name}"
                subkey = winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, subkey_path, 0, winreg.KEY_WRITE)
                for i, val in enumerate(subkey_values, 1):
                    winreg.SetValueEx(subkey, str(i), 0, winreg.REG_SZ, val)
                winreg.CloseKey(subkey)

        print(f"    -> Applied {len(policies)} policies to {reg_path}")

    except Exception as e:
        print(f"[!] Registry error: {e}")


def launch_browser(cmd: list) -> subprocess.Popen:
    """Launch the browser with the constructed command line."""
    print(f"\n[*] Launching browser...")
    print(f"    Command: {cmd[0]}")
    print(f"    Flags: {len(cmd) - 1}")

    # On Windows, use CREATE_NEW_CONSOLE to detach properly
    if platform.system() == "Windows":
        return subprocess.Popen(cmd, creationflags=subprocess.CREATE_NEW_CONSOLE)
    else:
        return subprocess.Popen(cmd, start_new_session=True)


def run_setup(base_dir: Path) -> None:
    """Run the setup script to prepare patched extensions."""
    setup_script = base_dir / "tools" / "setup.py"

    if not setup_script.exists():
        print(f"[!] Setup script not found: {setup_script}")
        sys.exit(1)

    print("[*] Running setup...")
    result = subprocess.run([sys.executable, str(setup_script)])

    if result.returncode != 0:
        print("[!] Setup failed")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Meteor v2 Launcher for Comet Browser")
    parser.add_argument("-c", "--config", type=Path, default=None,
                        help="Path to config.yaml")
    parser.add_argument("-p", "--profile", type=str, default=None,
                        help="Browser profile to use")
    parser.add_argument("--setup", action="store_true",
                        help="Run setup before launching")
    parser.add_argument("--browser", type=Path, default=None,
                        help="Path to browser executable")
    parser.add_argument("--user-data-dir", type=Path, default=None,
                        help="Custom user data directory")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print command without launching")
    args = parser.parse_args()

    # Determine base directory (where launcher.py is)
    base_dir = Path(__file__).parent.parent.resolve()

    # Find config
    if args.config:
        config_path = args.config
    else:
        config_path = Path(__file__).parent / "config.yaml"

    # Load config
    config = load_config(config_path)

    # Run setup if requested
    if args.setup:
        run_setup(base_dir)

    # Find browser executable
    if args.browser:
        browser_exe = args.browser
    elif config.get("browser", {}).get("executable"):
        browser_exe = Path(config["browser"]["executable"])
    else:
        browser_exe = detect_browser_executable()

    if not browser_exe or not browser_exe.exists():
        print("[!] Could not find Comet browser")
        print("[*] Please specify with --browser or set browser.executable in config")
        sys.exit(1)

    print(f"[*] Using browser: {browser_exe}")

    # Set up extensions
    ext_path = setup_patched_extensions(config, base_dir)
    print(f"[*] Using extensions: {ext_path}")

    # Get uBlock Origin
    ublock_path = download_ublock_if_needed(config, base_dir)
    if ublock_path:
        print(f"[*] Using uBlock Origin: {ublock_path}")

    # Apply registry policies (Windows only)
    apply_registry_policies(config)

    # Build command line
    cmd = build_command_line(config, ext_path, ublock_path, browser_exe, args.user_data_dir)

    if args.dry_run:
        print("\n[*] Dry run - command would be:")
        print(" ".join(cmd))
        return

    # Launch browser
    proc = launch_browser(cmd)
    print(f"[+] Browser launched (PID: {proc.pid})")
    print("[*] Meteor v2 active - privacy protections enabled")


if __name__ == "__main__":
    main()
