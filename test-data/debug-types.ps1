<#
.SYNOPSIS
    Debug script to see what types PowerShell produces for JSON parsing.
#>

$ErrorActionPreference = "Stop"

Write-Host "=== PowerShell Version ===" -ForegroundColor Cyan
Write-Host "Version: $($PSVersionTable.PSVersion)"
Write-Host ""

# Test 1: Empty array in JSON
Write-Host "=== Test 1: Empty array [] ===" -ForegroundColor Yellow
$json1 = '{"api":[]}'
$parsed1 = $json1 | ConvertFrom-Json
$apiValue = $parsed1.api
Write-Host "Input JSON: $json1"
Write-Host "Parsed api value: $apiValue"
Write-Host "Type: $($apiValue.GetType().FullName)"
Write-Host "Is null: $($null -eq $apiValue)"
Write-Host "Is array: $($apiValue -is [array])"
Write-Host "Is PSCustomObject: $($apiValue -is [PSCustomObject])"
if ($apiValue -is [array]) {
    Write-Host "Array count: $($apiValue.Count)"
}
if ($apiValue -is [PSCustomObject]) {
    Write-Host "PSObject properties count: $($apiValue.PSObject.Properties.Count)"
}
Write-Host ""

# Test 2: Empty object in JSON
Write-Host "=== Test 2: Empty object {} ===" -ForegroundColor Yellow
$json2 = '{"api":{}}'
$parsed2 = $json2 | ConvertFrom-Json
$apiValue2 = $parsed2.api
Write-Host "Input JSON: $json2"
Write-Host "Parsed api value: $apiValue2"
Write-Host "Type: $($apiValue2.GetType().FullName)"
Write-Host "Is null: $($null -eq $apiValue2)"
Write-Host "Is PSCustomObject: $($apiValue2 -is [PSCustomObject])"
if ($apiValue2 -is [PSCustomObject]) {
    Write-Host "PSObject properties count: $($apiValue2.PSObject.Properties.Count)"
}
Write-Host ""

# Test 3: OrderedDictionary serialization
Write-Host "=== Test 3: Empty OrderedDictionary serialization ===" -ForegroundColor Yellow
$ordered = [ordered]@{}
Write-Host "Type: $($ordered.GetType().FullName)"
Write-Host "Count: $($ordered.Count)"
Write-Host "Is OrderedDictionary: $($ordered -is [System.Collections.Specialized.OrderedDictionary])"
$serialized = $ordered | ConvertTo-Json -Compress
Write-Host "Serialized: $serialized"
Write-Host ""

# Test 4: Nested with empty
Write-Host "=== Test 4: Nested structure with empties ===" -ForegroundColor Yellow
$json4 = '{"outer":{"api":[],"host":[],"keep":"value"}}'
$parsed4 = $json4 | ConvertFrom-Json
Write-Host "Input JSON: $json4"
Write-Host "outer type: $($parsed4.outer.GetType().FullName)"
Write-Host "outer.api type: $(if ($null -eq $parsed4.outer.api) { 'NULL' } else { $parsed4.outer.api.GetType().FullName })"
Write-Host "outer.api is null: $($null -eq $parsed4.outer.api)"
Write-Host "outer.host type: $(if ($null -eq $parsed4.outer.host) { 'NULL' } else { $parsed4.outer.host.GetType().FullName })"
Write-Host ""

# Test 5: Check what happens when we put null in OrderedDictionary
Write-Host "=== Test 5: Null in OrderedDictionary ===" -ForegroundColor Yellow
$dict = [ordered]@{api=$null; keep="value"}
Write-Host "Dict with null: $($dict | ConvertTo-Json -Compress)"
Write-Host ""

# Test 6: Check secure-preferences.json specific extension
Write-Host "=== Test 6: Actual test data ===" -ForegroundColor Yellow
$testFile = Join-Path $PSScriptRoot "secure-preferences.json"
if (Test-Path $testFile) {
    $prefs = Get-Content $testFile -Raw | ConvertFrom-Json
    $ext = $prefs.extensions.settings.gkeojjjcdcopjkbelgbcpckplegclfeg
    if ($ext) {
        $ap = $ext.active_permissions
        Write-Host "active_permissions type: $($ap.GetType().FullName)"
        Write-Host "active_permissions.api:"
        Write-Host "  Value: $($ap.api)"
        Write-Host "  Is null: $($null -eq $ap.api)"
        if ($null -ne $ap.api) {
            Write-Host "  Type: $($ap.api.GetType().FullName)"
            Write-Host "  Is array: $($ap.api -is [array])"
            Write-Host "  Is PSCustomObject: $($ap.api -is [PSCustomObject])"
            if ($ap.api -is [array]) {
                Write-Host "  Array count: $($ap.api.Count)"
            }
            if ($ap.api -is [PSCustomObject]) {
                Write-Host "  PSObject properties: $($ap.api.PSObject.Properties.Count)"
            }
        }
    }
} else {
    Write-Host "Test file not found: $testFile"
}
Write-Host ""

Write-Host "=== Done ===" -ForegroundColor Cyan
