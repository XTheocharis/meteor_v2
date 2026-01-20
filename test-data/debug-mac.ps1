<#
.SYNOPSIS
    Debug MAC calculation by showing exact inputs for a simple preference.
#>

$ErrorActionPreference = "Stop"

# Get device ID
$deviceId = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Write-Host "Device ID: $deviceId"
Write-Host "Device ID Length: $($deviceId.Length)"
Write-Host "Device ID Bytes: $([System.Text.Encoding]::UTF8.GetBytes($deviceId) -join ',')"
Write-Host ""

# Test with a simple boolean preference
$path = "browser.show_home_button"
$valueJson = "true"
$seed = ""  # Empty for Comet file MACs

Write-Host "=== Simple Boolean Test ===" -ForegroundColor Cyan
Write-Host "Path: $path"
Write-Host "Value JSON: $valueJson"
Write-Host "Seed: '$seed' (empty)"
Write-Host ""

# Build message
$message = $deviceId + $path + $valueJson
Write-Host "Message: $message"
Write-Host "Message Length: $($message.Length)"
Write-Host ""

# Calculate MAC
$keyBytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
$messageBytes = [System.Text.Encoding]::UTF8.GetBytes($message)

$hmac = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = $keyBytes
$hashBytes = $hmac.ComputeHash($messageBytes)
$calculatedMac = ($hashBytes | ForEach-Object { $_.ToString("X2") }) -join ""

Write-Host "Calculated MAC: $calculatedMac"
Write-Host ""

# Read actual MAC from file
$meteorPath = Join-Path (Split-Path $PSScriptRoot -Parent) ".meteor"
$securePrefsFile = Join-Path $meteorPath "User Data\Default\Secure Preferences"

if (Test-Path $securePrefsFile) {
    $prefs = Get-Content $securePrefsFile -Raw | ConvertFrom-Json
    $actualMac = $prefs.protection.macs.browser.show_home_button
    Write-Host "Actual MAC from file: $actualMac"
    Write-Host ""

    if ($calculatedMac -eq $actualMac) {
        Write-Host "MATCH!" -ForegroundColor Green
    } else {
        Write-Host "MISMATCH!" -ForegroundColor Red

        # Try with registry seed to see if that's the issue
        Write-Host ""
        Write-Host "=== Trying with Registry Seed ===" -ForegroundColor Yellow
        $regSeed = "ChromeRegistryHashStoreValidationSeed"
        $keyBytes2 = [System.Text.Encoding]::UTF8.GetBytes($regSeed)
        $hmac2 = New-Object System.Security.Cryptography.HMACSHA256
        $hmac2.Key = $keyBytes2
        $hashBytes2 = $hmac2.ComputeHash($messageBytes)
        $calculatedMac2 = ($hashBytes2 | ForEach-Object { $_.ToString("X2") }) -join ""
        Write-Host "Calculated with registry seed: $calculatedMac2"

        if ($calculatedMac2 -eq $actualMac) {
            Write-Host "MATCH with registry seed! (File uses registry seed, not empty)" -ForegroundColor Green
        }
    }
}

# Also check what the actual value is in Secure Preferences
Write-Host ""
Write-Host "=== Actual Value in Secure Preferences ===" -ForegroundColor Cyan
if ($prefs.browser.show_home_button -ne $null) {
    $actualValue = $prefs.browser.show_home_button
    Write-Host "Value: $actualValue"
    Write-Host "Type: $($actualValue.GetType().Name)"
} else {
    Write-Host "Value is null/missing"
}

# Test pinned_tabs (empty array)
Write-Host ""
Write-Host "=== Empty Array Test (pinned_tabs) ===" -ForegroundColor Cyan
$path2 = "pinned_tabs"
$valueJson2 = "[]"

$message2 = $deviceId + $path2 + $valueJson2
Write-Host "Path: $path2"
Write-Host "Value JSON: $valueJson2"
Write-Host "Message: $message2"

$messageBytes2 = [System.Text.Encoding]::UTF8.GetBytes($message2)
$hmac.Key = [System.Text.Encoding]::UTF8.GetBytes("")
$hashBytes2 = $hmac.ComputeHash($messageBytes2)
$calculatedMac2 = ($hashBytes2 | ForEach-Object { $_.ToString("X2") }) -join ""

Write-Host "Calculated MAC: $calculatedMac2"
$actualMac2 = $prefs.protection.macs.pinned_tabs
Write-Host "Actual MAC: $actualMac2"

if ($calculatedMac2 -eq $actualMac2) {
    Write-Host "MATCH!" -ForegroundColor Green
} else {
    Write-Host "MISMATCH!" -ForegroundColor Red
}

# Check super_mac to understand the seed
Write-Host ""
Write-Host "=== Super MAC Info ===" -ForegroundColor Cyan
if ($prefs.protection.super_mac) {
    Write-Host "Super MAC exists: $($prefs.protection.super_mac)"
} else {
    Write-Host "No super_mac found"
}

# Check macs_without_sync_value (this might indicate different MAC mechanism)
if ($prefs.protection.macs_without_sync_value) {
    Write-Host "macs_without_sync_value exists"
}
