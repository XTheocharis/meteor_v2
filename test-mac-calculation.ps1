<#
.SYNOPSIS
    Standalone MAC calculation test script with verified real data.

.DESCRIPTION
    Uses actual browser-generated MACs and preference values to verify
    the correct HMAC calculation formula.

    Formula: HMAC-SHA256(key=seed, message=device_id + path + value_json)

    Value serialization rules:
    - Boolean true  -> "true"
    - Boolean false -> "false"
    - Empty array   -> "[]"
    - Null value    -> "" (empty string, NOT "null")

.NOTES
    Device ID (SID): S-1-5-21-2625391329-1236784108-3013698973
    File MAC Seed: Empty string (Comet/non-Chrome branded)
    Registry MAC Seed: "ChromeRegistryHashStoreValidationSeed"
#>

# ============================================================================
# VERIFIED DATA FROM BROWSER
# ============================================================================

$DeviceId = "S-1-5-21-2625391329-1236784108-3013698973"
$FileSeed = ""  # Empty for non-Chrome branded builds
$RegistrySeed = "ChromeRegistryHashStoreValidationSeed"

# Browser-generated MACs from Secure Preferences (protection.macs)
$BrowserFileMACs = @{
    # Simple boolean values
    "browser.show_home_button" = "7B86BD72BA7066A761584E2647874671EE93016ABAA16B3033279B856FEB4384"
    "extensions.ui.developer_mode" = "A6D1BB9C77B2F2DB333D7E67EF15B52AF14AC101038F6369DF529D4517FAB7B7"

    # Empty array (NOT null!)
    "pinned_tabs" = "E3EAF21E0C6A7D238AA915D30B5BE474BBE2177B43B9702AFB951A0B47C518DF"

    # Null values (preferences that don't exist)
    "homepage" = "4FB2A1B2E05D3545D1150B3B5BD7E7ECB0634780757C6EAE06C0CD92543B5979"
    "homepage_is_newtabpage" = "815CB85DAD7A8A7720650D033E82DA8029870332CE34AE3CAA11B1EE21FCD239"
    "session.restore_on_startup" = "8CFF98B25F87D7E5B516ECFD2079A476453287AFE75400826AEA00B793747DFC"
    "session.startup_urls" = "E2D68A7561B4E8E6CAD3CE9D455EDD44EAC3DCABE9A6EB008D381BF46EE8820D"
    "schedule_to_flush_to_disk" = "042A4537D3E6667F7EF61BC0590EEF8D92B5EB1ABB56D151A4CF242DB61D48F6"
    "search_provider_overrides" = "CAD9C2EF10C01A092D532E6765A51773F04A6A58DD074C1994AD838CB121A39C"
    "default_search_provider_data.template_url_data" = "48149FA5C304A2BD2A4AFC3924F1AC0B6CAAE2BAFA85A72F322F79546C85F363"

    # account_values paths - these also use null (empty string) since not signed in
    "account_values.browser.show_home_button" = "1520F0B72EAE8FD10E4172DF40C195633987B33032256741329CFC1EC3AA9E6D"
    "account_values.extensions.ui.developer_mode" = "560FDF90337F6A28E361DC5FEB1FB133201758A8031B399876E4EDAEDCDEE9BF"
    "account_values.homepage" = "D029612CB48C7844E473B3BF40098DAFBF525DAB911B4860E6B7E72B0AA90405"
    "account_values.homepage_is_newtabpage" = "DA418FA8ED1E29E5F48D58670AFA05DF86AC25DF69A93ADD867EFF673B1A15FA"
    "account_values.session.restore_on_startup" = "8731D670CE55134C07B884F584B6E4773A2A89F4665DE598954034252081D3B5"
    "account_values.session.startup_urls" = "9F8D26D3588F9EF960A74E053731D98B32C13EAB7906E775192627A629F3792B"
}

# Browser-generated MACs from Registry
$BrowserRegistryMACs = @{
    "browser.show_home_button" = "22D1086A8FD1B8A1AC662363188FD1DFBF0CEEEAB3B18EAC4C0D05E9C82FCEA1"
    "extensions.ui.developer_mode" = "2D3D23D6B928A21CD71AEA31DD8F402C7303A5A60EF846D606F019A62DA5359C"
    "pinned_tabs" = "91135E93C043C82412663EAC80FF3475A056DD5B4DD2F2F95F13263DE253328A"
    "homepage" = "E37FA038B133D163329C02076DF54AAB071347A07C4E2502524E86C2BDB0B7A1"
    "homepage_is_newtabpage" = "81A29BEA921245A120EB5CFF47ECE0142149FA14070877A30212FBEA801765F4"
    "session.restore_on_startup" = "733EAA1C4F7A9532CA9A3F7C0967ACEA983233898681ABD109155C3C7C7B828F"
    "session.startup_urls" = "F95C190137B535064F7E78CB3F740DBB803C0F464224B04D50D5F37C8E46F2A0"
    "schedule_to_flush_to_disk" = "43D343222761C47F39B58D22E672BB5BFABA8F1D4FCE8CDB1EDD6AEFA670BAB5"
    "search_provider_overrides" = "7E301F0C5D0291B4022B8D6FB7BAF6C369ACE415632992D76AC75331B879008E"
    "default_search_provider_data.template_url_data" = "52B45A9DDADF5B611BE33662B9EB7D142797828A208CE47F39B946A37D4DC7BC"
    "account_values.browser.show_home_button" = "ABB75636342D33AEE9C5265415B4D40E5353909B89420690F3E20685DED3C839"
    "account_values.extensions.ui.developer_mode" = "3360389830108F1F2BE0632B27A506CB89193CD8E412EAF361F46813AA95F95B"
    "account_values.homepage" = "04D4DE65217D07BBEE27B5F4923A482B84EC3BBA301E822B6CE548070FF9390E"
    "account_values.homepage_is_newtabpage" = "3B744F8E9F350E91A8E17B2A0B742C44ADE317EB052B0EA983B82BDA421C2165"
    "account_values.session.restore_on_startup" = "7EE48574F185879B045130ECB4283B98B2D8E11CEACF8F67AE46D64CFF078E84"
    "account_values.session.startup_urls" = "0711756C84C58DEC515C6ED15FA9FAFF9F2C787A4B818D5ACF20B9E285D14517"
}

# Actual values from Secure Preferences JSON
$ActualValues = @{
    "browser.show_home_button" = $true
    "extensions.ui.developer_mode" = $true
    "pinned_tabs" = @()  # Empty array, NOT null!
    "homepage" = $null
    "homepage_is_newtabpage" = $null
    "session.restore_on_startup" = $null
    "session.startup_urls" = $null
    "schedule_to_flush_to_disk" = $null
    "search_provider_overrides" = $null
    "default_search_provider_data.template_url_data" = $null

    # account_values paths - all null since not signed in
    "account_values.browser.show_home_button" = $null
    "account_values.extensions.ui.developer_mode" = $null
    "account_values.homepage" = $null
    "account_values.homepage_is_newtabpage" = $null
    "account_values.session.restore_on_startup" = $null
    "account_values.session.startup_urls" = $null
}

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

function ConvertTo-JsonValue {
    <#
    .SYNOPSIS
        Serialize value to JSON string for HMAC calculation.
    .DESCRIPTION
        Chromium's serialization rules:
        - Null:     "" (empty string, NOT "null")
        - Boolean:  "true" or "false" (lowercase)
        - Array:    "[]" or JSON representation
        - String:   JSON-quoted
        - Number:   String representation
    #>
    param($Value)

    if ($null -eq $Value) {
        return ""  # CRITICAL: Chromium uses empty string for null, not "null"
    }
    elseif ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }
    elseif ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return "[]"
        }
        return ($Value | ConvertTo-Json -Compress -Depth 10)
    }
    elseif ($Value -is [string]) {
        return "`"$Value`""
    }
    elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return $Value.ToString()
    }
    else {
        return ($Value | ConvertTo-Json -Compress -Depth 10)
    }
}

function Calculate-Mac {
    <#
    .SYNOPSIS
        Calculate MAC using the verified formula.
    .DESCRIPTION
        Formula: HMAC-SHA256(key=seed, message=device_id + path + value_json)
    #>
    param(
        [string]$Seed,
        [string]$DeviceId,
        [string]$Path,
        $Value
    )

    $valueJson = ConvertTo-JsonValue $Value
    $message = $DeviceId + $Path + $valueJson
    return Get-HmacSha256 -Key $Seed -Message $message
}

# ============================================================================
# RUN VERIFICATION
# ============================================================================

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "MAC CALCULATION VERIFICATION" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""
Write-Host "Formula: HMAC-SHA256(key=seed, message=device_id + path + value_json)"
Write-Host ""
Write-Host "Device ID: $DeviceId"
Write-Host "File Seed: '$FileSeed' (empty)"
Write-Host "Registry Seed: '$RegistrySeed'"
Write-Host ""

$totalTests = 0
$passedTests = 0

# ============================================================================
# TEST FILE MACs
# ============================================================================

Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host "FILE MACs (seed = empty string)" -ForegroundColor Yellow
Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host ""

foreach ($path in $BrowserFileMACs.Keys | Sort-Object) {
    $expectedMac = $BrowserFileMACs[$path]
    $value = $ActualValues[$path]
    $valueJson = ConvertTo-JsonValue $value
    $calculatedMac = Calculate-Mac -Seed $FileSeed -DeviceId $DeviceId -Path $path -Value $value

    $totalTests++
    $match = $calculatedMac -eq $expectedMac

    if ($match) {
        $passedTests++
        $status = "[PASS]"
        $color = "Green"
    } else {
        $status = "[FAIL]"
        $color = "Red"
    }

    Write-Host "$status $path" -ForegroundColor $color
    Write-Host "       Value: $valueJson"
    if (-not $match) {
        Write-Host "       Expected:   $expectedMac" -ForegroundColor DarkGray
        Write-Host "       Calculated: $calculatedMac" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ============================================================================
# TEST REGISTRY MACs
# ============================================================================

Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host "REGISTRY MACs (seed = 'ChromeRegistryHashStoreValidationSeed')" -ForegroundColor Yellow
Write-Host "=" * 80 -ForegroundColor Yellow
Write-Host ""

foreach ($path in $BrowserRegistryMACs.Keys | Sort-Object) {
    $expectedMac = $BrowserRegistryMACs[$path]
    $value = $ActualValues[$path]
    $valueJson = ConvertTo-JsonValue $value
    $calculatedMac = Calculate-Mac -Seed $RegistrySeed -DeviceId $DeviceId -Path $path -Value $value

    $totalTests++
    $match = $calculatedMac -eq $expectedMac

    if ($match) {
        $passedTests++
        $status = "[PASS]"
        $color = "Green"
    } else {
        $status = "[FAIL]"
        $color = "Red"
    }

    Write-Host "$status $path" -ForegroundColor $color
    Write-Host "       Value: $valueJson"
    if (-not $match) {
        Write-Host "       Expected:   $expectedMac" -ForegroundColor DarkGray
        Write-Host "       Calculated: $calculatedMac" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 80 -ForegroundColor Cyan
Write-Host ""

$failedTests = $totalTests - $passedTests

if ($failedTests -eq 0) {
    Write-Host "ALL TESTS PASSED: $passedTests/$totalTests" -ForegroundColor Green
} else {
    Write-Host "PASSED: $passedTests/$totalTests" -ForegroundColor Yellow
    Write-Host "FAILED: $failedTests/$totalTests" -ForegroundColor Red
}

Write-Host ""
Write-Host "Key findings:" -ForegroundColor White
Write-Host "  - Formula: HMAC-SHA256(key=seed, message=device_id + path + value_json)"
Write-Host "  - Null values serialize to empty string '', not 'null'"
Write-Host "  - Boolean values serialize to lowercase 'true'/'false'"
Write-Host "  - Empty arrays serialize to '[]'"
Write-Host ""
