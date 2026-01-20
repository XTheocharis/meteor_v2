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

# Test 7: Array unrolling issue
Write-Host "=== Test 7: Array unrolling in functions ===" -ForegroundColor Yellow
function ReturnEmptyArray { return @() }
function ReturnEmptyArrayWithComma { return ,@() }
$result1 = ReturnEmptyArray
$result2 = ReturnEmptyArrayWithComma
Write-Host "ReturnEmptyArray result:"
Write-Host "  Is null: $($null -eq $result1)"
Write-Host "  Type: $(if ($null -eq $result1) { 'NULL' } else { $result1.GetType().FullName })"
Write-Host "ReturnEmptyArrayWithComma result:"
Write-Host "  Is null: $($null -eq $result2)"
Write-Host "  Type: $(if ($null -eq $result2) { 'NULL' } else { $result2.GetType().FullName })"
Write-Host "  Is array: $($result2 -is [array])"
Write-Host "  Count: $(if ($result2 -is [array]) { $result2.Count } else { 'N/A' })"
Write-Host ""

# Test 8: What does null become when put in OrderedDictionary and serialized?
Write-Host "=== Test 8: Null vs empty in serialization ===" -ForegroundColor Yellow
$dict1 = [ordered]@{api=$null}
$dict2 = [ordered]@{}  # No api key at all
$dict3 = [ordered]@{api=@()}  # Empty array
Write-Host "With null value: $($dict1 | ConvertTo-Json -Compress)"
Write-Host "Without key:     $($dict2 | ConvertTo-Json -Compress)"
Write-Host "With empty array: $($dict3 | ConvertTo-Json -Compress)"
Write-Host ""

# Test 9: Analyze the failing PDF Viewer extension
Write-Host "=== Test 9: PDF Viewer extension deep dive ===" -ForegroundColor Yellow
$testFile = Join-Path $PSScriptRoot "secure-preferences.json"
$rawJson = Get-Content $testFile -Raw
if (Test-Path $testFile) {
    $prefs = Get-Content $testFile -Raw | ConvertFrom-Json
    $pdfExt = $prefs.extensions.settings.mhjfbmdgcfjbbpaeojofohoefgiehjai
    if ($pdfExt) {
        Write-Host "PDF Viewer manifest.mime_types:"
        $mt = $pdfExt.manifest.mime_types
        Write-Host "  Value: $mt"
        Write-Host "  Is null: $($null -eq $mt)"
        if ($null -ne $mt) {
            Write-Host "  Type: $($mt.GetType().FullName)"
            Write-Host "  Is array: $($mt -is [array])"
            Write-Host "  Is string: $($mt -is [string])"
        }

        Write-Host ""
        Write-Host "PDF Viewer manifest.web_accessible_resources:"
        $war = $pdfExt.manifest.web_accessible_resources
        Write-Host "  Value: $war"
        Write-Host "  Is null: $($null -eq $war)"
        if ($null -ne $war) {
            Write-Host "  Type: $($war.GetType().FullName)"
            Write-Host "  Is array: $($war -is [array])"
            Write-Host "  Is string: $($war -is [string])"
        }

        Write-Host ""
        Write-Host "PDF Viewer manifest.permissions (check for nested objects):"
        $perms = $pdfExt.manifest.permissions
        if ($perms -is [array]) {
            Write-Host "  Is array with $($perms.Count) items"
            for ($i = 0; $i -lt $perms.Count; $i++) {
                $item = $perms[$i]
                $type = if ($null -eq $item) { "null" } else { $item.GetType().Name }
                Write-Host "  [$i]: $type = $item"
            }
        }

        # Check raw JSON for these fields
        Write-Host ""
        Write-Host "Raw JSON patterns:"
        if ($rawJson -match '"mime_types"\s*:\s*"([^"]*)"') {
            Write-Host "  mime_types is STRING in raw: $($Matches[1])"
        } elseif ($rawJson -match '"mime_types"\s*:\s*\[') {
            Write-Host "  mime_types is ARRAY in raw"
        }
        if ($rawJson -match '"web_accessible_resources"\s*:\s*"([^"]*)"') {
            Write-Host "  web_accessible_resources is STRING in raw: $($Matches[1])"
        } elseif ($rawJson -match '"web_accessible_resources"\s*:\s*\[') {
            Write-Host "  web_accessible_resources is ARRAY in raw"
        }

        # Check fileSystem specifically
        Write-Host ""
        Write-Host "fileSystem in permissions:"
        if ($rawJson -match '\{"fileSystem"\s*:\s*"([^"]*)"\}') {
            Write-Host "  fileSystem is STRING in raw: $($Matches[1])"
        } elseif ($rawJson -match '\{"fileSystem"\s*:\s*\[([^\]]*)\]\}') {
            Write-Host "  fileSystem is ARRAY in raw: [$($Matches[1])]"
        }

        # Show what we serialize it as
        $fsObj = $perms | Where-Object { $_ -is [PSCustomObject] } | Select-Object -First 1
        if ($fsObj) {
            $fsValue = $fsObj.fileSystem
            Write-Host "  fileSystem parsed as: $($fsValue.GetType().Name)"
            if ($fsValue -is [array]) {
                Write-Host "  fileSystem array contents: $($fsValue -join ', ')"
            } else {
                Write-Host "  fileSystem value: $fsValue"
            }
        }
    }
}
Write-Host ""

Write-Host "=== Done ===" -ForegroundColor Cyan
