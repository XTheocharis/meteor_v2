<#
.SYNOPSIS
    Verifies MAC calculations against browser-generated values.

.DESCRIPTION
    Reads live browser data from .meteor\User Data and Windows registry to verify
    our MAC calculations match the browser's actual MACs.

.PARAMETER DataPath
    Path to the .meteor directory (default: .\.meteor relative to meteor_v2 root)

.PARAMETER Verbose
    Show JSON values for all MACs, not just failures.

.PARAMETER ShowValues
    Show full JSON values for failed MACs.

.PARAMETER FilterPath
    Only test paths containing this substring.

.NOTES
    Run from the meteor_v2 directory:
    .\test-data\verify-macs.ps1
    .\test-data\verify-macs.ps1 -DataPath "D:\CustomPath\.meteor"
#>

param(
    [string]$DataPath = "",
    [switch]$Verbose,
    [switch]$ShowValues,
    [string]$FilterPath = ""
)

$ErrorActionPreference = "Stop"

# Load shared utilities
. "$PSScriptRoot\Test-Utilities.ps1"

# ============================================================================
# CONFIGURATION
# ============================================================================

# Default to .meteor in parent directory (meteor_v2\.meteor)
if ([string]::IsNullOrEmpty($DataPath)) {
    $DataPath = Get-MeteorDataPath
}

$SecurePrefsFile = Get-SecurePreferencesPath -DataPath $DataPath
$RegistryPath = Get-RegistryMacsPath

# ============================================================================
# LOAD DATA
# ============================================================================

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "MAC CALCULATION VERIFICATION (Live Data)" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""

# Get device ID
$deviceId = Get-WindowsSidWithoutRid
Write-Host "Device ID (SID without RID): $deviceId"
Write-Host "File MAC Seed: '$($script:FileMacSeed)' (empty = Comet)"
Write-Host "Registry MAC Seed: '$($script:RegistryMacSeed)'"
Write-Host ""

# Check for Secure Preferences file
if (-not (Test-Path $SecurePrefsFile)) {
    Write-Host "ERROR: Secure Preferences not found at: $SecurePrefsFile" -ForegroundColor Red
    Write-Host "Make sure you have run meteor.ps1 at least once to create the browser profile." -ForegroundColor Yellow
    exit 1
}

Write-Host "Reading: $SecurePrefsFile"

$securePrefsRaw = Get-Content $SecurePrefsFile -Raw -Encoding UTF8
$securePrefs = $securePrefsRaw | ConvertFrom-Json

# Extract file MACs from protection.macs
$fileMacs = @{}
if ($securePrefs.protection -and $securePrefs.protection.macs) {
    $fileMacs = Get-MacsFromNestedObject -Object $securePrefs.protection.macs
}

Write-Host "Found $($fileMacs.Count) file MACs in Secure Preferences"

# Read registry MACs (handles hierarchical structure)
# Chromium stores MACs in two ways:
#   1. Atomic MACs: Direct values in PreferenceMACs\Default (e.g., "browser.show_home_button")
#   2. Split MACs:  Values in subkeys (e.g., PreferenceMACs\Default\extensions.settings\{extId})
$registryMacs = @{}
if (Test-Path $RegistryPath) {
    Write-Host "Reading: $RegistryPath"

    # Read atomic MACs (direct values in the Default key)
    $regProps = Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue
    if ($regProps) {
        foreach ($prop in $regProps.PSObject.Properties) {
            # Skip PowerShell metadata properties
            if ($prop.Name -match '^PS') { continue }
            $registryMacs[$prop.Name] = $prop.Value
        }
    }

    # Read split MACs (values in subkeys)
    # These are stored as: PreferenceMACs\Default\{prefix}\{suffix} = MAC
    # Which represents path: {prefix}.{suffix}
    $subkeys = Get-ChildItem -Path $RegistryPath -ErrorAction SilentlyContinue
    foreach ($subkey in $subkeys) {
        $subkeyName = $subkey.PSChildName  # e.g., "extensions.settings"
        $subkeyPath = Join-Path $RegistryPath $subkeyName
        $subkeyProps = Get-ItemProperty -Path $subkeyPath -ErrorAction SilentlyContinue
        if ($subkeyProps) {
            foreach ($prop in $subkeyProps.PSObject.Properties) {
                # Skip PowerShell metadata properties
                if ($prop.Name -match '^PS') { continue }
                # Reconstruct full path: subkey name + "." + value name
                $fullPath = "$subkeyName.$($prop.Name)"
                $registryMacs[$fullPath] = $prop.Value
            }
        }
    }

    Write-Host "Found $($registryMacs.Count) registry MACs"
}
else {
    Write-Host "Registry path not found: $RegistryPath" -ForegroundColor Yellow
    Write-Host "Registry MACs will be skipped." -ForegroundColor Yellow
}

Write-Host ""

# ============================================================================
# FILE MACs VERIFICATION
# ============================================================================

$totalTests = 0
$passedTests = 0
$failedTests = @()

Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host "FILE MACs VERIFICATION" -ForegroundColor Yellow
Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host ""

foreach ($path in ($fileMacs.Keys | Sort-Object)) {
    # Apply filter if specified
    if ($FilterPath -and $path -notlike "*$FilterPath*") { continue }

    $expectedMac = $fileMacs[$path]

    # Get the actual value from secure preferences
    $value = Get-PrefValue -Root $securePrefs -Path $path

    # Check if this is an empty array in the raw JSON (PS5.1 converts [] to $null)
    if ($null -eq $value) {
        $lastPart = ($path -split '\.')[-1]
        if (Test-RawJsonHasEmptyArray -RawJson $securePrefsRaw -Key $lastPart) {
            $value = @()
        }
    }

    # Calculate MAC
    $calculatedMac = Get-PreferenceHmac -DeviceId $deviceId -Path $path -Value $value

    $totalTests++
    $match = $calculatedMac -eq $expectedMac

    if ($match) {
        $passedTests++
        $status = "[PASS]"
        $color = "Green"
    }
    else {
        $status = "[FAIL]"
        $color = "Red"
        $failedTests += @{
            Path = $path
            Expected = $expectedMac
            Calculated = $calculatedMac
            Value = $value
            ValueJson = (ConvertTo-JsonForHmac -Value $value)
        }
    }

    Write-Host "$status $path" -ForegroundColor $color

    if ($Verbose -or (-not $match)) {
        $valueJson = ConvertTo-JsonForHmac -Value $value
        if ($valueJson.Length -gt 80) {
            $valueJson = $valueJson.Substring(0, 77) + "..."
        }
        Write-Host "       Value JSON: $valueJson" -ForegroundColor DarkGray
    }

    if (-not $match) {
        Write-Host "       Expected:   $expectedMac" -ForegroundColor DarkGray
        Write-Host "       Calculated: $calculatedMac" -ForegroundColor DarkGray
    }
}

# ============================================================================
# REGISTRY MACs VERIFICATION
# ============================================================================

Write-Host ""
Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host "REGISTRY MACs VERIFICATION" -ForegroundColor Yellow
Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host ""

$regPassedTests = 0
$regTotalTests = 0
$regFailedTests = @()

foreach ($path in ($registryMacs.Keys | Sort-Object)) {
    # Apply filter if specified
    if ($FilterPath -and $path -notlike "*$FilterPath*") { continue }

    $expectedMac = $registryMacs[$path]

    # Get the actual value from secure preferences
    $value = Get-PrefValue -Root $securePrefs -Path $path

    # Check if this is an empty array in the raw JSON
    if ($null -eq $value) {
        $lastPart = ($path -split '\.')[-1]
        if (Test-RawJsonHasEmptyArray -RawJson $securePrefsRaw -Key $lastPart) {
            $value = @()
        }
    }

    # Calculate MAC with registry seed
    $calculatedMac = Get-RegistryPreferenceHmac -DeviceId $deviceId -Path $path -Value $value

    $regTotalTests++
    $match = $calculatedMac -eq $expectedMac

    if ($match) {
        $regPassedTests++
        $status = "[PASS]"
        $color = "Green"
    }
    else {
        $status = "[FAIL]"
        $color = "Red"
        $regFailedTests += @{
            Path = $path
            Expected = $expectedMac
            Calculated = $calculatedMac
            Value = $value
            ValueJson = (ConvertTo-JsonForHmac -Value $value)
        }
    }

    Write-Host "$status $path" -ForegroundColor $color

    if ($Verbose -or (-not $match)) {
        $valueJson = ConvertTo-JsonForHmac -Value $value
        if ($valueJson.Length -gt 80) {
            $valueJson = $valueJson.Substring(0, 77) + "..."
        }
        Write-Host "       Value JSON: $valueJson" -ForegroundColor DarkGray
    }

    if (-not $match) {
        Write-Host "       Expected:   $expectedMac" -ForegroundColor DarkGray
        Write-Host "       Calculated: $calculatedMac" -ForegroundColor DarkGray
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""

$fileFailed = $totalTests - $passedTests
$regFailed = $regTotalTests - $regPassedTests

Write-Host "File MACs:     $passedTests/$totalTests passed" -ForegroundColor $(if ($fileFailed -eq 0) { "Green" } else { "Yellow" })
Write-Host "Registry MACs: $regPassedTests/$regTotalTests passed" -ForegroundColor $(if ($regFailed -eq 0) { "Green" } else { "Yellow" })
Write-Host ""

if ($failedTests.Count -gt 0 -and $ShowValues) {
    Write-Host "=" * 80 -ForegroundColor Red
    Write-Host "FAILED FILE MACs - DETAILED VALUES" -ForegroundColor Red
    Write-Host "=" * 80 -ForegroundColor Red
    Write-Host ""

    foreach ($failed in $failedTests) {
        Write-Host "Path: $($failed.Path)" -ForegroundColor Yellow
        Write-Host "Value JSON:" -ForegroundColor White
        Write-Host $failed.ValueJson
        Write-Host ""
        Write-Host "Expected MAC:   $($failed.Expected)" -ForegroundColor DarkGray
        Write-Host "Calculated MAC: $($failed.Calculated)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "-" * 40
        Write-Host ""
    }
}

if ($regFailedTests.Count -gt 0 -and $ShowValues) {
    Write-Host "=" * 80 -ForegroundColor Red
    Write-Host "FAILED REGISTRY MACs - DETAILED VALUES" -ForegroundColor Red
    Write-Host "=" * 80 -ForegroundColor Red
    Write-Host ""

    foreach ($failed in $regFailedTests) {
        Write-Host "Path: $($failed.Path)" -ForegroundColor Yellow
        Write-Host "Value JSON:" -ForegroundColor White
        Write-Host $failed.ValueJson
        Write-Host ""
        Write-Host "Expected MAC:   $($failed.Expected)" -ForegroundColor DarkGray
        Write-Host "Calculated MAC: $($failed.Calculated)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "-" * 40
        Write-Host ""
    }
}

if ($fileFailed -gt 0 -or $regFailed -gt 0) {
    Write-Host "HINT: Run with -ShowValues to see full JSON values for failed MACs" -ForegroundColor Yellow
    Write-Host "HINT: Run with -FilterPath 'extensions.settings' to focus on specific paths" -ForegroundColor Yellow
}

# Exit with error code if any failures
if ($fileFailed -gt 0 -or $regFailed -gt 0) {
    exit 1
}
