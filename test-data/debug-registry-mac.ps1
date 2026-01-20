<#
.SYNOPSIS
    Debug registry MAC calculation for extension settings.
#>

$ErrorActionPreference = "Stop"

# Get device ID (Windows SID WITHOUT the RID)
$fullSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$deviceId = $fullSid -replace '-\d+$', ''
Write-Host "Device ID: $deviceId" -ForegroundColor Cyan
Write-Host ""

# Chromium JSON conversion
function ConvertTo-ChromiumJson {
    param([string]$Json)
    if ([string]::IsNullOrEmpty($Json)) { return $Json }
    # Step 1: Convert all lowercase unicode escapes to uppercase
    $result = [regex]::Replace($Json, '\\u([0-9a-fA-F]{4})', {
        param($match)
        "\u" + $match.Groups[1].Value.ToUpper()
    })
    # Step 2: Unescape > (Chromium doesn't escape it)
    $result = $result -replace '\\u003E', '>'
    # Step 3: Unescape single quotes (Chromium doesn't escape them)
    $result = $result -replace '\\u0027', "'"
    return $result
}

# Convert value to sorted ordered dictionary (recursively)
function ConvertTo-SortedOrderedDict {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    elseif ($Value -is [array]) {
        $result = @()
        foreach ($item in $Value) {
            $converted = ConvertTo-SortedOrderedDict -Value $item
            $result += $converted
        }
        return ,$result
    }
    elseif ($Value -is [PSCustomObject]) {
        $sorted = [ordered]@{}
        $sortedProps = $Value.PSObject.Properties | Sort-Object Name
        foreach ($prop in $sortedProps) {
            $childValue = ConvertTo-SortedOrderedDict -Value $prop.Value
            $sorted[$prop.Name] = $childValue
        }
        return $sorted
    }
    else {
        return $Value
    }
}

# Calculate MAC
function Calculate-MAC {
    param(
        [string]$Seed,
        [string]$Path,
        [string]$ValueJson
    )
    $message = $deviceId + $Path + $ValueJson
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hashBytes = $hmac.ComputeHash($messageBytes)
    return ($hashBytes | ForEach-Object { $_.ToString("X2") }) -join ""
}

# Pick one failing extension to debug
$extensionId = "mhjfbmdgcfjbbpaeojofohoefgiehjai"  # PDF Viewer
$path = "extensions.settings.$extensionId"

Write-Host "=== Debugging Registry MAC for PDF Viewer ===" -ForegroundColor Yellow
Write-Host "Extension ID: $extensionId"
Write-Host "Path: $path"
Write-Host ""

# Read from Secure Preferences
$meteorPath = Join-Path (Split-Path $PSScriptRoot -Parent) ".meteor"
$securePrefsFile = Join-Path $meteorPath "User Data\Default\Secure Preferences"
$rawJson = Get-Content $securePrefsFile -Raw
$prefs = $rawJson | ConvertFrom-Json

# Get extension value
$extValue = $prefs.extensions.settings.$extensionId

# Get expected MACs
$fileMac = $prefs.protection.macs.extensions.settings.$extensionId
$regPath = "HKCU:\Software\Perplexity\Comet\PreferenceMACs\Default"
$regMac = (Get-ItemProperty -Path $regPath -Name $path -ErrorAction SilentlyContinue).$path

Write-Host "Expected File MAC:     $fileMac"
Write-Host "Expected Registry MAC: $regMac"
Write-Host ""

# Convert value to sorted JSON
$sorted = ConvertTo-SortedOrderedDict -Value $extValue
$valueJson = ConvertTo-Json -InputObject $sorted -Compress -Depth 50
$valueJson = ConvertTo-ChromiumJson -Json $valueJson

Write-Host "Value JSON (first 200 chars):"
Write-Host "  $($valueJson.Substring(0, [Math]::Min(200, $valueJson.Length)))..."
Write-Host "Value JSON length: $($valueJson.Length)"
Write-Host ""

# Calculate MACs with both seeds
$fileSeed = ""
$registrySeed = "ChromeRegistryHashStoreValidationSeed"

$calcFileMac = Calculate-MAC -Seed $fileSeed -Path $path -ValueJson $valueJson
$calcRegMac = Calculate-MAC -Seed $registrySeed -Path $path -ValueJson $valueJson

Write-Host "=== FILE MAC ===" -ForegroundColor Cyan
Write-Host "  Expected:   $fileMac"
Write-Host "  Calculated: $calcFileMac"
if ($fileMac -eq $calcFileMac) {
    Write-Host "  MATCH!" -ForegroundColor Green
} else {
    Write-Host "  MISMATCH!" -ForegroundColor Red
}
Write-Host ""

Write-Host "=== REGISTRY MAC ===" -ForegroundColor Cyan
Write-Host "  Expected:   $regMac"
Write-Host "  Calculated: $calcRegMac"
if ($regMac -eq $calcRegMac) {
    Write-Host "  MATCH!" -ForegroundColor Green
} else {
    Write-Host "  MISMATCH!" -ForegroundColor Red
}
Write-Host ""

# Try calculating with file seed but registry expected
Write-Host "=== CROSS-CHECK ===" -ForegroundColor Yellow
Write-Host "File seed calculates to:     $calcFileMac"
Write-Host "Registry seed calculates to: $calcRegMac"
Write-Host ""

# Could the registry MAC have been calculated with an empty seed?
if ($regMac -eq $calcFileMac) {
    Write-Host "INTERESTING: Registry MAC matches calculation with EMPTY seed!" -ForegroundColor Magenta
}

# Let's also check if the registry stores its own copy of the value
Write-Host "=== REGISTRY VALUE CHECK ===" -ForegroundColor Yellow
$regValuePath = "HKCU:\Software\Perplexity\Comet"
Write-Host "Checking if registry stores extension values separately..."

# List all registry keys under Comet
$cometRegPath = "HKCU:\Software\Perplexity\Comet"
if (Test-Path $cometRegPath) {
    $subkeys = Get-ChildItem -Path $cometRegPath -ErrorAction SilentlyContinue
    Write-Host "Registry subkeys under Comet:"
    foreach ($key in $subkeys) {
        Write-Host "  - $($key.PSChildName)"
    }
}
Write-Host ""

# Check what's actually stored in the PreferenceMACs key
$macsPath = "HKCU:\Software\Perplexity\Comet\PreferenceMACs\Default"
if (Test-Path $macsPath) {
    $allMacs = Get-ItemProperty -Path $macsPath
    $extMacProps = $allMacs.PSObject.Properties | Where-Object { $_.Name -like "extensions.settings.*" }
    Write-Host "Extension MACs in registry: $($extMacProps.Count)"

    # Show a few examples
    Write-Host ""
    Write-Host "Sample registry MACs (first 3):"
    $extMacProps | Select-Object -First 3 | ForEach-Object {
        Write-Host "  $($_.Name) = $($_.Value)"
    }
}

Write-Host ""
Write-Host "=== HYPOTHESIS ===" -ForegroundColor Magenta
Write-Host "The registry MACs might have been calculated from DIFFERENT data."
Write-Host "Possibilities:"
Write-Host "  1. Registry MACs were written at install time, file MACs updated later"
Write-Host "  2. Registry and file MACs are calculated from different sources"
Write-Host "  3. Some field ordering difference between registry and file calculation"
Write-Host ""

# Let's check if there's a pattern - do ANY extension registry MACs pass?
Write-Host "=== CHECKING ALL EXTENSION REGISTRY MACs ===" -ForegroundColor Yellow
$allRegMacs = Get-ItemProperty -Path $macsPath
$extIds = @(
    "ahfgeienlihckogmohjhadlkjgocpleb",
    "cjpalhdlnbpafiamejdnhcphjbkeiagm",
    "gkeojjjcdcopjkbelgbcpckplegclfeg",
    "mcjlamohcooanphmebaiigheeeoplihb",
    "mhjfbmdgcfjbbpaeojofohoefgiehjai",
    "mjdcklhepheaaemphcopihnmjlmjpcnh",
    "npclhjbddhklpbnacpjloidibaggcgon"
)

foreach ($extId in $extIds) {
    $extPath = "extensions.settings.$extId"
    $extVal = $prefs.extensions.settings.$extId
    $extSorted = ConvertTo-SortedOrderedDict -Value $extVal
    $extJson = ConvertTo-Json -InputObject $extSorted -Compress -Depth 50
    $extJson = ConvertTo-ChromiumJson -Json $extJson

    $expectedRegMac = $allRegMacs.$extPath
    $calcRegMac = Calculate-MAC -Seed $registrySeed -Path $extPath -ValueJson $extJson

    $status = if ($expectedRegMac -eq $calcRegMac) { "[PASS]" } else { "[FAIL]" }
    $color = if ($expectedRegMac -eq $calcRegMac) { "Green" } else { "Red" }

    Write-Host "$status $extId" -ForegroundColor $color
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
