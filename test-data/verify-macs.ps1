<#
.SYNOPSIS
    Verifies MAC calculations against browser-generated values.

.DESCRIPTION
    Loads browser-captured test data and compares our calculated MACs against
    the browser's actual MACs. Helps identify JSON serialization differences.

.NOTES
    Run from the meteor_v2 directory:
    .\test-data\verify-macs.ps1
#>

param(
    [switch]$Verbose,
    [switch]$ShowValues,
    [string]$FilterPath = ""
)

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION
# ============================================================================

$TestDataDir = Join-Path $PSScriptRoot ""
$BrowserStateFile = Join-Path $TestDataDir "browser-state.json"
$SecurePrefsFile = Join-Path $TestDataDir "secure-preferences.json"

# ============================================================================
# LOAD TEST DATA
# ============================================================================

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "MAC CALCULATION VERIFICATION" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $BrowserStateFile)) {
    Write-Host "ERROR: $BrowserStateFile not found" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $SecurePrefsFile)) {
    Write-Host "ERROR: $SecurePrefsFile not found" -ForegroundColor Red
    exit 1
}

$browserState = Get-Content $BrowserStateFile -Raw | ConvertFrom-Json
$securePrefs = Get-Content $SecurePrefsFile -Raw | ConvertFrom-Json
$securePrefsRaw = Get-Content $SecurePrefsFile -Raw

Write-Host "Device ID: $($browserState.device_id)"
Write-Host "File MAC Seed: '$($browserState.file_mac_seed)' (empty = Comet)"
Write-Host "Registry MAC Seed: '$($browserState.registry_mac_seed)'"
Write-Host ""

# ============================================================================
# MAC CALCULATION FUNCTIONS
# ============================================================================

function Get-HmacSha256 {
    param(
        [string]$Key,
        [string]$Message
    )

    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($Message)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hashBytes = $hmac.ComputeHash($messageBytes)

    return ($hashBytes | ForEach-Object { $_.ToString("X2") }) -join ""
}

function ConvertTo-SortedAndPruned {
    <#
    .SYNOPSIS
        Recursively sorts keys and prunes empty containers.
    .DESCRIPTION
        Chromium's PrefHashCalculator:
        1. Sorts dictionary keys alphabetically
        2. PRUNES empty Dict and List values (removes them entirely)

        PowerShell's ConvertTo-Json does NOT sort keys or prune empties.
        This function creates a copy with sorted keys and empty containers removed.
    #>
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    elseif ($Value -is [array]) {
        # Process array items (but don't prune items from arrays)
        $result = @()
        foreach ($item in $Value) {
            $result += ConvertTo-SortedAndPruned -Value $item
        }
        # CRITICAL: Use comma operator to prevent PowerShell from unrolling empty arrays to $null
        return ,$result
    }
    elseif ($Value -is [hashtable]) {
        $sorted = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object)) {
            $childValue = ConvertTo-SortedAndPruned -Value $Value[$key]
            # PRUNE: Skip null, empty arrays, empty hashtables, and empty PSCustomObjects
            if ($null -eq $childValue) {
                continue
            }
            if ($childValue -is [array] -and $childValue.Count -eq 0) {
                continue
            }
            if ($childValue -is [hashtable] -and $childValue.Count -eq 0) {
                continue
            }
            if ($childValue -is [System.Collections.Specialized.OrderedDictionary] -and $childValue.Count -eq 0) {
                continue
            }
            if ($childValue -is [PSCustomObject] -and $childValue.PSObject.Properties.Count -eq 0) {
                continue
            }
            $sorted[$key] = $childValue
        }
        return $sorted
    }
    elseif ($Value -is [PSCustomObject]) {
        $sorted = [ordered]@{}
        foreach ($prop in ($Value.PSObject.Properties | Sort-Object Name)) {
            $childValue = ConvertTo-SortedAndPruned -Value $prop.Value
            # PRUNE: Skip null, empty arrays, empty objects, and empty PSCustomObjects
            if ($null -eq $childValue) {
                continue
            }
            if ($childValue -is [array] -and $childValue.Count -eq 0) {
                continue
            }
            if ($childValue -is [hashtable] -and $childValue.Count -eq 0) {
                continue
            }
            if ($childValue -is [System.Collections.Specialized.OrderedDictionary] -and $childValue.Count -eq 0) {
                continue
            }
            if ($childValue -is [PSCustomObject] -and $childValue.PSObject.Properties.Count -eq 0) {
                continue
            }
            $sorted[$prop.Name] = $childValue
        }
        return $sorted
    }
    else {
        return $Value
    }
}

function ConvertTo-ChromiumJson {
    <#
    .SYNOPSIS
        Normalize PowerShell JSON to match Chromium's JSONWriter format.
    .DESCRIPTION
        PowerShell's ConvertTo-Json uses different unicode escaping than Chromium:
        - PowerShell: \u003c (lowercase), \u003e (escaped >)
        - Chromium:   \u003C (uppercase), > (not escaped)

        This function normalizes the JSON string to match Chromium's format.
    #>
    param([string]$Json)

    if ([string]::IsNullOrEmpty($Json)) {
        return $Json
    }

    # Step 1: Convert all lowercase unicode escapes to uppercase
    $result = [regex]::Replace($Json, '\\u([0-9a-fA-F]{4})', {
        param($match)
        "\u" + $match.Groups[1].Value.ToUpper()
    })

    # Step 2: Unescape > (Chromium doesn't escape it)
    $result = $result -replace '\\u003E', '>'

    return $result
}

function ConvertTo-JsonForHmac {
    <#
    .SYNOPSIS
        Serialize value to JSON string for HMAC calculation.
    .DESCRIPTION
        Chromium's serialization rules:
        - Null:     "" (empty string, NOT "null")
        - Boolean:  "true" or "false" (lowercase)
        - Array:    "[]" for empty, or JSON with sorted keys (after pruning empty children)
        - Object:   JSON with keys sorted alphabetically (empty containers pruned)
        - String:   JSON-quoted
        - Number:   String representation

        CRITICAL: Chromium prunes empty Dict and List values before MAC calculation!
        CRITICAL: Unicode escaping must match Chromium's format (uppercase hex, > not escaped)
    #>
    param($Value)

    if ($null -eq $Value) {
        return ""  # CRITICAL: Chromium uses empty string for null
    }
    elseif ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }
    elseif ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return "[]"
        }
        # Sort and prune, then serialize
        $pruned = ConvertTo-SortedAndPruned -Value $Value
        $json = ConvertTo-Json -InputObject $pruned -Compress -Depth 20
        return ConvertTo-ChromiumJson -Json $json
    }
    elseif ($Value -is [hashtable] -or $Value -is [PSCustomObject]) {
        # Sort and prune empty containers, then serialize
        $pruned = ConvertTo-SortedAndPruned -Value $Value
        # After pruning, check if result is empty
        if ($pruned -is [hashtable] -and $pruned.Count -eq 0) {
            return "{}"
        }
        if ($pruned -is [System.Collections.Specialized.OrderedDictionary] -and $pruned.Count -eq 0) {
            return "{}"
        }
        $json = ConvertTo-Json -InputObject $pruned -Compress -Depth 20
        return ConvertTo-ChromiumJson -Json $json
    }
    elseif ($Value -is [string]) {
        # JSON-encode the string (adds quotes and escapes)
        $json = ConvertTo-Json -InputObject $Value -Compress
        return ConvertTo-ChromiumJson -Json $json
    }
    elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return $Value.ToString()
    }
    else {
        $pruned = ConvertTo-SortedAndPruned -Value $Value
        $json = ConvertTo-Json -InputObject $pruned -Compress -Depth 20
        return ConvertTo-ChromiumJson -Json $json
    }
}

function Calculate-Mac {
    param(
        [string]$Seed,
        [string]$DeviceId,
        [string]$Path,
        $Value
    )

    $valueJson = ConvertTo-JsonForHmac -Value $Value
    $message = $DeviceId + $Path + $valueJson
    return Get-HmacSha256 -Key $Seed -Message $message
}

function Get-PrefValue {
    <#
    .SYNOPSIS
        Navigate a dotted path like "extensions.settings.xyz" to get a value.
    #>
    param(
        [PSCustomObject]$Root,
        [string]$Path
    )

    $parts = $Path -split '\.'
    $current = $Root

    foreach ($part in $parts) {
        if ($null -eq $current) {
            return $null
        }
        elseif ($current -is [PSCustomObject]) {
            if ($current.PSObject.Properties.Name -contains $part) {
                $current = $current.$part
            }
            else {
                return $null
            }
        }
        elseif ($current -is [hashtable]) {
            if ($current.ContainsKey($part)) {
                $current = $current[$part]
            }
            else {
                return $null
            }
        }
        else {
            return $null
        }
    }

    return $current
}

function Test-RawJsonHasEmptyArray {
    <#
    .SYNOPSIS
        Check if the raw JSON has an empty array [] for the given key.
    #>
    param(
        [string]$RawJson,
        [string]$Key
    )

    # Look for "key":[] pattern
    $escapedKey = [regex]::Escape($Key)
    $pattern = "`"$escapedKey`"\s*:\s*\[\s*\]"
    return $RawJson -match $pattern
}

# ============================================================================
# RUN VERIFICATION
# ============================================================================

$deviceId = $browserState.device_id
$fileSeed = $browserState.file_mac_seed
$registrySeed = $browserState.registry_mac_seed

$totalTests = 0
$passedTests = 0
$failedTests = @()

Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host "FILE MACs VERIFICATION" -ForegroundColor Yellow
Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host ""

foreach ($prop in $browserState.file_macs.PSObject.Properties) {
    $path = $prop.Name

    # Skip metadata
    if ($path -eq "_description") { continue }

    # Apply filter if specified
    if ($FilterPath -and $path -notlike "*$FilterPath*") { continue }

    $expectedMac = $prop.Value

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
    $calculatedMac = Calculate-Mac -Seed $fileSeed -DeviceId $deviceId -Path $path -Value $value

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

Write-Host ""
Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host "REGISTRY MACs VERIFICATION" -ForegroundColor Yellow
Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host ""

$regPassedTests = 0
$regTotalTests = 0

foreach ($prop in $browserState.registry_macs.PSObject.Properties) {
    $path = $prop.Name

    # Skip metadata
    if ($path -eq "_description") { continue }

    # Apply filter if specified
    if ($FilterPath -and $path -notlike "*$FilterPath*") { continue }

    $expectedMac = $prop.Value

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
    $calculatedMac = Calculate-Mac -Seed $registrySeed -DeviceId $deviceId -Path $path -Value $value

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

if ($fileFailed -gt 0 -or $regFailed -gt 0) {
    Write-Host "HINT: Run with -ShowValues to see full JSON values for failed MACs" -ForegroundColor Yellow
    Write-Host "HINT: Run with -FilterPath 'extensions.settings' to focus on specific paths" -ForegroundColor Yellow
}
