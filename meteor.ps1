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

.PARAMETER VerifyPak
    Verify that PAK modifications have been applied to resources.pak and exit.
    Use with -PakPath to specify a custom PAK file, otherwise auto-detects.

.PARAMETER PakPath
    Path to a specific resources.pak file to verify. Used with -VerifyPak.
    If not specified, auto-detects from Comet installation.

.PARAMETER DataPath
    Path to store Comet browser data (user profile, cache, etc.) and the portable browser.
    Defaults to .meteor subdirectory in the script's directory.
    This enables fully portable operation - no system-wide installation required.

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

.EXAMPLE
    .\Meteor.ps1 -VerifyPak
    Verify PAK patches are applied (auto-detects PAK location).

.EXAMPLE
    .\Meteor.ps1 -VerifyPak -PakPath "C:\Path\To\resources.pak"
    Verify PAK patches in a specific file.

.EXAMPLE
    .\Meteor.ps1 -DataPath "D:\PortableApps\Comet"
    Run with custom data directory for portable operation.
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
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'VerifyPak', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PakPath', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DataPath', Justification = 'Used in Main function')]
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Config,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$NoLaunch,

    [Parameter()]
    [switch]$VerifyPak,

    [Parameter()]
    [string]$PakPath,

    [Parameter()]
    [string]$DataPath
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

            # Use comma to prevent PowerShell from unwrapping single-element arrays
            return ,$data
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

    # Validate inputs
    if ($null -eq $NewData) {
        Write-Warning "[Set-PakResource] NewData is null"
        return $false
    }
    if ($null -eq $Pak.RawBytes) {
        Write-Warning "[Set-PakResource] Pak.RawBytes is null"
        return $false
    }

    for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
        if ($Pak.Resources[$i].Id -eq $ResourceId) {
            $startOffset = $Pak.Resources[$i].Offset
            $endOffset = $Pak.Resources[$i + 1].Offset
            $oldLength = $endOffset - $startOffset
            $newLength = $NewData.GetLength(0)
            $sizeDiff = $newLength - $oldLength

            # Create new byte array
            $rawBytesLength = $Pak.RawBytes.GetLength(0)
            $newBytes = New-Object byte[] ($rawBytesLength + $sizeDiff)

            # Copy everything before this resource
            [Array]::Copy($Pak.RawBytes, 0, $newBytes, 0, $startOffset)

            # Copy new data
            [Array]::Copy($NewData, 0, $newBytes, $startOffset, $newLength)

            # Copy everything after this resource
            $afterLength = $rawBytesLength - $endOffset
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

function Export-PakResources {
    <#
    .SYNOPSIS
        Export all resources from a PAK file to a directory structure.
    .DESCRIPTION
        Extracts all resources from resources.pak to individual files in a directory.
        Text resources are saved as .txt files (decompressed if gzipped).
        Binary resources are saved as .bin files.
        Creates a manifest.json with metadata about all resources.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Pak,
        [Parameter(Mandatory)]
        [string]$OutputDir
    )

    # Create output directory
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $manifest = @{
        version     = $Pak.Version
        encoding    = $Pak.Encoding
        exportedAt  = (Get-Date -Format "o")
        resources   = @{}
    }

    $textCount = 0
    $binaryCount = 0
    $gzipCount = 0

    # Iterate through all resources (skip sentinel at end)
    for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
        $resource = $Pak.Resources[$i]
        $resourceId = $resource.Id

        # Get resource bytes
        $resourceBytes = Get-PakResource -Pak $Pak -ResourceId $resourceId
        if ($null -eq $resourceBytes) { continue }

        [byte[]]$resourceBytes = $resourceBytes
        if ($resourceBytes.Length -lt 2) { continue }

        # Check if gzip compressed
        $isGzipped = ($resourceBytes[0] -eq 0x1f -and $resourceBytes[1] -eq 0x8b)
        $contentBytes = $resourceBytes
        $wasDecompressed = $false

        if ($isGzipped) {
            $gzipCount++
            try {
                $ms = New-Object System.IO.MemoryStream($resourceBytes, $false)
                $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                $outMs = New-Object System.IO.MemoryStream
                $gz.CopyTo($outMs)
                $gz.Close()
                $ms.Close()
                $contentBytes = $outMs.ToArray()
                $outMs.Close()
                $wasDecompressed = $true
            }
            catch {
                # Failed to decompress, keep original
                $contentBytes = $resourceBytes
                $wasDecompressed = $false
            }
        }

        # Determine if text or binary
        $isText = $false
        $content = $null
        try {
            $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)
            # Check for binary indicators (null bytes or control chars except newlines/tabs)
            if ($content -notmatch '[\x00-\x08\x0E-\x1F]') {
                $isText = $true
            }
        }
        catch {
            $isText = $false
        }

        # Save resource
        $resourceInfo = @{
            originalSize = $resourceBytes.Length
            gzipped      = $isGzipped
            decompressed = $wasDecompressed
        }

        if ($isText) {
            $textCount++
            $fileName = "$resourceId.txt"
            $filePath = Join-Path $OutputDir $fileName
            [System.IO.File]::WriteAllText($filePath, $content, [System.Text.UTF8Encoding]::new($false))
            $resourceInfo.type = "text"
            $resourceInfo.file = $fileName
            $resourceInfo.contentSize = $contentBytes.Length
        }
        else {
            $binaryCount++
            $fileName = "$resourceId.bin"
            $filePath = Join-Path $OutputDir $fileName
            [System.IO.File]::WriteAllBytes($filePath, $contentBytes)
            $resourceInfo.type = "binary"
            $resourceInfo.file = $fileName
            $resourceInfo.contentSize = $contentBytes.Length
        }

        $manifest.resources["$resourceId"] = $resourceInfo
    }

    # Handle aliases
    if ($Pak.Aliases -and $Pak.Aliases.Count -gt 0) {
        $manifest.aliases = @{}
        foreach ($alias in $Pak.Aliases) {
            $manifest.aliases["$($alias.Id)"] = $alias.ResourceIndex
        }
    }

    # Save manifest
    $manifestPath = Join-Path $OutputDir "manifest.json"
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

    return @{
        TextResources   = $textCount
        BinaryResources = $binaryCount
        GzippedCount    = $gzipCount
        TotalResources  = $textCount + $binaryCount
        ManifestPath    = $manifestPath
    }
}

function Import-PakResources {
    <#
    .SYNOPSIS
        Rebuild a PAK file from an exported resource directory.
    .DESCRIPTION
        Reads the manifest.json and resource files from an export directory
        and rebuilds a complete PAK file. Resources marked as gzipped in the
        manifest will be re-compressed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$InputDir,
        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $manifestPath = Join-Path $InputDir "manifest.json"
    if (-not (Test-Path $manifestPath)) {
        throw "manifest.json not found in $InputDir"
    }

    $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json

    # Create PAK structure
    $pak = @{
        Version   = $manifest.version
        Encoding  = $manifest.encoding
        Resources = [System.Collections.ArrayList]@()
        Aliases   = [System.Collections.ArrayList]@()
        RawBytes  = $null
    }

    # Collect all resource data
    $resourceData = @{}
    $sortedIds = $manifest.resources.PSObject.Properties.Name | ForEach-Object { [int]$_ } | Sort-Object

    foreach ($idStr in $manifest.resources.PSObject.Properties.Name) {
        $resourceId = [int]$idStr
        $resourceInfo = $manifest.resources.$idStr
        $filePath = Join-Path $InputDir $resourceInfo.file

        if (-not (Test-Path $filePath)) {
            Write-Warning "Resource file not found: $filePath"
            continue
        }

        # Read content
        if ($resourceInfo.type -eq "text") {
            $content = [System.IO.File]::ReadAllText($filePath)
            $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        }
        else {
            $contentBytes = [System.IO.File]::ReadAllBytes($filePath)
        }

        # Re-compress if originally gzipped
        if ($resourceInfo.gzipped -and $resourceInfo.decompressed) {
            $ms = New-Object System.IO.MemoryStream
            $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
            $gz.Write($contentBytes, 0, $contentBytes.Length)
            $gz.Close()
            $contentBytes = $ms.ToArray()
            $ms.Close()
        }

        $resourceData[$resourceId] = $contentBytes
    }

    # Build resource entries in order
    $currentOffset = 0
    # Calculate header size
    if ($manifest.version -eq 4) {
        # version(4) + encoding(1) + num_resources(4) + entries(6 each) + sentinel(6)
        $headerSize = 4 + 1 + 4 + (($sortedIds.Count + 1) * 6)
    }
    else {
        # version(4) + encoding(1) + padding(3) + num_resources(2) + num_aliases(2) + entries(6 each) + sentinel(6) + aliases(4 each)
        $aliasCount = if ($manifest.aliases) { $manifest.aliases.PSObject.Properties.Count } else { 0 }
        $headerSize = 4 + 1 + 3 + 2 + 2 + (($sortedIds.Count + 1) * 6) + ($aliasCount * 4)
    }
    $currentOffset = $headerSize

    foreach ($resourceId in $sortedIds) {
        [void]$pak.Resources.Add(@{
            Id     = $resourceId
            Offset = $currentOffset
            Data   = $resourceData[$resourceId]
        })
        $currentOffset += $resourceData[$resourceId].Length
    }

    # Add sentinel entry
    [void]$pak.Resources.Add(@{
        Id     = 0
        Offset = $currentOffset
    })

    # Add aliases if present
    if ($manifest.aliases) {
        foreach ($aliasIdStr in $manifest.aliases.PSObject.Properties.Name) {
            [void]$pak.Aliases.Add(@{
                Id            = [int]$aliasIdStr
                ResourceIndex = $manifest.aliases.$aliasIdStr
            })
        }
    }

    # Write the PAK file
    Write-PakFile -Pak $pak -Path $OutputPath

    return @{
        ResourceCount = $sortedIds.Count
        OutputPath    = $OutputPath
    }
}

function Test-PakModifications {
    <#
    .SYNOPSIS
        Verify that Meteor PAK modifications exist in a target resources.pak file.
    .DESCRIPTION
        Scans a resources.pak file to check if the expected replacement values from
        config.json pak_modifications are present. This confirms that patches have
        been successfully applied.
    .PARAMETER PakPath
        Path to the resources.pak file to verify. If not specified, auto-detects
        from the Comet installation directory.
    .PARAMETER ConfigPath
        Path to the configuration file. Defaults to ./config.json.
    .PARAMETER Detailed
        Show detailed output including resource IDs where patches were found.
    .OUTPUTS
        PSCustomObject with verification results:
        - Verified: Array of modification descriptions that were found
        - Missing: Array of modification descriptions that were not found
        - AllPatched: Boolean indicating if all modifications are present
    .EXAMPLE
        Test-PakModifications
        # Auto-detects PAK location and verifies all patches
    .EXAMPLE
        Test-PakModifications -PakPath "C:\Program Files\Comet\resources.pak" -Detailed
        # Verifies specific PAK file with detailed output
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$PakPath,

        [string]$ConfigPath = ".\config.json",

        [switch]$Detailed
    )

    # Load configuration
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "Configuration file not found: $ConfigPath"
        return $null
    }

    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Error "Failed to parse configuration: $_"
        return $null
    }

    if (-not $config.pak_modifications -or -not $config.pak_modifications.modifications) {
        Write-Error "No pak_modifications found in configuration"
        return $null
    }

    # Auto-detect PAK path if not specified
    if (-not $PakPath) {
        $comet = Get-CometInstallation
        if ($comet) {
            $PakPath = Join-Path $comet.Directory "resources.pak"
            if (-not (Test-Path $PakPath)) {
                # Try version subdirectories
                $versionDirs = Get-ChildItem -Path $comet.Directory -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d+\.\d+\.\d+' }
                foreach ($dir in $versionDirs) {
                    $testPath = Join-Path $dir.FullName "resources.pak"
                    if (Test-Path $testPath) {
                        $PakPath = $testPath
                        break
                    }
                }
            }
        }
    }

    if (-not $PakPath -or -not (Test-Path $PakPath)) {
        Write-Error "resources.pak not found. Specify -PakPath or ensure Comet is installed."
        return $null
    }

    Write-Status "Verifying PAK modifications in: $PakPath" -Type Info

    # Read and parse PAK file
    try {
        $pak = Read-PakFile -Path $PakPath
        Write-Status "Parsed PAK v$($pak.Version) with $($pak.Resources.Count - 1) resources" -Type Detail
    }
    catch {
        Write-Error "Failed to parse PAK file: $_"
        return $null
    }

    # Initialize results
    $results = @{
        Verified = [System.Collections.ArrayList]@()
        Missing  = [System.Collections.ArrayList]@()
        Details  = [System.Collections.ArrayList]@()
    }

    # Build verification patterns from replacement values
    # We look for the replacement text (what should exist after patching)
    $verificationPatterns = @()
    foreach ($mod in $config.pak_modifications.modifications) {
        $verificationPatterns += @{
            Description = $mod.description
            Replacement = $mod.replacement
            Pattern     = $mod.pattern
            Found       = $false
            ResourceIds = [System.Collections.ArrayList]@()
        }
    }

    # Scan all text resources
    $scannedCount = 0
    for ($i = 0; $i -lt $pak.Resources.Count - 1; $i++) {
        $resource = $pak.Resources[$i]
        $resourceId = $resource.Id

        $resourceBytes = Get-PakResource -Pak $pak -ResourceId $resourceId
        if ($null -eq $resourceBytes) { continue }

        [byte[]]$resourceBytes = $resourceBytes
        if ($resourceBytes.Length -lt 2) { continue }

        $scannedCount++

        # Check if gzip compressed
        $isGzipped = ($resourceBytes[0] -eq 0x1f -and $resourceBytes[1] -eq 0x8b)
        $contentBytes = $resourceBytes

        if ($isGzipped) {
            try {
                $ms = New-Object System.IO.MemoryStream($resourceBytes, $false)
                $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                $outMs = New-Object System.IO.MemoryStream
                $gz.CopyTo($outMs)
                $gz.Close()
                $ms.Close()
                $contentBytes = $outMs.ToArray()
                $outMs.Close()
            }
            catch {
                continue
            }
        }

        # Try to decode as UTF-8 text
        try {
            $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)
            if ($content -match '[\x00-\x08\x0E-\x1F]') { continue }
        }
        catch {
            continue
        }

        # Check each verification pattern (look for replacement values)
        foreach ($pattern in $verificationPatterns) {
            # Use literal string matching for the replacement value
            if ($content.Contains($pattern.Replacement)) {
                $pattern.Found = $true
                [void]$pattern.ResourceIds.Add($resourceId)
            }
        }
    }

    # Compile results
    foreach ($pattern in $verificationPatterns) {
        if ($pattern.Found) {
            [void]$results.Verified.Add($pattern.Description)
            if ($Detailed) {
                [void]$results.Details.Add(@{
                    Description = $pattern.Description
                    Status      = "Found"
                    ResourceIds = $pattern.ResourceIds.ToArray()
                    Replacement = $pattern.Replacement
                })
            }
            Write-Status "  [OK] $($pattern.Description)" -Type Detail
        }
        else {
            [void]$results.Missing.Add($pattern.Description)
            if ($Detailed) {
                [void]$results.Details.Add(@{
                    Description = $pattern.Description
                    Status      = "Missing"
                    ResourceIds = @()
                    Replacement = $pattern.Replacement
                })
            }
            Write-Status "  [MISSING] $($pattern.Description)" -Type Warning
        }
    }

    $allPatched = ($results.Missing.Count -eq 0)

    # Summary
    Write-Status "" -Type Info
    if ($allPatched) {
        Write-Status "All $($results.Verified.Count) PAK modifications verified" -Type Info
    }
    else {
        Write-Status "$($results.Verified.Count)/$($verificationPatterns.Count) PAK modifications verified, $($results.Missing.Count) missing" -Type Warning
    }

    # Return results object
    $output = [PSCustomObject]@{
        PakPath    = $PakPath
        Verified   = $results.Verified.ToArray()
        Missing    = $results.Missing.ToArray()
        AllPatched = $allPatched
        Scanned    = $scannedCount
    }

    if ($Detailed) {
        $output | Add-Member -NotePropertyName "Details" -NotePropertyValue $results.Details.ToArray()
    }

    return $output
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
        $valueLen = $Value.GetLength(0)
        while ($i -lt $valueLen - 1 -and $Value[$i] -eq 0) { $i++ }
        $Value = $Value[$i..($valueLen - 1)]
        if ($Value[0] -band 0x80) {
            $Value = @([byte]0) + $Value
        }
        $len = $Value.GetLength(0)
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
        $len = $Content.GetLength(0)
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
        $len = $Content.GetLength(0) + 1
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
    $zipLength = $bytes.GetLength(0) - $zipOffset
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
    .DESCRIPTION
        Checks for Comet in the following order:
        1. Portable installation in DataPath/comet
        2. System-wide installations in common locations
        3. PATH search via where.exe
    #>
    param(
        [string]$DataPath
    )

    # Check portable installation first
    if ($DataPath) {
        $portableBrowserDir = Join-Path $DataPath "comet"
        if (Test-Path $portableBrowserDir) {
            # Check for comet.exe directly in comet directory
            $directExe = Join-Path $portableBrowserDir "comet.exe"
            if (Test-Path $directExe) {
                return @{
                    Executable = $directExe
                    Directory  = $portableBrowserDir
                    Portable   = $true
                }
            }

            # Check for comet.exe in version subdirectory (e.g., browser\137.0.7151.87\comet.exe)
            $versionDir = Get-ChildItem -Path $portableBrowserDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
                Select-Object -First 1
            if ($versionDir) {
                $versionExe = Join-Path $versionDir.FullName "comet.exe"
                if (Test-Path $versionExe) {
                    return @{
                        Executable = $versionExe
                        Directory  = $versionDir.FullName
                        Portable   = $true
                    }
                }
            }
        }
    }

    # Check system-wide installations
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
                Portable   = $false
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
                Portable   = $false
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

function Set-CometRegistryValues {
    <#
    .SYNOPSIS
        Set registry values required for Comet update system.
    .DESCRIPTION
        Creates/updates registry keys at HKCU:\SOFTWARE\Perplexity\Update\Clients\{GUID}
        with name, lang, and pv (product version) values.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Version,
        [string]$Name = "Comet Dev",
        [string]$Lang = "en",
        [string]$ClientGuid = "0c18db21-6aaf-49d0-a339-5d135ad4c8e2",
        [switch]$DryRunMode
    )

    $regPath = "HKCU:\SOFTWARE\Perplexity\Update\Clients\$ClientGuid"

    if ($DryRunMode) {
        Write-Status "Would set registry values at: $regPath" -Type Detail
        Write-Verbose "[Registry] name=$Name, lang=$Lang, pv=$Version"
        return $true
    }

    try {
        # Create the registry path if it doesn't exist
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
            Write-Verbose "[Registry] Created path: $regPath"
        }

        # Set the values
        Set-ItemProperty -Path $regPath -Name "name" -Value $Name -Type String
        Set-ItemProperty -Path $regPath -Name "lang" -Value $Lang -Type String
        Set-ItemProperty -Path $regPath -Name "pv" -Value $Version -Type String

        Write-Status "Set registry values (pv=$Version)" -Type Detail
        return $true
    }
    catch {
        Write-Status "Failed to set registry values: $_" -Type Warning
        return $false
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

function Get-7ZipPath {
    <#
    .SYNOPSIS
        Find 7-Zip executable or return null if not found.
    #>
    $searchPaths = @(
        (Join-Path $env:ProgramFiles "7-Zip\7z.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\7-Zip\7z.exe")
    )

    foreach ($path in $searchPaths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }

    # Try PATH
    try {
        $whereResult = & where.exe 7z.exe 2>$null
        if ($whereResult) {
            return ($whereResult -split "`n")[0].Trim()
        }
    }
    catch {
        $null = $_.Exception
    }

    return $null
}

function Install-CometPortable {
    <#
    .SYNOPSIS
        Download and extract Comet browser for portable operation (no system installation).
    .DESCRIPTION
        Downloads the Comet installer, extracts nested archives to get Chrome-bin,
        and places it in the specified directory. Requires 7-Zip for extraction.

        Supports two installer formats:

        New format (mini_installer directly):
        - comet_latest_intel.exe (mini_installer)
          - chrome.7z
            - Chrome-bin\

        Old format (NSIS wrapper):
        - comet_latest_intel.exe (NSIS installer)
          - updater.7z
            - bin\Offline\{GUID1}\{GUID2}\mini_installer.exe
              - chrome.7z
                - Chrome-bin\
    #>
    param(
        [string]$DownloadUrl,
        [string]$TargetDir,
        [switch]$DryRunMode
    )

    Write-Status "Installing Comet in portable mode..." -Type Info

    # Check for 7-Zip
    $sevenZip = Get-7ZipPath
    if (-not $sevenZip) {
        Write-Status "7-Zip is required for portable installation. Please install 7-Zip from https://7-zip.org" -Type Error
        return $null
    }

    if ($DryRunMode) {
        Write-Status "Would download from: $DownloadUrl" -Type Detail
        Write-Status "Would extract to: $TargetDir" -Type Detail
        return $null
    }

    $tempDir = Join-Path $env:TEMP "meteor_comet_$(Get-Random)"
    $tempInstaller = Join-Path $tempDir "comet_installer.exe"

    try {
        # Create temp directory
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        # Download installer
        Write-Status "Downloading from: $DownloadUrl" -Type Detail
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", $script:UserAgent)
        $webClient.DownloadFile($DownloadUrl, $tempInstaller)

        Write-Status "Extracting installer (step 1/2)..." -Type Detail

        # Step 1: Extract installer (handles both mini_installer and NSIS formats)
        $extractDir1 = Join-Path $tempDir "installer"
        & $sevenZip x $tempInstaller -o"$extractDir1" -y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract installer"
        }

        # Check which format we have
        $chrome7z = Join-Path $extractDir1 "chrome.7z"
        if (Test-Path $chrome7z) {
            # New format: mini_installer directly contains chrome.7z
            Write-Verbose "Detected mini_installer format (chrome.7z found directly)"
        }
        else {
            # Old format: NSIS wrapper with updater.7z -> mini_installer -> chrome.7z
            Write-Verbose "Detected NSIS wrapper format, extracting nested archives..."
            $updater7z = Join-Path $extractDir1 "updater.7z"
            if (-not (Test-Path $updater7z)) {
                throw "Neither chrome.7z nor updater.7z found in installer - unknown format"
            }

            $extractDir2 = Join-Path $tempDir "updater"
            & $sevenZip x $updater7z -o"$extractDir2" -y 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract updater.7z"
            }

            # Find mini_installer.exe through the GUID directories
            $offlineDir = Join-Path $extractDir2 "bin\Offline"
            if (-not (Test-Path $offlineDir)) {
                throw "bin\Offline directory not found in updater"
            }

            $miniInstaller = Get-ChildItem -Path $offlineDir -Recurse -Filter "mini_installer.exe" | Select-Object -First 1
            if (-not $miniInstaller) {
                throw "mini_installer.exe not found in Offline directory"
            }

            $extractDir3 = Join-Path $tempDir "mini_installer"
            & $sevenZip x $miniInstaller.FullName -o"$extractDir3" -y 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract mini_installer.exe"
            }

            $chrome7z = Join-Path $extractDir3 "chrome.7z"
            if (-not (Test-Path $chrome7z)) {
                throw "chrome.7z not found in mini_installer"
            }
        }

        # Step 2: Extract chrome.7z to get Chrome-bin
        Write-Status "Extracting browser files (step 2/2)..." -Type Detail
        $extractDirChrome = Join-Path $tempDir "chrome"
        & $sevenZip x $chrome7z -o"$extractDirChrome" -y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract chrome.7z"
        }

        # Find Chrome-bin directory
        $chromeBin = Join-Path $extractDirChrome "Chrome-bin"
        if (-not (Test-Path $chromeBin)) {
            throw "Chrome-bin directory not found"
        }

        # Create target directory
        $cometDir = Join-Path $TargetDir "comet"
        if (Test-Path $cometDir) {
            Write-Status "Removing existing comet directory..." -Type Detail
            Remove-Item -Path $cometDir -Recurse -Force
        }

        # Move Chrome-bin to target
        Write-Status "Installing to: $cometDir" -Type Detail
        Move-Item -Path $chromeBin -Destination $cometDir -Force

        # Find the executable
        $cometExe = Join-Path $cometDir "comet.exe"
        if (-not (Test-Path $cometExe)) {
            # Try to find it in a version subdirectory
            $versionDir = Get-ChildItem -Path $cometDir -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } | Select-Object -First 1
            if ($versionDir) {
                $cometExe = Join-Path $versionDir.FullName "comet.exe"
            }
        }

        if (-not (Test-Path $cometExe)) {
            throw "comet.exe not found in extracted files"
        }

        Write-Status "Portable installation complete" -Type Success

        return @{
            Executable = $cometExe
            Directory  = Split-Path -Parent $cometExe
            Portable   = $true
        }
    }
    catch {
        Write-Status "Failed to install Comet portable: $_" -Type Error
        return $null
    }
    finally {
        # Cleanup temp directory
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
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
        $versionSource = $null

        Write-Verbose "Update check: Querying $DownloadUrl"
        Write-Verbose "Update check: Current version is $CurrentVersion"

        # Use GET request with MaximumRedirection 0 to capture the redirect URL
        # HEAD requests are blocked by Cloudflare, but GET with no redirect follow works
        # The API returns a 307 redirect to the actual download URL which contains the version
        $redirectUrl = $null
        try {
            $response = Invoke-WebRequest -Uri $DownloadUrl -Method Get -UseBasicParsing -MaximumRedirection 0 -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            }
            Write-Verbose "Update check: Response status $($response.StatusCode)"
            # PowerShell 5.1 may return 307 directly without throwing - check for Location header
            if ($response.StatusCode -eq 307) {
                $redirectUrl = $response.Headers["Location"]
                Write-Verbose "Update check: Got 307 redirect (no exception)"
            }
        }
        catch [System.Net.WebException] {
            # Some PowerShell versions throw on redirect with MaximumRedirection 0
            $webResponse = $_.Exception.Response
            if ($webResponse -and $webResponse.StatusCode -eq [System.Net.HttpStatusCode]::TemporaryRedirect) {
                $redirectUrl = $webResponse.Headers["Location"]
                Write-Verbose "Update check: Got 307 redirect (from exception)"
            }
            else {
                throw
            }
        }

        # Try to extract version from redirect Location header
        Write-Verbose "Update check: Redirect URL: $(if ($redirectUrl) { $redirectUrl } else { '(not present)' })"
        if ($redirectUrl) {
            # Version pattern in URL path like /143.2.7499.37654/comet_latest_intel.exe
            if ($redirectUrl -match '/(\d+\.\d+\.\d+(?:\.\d+)?)/' -or $redirectUrl -match '[\-_](\d+\.\d+\.\d+(?:\.\d+)?)') {
                $latestVersion = $Matches[1]
                $versionSource = "redirect Location header"
                Write-Verbose "Update check: Extracted version $latestVersion from redirect URL"
            }
            else {
                Write-Verbose "Update check: No version pattern found in redirect URL"
            }
        }

        if ($latestVersion) {
            Write-Verbose "Update check: Latest version $latestVersion found via $versionSource"
            $comparison = Compare-Versions -Version1 $latestVersion -Version2 $CurrentVersion
            Write-Verbose "Update check: Version comparison result: $comparison (positive = update available)"
            if ($comparison -gt 0) {
                Write-Verbose "Update check: Update available ($CurrentVersion -> $latestVersion)"
                return @{
                    Version     = $latestVersion
                    DownloadUrl = $DownloadUrl
                }
            }
            else {
                Write-Verbose "Update check: Already up to date"
            }
        }
        else {
            Write-Verbose "Update check: Could not determine latest version from response"
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

    # Find and process CRX files (prefer active .crx over .crx.meteor-backup)
    $crxSources = @{}

    # First collect .crx.meteor-backup files
    $backupFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx.meteor-backup" -ErrorAction SilentlyContinue
    foreach ($file in $backupFiles) {
        $baseName = $file.Name -replace '\.crx\.meteor-backup$', ''
        $crxSources[$baseName] = $file
    }

    # Then collect active .crx files (these override .meteor-backup versions)
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
        Also exports all resources to PatchedResourcesPath for manual editing.
    #>
    param(
        [string]$CometDir,
        [object]$PakConfig,
        [string]$PatchedResourcesPath,
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

    # 1.5. Restore from backup if -Force is used (ensures clean state)
    $backupPath = "$pakPath.meteor-backup"
    if ($Force -and (Test-Path $backupPath)) {
        Write-Status "Restoring PAK from backup (Force mode)" -Type Detail
        Copy-Item -Path $backupPath -Destination $pakPath -Force
    }

    # 2. Read and parse PAK
    try {
        $pak = Read-PakFile -Path $pakPath
        Write-Status "Parsed PAK v$($pak.Version) with $($pak.Resources.Count - 1) resources" -Type Detail
    }
    catch {
        Write-Status "Failed to parse PAK: $_" -Type Error
        return $false
    }

    # 2.5. Export resources to patched_resources directory (for manual editing)
    if ($PatchedResourcesPath -and -not $DryRunMode) {
        try {
            $exportResult = Export-PakResources -Pak $pak -OutputDir $PatchedResourcesPath
            Write-Status "Exported $($exportResult.TotalResources) resources to: $PatchedResourcesPath" -Type Detail
            Write-Verbose "[PAK] Export: $($exportResult.TextResources) text, $($exportResult.BinaryResources) binary, $($exportResult.GzippedCount) were gzipped"
        }
        catch {
            Write-Status "Failed to export PAK resources: $_" -Type Warning
            # Non-fatal - continue with modifications
        }
    }

    # 3. Search all resources and apply modifications
    $modifiedResources = @{}
    $appliedCount = 0
    $gzipCount = 0
    $textCount = 0
    $scannedCount = 0

    # Iterate through all resources (skip sentinel at end)
    for ($i = 0; $i -lt $pak.Resources.Count - 1; $i++) {
        $resource = $pak.Resources[$i]
        $resourceId = $resource.Id

        # Get resource bytes (comma operator in return preserves byte[] type)
        $resourceBytes = Get-PakResource -Pak $pak -ResourceId $resourceId
        if ($null -eq $resourceBytes) { continue }

        # Ensure we have a byte[] and get its length safely
        [byte[]]$resourceBytes = $resourceBytes
        $byteLength = $resourceBytes.Length
        if ($byteLength -lt 2) { continue }

        $scannedCount++

        # Check if gzip compressed (magic bytes: 0x1f 0x8b)
        $isGzipped = ($resourceBytes[0] -eq 0x1f -and $resourceBytes[1] -eq 0x8b)
        $contentBytes = $resourceBytes

        if ($isGzipped) {
            $gzipCount++
            try {
                $ms = New-Object System.IO.MemoryStream($resourceBytes, $false)
                $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                $outMs = New-Object System.IO.MemoryStream
                $gz.CopyTo($outMs)
                $gz.Close()
                $ms.Close()
                $contentBytes = $outMs.ToArray()
                $outMs.Close()
            }
            catch {
                # Failed to decompress, skip
                continue
            }
        }

        # Try to decode as UTF-8 text (skip binary resources)
        try {
            $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)
            # Skip if it looks like binary (has null bytes or non-printable chars)
            if ($content -match '[\x00-\x08\x0E-\x1F]') { continue }
        }
        catch {
            continue
        }

        $textCount++
        $resourceModified = $false

        # Log sample content for pattern debugging
        if ($content -match 'shouldHide|BooleanFlags|NumericFlags|perplexityChannel') {
            Write-Verbose "[PAK] Resource $resourceId contains potential target (gzip=$isGzipped)"
            $preview = $content.Substring(0, [Math]::Min(500, $content.Length)) -replace '[\r\n]+', ' '
            Write-Verbose "[PAK] Preview: $preview..."

            # Extra logging for shouldHide functions
            if ($content -match 'shouldHide\w*Perplexity|shouldHidePerplexity|hidePerplexity') {
                Write-Status "  [DEBUG] Resource $resourceId contains Perplexity hide function" -Type Detail
                # Find and show the function
                if ($content -match '(function\s+shouldHide\w*[^}]+\})') {
                    Write-Verbose "[PAK] Hide function: $($Matches[1] -replace '[\r\n]+', ' ')"
                }
            }
        }

        # Try each modification pattern
        foreach ($mod in $PakConfig.modifications) {
            if ($content -match $mod.pattern) {
                # Show context around the match for debugging
                if ($content -match "(.{0,100})($([regex]::Escape($mod.pattern)))(.{0,100})") {
                    $context = "$($Matches[1])>>>$($Matches[2])<<<$($Matches[3])" -replace '[\r\n]+', ' '
                    Write-Verbose "[PAK] Match context in $resourceId`: $context"
                }
                $content = $content -replace $mod.pattern, $mod.replacement
                Write-Status "  Resource $resourceId - $($mod.description)" -Type Detail
                $resourceModified = $true
                $appliedCount++
            }
        }

        # Track modified resources (with compression flag)
        if ($resourceModified) {
            $modifiedResources[$resourceId] = @{
                Content = $content
                WasGzipped = $isGzipped
            }
        }
    }

    # Log scan statistics
    Write-Verbose "[PAK] Scan complete: $scannedCount resources, $gzipCount gzipped, $textCount text files, $appliedCount patterns matched"
    if ($appliedCount -eq 0) {
        Write-Status "PAK scan stats: $scannedCount resources, $gzipCount gzipped, $textCount text - no pattern matches" -Type Detail
    }

    # 4. Apply all modifications to PAK structure
    $modified = $false
    foreach ($resourceId in $modifiedResources.Keys) {
        try {
            Write-Verbose "[PAK] Processing resource $resourceId"
            $entry = $modifiedResources[$resourceId]
            $contentString = $entry['Content']
            $wasGzipped = $entry['WasGzipped']

            Write-Verbose "[PAK] Content type: $($contentString.GetType().FullName), WasGzipped: $wasGzipped"

            if ($null -eq $contentString) {
                Write-Status "Content is null for resource $resourceId" -Type Error
                continue
            }

            Write-Verbose "[PAK] Encoding to UTF8..."
            [byte[]]$newBytes = [System.Text.Encoding]::UTF8.GetBytes($contentString)
            Write-Verbose "[PAK] Encoded bytes type: $($newBytes.GetType().FullName)"

            if ($null -eq $newBytes) {
                Write-Status "Failed to encode content for resource $resourceId" -Type Error
                continue
            }

            # Re-compress if originally gzipped
            if ($wasGzipped) {
                Write-Verbose "[PAK] Recompressing with gzip..."
                $outMs = New-Object System.IO.MemoryStream
                $gz = New-Object System.IO.Compression.GZipStream($outMs, [System.IO.Compression.CompressionLevel]::Optimal, $true)

                # Get length using .NET method to avoid PowerShell property resolution issues
                $byteCount = $newBytes.GetLength(0)
                Write-Verbose "[PAK] Writing $byteCount bytes to gzip stream..."

                $gz.Write($newBytes, 0, $byteCount)
                $gz.Flush()
                $gz.Dispose()
                $compressedBytes = $outMs.ToArray()
                $outMs.Dispose()

                if ($null -eq $compressedBytes) {
                    Write-Status "Gzip compression returned null for resource $resourceId" -Type Error
                    continue
                }
                $newBytes = [byte[]]$compressedBytes
                Write-Verbose "[PAK] Compressed to $($newBytes.GetLength(0)) bytes"
            }

            if ($DryRunMode) {
                Write-Status "Would modify resource $resourceId$(if ($wasGzipped) { ' (gzipped)' })" -Type DryRun
            }
            else {
                Write-Verbose "[PAK] Calling Set-PakResource..."
                $success = Set-PakResource -Pak $pak -ResourceId $resourceId -NewData $newBytes
                if ($success) {
                    $modified = $true
                }
                else {
                    Write-Status "Failed to set resource $resourceId" -Type Error
                }
            }
        }
        catch {
            Write-Status "Error processing resource $resourceId`: $($_.Exception.Message)" -Type Error
            Write-Status "  At: $($_.InvocationInfo.ScriptLineNumber)" -Type Error
            continue
        }
    }

    # 5. Write modified PAK (with backup)
    if ($modified -and -not $DryRunMode) {
        $backupPath = "$pakPath.meteor-backup"

        if (-not (Test-Path $backupPath)) {
            Copy-Item -Path $pakPath -Destination $backupPath -Force
            Write-Status "Created backup: $backupPath" -Type Detail
        }
        else {
            Write-Verbose "[PAK] Backup already exists at: $backupPath"
        }

        try {
            # Calculate hash before write for verification
            $beforeHash = (Get-FileHash -Path $pakPath -Algorithm SHA256).Hash
            Write-Verbose "[PAK] Hash before write: $beforeHash"

            Write-PakFile -Pak $pak -Path $pakPath

            # Verify write succeeded by comparing hashes
            $afterHash = (Get-FileHash -Path $pakPath -Algorithm SHA256).Hash
            Write-Verbose "[PAK] Hash after write: $afterHash"

            if ($beforeHash -eq $afterHash) {
                Write-Status "PAK file unchanged after write - modifications may not have been applied!" -Type Warning
            }
            else {
                Write-Status "Wrote modified PAK ($($modifiedResources.Count) resources, $appliedCount modifications)" -Type Success
                Write-Verbose "[PAK] File modified successfully (hash changed)"

                # Re-read and verify one of our modifications (resource 21192 - shouldHide)
                $verifyPak = Read-PakFile -Path $pakPath
                if ($verifyPak) {
                    $verifyBytes = Get-PakResource -Pak $verifyPak -ResourceId 21192
                    if ($verifyBytes) {
                        [byte[]]$verifyBytes = $verifyBytes
                        # Decompress if gzipped
                        if ($verifyBytes[0] -eq 0x1f -and $verifyBytes[1] -eq 0x8b) {
                            $ms = New-Object System.IO.MemoryStream($verifyBytes, $false)
                            $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
                            $outMs = New-Object System.IO.MemoryStream
                            $gz.CopyTo($outMs)
                            $gz.Close()
                            $ms.Close()
                            $verifyBytes = $outMs.ToArray()
                            $outMs.Close()
                        }
                        $verifyContent = [System.Text.Encoding]::UTF8.GetString($verifyBytes)
                        if ($verifyContent -match 'return false;\s*//\s*Meteor|shouldHidePerplexityServiceWorker.*return false;') {
                            Write-Verbose "[PAK] Verification: inspect modification confirmed in written file"
                        }
                        elseif ($verifyContent -notmatch 'return !isPerplexityInternalUser') {
                            Write-Verbose "[PAK] Verification: original pattern NOT found (modification likely applied)"
                        }
                        else {
                            Write-Status "PAK verification failed: original pattern still present in resource 21192" -Type Warning
                        }
                    }
                }
            }
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
        [string]$UserDataPath,
        [switch]$DryRunMode
    )

    # Determine User Data path
    $userDataPath = $null

    # Use provided path if specified (portable mode)
    if ($UserDataPath) {
        $userDataPath = $UserDataPath
        if (-not $DryRunMode -and -not (Test-Path $userDataPath)) {
            $null = New-Item -ItemType Directory -Path $userDataPath -Force
        }
    }
    else {
        # Fall back to system paths
        $systemPaths = @(
            (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data"),
            (Join-Path $env:LOCALAPPDATA "Comet\User Data")
        )

        foreach ($path in $systemPaths) {
            if (Test-Path $path) {
                $userDataPath = $path
                break
            }
        }

        if (-not $userDataPath) {
            # User Data doesn't exist yet - will be created on first run
            # Create it now so we can pre-seed Preferences
            $userDataPath = $systemPaths[0]
            if (-not $DryRunMode) {
                $null = New-Item -ItemType Directory -Path $userDataPath -Force
            }
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
        [string]$AdGuardExtraPath,
        [string]$UserDataPath
    )

    $cmd = [System.Collections.ArrayList]@()
    [void]$cmd.Add($BrowserExe)

    $browserConfig = $Config.browser

    # Add user data directory if specified (for portable mode)
    if ($UserDataPath) {
        [void]$cmd.Add("--user-data-dir=`"$UserDataPath`"")
    }

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
        # Quote each path to handle spaces in directory names
        $quotedExtensions = $extensions | ForEach-Object { "`"$_`"" }
        $extList = $quotedExtensions -join ","
        [void]$cmd.Add("--load-extension=$extList")
    }

    # Add flag switches section (mimics comet://flags UI-enabled flags)
    # These flags must be in this section to take effect
    [void]$cmd.Add("--flag-switches-begin")
    [void]$cmd.Add("--extensions-on-chrome-urls")
    [void]$cmd.Add("--extensions-on-extension-urls")
    [void]$cmd.Add("--flag-switches-end")

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

    # Show full command line in verbose mode
    $fullCommandLine = "`"$exe`" $($processArgs -join ' ')"
    Write-Verbose "Launching browser with command line:"
    Write-Verbose $fullCommandLine

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

    # Set up DataPath (for portable installation and user data)
    $meteorDataPath = if ($DataPath) {
        # Use provided path
        if ([System.IO.Path]::IsPathRooted($DataPath)) {
            $DataPath
        }
        else {
            Join-Path $baseDir $DataPath
        }
    }
    else {
        # Default to .meteor in script directory
        Join-Path $baseDir ".meteor"
    }

    # Ensure data directory exists
    if (-not (Test-Path $meteorDataPath)) {
        $null = New-Item -ItemType Directory -Path $meteorDataPath -Force
    }

    # User data path for browser profile (inside meteorDataPath)
    $userDataPath = Join-Path $meteorDataPath "User Data"

    # Load config
    $configPath = if ($Config) { $Config } else { Join-Path $baseDir "config.json" }
    $config = Get-MeteorConfig -ConfigPath $configPath

    # Determine if portable mode is enabled
    $portableMode = $config.comet.portable -eq $true

    # Handle -VerifyPak mode (verify and exit)
    if ($VerifyPak) {
        $pakPathArg = if ($PakPath) { $PakPath } else { $null }
        $result = Test-PakModifications -PakPath $pakPathArg -ConfigPath $configPath -Detailed
        if ($null -eq $result) {
            exit 1
        }
        if ($result.AllPatched) {
            Write-Host ""
            Write-Host "PAK verification passed." -ForegroundColor Green
            exit 0
        }
        else {
            Write-Host ""
            Write-Host "PAK verification failed - some patches are missing." -ForegroundColor Red
            exit 1
        }
    }

    # Resolve paths
    $patchedExtPath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.patched_extensions
    $ublockPath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.ublock
    $adguardExtraPath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.adguard_extra
    $patchedResourcesPath = Resolve-MeteorPath -BasePath $baseDir -RelativePath $config.paths.patched_resources
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
        $prefsPathsToCheck = @()

        if ($portableMode) {
            # Portable mode: only use portable path
            $prefsPathsToCheck += $userDataPath
        }
        else {
            # System mode: use system paths
            $prefsPathsToCheck += (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data")
            $prefsPathsToCheck += (Join-Path $env:LOCALAPPDATA "Comet\User Data")
        }

        foreach ($udPath in $prefsPathsToCheck) {
            if (Test-Path $udPath) {
                $profileName = if ($config.browser.profile) { $config.browser.profile } else { "Default" }
                $profilePath = Join-Path $udPath $profileName
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

    if ($portableMode) {
        Write-Status "Portable mode enabled - data path: $meteorDataPath" -Type Detail
    }

    # Check for existing installation (portable path first if in portable mode)
    $comet = Get-CometInstallation -DataPath $(if ($portableMode) { $meteorDataPath } else { $null })

    # In portable mode, we need a portable installation - don't use system-wide fallback
    if ($portableMode -and $comet -and -not $comet.Portable) {
        Write-Status "Found system installation but portable mode is enabled - extracting portable version..." -Type Info
        $comet = $null
    }

    if (-not $comet) {
        if ($portableMode) {
            # Portable installation - extract directly
            $comet = Install-CometPortable -DownloadUrl $config.comet.download_url -TargetDir $meteorDataPath -DryRunMode:$DryRun
        }
        else {
            # System installation - use installer
            $comet = Install-Comet -DownloadUrl $config.comet.download_url -DryRunMode:$DryRun
        }
    }

    if (-not $comet -and -not $DryRun) {
        Write-Status "Could not find or install Comet browser" -Type Error
        exit 1
    }

    if ($comet) {
        Write-Status "Comet found: $($comet.Executable)" -Type Success
        if ($comet.Portable) {
            Write-Status "Mode: Portable" -Type Detail
        }
        $cometVersion = Get-CometVersion -ExePath $comet.Executable
        Write-Status "Version: $cometVersion" -Type Detail

        # Set registry values for Comet update system
        if ($cometVersion) {
            Set-CometRegistryValues -Version $cometVersion -DryRunMode:$DryRun
        }
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
                if ($portableMode) {
                    $newComet = Install-CometPortable -DownloadUrl $config.comet.download_url -TargetDir $meteorDataPath -DryRunMode:$DryRun
                }
                else {
                    $newComet = Install-Comet -DownloadUrl $config.comet.download_url -DryRunMode:$DryRun
                }
                if ($newComet) {
                    $comet = $newComet
                    $cometVersion = Get-CometVersion -ExePath $comet.Executable
                    Write-Status "Updated to version: $cometVersion" -Type Success
                    # Update registry with new version
                    if ($cometVersion) {
                        Set-CometRegistryValues -Version $cometVersion -DryRunMode:$DryRun
                    }
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
        # Check if source files have changed (both .crx and .crx.meteor-backup)
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
            # Check backed-up CRX files
            $backupFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx.meteor-backup" -ErrorAction SilentlyContinue
            foreach ($crx in $backupFiles) {
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

            # Update state with new hashes (track both .crx and .crx.meteor-backup)
            if (-not $DryRun) {
                $defaultAppsDir = Join-Path $comet.Directory "default_apps"
                if (Test-Path $defaultAppsDir) {
                    $crxFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue
                    foreach ($crx in $crxFiles) {
                        Update-FileHash -FilePath $crx.FullName -State $state
                    }
                    $backupFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx.meteor-backup" -ErrorAction SilentlyContinue
                    foreach ($crx in $backupFiles) {
                        Update-FileHash -FilePath $crx.FullName -State $state
                    }
                }
            }

            # Clear Comet's CRX caches to ensure it loads our patched extensions
            $cachePaths = @()
            if ($portableMode -and $userDataPath) {
                # Portable mode: only use portable path
                $cachePaths += (Join-Path $userDataPath "extensions_crx_cache")
                $cachePaths += (Join-Path $userDataPath "component_crx_cache")
            }
            else {
                # System mode: use system paths
                $cachePaths += (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data\extensions_crx_cache")
                $cachePaths += (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data\component_crx_cache")
            }

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

                # Backup .crx files to .crx.meteor-backup
                $crxFilesToBackup = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue
                foreach ($crx in $crxFilesToBackup) {
                    $backupPath = "$($crx.FullName).meteor-backup"
                    if (-not (Test-Path $backupPath)) {
                        if ($DryRun) {
                            Write-Status "Would backup: $($crx.Name)" -Type Detail
                        }
                        else {
                            Move-Item -Path $crx.FullName -Destination $backupPath -Force
                            Write-Status "Backed up: $($crx.Name)" -Type Detail
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
            Initialize-PakModifications -CometDir $comet.Directory -PakConfig $config.pak_modifications -PatchedResourcesPath $patchedResourcesPath -DryRunMode:$DryRun
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
    $prefsUserDataPath = if ($portableMode) { $userDataPath } else { $null }
    $null = Set-BrowserPreferences -ProfileName $profileName -UserDataPath $prefsUserDataPath -DryRunMode:$DryRun

    if ($comet -or $DryRun) {
        $browserExe = if ($comet) { $comet.Executable } else { "comet.exe" }
        $browserUserDataPath = if ($portableMode) { $userDataPath } else { $null }
        $cmd = Build-BrowserCommand -Config $config -BrowserExe $browserExe -ExtPath $patchedExtPath -UBlockPath $ublockPath -AdGuardExtraPath $adguardExtraPath -UserDataPath $browserUserDataPath

        $proc = Start-Browser -Command $cmd -DryRunMode:$DryRun

        if ($proc) {
            Write-Host ""
            Write-Status "Browser launched (PID: $($proc.Id))" -Type Success
            Write-Status "Meteor v2 active - privacy protections enabled" -Type Info
            if ($portableMode) {
                Write-Status "User data: $userDataPath" -Type Detail
            }
        }
    }
}

# Run main
Main

#endregion

