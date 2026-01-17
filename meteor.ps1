<#
.SYNOPSIS
    Meteor v2 - Privacy-focused Comet browser enhancement system for Windows.

.DESCRIPTION
    A complete automated workflow that:
    - Downloads and installs Comet browser if not present
    - Checks for and applies Comet updates
    - Checks for extension updates from their update URLs
    - Extracts and patches extensions and resources.pak as needed
    - Launches Comet with privacy enhancements

.PARAMETER Config
    Path to config.json file. Defaults to config.json in script directory.

.PARAMETER DryRun
    Show what would be done without making changes or launching browser.

.PARAMETER Force
    Force re-extraction and re-patching even if files haven't changed.
    Stops running Comet processes and deletes Preferences files to ensure fresh settings.

.PARAMETER NoLaunch
    Perform all setup steps but don't launch the browser.

.PARAMETER Verbose
    Enable verbose output for debugging.

.EXAMPLE
    .\Meteor.ps1
    Run full workflow and launch browser.

.EXAMPLE
    .\Meteor.ps1 -DryRun
    Show what would be done without making changes.

.EXAMPLE
    .\Meteor.ps1 -Force
    Force re-setup even if files haven't changed.
#>

# Suppress PSScriptAnalyzer warnings for internal helper functions
# These are internal functions that don't need ShouldProcess support
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-FileHash')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Set-PakResource')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-Extension')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Set-BrowserPreferences')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Start-Browser')]
# Script parameters are used in Main function via direct variable access
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Config', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DryRun', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Force', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'NoLaunch', Justification = 'Used in Main function')]
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Config,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Constants

$script:MeteorVersion = "2.0.0"
$script:UserAgent = "Meteor/$script:MeteorVersion"
$script:ExtensionKeyFile = Join-Path (Join-Path $PSScriptRoot ".meteor") "extension-key.pem"

#endregion

#region Helper Functions

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Detail", "Step")]
        [string]$Type = "Info"
    )

    switch ($Type) {
        "Info" { Write-Host "[*] $Message" -ForegroundColor Cyan }
        "Success" { Write-Host "[+] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[!] $Message" -ForegroundColor Yellow }
        "Error" { Write-Host "[!] $Message" -ForegroundColor Red }
        "Detail" { Write-Host "    -> $Message" -ForegroundColor Gray }
        "Step" { Write-Host "`n=== $Message ===" -ForegroundColor Magenta }
    }
}

function Get-FileHash256 {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    $hash = Get-FileHash -Path $Path -Algorithm SHA256
    return $hash.Hash
}

function ConvertTo-LittleEndianUInt32 {
    param([byte[]]$Bytes, [int]$Offset = 0)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function ConvertTo-LittleEndianUInt16 {
    param([byte[]]$Bytes, [int]$Offset = 0)
    return [BitConverter]::ToUInt16($Bytes, $Offset)
}

function ConvertFrom-UInt32ToBytes {
    param([uint32]$Value)
    return [BitConverter]::GetBytes($Value)
}

function ConvertFrom-UInt16ToBytes {
    param([uint16]$Value)
    return [BitConverter]::GetBytes($Value)
}

#endregion

#region Configuration

function Get-MeteorConfig {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        throw "Config not found: $ConfigPath"
    }

    $content = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
    return $content | ConvertFrom-Json
}

function Resolve-MeteorPath {
    param(
        [string]$BasePath,
        [string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        return $RelativePath
    }

    return (Join-Path $BasePath $RelativePath)
}

#endregion

#region State Management

function ConvertTo-Hashtable {
    # Convert PSCustomObject to hashtable (PS 5.1 compatibility)
    param([object]$InputObject)

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $collection = @(foreach ($item in $InputObject) { ConvertTo-Hashtable $item })
        return $collection
    }
    elseif ($InputObject -is [PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $hash
    }
    else {
        return $InputObject
    }
}

function Get-MeteorState {
    param([string]$StatePath)

    if (-not (Test-Path $StatePath)) {
        return @{
            version            = $script:MeteorVersion
            comet_version      = ""
            file_hashes        = @{}
            extension_versions = @{}
            last_update_check  = ""
        }
    }

    $content = Get-Content -Path $StatePath -Raw -Encoding UTF8
    $json = $content | ConvertFrom-Json
    return ConvertTo-Hashtable $json
}

function Save-MeteorState {
    param(
        [string]$StatePath,
        [hashtable]$State
    )

    $stateDir = Split-Path -Parent $StatePath
    if (-not (Test-Path $stateDir)) {
        New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
    }

    $State.version = $script:MeteorVersion
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $StatePath -Encoding UTF8
}

function Test-FileChanged {
    param(
        [string]$FilePath,
        [hashtable]$State
    )

    $currentHash = Get-FileHash256 -Path $FilePath
    if (-not $currentHash) {
        return $true
    }

    $storedHash = $State.file_hashes[$FilePath]
    return ($currentHash -ne $storedHash)
}

function Update-FileHash {
    param(
        [string]$FilePath,
        [hashtable]$State
    )

    $hash = Get-FileHash256 -Path $FilePath
    if ($hash) {
        $State.file_hashes[$FilePath] = $hash
    }
}

#endregion

#region PAK File Operations

function Read-PakFile {
    <#
    .SYNOPSIS
        Parse a Chromium PAK file and return its structure.
    .DESCRIPTION
        Supports PAK format versions 4 and 5 (little-endian).
        Returns hashtable with version, encoding, resources, aliases, and raw data.
    #>
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    # Read version (4 bytes)
    $version = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset 0

    if ($version -ne 4 -and $version -ne 5) {
        throw "Unsupported PAK version: $version (expected 4 or 5)"
    }

    $pak = @{
        Version   = $version
        Encoding  = $bytes[4]
        Resources = [System.Collections.ArrayList]@()
        Aliases   = [System.Collections.ArrayList]@()
        RawBytes  = $bytes
    }

    $offset = 5

    if ($version -eq 4) {
        # Version 4: encoding(1) + num_resources(4)
        $numResources = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset $offset
        $offset += 4
        $numAliases = 0
    }
    else {
        # Version 5: encoding(1) + padding(3) + num_resources(2) + num_aliases(2)
        $offset += 3  # Skip padding
        $numResources = ConvertTo-LittleEndianUInt16 -Bytes $bytes -Offset $offset
        $offset += 2
        $numAliases = ConvertTo-LittleEndianUInt16 -Bytes $bytes -Offset $offset
        $offset += 2
    }

    # Read resource entries (id:2 + offset:4 = 6 bytes each)
    # Include sentinel entry (+1)
    for ($i = 0; $i -le $numResources; $i++) {
        $resId = ConvertTo-LittleEndianUInt16 -Bytes $bytes -Offset $offset
        $resOffset = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset ($offset + 2)

        [void]$pak.Resources.Add(@{
                Id     = $resId
                Offset = $resOffset
            })

        $offset += 6
    }

    # Read alias entries if version 5 (id:2 + index:2 = 4 bytes each)
    if ($version -eq 5 -and $numAliases -gt 0) {
        for ($i = 0; $i -lt $numAliases; $i++) {
            $aliasId = ConvertTo-LittleEndianUInt16 -Bytes $bytes -Offset $offset
            $aliasIndex = ConvertTo-LittleEndianUInt16 -Bytes $bytes -Offset ($offset + 2)

            [void]$pak.Aliases.Add(@{
                    Id            = $aliasId
                    ResourceIndex = $aliasIndex
                })

            $offset += 4
        }
    }

    $pak.DataStartOffset = $offset
    return $pak
}

function Get-PakResource {
    <#
    .SYNOPSIS
        Get the content of a specific resource from a PAK file.
    #>
    param(
        [hashtable]$Pak,
        [int]$ResourceId
    )

    for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
        if ($Pak.Resources[$i].Id -eq $ResourceId) {
            $startOffset = $Pak.Resources[$i].Offset
            $endOffset = $Pak.Resources[$i + 1].Offset
            $length = $endOffset - $startOffset

            $data = New-Object byte[] $length
            [Array]::Copy($Pak.RawBytes, $startOffset, $data, 0, $length)

            return $data
        }
    }

    return $null
}

function Set-PakResource {
    <#
    .SYNOPSIS
        Replace the content of a specific resource in a PAK structure.
    .DESCRIPTION
        Updates the PAK structure in-memory. Use Write-PakFile to save.
    #>
    param(
        [hashtable]$Pak,
        [int]$ResourceId,
        [byte[]]$NewData
    )

    for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
        if ($Pak.Resources[$i].Id -eq $ResourceId) {
            $startOffset = $Pak.Resources[$i].Offset
            $endOffset = $Pak.Resources[$i + 1].Offset
            $oldLength = $endOffset - $startOffset
            $newLength = $NewData.Length
            $sizeDiff = $newLength - $oldLength

            # Create new byte array
            $newBytes = New-Object byte[] ($Pak.RawBytes.Length + $sizeDiff)

            # Copy everything before this resource
            [Array]::Copy($Pak.RawBytes, 0, $newBytes, 0, $startOffset)

            # Copy new data
            [Array]::Copy($NewData, 0, $newBytes, $startOffset, $newLength)

            # Copy everything after this resource
            $afterLength = $Pak.RawBytes.Length - $endOffset
            if ($afterLength -gt 0) {
                [Array]::Copy($Pak.RawBytes, $endOffset, $newBytes, $startOffset + $newLength, $afterLength)
            }

            # Update offsets for all subsequent resources
            for ($j = $i + 1; $j -lt $Pak.Resources.Count; $j++) {
                $Pak.Resources[$j].Offset += $sizeDiff
            }

            $Pak.RawBytes = $newBytes
            return $true
        }
    }

    return $false
}

function Write-PakFile {
    <#
    .SYNOPSIS
        Write a PAK structure back to a file.
    #>
    param(
        [hashtable]$Pak,
        [string]$Path
    )

    # Rebuild the header and resource table
    $output = [System.Collections.ArrayList]@()

    # Version (4 bytes)
    [void]$output.AddRange((ConvertFrom-UInt32ToBytes -Value $Pak.Version))

    # Encoding (1 byte)
    [void]$output.Add($Pak.Encoding)

    $numResources = $Pak.Resources.Count - 1  # Exclude sentinel

    if ($Pak.Version -eq 4) {
        # num_resources (4 bytes)
        [void]$output.AddRange((ConvertFrom-UInt32ToBytes -Value $numResources))
    }
    else {
        # Version 5: padding(3) + num_resources(2) + num_aliases(2)
        [void]$output.Add([byte]0)
        [void]$output.Add([byte]0)
        [void]$output.Add([byte]0)
        [void]$output.AddRange((ConvertFrom-UInt16ToBytes -Value ([uint16]$numResources)))
        [void]$output.AddRange((ConvertFrom-UInt16ToBytes -Value ([uint16]$Pak.Aliases.Count)))
    }

    # Calculate header size
    $headerSize = $output.Count
    $resourceTableSize = $Pak.Resources.Count * 6  # 6 bytes per entry including sentinel
    $aliasTableSize = $Pak.Aliases.Count * 4

    $dataStartOffset = $headerSize + $resourceTableSize + $aliasTableSize

    # Recalculate resource offsets
    $currentDataOffset = $dataStartOffset
    $resourceData = [System.Collections.ArrayList]@()

    for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
        $startOffset = $Pak.Resources[$i].Offset
        $endOffset = $Pak.Resources[$i + 1].Offset
        $length = $endOffset - $startOffset

        $data = New-Object byte[] $length
        [Array]::Copy($Pak.RawBytes, $startOffset, $data, 0, $length)

        $Pak.Resources[$i].Offset = $currentDataOffset
        [void]$resourceData.Add($data)

        $currentDataOffset += $length
    }

    # Update sentinel offset
    $Pak.Resources[$Pak.Resources.Count - 1].Offset = $currentDataOffset

    # Write resource entries
    foreach ($res in $Pak.Resources) {
        [void]$output.AddRange((ConvertFrom-UInt16ToBytes -Value ([uint16]$res.Id)))
        [void]$output.AddRange((ConvertFrom-UInt32ToBytes -Value ([uint32]$res.Offset)))
    }

    # Write alias entries
    foreach ($alias in $Pak.Aliases) {
        [void]$output.AddRange((ConvertFrom-UInt16ToBytes -Value ([uint16]$alias.Id)))
        [void]$output.AddRange((ConvertFrom-UInt16ToBytes -Value ([uint16]$alias.ResourceIndex)))
    }

    # Write resource data
    foreach ($data in $resourceData) {
        [void]$output.AddRange($data)
    }

    # Write to file
    [System.IO.File]::WriteAllBytes($Path, [byte[]]$output.ToArray())
}

#endregion

#region CRX Extraction

function Read-ProtobufVarint {
    <#
    .SYNOPSIS
        Read a varint from byte array at given position, return value and new position.
    #>
    param([byte[]]$Bytes, [int]$Pos)

    $result = 0
    $shift = 0
    do {
        $b = $Bytes[$Pos]
        $result = $result -bor (($b -band 0x7F) -shl $shift)
        $shift += 7
        $Pos++
    } while ($b -band 0x80)

    return @{ Value = $result; Pos = $Pos }
}

function Get-CrxPublicKey {
    <#
    .SYNOPSIS
        Extract the public key from a CRX file as base64.
    .DESCRIPTION
        Handles both CRX2 (direct key) and CRX3 (protobuf header) formats.
        For CRX3, finds the key that matches the CRX ID in signed_header_data.
        Returns the key as a base64 string suitable for manifest.json "key" field.
    #>
    param([string]$CrxPath)

    $bytes = [System.IO.File]::ReadAllBytes($CrxPath)

    # Check magic header "Cr24"
    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($magic -ne "Cr24") {
        throw "Invalid CRX file: missing Cr24 magic header"
    }

    $version = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset 4

    if ($version -eq 2) {
        # CRX2: public key is at offset 16 for pubkeyLen bytes
        $pubkeyLen = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset 8
        $pubkey = New-Object byte[] $pubkeyLen
        [Array]::Copy($bytes, 16, $pubkey, 0, $pubkeyLen)
        return [Convert]::ToBase64String($pubkey)
    }
    elseif ($version -eq 3) {
        # CRX3: Find the key whose SHA256 hash matches the CRX ID
        $headerLen = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset 8
        $headerStart = 12
        $headerEnd = $headerStart + $headerLen

        # First pass: collect all keys and find the CRX ID
        $keys = [System.Collections.ArrayList]@()
        $crxId = $null

        $pos = $headerStart
        while ($pos -lt $headerEnd) {
            $result = Read-ProtobufVarint -Bytes $bytes -Pos $pos
            $tag = $result.Value
            $pos = $result.Pos

            $fieldNum = $tag -shr 3
            $wireType = $tag -band 0x07

            if ($wireType -eq 2) {
                $result = Read-ProtobufVarint -Bytes $bytes -Pos $pos
                $len = $result.Value
                $pos = $result.Pos
                $fieldEnd = $pos + $len

                if ($fieldNum -in @(2, 3)) {
                    # sha256_with_rsa (2) or sha256_with_ecdsa (3) - extract public_key
                    $nestedPos = $pos
                    while ($nestedPos -lt $fieldEnd) {
                        $result = Read-ProtobufVarint -Bytes $bytes -Pos $nestedPos
                        $nestedTag = $result.Value
                        $nestedPos = $result.Pos

                        $nestedFieldNum = $nestedTag -shr 3
                        $nestedWireType = $nestedTag -band 0x07

                        if ($nestedWireType -eq 2) {
                            $result = Read-ProtobufVarint -Bytes $bytes -Pos $nestedPos
                            $nestedLen = $result.Value
                            $nestedPos = $result.Pos

                            if ($nestedFieldNum -eq 1) {
                                # public_key field
                                $pubkey = New-Object byte[] $nestedLen
                                [Array]::Copy($bytes, $nestedPos, $pubkey, 0, $nestedLen)
                                [void]$keys.Add($pubkey)
                            }
                            $nestedPos += $nestedLen
                        }
                        else {
                            break
                        }
                    }
                }
                elseif ($fieldNum -eq 10000) {
                    # signed_header_data - contains crx_id
                    $nestedPos = $pos
                    while ($nestedPos -lt $fieldEnd) {
                        $result = Read-ProtobufVarint -Bytes $bytes -Pos $nestedPos
                        $nestedTag = $result.Value
                        $nestedPos = $result.Pos

                        $nestedFieldNum = $nestedTag -shr 3
                        $nestedWireType = $nestedTag -band 0x07

                        if ($nestedWireType -eq 2 -and $nestedFieldNum -eq 1) {
                            # crx_id field
                            $result = Read-ProtobufVarint -Bytes $bytes -Pos $nestedPos
                            $crxIdLen = $result.Value
                            $nestedPos = $result.Pos

                            $crxId = New-Object byte[] $crxIdLen
                            [Array]::Copy($bytes, $nestedPos, $crxId, 0, $crxIdLen)
                            break
                        }
                        else {
                            break
                        }
                    }
                }

                $pos = $fieldEnd
            }
            elseif ($wireType -eq 0) {
                $result = Read-ProtobufVarint -Bytes $bytes -Pos $pos
                $pos = $result.Pos
            }
            elseif ($wireType -eq 1) { $pos += 8 }
            elseif ($wireType -eq 5) { $pos += 4 }
        }

        # Find the key that matches the CRX ID
        if ($crxId -and $keys.Count -gt 0) {
            $crxIdHex = [BitConverter]::ToString($crxId).Replace("-", "").ToLower()

            foreach ($key in $keys) {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $hash = $sha.ComputeHash($key)
                $hashHex = [BitConverter]::ToString($hash[0..15]).Replace("-", "").ToLower()

                if ($hashHex -eq $crxIdHex) {
                    return [Convert]::ToBase64String($key)
                }
            }
        }

        # Fallback: return first key if no CRX ID match (shouldn't happen for valid CRX)
        if ($keys.Count -gt 0) {
            return [Convert]::ToBase64String($keys[0])
        }

        throw "Could not find public key in CRX3 header"
    }
    else {
        throw "Unsupported CRX version: $version"
    }
}

function ConvertTo-SpkiBase64 {
    <#
    .SYNOPSIS
        Convert RSA parameters to SubjectPublicKeyInfo (SPKI) base64 format.
    .DESCRIPTION
        Takes RSA public key parameters (modulus and exponent) and encodes them
        in the DER/SPKI format that Chrome uses for extension public keys.
    #>
    param([System.Security.Cryptography.RSAParameters]$Params)

    function Get-DerInteger {
        param([byte[]]$Value)
        $i = 0
        while ($i -lt $Value.Length - 1 -and $Value[$i] -eq 0) { $i++ }
        $Value = $Value[$i..($Value.Length - 1)]
        if ($Value[0] -band 0x80) {
            $Value = @([byte]0) + $Value
        }
        $len = $Value.Length
        if ($len -lt 128) {
            return @([byte]0x02, [byte]$len) + $Value
        }
        elseif ($len -lt 256) {
            return @([byte]0x02, [byte]0x81, [byte]$len) + $Value
        }
        else {
            return @([byte]0x02, [byte]0x82, [byte](($len -shr 8) -band 0xFF), [byte]($len -band 0xFF)) + $Value
        }
    }

    function Get-DerSequence {
        param([byte[]]$Content)
        $len = $Content.Length
        if ($len -lt 128) {
            return @([byte]0x30, [byte]$len) + $Content
        }
        elseif ($len -lt 256) {
            return @([byte]0x30, [byte]0x81, [byte]$len) + $Content
        }
        else {
            return @([byte]0x30, [byte]0x82, [byte](($len -shr 8) -band 0xFF), [byte]($len -band 0xFF)) + $Content
        }
    }

    function Get-DerBitString {
        param([byte[]]$Content)
        $len = $Content.Length + 1
        if ($len -lt 128) {
            return @([byte]0x03, [byte]$len, [byte]0x00) + $Content
        }
        elseif ($len -lt 256) {
            return @([byte]0x03, [byte]0x81, [byte]$len, [byte]0x00) + $Content
        }
        else {
            return @([byte]0x03, [byte]0x82, [byte](($len -shr 8) -band 0xFF), [byte]($len -band 0xFF), [byte]0x00) + $Content
        }
    }

    $rsaOid = [byte[]]@(0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01)
    $nullParam = [byte[]]@(0x05, 0x00)
    $algorithmId = Get-DerSequence -Content ($rsaOid + $nullParam)

    $modulus = Get-DerInteger -Value $Params.Modulus
    $exponent = Get-DerInteger -Value $Params.Exponent
    $rsaPublicKey = Get-DerSequence -Content ([byte[]]$modulus + [byte[]]$exponent)

    $publicKeyBitString = Get-DerBitString -Content $rsaPublicKey
    $spki = Get-DerSequence -Content ([byte[]]$algorithmId + [byte[]]$publicKeyBitString)

    return [Convert]::ToBase64String([byte[]]$spki)
}

function Initialize-ExtensionKey {
    <#
    .SYNOPSIS
        Generate and store an RSA key pair for extension signing if not present.
    .DESCRIPTION
        Creates a 2048-bit RSA key pair and stores it in XML format.
        This key is used to give all unpacked extensions a consistent ID.
    #>
    if (Test-Path $script:ExtensionKeyFile) {
        return $true
    }

    Write-Status "Generating extension pinning key..." -Type Info

    try {
        # Ensure .meteor directory exists
        $keyDir = Split-Path $script:ExtensionKeyFile -Parent
        if (-not (Test-Path $keyDir)) {
            $null = New-Item -ItemType Directory -Path $keyDir -Force
        }

        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
        $xmlKey = $rsa.ToXmlString($true)

        Set-Content -Path $script:ExtensionKeyFile -Value $xmlKey -Encoding UTF8 -NoNewline
        Write-Status "Extension key generated: $script:ExtensionKeyFile" -Type Success
        return $true
    }
    catch {
        Write-Status "Could not generate extension key: $_" -Type Warning
        return $false
    }
}

function Get-PublicKeyBase64 {
    <#
    .SYNOPSIS
        Get the public key in base64 SPKI format from the stored key file.
    #>
    if (-not (Test-Path $script:ExtensionKeyFile)) {
        return $null
    }

    try {
        $xmlKey = Get-Content $script:ExtensionKeyFile -Raw

        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
        $rsa.FromXmlString($xmlKey)
        $params = $rsa.ExportParameters($false)

        return ConvertTo-SpkiBase64 -Params $params
    }
    catch {
        Write-Status "Could not extract public key: $_" -Type Warning
        return $null
    }
}

function Get-ExtensionIdFromKey {
    <#
    .SYNOPSIS
        Calculate the extension ID from a public key.
    .DESCRIPTION
        Chrome extension IDs are derived from the first 128 bits of the SHA256 hash
        of the public key, encoded using a-p alphabet (not hex).
    #>
    param([string]$PublicKeyBase64)

    try {
        $keyBytes = [Convert]::FromBase64String($PublicKeyBase64)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($keyBytes)

        $chars = 'abcdefghijklmnop'
        $extId = ''
        for ($i = 0; $i -lt 16; $i++) {
            $extId += $chars[[int][Math]::Floor($hashBytes[$i] / 16)]
            $extId += $chars[$hashBytes[$i] % 16]
        }
        return $extId
    }
    catch {
        Write-Status "Could not calculate extension ID: $_" -Type Warning
        return $null
    }
}

function Add-ExtensionKey {
    <#
    .SYNOPSIS
        Inject the Meteor extension key into an extension's manifest.json.
    .DESCRIPTION
        Adds or updates the "key" field in manifest.json to ensure a consistent extension ID.
        Returns the extension ID that will result from this key.
    #>
    param(
        [string]$ExtensionDir,
        [string]$ExtensionName
    )

    $manifestPath = Join-Path $ExtensionDir "manifest.json"

    if (-not (Test-Path $manifestPath)) {
        Write-Status "Manifest not found: $manifestPath" -Type Warning
        return $null
    }

    try {
        # Ensure we have a key
        if (-not (Initialize-ExtensionKey)) {
            return $null
        }

        $publicKeyB64 = Get-PublicKeyBase64
        if (-not $publicKeyB64) {
            Write-Status "Could not get public key" -Type Warning
            return $null
        }

        $extId = Get-ExtensionIdFromKey $publicKeyB64
        if (-not $extId) {
            Write-Status "Could not calculate extension ID" -Type Warning
            return $null
        }

        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

        $existingKey = $null
        if ($manifest.PSObject.Properties.Name -contains 'key') {
            $existingKey = $manifest.key
        }

        if ($existingKey -eq $publicKeyB64) {
            Write-Status "Extension key verified ($ExtensionName ID: $extId)" -Type Detail
            return $extId
        }

        $manifest | Add-Member -NotePropertyName 'key' -NotePropertyValue $publicKeyB64 -Force
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8
        Write-Status "Updated extension key ($ExtensionName ID: $extId)" -Type Success
        return $extId
    }
    catch {
        Write-Status "Could not update extension key for ${ExtensionName}: $_" -Type Warning
        return $null
    }
}

function Export-CrxToDirectory {
    <#
    .SYNOPSIS
        Extract a CRX file to a directory.
    .DESCRIPTION
        Handles both CRX2 and CRX3 formats by detecting the header and extracting the ZIP payload.
        Optionally injects the public key into manifest.json for consistent extension ID.
    #>
    param(
        [string]$CrxPath,
        [string]$OutputDir,
        [switch]$InjectKey
    )

    $bytes = [System.IO.File]::ReadAllBytes($CrxPath)

    # Check magic header "Cr24"
    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($magic -ne "Cr24") {
        throw "Invalid CRX file: missing Cr24 magic header"
    }

    # Get version (4 bytes at offset 4)
    $version = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset 4

    $zipOffset = 0

    if ($version -eq 2) {
        # CRX2: magic(4) + version(4) + pubkey_len(4) + sig_len(4) + pubkey + sig + zip
        $pubkeyLen = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset 8
        $sigLen = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset 12
        $zipOffset = 16 + $pubkeyLen + $sigLen
    }
    elseif ($version -eq 3) {
        # CRX3: magic(4) + version(4) + header_len(4) + header + zip
        $headerLen = ConvertTo-LittleEndianUInt32 -Bytes $bytes -Offset 8
        $zipOffset = 12 + $headerLen
    }
    else {
        throw "Unsupported CRX version: $version"
    }

    # Extract ZIP portion
    $zipLength = $bytes.Length - $zipOffset
    $zipBytes = New-Object byte[] $zipLength
    [Array]::Copy($bytes, $zipOffset, $zipBytes, 0, $zipLength)

    # Write to temp file and extract
    $tempZip = Join-Path $env:TEMP "meteor_crx_$(Get-Random).zip"

    try {
        [System.IO.File]::WriteAllBytes($tempZip, $zipBytes)

        if (Test-Path $OutputDir) {
            Remove-Item -Path $OutputDir -Recurse -Force
        }

        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $tempZip -DestinationPath $OutputDir -Force

        # Inject public key into manifest if requested
        if ($InjectKey) {
            $publicKey = Get-CrxPublicKey -CrxPath $CrxPath
            $manifestPath = Join-Path $OutputDir "manifest.json"

            if ((Test-Path $manifestPath) -and $publicKey) {
                $manifest = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

                # Add key as first property for readability
                $manifest | Add-Member -NotePropertyName "key" -NotePropertyValue $publicKey -Force

                $manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8
            }
        }
    }
    finally {
        if (Test-Path $tempZip) {
            Remove-Item -Path $tempZip -Force
        }
    }
}

function Get-CrxManifest {
    <#
    .SYNOPSIS
        Read manifest.json from a CRX file without full extraction.
    #>
    param([string]$CrxPath)

    $tempDir = Join-Path $env:TEMP "meteor_manifest_$(Get-Random)"

    try {
        Export-CrxToDirectory -CrxPath $CrxPath -OutputDir $tempDir
        $manifestPath = Join-Path $tempDir "manifest.json"

        if (Test-Path $manifestPath) {
            $content = Get-Content -Path $manifestPath -Raw -Encoding UTF8
            return $content | ConvertFrom-Json
        }
    }
    finally {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force
        }
    }

    return $null
}

#endregion

#region Extension Update Checking

function Get-ExtensionUpdateInfo {
    <#
    .SYNOPSIS
        Query an extension's update URL to check for newer versions.
    #>
    param(
        [string]$UpdateUrl,
        [string]$ExtensionId,
        [string]$CurrentVersion
    )

    if (-not $UpdateUrl) {
        return $null
    }

    # Build update check URL
    $encodedId = [System.Web.HttpUtility]::UrlEncode("id=$ExtensionId")
    $encodedVersion = [System.Web.HttpUtility]::UrlEncode("v=$CurrentVersion")
    $checkUrl = "$UpdateUrl`?x=$encodedId%26$encodedVersion%26uc"

    try {
        $response = Invoke-WebRequest -Uri $checkUrl -UseBasicParsing -TimeoutSec 30 -Headers @{
            "User-Agent" = $script:UserAgent
        }

        # Parse XML response
        [xml]$xml = $response.Content

        $ns = @{ g = "http://www.google.com/update2/response" }
        $app = Select-Xml -Xml $xml -XPath "//g:app[@appid='$ExtensionId']" -Namespace $ns

        if ($app -and $app.Node) {
            # Access updatecheck child directly - works in both PS 5.1 and 7
            $node = $app.Node.updatecheck
            if ($node) {
                # Use PSObject.Properties to avoid StrictMode errors
                $hasVersion = $node.PSObject.Properties['version']
                $hasCodebase = $node.PSObject.Properties['codebase']
                if ($hasVersion -and $hasCodebase) {
                    return @{
                        Version  = $node.version
                        Codebase = $node.codebase
                    }
                }
            }
        }
    }
    catch {
        Write-Status "Failed to check updates for $ExtensionId : $_" -Type Warning
    }

    return $null
}

function Compare-Versions {
    <#
    .SYNOPSIS
        Compare two version strings (A.B.C.D format).
    .RETURNS
        -1 if v1 < v2, 0 if equal, 1 if v1 > v2
    #>
    param(
        [string]$Version1,
        [string]$Version2
    )

    $v1Parts = $Version1 -split '\.' | ForEach-Object { [int]$_ }
    $v2Parts = $Version2 -split '\.' | ForEach-Object { [int]$_ }

    $maxLen = [Math]::Max($v1Parts.Count, $v2Parts.Count)

    for ($i = 0; $i -lt $maxLen; $i++) {
        $p1 = if ($i -lt $v1Parts.Count) { $v1Parts[$i] } else { 0 }
        $p2 = if ($i -lt $v2Parts.Count) { $v2Parts[$i] } else { 0 }

        if ($p1 -lt $p2) { return -1 }
        if ($p1 -gt $p2) { return 1 }
    }

    return 0
}

function Update-Extension {
    <#
    .SYNOPSIS
        Download and extract an updated extension.
    #>
    param(
        [string]$Codebase,
        [string]$OutputPath
    )

    $tempCrx = Join-Path $env:TEMP "meteor_update_$(Get-Random).crx"

    try {
        Write-Status "Downloading update from: $Codebase" -Type Info

        Invoke-WebRequest -Uri $Codebase -OutFile $tempCrx -UseBasicParsing -TimeoutSec 120 -Headers @{
            "User-Agent" = $script:UserAgent
        }

        Export-CrxToDirectory -CrxPath $tempCrx -OutputDir $OutputPath -InjectKey
        return $true
    }
    catch {
        Write-Status "Failed to download extension update: $_" -Type Error
        return $false
    }
    finally {
        if (Test-Path $tempCrx) {
            Remove-Item -Path $tempCrx -Force
        }
    }
}

function Get-ChromeExtensionVersion {
    <#
    .SYNOPSIS
        Get the latest version of a Chrome Web Store extension.
    #>
    param([Parameter(Mandatory)][string]$ExtensionId)

    try {
        $url = "https://chromewebstore.google.com/detail/$ExtensionId"
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{
            "User-Agent" = $script:UserAgent
        }

        # Match version from the Details section specifically
        # Pattern: "Version</dt><dd>1.68.0</dd>" or similar
        if ($response.Content -match '>Version</[^>]+>\s*<[^>]+>([\d.]+)<') {
            return $Matches[1]
        }

        return $null
    }
    catch {
        Write-Status "Failed to get version for extension $ExtensionId`: $_" -Type Warning
        return $null
    }
}

function Get-ChromeExtensionCrx {
    <#
    .SYNOPSIS
        Download a CRX file from Chrome Web Store.
    .DESCRIPTION
        Downloads an extension from Chrome Web Store and saves it as a .crx file.
        Optionally checks if the current version is up to date before downloading.
    #>
    param(
        [Parameter(Mandatory)][string]$ExtensionId,
        [string]$CurrentVersion,
        [string]$OutPath = "."
    )

    $latest = Get-ChromeExtensionVersion $ExtensionId
    if (-not $latest) {
        Write-Status "Could not get latest version for extension $ExtensionId" -Type Error
        return $null
    }

    # Compare versions if current version provided
    if ($CurrentVersion) {
        $lParts = $latest -split '\.' | ForEach-Object { [int]$_ }
        $cParts = $CurrentVersion -split '\.' | ForEach-Object { [int]$_ }
        $newer = $false

        for ($i = 0; $i -lt [Math]::Max($lParts.Count, $cParts.Count); $i++) {
            $l = if ($i -lt $lParts.Count) { $lParts[$i] } else { 0 }
            $c = if ($i -lt $cParts.Count) { $cParts[$i] } else { 0 }

            if ($l -gt $c) {
                $newer = $true
                break
            }
            if ($l -lt $c) {
                break
            }
        }

        if (-not $newer) {
            Write-Status "Extension $ExtensionId is up to date (current: $CurrentVersion, latest: $latest)" -Type Success
            return $null
        }
    }

    # Build download URL
    $downloadUrl = "https://clients2.google.com/service/update2/crx?response=redirect&os=win&arch=x86-64&os_arch=x86-64&prod=chromecrx&prodchannel=unknown&prodversion=120.0.0.0&acceptformat=crx3&x=id%3D$ExtensionId%26uc"
    $outFile = Join-Path $OutPath "$ExtensionId`_$latest.crx"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $outFile -UseBasicParsing -TimeoutSec 120 -Headers @{
            "User-Agent" = $script:UserAgent
            Referer      = "https://chrome.google.com/webstore/detail/$ExtensionId"
        }

        if ((Get-Item $outFile).Length -gt 0) {
            Write-Status "Downloaded: $outFile (v$latest)" -Type Success
            return $outFile
        }
        else {
            Remove-Item $outFile -Force
            Write-Status "Download failed - file is empty" -Type Error
            return $null
        }
    }
    catch {
        Write-Status "Failed to download extension: $_" -Type Error
        if (Test-Path $outFile) {
            Remove-Item $outFile -Force
        }
        return $null
    }
}

#endregion

#region Comet Management

function Get-CometInstallation {
    <#
    .SYNOPSIS
        Find existing Comet installation or return null.
    #>

    $searchPaths = @(
        (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\Application\comet.exe"),
        (Join-Path $env:LOCALAPPDATA "Comet\Application\comet.exe"),
        (Join-Path $env:ProgramFiles "Comet\Application\comet.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Comet\Application\comet.exe")
    )

    foreach ($path in $searchPaths) {
        if ($path -and (Test-Path $path)) {
            return @{
                Executable = $path
                Directory  = Split-Path -Parent $path
            }
        }
    }

    # Try where.exe
    try {
        $whereResult = & where.exe comet 2>$null
        if ($whereResult) {
            $exe = ($whereResult -split "`n")[0].Trim()
            return @{
                Executable = $exe
                Directory  = Split-Path -Parent $exe
            }
        }
    }
    catch {
        # where.exe not available or failed - continue to return $null
        $null = $_.Exception
    }

    return $null
}

function Get-CometVersion {
    <#
    .SYNOPSIS
        Get version information from Comet executable.
    #>
    param([string]$ExePath)

    try {
        $versionInfo = (Get-Item $ExePath).VersionInfo
        return $versionInfo.FileVersion
    }
    catch {
        return $null
    }
}

function Install-Comet {
    <#
    .SYNOPSIS
        Download and install Comet browser.
    #>
    param(
        [string]$DownloadUrl,
        [switch]$DryRunMode
    )

    Write-Status "Comet browser not found. Downloading..." -Type Info

    if ($DryRunMode) {
        Write-Status "Would download from: $DownloadUrl" -Type Detail
        return $null
    }

    $tempInstaller = Join-Path $env:TEMP "CometSetup_$(Get-Random).exe"

    try {
        Write-Status "Downloading from: $DownloadUrl" -Type Detail

        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", $script:UserAgent)
        $webClient.DownloadFile($DownloadUrl, $tempInstaller)

        Write-Status "Running installer..." -Type Info
        $process = Start-Process -FilePath $tempInstaller -ArgumentList "/S" -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            Write-Status "Installer exited with code: $($process.ExitCode)" -Type Warning
        }

        # Wait for installation to complete and find the executable
        Start-Sleep -Seconds 5
        return Get-CometInstallation
    }
    catch {
        Write-Status "Failed to install Comet: $_" -Type Error
        return $null
    }
    finally {
        if (Test-Path $tempInstaller) {
            Remove-Item -Path $tempInstaller -Force
        }
    }
}

function Test-CometUpdate {
    <#
    .SYNOPSIS
        Check if a newer version of Comet is available by querying the download endpoint.
    #>
    param(
        [string]$CurrentVersion,
        [string]$DownloadUrl
    )

    if (-not $DownloadUrl -or -not $CurrentVersion) {
        return $null
    }

    try {
        $latestVersion = $null

        # Make HEAD request to get final redirect URL or Content-Disposition
        $response = Invoke-WebRequest -Uri $DownloadUrl -Method Head -UseBasicParsing -MaximumRedirection 5 -Headers @{
            "User-Agent" = $script:UserAgent
        }

        # Try to extract version from Content-Disposition header
        $disposition = $response.Headers["Content-Disposition"]
        if ($disposition) {
            # Look for version pattern in filename (e.g., comet-1.2.3.exe or CometSetup_1.2.3.exe)
            if ($disposition -match '[\-_](\d+\.\d+\.\d+(?:\.\d+)?)') {
                $latestVersion = $Matches[1]
            }
        }

        # Also check the final URL for version info
        if (-not $latestVersion -and $response.BaseResponse.ResponseUri) {
            $finalUrl = $response.BaseResponse.ResponseUri.ToString()
            if ($finalUrl -match '[\-_/](\d+\.\d+\.\d+(?:\.\d+)?)') {
                $latestVersion = $Matches[1]
            }
        }

        if ($latestVersion) {
            $comparison = Compare-Versions -Version1 $latestVersion -Version2 $CurrentVersion
            if ($comparison -gt 0) {
                return @{
                    Version     = $latestVersion
                    DownloadUrl = $DownloadUrl
                }
            }
        }
    }
    catch {
        Write-Status "Failed to check for Comet updates: $_" -Type Warning
    }

    return $null
}

#endregion

#region uBlock Origin

function Get-UBlockOrigin {
    <#
    .SYNOPSIS
        Download uBlock Origin MV2 from Chrome Web Store if not present or outdated.
    .DESCRIPTION
        Downloads the extension from Chrome Web Store, extracts it, and configures
        the auto-import system for applying Meteor defaults.
    #>
    param(
        [string]$OutputDir,
        [object]$UBlockConfig,
        [switch]$DryRunMode
    )

    $extensionId = $UBlockConfig.extension_id
    $manifestPath = Join-Path $OutputDir "manifest.json"
    $currentVersion = $null

    # Check if already installed
    if ((Test-Path $OutputDir) -and (Test-Path $manifestPath)) {
        $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
        $currentVersion = $manifest.version
        Write-Status "uBlock Origin $currentVersion installed, checking for updates..." -Type Info
    }
    else {
        Write-Status "uBlock Origin not found, downloading..." -Type Info
    }

    try {
        # Handle dry run mode
        if ($DryRunMode) {
            if ($currentVersion) {
                Write-Status "Would check for uBlock Origin updates" -Type Detail
            }
            else {
                Write-Status "Would download uBlock Origin from Chrome Web Store" -Type Detail
            }
            Write-Status "Would apply uBlock auto-import configuration" -Type Detail
            return $null
        }

        # Download CRX (will skip if up to date)
        $tempDir = Join-Path $env:TEMP "ublock_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $tempDir -Force
        $crxFile = Get-ChromeExtensionCrx -ExtensionId $extensionId -CurrentVersion $currentVersion -OutPath $tempDir

        if (-not $crxFile) {
            # Either up to date or download failed
            if ($currentVersion) {
                # Already have a version installed, skip to configuration
                Write-Status "uBlock Origin is up to date ($currentVersion)" -Type Success
            }
            else {
                throw "Failed to download uBlock Origin"
            }
        }
        else {
            # Extract CRX
            Write-Status "Extracting uBlock Origin..." -Type Detail

            # Remove existing directory
            if (Test-Path $OutputDir) {
                Remove-Item $OutputDir -Recurse -Force
            }

            # Extract CRX to output directory (with key injection for consistent extension ID)
            Export-CrxToDirectory -CrxPath $crxFile -OutputDir $OutputDir -InjectKey

            # Cleanup temp directory
            if (Test-Path $tempDir) {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-Status "uBlock Origin installed successfully" -Type Success
        }

        # Apply defaults if configured - using auto-import approach
        # Only run if uBlock directory and js/ subdirectory exist (either just extracted or previously installed)
        if ($UBlockConfig.defaults -and (Test-Path $OutputDir)) {
            $jsDir = Join-Path $OutputDir "js"

            # Ensure js/ directory exists before attempting configuration
            if (-not (Test-Path $jsDir)) {
                Write-Status "uBlock js/ directory not found, skipping auto-import configuration" -Type Warning
            }
            else {
                # Save settings file that auto-import.js will load
                $settingsPath = Join-Path $OutputDir "ublock-settings.json"
                $UBlockConfig.defaults | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding UTF8

                # Get custom filter lists for the auto-import check
                $customLists = $UBlockConfig.defaults.selectedFilterLists | Where-Object { $_ -match '^https?://' }
                $customListsJson = $customLists | ConvertTo-Json -Compress

                # Create auto-import.js that applies settings on first run
                $autoImportPath = Join-Path $jsDir "auto-import.js"
            $autoImportCode = @"
/*******************************************************************************

    Meteor - Auto-import custom defaults on first run

*******************************************************************************/

import µb from './background.js';
import io from './assets.js';

/******************************************************************************/

const customFilterLists = $customListsJson;

const checkAndImport = async () => {
    try {
        await µb.isReadyPromise;

        const stored = await vAPI.storage.get(['lastRestoreFile', 'importedLists']);

        if (stored.lastRestoreFile === 'meteor-auto-import') {
            console.log('[Meteor] uBlock settings already imported, skipping');
            return;
        }

        const importedLists = stored.importedLists || [];
        const allPresent = customFilterLists.every(url => importedLists.includes(url));

        if (allPresent) {
            console.log('[Meteor] Custom lists already imported, skipping');
            return;
        }

        console.log('[Meteor] Importing uBlock settings...');

        const response = await fetch('/ublock-settings.json');
        if (!response.ok) {
            console.error('[Meteor] Failed to load ublock-settings.json');
            return;
        }

        const userData = await response.json();

        console.log('[Meteor] Applying uBlock settings...');

        io.rmrf();

        await vAPI.storage.set({
            ...userData.userSettings,
            netWhitelist: userData.whitelist || [],
            dynamicFilteringString: userData.dynamicFilteringString || '',
            urlFilteringString: userData.urlFilteringString || '',
            hostnameSwitchesString: userData.hostnameSwitchesString || '',
            lastRestoreFile: 'meteor-auto-import',
            lastRestoreTime: Date.now()
        });

        if (userData.userFilters) {
            await µb.saveUserFilters(userData.userFilters);
        }

        if (Array.isArray(userData.selectedFilterLists)) {
            await µb.saveSelectedFilterLists(userData.selectedFilterLists);
        }

        console.log('[Meteor] uBlock settings applied, restarting...');

        vAPI.app.restart();

    } catch (ex) {
        console.error('[Meteor] Error importing uBlock settings:', ex);
    }
};

setTimeout(checkAndImport, 3000);

/******************************************************************************/
"@
            Set-Content -Path $autoImportPath -Value $autoImportCode -Encoding UTF8

            # Patch start.js to import auto-import.js
            $startJsPath = Join-Path $jsDir "start.js"
            if (Test-Path $startJsPath) {
                $startContent = Get-Content -Path $startJsPath -Raw
                if ($startContent -notmatch "import './auto-import.js';") {
                    # Find last import statement and add our import after it
                    $importPattern = "(import .+ from .+;)\n"
                    $importMatches = [regex]::Matches($startContent, $importPattern)
                    if ($importMatches.Count -gt 0) {
                        $lastMatch = $importMatches[$importMatches.Count - 1]
                        $insertPos = $lastMatch.Index + $lastMatch.Length
                        $newContent = $startContent.Substring(0, $insertPos) + "import './auto-import.js';`n" + $startContent.Substring($insertPos)
                        Set-Content -Path $startJsPath -Value $newContent -Encoding UTF8 -NoNewline
                    }
                }
            }

                Write-Status "uBlock auto-import configured" -Type Detail
            }
        }

        return $OutputDir
    }
    catch {
        Write-Status "Failed to get uBlock Origin: $_" -Type Error
        if ($currentVersion) {
            Write-Status "Continuing with existing installation ($currentVersion)" -Type Warning
            return $OutputDir
        }
        return $null
    }
}

function Get-AdGuardExtra {
    <#
    .SYNOPSIS
        Download AdGuard Extra from Chrome Web Store if not present or outdated.
    .DESCRIPTION
        Downloads the extension from Chrome Web Store, extracts it, and ensures it's
        enabled in both regular and incognito modes by default.
    #>
    param(
        [string]$OutputDir,
        [object]$AdGuardConfig,
        [switch]$DryRunMode
    )

    $extensionId = $AdGuardConfig.extension_id
    $manifestPath = Join-Path $OutputDir "manifest.json"
    $currentVersion = $null

    # Check if already installed
    if ((Test-Path $OutputDir) -and (Test-Path $manifestPath)) {
        $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
        $currentVersion = $manifest.version
        Write-Status "AdGuard Extra $currentVersion installed, checking for updates..." -Type Info
    }
    else {
        Write-Status "AdGuard Extra not found, downloading..." -Type Info
    }

    try {
        # Handle dry run mode
        if ($DryRunMode) {
            if ($currentVersion) {
                Write-Status "Would check for AdGuard Extra updates" -Type Detail
            }
            else {
                Write-Status "Would download AdGuard Extra from Chrome Web Store" -Type Detail
            }
            return $null
        }

        # Download CRX (will skip if up to date)
        $tempDir = Join-Path $env:TEMP "adguard_extra_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $tempDir -Force
        $crxFile = Get-ChromeExtensionCrx -ExtensionId $extensionId -CurrentVersion $currentVersion -OutPath $tempDir

        if (-not $crxFile) {
            # Either up to date or download failed
            if ($currentVersion) {
                # Already have a version installed
                return $OutputDir
            }
            throw "Failed to download AdGuard Extra"
        }

        # Extract CRX
        Write-Status "Extracting AdGuard Extra..." -Type Detail

        # Remove existing directory
        if (Test-Path $OutputDir) {
            Remove-Item $OutputDir -Recurse -Force
        }

        # Extract CRX to output directory (with key injection for consistent extension ID)
        Export-CrxToDirectory -CrxPath $crxFile -OutputDir $OutputDir -InjectKey

        # Cleanup temp directory
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Status "AdGuard Extra installed successfully" -Type Success
        return $OutputDir
    }
    catch {
        Write-Status "Failed to get AdGuard Extra: $_" -Type Error
        if ($currentVersion) {
            Write-Status "Continuing with existing installation ($currentVersion)" -Type Warning
            return $OutputDir
        }
        return $null
    }
}

#endregion

#region Extension Patching

function Initialize-PatchedExtensions {
    <#
    .SYNOPSIS
        Extract and patch extensions from Comet's default_apps.
    #>
    param(
        [string]$CometDir,
        [string]$OutputDir,
        [string]$PatchesDir,
        [object]$PatchConfig,
        [switch]$DryRunMode
    )

    $defaultAppsDir = Join-Path $CometDir "default_apps"

    if (-not (Test-Path $defaultAppsDir)) {
        # Try version subdirectory
        $versionDirs = Get-ChildItem -Path $CometDir -Directory -ErrorAction SilentlyContinue
        foreach ($vDir in $versionDirs) {
            $subDefaultApps = Join-Path $vDir.FullName "default_apps"
            if (Test-Path $subDefaultApps) {
                $defaultAppsDir = $subDefaultApps
                break
            }
        }
    }

    if (-not (Test-Path $defaultAppsDir)) {
        Write-Status "default_apps directory not found in: $CometDir" -Type Error
        return $false
    }

    Write-Status "Source: $defaultAppsDir" -Type Detail
    Write-Status "Output: $OutputDir" -Type Detail

    if (-not (Test-Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
    }

    # Find and process CRX files (prefer active .crx over .crx.disabled)
    $crxSources = @{}

    # First collect .crx.disabled files
    $disabledFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx.disabled" -ErrorAction SilentlyContinue
    foreach ($file in $disabledFiles) {
        $baseName = $file.Name -replace '\.crx\.disabled$', ''
        $crxSources[$baseName] = $file
    }

    # Then collect active .crx files (these override .disabled versions)
    $activeFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue
    foreach ($file in $activeFiles) {
        $baseName = $file.Name -replace '\.crx$', ''
        $crxSources[$baseName] = $file
    }

    foreach ($extName in $crxSources.Keys | Sort-Object) {
        $crx = $crxSources[$extName]
        $extOutputDir = Join-Path $OutputDir $extName

        Write-Status "Processing: $extName" -Type Info

        if ($DryRunMode) {
            Write-Status "Would extract to: $extOutputDir" -Type Detail
            continue
        }

        # Extract CRX and inject public key for consistent extension ID
        Export-CrxToDirectory -CrxPath $crx.FullName -OutputDir $extOutputDir -InjectKey
        Write-Status "Extracted to: $extOutputDir" -Type Detail

        # Apply patches if configured (check property exists to avoid StrictMode error)
        if ($PatchConfig.PSObject.Properties[$extName]) {
            $config = $PatchConfig.$extName

            # Copy additional files
            if ($config.PSObject.Properties['copy_files']) {
                foreach ($destFile in $config.copy_files.PSObject.Properties) {
                    $destPath = Join-Path $extOutputDir $destFile.Name
                    $srcPath = Resolve-MeteorPath -BasePath $PatchesDir -RelativePath $destFile.Value

                    # Ensure directory exists
                    $destDir = Split-Path -Parent $destPath
                    if (-not (Test-Path $destDir)) {
                        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                    }

                    if (Test-Path $srcPath) {
                        Copy-Item -Path $srcPath -Destination $destPath -Force
                        Write-Status "Copied: $($destFile.Name)" -Type Detail
                    }
                    else {
                        Write-Status "Source not found: $srcPath" -Type Warning
                    }
                }
            }

            # Apply manifest additions
            if ($config.PSObject.Properties['manifest_additions']) {
                $manifestPath = Join-Path $extOutputDir "manifest.json"
                if (Test-Path $manifestPath) {
                    $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json

                    # Add declarative_net_request
                    if ($config.manifest_additions.PSObject.Properties['declarative_net_request']) {
                        if (-not $manifest.PSObject.Properties['declarative_net_request']) {
                            $manifest | Add-Member -NotePropertyName "declarative_net_request" -NotePropertyValue ([PSCustomObject]@{})
                        }

                        $dnr = $config.manifest_additions.declarative_net_request
                        if ($dnr.PSObject.Properties['rule_resources']) {
                            if (-not $manifest.declarative_net_request.PSObject.Properties['rule_resources']) {
                                $manifest.declarative_net_request | Add-Member -NotePropertyName "rule_resources" -NotePropertyValue @()
                            }

                            $existingResources = @($manifest.declarative_net_request.rule_resources)
                            $newResources = @($dnr.rule_resources)
                            $manifest.declarative_net_request.rule_resources = $existingResources + $newResources
                        }
                    }

                    # Add content_scripts
                    if ($config.manifest_additions.PSObject.Properties['content_scripts']) {
                        if (-not $manifest.PSObject.Properties['content_scripts']) {
                            $manifest | Add-Member -NotePropertyName "content_scripts" -NotePropertyValue @()
                        }

                        $existingScripts = @($manifest.content_scripts)
                        $newScripts = @($config.manifest_additions.content_scripts)
                        $manifest.content_scripts = $existingScripts + $newScripts
                    }

                    $manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8
                    Write-Status "Applied manifest patches" -Type Detail
                }
            }

            # Modify service-worker-loader.js
            if ($config.PSObject.Properties['service_worker_import']) {
                $loaderPath = Join-Path $extOutputDir "service-worker-loader.js"
                if (Test-Path $loaderPath) {
                    $content = Get-Content -Path $loaderPath -Raw -Encoding UTF8

                    if ($content -notmatch [regex]::Escape($config.service_worker_import)) {
                        $modified = "import './$($config.service_worker_import)';  // Meteor preference enforcement`n$content"
                        Set-Content -Path $loaderPath -Value $modified -Encoding UTF8 -NoNewline
                        Write-Status "Modified service-worker-loader.js" -Type Detail
                    }
                }
            }
        }
    }

    return $true
}

#endregion

#region PAK Processing

function Initialize-PakModifications {
    <#
    .SYNOPSIS
        Apply content-based modifications to resources.pak.
        Searches all text resources for matching patterns and applies replacements.
    #>
    param(
        [string]$CometDir,
        [object]$PakConfig,
        [switch]$DryRunMode
    )

    if (-not $PakConfig.enabled) {
        Write-Status "PAK modifications disabled in config" -Type Detail
        return $true
    }

    # 1. Locate resources.pak
    $pakPath = Join-Path $CometDir "resources.pak"
    if (-not (Test-Path $pakPath)) {
        $versionDirs = Get-ChildItem -Path $CometDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+' }
        foreach ($dir in $versionDirs) {
            $testPath = Join-Path $dir.FullName "resources.pak"
            if (Test-Path $testPath) {
                $pakPath = $testPath
                break
            }
        }
    }

    if (-not (Test-Path $pakPath)) {
        Write-Status "resources.pak not found - skipping PAK modifications" -Type Warning
        return $true
    }

    Write-Status "Found resources.pak: $pakPath" -Type Detail

    # 2. Read and parse PAK
    try {
        $pak = Read-PakFile -Path $pakPath
        Write-Status "Parsed PAK v$($pak.Version) with $($pak.Resources.Count - 1) resources" -Type Detail
    }
    catch {
        Write-Status "Failed to parse PAK: $_" -Type Error
        return $false
    }

    # 3. Search all resources and apply modifications
    $modifiedResources = @{}
    $appliedCount = 0

    # Iterate through all resources (skip sentinel at end)
    for ($i = 0; $i -lt $pak.Resources.Count - 1; $i++) {
        $resource = $pak.Resources[$i]
        $resourceId = $resource.Id

        # Get resource bytes
        $resourceBytes = Get-PakResource -Pak $pak -ResourceId $resourceId
        if ($null -eq $resourceBytes) { continue }

        # Try to decode as UTF-8 text (skip binary resources)
        try {
            $content = [System.Text.Encoding]::UTF8.GetString($resourceBytes)
            # Skip if it looks like binary (has null bytes or non-printable chars)
            if ($content -match '[\x00-\x08\x0E-\x1F]') { continue }
        }
        catch {
            continue
        }

        $resourceModified = $false

        # Try each modification pattern
        foreach ($mod in $PakConfig.modifications) {
            if ($content -match $mod.pattern) {
                $content = $content -replace $mod.pattern, $mod.replacement
                Write-Status "  Resource $resourceId - $($mod.description)" -Type Detail
                $resourceModified = $true
                $appliedCount++
            }
        }

        # Track modified resources
        if ($resourceModified) {
            $modifiedResources[$resourceId] = $content
        }
    }

    # 4. Apply all modifications to PAK structure
    $modified = $false
    foreach ($resourceId in $modifiedResources.Keys) {
        $newContent = $modifiedResources[$resourceId]
        $newBytes = [System.Text.Encoding]::UTF8.GetBytes($newContent)

        if ($DryRunMode) {
            Write-Status "Would modify resource $resourceId" -Type DryRun
        }
        else {
            $success = Set-PakResource -Pak $pak -ResourceId $resourceId -NewData $newBytes
            if ($success) {
                $modified = $true
            }
            else {
                Write-Status "Failed to set resource $resourceId" -Type Error
            }
        }
    }

    # 5. Write modified PAK (with backup)
    if ($modified -and -not $DryRunMode) {
        $backupPath = "$pakPath.meteor-backup"

        if (-not (Test-Path $backupPath)) {
            Copy-Item -Path $pakPath -Destination $backupPath -Force
            Write-Status "Created backup: $backupPath" -Type Detail
        }

        try {
            Write-PakFile -Pak $pak -Path $pakPath
            Write-Status "Wrote modified PAK ($($modifiedResources.Count) resources, $appliedCount modifications)" -Type Success
        }
        catch {
            Write-Status "Failed to write PAK: $_" -Type Error
            if (Test-Path $backupPath) {
                Copy-Item -Path $backupPath -Destination $pakPath -Force
                Write-Status "Restored from backup" -Type Warning
            }
            return $false
        }
    }
    elseif ($appliedCount -eq 0) {
        Write-Status "PAK modifications: No matching patterns found" -Type Warning
    }

    return $true
}

#endregion

#region Preferences Pre-seeding

function Set-BrowserPreferences {
    <#
    .SYNOPSIS
        Pre-seed browser Preferences file with critical settings.
    .DESCRIPTION
        Settings like extensions.ui.developer_mode must be set BEFORE the browser
        loads extensions, otherwise unpacked extensions (loaded via --load-extension)
        will fail with "requires developer mode" errors.

        The service worker (meteor-prefs.js) runs too late - after startup checks.
        This function pre-seeds the Preferences file before launch.
    #>
    param(
        [string]$ProfileName = "Default",
        [switch]$DryRunMode
    )

    # Determine User Data path
    $userDataPaths = @(
        (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data"),
        (Join-Path $env:LOCALAPPDATA "Comet\User Data")
    )

    $userDataPath = $null
    foreach ($path in $userDataPaths) {
        if (Test-Path $path) {
            $userDataPath = $path
            break
        }
    }

    if (-not $userDataPath) {
        # User Data doesn't exist yet - will be created on first run
        # Create it now so we can pre-seed Preferences
        $userDataPath = $userDataPaths[0]
        if (-not $DryRunMode) {
            $null = New-Item -ItemType Directory -Path $userDataPath -Force
        }
    }

    $profilePath = Join-Path $userDataPath $ProfileName
    $prefsPath = Join-Path $profilePath "Preferences"
    $firstRunPath = Join-Path $userDataPath "First Run"

    if ($DryRunMode) {
        Write-Status "Would pre-seed Preferences at: $prefsPath" -Type DryRun
        return $true
    }

    # Ensure profile directory exists
    if (-not (Test-Path $profilePath)) {
        $null = New-Item -ItemType Directory -Path $profilePath -Force
    }

    # Create "First Run" sentinel file to skip first-run dialogs
    # Chromium checks for this file's existence, not its contents
    if (-not (Test-Path $firstRunPath)) {
        $null = New-Item -ItemType File -Path $firstRunPath -Force
    }

    # Critical settings that must be set before startup
    # These cannot be effectively set by meteor-prefs.js (runs too late)

    # uBlock Origin extension ID (fixed ID from Chrome Web Store)
    $ublockExtId = "cjpalhdlnbpafiamejdnhcphjbkeiagm"

    # NOTE: Chrome does not allow programmatically enabling extensions in incognito mode.
    # Per Chrome Enterprise docs: "As an admin, you can't automatically install extensions
    # in Incognito mode." Any incognito settings written to Preferences are rejected by
    # Chrome's HMAC protection and added to tracked_preferences_reset.
    # Users must manually enable via chrome://extensions → Details → Allow in incognito.

    $criticalSettings = @{
        extensions   = @{
            ui                = @{
                developer_mode = $true
            }
            # Pin uBlock Origin to toolbar
            pinned_extensions = @($ublockExtId)
            settings          = @{
                $ublockExtId  = @{
                    toolbar_pin = "force_pinned"
                }
            }
        }
        # Note: signin.allowed is NOT set here - allow sign-in but disable sync
        sync         = @{
            managed = $true
        }
        browser      = @{
            show_home_button = $true
        }
        bookmark_bar = @{
            show_apps_shortcut = $false
        }
        # Perplexity-specific settings
        perplexity   = @{
            onboarding_completed = $true
            metrics_allowed      = $false
        }
    }

    try {
        # CRITICAL: Only set HMAC-protected preferences on FIRST RUN.
        # Chromium uses HMAC signatures in "Secure Preferences" to detect tampering.
        # If we modify Preferences after the browser has run, the HMAC becomes invalid,
        # which can cause crashes (especially when opening the browser menu).
        # See: https://www.cse.chalmers.se/~andrei/cans20.pdf
        $isFirstRun = -not (Test-Path $prefsPath)

        if (-not $isFirstRun) {
            Write-Status "Preferences already exist - skipping to avoid HMAC validation issues" -Type Detail
            return $true
        }

        $prefs = @{}

        # Deep merge critical settings (only on first run)
        $prefs = Merge-Hashtables -Base $prefs -Override $criticalSettings

        # Write preferences
        $json = $prefs | ConvertTo-Json -Depth 20 -Compress
        Set-Content -Path $prefsPath -Value $json -Encoding UTF8 -Force

        Write-Status "Browser preferences pre-seeded (developer mode enabled)" -Type Success
        return $true
    }
    catch {
        Write-Status "Failed to pre-seed preferences: $_" -Type Warning
        return $false
    }
}

function Convert-PSObjectToHashtable {
    <#
    .SYNOPSIS
        Convert PSCustomObject to hashtable (for PS 5.1 compatibility).
    #>
    param([object]$Object)

    if ($null -eq $Object) { return @{} }
    if ($Object -is [hashtable]) { return $Object }
    if ($Object -is [array]) { return @($Object | ForEach-Object { Convert-PSObjectToHashtable $_ }) }
    if ($Object -is [PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $Object.PSObject.Properties) {
            $hash[$prop.Name] = Convert-PSObjectToHashtable $prop.Value
        }
        return $hash
    }
    return $Object
}

function Merge-Hashtables {
    <#
    .SYNOPSIS
        Deep merge two hashtables, with Override taking precedence.
    #>
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )

    if ($null -eq $Base) { $Base = @{} }
    $result = $Base.Clone()

    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and
            $result[$key] -is [hashtable] -and
            $Override[$key] -is [hashtable]) {
            # Recursive merge for nested hashtables
            $result[$key] = Merge-Hashtables -Base $result[$key] -Override $Override[$key]
        }
        else {
            $result[$key] = $Override[$key]
        }
    }

    return $result
}

#endregion

#region Browser Launch

function Build-BrowserCommand {
    <#
    .SYNOPSIS
        Build the browser command line with all flags.
    #>
    param(
        [object]$Config,
        [string]$BrowserExe,
        [string]$ExtPath,
        [string]$UBlockPath,
        [string]$AdGuardExtraPath
    )

    $cmd = [System.Collections.ArrayList]@()
    [void]$cmd.Add($BrowserExe)

    $browserConfig = $Config.browser

    # Add profile directory if specified
    if ($browserConfig.profile) {
        [void]$cmd.Add("--profile-directory=$($browserConfig.profile)")
    }

    # Add explicit flags
    foreach ($flag in $browserConfig.flags) {
        [void]$cmd.Add($flag)
    }

    # Build --enable-features
    if ($browserConfig.enable_features -and $browserConfig.enable_features.Count -gt 0) {
        $enableFeatures = $browserConfig.enable_features -join ","
        [void]$cmd.Add("--enable-features=$enableFeatures")
    }

    # Build --disable-features
    if ($browserConfig.disable_features -and $browserConfig.disable_features.Count -gt 0) {
        $disableFeatures = $browserConfig.disable_features -join ","
        [void]$cmd.Add("--disable-features=$disableFeatures")
    }

    # Build extension list
    $extensions = [System.Collections.ArrayList]@()

    # Add patched extensions
    foreach ($extName in $Config.extensions.sources) {
        $extDir = Join-Path $ExtPath $extName
        if (Test-Path $extDir) {
            [void]$extensions.Add($extDir)
        }
    }

    # Add uBlock Origin
    if ($UBlockPath -and (Test-Path $UBlockPath)) {
        [void]$extensions.Add($UBlockPath)
    }

    # Add AdGuard Extra
    if ($AdGuardExtraPath -and (Test-Path $AdGuardExtraPath)) {
        [void]$extensions.Add($AdGuardExtraPath)
    }

    if ($extensions.Count -gt 0) {
        $extList = $extensions -join ","
        [void]$cmd.Add("--load-extension=$extList")
    }

    return $cmd
}

function Start-Browser {
    <#
    .SYNOPSIS
        Launch the browser with the built command.
    #>
    param(
        [array]$Command,
        [switch]$DryRunMode
    )

    if ($DryRunMode) {
        Write-Host ""
        Write-Status "Would launch with command:" -Type Info
        Write-Host $Command[0]
        Write-Host "Flags: $($Command.Count - 1)"
        return $null
    }

    $exe = $Command[0]
    $processArgs = $Command[1..($Command.Count - 1)]

    $process = Start-Process -FilePath $exe -ArgumentList $processArgs -PassThru
    return $process
}

#endregion

#region Main

function Main {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           Meteor v2 - Privacy Enhancement System              ║" -ForegroundColor Cyan
    Write-Host "║                     Version $script:MeteorVersion                          ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # Determine paths
    $scriptDir = Split-Path -Parent $PSCommandPath
    $baseDir = $scriptDir

    # Load config
    $configPath = if ($Config) { $Config } else { Join-Path $baseDir "config.json" }
    $config = Get-MeteorConfig -ConfigPath $configPath

    # Resolve paths
    $patchedExtPath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.patched_extensions
    $ublockPath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.ublock
    $adguardExtraPath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.adguard_extra
    $statePath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.state_file
    $patchesPath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.patches

    # Load state
    $state = Get-MeteorState -StatePath $statePath

    if ($DryRun) {
        Write-Status "DRY RUN MODE - No changes will be made" -Type Warning
        Write-Host ""
    }

    # Kill running Comet processes if -Force is specified
    if ($Force) {
        $cometProcesses = Get-Process -Name "comet" -ErrorAction SilentlyContinue
        if ($cometProcesses) {
            if ($DryRun) {
                Write-Status "Would stop $($cometProcesses.Count) running Comet process(es)" -Type DryRun
            }
            else {
                Write-Status "Stopping $($cometProcesses.Count) running Comet process(es)..." -Type Warning
                $cometProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500  # Brief pause for file handles to release
                Write-Status "Comet processes stopped" -Type Success
            }
        }

        # Delete Preferences files to force fresh settings on next launch
        # This ensures extension incognito settings are written correctly
        $userDataPaths = @(
            (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data"),
            (Join-Path $env:LOCALAPPDATA "Comet\User Data")
        )

        foreach ($userDataPath in $userDataPaths) {
            if (Test-Path $userDataPath) {
                $profileName = if ($config.browser.profile) { $config.browser.profile } else { "Default" }
                $profilePath = Join-Path $userDataPath $profileName
                $prefsPath = Join-Path $profilePath "Preferences"
                $securePrefsPath = Join-Path $profilePath "Secure Preferences"

                if (Test-Path $prefsPath) {
                    if ($DryRun) {
                        Write-Status "Would delete: $prefsPath" -Type DryRun
                    }
                    else {
                        Remove-Item -Path $prefsPath -Force -ErrorAction SilentlyContinue
                        Write-Status "Deleted Preferences file" -Type Detail
                    }
                }

                if (Test-Path $securePrefsPath) {
                    if ($DryRun) {
                        Write-Status "Would delete: $securePrefsPath" -Type DryRun
                    }
                    else {
                        Remove-Item -Path $securePrefsPath -Force -ErrorAction SilentlyContinue
                        Write-Status "Deleted Secure Preferences file" -Type Detail
                    }
                }
            }
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 0: Comet Installation
    # ═══════════════════════════════════════════════════════════════
    Write-Status "Step 0: Checking Comet Installation" -Type Step

    $comet = Get-CometInstallation

    if (-not $comet) {
        $comet = Install-Comet -DownloadUrl $config.comet.download_url -DryRunMode:$DryRun
    }

    if (-not $comet -and -not $DryRun) {
        Write-Status "Could not find or install Comet browser" -Type Error
        exit 1
    }

    if ($comet) {
        Write-Status "Comet found: $($comet.Executable)" -Type Success
        $cometVersion = Get-CometVersion -ExePath $comet.Executable
        Write-Status "Version: $cometVersion" -Type Detail
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 1: Comet Update Check
    # ═══════════════════════════════════════════════════════════════
    Write-Status "Step 1: Checking for Comet Updates" -Type Step

    if ($config.comet.auto_update -and $comet) {
        $updateInfo = Test-CometUpdate -CurrentVersion $cometVersion -DownloadUrl $config.comet.download_url

        if ($updateInfo) {
            Write-Status "Update available: $($updateInfo.Version) (current: $cometVersion)" -Type Warning
            if (-not $DryRun) {
                Write-Status "Downloading Comet update..." -Type Info
                $newComet = Install-Comet -DownloadUrl $config.comet.download_url -DryRunMode:$DryRun
                if ($newComet) {
                    $comet = $newComet
                    $cometVersion = Get-CometVersion -ExePath $comet.Executable
                    Write-Status "Updated to version: $cometVersion" -Type Success
                }
            }
            else {
                Write-Status "Would download and install Comet $($updateInfo.Version)" -Type DryRun
            }
        }
        else {
            Write-Status "Comet is up to date" -Type Success
        }
    }
    else {
        Write-Status "Auto-update disabled or Comet not installed" -Type Detail
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 2: Extension Update Check
    # ═══════════════════════════════════════════════════════════════
    Write-Status "Step 2: Checking for Extension Updates" -Type Step

    $extensionsUpdated = $false
    if ($config.extensions.check_updates -and $comet) {
        $defaultAppsDir = Join-Path $comet.Directory "default_apps"
        if (Test-Path $defaultAppsDir) {
            $crxFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue
            foreach ($crx in $crxFiles) {
                $manifest = Get-CrxManifest -CrxPath $crx.FullName
                if (-not $manifest) { continue }

                $extId = if ($manifest.key) {
                    # Generate extension ID from public key
                    $keyBytes = [Convert]::FromBase64String($manifest.key)
                    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($keyBytes)
                    $idChars = $hash[0..15] | ForEach-Object { [char](97 + ($_ % 26)) }
                    -join $idChars
                }
                else { $null }

                $updateUrl = $manifest.update_url
                $currentVersion = $manifest.version

                if ($extId -and $updateUrl -and $currentVersion) {
                    Write-Status "Checking $($manifest.name)..." -Type Detail
                    $extUpdate = Get-ExtensionUpdateInfo -UpdateUrl $updateUrl -ExtensionId $extId -CurrentVersion $currentVersion

                    if ($extUpdate -and $extUpdate.Version -and $extUpdate.Codebase) {
                        $comparison = Compare-Versions -Version1 $extUpdate.Version -Version2 $currentVersion
                        if ($comparison -gt 0) {
                            Write-Status "  Update available: $currentVersion -> $($extUpdate.Version)" -Type Info
                            if (-not $DryRun) {
                                try {
                                    $tempCrx = Join-Path $env:TEMP "meteor_ext_$(Get-Random).crx"
                                    Invoke-WebRequest -Uri $extUpdate.Codebase -OutFile $tempCrx -UseBasicParsing -Headers @{
                                        "User-Agent" = $script:UserAgent
                                    }
                                    Copy-Item -Path $tempCrx -Destination $crx.FullName -Force
                                    Remove-Item -Path $tempCrx -Force -ErrorAction SilentlyContinue
                                    Write-Status "  Updated $($manifest.name) to $($extUpdate.Version)" -Type Success
                                    $extensionsUpdated = $true
                                }
                                catch {
                                    Write-Status "  Failed to update: $_" -Type Error
                                }
                            }
                            else {
                                Write-Status "  Would download from $($extUpdate.Codebase)" -Type DryRun
                            }
                        }
                        else {
                            Write-Status "  Up to date ($currentVersion)" -Type Detail
                        }
                    }
                    else {
                        Write-Status "  Up to date ($currentVersion)" -Type Detail
                    }
                }
            }
        }
    }
    else {
        Write-Status "Extension update checking disabled" -Type Detail
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 3: Change Detection
    # ═══════════════════════════════════════════════════════════════
    Write-Status "Step 3: Detecting Changes" -Type Step

    $needsSetup = $Force -or $extensionsUpdated -or -not (Test-Path $patchedExtPath)

    if (-not $needsSetup -and $comet) {
        # Check if source files have changed (both .crx and .crx.disabled)
        $defaultAppsDir = Join-Path $comet.Directory "default_apps"
        if (Test-Path $defaultAppsDir) {
            # Check active CRX files
            $crxFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue
            foreach ($crx in $crxFiles) {
                if (Test-FileChanged -FilePath $crx.FullName -State $state) {
                    Write-Status "Changed: $($crx.Name)" -Type Detail
                    $needsSetup = $true
                }
            }
            # Check disabled CRX files
            $disabledFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx.disabled" -ErrorAction SilentlyContinue
            foreach ($crx in $disabledFiles) {
                if (Test-FileChanged -FilePath $crx.FullName -State $state) {
                    Write-Status "Changed: $($crx.Name)" -Type Detail
                    $needsSetup = $true
                }
            }
        }
    }

    if ($needsSetup) {
        Write-Status "Setup required" -Type Info
    }
    else {
        Write-Status "No changes detected - using cached setup" -Type Success
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 4: Extract & Patch
    # ═══════════════════════════════════════════════════════════════
    Write-Status "Step 4: Extracting and Patching" -Type Step

    if ($needsSetup -and $comet) {
        $setupResult = Initialize-PatchedExtensions `
            -CometDir $comet.Directory `
            -OutputDir $patchedExtPath `
            -PatchesDir $patchesPath `
            -PatchConfig $config.extensions.patch_config `
            -DryRunMode:$DryRun

        if ($setupResult) {
            Write-Status "Extensions patched successfully" -Type Success

            # Update state with new hashes (track both .crx and .crx.disabled)
            if (-not $DryRun) {
                $defaultAppsDir = Join-Path $comet.Directory "default_apps"
                if (Test-Path $defaultAppsDir) {
                    $crxFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue
                    foreach ($crx in $crxFiles) {
                        Update-FileHash -FilePath $crx.FullName -State $state
                    }
                    $disabledFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx.disabled" -ErrorAction SilentlyContinue
                    foreach ($crx in $disabledFiles) {
                        Update-FileHash -FilePath $crx.FullName -State $state
                    }
                }
            }

            # Clear Comet's CRX caches to ensure it loads our patched extensions
            $cachePaths = @(
                (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data\extensions_crx_cache"),
                (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data\component_crx_cache")
            )
            foreach ($crxCachePath in $cachePaths) {
                if (Test-Path $crxCachePath) {
                    if ($DryRun) {
                        Write-Status "Would clear: $crxCachePath" -Type Detail
                    }
                    else {
                        Remove-Item -Path $crxCachePath -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Status "Cleared: $(Split-Path -Leaf $crxCachePath)" -Type Detail
                    }
                }
            }

            # Disable bundled extensions to prevent conflicts
            $defaultAppsDir = Join-Path $comet.Directory "default_apps"
            if (Test-Path $defaultAppsDir) {
                # Clear external_extensions.json (backup first)
                $extJsonPath = Join-Path $defaultAppsDir "external_extensions.json"
                $extJsonBackup = "$extJsonPath.meteor-backup"
                if (Test-Path $extJsonPath) {
                    if ($DryRun) {
                        Write-Status "Would clear external_extensions.json" -Type Detail
                    }
                    else {
                        if (-not (Test-Path $extJsonBackup)) {
                            Copy-Item -Path $extJsonPath -Destination $extJsonBackup -Force
                        }
                        Set-Content -Path $extJsonPath -Value "{}" -Encoding UTF8
                        Write-Status "Cleared external_extensions.json" -Type Detail
                    }
                }

                # Rename .crx files to .crx.disabled
                $crxFilesToDisable = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue
                foreach ($crx in $crxFilesToDisable) {
                    $disabledPath = "$($crx.FullName).disabled"
                    if (-not (Test-Path $disabledPath)) {
                        if ($DryRun) {
                            Write-Status "Would disable: $($crx.Name)" -Type Detail
                        }
                        else {
                            Move-Item -Path $crx.FullName -Destination $disabledPath -Force
                            Write-Status "Disabled: $($crx.Name)" -Type Detail
                        }
                    }
                }
            }
        }
        else {
            Write-Status "Extension patching failed" -Type Error
        }

        # PAK modifications (if enabled)
        if ($config.pak_modifications.enabled) {
            Initialize-PakModifications -CometDir $comet.Directory -PakConfig $config.pak_modifications -DryRunMode:$DryRun
        }
    }
    else {
        Write-Status "Using existing patched extensions" -Type Detail
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 5: uBlock Origin
    # ═══════════════════════════════════════════════════════════════
    Write-Status "Step 5: Checking uBlock Origin" -Type Step

    if ($config.ublock.enabled) {
        $null = Get-UBlockOrigin -OutputDir $ublockPath -UBlockConfig $config.ublock -DryRunMode:$DryRun
    }
    else {
        Write-Status "uBlock Origin disabled in config" -Type Detail
        $ublockPath = $null
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 5.5: AdGuard Extra
    # ═══════════════════════════════════════════════════════════════
    Write-Status "Step 5.5: Checking AdGuard Extra" -Type Step

    if ($config.adguard_extra.enabled) {
        $null = Get-AdGuardExtra -OutputDir $adguardExtraPath -AdGuardConfig $config.adguard_extra -DryRunMode:$DryRun
    }
    else {
        Write-Status "AdGuard Extra disabled in config" -Type Detail
        $adguardExtraPath = $null
    }

    # Save state
    if (-not $DryRun) {
        $state.last_update_check = (Get-Date).ToString("o")
        if ($comet) {
            $state.comet_version = $cometVersion
        }
        Save-MeteorState -StatePath $statePath -State $state
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 6: Launch Browser
    # ═══════════════════════════════════════════════════════════════
    if ($NoLaunch) {
        Write-Status "Step 6: Skipping Launch (NoLaunch specified)" -Type Step
        Write-Host ""
        Write-Status "Setup complete. Run without -NoLaunch to start browser." -Type Success
        return
    }

    Write-Status "Step 6: Launching Browser" -Type Step

    if (-not $comet -and -not $DryRun) {
        Write-Status "Cannot launch - Comet not installed" -Type Error
        exit 1
    }

    # CRITICAL: Stop any running Comet processes before launching
    # Chromium ignores command-line flags when an instance is already running -
    # it just signals the existing process to open a new window. This means
    # --no-first-run, --disable-features, etc. would all be ignored.
    $cometProcesses = Get-Process -Name "comet" -ErrorAction SilentlyContinue
    if ($cometProcesses) {
        if ($DryRun) {
            Write-Status "Would stop $($cometProcesses.Count) running Comet process(es) to apply flags" -Type DryRun
        }
        else {
            Write-Status "Stopping running Comet to apply command-line flags..." -Type Warning
            Write-Status "(Chromium ignores flags when browser is already running)" -Type Detail
            $cometProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 1000  # Wait for processes to fully exit
            Write-Status "Comet stopped - will relaunch with privacy flags" -Type Success
        }
    }

    # Pre-seed Preferences file with critical settings before launch
    # This ensures extensions.ui.developer_mode is set BEFORE extension loading
    $profileName = if ($config.browser.profile) { $config.browser.profile } else { "Default" }
    $null = Set-BrowserPreferences -ProfileName $profileName -DryRunMode:$DryRun

    if ($comet -or $DryRun) {
        $browserExe = if ($comet) { $comet.Executable } else { "comet.exe" }
        $cmd = Build-BrowserCommand -Config $config -BrowserExe $browserExe -ExtPath $patchedExtPath -UBlockPath $ublockPath -AdGuardExtraPath $adguardExtraPath

        $proc = Start-Browser -Command $cmd -DryRunMode:$DryRun

        if ($proc) {
            Write-Host ""
            Write-Status "Browser launched (PID: $($proc.Id))" -Type Success
            Write-Status "Meteor v2 active - privacy protections enabled" -Type Info
        }
    }
}

# Run main
Main

#endregion

