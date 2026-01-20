<#
.SYNOPSIS
    Compare raw file/registry JSON with PowerShell round-tripped JSON.

.DESCRIPTION
    This script helps debug MAC calculation mismatches by showing:
    1. Raw JSON from file (exactly as Chromium wrote it)
    2. PowerShell parsed -> re-serialized JSON (what we calculate MACs for)
    3. The differences that cause MAC mismatches

.PARAMETER DataPath
    Path to .meteor directory (default: .\.meteor)

.PARAMETER ExtensionId
    Specific extension ID to analyze (default: mhjfbmdgcfjbbpaeojofohoefgiehjai - Chrome PDF Viewer)
#>

param(
    [string]$DataPath = ".\.meteor",
    [string]$ExtensionId = "mhjfbmdgcfjbbpaeojofohoefgiehjai"
)

$ErrorActionPreference = "Stop"

# Paths
$SecurePrefsPath = Join-Path $DataPath "User Data\Default\Secure Preferences"
$RegistryPath = "HKCU:\Software\Perplexity\Comet\PreferenceMACs\Default"

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "JSON SERIALIZATION COMPARISON" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# PART 1: RAW FILE CONTENTS
# ============================================================================

Write-Host "=== PART 1: RAW FILE CONTENTS ===" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $SecurePrefsPath)) {
    Write-Host "ERROR: Secure Preferences not found at: $SecurePrefsPath" -ForegroundColor Red
    exit 1
}

$rawJson = Get-Content $SecurePrefsPath -Raw -Encoding UTF8
Write-Host "File: $SecurePrefsPath"
Write-Host "Raw file length: $($rawJson.Length) chars"
Write-Host ""

# Extract specific extension JSON using regex (to get EXACT bytes)
$extPath = "extensions.settings.$ExtensionId"
Write-Host "Extracting raw JSON for: $extPath" -ForegroundColor Cyan

# Pattern to find the extension settings - this is tricky because JSON is nested
# We'll use a simpler approach: find the start and count braces
$searchKey = "`"$ExtensionId`":"
$startIndex = $rawJson.IndexOf($searchKey)

if ($startIndex -eq -1) {
    Write-Host "ERROR: Extension $ExtensionId not found in file" -ForegroundColor Red
} else {
    # Find the opening brace after the key
    $braceStart = $rawJson.IndexOf("{", $startIndex)

    # Count braces to find the matching close
    $depth = 0
    $braceEnd = -1
    for ($i = $braceStart; $i -lt $rawJson.Length; $i++) {
        $char = $rawJson[$i]
        if ($char -eq '{') { $depth++ }
        elseif ($char -eq '}') {
            $depth--
            if ($depth -eq 0) {
                $braceEnd = $i
                break
            }
        }
    }

    if ($braceEnd -gt $braceStart) {
        $rawExtJson = $rawJson.Substring($braceStart, $braceEnd - $braceStart + 1)
        Write-Host ""
        Write-Host "RAW JSON from file (first 500 chars):" -ForegroundColor Green
        Write-Host $rawExtJson.Substring(0, [Math]::Min(500, $rawExtJson.Length))
        if ($rawExtJson.Length -gt 500) {
            Write-Host "... (truncated, total $($rawExtJson.Length) chars)"
        }
        Write-Host ""

        # Show specific patterns we care about
        Write-Host "Key patterns in raw JSON:" -ForegroundColor Cyan

        # Check for empty arrays
        $emptyArrayMatches = [regex]::Matches($rawExtJson, '"([^"]+)":\s*\[\s*\]')
        Write-Host "  Empty arrays ([]):"
        foreach ($match in $emptyArrayMatches) {
            Write-Host "    - $($match.Groups[1].Value)"
        }

        # Check for empty objects
        $emptyObjMatches = [regex]::Matches($rawExtJson, '"([^"]+)":\s*\{\s*\}')
        Write-Host "  Empty objects ({}):"
        foreach ($match in $emptyObjMatches) {
            Write-Host "    - $($match.Groups[1].Value)"
        }
    }
}

Write-Host ""

# ============================================================================
# PART 2: POWERSHELL ROUND-TRIP
# ============================================================================

Write-Host "=== PART 2: POWERSHELL ROUND-TRIP ===" -ForegroundColor Yellow
Write-Host ""

# Parse the entire file
$parsed = $rawJson | ConvertFrom-Json

# Get the extension value
$extValue = $parsed.extensions.settings.$ExtensionId

if ($null -eq $extValue) {
    Write-Host "ERROR: Extension value is null after parsing" -ForegroundColor Red
} else {
    Write-Host "Parsed extension value type: $($extValue.GetType().FullName)"
    Write-Host "Parsed extension properties: $($extValue.PSObject.Properties.Name -join ', ')"
    Write-Host ""

    # Re-serialize with PowerShell's default
    $reserialized = $extValue | ConvertTo-Json -Compress -Depth 20

    Write-Host "RE-SERIALIZED JSON (first 500 chars):" -ForegroundColor Green
    Write-Host $reserialized.Substring(0, [Math]::Min(500, $reserialized.Length))
    if ($reserialized.Length -gt 500) {
        Write-Host "... (truncated, total $($reserialized.Length) chars)"
    }
    Write-Host ""

    # Check what happened to empty arrays
    Write-Host "After round-trip:" -ForegroundColor Cyan
    $emptyArrayMatches2 = [regex]::Matches($reserialized, '"([^"]+)":\s*\[\s*\]')
    Write-Host "  Empty arrays ([]):"
    foreach ($match in $emptyArrayMatches2) {
        Write-Host "    - $($match.Groups[1].Value)"
    }

    # Check for null values (PS 5.1 converts [] to null)
    $nullMatches = [regex]::Matches($reserialized, '"([^"]+)":\s*null')
    Write-Host "  Null values:"
    foreach ($match in $nullMatches) {
        Write-Host "    - $($match.Groups[1].Value)"
    }
}

Write-Host ""

# ============================================================================
# PART 3: KEY ORDER COMPARISON
# ============================================================================

Write-Host "=== PART 3: KEY ORDER COMPARISON ===" -ForegroundColor Yellow
Write-Host ""

if ($null -ne $extValue) {
    # Extract keys from raw JSON (in order they appear)
    $rawKeyMatches = [regex]::Matches($rawExtJson, '"([^"]+)":')
    $rawKeys = @()
    foreach ($match in $rawKeyMatches) {
        $key = $match.Groups[1].Value
        if ($key -notin $rawKeys) {
            $rawKeys += $key
        }
    }

    # Get keys from parsed object
    $parsedKeys = $extValue.PSObject.Properties.Name | Sort-Object

    Write-Host "Raw JSON key order (first 15):" -ForegroundColor Green
    Write-Host "  $($rawKeys[0..14] -join ', ')"
    Write-Host ""

    Write-Host "Parsed object keys (sorted, first 15):" -ForegroundColor Green
    Write-Host "  $($parsedKeys[0..14] -join ', ')"
    Write-Host ""

    # Check if sorted
    $rawSorted = ($rawKeys | Sort-Object) -join ','
    $rawOriginal = $rawKeys -join ','
    if ($rawSorted -eq $rawOriginal) {
        Write-Host "Raw JSON keys ARE sorted alphabetically" -ForegroundColor Green
    } else {
        Write-Host "Raw JSON keys are NOT sorted - Chromium stores unsorted!" -ForegroundColor Red
    }
}

Write-Host ""

# ============================================================================
# PART 4: REGISTRY MACS
# ============================================================================

Write-Host "=== PART 4: REGISTRY MACS ===" -ForegroundColor Yellow
Write-Host ""

if (Test-Path $RegistryPath) {
    $regValues = Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue

    # Find extension MAC
    $extMacKey = "extensions.settings.$ExtensionId"
    $regMac = $regValues.$extMacKey

    if ($regMac) {
        Write-Host "Registry MAC for $extMacKey :"
        Write-Host "  $regMac"
    } else {
        Write-Host "No registry MAC found for $extMacKey"
    }

    Write-Host ""
    Write-Host "All registry MAC keys:" -ForegroundColor Cyan
    $regValues.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
        Write-Host "  $($_.Name)"
    }
} else {
    Write-Host "Registry path not found: $RegistryPath"
}

Write-Host ""

# ============================================================================
# PART 5: FILE MACS
# ============================================================================

Write-Host "=== PART 5: FILE MACS ===" -ForegroundColor Yellow
Write-Host ""

$fileMac = $parsed.protection.macs.extensions.settings.$ExtensionId

if ($fileMac) {
    Write-Host "File MAC for $extPath :"
    Write-Host "  $fileMac"
} else {
    Write-Host "No file MAC found for $extPath"
}

Write-Host ""

# ============================================================================
# PART 6: SPECIFIC VALUE COMPARISONS
# ============================================================================

Write-Host "=== PART 6: SPECIFIC VALUE DEEP DIVE ===" -ForegroundColor Yellow
Write-Host ""

if ($null -ne $extValue) {
    # Check active_permissions specifically (common source of issues)
    Write-Host "active_permissions analysis:" -ForegroundColor Cyan

    $activePerms = $extValue.active_permissions
    if ($null -eq $activePerms) {
        Write-Host "  active_permissions is NULL (was it an empty object in file?)"

        # Check raw JSON
        if ($rawExtJson -match '"active_permissions"\s*:\s*\{[^}]*\}') {
            Write-Host "  Raw JSON had: $($Matches[0])"
        }
    } else {
        Write-Host "  active_permissions type: $($activePerms.GetType().FullName)"
        Write-Host "  active_permissions properties:"
        $activePerms.PSObject.Properties | ForEach-Object {
            $val = $_.Value
            $valType = if ($null -eq $val) { "null" } elseif ($val -is [array]) { "array[$($val.Count)]" } else { $val.GetType().Name }
            Write-Host "    $($_.Name): $valType"
        }
    }

    Write-Host ""

    # Check commands
    Write-Host "commands analysis:" -ForegroundColor Cyan
    $commands = $extValue.commands
    if ($null -eq $commands) {
        Write-Host "  commands is NULL"
        if ($rawExtJson -match '"commands"\s*:\s*(\{[^}]*\}|\[\])') {
            Write-Host "  Raw JSON had: $($Matches[0])"
        }
    } else {
        Write-Host "  commands type: $($commands.GetType().FullName)"
        if ($commands -is [array]) {
            Write-Host "  commands count: $($commands.Count)"
        }
    }
}

Write-Host ""

# ============================================================================
# PART 7: NORMALIZED JSON COMPARISON
# ============================================================================

Write-Host "=== PART 7: NORMALIZED JSON COMPARISON ===" -ForegroundColor Yellow
Write-Host ""

# ConvertTo-ChromiumJson function (from meteor.ps1)
function ConvertTo-ChromiumJson {
    param([string]$Json)
    if ([string]::IsNullOrEmpty($Json)) { return $Json }
    $result = [regex]::Replace($Json, '\\u([0-9a-fA-F]{4})', {
        param($match)
        "\u" + $match.Groups[1].Value.ToUpper()
    })
    $result = $result -replace '\\u003E', '>'
    return $result
}

# ConvertTo-SortedAndPruned function
function ConvertTo-SortedAndPruned {
    param($Value)
    if ($null -eq $Value) { return $null }
    elseif ($Value -is [array]) {
        $result = @()
        foreach ($item in $Value) {
            $result += ConvertTo-SortedAndPruned -Value $item
        }
        return $result
    }
    elseif ($Value -is [PSCustomObject]) {
        $sorted = [ordered]@{}
        foreach ($prop in ($Value.PSObject.Properties | Sort-Object Name)) {
            $childValue = ConvertTo-SortedAndPruned -Value $prop.Value
            # PRUNE: Skip empty arrays, empty objects, and empty PSCustomObjects
            if ($childValue -is [array] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [hashtable] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [System.Collections.Specialized.OrderedDictionary] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [PSCustomObject] -and $childValue.PSObject.Properties.Count -eq 0) { continue }
            $sorted[$prop.Name] = $childValue
        }
        return $sorted
    }
    else { return $Value }
}

if ($null -ne $extValue) {
    # Get our serialized JSON (sorted, pruned, normalized)
    $pruned = ConvertTo-SortedAndPruned -Value $extValue
    $ourJson = ConvertTo-Json -InputObject $pruned -Compress -Depth 20
    $ourJsonNormalized = ConvertTo-ChromiumJson -Json $ourJson

    Write-Host "Our serialized JSON length: $($ourJsonNormalized.Length) chars" -ForegroundColor Cyan
    Write-Host "Raw JSON length:            $($rawExtJson.Length) chars" -ForegroundColor Cyan
    Write-Host ""

    # Find first difference
    $minLen = [Math]::Min($ourJsonNormalized.Length, $rawExtJson.Length)
    $firstDiff = -1
    for ($i = 0; $i -lt $minLen; $i++) {
        if ($ourJsonNormalized[$i] -ne $rawExtJson[$i]) {
            $firstDiff = $i
            break
        }
    }

    if ($firstDiff -eq -1 -and $ourJsonNormalized.Length -ne $rawExtJson.Length) {
        $firstDiff = $minLen
    }

    if ($firstDiff -eq -1) {
        Write-Host "JSON MATCHES EXACTLY!" -ForegroundColor Green
    } else {
        Write-Host "FIRST DIFFERENCE at position $firstDiff" -ForegroundColor Red
        Write-Host ""

        # Show context around difference
        $start = [Math]::Max(0, $firstDiff - 30)
        $end = [Math]::Min($ourJsonNormalized.Length, $firstDiff + 30)

        Write-Host "Our JSON around diff:" -ForegroundColor Green
        $snippet = $ourJsonNormalized.Substring($start, [Math]::Min($end - $start, $ourJsonNormalized.Length - $start))
        Write-Host "  ...$snippet..."
        Write-Host "        $(' ' * ($firstDiff - $start))^" -ForegroundColor Red

        $end = [Math]::Min($rawExtJson.Length, $firstDiff + 30)
        Write-Host ""
        Write-Host "Raw JSON around diff:" -ForegroundColor Green
        $snippet = $rawExtJson.Substring($start, [Math]::Min($end - $start, $rawExtJson.Length - $start))
        Write-Host "  ...$snippet..."
        Write-Host "        $(' ' * ($firstDiff - $start))^" -ForegroundColor Red

        Write-Host ""
        Write-Host "Character values at diff position:" -ForegroundColor Cyan
        if ($firstDiff -lt $ourJsonNormalized.Length) {
            $ourChar = $ourJsonNormalized[$firstDiff]
            Write-Host "  Our:  '$ourChar' (0x$([int][char]$ourChar | ForEach-Object { $_.ToString("X2") }))"
        }
        if ($firstDiff -lt $rawExtJson.Length) {
            $rawChar = $rawExtJson[$firstDiff]
            Write-Host "  Raw:  '$rawChar' (0x$([int][char]$rawChar | ForEach-Object { $_.ToString("X2") }))"
        }
    }
}

Write-Host ""
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "DONE" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
