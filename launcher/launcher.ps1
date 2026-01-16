<#
.SYNOPSIS
    Meteor v2 Launcher for Comet Browser (Windows PowerShell)

.DESCRIPTION
    Privacy-focused launcher for Comet browser with telemetry blocking,
    uBlock Origin MV2 support, and MCP UI force-enabling.

.PARAMETER Config
    Path to config.yaml (default: .\config.yaml)

.PARAMETER Setup
    Run setup before launching

.PARAMETER DryRun
    Print command without launching

.EXAMPLE
    .\launcher.ps1
    .\launcher.ps1 -Setup
    .\launcher.ps1 -DryRun
#>

param(
    [string]$Config = "",
    [switch]$Setup,
    [switch]$DryRun,
    [string]$Browser = ""
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Configuration
# ============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseDir = Split-Path -Parent $ScriptDir

if (-not $Config) {
    $Config = Join-Path $ScriptDir "config.yaml"
}

# Simple YAML parser (PowerShell 5.1 compatible)
function ConvertFrom-SimpleYaml {
    param([string]$Path)

    $content = Get-Content $Path -Raw
    $result = @{}

    # This is a simplified parser - for production, use powershell-yaml module
    # It handles the basic structure of config.yaml

    $currentSection = ""
    $currentSubSection = ""
    $inList = $false
    $listName = ""
    $listItems = @()

    foreach ($line in $content -split "`n") {
        $line = $line.TrimEnd()

        # Skip comments and empty lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }

        # Top-level section
        if ($line -match '^(\w+):') {
            if ($inList -and $listItems.Count -gt 0) {
                if ($currentSubSection) {
                    if (-not $result[$currentSection]) { $result[$currentSection] = @{} }
                    $result[$currentSection][$listName] = $listItems
                } else {
                    $result[$listName] = $listItems
                }
            }
            $inList = $false
            $listItems = @()
            $currentSection = $Matches[1]
            $currentSubSection = ""
            if (-not $result[$currentSection]) { $result[$currentSection] = @{} }
            continue
        }

        # Sub-section
        if ($line -match '^  (\w+):(.*)$') {
            if ($inList -and $listItems.Count -gt 0) {
                if (-not $result[$currentSection]) { $result[$currentSection] = @{} }
                $result[$currentSection][$listName] = $listItems
            }
            $inList = $false
            $listItems = @()
            $currentSubSection = $Matches[1]
            $value = $Matches[2].Trim()

            if ($value -and $value -notmatch '^#') {
                # Inline value
                $value = $value.Trim('"', "'")
                if (-not $result[$currentSection]) { $result[$currentSection] = @{} }
                $result[$currentSection][$currentSubSection] = $value
            } else {
                $listName = $currentSubSection
            }
            continue
        }

        # List item
        if ($line -match '^\s+-\s+"?([^"]+)"?') {
            $inList = $true
            $listItems += $Matches[1].Trim('"', "'")
            continue
        }

        # Key-value in sub-section (policies)
        if ($line -match '^\s{4}(\w+):\s*(.+)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim()

            # Parse value type
            if ($val -match '^\d+$') {
                $val = [int]$val
            } elseif ($val -eq 'true') {
                $val = 1
            } elseif ($val -eq 'false') {
                $val = 0
            } else {
                $val = $val.Trim('"', "'")
            }

            if (-not $result[$currentSection]) { $result[$currentSection] = @{} }
            if (-not $result[$currentSection][$currentSubSection]) {
                $result[$currentSection][$currentSubSection] = @{}
            }
            $result[$currentSection][$currentSubSection][$key] = $val
        }
    }

    # Save any remaining list
    if ($inList -and $listItems.Count -gt 0) {
        if (-not $result[$currentSection]) { $result[$currentSection] = @{} }
        $result[$currentSection][$listName] = $listItems
    }

    return $result
}

# ============================================================================
# Browser Detection
# ============================================================================

function Find-CometBrowser {
    $paths = @(
        "$env:LOCALAPPDATA\Comet\Application\comet.exe",
        "$env:PROGRAMFILES\Comet\Application\comet.exe",
        "${env:PROGRAMFILES(x86)}\Comet\Application\comet.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            return $path
        }
    }

    # Try where command
    try {
        $result = where.exe comet 2>$null
        if ($result) { return $result.Split("`n")[0] }
    } catch {}

    return $null
}

# ============================================================================
# Registry Policies
# ============================================================================

function Apply-RegistryPolicies {
    param([hashtable]$Config)

    $regConfig = $Config["registry"]
    if (-not $regConfig) { return }

    Write-Host "[*] Applying Windows registry policies..."

    $regPath = "HKCU:\SOFTWARE\Policies\Chromium"

    # Create key if not exists
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }

    $policies = $regConfig["policies"]
    if ($policies) {
        foreach ($key in $policies.Keys) {
            $value = $policies[$key]
            Set-ItemProperty -Path $regPath -Name $key -Value $value -Type DWord -Force
        }
        Write-Host "    -> Applied $($policies.Count) policies"
    }

    # Sub-keys
    foreach ($subKeyName in @("ExtensionInstallForcelist", "MandatoryExtensionsForIncognitoNavigation", "PrinterTypeDenyList")) {
        $subKeyValues = $regConfig[$subKeyName]
        if ($subKeyValues) {
            $subKeyPath = "$regPath\$subKeyName"
            if (-not (Test-Path $subKeyPath)) {
                New-Item -Path $subKeyPath -Force | Out-Null
            }
            for ($i = 0; $i -lt $subKeyValues.Count; $i++) {
                Set-ItemProperty -Path $subKeyPath -Name ($i + 1) -Value $subKeyValues[$i] -Type String -Force
            }
        }
    }
}

# ============================================================================
# Main
# ============================================================================

Write-Host "Meteor v2 Launcher for Comet Browser"
Write-Host "======================================"

# Load config
if (-not (Test-Path $Config)) {
    Write-Host "[!] Config not found: $Config" -ForegroundColor Red
    exit 1
}

Write-Host "[*] Loading config: $Config"
$cfg = ConvertFrom-SimpleYaml -Path $Config

# Run setup if requested
if ($Setup) {
    $setupScript = Join-Path $BaseDir "tools\setup.py"
    if (Test-Path $setupScript) {
        Write-Host "[*] Running setup..."
        python $setupScript
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[!] Setup failed" -ForegroundColor Red
            exit 1
        }
    }
}

# Find browser
if ($Browser) {
    $browserExe = $Browser
} elseif ($cfg["browser"] -and $cfg["browser"]["executable"]) {
    $browserExe = $cfg["browser"]["executable"]
} else {
    $browserExe = Find-CometBrowser
}

if (-not $browserExe -or -not (Test-Path $browserExe)) {
    Write-Host "[!] Comet browser not found" -ForegroundColor Red
    Write-Host "[*] Please specify with -Browser parameter"
    exit 1
}

Write-Host "[*] Using browser: $browserExe"

# Check patched extensions
$extPath = Join-Path $BaseDir "patched_extensions"
if (-not (Test-Path $extPath)) {
    Write-Host "[!] Patched extensions not found: $extPath" -ForegroundColor Red
    Write-Host "[*] Run: python tools\setup.py first"
    exit 1
}

Write-Host "[*] Using extensions: $extPath"

# Check uBlock Origin
$ublockPath = Join-Path $BaseDir "ublock-origin"
if (-not (Test-Path $ublockPath)) {
    Write-Host "[*] uBlock Origin not found. Downloading..."
    $downloadScript = Join-Path $BaseDir "ublock\download.py"
    if (Test-Path $downloadScript) {
        python $downloadScript -o $ublockPath
    }
}

if (Test-Path $ublockPath) {
    Write-Host "[*] Using uBlock Origin: $ublockPath"
}

# Apply registry policies
Apply-RegistryPolicies -Config $cfg

# Build command line
$cmdArgs = @()

# Flags
$browserCfg = $cfg["browser"]
if ($browserCfg -and $browserCfg["flags"]) {
    foreach ($flag in $browserCfg["flags"]) {
        $flag = $flag -replace '\$\{UBLOCK_PATH\}', $ublockPath
        $cmdArgs += $flag
    }
}

# Enable features
if ($browserCfg -and $browserCfg["enable_features"]) {
    $cmdArgs += "--enable-features=$($browserCfg["enable_features"] -join ',')"
}

# Disable features
if ($browserCfg -and $browserCfg["disable_features"]) {
    $cmdArgs += "--disable-features=$($browserCfg["disable_features"] -join ',')"
}

# Load extensions
$extensions = @(
    (Join-Path $extPath "perplexity")
)

$cwrPath = Join-Path $extPath "comet_web_resources"
if (Test-Path $cwrPath) { $extensions += $cwrPath }

$agentsPath = Join-Path $extPath "agents"
if (Test-Path $agentsPath) { $extensions += $agentsPath }

if (Test-Path $ublockPath) { $extensions += $ublockPath }

$cmdArgs += "--load-extension=$($extensions -join ',')"

if ($DryRun) {
    Write-Host "`n[*] Dry run - command would be:"
    Write-Host "$browserExe $($cmdArgs -join ' ')"
    exit 0
}

# Launch browser
Write-Host "`n[*] Launching browser..."
$proc = Start-Process -FilePath $browserExe -ArgumentList $cmdArgs -PassThru

Write-Host "[+] Browser launched (PID: $($proc.Id))"
Write-Host "[*] Meteor v2 active - privacy protections enabled"
