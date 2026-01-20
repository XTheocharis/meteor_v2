<#
.SYNOPSIS
    Debug the PDF Viewer MAC calculation specifically.
.DESCRIPTION
    Compares raw JSON from file with our serialized JSON to find differences.
#>

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION
# ============================================================================

$MeteorPath = Join-Path (Split-Path $PSScriptRoot -Parent) ".meteor"
$SecurePrefsFile = Join-Path $MeteorPath "User Data\Default\Secure Preferences"
$ExtensionId = "mhjfbmdgcfjbbpaeojofohoefgiehjai"
$ExtPath = "extensions.settings.$ExtensionId"

# Get device ID (without RID)
$fullSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$deviceId = $fullSid -replace '-\d+$', ''

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "PDF VIEWER MAC DEBUG" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""
Write-Host "Device ID: $deviceId"
Write-Host "Extension: $ExtensionId (PDF Viewer)"
Write-Host ""

# ============================================================================
# LOAD RAW FILE
# ============================================================================

if (-not (Test-Path $SecurePrefsFile)) {
    Write-Host "ERROR: Secure Preferences not found: $SecurePrefsFile" -ForegroundColor Red
    exit 1
}

$rawFileContent = Get-Content $SecurePrefsFile -Raw -Encoding UTF8
$parsed = $rawFileContent | ConvertFrom-Json

# Get the expected MAC
$expectedMac = $parsed.protection.macs.extensions.settings.$ExtensionId
Write-Host "Expected MAC: $expectedMac"
Write-Host ""

# ============================================================================
# EXTRACT RAW JSON FOR EXTENSION
# ============================================================================

Write-Host "=== EXTRACTING RAW JSON ===" -ForegroundColor Yellow

$searchKey = "`"$ExtensionId`":"
$startIndex = $rawFileContent.IndexOf($searchKey)

if ($startIndex -eq -1) {
    Write-Host "ERROR: Extension not found in raw file" -ForegroundColor Red
    exit 1
}

# Find the opening brace
$braceStart = $rawFileContent.IndexOf("{", $startIndex)

# Count braces to find matching close
$depth = 0
$braceEnd = -1
for ($i = $braceStart; $i -lt $rawFileContent.Length; $i++) {
    if ($rawFileContent[$i] -eq '{') { $depth++ }
    elseif ($rawFileContent[$i] -eq '}') {
        $depth--
        if ($depth -eq 0) {
            $braceEnd = $i
            break
        }
    }
}

$rawExtJson = $rawFileContent.Substring($braceStart, $braceEnd - $braceStart + 1)
Write-Host "Raw JSON length: $($rawExtJson.Length) chars"
Write-Host ""

# ============================================================================
# OUR SERIALIZATION FUNCTIONS
# ============================================================================

function ConvertTo-SortedAndPruned {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    elseif ($Value -is [array]) {
        $result = @()
        foreach ($item in $Value) {
            $childValue = ConvertTo-SortedAndPruned -Value $item
            if ($childValue -is [array] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [hashtable] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [System.Collections.Specialized.OrderedDictionary] -and $childValue.Count -eq 0) { continue }
            $result += $childValue
        }
        return ,$result
    }
    elseif ($Value -is [hashtable]) {
        $sorted = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object)) {
            $childValue = ConvertTo-SortedAndPruned -Value $Value[$key]
            if ($null -eq $childValue) { continue }
            if ($childValue -is [array] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [hashtable] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [System.Collections.Specialized.OrderedDictionary] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [PSCustomObject] -and $childValue.PSObject.Properties.Count -eq 0) { continue }
            $sorted[$key] = $childValue
        }
        return $sorted
    }
    elseif ($Value -is [PSCustomObject]) {
        $sorted = [ordered]@{}
        foreach ($prop in ($Value.PSObject.Properties | Sort-Object Name)) {
            $childValue = ConvertTo-SortedAndPruned -Value $prop.Value
            if ($null -eq $childValue) { continue }
            if ($childValue -is [array] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [hashtable] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [System.Collections.Specialized.OrderedDictionary] -and $childValue.Count -eq 0) { continue }
            if ($childValue -is [PSCustomObject] -and $childValue.PSObject.Properties.Count -eq 0) { continue }
            $sorted[$prop.Name] = $childValue
        }
        return $sorted
    }
    else {
        return $Value
    }
}

function ConvertTo-ChromiumJson {
    param([string]$Json)
    if ([string]::IsNullOrEmpty($Json)) { return $Json }
    # Chromium uses uppercase hex in \uXXXX escapes
    $result = [regex]::Replace($Json, '\\u([0-9a-fA-F]{4})', {
        param($match)
        "\u" + $match.Groups[1].Value.ToUpper()
    })
    # Chromium does NOT escape > (but does escape <)
    $result = $result -replace '\\u003E', '>'
    return $result
}

# ============================================================================
# OUR SERIALIZATION
# ============================================================================

Write-Host "=== OUR SERIALIZATION ===" -ForegroundColor Yellow

$extValue = $parsed.extensions.settings.$ExtensionId
$sorted = ConvertTo-SortedAndPruned -Value $extValue
$ourJson = ConvertTo-Json -InputObject $sorted -Compress -Depth 20
$ourJson = ConvertTo-ChromiumJson -Json $ourJson

Write-Host "Our JSON length: $($ourJson.Length) chars"
Write-Host ""

# ============================================================================
# FIND FIRST DIFFERENCE
# ============================================================================

Write-Host "=== COMPARISON ===" -ForegroundColor Yellow

$minLen = [Math]::Min($ourJson.Length, $rawExtJson.Length)
$firstDiff = -1
for ($i = 0; $i -lt $minLen; $i++) {
    if ($ourJson[$i] -ne $rawExtJson[$i]) {
        $firstDiff = $i
        break
    }
}

if ($firstDiff -eq -1 -and $ourJson.Length -ne $rawExtJson.Length) {
    $firstDiff = $minLen
}

if ($firstDiff -eq -1) {
    Write-Host "JSON MATCHES EXACTLY!" -ForegroundColor Green
} else {
    Write-Host "FIRST DIFFERENCE at position $firstDiff" -ForegroundColor Red
    Write-Host ""

    # Show context around difference
    $start = [Math]::Max(0, $firstDiff - 50)
    $end = [Math]::Min($firstDiff + 50, [Math]::Min($ourJson.Length, $rawExtJson.Length))

    Write-Host "Our JSON around diff:" -ForegroundColor Green
    $snippet = $ourJson.Substring($start, [Math]::Min($end - $start, $ourJson.Length - $start))
    Write-Host "  ...$snippet..."
    Write-Host "     $(' ' * ($firstDiff - $start))^" -ForegroundColor Red

    Write-Host ""
    Write-Host "Raw JSON around diff:" -ForegroundColor Green
    $snippet = $rawExtJson.Substring($start, [Math]::Min($end - $start, $rawExtJson.Length - $start))
    Write-Host "  ...$snippet..."
    Write-Host "     $(' ' * ($firstDiff - $start))^" -ForegroundColor Red

    Write-Host ""
    Write-Host "Character at diff:" -ForegroundColor Cyan
    if ($firstDiff -lt $ourJson.Length) {
        $ourChar = $ourJson[$firstDiff]
        Write-Host "  Our:  '$ourChar' (0x$([int][char]$ourChar | ForEach-Object { $_.ToString('X2') }))"
    }
    if ($firstDiff -lt $rawExtJson.Length) {
        $rawChar = $rawExtJson[$firstDiff]
        Write-Host "  Raw:  '$rawChar' (0x$([int][char]$rawChar | ForEach-Object { $_.ToString('X2') }))"
    }
}

Write-Host ""

# ============================================================================
# CALCULATE MACs
# ============================================================================

Write-Host "=== MAC CALCULATION ===" -ForegroundColor Yellow

function Get-HmacSha256 {
    param([string]$Key, [string]$Message)
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hashBytes = $hmac.ComputeHash($messageBytes)
    return ($hashBytes | ForEach-Object { $_.ToString("X2") }) -join ""
}

$seed = ""  # Empty for Comet file MACs

# Calculate MAC with our JSON
$ourMessage = $deviceId + $ExtPath + $ourJson
$ourMac = Get-HmacSha256 -Key $seed -Message $ourMessage

# Calculate MAC with raw JSON
$rawMessage = $deviceId + $ExtPath + $rawExtJson
$rawMac = Get-HmacSha256 -Key $seed -Message $rawMessage

Write-Host "Expected MAC (from file):     $expectedMac"
Write-Host "Our calculated MAC:           $ourMac"
Write-Host "MAC from raw JSON:            $rawMac"
Write-Host ""

if ($ourMac -eq $expectedMac) {
    Write-Host "Our MAC MATCHES expected!" -ForegroundColor Green
} elseif ($rawMac -eq $expectedMac) {
    Write-Host "Raw JSON MAC matches expected - our serialization differs from raw" -ForegroundColor Yellow
} else {
    Write-Host "Neither MAC matches - the stored MAC may be stale" -ForegroundColor Red
}

Write-Host ""

# ============================================================================
# ANALYZE SPECIFIC FIELDS
# ============================================================================

Write-Host "=== MANIFEST.PERMISSIONS ANALYSIS ===" -ForegroundColor Yellow

$manifest = $extValue.manifest
if ($manifest -and $manifest.permissions) {
    Write-Host "Permissions array contents:"
    for ($i = 0; $i -lt $manifest.permissions.Count; $i++) {
        $item = $manifest.permissions[$i]
        $type = if ($null -eq $item) { "null" } elseif ($item -is [PSCustomObject]) { "object" } elseif ($item -is [string]) { "string" } else { $item.GetType().Name }
        if ($type -eq "object") {
            $props = $item.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }
            Write-Host "  [$i] $type : { $($props -join ', ') }"
        } else {
            Write-Host "  [$i] $type : $item"
        }
    }
}

Write-Host ""

# Check raw JSON for permissions
Write-Host "Raw JSON permissions pattern:" -ForegroundColor Cyan
if ($rawExtJson -match '"permissions":\s*\[([^\]]+)\]') {
    $permsRaw = $Matches[1]
    # Show a truncated version
    if ($permsRaw.Length -gt 200) {
        Write-Host "  $($permsRaw.Substring(0, 200))..."
    } else {
        Write-Host "  $permsRaw"
    }
}

Write-Host ""

# ============================================================================
# DETAILED FIELD-BY-FIELD COMPARISON
# ============================================================================

Write-Host "=== FIELD-BY-FIELD COMPARISON ===" -ForegroundColor Yellow
Write-Host ""

# Parse both JSONs to compare structure
$rawParsed = $rawExtJson | ConvertFrom-Json
$ourParsed = $ourJson | ConvertFrom-Json

function Compare-Objects {
    param($Path, $Raw, $Ours)

    if ($null -eq $Raw -and $null -eq $Ours) { return }

    if ($null -eq $Raw -and $null -ne $Ours) {
        Write-Host "  EXTRA in ours: $Path" -ForegroundColor Red
        return
    }

    if ($null -ne $Raw -and $null -eq $Ours) {
        Write-Host "  MISSING in ours: $Path" -ForegroundColor Red
        if ($Raw -is [array]) {
            Write-Host "    Raw value: [$($Raw.Count) items]" -ForegroundColor Gray
        } elseif ($Raw -is [PSCustomObject]) {
            Write-Host "    Raw value: {$($Raw.PSObject.Properties.Count) props}" -ForegroundColor Gray
        } else {
            Write-Host "    Raw value: $Raw" -ForegroundColor Gray
        }
        return
    }

    if ($Raw -is [PSCustomObject] -and $Ours -is [PSCustomObject]) {
        $rawProps = @($Raw.PSObject.Properties.Name)
        $ourProps = @($Ours.PSObject.Properties.Name)

        foreach ($prop in $rawProps) {
            if ($prop -notin $ourProps) {
                Write-Host "  MISSING in ours: $Path.$prop" -ForegroundColor Red
                $val = $Raw.$prop
                if ($val -is [array]) {
                    Write-Host "    Raw value: [$($val.Count) items] $($val -join ', ')" -ForegroundColor Gray
                } elseif ($val -is [PSCustomObject]) {
                    Write-Host "    Raw value: {object}" -ForegroundColor Gray
                } else {
                    Write-Host "    Raw value: $val" -ForegroundColor Gray
                }
            } else {
                Compare-Objects -Path "$Path.$prop" -Raw $Raw.$prop -Ours $Ours.$prop
            }
        }

        foreach ($prop in $ourProps) {
            if ($prop -notin $rawProps) {
                Write-Host "  EXTRA in ours: $Path.$prop" -ForegroundColor Yellow
            }
        }
    }
    elseif ($Raw -is [array] -and $Ours -is [array]) {
        if ($Raw.Count -ne $Ours.Count) {
            Write-Host "  ARRAY SIZE DIFF: $Path (raw=$($Raw.Count), ours=$($Ours.Count))" -ForegroundColor Red
        }
    }
}

Write-Host "Comparing parsed structures..." -ForegroundColor Cyan
Compare-Objects -Path "root" -Raw $rawParsed -Ours $ourParsed

Write-Host ""

# ============================================================================
# TEST: WHAT IF WE DON'T PRUNE?
# ============================================================================

Write-Host "=== TEST: MAC WITHOUT PRUNING ===" -ForegroundColor Yellow

function ConvertTo-SortedNoPrune {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    elseif ($Value -is [array]) {
        $result = @()
        foreach ($item in $Value) {
            $result += ConvertTo-SortedNoPrune -Value $item
        }
        return ,$result
    }
    elseif ($Value -is [PSCustomObject]) {
        $sorted = [ordered]@{}
        foreach ($prop in ($Value.PSObject.Properties | Sort-Object Name)) {
            $sorted[$prop.Name] = ConvertTo-SortedNoPrune -Value $prop.Value
        }
        return $sorted
    }
    else {
        return $Value
    }
}

$sortedNoPrune = ConvertTo-SortedNoPrune -Value $extValue
$noPruneJson = ConvertTo-Json -InputObject $sortedNoPrune -Compress -Depth 20
$noPruneJson = ConvertTo-ChromiumJson -Json $noPruneJson

Write-Host "No-prune JSON length: $($noPruneJson.Length) chars"

$noPruneMessage = $deviceId + $ExtPath + $noPruneJson
$noPruneMac = Get-HmacSha256 -Key $seed -Message $noPruneMessage

Write-Host "No-prune MAC: $noPruneMac"

if ($noPruneMac -eq $expectedMac) {
    Write-Host "NO-PRUNE MAC MATCHES! Chromium does NOT prune for this extension." -ForegroundColor Green
} else {
    Write-Host "No-prune MAC doesn't match either." -ForegroundColor Gray
}

Write-Host ""
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "DONE" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
