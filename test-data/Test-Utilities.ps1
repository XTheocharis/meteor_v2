<#
.SYNOPSIS
    Shared utility functions for MAC calculation test scripts.

.DESCRIPTION
    This module provides common functions used by multiple debug and test scripts
    in the test-data directory for verifying MAC (Message Authentication Code)
    calculations used by Chromium's Secure Preferences system.

    Functions included:
    - Get-WindowsSidWithoutRid: Gets the Windows SID without the RID component
    - Get-HmacSha256: Calculates HMAC-SHA256 hash
    - ConvertTo-SortedAndPruned: Recursively sorts keys and prunes empty containers
    - ConvertTo-ChromiumJson: Normalizes JSON to match Chromium's format
    - ConvertTo-JsonForHmac: Serializes values for MAC calculation
    - Get-PreferenceHmac: Calculates file MAC (empty seed)
    - Get-RegistryPreferenceHmac: Calculates registry MAC (literal seed)
    - Get-PrefValue: Navigates a dotted path to get a value

.NOTES
    Dot-source this file at the beginning of debug scripts:
    . "$PSScriptRoot\Test-Utilities.ps1"
#>

# ============================================================================
# CONSTANTS
# ============================================================================

# MAC seeds - empty for Comet (non-Chrome branded), standard seed for registry
$script:FileMacSeed = ""  # Comet uses empty string
$script:RegistryMacSeed = "ChromeRegistryHashStoreValidationSeed"

# ============================================================================
# DEVICE ID
# ============================================================================

function Get-WindowsSidWithoutRid {
    <#
    .SYNOPSIS
        Get the Windows machine SID without the RID (Relative ID) component.

    .DESCRIPTION
        Chromium uses the SID without the final RID component as the device ID
        for MAC calculations.

        Example: S-1-5-21-123456789-987654321-555555555-1001
              -> S-1-5-21-123456789-987654321-555555555

    .OUTPUTS
        [string] The Windows SID without the RID suffix.

    .EXAMPLE
        $deviceId = Get-WindowsSidWithoutRid
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $fullSid = $currentUser.User.Value
        # Remove the RID (last component after final dash)
        $sidWithoutRid = $fullSid -replace '-\d+$', ''
        return $sidWithoutRid
    }
    catch {
        throw "Failed to get Windows SID: $_"
    }
}

# ============================================================================
# HMAC CALCULATION
# ============================================================================

function Get-HmacSha256 {
    <#
    .SYNOPSIS
        Calculate HMAC-SHA256 hash.

    .DESCRIPTION
        Computes the HMAC-SHA256 hash of a message using the specified key.
        Returns the hash as an uppercase hexadecimal string.

    .PARAMETER Key
        The HMAC key as a string (will be UTF-8 encoded).

    .PARAMETER Message
        The message to hash as a string (will be UTF-8 encoded).

    .OUTPUTS
        [string] The HMAC-SHA256 hash as an uppercase hex string.

    .EXAMPLE
        Get-HmacSha256 -Key "" -Message "S-1-5-21-123browser.show_home_buttontrue"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($Message)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $hashBytes = $hmac.ComputeHash($messageBytes)

    return ($hashBytes | ForEach-Object { $_.ToString("X2") }) -join ""
}

# ============================================================================
# JSON UTILITIES
# ============================================================================

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

    .PARAMETER Value
        The value to process (can be any type).

    .OUTPUTS
        The processed value with sorted keys and pruned empties.

    .EXAMPLE
        $sorted = ConvertTo-SortedAndPruned -Value $myObject
    #>
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    elseif ($Value -is [array]) {
        # Process array items AND prune empty dicts/arrays from the list
        $result = @()
        foreach ($item in $Value) {
            $childValue = ConvertTo-SortedAndPruned -Value $item
            # PRUNE: Skip empty arrays and empty dicts/ordered dicts from list items
            if ($childValue -is [array] -and $childValue.Count -eq 0) {
                continue
            }
            if ($childValue -is [hashtable] -and $childValue.Count -eq 0) {
                continue
            }
            if ($childValue -is [System.Collections.Specialized.OrderedDictionary] -and $childValue.Count -eq 0) {
                continue
            }
            $result += $childValue
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
        - PowerShell: \u003c (lowercase), \u003e (escaped >), \u0027 (escaped ')
        - Chromium:   \u003C (uppercase), > (not escaped), ' (not escaped)

        This function normalizes the JSON string to match Chromium's format.

    .PARAMETER Json
        The JSON string to normalize.

    .OUTPUTS
        [string] The normalized JSON string.

    .EXAMPLE
        $chromiumJson = ConvertTo-ChromiumJson -Json $powershellJson
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Json
    )

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

    # Step 3: Unescape single quotes (Chromium doesn't escape them)
    $result = $result -replace '\\u0027', "'"

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

    .PARAMETER Value
        The value to serialize.

    .OUTPUTS
        [string] The JSON representation suitable for MAC calculation.

    .EXAMPLE
        $json = ConvertTo-JsonForHmac -Value $true
        # Returns: "true"

    .EXAMPLE
        $json = ConvertTo-JsonForHmac -Value $null
        # Returns: "" (empty string)
    #>
    [CmdletBinding()]
    [OutputType([string])]
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

# ============================================================================
# MAC CALCULATION FUNCTIONS
# ============================================================================

function Get-PreferenceHmac {
    <#
    .SYNOPSIS
        Calculate MAC for a preference value (file MAC with empty seed).

    .DESCRIPTION
        Calculates the HMAC-SHA256 for a Chromium preference value using
        the formula: HMAC-SHA256(key="", message=device_id + path + value_json)

        This is used for MACs stored in the Secure Preferences file.

    .PARAMETER DeviceId
        The Windows SID without RID.

    .PARAMETER Path
        The preference path (e.g., "browser.show_home_button").

    .PARAMETER Value
        The preference value.

    .OUTPUTS
        [string] The MAC as an uppercase hex string.

    .EXAMPLE
        $mac = Get-PreferenceHmac -DeviceId $sid -Path "browser.show_home_button" -Value $true
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$DeviceId,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        $Value
    )

    $valueJson = ConvertTo-JsonForHmac -Value $Value
    $message = $DeviceId + $Path + $valueJson
    return Get-HmacSha256 -Key $script:FileMacSeed -Message $message
}

function Get-RegistryPreferenceHmac {
    <#
    .SYNOPSIS
        Calculate MAC for a preference value (registry MAC with literal seed).

    .DESCRIPTION
        Calculates the HMAC-SHA256 for a Chromium preference value using
        the formula: HMAC-SHA256(key="ChromeRegistryHashStoreValidationSeed", message=device_id + path + value_json)

        This is used for MACs stored in the Windows Registry.

    .PARAMETER DeviceId
        The Windows SID without RID.

    .PARAMETER Path
        The preference path (e.g., "browser.show_home_button").

    .PARAMETER Value
        The preference value.

    .OUTPUTS
        [string] The MAC as an uppercase hex string.

    .EXAMPLE
        $mac = Get-RegistryPreferenceHmac -DeviceId $sid -Path "browser.show_home_button" -Value $true
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$DeviceId,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        $Value
    )

    $valueJson = ConvertTo-JsonForHmac -Value $Value
    $message = $DeviceId + $Path + $valueJson
    return Get-HmacSha256 -Key $script:RegistryMacSeed -Message $message
}

# ============================================================================
# VALUE NAVIGATION
# ============================================================================

function Get-PrefValue {
    <#
    .SYNOPSIS
        Navigate a dotted path like "extensions.settings.xyz" to get a value.

    .DESCRIPTION
        Traverses a nested object structure using a dot-separated path string.

    .PARAMETER Root
        The root object to navigate from.

    .PARAMETER Path
        The dot-separated path (e.g., "extensions.settings.abc123").

    .OUTPUTS
        The value at the specified path, or $null if not found.

    .EXAMPLE
        $value = Get-PrefValue -Root $securePrefs -Path "browser.show_home_button"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Root,

        [Parameter(Mandatory)]
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

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Test-RawJsonHasEmptyArray {
    <#
    .SYNOPSIS
        Check if the raw JSON has an empty array [] for the given key.

    .DESCRIPTION
        PowerShell 5.1's ConvertFrom-Json converts empty arrays [] to $null.
        This function checks the raw JSON to detect if a key had an empty array.

    .PARAMETER RawJson
        The raw JSON string.

    .PARAMETER Key
        The key name to check.

    .OUTPUTS
        [bool] $true if the key has an empty array in the raw JSON.

    .EXAMPLE
        if (Test-RawJsonHasEmptyArray -RawJson $json -Key "pinned_tabs") { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$RawJson,

        [Parameter(Mandatory)]
        [string]$Key
    )

    # Look for "key":[] pattern
    $escapedKey = [regex]::Escape($Key)
    $pattern = "`"$escapedKey`"\s*:\s*\[\s*\]"
    return $RawJson -match $pattern
}

function Get-MacsFromNestedObject {
    <#
    .SYNOPSIS
        Recursively extract all MAC paths and values from a nested PSCustomObject.

    .DESCRIPTION
        The protection.macs structure mirrors the preference structure:
        protection.macs.extensions.settings.{id} = "MAC"
        This becomes path "extensions.settings.{id}"

    .PARAMETER Object
        The PSCustomObject to extract MACs from.

    .PARAMETER Prefix
        The current path prefix (used during recursion).

    .OUTPUTS
        [hashtable] A hashtable mapping paths to MAC values.

    .EXAMPLE
        $macs = Get-MacsFromNestedObject -Object $securePrefs.protection.macs
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [PSCustomObject]$Object,

        [Parameter()]
        [string]$Prefix = ""
    )

    $results = @{}

    if ($null -eq $Object) {
        return $results
    }

    foreach ($prop in $Object.PSObject.Properties) {
        $name = $prop.Name
        $value = $prop.Value
        $path = if ($Prefix) { "$Prefix.$name" } else { $name }

        if ($value -is [PSCustomObject]) {
            # Recurse into nested objects
            $nested = Get-MacsFromNestedObject -Object $value -Prefix $path
            foreach ($key in $nested.Keys) {
                $results[$key] = $nested[$key]
            }
        }
        elseif ($value -is [string]) {
            # This is a MAC value
            $results[$path] = $value
        }
    }

    return $results
}

# ============================================================================
# PATH UTILITIES
# ============================================================================

function Get-MeteorDataPath {
    <#
    .SYNOPSIS
        Get the default .meteor data path.

    .DESCRIPTION
        Returns the path to the .meteor directory in the parent of the test-data folder.

    .OUTPUTS
        [string] The path to the .meteor directory.

    .EXAMPLE
        $dataPath = Get-MeteorDataPath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return Join-Path (Split-Path $PSScriptRoot -Parent) ".meteor"
}

function Get-SecurePreferencesPath {
    <#
    .SYNOPSIS
        Get the path to the Secure Preferences file.

    .PARAMETER DataPath
        Optional custom data path. Defaults to Get-MeteorDataPath.

    .OUTPUTS
        [string] The path to the Secure Preferences file.

    .EXAMPLE
        $prefsPath = Get-SecurePreferencesPath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$DataPath
    )

    if ([string]::IsNullOrEmpty($DataPath)) {
        $DataPath = Get-MeteorDataPath
    }

    return Join-Path $DataPath "User Data\Default\Secure Preferences"
}

function Get-RegistryMacsPath {
    <#
    .SYNOPSIS
        Get the registry path for preference MACs.

    .OUTPUTS
        [string] The registry path.

    .EXAMPLE
        $regPath = Get-RegistryMacsPath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return "HKCU:\Software\Perplexity\Comet\PreferenceMACs\Default"
}

# ============================================================================
# EXPORT (for module use, though we typically dot-source)
# ============================================================================

# Note: When dot-sourced, all functions are automatically available in the calling scope.
# This export list is for documentation purposes.

$ExportedFunctions = @(
    'Get-WindowsSidWithoutRid'
    'Get-HmacSha256'
    'ConvertTo-SortedAndPruned'
    'ConvertTo-ChromiumJson'
    'ConvertTo-JsonForHmac'
    'Get-PreferenceHmac'
    'Get-RegistryPreferenceHmac'
    'Get-PrefValue'
    'Test-RawJsonHasEmptyArray'
    'Get-MacsFromNestedObject'
    'Get-MeteorDataPath'
    'Get-SecurePreferencesPath'
    'Get-RegistryMacsPath'
)
