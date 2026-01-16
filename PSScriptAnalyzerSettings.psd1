@{
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @(
                '5.1'  # Windows PowerShell 5.1 (target platform)
            )
        }
    }

    ExcludeRules = @(
        'PSAvoidUsingWriteHost'        # Intentional for CLI output
        'PSUseSingularNouns'           # Would be breaking changes to rename
        'PSUseBOMForUnicodeEncodedFile' # BOM can cause issues with some tools
    )
}
