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

.PARAMETER WhatIf
    Shows what would happen if the command runs. The command is not executed.

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

.PARAMETER SkipPak
    Skip PAK unpacking/patching/repacking stage for faster testing.
    Use this when iterating on non-PAK changes (e.g., preferences, extensions).

.PARAMETER Verbose
    Enable verbose output for debugging.

.EXAMPLE
    .\Meteor.ps1
    Run full workflow and launch browser.

.EXAMPLE
    .\Meteor.ps1 -WhatIf
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

.EXAMPLE
    .\Meteor.ps1 -SkipPak -Verbose
    Run without PAK processing for faster preference/extension testing.
#>

# Suppress PSScriptAnalyzer warnings for internal helper functions
# These functions don't need individual ShouldProcess - they are called from workflow functions that check $WhatIfPreference
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'New-DirectoryIfNotExists')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Set-NestedValue')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-FileHash')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Set-PakResource')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-Extension')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Set-RegistryPreferenceMacs')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Set-BrowserPreferences')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-TrackedPreferences')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-ModifiedMacs')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-AllMacs')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-CometBrowser')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Update-BundledExtensions')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = 'Start-Browser')]
# Script parameters are used in Main function via direct variable access
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Config', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Force', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'NoLaunch', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'VerifyPak', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PakPath', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DataPath', Justification = 'Used in Main function')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SkipPak', Justification = 'Used in Main function')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$Config,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$NoLaunch,

    [Parameter()]
    [switch]$VerifyPak,

    [Parameter()]
    [string]$PakPath,

    [Parameter()]
    [string]$DataPath,

    [Parameter()]
    [switch]$SkipPak
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Constants

$script:MeteorVersion = "2.0.0"
$script:UserAgent = "Meteor/$script:MeteorVersion"

# Registry MAC Constant - Used as literal ASCII bytes for Windows Registry MAC calculation
# This is different from the 64-byte seed in resources.pak used for Secure Preferences file MACs
$script:RegistryHashSeed = "ChromeRegistryHashStoreValidationSeed"

# CRX Format Constants
# CRX (Chrome Extension) files are signed ZIP archives with a header containing version info and signatures.
# See: https://developer.chrome.com/docs/extensions/how-to/distribute/host-on-linux#packaging
$script:CRX_MAGIC = [byte[]]@(0x43, 0x72, 0x32, 0x34)  # "Cr24" in ASCII
$script:CRX_VERSION_2 = 2
$script:CRX_VERSION_3 = 3
$script:CRX_HEADER_SIZE_BASE = 8   # magic(4) + version(4)
$script:CRX2_HEADER_SIZE_MIN = 16  # magic(4) + version(4) + pubkey_len(4) + sig_len(4)
$script:CRX3_HEADER_SIZE_MIN = 12  # magic(4) + version(4) + header_len(4)

# Feature-to-Flag Mapping Table
# Maps feature names (used in --enable-features/--disable-features) to chrome://flags names
# The mapping is NON-ALGORITHMIC - feature names cannot be mechanically converted to flag names
# Format: "FeatureName" = "flag-name" (without @N suffix - that's added based on enable/disable)
#
# Features in this table will be enforced via Local State's browser.enabled_labs_experiments
# Features NOT in this table will remain on the command line (no chrome://flags equivalent)
#
# Source: SETTINGS/Local State reference file with verified flag names
$script:FeatureToFlagMapping = @{
    # === ENABLE FEATURES (@1) ===
    # These get "@1" suffix in enabled_labs_experiments
    "WebTransportDeveloperMode"                 = "webtransport-developer-mode"
    "ExtensionsOnChromeURLs"                    = "extensions-on-chrome-urls"
    "ExtensionsOnExtensionURLs"                 = "extensions-on-extension-urls"
    "DirectSocketsInServiceWorkers"             = "direct-sockets-in-service-workers"
    "DirectSocketsInSharedWorkers"              = "direct-sockets-in-shared-workers"
    "IsolatedWebApps"                           = "enable-isolated-web-apps"
    "IsolatedWebAppDevMode"                     = "enable-isolated-web-app-dev-mode"
    "MulticastInDirectSockets"                  = "multicast-in-direct-sockets"
    "ReadAnythingWithReadability"               = "read-anything-with-readability-enabled"
    "DevToolsIndividualRequestThrottling"       = "devtools-individual-request-throttling"
    "DevToolsLiveEdit"                          = "devtools-live-edit"
    "DevToolsPrivacyUI"                         = "devtools-privacy-ui"
    "DevToolsStartingStyleDebugging"            = "devtools-starting-style-debugging"
    "EnableDevtoolsDeepLinkViaExtensibilityApi" = "enable-devtools-deep-link-via-extensibility-api"
    "EnableGamepadMultitouch"                   = "enable-gamepad-multitouch"
    "EnableWindowsGamingInputDataFetcher"       = "enable-windows-gaming-input"
    "ExperimentalWebPlatformFeatures"           = "enable-experimental-web-platform-features"
    "ExtensionPermissionOmniboxDirectInput"     = "enable-extension-permission-omnibox-directinput"
    "LocationProviderManager"                   = "enable-location-provider-manager"
    "ParallelDownloading"                       = "enable-parallel-downloading"
    "UiaProvider"                               = "ui-automation-provider"
    "UIDebugTools"                              = "ui-debug-tools"
    "ExperimentalOmniboxLabs"                   = "experimental-omnibox-labs"
    "WebRtcHideLocalIpsWithMdns"                = "enable-webrtc-hide-local-ips-with-mdns"

    # === DISABLE FEATURES (@2) ===
    # These get "@2" suffix in enabled_labs_experiments
    # NOTE: ExtensionManifestV2* features have NO chrome://flags equivalent - must stay on command line
    "ActorFormFillingServiceEnableAddress"                  = "actor-form-filling-service-enable-address"
    "ActorFormFillingServiceEnableCreditCard"               = "actor-form-filling-service-enable-credit-card"
    "AutofillCreditCardUpload"                              = "enable-autofill-credit-card-upload"
    "AutofillUpstream"                                      = "autofill-upstream"
    "DiscountAutofill"                                      = "discount-autofill"
    "AutofillEnableBuyNowPayLater"                          = "autofill-enable-buy-now-pay-later"
    "AutofillEnableAmountExtraction"                        = "autofill-enable-amount-extraction"
    "AutofillEnableAiBasedAmountExtraction"                 = "autofill-enable-ai-based-amount-extraction"
    "AutofillEnableCardInfoRuntimeRetrieval"                = "autofill-enable-card-info-runtime-retrieval"
    "AutofillEnableLoyaltyCardsFilling"                     = "autofill-enable-loyalty-cards-filling"
    "AutofillEnableSupportForHomeAndWork"                   = "autofill-enable-support-for-home-and-work"
    "AutofillEnableSupportForNameAndEmailProfile"           = "autofill-enable-support-for-name-and-email-profile"
    "AutofillEnableVcn3dsAuthentication"                    = "autofill-enable-vcn-3ds-authentication"
    "NtpComposebox"                                         = "ntp-composebox"
    "NtpRealboxNext"                                        = "ntp-realbox-next"
    "EnableNtpBrowserPromos"                                = "enable-ntp-browser-promos"
    "NtpCustomizeChromeAutoOpen"                            = "ntp-customize-chrome-auto-open"
    "NtpMicrosoftAuthenticationModule"                      = "ntp-microsoft-authentication-module"
    "NtpNextFeatures"                                       = "ntp-next-features"
    "NtpSharepointModule"                                   = "ntp-sharepoint-module"
    "BrowsingHistoryActorIntegrationM1"                     = "browsing-history-actor-integration-M1"
    "LogUrlScoringSignals"                                  = "omnibox-ml-log-url-scoring-signals"
    "ChromeWebStoreNavigationThrottle"                      = "chrome-web-store-navigation-throttle"
    "CollaborationSharedTabGroupAccountData"                = "collaboration-shared-tab-group-account-data"
    "ComposeSelectionNudge"                                 = "compose-selection-nudge"
    "ContextualCueing"                                      = "contextual-cueing"
    "ContextualSearchBoxUsesContextualSearchProvider"       = "contextual-search-box-uses-contextual-search-provider"
    "ContextualTasks"                                       = "contextual-tasks"
    "ContextualTasksContext"                                = "contextual-tasks-context"
    "CWSInfoFastCheck"                                      = "cws-info-fast-check"
    "DataSharing"                                           = "data-sharing"
    "DataSharingJoinOnly"                                   = "data-sharing-join-only"
    "DefaultSearchEnginePrewarm"                            = "default-search-engine-prewarm"
    "EnableCrossDevicePrefTracker"                          = "enable-cross-device-pref-tracker"
    "EnableOidcProfileRemoteCommands"                       = "enable-oidc-profile-remote-commands"
    "ShoppingAlternateServer"                               = "shopping-alternate-server"
    "GroupSuggestionService"                                = "group-suggestion-service"
    "ExtensionDisableUnsupportedDeveloper"                  = "extension-disable-unsupported-developer-mode-extensions"
    "SearchPrefetchServicePrefetching"                      = "omnibox-search-prefetch"
    "SearchNavigationPrefetch"                              = "search-navigation-prefetch"
    "BookmarkTriggerForPrefetch"                            = "prefetch-bookmarkbar-trigger"
    "DsePreload2"                                           = "dse-preload2"
    "DsePreload2OnPress"                                    = "dse-preload2-on-press"
    "IpProtectionProxyOptOut"                               = "ip-protection-proxy-opt-out"
    "OfferMigrationToDiceUsers"                             = "offer-migration-to-dice-users"
    "OmniboxContextualSearchOnFocusSuggestions"             = "omnibox-contextual-search-on-focus-suggestions"
    "OmniboxContextualSuggestions"                          = "omnibox-contextual-suggestions"
    "OmniboxEnterpriseSearchAggregator"                     = "omnibox-enterprise-search-aggregator"
    "OmniboxFocusTriggersWebAndSrpZeroSuggest"              = "omnibox-focus-triggers-web-and-srp-zero-suggest"
    "OmniboxMiaZPS"                                         = "omnibox-mia-zps"
    "OmniboxOnDeviceHeadProviderIncognito"                  = "omnibox-on-device-head-suggestions-incognito"
    "OmniboxSearchClientPrefetch"                           = "omnibox-search-client-prefetch"
    "OmniboxToolbelt"                                       = "omnibox-toolbelt"
    "OmniboxZeroSuggestPrefetching"                         = "omnibox-zero-suggest-prefetching"
    "OmniboxZeroSuggestPrefetchingOnSRP"                    = "omnibox-zero-suggest-prefetching-on-srp"
    "OmniboxZeroSuggestPrefetchingOnWeb"                    = "omnibox-zero-suggest-prefetching-on-web"
    "OptimizationGuideDogfoodLogging"                       = "optimization-guide-enable-dogfood-logging"
    "PageContentAnnotationsRemotePageMetadata"              = "page-content-annotations-remote-page-metadata"
    "PermissionsAIP92"                                      = "permissions-ai-p92"
    "PermissionsAIv3"                                       = "permissions-ai-v3"
    "PermissionsAIv4"                                       = "permissions-ai-v4"
    "ProductSpecifications"                                 = "product-specifications"
    "RcapsDynamicProfileCountry"                            = "rcaps-dynamic-profile-country"
    "AutoPictureInPictureForVideoPlayback"                  = "auto-picture-in-picture-for-video-playback"
    "BrowserInitiatedAutomaticPictureInPicture"             = "browser-initiated-automatic-picture-in-picture"
    "VideoPictureInPictureControlsUpdate2024"               = "video-picture-in-picture-controls-update-2024"
    "SafetyHubDisruptiveNotificationRevocation"             = "safety-hub-disruptive-notification-revocation"
    "ImprovedPasswordChangeService"                         = "improved-password-change-service"
    "MarkAllCredentialsAsLeaked"                            = "mark-all-credentials-as-leaked"
    "SafetyHubUnusedPermissionRevocationForAllSurfaces"     = "safety-hub-unused-permission-revocation-for-all-surfaces"
    "TextSafetyClassifier"                                  = "text-safety-classifier"
    "WebAppMigratePreinstalledChat"                         = "web-app-migrate-preinstalled-chat"
    "WebAuthenticationPasskeyUpgrade"                       = "web-authentication-passkey-upgrade"
    "LinkPreview"                                           = "link-preview"
    "MobilePromoOnDesktop"                                  = "mobile-promo-on-desktop"
    "AvatarButtonSyncPromo"                                 = "avatar-button-sync-promo"
    "EnforceManagementDisclaimer"                           = "enforce-management-disclaimer"
    "IPH_DemoMode"                                          = "in-product-help-demo-mode-choice"
    "ProfileCreationDeclineSigninCTAExperiment"             = "profile-creation-decline-signin-cta-experiment"
    # NOTE: ReplaceSyncPromosWithSignInPromos intentionally has NO mapping here.
    # It lacks reliable chrome://flags support and must be disabled via --disable-features
    "ShowProfilePickerToAllUsersExperiment"                 = "show-profile-picker-to-all-users-experiment"
    "WebUIOmniboxAimPopup"                                  = "webui-omnibox-aim-popup"
    "PdfSaveToDrive"                                        = "pdf-save-to-drive"
    "PrivacyPolicyInsights"                                 = "privacy-policy-insights"
    "ReadAnythingDocsIntegration"                           = "read-anything-docs-integration"
    "ReadAnythingDocsLoadMoreButton"                        = "read-anything-docs-load-more-button"
    "ReadPrinterCapabilitiesWithXps"                        = "read-printer-capabilities-with-xps"
    "AimServerEligibilityEnabled"                           = "aim-server-eligibility"
    "AllowAiModeMatches"                                    = "omnibox-allow-ai-mode-matches"

    # === NEW DISABLE FEATURES (from chrome://flags) ===
    # Network
    "FeedbackIncludeVariations"                             = "feedback-include-variations"
    "ProfileSignalsReportingEnabled"                        = "profile-signals-reporting-enabled"

    # AI API Features
    "AiModeOmniboxEntryPoint"                               = "ai-mode-omnibox-entry-point"

    # NOTE: Glic* and Lens* features intentionally have NO mappings here.
    # They lack chrome://flags equivalents and must be disabled via --disable-features
    # on the command line. See Get-CommandLineOnlyFeatures.

    # Autofill Additional Features
    "AutofillEnableAllowlistForBmoCardCategoryBenefits"     = "autofill-enable-allowlist-for-bmo-card-category-benefits"
    "AutofillEnableBuyNowPayLaterForExternallyLinked"       = "autofill-enable-buy-now-pay-later-for-externally-linked"
    "AutofillEnableBuyNowPayLaterForKlarna"                 = "autofill-enable-buy-now-pay-later-for-klarna"
    "AutofillEnableBuyNowPayLaterSyncing"                   = "autofill-enable-buy-now-pay-later-syncing"
    "AutofillEnableBuyNowPayLaterUpdatedSuggestionSecondLineString" = "autofill-enable-buy-now-pay-later-updated-suggestion-second-line-string"
    "AutofillEnableCardBenefitsForAmericanExpress"          = "autofill-enable-card-benefits-for-american-express"
    "AutofillEnableCardBenefitsForBmo"                      = "autofill-enable-card-benefits-for-bmo"
    "AutofillEnableCardBenefitsIph"                         = "autofill-enable-card-benefits-iph"
    "AutofillEnableDownstreamCardAwarenessIph"              = "autofill-enable-downstream-card-awareness-iph"
    "AutofillEnableFlatRateCardBenefitsFromCurinos"         = "autofill-enable-flat-rate-card-benefits-from-curinos"
    "AutofillEnableMultipleRequestInVirtualCardDownstreamEnrollment" = "autofill-enable-multiple-request-in-virtual-card-downstream-enrollment"
    "AutofillEnablePrefetchingRiskDataForRetrieval"         = "autofill-enable-prefetching-risk-data-for-retrieval"
    "AutofillPreferBuyNowPayLaterBlocklists"                = "autofill-prefer-buy-now-pay-later-blocklists"

    # NTP Additional Features
    "NtpModuleSignInRequirement"                            = "ntp-module-sign-in-requirement"
    "NtpOneGoogleBarAsyncBarParts"                          = "ntp-ogb-async-bar-parts"
    "NtpSearchboxComposeEntrypoint"                         = "ntp-compose-entrypoint"

    # Sync Features
    "SyncAutofillLoyaltyCard"                               = "autofill-enable-syncing-of-loyalty-cards"
    "SyncAutofillWalletCredentialData"                      = "sync-autofill-wallet-credential-data"

    # Data Sharing
    "DataSharingNonProductionEnvironment"                   = "data-sharing-non-production-environment"
    # NOTE: SharedDataTypesKillSwitch intentionally has NO mapping here.
    # It lacks reliable chrome://flags support and must be disabled via --disable-features

    # Contextual Search
    "ContextualSearchOpenLensActionUsesThumbnail"           = "contextual-search-open-lens-action-uses-thumbnail"

    # IPH Feature
    "IPH_AutofillCreditCardBenefit"                         = "iph-autofill-credit-card-benefit-feature"

    # Comet-specific
    "PerplexityAutoupdate"                                  = "perplexity-autoupdate"
}

#endregion

#region Helper Functions

function Write-Status {
    <#
    .SYNOPSIS
        Write a timestamped status message to the console.
    .DESCRIPTION
        Outputs formatted status messages with consistent timestamps and color coding.
        Supports common parameters like -Verbose through CmdletBinding.

        Color Scheme:
        - Info    (Cyan):       General informational messages [*]
        - Success (Green):      Operation completed successfully [+]
        - Warning (Yellow):     Non-critical issues or cautions [!]
        - Error   (Red):        Errors or failures [!]
        - Detail  (Gray):       Sub-item details, indented with ->
        - Step    (Magenta):    Major workflow step headers ===
        - DryRun  (DarkYellow): Dry-run mode indicators [DRY]
    .OUTPUTS
        [void]
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Detail", "Step", "DryRun")]
        [string]$Type = "Info",
        [switch]$NoNewline
    )

    $timestamp = Get-Date -Format "HH:mm:ss.fff"

    # Build Write-Host parameters
    $writeParams = @{ NoNewline = $NoNewline.IsPresent }

    switch ($Type) {
        "Info"    { Write-Host "[$timestamp] [*] $Message" -ForegroundColor Cyan @writeParams }
        "Success" { Write-Host "[$timestamp] [+] $Message" -ForegroundColor Green @writeParams }
        "Warning" { Write-Host "[$timestamp] [!] $Message" -ForegroundColor Yellow @writeParams }
        "Error"   { Write-Host "[$timestamp] [!] $Message" -ForegroundColor Red @writeParams }
        "Detail"  { Write-Host "[$timestamp]     -> $Message" -ForegroundColor Gray @writeParams }
        "Step"    { Write-Host "`n[$timestamp] === $Message ===" -ForegroundColor Magenta @writeParams }
        "DryRun"  { Write-Host "[$timestamp] [DRY] $Message" -ForegroundColor DarkYellow @writeParams }
    }
}

function ConvertTo-HexString {
    <#
    .SYNOPSIS
        Convert a byte array to a hexadecimal string.
    .DESCRIPTION
        Converts each byte to its two-character hexadecimal representation.
        Returns an empty string for empty arrays.
    .OUTPUTS
        [string]
    .EXAMPLE
        ConvertTo-HexString -Bytes @(0xDE, 0xAD, 0xBE, 0xEF)
        # Returns "DEADBEEF"
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -eq 0) {
        return [string]::Empty
    }

    return [BitConverter]::ToString($Bytes) -replace '-', ''
}

function ConvertFrom-HexString {
    <#
    .SYNOPSIS
        Convert a hexadecimal string to a byte array.
    .DESCRIPTION
        Parses a hexadecimal string and returns the corresponding byte array.
        Validates that the string has even length and contains only hex characters.
    .OUTPUTS
        [byte[]]
    .EXAMPLE
        ConvertFrom-HexString -HexString "DEADBEEF"
        # Returns byte array @(0xDE, 0xAD, 0xBE, 0xEF)
    #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$HexString
    )

    # Validate hex string length is even
    if ($HexString.Length % 2 -ne 0) {
        throw "Invalid hex string: length must be even (got $($HexString.Length) characters)"
    }

    # Validate hex string contains only valid hex characters
    if ($HexString -notmatch '^[0-9A-Fa-f]*$') {
        throw "Invalid hex string: contains non-hexadecimal characters"
    }

    $bytes = [byte[]]::new($HexString.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($HexString.Substring($i * 2, 2), 16)
    }

    return ,$bytes
}

function Write-VerboseTimestamped {
    param([string]$Message)

    if ($VerbosePreference -eq 'Continue') {
        $timestamp = Get-Date -Format "HH:mm:ss.fff"
        Write-Host "[$timestamp] [V] $Message" -ForegroundColor DarkGray
    }
}

function Invoke-WebRequestTimestamped {
    <#
    .SYNOPSIS
        Wrapper for Invoke-WebRequest that timestamps verbose output.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        [string]$Method = 'Get',
        [string]$OutFile,
        [hashtable]$Headers,
        [int]$TimeoutSec = 30,
        [int]$MaximumRedirection = 5,
        [switch]$UseBasicParsing
    )

    $params = @{
        Uri = $Uri
        Method = $Method
        UseBasicParsing = $UseBasicParsing
        TimeoutSec = $TimeoutSec
        MaximumRedirection = $MaximumRedirection
        Verbose = ($VerbosePreference -eq 'Continue')
    }
    if ($Headers) { $params.Headers = $Headers }
    if ($OutFile) { $params.OutFile = $OutFile }

    # Capture verbose stream (4) and merge to output
    $output = Invoke-WebRequest @params 4>&1

    foreach ($item in $output) {
        if ($item -is [System.Management.Automation.VerboseRecord]) {
            Write-VerboseTimestamped $item.Message
        }
        else {
            # Return non-verbose output (the actual response)
            $item
        }
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

function Get-StringHash256 {
    <#
    .SYNOPSIS
        Compute SHA256 hash of a string.
    .DESCRIPTION
        Used for deterministic config hashing to detect configuration changes.
    #>
    param([string]$Content)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function New-DirectoryIfNotExists {
    <#
    .SYNOPSIS
        Create a directory if it doesn't exist.
    .DESCRIPTION
        Wrapper for New-Item -ItemType Directory that checks existence first.
        Reduces boilerplate and suppresses output.
    #>
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

function Get-JsonFile {
    <#
    .SYNOPSIS
        Read and parse a JSON file.
    .DESCRIPTION
        Wrapper for Get-Content + ConvertFrom-Json with consistent UTF8 encoding.
    #>
    param([string]$Path)

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    return $content | ConvertFrom-Json
}

function Save-JsonFile {
    <#
    .SYNOPSIS
        Save object to JSON file.
    .DESCRIPTION
        Wrapper for ConvertTo-Json + Set-Content with consistent UTF8 encoding and depth.
    #>
    param(
        [string]$Path,
        [object]$Object,
        [int]$Depth = 30,
        [switch]$Compress
    )

    $json = ConvertTo-Json -InputObject $Object -Depth $Depth -Compress:$Compress
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Test-IsEmptyContainer {
    <#
    .SYNOPSIS
        Test if a value is an empty container (null, empty array, empty hashtable, etc.)

    .DESCRIPTION
        PURPOSE: Support function for ConvertTo-SortedObject to identify values that should
        be pruned during JSON serialization to match Chromium's PrefHashCalculator behavior.

        EMPTY CONTAINER TYPES:
        - $null
        - Empty array: @()
        - Empty hashtable: @{}
        - Empty OrderedDictionary: [ordered]@{}
        - Empty PSCustomObject: New-Object PSCustomObject

        WHY PRUNING MATTERS:
        Chromium's MAC calculation prunes empty containers from dictionary values.
        If we don't prune them, our serialized JSON won't match Chromium's format,
        and the calculated MAC will be incorrect.

        NOTE: This only checks if a container IS empty, not if it CONTAINS empty containers.
        ConvertTo-SortedObject handles recursive pruning by calling this on each value.

    .PARAMETER Value
        The value to test for emptiness.

    .OUTPUTS
        $true if the value is null or an empty container, $false otherwise.

    .EXAMPLE
        Test-IsEmptyContainer -Value @()
        # Returns: $true

    .EXAMPLE
        Test-IsEmptyContainer -Value @(1, 2, 3)
        # Returns: $false

    .NOTES
        Used internally by ConvertTo-SortedObject for MAC calculation preparation.
    #>
    [OutputType([bool])]
    param(
        [object]$Value
    )

    if ($null -eq $Value) { return $true }
    if ($Value -is [array] -and $Value.Count -eq 0) { return $true }
    if ($Value -is [hashtable] -and $Value.Count -eq 0) { return $true }
    if ($Value -is [System.Collections.Specialized.OrderedDictionary] -and $Value.Count -eq 0) { return $true }
    if ($Value -is [PSCustomObject] -and $Value.PSObject.Properties.Count -eq 0) { return $true }
    return $false
}

function Set-NestedValue {
    <#
    .SYNOPSIS
        Set a value in a nested hashtable using a dot-separated path.
    .DESCRIPTION
        Navigates/creates nested hashtable structure and sets the final value.
        Example: Set-NestedValue -Hashtable $h -Path "browser.show_home_button" -Value $true
    #>
    param(
        [hashtable]$Hashtable,
        [string]$Path,
        [object]$Value
    )

    $parts = $Path -split '\.'
    $current = $Hashtable

    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        if (-not $current.ContainsKey($part)) {
            $current[$part] = @{}
        }
        elseif ($current[$part] -isnot [hashtable]) {
            $current[$part] = @{}
        }
        $current = $current[$part]
    }

    $current[$parts[-1]] = $Value
}

function Get-NestedValue {
    <#
    .SYNOPSIS
        Get a value from a nested hashtable using a dot-separated path.
    .DESCRIPTION
        Navigates nested hashtable structure and returns the value.
        Returns $null if path doesn't exist.
    .OUTPUTS
        Hashtable with Found (bool) and Value properties.
    #>
    param(
        [object]$Object,
        [string]$Path
    )

    $parts = $Path -split '\.'
    $current = $Object

    foreach ($part in $parts) {
        if ($current -is [hashtable] -and $current.ContainsKey($part)) {
            $current = $current[$part]
        }
        elseif ($current -is [PSCustomObject] -and $current.PSObject.Properties.Name -contains $part) {
            $current = $current.$part
        }
        else {
            return @{ Found = $false; Value = $null }
        }
    }

    return @{ Found = $true; Value = $current }
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

function Write-BytesToStream {
    <#
    .SYNOPSIS
        Write byte array to a stream.
    #>
    param(
        [System.IO.Stream]$Stream,
        [byte[]]$Bytes
    )
    $Stream.Write($Bytes, 0, $Bytes.Length)
}

function Expand-GzipData {
    <#
    .SYNOPSIS
        Decompress gzip-compressed byte array.
    .DESCRIPTION
        Takes a gzip-compressed byte array and returns the decompressed data.
        Returns $null on decompression failure.
    #>
    param([byte[]]$CompressedBytes)

    $inputStream = $null
    $gzipStream = $null
    $outputStream = $null

    try {
        $inputStream = New-Object System.IO.MemoryStream($CompressedBytes, $false)
        $gzipStream = New-Object System.IO.Compression.GZipStream(
            $inputStream,
            [System.IO.Compression.CompressionMode]::Decompress
        )
        $outputStream = New-Object System.IO.MemoryStream
        $gzipStream.CopyTo($outputStream)
        return $outputStream.ToArray()
    }
    catch {
        return $null
    }
    finally {
        # GZipStream owns inputStream (leaveOpen=false by default)
        if ($null -ne $gzipStream) { $gzipStream.Dispose() }
        if ($null -ne $outputStream) { $outputStream.Dispose() }
    }
}

function Compress-GzipData {
    <#
    .SYNOPSIS
        Compress byte array using gzip.
    .DESCRIPTION
        Takes a byte array and returns gzip-compressed data.
        Throws on compression failure (unlike Expand-GzipData which returns $null).
    #>
    param([byte[]]$UncompressedBytes)

    $outputStream = $null
    $gzipStream = $null

    try {
        $outputStream = New-Object System.IO.MemoryStream
        $gzipStream = New-Object System.IO.Compression.GZipStream(
            $outputStream,
            [System.IO.Compression.CompressionMode]::Compress
        )
        $gzipStream.Write($UncompressedBytes, 0, $UncompressedBytes.Length)
        $gzipStream.Close()  # Must close before ToArray to flush
        return $outputStream.ToArray()
    }
    finally {
        if ($null -ne $gzipStream) { $gzipStream.Dispose() }
        if ($null -ne $outputStream) { $outputStream.Dispose() }
    }
    # No catch block - let exceptions propagate to prevent silent corruption
}

function Test-BinaryContent {
    <#
    .SYNOPSIS
        Test if byte array contains binary (non-text) content.
    .DESCRIPTION
        Checks bytes directly for binary indicators (null bytes and control characters).
        Only scans first 8KB for efficiency - avoids full UTF-8 string conversion.
    .RETURNS
        $true if content appears to be binary, $false if it appears to be text.
    #>
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return $false
    }

    # Check first 8KB for binary indicators (sufficient for detection)
    $checkLength = [Math]::Min($Bytes.Length, 8192)
    for ($i = 0; $i -lt $checkLength; $i++) {
        $b = $Bytes[$i]
        # Binary indicators: null byte or control chars (except tab=9, LF=10, CR=13)
        if ($b -eq 0 -or ($b -lt 32 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13)) {
            return $true
        }
    }
    return $false
}

function Find-CometVersionDirectory {
    <#
    .SYNOPSIS
        Find the version directory inside a Comet installation.
    .DESCRIPTION
        Looks for directories matching version pattern (e.g., "131.0.6778.140")
        and returns the one with the highest version number.
    #>
    param([string]$CometPath)

    if (-not (Test-Path $CometPath)) {
        return $null
    }

    # Wrap in @() to ensure array - single item doesn't have .Count in PS 5.1
    $versionDirs = @(Get-ChildItem -Path $CometPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
        Sort-Object { [Version]($_.Name -replace '^(\d+\.\d+\.\d+\.\d+).*', '$1') } -Descending)

    if ($versionDirs.Count -gt 0) {
        return $versionDirs[0]
    }

    return $null
}

function Get-DefaultAppsDirectory {
    <#
    .SYNOPSIS
        Find the default_apps directory in a Comet installation.
    .DESCRIPTION
        Searches for the default_apps directory, which may be in the root
        or in a version subdirectory (e.g., .meteor/comet/143.2.7499.37654/default_apps).
    #>
    param([string]$CometDir)

    $defaultAppsDir = Join-Path $CometDir "default_apps"
    if (Test-Path $defaultAppsDir) {
        return $defaultAppsDir
    }

    # Try version subdirectory
    $versionDirs = Get-ChildItem -Path $CometDir -Directory -ErrorAction SilentlyContinue
    foreach ($vDir in $versionDirs) {
        $subDefaultApps = Join-Path $vDir.FullName "default_apps"
        if (Test-Path $subDefaultApps) {
            return $subDefaultApps
        }
    }

    return $null
}

function Invoke-MeteorWebRequest {
    <#
    .SYNOPSIS
        Unified web request helper with consistent settings.
    .DESCRIPTION
        Handles three modes of web requests:
        - Content: Returns response content (for API calls)
        - Download: Downloads to file (for smaller files)
        - Redirect: Returns redirect URL without following (for version checks)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [ValidateSet('Content', 'Download', 'Redirect')]
        [string]$Mode = 'Content',

        [string]$OutFile,

        [int]$TimeoutSec = 30
    )

    # Ensure TLS 1.2 is enabled
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $headers = @{
        "User-Agent" = $script:UserAgent
    }

    try {
        switch ($Mode) {
            'Content' {
                $response = Invoke-WebRequestTimestamped -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -Headers $headers
                return $response.Content
            }
            'Download' {
                if (-not $OutFile) {
                    throw "OutFile is required for Download mode"
                }
                Invoke-WebRequestTimestamped -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -Headers $headers
                return $true
            }
            'Redirect' {
                try {
                    $response = Invoke-WebRequestTimestamped -Uri $Uri -Method Get -UseBasicParsing -MaximumRedirection 0 -Headers $headers
                    return $null
                }
                catch {
                    if ($_.Exception.Response.StatusCode -eq 302 -or $_.Exception.Response.StatusCode -eq 301) {
                        return $_.Exception.Response.Headers.Location
                    }
                    throw
                }
            }
        }
    }
    catch {
        Write-VerboseTimestamped "Web request failed: $_"
        throw
    }
}

function Invoke-MeteorDownload {
    <#
    .SYNOPSIS
        Download large files using WebClient for better performance.
    .DESCRIPTION
        Uses System.Net.WebClient for downloading large files like browser installers.
        Provides progress indication via events.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$OutFile
    )

    # Ensure TLS 1.2 is enabled
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("User-Agent", $script:UserAgent)

    try {
        $webClient.DownloadFile($Uri, $OutFile)
        return $true
    }
    finally {
        $webClient.Dispose()
    }
}

function New-EppoConfigBlob {
    <#
    .SYNOPSIS
        Creates a gzipped base64-encoded Eppo feature flag config blob.

    .DESCRIPTION
        The Comet browser stores feature flags in a gzipped JSON blob at perplexity.features.value.
        This function creates a custom blob with our desired flag values, which takes precedence
        over individual perplexity.feature.* settings for flags that exist in the blob.

        Flags NOT in the blob fall back to browser defaults, so we must explicitly include
        all flags we want to control (like nav-logging which defaults to true if not in blob).

    .PARAMETER FeatureFlags
        Hashtable of feature flag names to values (bool, string, or complex objects).

    .OUTPUTS
        Base64-encoded gzipped JSON string suitable for perplexity.features.value.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$FeatureFlags
    )

    # Convert hashtable to sorted JSON (Eppo uses alphabetically sorted keys)
    $sortedFlags = [ordered]@{}
    foreach ($key in ($FeatureFlags.Keys | Sort-Object)) {
        $sortedFlags[$key] = $FeatureFlags[$key]
    }

    # Use compact JSON without extra whitespace
    $json = $sortedFlags | ConvertTo-Json -Depth 10 -Compress

    # Convert to UTF-8 bytes
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    # Gzip compress
    $memoryStream = New-Object System.IO.MemoryStream
    try {
        $gzipStream = New-Object System.IO.Compression.GZipStream(
            $memoryStream,
            [System.IO.Compression.CompressionMode]::Compress,
            $true  # leaveOpen
        )
        try {
            $gzipStream.Write($jsonBytes, 0, $jsonBytes.Length)
        }
        finally {
            $gzipStream.Close()
        }

        # Get compressed bytes and base64 encode
        $compressedBytes = $memoryStream.ToArray()
        return [Convert]::ToBase64String($compressedBytes)
    }
    finally {
        $memoryStream.Dispose()
    }
}

#endregion

#region Configuration

function Get-MeteorConfig {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        throw "Config not found: $ConfigPath"
    }

    return Get-JsonFile -Path $ConfigPath
}

function Resolve-MeteorPath {
    param(
        [string]$BasePath,
        [string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        return $RelativePath
    }

    # Strip leading ./ or .\ to avoid double-dot paths when joining
    $cleanPath = $RelativePath -replace '^\.[\\/]', ''

    return (Join-Path $BasePath $cleanPath)
}

function Test-MeteorConfig {
    <#
    .SYNOPSIS
        Validates that the Meteor configuration has all required sections and paths.
    .DESCRIPTION
        Fails fast with a clear error message if required configuration is missing.
        Called early in the workflow to catch config issues before any changes are made.
    #>
    param([PSCustomObject]$Config)

    $requiredSections = @('comet', 'browser', 'extensions', 'paths', 'pak_modifications', 'ublock')
    $requiredPaths = @('patched_extensions', 'ublock', 'state_file', 'patches')

    # Check required top-level sections
    foreach ($section in $requiredSections) {
        if (-not $Config.PSObject.Properties.Name -contains $section) {
            throw "Config validation failed: missing required section '$section'"
        }
        if ($null -eq $Config.$section) {
            throw "Config validation failed: section '$section' is null"
        }
    }

    # Check required paths
    foreach ($pathName in $requiredPaths) {
        if (-not $Config.paths.PSObject.Properties.Name -contains $pathName) {
            throw "Config validation failed: missing required path 'paths.$pathName'"
        }
        if ([string]::IsNullOrWhiteSpace($Config.paths.$pathName)) {
            throw "Config validation failed: path 'paths.$pathName' is empty"
        }
    }

    # Check browser has required settings
    if (-not $Config.browser.PSObject.Properties.Name -contains 'flags') {
        throw "Config validation failed: missing 'browser.flags'"
    }

    # Check extensions has required settings
    if (-not $Config.extensions.PSObject.Properties.Name -contains 'bundled') {
        throw "Config validation failed: missing 'extensions.bundled'"
    }

    return $true
}

function Invoke-Parallel {
    <#
    .SYNOPSIS
        Execute scriptblocks in parallel using runspace pool.
    .DESCRIPTION
        Low-overhead parallel execution for PS 5.1 compatibility.
        Each task receives arguments positionally via AddArgument.
        Functions from the main script are NOT available inside runspaces.
    .PARAMETER Tasks
        Array of @{ Script = [scriptblock]; Args = @(...) }
    .PARAMETER MaxThreads
        Maximum concurrent threads (default: 4)
    .RETURNS
        Array of results from all tasks
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Tasks,

        [int]$MaxThreads = 4
    )

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $runspacePool.Open()

    $runspaces = @()

    foreach ($task in $Tasks) {
        $powershell = [powershell]::Create()
        $powershell.RunspacePool = $runspacePool
        [void]$powershell.AddScript($task.Script)

        # Add arguments positionally (PS 5.1 compatible)
        foreach ($arg in $task.Args) {
            [void]$powershell.AddArgument($arg)
        }

        $runspaces += @{
            PowerShell = $powershell
            Handle     = $powershell.BeginInvoke()
        }
    }

    # Wait for all to complete and collect results with error handling
    $results = @()
    foreach ($rs in $runspaces) {
        try {
            $results += $rs.PowerShell.EndInvoke($rs.Handle)
        }
        finally {
            # Surface any errors from the runspace
            if ($rs.PowerShell.HadErrors) {
                foreach ($err in $rs.PowerShell.Streams.Error) {
                    Write-Warning "Parallel task error: $err"
                }
            }
            $rs.PowerShell.Dispose()
        }
    }

    $runspacePool.Close()
    $runspacePool.Dispose()

    return , $results  # Comma preserves array in PS 5.1
}

function Start-BackgroundRunspace {
    <#
    .SYNOPSIS
        Start a scriptblock in a background runspace (non-blocking).
    .DESCRIPTION
        Executes a scriptblock asynchronously in its own runspace.
        Returns a task object that can be passed to Wait-BackgroundRunspace.
        Use this for true parallel execution without blocking the main thread.
    .PARAMETER Script
        The scriptblock to execute.
    .PARAMETER Args
        Array of arguments to pass to the scriptblock.
    .OUTPUTS
        Hashtable with PowerShell, Handle, and Runspace objects for tracking.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Script,

        [Parameter()]
        [array]$Args = @()
    )

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($Script)
    foreach ($arg in $Args) {
        [void]$ps.AddArgument($arg)
    }

    $handle = $ps.BeginInvoke()

    return @{
        PowerShell = $ps
        Handle     = $handle
        Runspace   = $runspace
    }
}

function Wait-BackgroundRunspace {
    <#
    .SYNOPSIS
        Wait for a background runspace to complete and retrieve its result.
    .DESCRIPTION
        Blocks until the background task completes, then returns the result.
        Also cleans up the runspace resources.
    .PARAMETER Task
        The task object returned by Start-BackgroundRunspace.
    .OUTPUTS
        The result returned by the background scriptblock.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Task
    )

    try {
        $result = $Task.PowerShell.EndInvoke($Task.Handle)

        # Surface any errors from the runspace
        if ($Task.PowerShell.HadErrors) {
            foreach ($err in $Task.PowerShell.Streams.Error) {
                Write-Warning "Background task error: $err"
            }
        }

        # Return the last result (or $null if empty)
        if ($result -and $result.Count -gt 0) {
            return $result[$result.Count - 1]
        }
        return $null
    }
    finally {
        $Task.PowerShell.Dispose()
        $Task.Runspace.Close()
        $Task.Runspace.Dispose()
    }
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
            pak_state          = $null
        }
    }

    $state = ConvertTo-Hashtable (Get-JsonFile -Path $StatePath)

    # State migration: add pak_state if missing (for existing state files)
    if (-not $state.ContainsKey('pak_state')) {
        $state['pak_state'] = $null
    }

    return $state
}

function Save-MeteorState {
    param(
        [string]$StatePath,
        [hashtable]$State
    )

    New-DirectoryIfNotExists -Path (Split-Path -Parent $StatePath)

    $State.version = $script:MeteorVersion
    Save-JsonFile -Path $StatePath -Object $State -Depth 10
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

    # Build hash index for O(1) resource lookup (optimization)
    # This eliminates O(n) linear search in Get-PakResource
    # Cast to [int] to ensure consistent key type (Id comes as UInt16, lookups use int)
    $resourceIndex = @{}
    for ($i = 0; $i -lt $pak.Resources.Count; $i++) {
        $resourceIndex[[int]$pak.Resources[$i].Id] = $i
    }
    $pak.ResourceIndex = $resourceIndex

    return $pak
}

function Get-PakResource {
    <#
    .SYNOPSIS
        Get the content of a specific resource from a PAK file.
    .DESCRIPTION
        Uses hash index for O(1) lookup instead of O(n) linear search.
        The index is built during Read-PakFile.
    #>
    param(
        [hashtable]$Pak,
        [int]$ResourceId
    )

    # Use hash index for O(1) lookup (built in Read-PakFile)
    if ($Pak.ResourceIndex -and $Pak.ResourceIndex.ContainsKey($ResourceId)) {
        $i = $Pak.ResourceIndex[$ResourceId]

        # Bounds check: ensure there's a next entry (sentinel) for length calculation
        if ($i -ge $Pak.Resources.Count - 1) {
            return $null
        }

        $startOffset = $Pak.Resources[$i].Offset
        $endOffset = $Pak.Resources[$i + 1].Offset
        $length = $endOffset - $startOffset

        $data = New-Object byte[] $length
        [Array]::Copy($Pak.RawBytes, $startOffset, $data, 0, $length)

        # Use comma to prevent PowerShell from unwrapping single-element arrays
        return ,$data
    }

    return $null
}

function Set-PakResource {
    <#
    .SYNOPSIS
        Replace the content of a specific resource in a PAK structure.
    .DESCRIPTION
        Updates the PAK structure in-memory. Use Write-PakFile to save.

        DEPRECATION NOTICE: For bulk modifications, prefer Write-PakFileWithModifications
        which applies all changes in a single pass (O(n) vs O(n²) memory).
        This function is retained for single-resource updates where batch writing
        is not appropriate.
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
    .DESCRIPTION
        Optimized writer using FileStream for direct writes without intermediate
        ArrayList allocation. Supports both RawBytes (from Read-PakFile) and
        Data property (from Import-PakResources) source modes.
        This function does NOT mutate $Pak.Resources[].Offset.
    #>
    param(
        [hashtable]$Pak,
        [string]$Path
    )

    # Input validation
    if ($null -eq $Pak -or $null -eq $Pak.Resources -or $Pak.Resources.Count -eq 0) {
        throw "Invalid PAK structure: missing or empty Resources"
    }

    # Determine source mode: Data property (from Import) vs RawBytes (from Read)
    $useDataProperty = ($Pak.Resources.Count -gt 0 -and
                        $null -ne $Pak.Resources[0].Data -and
                        $null -eq $Pak.RawBytes)

    $numResources = $Pak.Resources.Count - 1  # Exclude sentinel

    # Calculate header size
    if ($Pak.Version -eq 4) {
        $headerSize = 4 + 1 + 4  # version + encoding + num_resources
    }
    else {
        $headerSize = 4 + 1 + 3 + 2 + 2  # version + encoding + padding + num_resources + num_aliases
    }

    $resourceTableSize = $Pak.Resources.Count * 6
    $aliasTableSize = $Pak.Aliases.Count * 4
    $dataStartOffset = $headerSize + $resourceTableSize + $aliasTableSize

    # Calculate new offsets
    $currentDataOffset = $dataStartOffset
    $resourceInfo = New-Object System.Collections.ArrayList($Pak.Resources.Count)

    for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
        if ($useDataProperty) {
            $length = $Pak.Resources[$i].Data.Length
            $info = @{ NewOffset = $currentDataOffset; Data = $Pak.Resources[$i].Data }
        }
        else {
            $startOffset = $Pak.Resources[$i].Offset
            $endOffset = $Pak.Resources[$i + 1].Offset
            $length = $endOffset - $startOffset
            $info = @{ NewOffset = $currentDataOffset; SrcOffset = $startOffset; Length = $length }
        }
        [void]$resourceInfo.Add($info)
        $currentDataOffset += $length
    }

    $sentinelOffset = $currentDataOffset

    # Write directly to file
    $fileStream = [System.IO.File]::Create($Path)
    try {
        # Header
        Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt32ToBytes -Value $Pak.Version)
        $fileStream.WriteByte($Pak.Encoding)

        if ($Pak.Version -eq 4) {
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt32ToBytes -Value $numResources)
        }
        else {
            $fileStream.WriteByte(0); $fileStream.WriteByte(0); $fileStream.WriteByte(0)
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$numResources))
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$Pak.Aliases.Count))
        }

        # Resource table
        for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$Pak.Resources[$i].Id))
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt32ToBytes -Value ([uint32]$resourceInfo[$i].NewOffset))
        }

        # Sentinel
        Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$Pak.Resources[$Pak.Resources.Count - 1].Id))
        Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt32ToBytes -Value ([uint32]$sentinelOffset))

        # Aliases
        foreach ($alias in $Pak.Aliases) {
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$alias.Id))
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$alias.ResourceIndex))
        }

        # Resource data - direct writes
        for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
            if ($useDataProperty) {
                Write-BytesToStream -Stream $fileStream -Bytes $resourceInfo[$i].Data
            }
            else {
                $fileStream.Write($Pak.RawBytes, $resourceInfo[$i].SrcOffset, $resourceInfo[$i].Length)
            }
        }
    }
    finally {
        $fileStream.Close()
        $fileStream.Dispose()
    }
}

function Write-PakFileWithModifications {
    <#
    .SYNOPSIS
        Write a PAK file with multiple resource modifications in a single pass.
    .DESCRIPTION
        Optimized batch writer using FileStream. Takes a hashtable of modifications
        and applies them all during the write operation.
        This function does NOT modify Pak.RawBytes, making it safe for repeated use.
    .PARAMETER Pak
        The PAK structure from Read-PakFile.
    .PARAMETER Path
        Output file path.
    .PARAMETER Modifications
        Hashtable mapping ResourceId (int) -> NewData (byte[]).
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Pak,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Modifications
    )

    # Input validation
    if ($null -eq $Pak -or $null -eq $Pak.Resources -or $Pak.Resources.Count -eq 0) {
        throw "Invalid PAK structure: missing or empty Resources"
    }

    $numResources = $Pak.Resources.Count - 1  # Exclude sentinel

    # Calculate header size
    if ($Pak.Version -eq 4) {
        $headerSize = 4 + 1 + 4
    }
    else {
        $headerSize = 4 + 1 + 3 + 2 + 2
    }

    $resourceTableSize = $Pak.Resources.Count * 6
    $aliasTableSize = $Pak.Aliases.Count * 4
    $dataStartOffset = $headerSize + $resourceTableSize + $aliasTableSize

    # Build resource info and calculate new offsets
    $currentDataOffset = $dataStartOffset
    $resourceInfo = New-Object System.Collections.ArrayList($Pak.Resources.Count)

    for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
        $resourceId = $Pak.Resources[$i].Id
        $startOffset = $Pak.Resources[$i].Offset
        $endOffset = $Pak.Resources[$i + 1].Offset
        $originalLength = $endOffset - $startOffset

        if ($Modifications.ContainsKey($resourceId)) {
            $info = @{
                NewOffset = $currentDataOffset
                ModifiedData = $Modifications[$resourceId]
            }
            $currentDataOffset += $Modifications[$resourceId].Length
        }
        else {
            $info = @{
                NewOffset = $currentDataOffset
                SrcOffset = $startOffset
                Length = $originalLength
            }
            $currentDataOffset += $originalLength
        }
        [void]$resourceInfo.Add($info)
    }

    $sentinelOffset = $currentDataOffset

    # Write to file
    $fileStream = [System.IO.File]::Create($Path)
    try {
        # Header
        Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt32ToBytes -Value $Pak.Version)
        $fileStream.WriteByte($Pak.Encoding)

        if ($Pak.Version -eq 4) {
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt32ToBytes -Value $numResources)
        }
        else {
            $fileStream.WriteByte(0); $fileStream.WriteByte(0); $fileStream.WriteByte(0)
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$numResources))
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$Pak.Aliases.Count))
        }

        # Resource table with new offsets
        for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$Pak.Resources[$i].Id))
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt32ToBytes -Value ([uint32]$resourceInfo[$i].NewOffset))
        }

        # Sentinel
        Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$Pak.Resources[$Pak.Resources.Count - 1].Id))
        Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt32ToBytes -Value ([uint32]$sentinelOffset))

        # Aliases
        foreach ($alias in $Pak.Aliases) {
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$alias.Id))
            Write-BytesToStream -Stream $fileStream -Bytes (ConvertFrom-UInt16ToBytes -Value ([uint16]$alias.ResourceIndex))
        }

        # Resource data - direct writes
        for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
            if ($null -ne $resourceInfo[$i].ModifiedData) {
                Write-BytesToStream -Stream $fileStream -Bytes $resourceInfo[$i].ModifiedData
            }
            else {
                $fileStream.Write($Pak.RawBytes, $resourceInfo[$i].SrcOffset, $resourceInfo[$i].Length)
            }
        }
    }
    finally {
        $fileStream.Close()
        $fileStream.Dispose()
    }
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
    New-DirectoryIfNotExists -Path $OutputDir

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
            $decompressed = Expand-GzipData -CompressedBytes $resourceBytes
            if ($null -ne $decompressed) {
                $contentBytes = $decompressed
                $wasDecompressed = $true
            }
        }

        # Determine if text or binary
        $isText = -not (Test-BinaryContent -Bytes $contentBytes)
        $content = $null
        if ($isText) {
            $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)
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
    Save-JsonFile -Path $manifestPath -Object $manifest -Depth 10

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

    $manifest = Get-JsonFile -Path $manifestPath

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
            $contentBytes = Compress-GzipData -UncompressedBytes $contentBytes
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
        $config = Get-JsonFile -Path $ConfigPath
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
                $versionDir = Find-CometVersionDirectory -CometPath $comet.Directory
                if ($versionDir) {
                    $testPath = Join-Path $versionDir.FullName "resources.pak"
                    if (Test-Path $testPath) {
                        $PakPath = $testPath
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

    # Track unfound patterns for early exit (using List for PS 5.1 compatibility)
    $unfoundIndices = New-Object 'System.Collections.Generic.List[int]'
    for ($j = 0; $j -lt $verificationPatterns.Count; $j++) {
        [void]$unfoundIndices.Add($j)
    }
    $totalPatterns = $unfoundIndices.Count

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

        # Check if gzip compressed and decompress
        $isGzipped = ($resourceBytes[0] -eq 0x1f -and $resourceBytes[1] -eq 0x8b)
        $contentBytes = $resourceBytes

        if ($isGzipped) {
            $decompressed = Expand-GzipData -CompressedBytes $resourceBytes
            if ($null -eq $decompressed) { continue }
            $contentBytes = $decompressed
        }

        # Skip binary content
        if (Test-BinaryContent -Bytes $contentBytes) { continue }
        $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)

        # Check each verification pattern (look for replacement values)
        # Iterate in reverse to safely remove from list during iteration
        for ($k = $unfoundIndices.Count - 1; $k -ge 0; $k--) {
            $patternIdx = $unfoundIndices[$k]
            $pattern = $verificationPatterns[$patternIdx]
            # Use literal string matching for the replacement value
            if ($content.Contains($pattern.Replacement)) {
                $pattern.Found = $true
                [void]$pattern.ResourceIds.Add($resourceId)
                # Remove from unfound list
                [void]$unfoundIndices.RemoveAt($k)
            }
        }

        # Early exit: stop scanning if all patterns have been found
        if ($unfoundIndices.Count -eq 0 -and $totalPatterns -gt 0) {
            Write-Status "[PAK] All $totalPatterns patterns verified - stopping scan early at resource $($i+1) of $($pak.Resources.Count - 1)" -Type Detail
            break
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
# ====================================================================================
# CRX File Format Documentation
# ====================================================================================
#
# CRX (Chrome Extension) files are signed ZIP archives with a header containing
# version information, public keys, and cryptographic signatures.
#
# CRX2 Format (legacy):
# +------------------+------------------+------------------+------------------+
# |    Magic (4)     |   Version (4)    | PubKey Len (4)   |   Sig Len (4)    |
# +------------------+------------------+------------------+------------------+
# |                          Public Key (variable)                            |
# +----------------------------------------------------------------------------+
# |                          Signature (variable)                              |
# +----------------------------------------------------------------------------+
# |                          ZIP Archive (variable)                            |
# +----------------------------------------------------------------------------+
#
# CRX3 Format (current):
# +------------------+------------------+------------------+
# |    Magic (4)     |   Version (4)    | Header Len (4)   |
# +------------------+------------------+------------------+
# |                   Protobuf Header (variable)                               |
# |   Contains: signed_header_data, sha256_with_rsa/ecdsa proofs with keys     |
# +----------------------------------------------------------------------------+
# |                          ZIP Archive (variable)                            |
# +----------------------------------------------------------------------------+
#
# Magic: 0x43 0x72 0x32 0x34 ("Cr24")
# All integers are little-endian.
#
# Reference: https://chromium.googlesource.com/chromium/src/+/HEAD/components/crx_file/crx3.proto
# ====================================================================================

function Test-CrxMagic {
    <#
    .SYNOPSIS
        Validate that a byte array starts with the CRX magic header "Cr24".
    .DESCRIPTION
        Checks the first 4 bytes against the expected CRX magic bytes (0x43, 0x72, 0x32, 0x34).
        Returns $true if valid, $false otherwise.
    .OUTPUTS
        System.Boolean
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -lt 4) {
        return $false
    }

    for ($i = 0; $i -lt 4; $i++) {
        if ($Bytes[$i] -ne $script:CRX_MAGIC[$i]) {
            return $false
        }
    }

    return $true
}

function Get-CrxVersion {
    <#
    .SYNOPSIS
        Extract and validate the CRX version from file header bytes.
    .DESCRIPTION
        Reads the version field (bytes 4-7) from CRX header and validates it.
        Supports CRX version 2 and 3. Throws for invalid or unsupported versions.
    .OUTPUTS
        System.Int32
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [byte[]]$Header
    )

    if ($Header.Length -lt $script:CRX_HEADER_SIZE_BASE) {
        throw "CRX header too short: expected at least $($script:CRX_HEADER_SIZE_BASE) bytes, got $($Header.Length)"
    }

    if (-not (Test-CrxMagic -Bytes $Header)) {
        throw "Invalid CRX file: missing Cr24 magic header (expected 0x43 0x72 0x32 0x34)"
    }

    $version = ConvertTo-LittleEndianUInt32 -Bytes $Header -Offset 4

    if ($version -eq $script:CRX_VERSION_2) {
        if ($Header.Length -lt $script:CRX2_HEADER_SIZE_MIN) {
            throw "CRX2 header truncated: expected at least $($script:CRX2_HEADER_SIZE_MIN) bytes, got $($Header.Length)"
        }
        return $version
    }
    elseif ($version -eq $script:CRX_VERSION_3) {
        if ($Header.Length -lt $script:CRX3_HEADER_SIZE_MIN) {
            throw "CRX3 header truncated: expected at least $($script:CRX3_HEADER_SIZE_MIN) bytes, got $($Header.Length)"
        }
        return $version
    }
    else {
        throw "Unsupported CRX version: $version (expected $($script:CRX_VERSION_2) or $($script:CRX_VERSION_3))"
    }
}

function Get-CrxZipOffset {
    <#
    .SYNOPSIS
        Calculate the offset where the ZIP archive starts within a CRX file.
    .DESCRIPTION
        Parses CRX header to determine where the embedded ZIP archive begins.
        For CRX2: offset = 16 + pubkey_length + signature_length
        For CRX3: offset = 12 + header_length
    .OUTPUTS
        System.Int32
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [byte[]]$Bytes
    )

    $version = Get-CrxVersion -Header $Bytes

    if ($version -eq $script:CRX_VERSION_2) {
        # CRX2: magic(4) + version(4) + pubkey_len(4) + sig_len(4) + pubkey + sig + zip
        $pubkeyLen = ConvertTo-LittleEndianUInt32 -Bytes $Bytes -Offset 8
        $sigLen = ConvertTo-LittleEndianUInt32 -Bytes $Bytes -Offset 12
        $offset = $script:CRX2_HEADER_SIZE_MIN + $pubkeyLen + $sigLen

        if ($offset -gt $Bytes.Length) {
            throw "CRX2 file truncated: ZIP offset ($offset) exceeds file size ($($Bytes.Length))"
        }
        return $offset
    }
    else {
        # CRX3: magic(4) + version(4) + header_len(4) + header + zip
        $headerLen = ConvertTo-LittleEndianUInt32 -Bytes $Bytes -Offset 8
        $offset = $script:CRX3_HEADER_SIZE_MIN + $headerLen

        if ($offset -gt $Bytes.Length) {
            throw "CRX3 file truncated: ZIP offset ($offset) exceeds file size ($($Bytes.Length))"
        }
        return $offset
    }
}

function Read-ProtobufVarint {
    <#
    .SYNOPSIS
        Read a protobuf varint from byte array at given position.
    .DESCRIPTION
        Decodes a variable-length integer (varint) used in Protocol Buffers encoding.
        Each byte uses 7 bits for the value and 1 bit (MSB) to indicate continuation.
        Returns a hashtable with Value (the decoded integer) and Pos (new position).
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [byte[]]$Bytes,

        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$Pos
    )

    if ($Pos -ge $Bytes.Length) {
        throw "Protobuf varint read out of bounds: position $Pos >= length $($Bytes.Length)"
    }

    $result = 0
    $shift = 0
    do {
        if ($Pos -ge $Bytes.Length) {
            throw "Protobuf varint truncated at position $Pos"
        }
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

        Uses streaming to read only the CRX header portion (typically <10KB),
        avoiding loading the entire CRX file (10+ MB) into memory.
    .OUTPUTS
        System.String
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CrxPath
    )

    if (-not (Test-Path -LiteralPath $CrxPath)) {
        throw "CRX file not found: $CrxPath"
    }

    $fileStream = $null
    try {
        $fileStream = [System.IO.File]::OpenRead($CrxPath)

        # Read CRX header (first 16 bytes) to determine version and header size
        $header = New-Object byte[] 16
        $bytesRead = $fileStream.Read($header, 0, 16)
        if ($bytesRead -lt 12) {
            throw "CRX file too small: only $bytesRead bytes"
        }

        # Validate magic "Cr24"
        if ($header[0] -ne 0x43 -or $header[1] -ne 0x72 -or $header[2] -ne 0x32 -or $header[3] -ne 0x34) {
            throw "Invalid CRX file: missing Cr24 magic header"
        }

        $version = [BitConverter]::ToUInt32($header, 4)

        if ($version -eq 2) {
            # CRX2: public key at offset 16, length in header
            $pubkeyLen = [BitConverter]::ToUInt32($header, 8)
            if ($pubkeyLen -eq 0) {
                throw "CRX2 file has zero-length public key"
            }

            # Read just the public key (already at offset 16 after reading header)
            $pubkey = New-Object byte[] $pubkeyLen
            $fileStream.Read($pubkey, 0, $pubkeyLen) | Out-Null
            return [Convert]::ToBase64String($pubkey)
        }
        elseif ($version -eq 3) {
            # CRX3: Read protobuf header only
            $headerLen = [BitConverter]::ToUInt32($header, 8)

            # Seek to start of protobuf header (offset 12)
            $fileStream.Seek(12, [System.IO.SeekOrigin]::Begin) | Out-Null
            $bytes = New-Object byte[] $headerLen
            $fileStream.Read($bytes, 0, $headerLen) | Out-Null

            # Parse protobuf header to collect keys and find the CRX ID
            # Note: $bytes now starts at offset 0 (not 12)
            $headerEnd = $headerLen
            $keys = [System.Collections.ArrayList]@()
            $crxId = $null

            $pos = 0
            while ($pos -lt $headerEnd) {
                $result = Read-ProtobufVarint -Bytes $bytes -Pos $pos
                $tag = $result.Value
                $pos = $result.Pos

                $fieldNum = $tag -shr 3
                $wireType = $tag -band 0x07

                if ($wireType -eq 2) {
                    # Length-delimited field
                    $result = Read-ProtobufVarint -Bytes $bytes -Pos $pos
                    $len = $result.Value
                    $pos = $result.Pos
                    $fieldEnd = $pos + $len

                    if ($fieldEnd -gt $headerEnd) {
                        throw "CRX3 protobuf field extends beyond header at position $pos"
                    }

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
                    # Varint field
                    $result = Read-ProtobufVarint -Bytes $bytes -Pos $pos
                    $pos = $result.Pos
                }
                elseif ($wireType -eq 1) { $pos += 8 }  # 64-bit fixed
                elseif ($wireType -eq 5) { $pos += 4 }  # 32-bit fixed
                else {
                    throw "CRX3 protobuf unknown wire type $wireType at position $pos"
                }
            }

            # Find the key that matches the CRX ID
            if ($crxId -and $keys.Count -gt 0) {
                $crxIdHex = [BitConverter]::ToString($crxId).Replace("-", "").ToLower()

                foreach ($key in $keys) {
                    $sha = [System.Security.Cryptography.SHA256]::Create()
                    try {
                        $hash = $sha.ComputeHash($key)
                        $hashHex = [BitConverter]::ToString($hash[0..15]).Replace("-", "").ToLower()

                        if ($hashHex -eq $crxIdHex) {
                            return [Convert]::ToBase64String($key)
                        }
                    }
                    finally {
                        $sha.Dispose()
                    }
                }
            }

            # Fallback: return first key if no CRX ID match (shouldn't happen for valid CRX)
            if ($keys.Count -gt 0) {
                Write-VerboseTimestamped "Warning: CRX ID not found in header, using first available key"
                return [Convert]::ToBase64String($keys[0])
            }

            throw "Could not find public key in CRX3 header (found $($keys.Count) keys, crxId present: $($null -ne $crxId))"
        }
        else {
            throw "Unsupported CRX version: $version"
        }
    }
    finally {
        if ($fileStream) { $fileStream.Dispose() }
    }
}

function Export-CrxToDirectory {
    <#
    .SYNOPSIS
        Extract a CRX file to a directory.
    .DESCRIPTION
        Handles both CRX2 and CRX3 formats by detecting the header and extracting the ZIP payload.
        Uses streaming to avoid loading the entire CRX file into memory.
        Optionally injects the public key into manifest.json for consistent extension ID.
    .OUTPUTS
        System.Boolean
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CrxPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDir,

        [switch]$InjectKey
    )

    if (-not (Test-Path -LiteralPath $CrxPath)) {
        throw "CRX file not found: $CrxPath"
    }

    $tempZip = Join-Path $env:TEMP "meteor_crx_$(Get-Random).zip"
    $inputStream = $null
    $outputStream = $null

    try {
        # Open input file and read header to find ZIP offset
        $inputStream = [System.IO.File]::OpenRead($CrxPath)

        $header = New-Object byte[] 16
        $bytesRead = $inputStream.Read($header, 0, 16)
        if ($bytesRead -lt 12) {
            throw "CRX file too small: only $bytesRead bytes"
        }

        # Validate magic "Cr24"
        if ($header[0] -ne 0x43 -or $header[1] -ne 0x72 -or $header[2] -ne 0x32 -or $header[3] -ne 0x34) {
            throw "Invalid CRX file: missing Cr24 magic header"
        }

        # Calculate ZIP offset
        $version = [BitConverter]::ToUInt32($header, 4)
        if ($version -eq 2) {
            $pubkeyLen = [BitConverter]::ToUInt32($header, 8)
            $sigLen = [BitConverter]::ToUInt32($header, 12)
            $zipOffset = 16 + $pubkeyLen + $sigLen
        }
        elseif ($version -eq 3) {
            $headerLen = [BitConverter]::ToUInt32($header, 8)
            $zipOffset = 12 + $headerLen
        }
        else {
            throw "Unsupported CRX version: $version"
        }

        $zipLength = $inputStream.Length - $zipOffset
        if ($zipLength -le 0) {
            throw "CRX file has no ZIP content (ZIP length: $zipLength)"
        }

        # Seek to ZIP start and validate ZIP magic
        $inputStream.Seek($zipOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $zipMagic = New-Object byte[] 4
        $inputStream.Read($zipMagic, 0, 4) | Out-Null
        if ($zipMagic[0] -ne 0x50 -or $zipMagic[1] -ne 0x4B) {
            throw "CRX file contains invalid ZIP archive (missing PK signature at offset $zipOffset)"
        }

        # Stream ZIP portion to temp file (64KB buffer)
        $inputStream.Seek($zipOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $outputStream = [System.IO.File]::Create($tempZip)
        $buffer = New-Object byte[] 65536
        $remaining = $zipLength
        while ($remaining -gt 0) {
            $toRead = [Math]::Min($buffer.Length, $remaining)
            $read = $inputStream.Read($buffer, 0, $toRead)
            if ($read -eq 0) { break }
            $outputStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
        $outputStream.Close()
        $outputStream = $null
        $inputStream.Close()
        $inputStream = $null

        if (Test-Path $OutputDir) {
            Remove-Item -Path $OutputDir -Recurse -Force
        }

        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

        # Use 7-Zip if available (2-5x faster than Expand-Archive)
        $sevenZip = Get-7ZipPath
        if ($sevenZip) {
            # -bso0 -bsp0 = suppress stdout/progress output, -y = yes to all prompts
            $null = & $sevenZip x $tempZip "-o$OutputDir" -y -bso0 -bsp0 2>$null
            if ($LASTEXITCODE -ne 0) {
                # Fallback to Expand-Archive if 7-Zip fails
                Write-VerboseTimestamped "[CRX] 7-Zip extraction failed (exit code $LASTEXITCODE), falling back to Expand-Archive"
                Expand-Archive -Path $tempZip -DestinationPath $OutputDir -Force
            }
        }
        else {
            # Fallback to Expand-Archive (slower but always available)
            Expand-Archive -Path $tempZip -DestinationPath $OutputDir -Force
        }

        # Inject public key into manifest if requested
        if ($InjectKey) {
            $publicKey = Get-CrxPublicKey -CrxPath $CrxPath
            $manifestPath = Join-Path $OutputDir "manifest.json"

            if ((Test-Path $manifestPath) -and $publicKey) {
                $manifest = Get-JsonFile -Path $manifestPath

                # Add key as first property for readability
                $manifest | Add-Member -NotePropertyName "key" -NotePropertyValue $publicKey -Force

                Save-JsonFile -Path $manifestPath -Object $manifest -Depth 20
            }
        }
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if (Test-Path $tempZip) {
            Remove-Item -Path $tempZip -Force
        }
    }

    return $true
}

function Get-CrxManifest {
    <#
    .SYNOPSIS
        Read manifest.json from a CRX file without full extraction.
    .DESCRIPTION
        Uses streaming to read only the CRX header and manifest.json entry,
        avoiding loading the entire CRX file into memory. This is critical
        for large CRX files (10+ MB) where ReadAllBytes would be slow.
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CrxPath
    )

    $fileStream = $null

    try {
        if (-not (Test-Path -LiteralPath $CrxPath)) {
            Write-VerboseTimestamped "CRX file not found: $CrxPath"
            return $null
        }

        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

        # Open file stream (don't load entire file into memory)
        $fileStream = [System.IO.File]::OpenRead($CrxPath)

        # Read only the CRX header (first 16 bytes max needed)
        $header = New-Object byte[] 16
        $bytesRead = $fileStream.Read($header, 0, 16)
        if ($bytesRead -lt 12) {
            Write-VerboseTimestamped "CRX file too small: $bytesRead bytes read"
            return $null
        }

        # Check magic header "Cr24"
        if ($header[0] -ne 0x43 -or $header[1] -ne 0x72 -or $header[2] -ne 0x32 -or $header[3] -ne 0x34) {
            Write-VerboseTimestamped "Invalid CRX file: missing Cr24 magic header"
            return $null
        }

        # Calculate ZIP offset from header
        $version = [BitConverter]::ToUInt32($header, 4)
        if ($version -eq 2) {
            # CRX2: magic(4) + version(4) + pubkey_len(4) + sig_len(4) + pubkey + sig + zip
            $pubkeyLen = [BitConverter]::ToUInt32($header, 8)
            $sigLen = [BitConverter]::ToUInt32($header, 12)
            $zipOffset = 16 + $pubkeyLen + $sigLen
        }
        elseif ($version -eq 3) {
            # CRX3: magic(4) + version(4) + header_len(4) + header + zip
            $headerLen = [BitConverter]::ToUInt32($header, 8)
            $zipOffset = 12 + $headerLen
        }
        else {
            Write-VerboseTimestamped "Unsupported CRX version: $version"
            return $null
        }

        # manifest.json is typically at the start of the ZIP and small (<10KB)
        # Read only first 1MB of ZIP portion to find it, avoiding full file load
        $remainingLength = $fileStream.Length - $zipOffset
        $readSize = [Math]::Min(1048576, $remainingLength)  # 1MB max

        # Seek to ZIP start and read limited portion
        $fileStream.Seek($zipOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $zipBytes = New-Object byte[] $readSize
        $actualRead = $fileStream.Read($zipBytes, 0, $readSize)

        # Parse ZIP local file headers to find manifest.json without full archive
        # ZIP local file header: signature(4) + version(2) + flags(2) + compression(2) +
        #                        modtime(2) + moddate(2) + crc(4) + compressed_size(4) +
        #                        uncompressed_size(4) + name_len(2) + extra_len(2) + name + extra + data
        $pos = 0
        while ($pos + 30 -lt $actualRead) {
            # Check local file header signature (0x04034b50)
            if ($zipBytes[$pos] -ne 0x50 -or $zipBytes[$pos+1] -ne 0x4b -or
                $zipBytes[$pos+2] -ne 0x03 -or $zipBytes[$pos+3] -ne 0x04) {
                break  # Not a local file header
            }

            $flags = [BitConverter]::ToUInt16($zipBytes, $pos + 6)
            $compression = [BitConverter]::ToUInt16($zipBytes, $pos + 8)
            $compressedSize = [BitConverter]::ToUInt32($zipBytes, $pos + 18)
            $nameLen = [BitConverter]::ToUInt16($zipBytes, $pos + 26)
            $extraLen = [BitConverter]::ToUInt16($zipBytes, $pos + 28)
            $nameStart = $pos + 30
            $dataStart = $nameStart + $nameLen + $extraLen

            # Check for data descriptor flag (bit 3) - if set, sizes in header are 0
            $hasDataDescriptor = ($flags -band 0x08) -ne 0

            if ($nameStart + $nameLen -gt $actualRead) { break }

            $fileName = [System.Text.Encoding]::UTF8.GetString($zipBytes, $nameStart, $nameLen)

            if ($fileName -eq "manifest.json") {
                # Found it! Extract and decompress
                # If data descriptor flag is set, we need to find the size differently
                if ($hasDataDescriptor -and $compressedSize -eq 0) {
                    # Scan for the next local file header or central directory to find data end
                    # Data descriptor is: optional sig (0x08074b50) + crc(4) + compressed(4) + uncompressed(4)
                    $scanPos = $dataStart
                    while ($scanPos + 4 -lt $actualRead) {
                        # Look for next local file header (PK\x03\x04) or central dir (PK\x01\x02)
                        if ($zipBytes[$scanPos] -eq 0x50 -and $zipBytes[$scanPos+1] -eq 0x4b) {
                            if (($zipBytes[$scanPos+2] -eq 0x03 -and $zipBytes[$scanPos+3] -eq 0x04) -or
                                ($zipBytes[$scanPos+2] -eq 0x01 -and $zipBytes[$scanPos+3] -eq 0x02)) {
                                # Found next entry - data descriptor is 12-16 bytes before this
                                # (optional 4-byte sig + 4 crc + 4 compressed + 4 uncompressed)
                                $compressedSize = $scanPos - $dataStart - 16
                                if ($compressedSize -lt 0) { $compressedSize = $scanPos - $dataStart - 12 }
                                break
                            }
                        }
                        $scanPos++
                    }
                    if ($compressedSize -le 0) {
                        Write-VerboseTimestamped "manifest.json: could not determine size from data descriptor"
                        break
                    }
                }

                $dataEnd = $dataStart + $compressedSize
                if ($dataEnd -gt $actualRead) {
                    Write-VerboseTimestamped "manifest.json data extends beyond read buffer"
                    break
                }

                $compressedData = New-Object byte[] $compressedSize
                [Array]::Copy($zipBytes, $dataStart, $compressedData, 0, $compressedSize)

                if ($compression -eq 0) {
                    # Stored (no compression)
                    $content = [System.Text.Encoding]::UTF8.GetString($compressedData)
                }
                elseif ($compression -eq 8) {
                    # Deflate
                    $compStream = New-Object System.IO.MemoryStream($compressedData, $false)
                    $deflateStream = New-Object System.IO.Compression.DeflateStream($compStream, [System.IO.Compression.CompressionMode]::Decompress)
                    $reader = New-Object System.IO.StreamReader($deflateStream)
                    try {
                        $content = $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                        $deflateStream.Dispose()
                        $compStream.Dispose()
                    }
                }
                else {
                    Write-VerboseTimestamped "Unsupported compression method: $compression"
                    break
                }

                return $content | ConvertFrom-Json
            }

            # Move to next entry - if data descriptor is used, scan for next header
            if ($hasDataDescriptor -and $compressedSize -eq 0) {
                # Scan forward for the next local file header
                $scanPos = $dataStart
                while ($scanPos + 4 -lt $actualRead) {
                    if ($zipBytes[$scanPos] -eq 0x50 -and $zipBytes[$scanPos+1] -eq 0x4b -and
                        $zipBytes[$scanPos+2] -eq 0x03 -and $zipBytes[$scanPos+3] -eq 0x04) {
                        $pos = $scanPos
                        break
                    }
                    $scanPos++
                }
                if ($scanPos + 4 -ge $actualRead) { break }  # No more headers found
            }
            else {
                $pos = $dataStart + $compressedSize
            }
        }

        Write-VerboseTimestamped "manifest.json not found in first 1MB of CRX archive"
    }
    catch {
        Write-VerboseTimestamped "Failed to read CRX manifest: $_"
    }
    finally {
        if ($fileStream) { $fileStream.Dispose() }
    }

    return $null
}

#endregion

#region Extension Update Checking

function Get-ExtensionUpdateInfo {
    <#
    .SYNOPSIS
        Query an extension's update URL to check for newer versions.
    .DESCRIPTION
        Uses the standard Chrome/Omaha update protocol to query for extension updates.
    #>
    param(
        [string]$UpdateUrl,
        [string]$ExtensionId,
        [string]$CurrentVersion,
        [string]$BrowserVersion = "120.0.0.0"
    )

    if (-not $UpdateUrl) {
        return $null
    }

    # Build update check URL with required Chrome-style parameters
    # The x= parameter contains: id=<ExtensionId>&v=<Version>&uc (URL-encoded)
    $xParam = "id%3D$ExtensionId%26v%3D$CurrentVersion%26uc"

    # Determine separator (& if URL already has query params, ? otherwise)
    $separator = if ($UpdateUrl.Contains("?")) { "&" } else { "?" }

    # Generate a random 64-character lowercase hex machine ID (matches Comet's format)
    $randomBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randomBytes)
    $machineId = [System.BitConverter]::ToString($randomBytes).Replace("-", "").ToLower()

    # Build full URL with parameters matching Comet's actual request format
    $checkUrl = "$UpdateUrl$separator" + `
        "response=updatecheck&" + `
        "os=win&arch=x64&os_arch=x86_64&" + `
        "prod=chromiumcrx&prodchannel=&prodversion=$BrowserVersion&" + `
        "lang=en-US&acceptformat=crx3,puff&machine=$machineId&x=$xParam"

    try {
        $content = Invoke-MeteorWebRequest -Uri $checkUrl -Mode Content -TimeoutSec 30

        # Parse XML response
        [xml]$xml = $content

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

        $null = Invoke-MeteorWebRequest -Uri $Codebase -Mode Download -OutFile $tempCrx -TimeoutSec 120

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

function Get-BundledExtensionFromServer {
    <#
    .SYNOPSIS
        Download the latest version of a bundled extension from Perplexity's update server.
    .DESCRIPTION
        Queries the update server for the latest version, downloads the CRX, and extracts it.
        Uses CurrentVersion to check for updates - if newer version available, downloads it.
    .OUTPUTS
        Hashtable with Version and Path on success, $null on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$ExtensionId,
        [Parameter(Mandatory)][string]$ExtensionName,
        [Parameter(Mandatory)][string]$UpdateUrl,
        [Parameter(Mandatory)][string]$OutputDir,
        [string]$CurrentVersion = "0.0.0",
        [string]$BrowserVersion = "120.0.0.0",
        [switch]$InjectKey
    )

    Write-Status "Fetching $ExtensionName from update server..." -Type Detail

    # Query update server for latest version
    $updateInfo = Get-ExtensionUpdateInfo -UpdateUrl $UpdateUrl -ExtensionId $ExtensionId -CurrentVersion $CurrentVersion -BrowserVersion $BrowserVersion

    if (-not $updateInfo -or -not $updateInfo.Codebase) {
        Write-Status "  No update info available for $ExtensionName" -Type Warning
        return $null
    }

    Write-Status "  Latest version: $($updateInfo.Version)" -Type Detail

    # Download CRX
    $tempCrx = Join-Path $env:TEMP "meteor_bundled_$(Get-Random).crx"
    try {
        $null = Invoke-MeteorWebRequest -Uri $updateInfo.Codebase -Mode Download -OutFile $tempCrx -TimeoutSec 120
        Write-Status "  Downloaded: $(Split-Path -Leaf $updateInfo.Codebase)" -Type Detail

        # Extract to output directory
        if (Test-Path $OutputDir) {
            Remove-Item -Path $OutputDir -Recurse -Force
        }

        $exportResult = Export-CrxToDirectory -CrxPath $tempCrx -OutputDir $OutputDir -InjectKey:$InjectKey
        if (-not $exportResult) {
            Write-Status "  Failed to extract $ExtensionName" -Type Error
            return $null
        }

        Write-Status "  Extracted to: $OutputDir" -Type Detail

        return @{
            Version = $updateInfo.Version
            Path    = $OutputDir
        }
    }
    catch {
        Write-Status "  Failed to download $ExtensionName : $_" -Type Error
        return $null
    }
    finally {
        if (Test-Path $tempCrx) {
            Remove-Item -Path $tempCrx -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ChromeExtensionVersion {
    <#
    .SYNOPSIS
        Get the latest version of a Chrome Web Store extension using the update API.
    .DESCRIPTION
        Uses the lightweight Chrome Web Store update check API instead of scraping
        the full HTML detail page. Returns just the version string.
    #>
    param([Parameter(Mandatory)][string]$ExtensionId)

    try {
        # Use Chrome Web Store update API - much faster than scraping HTML
        $url = "https://clients2.google.com/service/update2/crx?response=updatecheck&os=win&arch=x86-64&os_arch=x86-64&prod=chromecrx&prodchannel=unknown&prodversion=120.0.0.0&acceptformat=crx3&x=id%3D$ExtensionId%26v%3D0.0.0%26uc"

        $content = Invoke-MeteorWebRequest -Uri $url -Mode Content -TimeoutSec 30

        # Parse XML response for version attribute
        [xml]$xml = $content
        $updatecheck = $xml.gupdate.app.updatecheck

        if ($updatecheck -and $updatecheck.status -eq "ok" -and $updatecheck.version) {
            return $updatecheck.version
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

    # Compare versions if current version provided - use existing Compare-Versions helper
    if ($CurrentVersion) {
        $comparison = Compare-Versions -Version1 $latest -Version2 $CurrentVersion
        if ($comparison -le 0) {
            Write-Status "Extension $ExtensionId is up to date (current: $CurrentVersion, latest: $latest)" -Type Success
            return $null
        }
    }

    # Build download URL
    $downloadUrl = "https://clients2.google.com/service/update2/crx?response=redirect&os=win&arch=x86-64&os_arch=x86-64&prod=chromecrx&prodchannel=unknown&prodversion=120.0.0.0&acceptformat=crx3&x=id%3D$ExtensionId%26uc"
    $outFile = Join-Path $OutPath "$ExtensionId`_$latest.crx"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequestTimestamped -Uri $downloadUrl -OutFile $outFile -UseBasicParsing -TimeoutSec 120 -Headers @{
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
            $versionDir = Find-CometVersionDirectory -CometPath $portableBrowserDir
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

function Install-Comet {
    <#
    .SYNOPSIS
        Download and install Comet browser.
    #>
    param(
        [string]$DownloadUrl
    )

    Write-Status "Comet browser not found. Downloading..." -Type Info

    if ($WhatIfPreference) {
        Write-Status "Would download from: $DownloadUrl" -Type Detail
        return $null
    }

    $tempInstaller = Join-Path $env:TEMP "CometSetup_$(Get-Random).exe"

    try {
        Write-Status "Downloading from: $DownloadUrl" -Type Detail

        $null = Invoke-MeteorDownload -Uri $DownloadUrl -OutFile $tempInstaller

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
        [string]$PreDownloadedInstaller
    )

    Write-Status "Installing Comet in portable mode..." -Type Info

    # Check for 7-Zip
    $sevenZip = Get-7ZipPath
    if (-not $sevenZip) {
        Write-Status "7-Zip is required for portable installation. Please install 7-Zip from https://7-zip.org" -Type Error
        return $null
    }

    if ($WhatIfPreference) {
        Write-Status "Would download from: $DownloadUrl" -Type Detail
        Write-Status "Would extract to: $TargetDir" -Type Detail
        return $null
    }

    $tempDir = Join-Path $env:TEMP "meteor_comet_$(Get-Random)"
    $tempInstaller = Join-Path $tempDir "comet_installer.exe"

    try {
        # Create temp directory
        New-DirectoryIfNotExists -Path $tempDir

        # Use pre-downloaded installer if available, otherwise download
        if ($PreDownloadedInstaller -and (Test-Path $PreDownloadedInstaller)) {
            Write-Status "Using pre-downloaded installer" -Type Detail
            Copy-Item -Path $PreDownloadedInstaller -Destination $tempInstaller -Force
            Remove-Item -Path $PreDownloadedInstaller -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Status "Downloading from: $DownloadUrl" -Type Detail
            $null = Invoke-MeteorDownload -Uri $DownloadUrl -OutFile $tempInstaller
        }

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
            Write-VerboseTimestamped "Detected mini_installer format (chrome.7z found directly)"
        }
        else {
            # Old format: NSIS wrapper with updater.7z -> mini_installer -> chrome.7z
            Write-VerboseTimestamped "Detected NSIS wrapper format, extracting nested archives..."
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
            $versionDir = Find-CometVersionDirectory -CometPath $cometDir
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
            Directory  = $cometDir
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

        Write-VerboseTimestamped "Update check: Querying $DownloadUrl"
        Write-VerboseTimestamped "Update check: Current version is $CurrentVersion"

        # Use GET request with MaximumRedirection 0 to capture the redirect URL
        # HEAD requests are blocked by Cloudflare, but GET with no redirect follow works
        # The API returns a 307 redirect to the actual download URL which contains the version
        $redirectUrl = $null
        try {
            $response = Invoke-WebRequestTimestamped -Uri $DownloadUrl -Method Get -UseBasicParsing -MaximumRedirection 0 -Headers @{
                "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            }
            Write-VerboseTimestamped "Update check: Response status $($response.StatusCode)"
            # PowerShell 5.1 may return 307 directly without throwing - check for Location header
            if ($response.StatusCode -eq 307) {
                $redirectUrl = $response.Headers["Location"]
                Write-VerboseTimestamped "Update check: Got 307 redirect (no exception)"
            }
        }
        catch [System.Net.WebException] {
            # Some PowerShell versions throw on redirect with MaximumRedirection 0
            $webResponse = $_.Exception.Response
            if ($webResponse -and $webResponse.StatusCode -eq [System.Net.HttpStatusCode]::TemporaryRedirect) {
                $redirectUrl = $webResponse.Headers["Location"]
                Write-VerboseTimestamped "Update check: Got 307 redirect (from exception)"
            }
            else {
                throw
            }
        }

        # Try to extract version from redirect Location header
        Write-VerboseTimestamped "Update check: Redirect URL: $(if ($redirectUrl) { $redirectUrl } else { '(not present)' })"
        if ($redirectUrl) {
            # Version pattern in URL path like /143.2.7499.37654/comet_latest_intel.exe
            if ($redirectUrl -match '/(\d+\.\d+\.\d+(?:\.\d+)?)/' -or $redirectUrl -match '[\-_](\d+\.\d+\.\d+(?:\.\d+)?)') {
                $latestVersion = $Matches[1]
                $versionSource = "redirect Location header"
                Write-VerboseTimestamped "Update check: Extracted version $latestVersion from redirect URL"
            }
            else {
                Write-VerboseTimestamped "Update check: No version pattern found in redirect URL"
            }
        }

        if ($latestVersion) {
            Write-VerboseTimestamped "Update check: Latest version $latestVersion found via $versionSource"
            $comparison = Compare-Versions -Version1 $latestVersion -Version2 $CurrentVersion
            Write-VerboseTimestamped "Update check: Version comparison result: $comparison (positive = update available)"
            if ($comparison -gt 0) {
                Write-VerboseTimestamped "Update check: Update available ($CurrentVersion -> $latestVersion)"
                return @{
                    Version     = $latestVersion
                    DownloadUrl = $DownloadUrl
                }
            }
            else {
                Write-VerboseTimestamped "Update check: Already up to date"
            }
        }
        else {
            Write-VerboseTimestamped "Update check: Could not determine latest version from response"
        }
    }
    catch {
        Write-Status "Failed to check for Comet updates: $_" -Type Warning
    }

    return $null
}

#endregion

#region Chrome Web Store Extensions

function Install-ChromeWebStoreExtension {
    <#
    .SYNOPSIS
        Download and install an extension from Chrome Web Store.
    .DESCRIPTION
        Generic helper function that handles the common download/extract workflow:
        - Checks current version if already installed
        - Downloads CRX from Chrome Web Store (skips if up to date)
        - Extracts to output directory with key injection
        - Handles dry run mode and force download

        Returns @{Updated=$true/false; Path=$OutputDir} on success, $null on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ExtensionId,

        [Parameter(Mandatory)]
        [string]$ExtensionName,

        [Parameter(Mandatory)]
        [string]$OutputDir,

        [switch]$ForceDownload
    )

    $manifestPath = Join-Path $OutputDir "manifest.json"
    $currentVersion = $null

    # Check if already installed
    if ((Test-Path $OutputDir) -and (Test-Path $manifestPath)) {
        $manifest = Get-JsonFile -Path $manifestPath
        $currentVersion = $manifest.version
        if ($ForceDownload) {
            Write-Status "$ExtensionName $currentVersion installed, forcing re-download..." -Type Info
        }
        else {
            Write-Status "$ExtensionName $currentVersion installed, checking for updates..." -Type Info
        }
    }
    else {
        Write-Status "$ExtensionName not found, downloading..." -Type Info
    }

    # Handle dry run mode
    if ($WhatIfPreference) {
        if ($currentVersion) {
            Write-Status "Would check for $ExtensionName updates" -Type Detail
        }
        else {
            Write-Status "Would download $ExtensionName from Chrome Web Store" -Type Detail
        }
        return @{ Updated = $false; Path = $null; CurrentVersion = $currentVersion }
    }

    # Download CRX (will skip if up to date, unless ForceDownload)
    $tempDir = Join-Path $env:TEMP "cws_ext_$(Get-Random)"
    New-DirectoryIfNotExists -Path $tempDir

    try {
        $versionToCheck = if ($ForceDownload) { $null } else { $currentVersion }
        $crxFile = Get-ChromeExtensionCrx -ExtensionId $ExtensionId -CurrentVersion $versionToCheck -OutPath $tempDir

        if (-not $crxFile) {
            # Either up to date or download failed
            if ($currentVersion) {
                Write-Status "$ExtensionName is up to date ($currentVersion)" -Type Success
                return @{ Updated = $false; Path = $OutputDir; CurrentVersion = $currentVersion }
            }
            return $null
        }

        # Extract CRX
        Write-Status "Extracting $ExtensionName..." -Type Detail

        # Remove existing directory
        if (Test-Path $OutputDir) {
            Remove-Item $OutputDir -Recurse -Force
        }

        # Extract CRX to output directory (with key injection for consistent extension ID)
        $null = Export-CrxToDirectory -CrxPath $crxFile -OutputDir $OutputDir -InjectKey

        # Get new version from manifest
        $newManifest = Get-JsonFile -Path $manifestPath
        Write-Status "$ExtensionName installed successfully (v$($newManifest.version))" -Type Success

        return @{ Updated = $true; Path = $OutputDir; CurrentVersion = $newManifest.version }
    }
    finally {
        # Cleanup temp directory
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region uBlock Origin

function Initialize-UBlockAutoImport {
    <#
    .SYNOPSIS
        Configure uBlock Origin auto-import system.
    .DESCRIPTION
        Creates auto-import.js and patches start.js to apply Meteor defaults on first run.
        Extracted as helper for use by both Get-UBlockOrigin and parallel download path.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$UBlockDir,

        [Parameter(Mandatory)]
        [object]$UBlockConfig
    )

    $jsDir = Join-Path $UBlockDir "js"
    if (-not (Test-Path $jsDir)) {
        Write-Status "uBlock js/ directory not found, skipping auto-import configuration" -Type Warning
        return
    }

    if (-not $UBlockConfig.defaults) {
        return
    }

    # Get custom filter lists for the auto-import check
    $customLists = $UBlockConfig.defaults.selectedFilterLists | Where-Object { $_ -match '^https?://' }
    $customListsJson = if ($customLists) { $customLists | ConvertTo-Json -Compress } else { "[]" }

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
        [switch]$ForceDownload,
        [switch]$SkipDownload
    )

    try {
        # Handle dry run mode - just show what would happen
        if ($WhatIfPreference) {
            $manifestPath = Join-Path $OutputDir "manifest.json"
            if ((Test-Path $OutputDir) -and (Test-Path $manifestPath)) {
                Write-Status "Would check for uBlock Origin updates" -Type Detail
            }
            else {
                Write-Status "Would download uBlock Origin from Chrome Web Store" -Type Detail
            }
            Write-Status "Would apply uBlock auto-import configuration" -Type Detail
            return $null
        }

        # Skip download if already extracted (from parallel pre-download)
        if (-not $SkipDownload) {
            # Use common helper for download/extract
            $result = Install-ChromeWebStoreExtension `
                -ExtensionId $UBlockConfig.extension_id `
                -ExtensionName "uBlock Origin" `
                -OutputDir $OutputDir `
                -ForceDownload:$ForceDownload

            if ($null -eq $result) {
                throw "Failed to download uBlock Origin"
            }
        }

        # Apply defaults if configured - using auto-import approach
        if ($UBlockConfig.defaults -and (Test-Path $OutputDir)) {
            # Save settings file that auto-import.js will load
            $settingsPath = Join-Path $OutputDir "ublock-settings.json"
            Save-JsonFile -Path $settingsPath -Object $UBlockConfig.defaults -Depth 20

            # Use helper function to create auto-import.js and patch start.js
            Initialize-UBlockAutoImport -UBlockDir $OutputDir -UBlockConfig $UBlockConfig
        }

        return $OutputDir
    }
    catch {
        Write-Status "Failed to get uBlock Origin: $_" -Type Error
        # Return existing path if it exists
        if (Test-Path $OutputDir) {
            Write-Status "Continuing with existing installation" -Type Warning
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
        [switch]$ForceDownload
    )

    try {
        # Use common helper for download/extract
        $result = Install-ChromeWebStoreExtension `
            -ExtensionId $AdGuardConfig.extension_id `
            -ExtensionName "AdGuard Extra" `
            -OutputDir $OutputDir `
            -ForceDownload:$ForceDownload

        if ($null -eq $result) {
            throw "Failed to download AdGuard Extra"
        }

        return $result.Path
    }
    catch {
        Write-Status "Failed to get AdGuard Extra: $_" -Type Error
        # Return existing path if it exists
        if (Test-Path $OutputDir) {
            Write-Status "Continuing with existing installation" -Type Warning
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
        Fetch latest extensions from update server and apply patches.
    .DESCRIPTION
        If fetch_from_server is enabled, downloads latest CRX files from Perplexity's
        update server. Falls back to local CRX files if server is unavailable.
        Uses parallel update checks and downloads for better performance.
        When FreshInstall is true, reads CRX versions from local files for update checks.
    #>
    param(
        [string]$CometDir,
        [string]$OutputDir,
        [string]$PatchesDir,
        [object]$PatchConfig,
        [object]$ExtensionConfig,
        [string]$BrowserVersion = "120.0.0.0",
        [switch]$FreshInstall
    )

    # Determine if we should fetch from server
    $fetchFromServer = $ExtensionConfig.fetch_from_server -eq $true
    $updateUrl = $ExtensionConfig.update_url
    $bundledExtensions = $ExtensionConfig.bundled

    Write-Status "Output: $OutputDir" -Type Detail

    New-DirectoryIfNotExists -Path $OutputDir

    # Build list of extensions to process
    $extensionsToProcess = @{}

    # Find default_apps directory for reading local CRX versions
    $defaultAppsDir = Get-DefaultAppsDirectory -CometDir $CometDir
    $localCrxVersions = @{}

    # On fresh install, read CRX versions from the installer's bundled files
    if ($FreshInstall -and $defaultAppsDir) {
        Write-VerboseTimestamped "Fresh install - reading CRX versions from: $defaultAppsDir"
        Get-ChildItem -Path $defaultAppsDir -Filter "*.crx*" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.crx' -or $_.Name.EndsWith('.crx.meteor-backup') } | ForEach-Object {
            $baseName = $_.Name -replace '\.crx(\.meteor-backup)?$', ''
            $crxManifest = Get-CrxManifest -CrxPath $_.FullName
            if ($crxManifest -and $crxManifest.version) {
                $localCrxVersions[$baseName] = $crxManifest.version
                Write-VerboseTimestamped "  $baseName local CRX version: $($crxManifest.version)"
            }
        }
    }

    if ($fetchFromServer -and $updateUrl -and $bundledExtensions) {
        Write-Status "Fetching extensions from update server..." -Type Info

        # ═══════════════════════════════════════════════════════════════
        # Phase 1: Collect extension info (sequential - reads manifests)
        # ═══════════════════════════════════════════════════════════════
        $extensionInfoList = @()
        foreach ($extName in $bundledExtensions.PSObject.Properties.Name) {
            $extInfo = $bundledExtensions.$extName
            $extOutputDir = Join-Path $OutputDir $extName

            # Determine current version (priority: existing patched > local CRX > fallback)
            $currentVersion = "0.0.0"
            $existingManifest = Join-Path $extOutputDir "manifest.json"
            if (Test-Path $existingManifest) {
                try {
                    $manifest = Get-JsonFile -Path $existingManifest
                    if ($manifest.version) {
                        $currentVersion = $manifest.version
                        Write-VerboseTimestamped "  $extName existing version: $currentVersion"
                    }
                } catch {
                    $null = $_
                }
            }
            elseif ($FreshInstall -and $localCrxVersions.ContainsKey($extName)) {
                # Fresh install: use version from local CRX file
                $currentVersion = $localCrxVersions[$extName]
                Write-VerboseTimestamped "  $extName local CRX version: $currentVersion"
            }
            elseif ($extInfo.fallback_version) {
                $currentVersion = $extInfo.fallback_version
                Write-VerboseTimestamped "  $extName using fallback version: $currentVersion"
            }

            $extensionInfoList += @{
                Name           = $extName
                Id             = $extInfo.id
                ExtensionName  = $extInfo.name
                OutputDir      = $extOutputDir
                CurrentVersion = $currentVersion
            }
        }

        if ($WhatIfPreference) {
            foreach ($ext in $extensionInfoList) {
                Write-Status "Would fetch $($ext.Name) from: $updateUrl (current: $($ext.CurrentVersion))" -Type Detail
                $extensionsToProcess[$ext.Name] = @{ OutputDir = $ext.OutputDir; FromServer = $true; NeedsFallback = $false }
            }
        }
        elseif ($extensionInfoList.Count -eq 1) {
            # Single extension - no parallelization overhead
            $ext = $extensionInfoList[0]
            Write-Status "Processing: $($ext.Name)" -Type Info
            $result = Get-BundledExtensionFromServer `
                -ExtensionId $ext.Id `
                -ExtensionName $ext.ExtensionName `
                -UpdateUrl $updateUrl `
                -OutputDir $ext.OutputDir `
                -CurrentVersion $ext.CurrentVersion `
                -BrowserVersion $BrowserVersion `
                -InjectKey

            if ($result) {
                $extensionsToProcess[$ext.Name] = @{ OutputDir = $ext.OutputDir; FromServer = $true; NeedsFallback = $false; Version = $result.Version }
            }
            else {
                Write-Status "  Server fetch failed, will try local fallback" -Type Warning
                $extensionsToProcess[$ext.Name] = @{ OutputDir = $ext.OutputDir; FromServer = $false; NeedsFallback = $true }
            }
        }
        else {
            # ═══════════════════════════════════════════════════════════════
            # Phase 2: Parallel update checks
            # ═══════════════════════════════════════════════════════════════
            Write-Status "Checking for updates (parallel)..." -Type Detail

            # Inline update check scriptblock (can't call main script functions in runspaces)
            $updateCheckScript = {
                param($ExtensionId, $ExtensionName, $UpdateUrl, $CurrentVersion, $BrowserVersion)

                try {
                    # Build update check URL (inline from Get-ExtensionUpdateInfo)
                    $xParam = "id%3D$ExtensionId%26v%3D$CurrentVersion%26uc"
                    $separator = if ($UpdateUrl.Contains("?")) { "&" } else { "?" }
                    $randomBytes = New-Object byte[] 32
                    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randomBytes)
                    $machineId = [System.BitConverter]::ToString($randomBytes).Replace("-", "").ToLower()

                    $checkUrl = "$UpdateUrl$separator" + `
                        "response=updatecheck&os=win&arch=x64&os_arch=x86_64&" + `
                        "prod=chromiumcrx&prodchannel=&prodversion=$BrowserVersion&" + `
                        "lang=en-US&acceptformat=crx3,puff&machine=$machineId&x=$xParam"

                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/$BrowserVersion")
                    $content = $wc.DownloadString($checkUrl)
                    $wc.Dispose()

                    [xml]$xml = $content
                    $ns = @{ g = "http://www.google.com/update2/response" }
                    $app = Select-Xml -Xml $xml -XPath "//g:app[@appid='$ExtensionId']" -Namespace $ns

                    if ($app -and $app.Node) {
                        $node = $app.Node.updatecheck
                        if ($node -and $node.version -and $node.codebase) {
                            return @{
                                Success      = $true
                                Name         = $ExtensionName
                                Version      = $node.version
                                Codebase     = $node.codebase
                                NeedsUpdate  = $true
                            }
                        }
                    }
                    return @{ Success = $true; Name = $ExtensionName; NeedsUpdate = $false }
                }
                catch {
                    return @{ Success = $false; Name = $ExtensionName; Error = $_.ToString() }
                }
            }

            # Build update check tasks
            $updateTasks = @()
            foreach ($ext in $extensionInfoList) {
                $updateTasks += @{
                    Script = $updateCheckScript
                    Args   = @($ext.Id, $ext.Name, $updateUrl, $ext.CurrentVersion, $BrowserVersion)
                }
            }

            $updateResults = Invoke-Parallel -Tasks $updateTasks -MaxThreads 4

            # ═══════════════════════════════════════════════════════════════
            # Phase 3: Parallel downloads for extensions needing updates
            # ═══════════════════════════════════════════════════════════════
            $downloadTasks = @()
            $downloadInfoMap = @{}  # Map extension name to output dir

            for ($idx = 0; $idx -lt $extensionInfoList.Count; $idx++) {
                $ext = $extensionInfoList[$idx]
                $result = $updateResults[$idx]

                if ($result.Success -and $result.NeedsUpdate) {
                    Write-Status "  $($ext.Name): v$($result.Version) available" -Type Detail

                    # All extensions download to temp first, then get moved/extracted
                    $tempCrx = Join-Path $env:TEMP "meteor_ext_$($ext.Name)_$(Get-Random).crx"

                    # comet_web_resources: mark for direct install (no extraction, just move to default_apps)
                    if ($ext.Name -eq 'comet_web_resources') {
                        $finalCrxPath = Join-Path $defaultAppsDir "comet_web_resources.crx"
                        $downloadInfoMap[$ext.Name] = @{
                            TempCrx       = $tempCrx
                            FinalCrxPath  = $finalCrxPath  # Where to move after download
                            OutputDir     = $null  # No extraction
                            Version       = $result.Version
                            Codebase      = $result.Codebase
                            DirectInstall = $true  # Flag for direct CRX install
                        }
                    }
                    else {
                        $downloadInfoMap[$ext.Name] = @{
                            TempCrx       = $tempCrx
                            FinalCrxPath  = $null
                            OutputDir     = $ext.OutputDir
                            Version       = $result.Version
                            Codebase      = $result.Codebase
                            DirectInstall = $false
                        }
                    }

                    # Inline download scriptblock
                    $downloadScript = {
                        param($Codebase, $TempCrx, $ExtName)
                        try {
                            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                            $wc = New-Object System.Net.WebClient
                            $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0")
                            $wc.DownloadFile($Codebase, $TempCrx)
                            $wc.Dispose()
                            return @{ Success = $true; Name = $ExtName; TempCrx = $TempCrx }
                        }
                        catch {
                            return @{ Success = $false; Name = $ExtName; Error = $_.ToString() }
                        }
                    }

                    $downloadTasks += @{
                        Script = $downloadScript
                        Args   = @($result.Codebase, $tempCrx, $ext.Name)
                    }
                }
                elseif (-not $result.Success) {
                    Write-Status "  $($ext.Name): update check failed - $($result.Error)" -Type Warning
                    $extensionsToProcess[$ext.Name] = @{ OutputDir = $ext.OutputDir; FromServer = $false; NeedsFallback = $true }
                }
                else {
                    Write-Status "  $($ext.Name): up to date" -Type Detail
                    $extensionsToProcess[$ext.Name] = @{ OutputDir = $ext.OutputDir; FromServer = $false; NeedsFallback = $true }
                }
            }

            # Run parallel downloads if any
            if ($downloadTasks.Count -gt 0) {
                Write-Status "Downloading $($downloadTasks.Count) extension(s) (parallel)..." -Type Detail
                $downloadResults = Invoke-Parallel -Tasks $downloadTasks -MaxThreads 4

                # ═══════════════════════════════════════════════════════════════
                # Phase 4: Sequential extraction (file I/O must be serial)
                # ═══════════════════════════════════════════════════════════════
                foreach ($dlResult in $downloadResults) {
                    $extName = $dlResult.Name
                    $dlInfo = $downloadInfoMap[$extName]

                    if ($dlResult.Success -and (Test-Path $dlResult.TempCrx)) {
                        # comet_web_resources: move from temp to final location, no extraction needed
                        if ($dlInfo.DirectInstall) {
                            try {
                                # Remove existing CRX if present
                                if (Test-Path $dlInfo.FinalCrxPath) {
                                    Remove-Item -Path $dlInfo.FinalCrxPath -Force
                                }
                                # Move temp CRX to final location
                                Move-Item -Path $dlResult.TempCrx -Destination $dlInfo.FinalCrxPath -Force
                                Write-Status "  $extName`: v$($dlInfo.Version) installed directly" -Type Success
                            }
                            catch {
                                Write-Status "  $extName`: failed to install ($($_.Exception.Message)), using existing CRX" -Type Warning
                                Remove-Item -Path $dlResult.TempCrx -Force -ErrorAction SilentlyContinue
                            }
                            # Don't add to extensionsToProcess - no patching needed, loaded via external_extensions.json
                            continue
                        }

                        Write-Status "  Extracting: $extName" -Type Detail
                        try {
                            if (Test-Path $dlInfo.OutputDir) {
                                Remove-Item -Path $dlInfo.OutputDir -Recurse -Force
                            }
                            $exportResult = Export-CrxToDirectory -CrxPath $dlResult.TempCrx -OutputDir $dlInfo.OutputDir -InjectKey
                            if ($exportResult) {
                                $extensionsToProcess[$extName] = @{
                                    OutputDir     = $dlInfo.OutputDir
                                    FromServer    = $true
                                    NeedsFallback = $false
                                    Version       = $dlInfo.Version
                                }
                            }
                            else {
                                Write-Status "  $extName`: extraction failed" -Type Warning
                                $extensionsToProcess[$extName] = @{ OutputDir = $dlInfo.OutputDir; FromServer = $false; NeedsFallback = $true }
                            }
                        }
                        finally {
                            Remove-Item -Path $dlResult.TempCrx -Force -ErrorAction SilentlyContinue
                        }
                    }
                    else {
                        # For DirectInstall extensions that failed, they'll still be loaded from existing CRX
                        if ($dlInfo.DirectInstall) {
                            $errMsg = if ($dlResult.Error) { $dlResult.Error } else { "unknown error" }
                            Write-Status "  $extName`: download failed ($errMsg), using existing CRX" -Type Warning
                            continue
                        }
                        Write-Status "  $extName`: download failed - $($dlResult.Error)" -Type Warning
                        $extensionsToProcess[$extName] = @{ OutputDir = $dlInfo.OutputDir; FromServer = $false; NeedsFallback = $true }
                    }
                }
            }
        }
    }
    else {
        # Mark all extensions for local fallback (except comet_web_resources which loads directly from CRX)
        if ($bundledExtensions) {
            foreach ($extName in $bundledExtensions.PSObject.Properties.Name) {
                if ($extName -eq 'comet_web_resources') { continue }  # Loaded via external_extensions.json
                $extOutputDir = Join-Path $OutputDir $extName
                $extensionsToProcess[$extName] = @{ OutputDir = $extOutputDir; FromServer = $false; NeedsFallback = $true }
            }
        }
    }

    # Handle local fallback for any extensions that failed server fetch
    $needsFallback = $extensionsToProcess.Values | Where-Object { $_.NeedsFallback }
    if ($needsFallback) {
        Write-Status "Using local CRX files for fallback..." -Type Detail

        # Find default_apps directory
        $defaultAppsDir = Get-DefaultAppsDirectory -CometDir $CometDir

        if ($defaultAppsDir) {
            Write-Status "Local source: $defaultAppsDir" -Type Detail

            # Find CRX files (backups first, then active - active takes precedence)
            $crxSources = @{}
            Get-ChildItem -Path $defaultAppsDir -Filter "*.crx*" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.crx' -or $_.Name.EndsWith('.crx.meteor-backup') } | ForEach-Object {
                $baseName = $_.Name -replace '\.crx(\.meteor-backup)?$', ''
                $crxSources[$baseName] = $_
            }

            # Process fallback extensions
            foreach ($extName in $extensionsToProcess.Keys) {
                $extData = $extensionsToProcess[$extName]
                if (-not $extData.NeedsFallback) { continue }

                if ($crxSources.ContainsKey($extName)) {
                    $crx = $crxSources[$extName]
                    Write-Status "Processing (local): $extName" -Type Info

                    if (-not $WhatIfPreference) {
                        Export-CrxToDirectory -CrxPath $crx.FullName -OutputDir $extData.OutputDir -InjectKey
                        Write-Status "Extracted to: $($extData.OutputDir)" -Type Detail
                        $extData.NeedsFallback = $false
                    }
                }
                else {
                    Write-Status "No local CRX found for: $extName" -Type Warning
                }
            }
        }
        else {
            Write-Status "No local CRX source available" -Type Warning
        }
    }

    # Apply patches to all successfully extracted extensions
    foreach ($extName in $extensionsToProcess.Keys) {
        $extData = $extensionsToProcess[$extName]
        $extOutputDir = $extData.OutputDir

        if ($WhatIfPreference) { continue }
        if (-not (Test-Path $extOutputDir)) { continue }

        # Apply patches if configured (check property exists to avoid StrictMode error)
        if ($PatchConfig.PSObject.Properties[$extName]) {
            $config = $PatchConfig.$extName

            # Copy additional files
            if ($config.PSObject.Properties['copy_files']) {
                foreach ($destFile in $config.copy_files.PSObject.Properties) {
                    $destPath = Join-Path $extOutputDir $destFile.Name
                    $srcPath = Resolve-MeteorPath -BasePath $PatchesDir -RelativePath $destFile.Value

                    # Ensure directory exists
                    New-DirectoryIfNotExists -Path (Split-Path -Parent $destPath)

                    if (Test-Path $srcPath) {
                        Copy-Item -Path $srcPath -Destination $destPath -Force

                        # Inject feature flags if this is a JS file with the placeholder
                        if ($destPath -match '\.js$') {
                            $content = Get-Content -Path $destPath -Raw -Encoding UTF8
                            if ($content -match '__METEOR_FEATURE_FLAGS__') {
                                # Build combined flags from config (simple + complex)
                                $combinedFlags = @{}
                                if ($MeteorConfig.PSObject.Properties['feature_flag_overrides']) {
                                    foreach ($prop in $MeteorConfig.feature_flag_overrides.PSObject.Properties) {
                                        if ($prop.Name -notlike '_comment*') {
                                            $combinedFlags[$prop.Name] = $prop.Value
                                        }
                                    }
                                }
                                if ($MeteorConfig.PSObject.Properties['feature_flag_complex_overrides']) {
                                    foreach ($prop in $MeteorConfig.feature_flag_complex_overrides.PSObject.Properties) {
                                        if ($prop.Name -notlike '_comment*') {
                                            $combinedFlags[$prop.Name] = $prop.Value
                                        }
                                    }
                                }
                                # Convert to JSON (use ConvertTo-Json with depth for nested objects)
                                $flagsJson = $combinedFlags | ConvertTo-Json -Depth 10 -Compress
                                $content = $content -replace '__METEOR_FEATURE_FLAGS__', $flagsJson
                                [System.IO.File]::WriteAllText($destPath, $content, [System.Text.UTF8Encoding]::new($false))
                                Write-Status "Injected feature flags into: $($destFile.Name)" -Type Detail
                            }
                        }

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
                    $manifest = Get-JsonFile -Path $manifestPath

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

                    Save-JsonFile -Path $manifestPath -Object $manifest -Depth 20
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
    .OUTPUTS
        Hashtable with Success, Skipped, ModifiedResourceIds, HashAfterModification
    #>
    param(
        [string]$CometDir,
        [object]$PakConfig,
        [string]$PatchedResourcesPath,
        [switch]$Force,
        [hashtable]$State = @{}
    )

    if (-not $PakConfig.enabled) {
        Write-Status "PAK modifications disabled in config" -Type Detail
        return @{ Success = $true; Skipped = $true }
    }

    # Early exit if no modifications configured - skip entire PAK processing
    # Use @() wrapper for PS 5.1 null-safety (ConvertFrom-Json returns $null for [])
    if (-not $PakConfig.modifications -or @($PakConfig.modifications).Count -eq 0) {
        Write-Status "No PAK modifications configured - skipping PAK processing" -Type Detail
        return @{ Success = $true; Skipped = $true }
    }

    # 1. Locate resources.pak
    $pakPath = Join-Path $CometDir "resources.pak"
    if (-not (Test-Path $pakPath)) {
        $versionDir = Find-CometVersionDirectory -CometPath $CometDir
        if ($versionDir) {
            $testPath = Join-Path $versionDir.FullName "resources.pak"
            if (Test-Path $testPath) {
                $pakPath = $testPath
            }
        }
    }

    if (-not (Test-Path $pakPath)) {
        Write-Status "resources.pak not found - skipping PAK modifications" -Type Warning
        return @{ Success = $true; Skipped = $true }
    }

    Write-Status "Found resources.pak: $pakPath" -Type Detail

    # 1.5. Restore from backup if -Force is used (ensures clean state)
    $backupPath = "$pakPath.meteor-backup"
    if ($Force -and (Test-Path $backupPath)) {
        Write-Status "Restoring PAK from backup (Force mode)" -Type Detail
        Copy-Item -Path $backupPath -Destination $pakPath -Force
    }

    # 1.6. State-based skip (only when NOT forcing)
    # If we have pak_state with matching hash and config, skip processing
    # Optimization: Check file hash first (fast), only calculate config hash if file hash matches
    if (-not $Force -and $State.pak_state -and $State.pak_state.hash_after_modification) {
        $currentHash = Get-FileHash256 -Path $pakPath

        if ($State.pak_state.hash_after_modification -eq $currentHash) {
            # File matches - now check config hash (slower)
            $sortedConfig = ConvertTo-SortedObject -InputObject $PakConfig
            $configHash = Get-StringHash256 -Content ($sortedConfig | ConvertTo-Json -Compress -Depth 10)

            if ($State.pak_state.modification_config_hash -eq $configHash) {
                Write-Status "PAK already patched (verified via state hash) - skipping" -Type Detail
                return @{
                    Success               = $true
                    Skipped               = $true
                    ModifiedResourceIds   = $State.pak_state.modified_resources
                    HashAfterModification = $currentHash
                }
            }
        }
    }

    # 2. Read and parse PAK
    try {
        $pak = Read-PakFile -Path $pakPath
        Write-Status "Parsed PAK v$($pak.Version) with $($pak.Resources.Count - 1) resources" -Type Detail
    }
    catch {
        Write-Status "Failed to parse PAK: $_" -Type Error
        return @{ Success = $false; Error = "Failed to parse PAK: $_" }
    }

    # 2.5. Export resources to patched_resources directory (for manual editing)
    if ($PatchedResourcesPath -and -not $WhatIfPreference) {
        try {
            $exportResult = Export-PakResources -Pak $pak -OutputDir $PatchedResourcesPath
            Write-Status "Exported $($exportResult.TotalResources) resources to: $PatchedResourcesPath" -Type Detail
            Write-VerboseTimestamped "[PAK] Export: $($exportResult.TextResources) text, $($exportResult.BinaryResources) binary, $($exportResult.GzippedCount) were gzipped"
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

    # Track unmatched patterns for early exit optimization
    # Once a pattern is matched, we remove its index - when set is empty, all patterns found
    $unmatchedPatterns = New-Object 'System.Collections.Generic.HashSet[int]'
    for ($j = 0; $j -lt @($PakConfig.modifications).Count; $j++) {
        [void]$unmatchedPatterns.Add($j)
    }
    $totalPatterns = $unmatchedPatterns.Count

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
            $decompressed = Expand-GzipData -CompressedBytes $resourceBytes
            if ($null -eq $decompressed) { continue }
            $contentBytes = $decompressed
        }

        # Skip binary resources
        if (Test-BinaryContent -Bytes $contentBytes) { continue }
        $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)

        $textCount++
        $resourceModified = $false

        # Try each modification pattern
        $modIndex = 0
        foreach ($mod in $PakConfig.modifications) {
            if ($content -match $mod.pattern) {
                # Show context around the match for debugging
                if ($content -match "(.{0,100})($([regex]::Escape($mod.pattern)))(.{0,100})") {
                    $context = "$($Matches[1])>>>$($Matches[2])<<<$($Matches[3])" -replace '[\r\n]+', ' '
                    Write-VerboseTimestamped "[PAK] Match context in $resourceId`: $context"
                }
                $content = $content -replace $mod.pattern, $mod.replacement
                Write-Status "  Resource $resourceId - $($mod.description)" -Type Detail
                $resourceModified = $true
                $appliedCount++
                # Mark this pattern as matched for early exit
                [void]$unmatchedPatterns.Remove($modIndex)
            }
            $modIndex++
        }

        # Track modified resources (with compression flag)
        if ($resourceModified) {
            $modifiedResources[$resourceId] = @{
                Content = $content
                WasGzipped = $isGzipped
            }
        }

        # Early exit: stop scanning if all patterns have been matched
        if ($unmatchedPatterns.Count -eq 0 -and $totalPatterns -gt 0) {
            Write-Status "[PAK] All $totalPatterns patterns matched - stopping scan early at resource $($i+1) of $($pak.Resources.Count - 1)" -Type Detail
            break
        }
    }

    # Log scan statistics
    Write-VerboseTimestamped "[PAK] Scan complete: $scannedCount resources, $gzipCount gzipped, $textCount text files, $appliedCount patterns matched"
    if ($appliedCount -eq 0) {
        Write-Status "PAK scan stats: $scannedCount resources, $gzipCount gzipped, $textCount text - no pattern matches" -Type Detail
    }

    # 4. Prepare all byte modifications (optimized batch approach)
    $byteModifications = @{}
    foreach ($resourceId in $modifiedResources.Keys) {
        try {
            Write-VerboseTimestamped "[PAK] Preparing resource $resourceId"
            $entry = $modifiedResources[$resourceId]
            $contentString = $entry['Content']
            $wasGzipped = $entry['WasGzipped']

            Write-VerboseTimestamped "[PAK] Content type: $($contentString.GetType().FullName), WasGzipped: $wasGzipped"

            if ($null -eq $contentString) {
                Write-Status "Content is null for resource $resourceId" -Type Error
                continue
            }

            Write-VerboseTimestamped "[PAK] Encoding to UTF8..."
            [byte[]]$newBytes = [System.Text.Encoding]::UTF8.GetBytes($contentString)

            if ($null -eq $newBytes) {
                Write-Status "Failed to encode content for resource $resourceId" -Type Error
                continue
            }

            # Re-compress if originally gzipped
            if ($wasGzipped) {
                Write-VerboseTimestamped "[PAK] Recompressing with gzip..."
                $compressedBytes = Compress-GzipData -UncompressedBytes $newBytes
                if ($null -eq $compressedBytes) {
                    Write-Status "Gzip compression returned null for resource $resourceId" -Type Error
                    continue
                }
                $newBytes = [byte[]]$compressedBytes
                Write-VerboseTimestamped "[PAK] Compressed to $($newBytes.GetLength(0)) bytes"
            }

            if ($WhatIfPreference) {
                Write-Status "Would modify resource $resourceId$(if ($wasGzipped) { ' (gzipped)' })" -Type DryRun
            }
            else {
                $byteModifications[$resourceId] = $newBytes
            }
        }
        catch {
            Write-Status "Error preparing resource $resourceId`: $($_.Exception.Message)" -Type Error
            continue
        }
    }

    # 5. Write modified PAK in single pass (with backup)
    $finalHash = $null
    $modifiedResourceIds = @([int[]]$modifiedResources.Keys)

    if ($byteModifications.Count -gt 0 -and -not $WhatIfPreference) {
        $backupPath = "$pakPath.meteor-backup"

        if (-not (Test-Path $backupPath)) {
            Copy-Item -Path $pakPath -Destination $backupPath -Force
            Write-Status "Created backup: $backupPath" -Type Detail
        }
        else {
            Write-VerboseTimestamped "[PAK] Backup already exists at: $backupPath"
        }

        try {
            # Skip beforeHash when -Force is used (we just restored from backup, so we know it's changing)
            $beforeHash = $null
            if (-not $Force) {
                $beforeHash = Get-FileHash256 -Path $pakPath
                Write-VerboseTimestamped "[PAK] Hash before write: $beforeHash"
            }

            # Use optimized batch writer (single pass, no O(n²) memory)
            Write-PakFileWithModifications -Pak $pak -Path $pakPath -Modifications $byteModifications

            # Always calculate afterHash - needed for state
            $afterHash = Get-FileHash256 -Path $pakPath
            $finalHash = $afterHash
            Write-VerboseTimestamped "[PAK] Hash after write: $afterHash"

            if ($beforeHash -and $beforeHash -eq $afterHash) {
                Write-Status "PAK file unchanged after write - modifications may not have been applied!" -Type Warning
            }
            else {
                Write-Status "Wrote modified PAK ($($modifiedResources.Count) resources, $appliedCount modifications)" -Type Success
                Write-VerboseTimestamped "[PAK] File modified successfully (hash changed)"

                # Re-read and verify one of our modifications (resource 21192 - shouldHide)
                $verifyPak = Read-PakFile -Path $pakPath
                if ($verifyPak) {
                    $verifyBytes = Get-PakResource -Pak $verifyPak -ResourceId 21192
                    if ($verifyBytes) {
                        [byte[]]$verifyBytes = $verifyBytes
                        # Decompress if gzipped
                        if ($verifyBytes[0] -eq 0x1f -and $verifyBytes[1] -eq 0x8b) {
                            $decompressed = Expand-GzipData -CompressedBytes $verifyBytes
                            if ($null -ne $decompressed) {
                                $verifyBytes = $decompressed
                            }
                        }
                        $verifyContent = [System.Text.Encoding]::UTF8.GetString($verifyBytes)
                        if ($verifyContent -match 'return false;\s*//\s*Meteor|shouldHidePerplexityServiceWorker.*return false;') {
                            Write-VerboseTimestamped "[PAK] Verification: inspect modification confirmed in written file"
                        }
                        elseif ($verifyContent -notmatch 'return !isPerplexityInternalUser') {
                            Write-VerboseTimestamped "[PAK] Verification: original pattern NOT found (modification likely applied)"
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
            return @{ Success = $false; Error = "Failed to write PAK: $_" }
        }
    }
    elseif ($appliedCount -eq 0) {
        Write-Status "PAK modifications: No matching patterns found" -Type Warning
    }

    # Calculate config hash for state storage
    $sortedConfig = ConvertTo-SortedObject -InputObject $PakConfig
    $configHash = Get-StringHash256 -Content ($sortedConfig | ConvertTo-Json -Compress -Depth 10)

    return @{
        Success                 = $true
        Skipped                 = $false
        ModifiedResourceIds     = $modifiedResourceIds
        HashAfterModification   = $finalHash
        ModificationConfigHash  = $configHash
    }
}

#endregion

#region Preferences Pre-seeding

# ============================================================================
# HMAC-Based Secure Preferences
# ============================================================================
# Chromium protects certain preferences with HMAC-SHA256 signatures.
# Directly modifying these preferences triggers "tracked_preferences_reset".
#
# This implementation calculates proper HMACs using:
# 1. HMAC seed extracted from resources.pak
# 2. Device ID (Windows SID without RID, hashed)
# 3. Preference path + JSON-serialized value
#
# Reference: https://www.cse.chalmers.se/~andrei/cans20.pdf
# Source: services/preferences/tracked/pref_hash_calculator.cc
# ============================================================================

function Get-Sha256 {
    <#
    .SYNOPSIS
        Calculate plain SHA256 and return as uppercase hex string.
    .DESCRIPTION
        Used for Chromium preference MAC calculation. Chromium uses plain SHA256
        (not HMAC) for individual preference MACs via crypto::SHA256HashString().
        Reference: chromium/src/components/prefs/pref_hash_calculator.cc
    #>
    param(
        [byte[]]$Message
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha256.ComputeHash($Message)
    $sha256.Dispose()
    return ([BitConverter]::ToString($hash) -replace '-', '').ToUpper()
}

function Get-HmacSha256 {
    <#
    .SYNOPSIS
        Calculate HMAC-SHA256 and return as uppercase hex string.
    .DESCRIPTION
        Used for Registry MACs which use HMAC with the literal seed string.
    #>
    param(
        [byte[]]$Key,
        [byte[]]$Message
    )

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $Key
    $hash = $hmac.ComputeHash($Message)
    return ([BitConverter]::ToString($hash) -replace '-', '').ToUpper()
}

function Get-WindowsSidWithoutRid {
    <#
    .SYNOPSIS
        Get Windows User SID without the RID (Relative ID) component.
    .DESCRIPTION
        Chromium uses the SID without the final component as the machine identifier.
        Example: S-1-5-21-123456789-987654321-555555555-1001 → S-1-5-21-123456789-987654321-555555555
    #>

    try {
        # Method 1: Use .NET SecurityIdentifier
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $sid = $identity.User.Value

        # Remove the RID (last component after final dash)
        $sidWithoutRid = $sid -replace '-\d+$', ''
        return $sidWithoutRid
    }
    catch {
        Write-VerboseTimestamped "[SID] .NET method failed: $_"
    }

    try {
        # Method 2: whoami /user
        $output = & whoami /user /fo csv 2>$null
        if ($output) {
            $lines = $output -split "`n"
            if ($lines.Count -gt 1) {
                $sid = ($lines[1] -split ',')[1].Trim().Trim('"')
                $sidWithoutRid = $sid -replace '-\d+$', ''
                return $sidWithoutRid
            }
        }
    }
    catch {
        Write-VerboseTimestamped "[SID] whoami method failed: $_"
    }

    Write-Warning "[SID] Could not extract Windows SID - using empty device ID"
    return ""
}

function Get-ChromiumDeviceId {
    <#
    .SYNOPSIS
        Get device ID for Chromium preference HMAC calculation.
    .DESCRIPTION
        According to Chromium source (services/preferences/tracked/device_id_win.cc),
        the device ID is the raw machine SID used DIRECTLY without any transformation.

        The old GenerateDeviceIdLikePrefMetricsServiceDid() function exists in the codebase
        but is NOT used for preference protection. The PrefHashStoreImpl constructor
        passes GenerateDeviceId() directly to PrefHashCalculator:
          prefs_hash_calculator_(seed, GenerateDeviceId())

        See: https://chromium.googlesource.com/chromium/src/+/main/services/preferences/tracked/device_id_win.cc
        See: https://chromium.googlesource.com/chromium/src/+/main/services/preferences/tracked/pref_hash_store_impl.cc
    #>
    param([string]$RawMachineId)

    # Device ID is the raw machine SID used directly - no transformation
    return $RawMachineId
}

function Get-HmacSeedFromLocalState {
    <#
    .SYNOPSIS
        Get or create HMAC seed from Local State file.
    .DESCRIPTION
        Chromium stores the HMAC seed in the Local State file under protection.seed
        as a base64-encoded 32-byte value. If no seed exists, we generate one.
    .PARAMETER LocalStatePath
        Path to the Local State file.
    .PARAMETER CreateIfMissing
        If true, creates a new random seed if none exists.
    .OUTPUTS
        Hashtable with 'seed' (hex string) and 'localState' (parsed JSON object).
    #>
    param(
        [string]$LocalStatePath,
        [switch]$CreateIfMissing
    )

    $localState = $null
    $seedBytes = $null

    # Try to read existing Local State
    if (Test-Path $LocalStatePath) {
        try {
            $json = Get-Content -Path $LocalStatePath -Raw -ErrorAction Stop
            $localState = $json | ConvertFrom-Json -ErrorAction Stop

            # Check for existing seed
            if ($localState.protection -and $localState.protection.seed) {
                $seedBase64 = $localState.protection.seed
                $seedBytes = [Convert]::FromBase64String($seedBase64)
                Write-VerboseTimestamped "[HMAC Seed] Found existing seed in Local State"
            }
        }
        catch {
            Write-VerboseTimestamped "[HMAC Seed] Failed to parse Local State: $_"
            $localState = $null
        }
    }

    # Generate new seed if needed
    if (-not $seedBytes -and $CreateIfMissing) {
        $seedBytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
        $rng.GetBytes($seedBytes)
        $rng.Dispose()
        Write-VerboseTimestamped "[HMAC Seed] Generated new random seed"
    }

    if (-not $seedBytes) {
        return $null
    }

    # Convert to hex for our HMAC functions
    $hexSeed = ([BitConverter]::ToString($seedBytes) -replace '-', '').ToLower()

    # Prepare Local State object if needed
    if (-not $localState) {
        $localState = @{}
    }

    # Ensure protection section exists with seed
    $seedBase64 = [Convert]::ToBase64String($seedBytes)
    if ($localState -is [PSCustomObject]) {
        # Convert to hashtable for modification
        $localState = Convert-PSObjectToHashtable -InputObject $localState
    }
    if (-not $localState.ContainsKey('protection')) {
        $localState['protection'] = @{}
    }
    $localState['protection']['seed'] = $seedBase64

    return @{
        seed       = $hexSeed
        localState = $localState
    }
}

function ConvertTo-SortedObject {
    <#
    .SYNOPSIS
        Recursively sort all keys and PRUNE empty containers for internal state management.

    .DESCRIPTION
        PURPOSE: Internal state management and preparation for JSON serialization.
        This function prepares objects for consistent JSON output by sorting keys
        alphabetically and pruning empty containers.

        DISTINCT FROM ConvertTo-ChromiumJson:
        - ConvertTo-SortedObject: Handles STRUCTURE (key ordering, pruning)
        - ConvertTo-ChromiumJson: Handles STRING FORMAT (unicode escaping)
        - ConvertTo-JsonForHmac: Orchestrates both for MAC calculation

        KEY BEHAVIORS:
        1. Sorts hashtable/object keys alphabetically (Chromium's JSONWriter behavior)
        2. Prunes empty containers (null, [], {}) from dictionary entries
        3. Recursively processes nested structures
        4. Preserves array element order (only sorts keys within array elements)

        EDGE CASES:
        - Empty arrays [] inside arrays: Preserved (not pruned from parent array)
        - Empty arrays [] as dict values: Pruned (removed from parent dict)
        - Null values: Pruned from dict entries
        - Primitives (string, bool, number): Passed through unchanged

        PowerShell 5.1 COMPATIBILITY:
        - Empty arrays ([]) returned from pipelines become $null due to array unrolling
        - SOLUTION: Use comma operator (return ,$result) to prevent unrolling
        - Uses explicit foreach loops instead of pipelines for array processing
        - Uses ArrayList for building arrays to avoid PS 5.1 quirks

    .PARAMETER Value
        The object to sort. Can be hashtable, PSCustomObject, array, or primitive.

    .OUTPUTS
        Returns the sorted object with the same type as input (hashtable -> ordered hashtable,
        PSCustomObject -> ordered hashtable, array -> array, primitives unchanged).

    .EXAMPLE
        $sorted = ConvertTo-SortedObject -Value @{ z = 1; a = 2; m = @{ y = 3; b = 4 } }
        # Result: [ordered]@{ a = 2; m = [ordered]@{ b = 4; y = 3 }; z = 1 }

    .NOTES
        Reference: Chromium's PrefHashCalculator prunes empty containers before MAC calculation.
        See: services/preferences/tracked/pref_hash_calculator.cc
    #>
    [OutputType([object])]
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [hashtable]) {
        $sorted = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object)) {
            $childValue = ConvertTo-SortedObject -Value $Value[$key]
            # PRUNE: Skip empty containers (null, empty arrays, empty hashtables, etc.)
            if (Test-IsEmptyContainer -Value $childValue) { continue }
            $sorted[$key] = $childValue
        }
        return $sorted
    }

    if ($Value -is [PSCustomObject]) {
        $sorted = [ordered]@{}
        foreach ($prop in ($Value.PSObject.Properties | Sort-Object Name)) {
            $childValue = ConvertTo-SortedObject -Value $prop.Value
            # PRUNE: Skip empty containers (null, empty arrays, empty hashtables, etc.)
            if (Test-IsEmptyContainer -Value $childValue) { continue }
            $sorted[$prop.Name] = $childValue
        }
        return $sorted
    }

    if ($Value -is [array]) {
        # Arrays maintain order, but sort nested objects (don't prune items from arrays)
        # CRITICAL: Use explicit foreach, not pipeline, to avoid PS 5.1 serialization bugs
        $result = [System.Collections.ArrayList]::new()
        foreach ($item in $Value) {
            $sorted = ConvertTo-SortedObject -Value $item
            $null = $result.Add($sorted)
        }
        # CRITICAL: Use comma operator to prevent PowerShell from unrolling empty arrays to $null
        return ,$result.ToArray()
    }

    # Primitives pass through unchanged
    return $Value
}

function ConvertTo-ChromiumJson {
    <#
    .SYNOPSIS
        Normalize PowerShell JSON string to match Chromium's JSONWriter unicode escaping format.

    .DESCRIPTION
        PURPOSE: MAC calculation - ensures JSON strings match Chromium's exact format for HMAC.
        This function performs STRING-LEVEL normalization on already-serialized JSON.

        DISTINCT FROM ConvertTo-SortedObject:
        - ConvertTo-SortedObject: Handles STRUCTURE (key ordering, pruning) before serialization
        - ConvertTo-ChromiumJson: Handles STRING FORMAT (unicode escaping) after serialization
        - ConvertTo-JsonForHmac: Orchestrates both for complete MAC calculation

        UNICODE ESCAPING DIFFERENCES:
        +--------------+------------------+-------------------+
        | Character    | PowerShell       | Chromium          |
        +--------------+------------------+-------------------+
        | <            | \u003c           | \u003C (uppercase)|
        | >            | \u003e           | > (literal)       |
        | '            | \u0027           | ' (literal)       |
        | Other escapes| \uxxxx (lower)   | \uXXXX (upper)    |
        +--------------+------------------+-------------------+

        WHY THIS MATTERS:
        HMAC-SHA256 is calculated on the byte-level representation of the JSON string.
        Even a single character difference (e.g., lowercase 'c' vs uppercase 'C' in \u003c)
        will produce a completely different MAC, causing Chromium to reject the preference.

        TRANSFORMATIONS APPLIED:
        1. Convert all \uXXXX escapes to uppercase hex (\u003c -> \u003C)
        2. Unescape > character (\u003E -> >)
        3. Unescape ' character (\u0027 -> ')

    .PARAMETER Json
        The JSON string to normalize. Must be valid JSON from ConvertTo-Json.

    .OUTPUTS
        The normalized JSON string with Chromium-compatible unicode escaping.

    .EXAMPLE
        $json = '{"url":"\u003cscript\u003e"}'
        ConvertTo-ChromiumJson -Json $json
        # Returns: '{"url":"\u003Cscript>"}'

    .NOTES
        Reference: Chromium's JSONWriter implementation
        See: base/json/json_writer.cc
    #>
    [OutputType([string])]
    param(
        [ValidateNotNull()]
        [string]$Json
    )

    if ([string]::IsNullOrEmpty($Json)) {
        return $Json
    }

    # Step 1: Convert all lowercase unicode escapes to uppercase
    # Pattern: \uXXXX where XXXX is hex (case-insensitive match, replace with uppercase)
    $result = [regex]::Replace($Json, '\\u([0-9a-fA-F]{4})', {
        param($match)
        "\u" + $match.Groups[1].Value.ToUpper()
    })

    # Step 2: Unescape > (Chromium doesn't escape it)
    # \u003E -> >
    $result = $result -replace '\\u003E', '>'

    # Step 3: Unescape single quotes (Chromium doesn't escape them)
    # \u0027 -> '
    # PowerShell escapes ' as \u0027, but Chromium writes literal '
    $result = $result -replace '\\u0027', "'"

    return $result
}

function ConvertTo-JsonForHmac {
    <#
    .SYNOPSIS
        Serialize any value to JSON string for HMAC/MAC calculation, matching Chromium's exact format.

    .DESCRIPTION
        PURPOSE: MAC calculation - this is the MAIN entry point for serializing values
        for HMAC calculation. Orchestrates ConvertTo-SortedObject and ConvertTo-ChromiumJson.

        SERIALIZATION PIPELINE:
        1. Handle special cases (null, booleans, numbers) with type-specific formatting
        2. For complex types, sort keys via ConvertTo-SortedObject
        3. Serialize to JSON via ConvertTo-Json
        4. Normalize unicode escaping via ConvertTo-ChromiumJson

        TYPE-SPECIFIC RULES (must match Chromium's PrefHashCalculator):
        +--------------+------------------------+---------------------------+
        | Type         | PowerShell Default     | Chromium Format           |
        +--------------+------------------------+---------------------------+
        | null         | "null"                 | "" (empty string)         |
        | bool true    | "True" or true         | "true" (lowercase)        |
        | bool false   | "False" or false       | "false" (lowercase)       |
        | numbers      | JSON number            | JSON number               |
        | strings      | "value"                | "value" (with \u003C etc) |
        | arrays       | [...]                  | [...] (sorted inner keys) |
        | objects      | {...}                  | {...} (sorted keys)       |
        +--------------+------------------------+---------------------------+

        PowerShell 5.1 EMPTY ARRAY HANDLING:
        - Problem: Empty arrays [] piped to ConvertTo-Json become $null due to unrolling
        - Solution: Check for empty array BEFORE piping to ConvertTo-Json
        - Returns literal "[]" string for empty arrays

    .PARAMETER Value
        The value to serialize. Can be any type: null, bool, number, string, array, or object.

    .OUTPUTS
        JSON string matching Chromium's exact format for HMAC calculation.

    .EXAMPLE
        ConvertTo-JsonForHmac -Value $true
        # Returns: "true"

    .EXAMPLE
        ConvertTo-JsonForHmac -Value @{ b = 2; a = 1 }
        # Returns: '{"a":1,"b":2}' (keys sorted alphabetically)

    .NOTES
        Reference: Chromium's PrefHashCalculator::Serialize
        See: services/preferences/tracked/pref_hash_calculator.cc
    #>
    [OutputType([string])]
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return ""  # Chromium uses empty string for null values, not "null"
    }
    if ($Value -is [bool]) {
        if ($Value) { return "true" } else { return "false" }
    }
    if ($Value -is [int] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [float] -or $Value -is [single]) {
        # Use ConvertTo-Json for consistent number formatting
        return ($Value | ConvertTo-Json -Compress)
    }
    if ($Value -is [string]) {
        # JSON-encode the string (adds quotes and escapes), then normalize unicode
        $json = $Value | ConvertTo-Json -Compress
        return ConvertTo-ChromiumJson -Json $json
    }
    if ($Value -is [array]) {
        # WORKAROUND for PowerShell 5.1: Empty arrays piped to ConvertTo-Json return null
        # because PowerShell unrolls the array in the pipeline
        if ($Value.Count -eq 0) {
            return "[]"
        }
        # CRITICAL: Sort keys alphabetically to match Chromium's JSONWriter
        $sorted = ConvertTo-SortedObject -Value $Value
        $json = ConvertTo-Json -InputObject $sorted -Compress -Depth 20
        return ConvertTo-ChromiumJson -Json $json
    }
    if ($Value -is [hashtable] -or $Value -is [PSCustomObject]) {
        # CRITICAL: Sort keys alphabetically to match Chromium's JSONWriter
        $sorted = ConvertTo-SortedObject -Value $Value
        $json = ConvertTo-Json -InputObject $sorted -Compress -Depth 20
        return ConvertTo-ChromiumJson -Json $json
    }

    $json = $Value | ConvertTo-Json -Compress
    return ConvertTo-ChromiumJson -Json $json
}

function Get-HmacMessageBytes {
    <#
    .SYNOPSIS
        Build HMAC message bytes for preference MAC calculation.
    .DESCRIPTION
        Chromium's HMAC message format: device_id + path + value_json (simple concatenation)
    #>
    param(
        [string]$DeviceId,
        [string]$Path,
        [object]$Value
    )

    $valueJson = ConvertTo-JsonForHmac -Value $Value
    $message = $DeviceId + $Path + $valueJson
    return [System.Text.Encoding]::UTF8.GetBytes($message)
}

function Get-PreferenceHmac {
    <#
    .SYNOPSIS
        Calculate HMAC for a single preference (file-based).
    .DESCRIPTION
        HMAC-SHA256(key=seed, message=device_id + path + value_json)
        Returns uppercase hex string.

        For Google Chrome: seed is 64-byte value from IDR_PREF_HASH_SEED_BIN
        For non-Chrome builds (Comet): seed is empty string, resulting in empty key
    #>
    param(
        [string]$SeedHex,
        [string]$DeviceId,
        [string]$Path,
        [object]$Value
    )

    # Handle empty seed for non-Chrome builds
    if ([string]::IsNullOrEmpty($SeedHex)) {
        $seedBytes = [byte[]]@()
    } else {
        $seedLength = $SeedHex.Length / 2
        $seedBytes = [byte[]]::new($seedLength)
        for ($i = 0; $i -lt $seedLength; $i++) {
            $seedBytes[$i] = [Convert]::ToByte($SeedHex.Substring($i * 2, 2), 16)
        }
    }

    $messageBytes = Get-HmacMessageBytes -DeviceId $DeviceId -Path $Path -Value $Value
    return Get-HmacSha256 -Key $seedBytes -Message $messageBytes
}

function Get-PreferenceHmacSeedFromPak {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'CometDir', Justification = 'Kept for API compatibility')]
    param(
        [string]$CometDir
    )

    # Comet is NOT Google Chrome branded, so it uses an empty seed for file MACs
    # This is by design in Chromium - see chrome_pref_service_factory.cc
    Write-VerboseTimestamped "[PAK Seed] Comet (non-Chrome branded build) uses empty seed for file MACs"

    return @{
        seedHex    = ""
        seedBytes  = @()
        resourceId = -1
        pakPath    = $null
    }
}

function Get-RegistryPreferenceHmac {
    <#
    .SYNOPSIS
        Calculate HMAC for a single preference in Windows Registry.
    .DESCRIPTION
        HMAC-SHA256(key="ChromeRegistryHashStoreValidationSeed", message=device_id + path + value_json)
        Returns uppercase hex string. Uses literal ASCII seed for registry-based MACs.
    #>
    param(
        [string]$DeviceId,
        [string]$Path,
        [object]$Value
    )

    $seedBytes = [System.Text.Encoding]::ASCII.GetBytes($script:RegistryHashSeed)
    $messageBytes = Get-HmacMessageBytes -DeviceId $DeviceId -Path $Path -Value $Value
    return Get-HmacSha256 -Key $seedBytes -Message $messageBytes
}

function Set-RegistryPreferenceMacs {
    param(
        [string]$DeviceId,
        [hashtable]$PreferencesToSet
    )

    $regPath = "HKCU:\SOFTWARE\Perplexity\Comet\PreferenceMACs\Default"

    # Known split prefixes - these use hierarchical subkey structure
    # Determined by Chromium's pref_hash_filter.cc tracked split preferences
    $splitPrefixes = @(
        "extensions.settings"
    )

    function Test-IsSplitPath {
        param([string]$Path)
        foreach ($prefix in $splitPrefixes) {
            if ($Path.StartsWith("$prefix.")) {
                return @{
                    IsSplit = $true
                    Prefix = $prefix
                    Suffix = $Path.Substring($prefix.Length + 1)
                }
            }
        }
        return @{ IsSplit = $false }
    }

    if ($WhatIfPreference) {
        Write-Status "Would set registry MACs at: $regPath" -Type Detail
        foreach ($path in $PreferencesToSet.Keys) {
            # Use FULL path for HMAC calculation (including account_values prefix if present)
            # This matches Chromium behavior where account_values.X and X have different MACs
            $mac = Get-RegistryPreferenceHmac -DeviceId $DeviceId -Path $path -Value $PreferencesToSet[$path]
            $splitInfo = Test-IsSplitPath -Path $path
            if ($splitInfo.IsSplit) {
                Write-VerboseTimestamped "[Registry MAC] Would set (split) $($splitInfo.Prefix)\$($splitInfo.Suffix) = $($mac.Substring(0, 16))..."
            }
            else {
                Write-VerboseTimestamped "[Registry MAC] Would set (atomic) $path = $($mac.Substring(0, 16))..."
            }
        }
        return $true
    }

    try {
        # Create the registry path if it doesn't exist
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
            Write-VerboseTimestamped "[Registry MAC] Created path: $regPath"
        }

        foreach ($path in $PreferencesToSet.Keys) {
            $value = $PreferencesToSet[$path]
            # Use FULL path for HMAC calculation (including account_values prefix if present)
            # This matches Chromium behavior where account_values.X and X have different MACs
            $mac = Get-RegistryPreferenceHmac -DeviceId $DeviceId -Path $path -Value $value

            $splitInfo = Test-IsSplitPath -Path $path

            if ($splitInfo.IsSplit) {
                # Split MAC: Write to subkey structure
                # e.g., extensions.settings.xxx -> Default\extensions.settings\xxx
                $subkeyPath = Join-Path $regPath $splitInfo.Prefix
                if (-not (Test-Path $subkeyPath)) {
                    New-Item -Path $subkeyPath -Force | Out-Null
                    Write-VerboseTimestamped "[Registry MAC] Created subkey: $subkeyPath"
                }
                Set-ItemProperty -Path $subkeyPath -Name $splitInfo.Suffix -Value $mac -Type String -Force
                Write-VerboseTimestamped "[Registry MAC] Set (split) $($splitInfo.Prefix)\$($splitInfo.Suffix) = $($mac.Substring(0, 16))..."
            }
            else {
                # Atomic MAC: Write directly to Default key
                Set-ItemProperty -Path $regPath -Name $path -Value $mac -Type String -Force
                Write-VerboseTimestamped "[Registry MAC] Set (atomic) $path = $($mac.Substring(0, 16))..."
            }
        }

        Write-VerboseTimestamped "[Registry MAC] Updated $($PreferencesToSet.Count) registry MACs"
        return $true
    }
    catch {
        Write-VerboseTimestamped "[Registry MAC] Error setting registry MACs: $_"
        return $false
    }
}

function Get-SuperMac {
    <#
    .SYNOPSIS
        Calculate super_mac (global integrity check).
    .DESCRIPTION
        According to Chromium source (pref_hash_store_impl.cc):
            contents_->SetSuperMac(outer_->ComputeMac("", hashes_dict));

        Where ComputeMac calls:
            HMAC-SHA256(seed, device_id + path + value_json)

        For super_mac:
            path = "" (empty string)
            value_json = JSON serialization of the nested macs dictionary

        The message format is: device_id + "" + json(macs_dict)
    #>
    param(
        [string]$SeedHex,
        [string]$DeviceId,
        [hashtable]$MacsTree  # Nested macs structure (not flattened)
    )

    # Handle empty seed for non-Chrome builds (Comet uses empty seed)
    if ([string]::IsNullOrEmpty($SeedHex)) {
        $seedBytes = [byte[]]@()
    } else {
        $seedLength = $SeedHex.Length / 2
        $seedBytes = [byte[]]::new($seedLength)
        for ($i = 0; $i -lt $seedLength; $i++) {
            $seedBytes[$i] = [Convert]::ToByte($SeedHex.Substring($i * 2, 2), 16)
        }
    }

    # Serialize the macs tree to JSON (Chromium style)
    # The macs tree is the nested structure like: { homepage: "MAC", browser: { show_home_button: "MAC" }, ... }
    $macsJson = ConvertTo-JsonForHmac -Value $MacsTree

    # Debug: Show first part of macs JSON for verification
    Write-VerboseTimestamped "[SuperMac] Macs JSON length: $($macsJson.Length)"
    Write-VerboseTimestamped "[SuperMac] Macs JSON (first 200 chars): $($macsJson.Substring(0, [Math]::Min(200, $macsJson.Length)))"

    # Build message: device_id + path + value_json
    # For super_mac: path is empty string ""
    $message = $DeviceId + "" + $macsJson

    Write-VerboseTimestamped "[SuperMac] Message length: $($message.Length) (device_id=$($DeviceId.Length) + path=0 + json=$($macsJson.Length))"

    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    return Get-HmacSha256 -Key $seedBytes -Message $messageBytes
}

function Build-MacsTree {
    <#
    .SYNOPSIS
        Build nested macs tree from flat dictionary.
    .DESCRIPTION
        Input: @{"homepage" = "MAC1"; "browser.show_home_button" = "MAC2"}
        Output: @{homepage = "MAC1"; browser = @{show_home_button = "MAC2"}}
    #>
    param([hashtable]$PathsAndMacs)

    $macsTree = @{}
    foreach ($path in $PathsAndMacs.Keys) {
        Set-NestedValue -Hashtable $macsTree -Path $path -Value $PathsAndMacs[$path]
    }
    return $macsTree
}

function Set-BrowserPreferences {
    <#
    .SYNOPSIS
        Write Secure Preferences file with tracked preferences and valid MACs.
    .DESCRIPTION
        On first run: Creates Secure Preferences with tracked preferences, calculates
        valid HMACs (file + registry), and sets up the protection.macs structure.
        Comet (non-Chrome branded) uses an EMPTY seed for file MACs, so we can
        calculate them immediately without waiting for browser initialization.

        On subsequent runs: Updates existing tracked preferences and recalculates MACs.
    #>
    param(
        [string]$UserDataPath,
        [string]$ProfileName = "Default",
        [string]$CometDir
    )

    # Determine User Data path
    $effectiveUserDataPath = $null
    if ($UserDataPath) {
        $effectiveUserDataPath = $UserDataPath
    }
    else {
        $systemPaths = @(
            (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data"),
            (Join-Path $env:LOCALAPPDATA "Comet\User Data")
        )
        foreach ($path in $systemPaths) {
            if (Test-Path $path) {
                $effectiveUserDataPath = $path
                break
            }
        }
        if (-not $effectiveUserDataPath) {
            $effectiveUserDataPath = $systemPaths[0]
        }
    }

    $profilePath = Join-Path $effectiveUserDataPath $ProfileName
    $securePrefsPath = Join-Path $profilePath "Secure Preferences"
    $localStatePath = Join-Path $effectiveUserDataPath "Local State"
    $firstRunPath = Join-Path $effectiveUserDataPath "First Run"

    if ($WhatIfPreference) {
        Write-Status "Would write Secure Preferences at: $securePrefsPath" -Type DryRun
        return $true
    }

    # If Secure Preferences exists AND Local State exists, update tracked preferences
    # Uses dual MAC synchronization: Secure Preferences file + Windows Registry
    # Both stores use DIFFERENT HMAC seeds:
    #   - File: 64-byte seed from resources.pak (NOT os_crypt.encrypted_key!)
    #   - Registry: Literal ASCII string "ChromeRegistryHashStoreValidationSeed"
    if ((Test-Path $securePrefsPath) -and (Test-Path $localStatePath)) {
        Write-VerboseTimestamped "[Secure Prefs] Existing profile found - updating tracked prefs with dual MAC sync"
        $result = Update-TrackedPreferences -SecurePrefsPath $securePrefsPath -LocalStatePath $localStatePath -CometDir $CometDir
        return $result
    }

    # First run - create tracked preferences with valid MACs
    # Comet (non-Chrome branded) uses EMPTY seed for file MACs, so we can calculate them now
    New-DirectoryIfNotExists -Path $effectiveUserDataPath
    New-DirectoryIfNotExists -Path $profilePath

    Write-VerboseTimestamped "[Secure Prefs] First run - creating tracked preferences with valid MACs"

    # Get device ID for MAC calculation
    $deviceId = Get-WindowsSidWithoutRid
    if (-not $deviceId) {
        Write-Status "Failed to get device ID for MAC calculation" -Type Warning
        return $false
    }
    Write-VerboseTimestamped "[Secure Prefs] Device ID: $deviceId"

    # Comet uses empty seed for file MACs (non-Chrome branded build)
    $seedHex = ""

    # Extension IDs for incognito and pinning
    $uBlockId = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
    $adGuardExtraId = "gkeojjjcdcopjkbelgbcpckplegclfeg"

    # ============================================================================
    # TRACKED PREFERENCES (Secure Preferences with MAC)
    # These are protected by Chromium's MAC system and require valid HMACs
    # Verified against services/preferences/tracked/ in Chromium source
    # ============================================================================
    $trackedPrefs = @{
        "extensions.ui.developer_mode"    = $true
        "browser.show_home_button"        = $true
        "bookmark_bar.show_apps_shortcut" = $false
        "safebrowsing.enabled"            = $false  # TRACKED - requires MAC
    }

    # ============================================================================
    # PROFILE PREFERENCES (Regular Preferences file, no MAC)
    # Registered via RegisterProfilePrefs() - go in profile's Preferences file
    # Verified against chrome/browser/prefs/ and component registrations
    # ============================================================================
    $profilePrefs = @{
        # Hyperlink auditing (click tracking)
        "enable_a_ping" = $false

        # DevTools
        "devtools.availability" = 1      # 1 = always available
        "devtools.gen_ai_settings" = 1   # 1 = disallow Gen AI features

        # AI & Lens Features (disable Google AI integrations)
        "browser.gemini_settings"           = 1      # 1 = disabled
        "glic.actuation_on_web"             = 1      # 1 = disabled (Gemini web actions)
        "lens.policy.lens_overlay_settings" = 1      # 1 = disabled
        "omnibox.ai_mode_settings"          = 1      # 1 = disabled

        # Network
        "net.quic_allowed" = $false

        # Safe Browsing (untracked prefs - safebrowsing.enabled is tracked above)
        "safebrowsing.enhanced" = $false
        "safebrowsing.password_protection_warning_trigger" = 0  # 0 = disabled
        "safebrowsing.scout_reporting_enabled" = $false

        # Privacy - URL & Search
        "omnibox.prevent_url_elisions" = $true   # Full URLs in address bar
        "search.suggest_enabled" = $false
        "url_keyed_anonymized_data_collection.enabled" = $false  # Fixed path (was unified_consent.*)

        # User Feedback
        "feedback_allowed" = $false

        # MV2 Extension Support (PrefScope::kProfile in extensions/browser/pref_types.cc)
        "mv2_deprecation_warning_ack_globally" = $true

        # NTP Modules - disable all modules via policy-controlled pref
        # This replaces --disable-features=NtpDriveModuleHistorySyncRequirement
        "NewTabPage.ModulesVisible" = $false
    }

    # ============================================================================
    # LOCAL STATE PREFERENCES (Local State file, no MAC)
    # Registered via RegisterLocalStatePrefs() or policy prefs - machine-wide
    # Verified against chrome/browser/prefs/ and component registrations
    # ============================================================================
    $localStatePrefs = @{
        # Policy-controlled prefs
        "policy.lens_desktop_ntp_search_enabled" = $false
        "policy.lens_region_search_enabled"      = $false
        "browser.default_browser_setting_enabled" = $false
        "domain_reliability.allowed_by_policy"   = $false

        # Background mode (BackgroundModeManager::RegisterPrefs uses PrefRegistrySimple)
        "background_mode.enabled" = $false

        # Disable browser promotions
        "browser.promotions_enabled" = $false

        # NOTE: perplexity.feature.* browser flags are set in Update-TrackedPreferences
        # with full object structure including "user_controlled" metadata.

        # Tracking protection
        "tracking_protection.ip_protection_enabled" = $false

        # Updates & Variations
        "update.component_updates_enabled" = $false
        "variations.restrictions_by_policy" = 2  # 2 = VariationsDisabled

        # ServiceWorker
        "worker.service_worker_auto_preload_enabled" = $true
    }

    # Extension settings with incognito enabled (split MACs)
    # These are tracked under extensions.settings.{extId} with split MAC structure
    $extensionSettings = @{
        $uBlockId = @{
            incognito = $true
            # Acknowledge MV2 deprecation warning (reason 4 = user acknowledged)
            # This prevents the Safety Hub from flagging uBlock as requiring action
            ack_safety_check_warning_reason = 4
        }
        $adGuardExtraId = @{
            incognito = $true
            ack_safety_check_warning_reason = 4
        }
    }

    # Untracked preferences (no MAC needed)
    $untrackedPrefs = @{
        sync       = @{
            managed = $true
        }
        perplexity = @{
            onboarding_completed = $true
            metrics_allowed      = $false
        }
    }

    # Extensions to pin to toolbar (for Regular Preferences)
    $extensionsToPinToToolbar = @($uBlockId)

    # Build the Secure Preferences structure
    $securePrefs = $untrackedPrefs.Clone()

    # Add tracked preferences to the structure (these need MACs)
    foreach ($path in $trackedPrefs.Keys) {
        Set-NestedValue -Hashtable $securePrefs -Path $path -Value $trackedPrefs[$path]
        Write-VerboseTimestamped "[Secure Prefs] Added tracked pref: $path = $($trackedPrefs[$path])"
    }

    # NOTE: Profile prefs ($profilePrefs) go to Regular Preferences file, not here
    # NOTE: Local State prefs ($localStatePrefs) go to Local State file, not here

    # Add extension settings to the structure
    if (-not $securePrefs.ContainsKey('extensions')) {
        $securePrefs['extensions'] = @{}
    }
    if (-not $securePrefs['extensions'].ContainsKey('settings')) {
        $securePrefs['extensions']['settings'] = @{}
    }
    foreach ($extId in $extensionSettings.Keys) {
        $securePrefs['extensions']['settings'][$extId] = $extensionSettings[$extId]
        Write-VerboseTimestamped "[Secure Prefs] Added extension settings for $extId"
    }

    # Calculate MACs for tracked preferences (atomic MACs)
    $macs = @{}
    foreach ($path in $trackedPrefs.Keys) {
        $value = $trackedPrefs[$path]
        $mac = Get-PreferenceHmac -SeedHex $seedHex -DeviceId $deviceId -Path $path -Value $value
        Set-NestedValue -Hashtable $macs -Path $path -Value $mac
        Write-VerboseTimestamped "[Secure Prefs] Calculated MAC for $path = $($mac.Substring(0, 16))..."
    }

    # Calculate MACs for extension settings (split MACs)
    # These are stored under extensions.settings.{extId} in the macs structure
    if (-not $macs.ContainsKey('extensions')) {
        $macs['extensions'] = @{}
    }
    if (-not $macs['extensions'].ContainsKey('settings')) {
        $macs['extensions']['settings'] = @{}
    }
    foreach ($extId in $extensionSettings.Keys) {
        $extSettings = $extensionSettings[$extId]
        $path = "extensions.settings.$extId"
        $mac = Get-PreferenceHmac -SeedHex $seedHex -DeviceId $deviceId -Path $path -Value $extSettings
        $macs['extensions']['settings'][$extId] = $mac
        Write-VerboseTimestamped "[Secure Prefs] Calculated split MAC for $path = $($mac.Substring(0, 16))..."

        # Also add to trackedPrefs for registry MAC calculation
        $trackedPrefs[$path] = $extSettings
    }

    # Calculate super_mac
    $superMac = Get-SuperMac -SeedHex $seedHex -DeviceId $deviceId -MacsTree $macs
    Write-VerboseTimestamped "[Secure Prefs] Calculated super_mac = $($superMac.Substring(0, 16))..."

    # Add protection structure
    $securePrefs['protection'] = @{
        macs      = $macs
        super_mac = $superMac
    }

    try {
        # Create First Run sentinel
        if (-not (Test-Path $firstRunPath)) {
            $null = New-Item -ItemType File -Path $firstRunPath -Force
        }

        # Write Secure Preferences (Save-JsonFile uses -InputObject to avoid PS 5.1 serialization bugs)
        Save-JsonFile -Path $securePrefsPath -Object $securePrefs -Compress
        Write-VerboseTimestamped "[Secure Prefs] Wrote Secure Preferences to: $securePrefsPath"

        # Write Regular Preferences (profile prefs registered via RegisterProfilePrefs - not tracked by MAC)
        $regularPrefsPath = Join-Path $profilePath "Preferences"
        $regularPrefsToWrite = $profilePrefs.Clone()
        $regularPrefsToWrite['extensions'] = @{
            pinned_extensions = $extensionsToPinToToolbar
        }

        # Add Safety Hub notifications (prevents prompts about extensions/passwords/safe-browsing)
        # Generate current timestamp in Windows FileTime format (100-nanosecond intervals since 1601-01-01)
        $currentFileTime = [DateTime]::UtcNow.ToFileTimeUtc().ToString()
        $regularPrefsToWrite['profile'] = @{
            safety_hub_menu_notifications = @{
                extensions = @{
                    isCurrentlyActive = $false
                    result = @{
                        timestamp = $currentFileTime
                        triggeringExtensions = @()
                    }
                }
                passwords = @{
                    isCurrentlyActive = $false
                    result = @{
                        passwordCheckOrigins = @()
                        timestamp = $currentFileTime
                    }
                }
                "safe-browsing" = @{
                    isCurrentlyActive = $false
                    onlyShowAfterTime = $currentFileTime
                    result = @{
                        safeBrowsingStatus = 1
                        timestamp = $currentFileTime
                    }
                }
                "unused-site-permissions" = @{
                    isCurrentlyActive = $false
                    result = @{
                        permissions = @()
                        timestamp = $currentFileTime
                    }
                }
            }
            content_settings = @{
                exceptions = @{
                    # chrome://extensions/ site engagement - allows extension management page access
                    site_engagement = @{
                        "chrome://extensions/,*" = @{
                            last_modified = $currentFileTime
                            setting = @{
                                lastEngagementTime = [double]$currentFileTime
                                lastShortcutLaunchTime = 0.0
                                pointsAddedToday = 3.0
                                rawScore = 3.0
                            }
                        }
                    }
                }
            }
        }

        Save-JsonFile -Path $regularPrefsPath -Object $regularPrefsToWrite -Compress
        Write-VerboseTimestamped "[Regular Prefs] Wrote $($profilePrefs.Count) profile prefs + pinned extensions + safety_hub to: $regularPrefsPath"

        # Write Local State with enabled_labs_experiments AND local state prefs
        $configPath = Join-Path $PSScriptRoot "config.json"
        $config = Get-MeteorConfig -ConfigPath $configPath
        $experiments = Build-EnabledLabsExperiments -Config $config
        $localStateResult = Write-LocalState -LocalStatePath $localStatePath -Experiments $experiments -AdditionalPrefs $localStatePrefs
        if ($localStateResult) {
            Write-VerboseTimestamped "[Local State] Local State written with $($experiments.Count) experiments + $($localStatePrefs.Count) prefs"
        }
        else {
            Write-VerboseTimestamped "[Local State] WARNING: Failed to write Local State"
        }

        # Set registry MACs (uses different seed: "ChromeRegistryHashStoreValidationSeed")
        $registryResult = Set-RegistryPreferenceMacs -DeviceId $deviceId -PreferencesToSet $trackedPrefs
        if ($registryResult) {
            Write-VerboseTimestamped "[Registry MAC] Registry MACs set successfully"
        }
        else {
            Write-VerboseTimestamped "[Registry MAC] WARNING: Failed to set registry MACs"
        }

        Write-Status "First-run preferences with tracked prefs, extension settings, and pinning written successfully" -Type Success
        return $true
    }
    catch {
        Write-Status "Failed to write Secure Preferences: $_" -Type Warning
        return $false
    }
}

function Update-TrackedPreferences {
    <#
    .SYNOPSIS
        Modify tracked preferences in existing Secure Preferences file.
    .DESCRIPTION
        Uses the 64-byte HMAC seed from resources.pak to calculate valid HMACs for
        tracked preferences. This seed is embedded in the browser binary and is
        different from os_crypt.encrypted_key (which is for cookie encryption).

        Reference: https://www.adlice.com/google-chrome-secure-preferences/
    #>
    param(
        [string]$SecurePrefsPath,
        [string]$LocalStatePath,
        [string]$CometDir
    )

    try {
        # Read existing files
        Write-VerboseTimestamped "[Secure Prefs] Reading Local State from: $LocalStatePath"
        Write-VerboseTimestamped "[Secure Prefs] Reading Secure Prefs from: $SecurePrefsPath"

        $localStateJson = Get-Content -Path $LocalStatePath -Raw -ErrorAction Stop
        $localState = $localStateJson | ConvertFrom-Json -ErrorAction Stop

        # Debug: Show Local State structure
        $localStateKeys = $localState.PSObject.Properties.Name -join ", "
        Write-VerboseTimestamped "[Secure Prefs] Local State keys: $localStateKeys"

        $securePrefsJson = Get-Content -Path $SecurePrefsPath -Raw -ErrorAction Stop
        $securePrefs = $securePrefsJson | ConvertFrom-Json -ErrorAction Stop

        # Also load regular Preferences file - many tracked prefs are stored here
        # (session.*, homepage, google.services.*, etc.)
        $regularPrefsPath = Join-Path (Split-Path $SecurePrefsPath -Parent) "Preferences"
        $regularPrefsHash = $null
        if (Test-Path $regularPrefsPath) {
            Write-VerboseTimestamped "[Secure Prefs] Reading Regular Prefs from: $regularPrefsPath"
            $regularPrefsJson = Get-Content -Path $regularPrefsPath -Raw -ErrorAction SilentlyContinue
            if ($regularPrefsJson) {
                $regularPrefs = $regularPrefsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($regularPrefs) {
                    $regularPrefsHash = Convert-PSObjectToHashtable -InputObject $regularPrefs
                    Write-VerboseTimestamped "[Secure Prefs] Regular Prefs loaded ($($regularPrefsHash.Keys.Count) top-level keys)"
                }
            }
        }
        else {
            Write-VerboseTimestamped "[Secure Prefs] Regular Preferences file not found at: $regularPrefsPath"
        }

        # Debug: Show raw JSON structure to understand what Comet stores
        Write-VerboseTimestamped "[Secure Prefs] Raw Secure Preferences file length: $($securePrefsJson.Length) chars"
        # Check if 'protection' exists in raw JSON
        if ($securePrefsJson -match '"protection"') {
            Write-VerboseTimestamped "[Secure Prefs] Raw JSON CONTAINS 'protection' key"
            # Extract a sample of the protection section
            if ($securePrefsJson -match '"protection"\s*:\s*\{[^}]{0,200}') {
                Write-VerboseTimestamped "[Secure Prefs] Protection section sample: $($Matches[0])..."
            }
        } else {
            Write-VerboseTimestamped "[Secure Prefs] Raw JSON does NOT contain 'protection' key!"
            # Show first 500 chars of the file to see its structure
            $preview = $securePrefsJson.Substring(0, [Math]::Min(500, $securePrefsJson.Length))
            Write-VerboseTimestamped "[Secure Prefs] JSON preview: $preview"
        }

        # Get HMAC seed for file MAC calculation
        # For Google Chrome: 64-byte seed from IDR_PREF_HASH_SEED_BIN in resources.pak
        # For Comet (non-Chrome): Empty string (per Chromium source - GOOGLE_CHROME_BRANDING guard)
        $pakSeed = Get-PreferenceHmacSeedFromPak -CometDir $CometDir
        if (-not $pakSeed) {
            Write-VerboseTimestamped "[Secure Prefs] Failed to get HMAC seed"
            return $false
        }

        $seedHex = $pakSeed.seedHex
        if ($seedHex -eq "") {
            Write-VerboseTimestamped "[Secure Prefs] Using empty seed (non-Chrome branded build)"
        } else {
            Write-VerboseTimestamped "[Secure Prefs] Extracted 64-byte seed from PAK resource ID $($pakSeed.resourceId)"
            Write-VerboseTimestamped "[Secure Prefs] Seed: $($seedHex.Substring(0, 32))..."
        }

        # Get device ID (Windows SID without RID)
        $rawSid = Get-WindowsSidWithoutRid
        $deviceId = Get-ChromiumDeviceId -RawMachineId $rawSid

        Write-VerboseTimestamped "[Secure Prefs] Device ID (raw SID): $deviceId"

        # Debug: Check original securePrefs BEFORE conversion
        Write-VerboseTimestamped "[Secure Prefs] Original securePrefs type: $($securePrefs.GetType().FullName)"
        $origProps = $securePrefs.PSObject.Properties.Name -join ", "
        Write-VerboseTimestamped "[Secure Prefs] Original securePrefs properties: $origProps"
        if ($securePrefs.PSObject.Properties.Name -contains 'protection') {
            Write-VerboseTimestamped "[Secure Prefs] Original HAS 'protection' property!"
        } else {
            Write-VerboseTimestamped "[Secure Prefs] Original MISSING 'protection' property!"
        }

        # Convert to hashtable for modification
        $securePrefsHash = Convert-PSObjectToHashtable -InputObject $securePrefs

        # Debug: Check AFTER conversion
        $hashKeys = $securePrefsHash.Keys -join ", "
        Write-VerboseTimestamped "[Secure Prefs] After conversion - hashtable keys: $hashKeys"

        # ============================================================================
        # TRACKED PREFERENCES (need MAC recalculation)
        # Verified against services/preferences/tracked/ in Chromium source
        # ============================================================================
        $trackedPrefsToModify = @{
            "extensions.ui.developer_mode"    = $true
            "browser.show_home_button"        = $true
            "bookmark_bar.show_apps_shortcut" = $false
            "safebrowsing.enabled"            = $false  # TRACKED - requires MAC
        }

        # ============================================================================
        # PROFILE PREFERENCES (go to Regular Preferences file, no MAC)
        # ============================================================================
        $profilePrefsToModify = @{
            "enable_a_ping" = $false
            "devtools.availability" = 1
            "devtools.gen_ai_settings" = 1
            "browser.gemini_settings" = 1
            "glic.actuation_on_web" = 1
            "lens.policy.lens_overlay_settings" = 1
            "omnibox.ai_mode_settings" = 1
            "net.quic_allowed" = $false
            "safebrowsing.enhanced" = $false
            "safebrowsing.password_protection_warning_trigger" = 0
            "safebrowsing.scout_reporting_enabled" = $false
            "omnibox.prevent_url_elisions" = $true
            "search.suggest_enabled" = $false
            "url_keyed_anonymized_data_collection.enabled" = $false
            "feedback_allowed" = $false
            "mv2_deprecation_warning_ack_globally" = $true
            "browser.default_browser_setting_enabled" = $false
            # Perplexity-specific privacy preferences
            "perplexity.adblock.enabled" = $false
            "perplexity.help_me_with_text.enabled" = $false
            "perplexity.history_search_enabled" = $false
            "perplexity.notifications.proactive_assistance.enabled" = $false
            "perplexity.proactive_scraping.enabled" = $false
            "perplexity.analytics_observer_initialised" = $false
            # NTP Modules - disable all modules via policy-controlled pref
            # This replaces --disable-features=NtpDriveModuleHistorySyncRequirement
            "NewTabPage.ModulesVisible" = $false
        }

        # ============================================================================
        # LOCAL STATE PREFERENCES (go to Local State file, no MAC)
        # ============================================================================
        $localStatePrefsToModify = @{
            "policy.lens_desktop_ntp_search_enabled" = $false
            "policy.lens_region_search_enabled" = $false
            # Privacy/telemetry preferences (verified in example_data/Local State)
            "breadcrumbs.enabled" = $false
            "background_mode.enabled" = $false
            "browser.promotions_enabled" = $false
            "domain_reliability.allowed_by_policy" = $false
            "tracking_protection.ip_protection_enabled" = $false
            "update.component_updates_enabled" = $false
            "variations.restrictions_by_policy" = 2
            "worker.service_worker_auto_preload_enabled" = $true
        }

        # Perplexity browser feature flags (require full object structure with metadata)
        # These are under perplexity.feature.{name} and need "user_controlled" to take effect
        $perplexityFeatureFlags = @{
            # CRITICAL: Force extension to use JS SDK instead of browser's native API
            # When true, extension delegates to chrome.perplexity.features (browser C++)
            # When false, extension uses bundled Eppo SDK and reads our eppo_overrides
            "test-migration-feature" = $false

            # Privacy/Telemetry (DISABLE)
            "nav-logging" = $false
            "zero-suggests-enabled" = $false
            "native-analytics" = $false
            "enable-enterprise-telemetry" = $false
            "enable-sync" = $false
            "inactive-tab-notifications" = $false

            # Auto-update (DISABLE - we control updates)
            "native-autoupdate" = $false
            "omaha-autoupdater" = $false

            # AI Assistant (ENABLE)
            "auto-assist-notification-settings" = $true
            "auto-assist-scraping-settings" = $true
            "always-allow-browser-agent-settings" = $true
            "voice-assistant" = $true

            # MCP/DXT (ENABLE)
            "enable-dxt" = $true
            "enable-local-mcp" = $true
            "enable-local-custom-mcp" = $true

            # Preloading (ENABLE)
            "prerender2-comet" = $true
            "enable-preloaded-ntp" = $true
            "use-preloaded-ntp-from-omnibox" = $true

            # Bundled resources (ENABLE)
            "bundled-comet-web-resources-3" = $true

            # Privacy restrictions (ENABLE)
            "disable-local-discovery" = $true
            "omnibox-resedign-disable-promo-suggestions" = $true

            # Partner/promo (DISABLE)
            "nordvpn-partner-extension-enabled" = $false
            "whats-new-show-in-menu" = $false
            "nudge-sync-tab-groups" = $false
        }

        # Convert feature flags to full object structure with metadata
        $featureFlagMetadata = @("user_controlled", "user_modifiable", "extension_modifiable")
        foreach ($flagName in $perplexityFeatureFlags.Keys) {
            $flagValue = $perplexityFeatureFlags[$flagName]
            $localStatePrefsToModify["perplexity.feature.$flagName"] = @{
                metadata = $featureFlagMetadata
                value = $flagValue
            }
        }

        # Inject our own Eppo config blob with desired feature flags
        # The browser loads this blob on startup BEFORE content scripts run, so we must
        # inject our values directly rather than relying on fetch interception.
        # Flags not in the blob fall back to browser defaults (e.g., nav-logging defaults to true).
        $eppoConfigBlob = New-EppoConfigBlob -FeatureFlags $perplexityFeatureFlags
        Write-VerboseTimestamped "[Local State] Generated Eppo config blob ($($eppoConfigBlob.Length) chars)"
        $localStatePrefsToModify["perplexity.features"] = @{
            metadata = @("user_controlled", "user_modifiable", "extension_modifiable")
            value = $eppoConfigBlob
        }

        # Set tracked preferences in Secure Preferences (these need MACs)
        foreach ($path in $trackedPrefsToModify.Keys) {
            Set-NestedValue -Hashtable $securePrefsHash -Path $path -Value $trackedPrefsToModify[$path]
            Write-VerboseTimestamped "[Secure Prefs] Set tracked pref: $path = $($trackedPrefsToModify[$path])"
        }

        # Enable incognito access and acknowledge MV2 warning for uBlock Origin and AdGuard Extra
        # These settings are in extensions.settings.{id} and ARE tracked with SPLIT MAC
        # The MAC will be recalculated automatically since we recalculate all extension MACs
        $extensionsToModify = @(
            "cjpalhdlnbpafiamejdnhcphjbkeiagm",  # uBlock Origin
            "gkeojjjcdcopjkbelgbcpckplegclfeg"   # AdGuard Extra
        )
        if ($securePrefsHash.ContainsKey('extensions') -and $securePrefsHash['extensions'].ContainsKey('settings')) {
            $extSettings = $securePrefsHash['extensions']['settings']
            foreach ($extId in $extensionsToModify) {
                if ($extSettings.ContainsKey($extId)) {
                    $extSettings[$extId]['incognito'] = $true
                    # Acknowledge MV2 deprecation warning (reason 4 = user acknowledged)
                    # This prevents the Safety Hub from flagging extension as requiring action
                    $extSettings[$extId]['ack_safety_check_warning_reason'] = 4
                    Write-VerboseTimestamped "[Secure Prefs] Set incognito + ack_safety_check for extension $extId"
                }
            }
        }

        # Update Regular Preferences (untracked profile prefs and pinned extensions)
        # These settings are NOT tracked by MAC system
        if ($null -ne $regularPrefsHash) {
            # Set all profile preferences (registered via RegisterProfilePrefs, not tracked)
            foreach ($path in $profilePrefsToModify.Keys) {
                Set-NestedValue -Hashtable $regularPrefsHash -Path $path -Value $profilePrefsToModify[$path]
                Write-VerboseTimestamped "[Regular Prefs] Set profile pref: $path = $($profilePrefsToModify[$path])"
            }

            # Pin uBlock Origin to toolbar
            $extensionsToPinToToolbar = @(
                "cjpalhdlnbpafiamejdnhcphjbkeiagm"   # uBlock Origin
            )
            if (-not $regularPrefsHash.ContainsKey('extensions')) {
                $regularPrefsHash['extensions'] = @{}
            }
            # Get existing pinned extensions or create new list
            $existingPinned = @()
            if ($regularPrefsHash['extensions'].ContainsKey('pinned_extensions')) {
                $existingPinned = @($regularPrefsHash['extensions']['pinned_extensions'])
            }
            # Add our extensions if not already pinned
            foreach ($extId in $extensionsToPinToToolbar) {
                if ($existingPinned -notcontains $extId) {
                    $existingPinned += $extId
                }
            }
            $regularPrefsHash['extensions']['pinned_extensions'] = $existingPinned
            Write-VerboseTimestamped "[Regular Prefs] Pinned extensions to toolbar: $($existingPinned -join ', ')"

            # Add Safety Hub notifications (prevents prompts about extensions/passwords/safe-browsing)
            # Generate current timestamp in Windows FileTime format (100-nanosecond intervals since 1601-01-01)
            $currentFileTime = [DateTime]::UtcNow.ToFileTimeUtc().ToString()

            # Ensure profile key exists
            if (-not $regularPrefsHash.ContainsKey('profile')) {
                $regularPrefsHash['profile'] = @{}
            }

            # Add safety_hub_menu_notifications
            $regularPrefsHash['profile']['safety_hub_menu_notifications'] = @{
                extensions = @{
                    isCurrentlyActive = $false
                    result = @{
                        timestamp = $currentFileTime
                        triggeringExtensions = @()
                    }
                }
                passwords = @{
                    isCurrentlyActive = $false
                    result = @{
                        passwordCheckOrigins = @()
                        timestamp = $currentFileTime
                    }
                }
                "safe-browsing" = @{
                    isCurrentlyActive = $false
                    onlyShowAfterTime = $currentFileTime
                    result = @{
                        safeBrowsingStatus = 1
                        timestamp = $currentFileTime
                    }
                }
                "unused-site-permissions" = @{
                    isCurrentlyActive = $false
                    result = @{
                        permissions = @()
                        timestamp = $currentFileTime
                    }
                }
            }
            Write-VerboseTimestamped "[Regular Prefs] Set safety_hub_menu_notifications"

            # Add chrome://extensions/ site engagement
            if (-not $regularPrefsHash['profile'].ContainsKey('content_settings')) {
                $regularPrefsHash['profile']['content_settings'] = @{}
            }
            if (-not $regularPrefsHash['profile']['content_settings'].ContainsKey('exceptions')) {
                $regularPrefsHash['profile']['content_settings']['exceptions'] = @{}
            }
            if (-not $regularPrefsHash['profile']['content_settings']['exceptions'].ContainsKey('site_engagement')) {
                $regularPrefsHash['profile']['content_settings']['exceptions']['site_engagement'] = @{}
            }
            $regularPrefsHash['profile']['content_settings']['exceptions']['site_engagement']['chrome://extensions/,*'] = @{
                last_modified = $currentFileTime
                setting = @{
                    lastEngagementTime = [double]$currentFileTime
                    lastShortcutLaunchTime = 0.0
                    pointsAddedToday = 3.0
                    rawScore = 3.0
                }
            }
            Write-VerboseTimestamped "[Regular Prefs] Set chrome://extensions/ site engagement"

            # Write updated Regular Preferences (Save-JsonFile uses -InputObject to avoid PS 5.1 bugs)
            Save-JsonFile -Path $regularPrefsPath -Object $regularPrefsHash -Compress
            Write-VerboseTimestamped "[Regular Prefs] Updated Regular Preferences file"
        }

        # Update Local State (machine-wide/policy prefs)
        # These are NOT profile-specific and go in the User Data root
        if ($localStatePrefsToModify.Count -gt 0) {
            Write-VerboseTimestamped "[Local State] Updating Local State with $($localStatePrefsToModify.Count) prefs"
            $localStateHash = Convert-PSObjectToHashtable -InputObject $localState

            foreach ($path in $localStatePrefsToModify.Keys) {
                Set-NestedValue -Hashtable $localStateHash -Path $path -Value $localStatePrefsToModify[$path]
                Write-VerboseTimestamped "[Local State] Set pref: $path = $($localStatePrefsToModify[$path])"
            }

            # Write updated Local State
            Save-JsonFile -Path $LocalStatePath -Object $localStateHash -Compress
            Write-VerboseTimestamped "[Local State] Updated Local State file"
        }

        # Get existing MACs structure - debug what we have BEFORE any modification
        Write-VerboseTimestamped "[Secure Prefs] securePrefsHash has 'protection' key: $($securePrefsHash.ContainsKey('protection'))"
        if ($securePrefsHash.ContainsKey('protection')) {
            $prot = $securePrefsHash['protection']
            Write-VerboseTimestamped "[Secure Prefs] protection type: $($prot.GetType().FullName)"
            if ($prot -is [hashtable]) {
                $protKeys = $prot.Keys -join ", "
                Write-VerboseTimestamped "[Secure Prefs] protection keys: $protKeys"
                if ($prot.ContainsKey('macs')) {
                    $macsObj = $prot['macs']
                    Write-VerboseTimestamped "[Secure Prefs] macs type: $($macsObj.GetType().FullName)"
                    if ($macsObj -is [hashtable]) {
                        $macsKeys = $macsObj.Keys -join ", "
                        Write-VerboseTimestamped "[Secure Prefs] macs keys: $macsKeys"
                    }
                }
            }
        }

        # Only create structures if they don't exist - DON'T replace existing ones
        if (-not $securePrefsHash.ContainsKey('protection')) {
            Write-VerboseTimestamped "[Secure Prefs] Creating new protection structure"
            $securePrefsHash['protection'] = @{ macs = @{} }
        }
        if (-not ($securePrefsHash['protection'] -is [hashtable])) {
            Write-VerboseTimestamped "[Secure Prefs] ERROR: protection is not a hashtable after conversion!"
            return $false
        }
        if (-not $securePrefsHash['protection'].ContainsKey('macs')) {
            Write-VerboseTimestamped "[Secure Prefs] Creating new macs structure (this will LOSE existing MACs!)"
            $securePrefsHash['protection']['macs'] = @{}
        }

        $macs = $securePrefsHash['protection']['macs']

        # Debug: Show existing MAC structure after getting reference
        $existingMacKeys = $macs.Keys -join ", "
        Write-VerboseTimestamped "[Secure Prefs] After getting macs - top-level keys: $existingMacKeys"

        # Flatten existing MACs first to count them
        $existingMacs = @{}
        Get-FlattenedMacs -Node $macs -Path "" -Result $existingMacs
        Write-VerboseTimestamped "[Secure Prefs] Found $($existingMacs.Count) existing MACs before modification"

        # CRITICAL: Recalculate ALL existing MACs, not just our target preferences
        # The JSON round-trip through PowerShell (ConvertFrom-Json → ConvertTo-Json) may
        # change the serialization of values we didn't modify (unicode escaping, key order,
        # empty container handling, etc.). If we only update MACs for modified paths, the
        # browser will detect that other values changed but their MACs didn't, triggering
        # "tracked_preferences_reset".
        #
        # Our JSON serialization includes empty container pruning to match Chromium's
        # PrefHashCalculator behavior.
        $updateResult = Update-AllMacs -Macs $macs -SecurePreferences $securePrefsHash -RegularPreferences $regularPrefsHash -SeedHex $seedHex -DeviceId $deviceId -SecurePrefsRawJson $securePrefsJson

        Write-VerboseTimestamped "[Secure Prefs] Recalculated $($updateResult.recalculated) MACs, removed $($updateResult.removed) orphaned MACs"

        # Log our specific target preferences
        foreach ($path in $trackedPrefsToModify.Keys) {
            $value = $trackedPrefsToModify[$path]
            Write-VerboseTimestamped "[Secure Prefs] Target pref: $path = $(ConvertTo-JsonForHmac $value)"
        }

        # Check for account_values (signed-in users)
        $hasAccountValues = $macs.ContainsKey('account_values')
        if ($hasAccountValues) {
            Write-VerboseTimestamped "[Secure Prefs] Found account_values section - MACs were included in recalculation"
        }

        # Flatten MACs to count them (for logging only)
        $allMacs = @{}
        Get-FlattenedMacs -Node $macs -Path "" -Result $allMacs

        # Calculate new super_mac using the NESTED macs structure
        # Chromium formula: HMAC-SHA256(seed, device_id + "" + json(macs_dict))
        $superMac = Get-SuperMac -SeedHex $seedHex -DeviceId $deviceId -MacsTree $macs
        $securePrefsHash['protection']['super_mac'] = $superMac

        Write-VerboseTimestamped "[Secure Prefs] Calculated super_mac from $($allMacs.Count) MACs: $($superMac.Substring(0, 16))..."

        # CRITICAL: Clear prefs.tracked_preferences_reset if it exists
        # When browser detects invalid MACs, it populates this array with reset preference names
        # If this array is non-empty, subsequent runs may crash
        # NOTE: Chromium may write this as a TOP-LEVEL key with literal dot in name,
        # or nested under 'prefs' section - check both locations

        # Check for top-level key with literal dot in name (e.g., "prefs.tracked_preferences_reset")
        if ($securePrefsHash.ContainsKey('prefs.tracked_preferences_reset')) {
            Write-VerboseTimestamped "[Secure Prefs] Removing top-level 'prefs.tracked_preferences_reset' key"
            $securePrefsHash.Remove('prefs.tracked_preferences_reset')
        }

        # Also check nested under 'prefs' section
        if ($securePrefsHash.ContainsKey('prefs')) {
            $prefsSection = $securePrefsHash['prefs']
            if ($prefsSection -is [hashtable] -and $prefsSection.ContainsKey('tracked_preferences_reset')) {
                $resetArray = $prefsSection['tracked_preferences_reset']
                if ($resetArray -and $resetArray.Count -gt 0) {
                    Write-VerboseTimestamped "[Secure Prefs] Clearing nested tracked_preferences_reset array (had $($resetArray.Count) entries)"
                    $prefsSection['tracked_preferences_reset'] = @()
                }
            }
        }

        # CRITICAL: Restore empty arrays that PowerShell 5.1 converted to $null
        # The MACs were calculated using [] but the hashtable has $null. If we write $null,
        # the browser sees "pinned_tabs":null but MAC was calculated for [], triggering reset.
        if ($updateResult.emptyArrayPaths -and $updateResult.emptyArrayPaths.Count -gt 0) {
            Write-VerboseTimestamped "[Secure Prefs] Restoring $($updateResult.emptyArrayPaths.Count) empty arrays that PS 5.1 converted to null"
            foreach ($path in $updateResult.emptyArrayPaths.Keys) {
                # If the path exists and value is null, restore to empty array
                $existing = Get-NestedValue -Object $securePrefsHash -Path $path
                if ($existing.Found -and $null -eq $existing.Value) {
                    Set-NestedValue -Hashtable $securePrefsHash -Path $path -Value @()
                    Write-VerboseTimestamped "[Secure Prefs]   Restored: $path = []"
                }
            }
        }

        # Write modified Secure Preferences
        # Use -Compress for compact JSON (Chromium's format). Save-JsonFile uses -InputObject
        # to avoid PS 5.1 serialization bugs (piping causes arrays to serialize as {"Length":N})
        Save-JsonFile -Path $SecurePrefsPath -Object $securePrefsHash -Compress

        Write-VerboseTimestamped "[Secure Prefs] File updated successfully"

        # CRITICAL: Also update Windows Registry MACs for ALL recalculated paths
        # Comet stores duplicate MACs in registry using a DIFFERENT seed ("ChromeRegistryHashStoreValidationSeed")
        # If registry MACs don't match, browser detects tampering
        # We must update registry MACs for ALL preferences that have file MACs
        $registryPrefs = @{}
        foreach ($path in $updateResult.paths) {
            # Look up the value for this path - check both Secure and Regular Preferences
            # For account_values.*, value is stored IN the account_values dictionary
            # at the full nested path, NOT at the root level with stripped prefix
            $lookupPath = $path
            # NOTE: We use the full path for lookup since account_values is a dictionary
            # containing account-scoped preference values
            $lookupResult = Get-PreferenceValue -Preferences $securePrefsHash -Path $lookupPath
            if (-not $lookupResult.Found -and $null -ne $regularPrefsHash) {
                $lookupResult = Get-PreferenceValue -Preferences $regularPrefsHash -Path $lookupPath
            }

            # NOTE: For account_values.* paths when not signed in, browser expects NULL value
            # (not the local value). Do NOT fall back to local values.

            # CRITICAL: Set registry MAC for ALL paths, including those with null values
            # The file MAC was calculated (possibly with null), so registry MAC must match
            if ($lookupResult.Found) {
                $value = $lookupResult.Value
                # WORKAROUND: PowerShell 5.1 converts [] to $null
                # Check if raw JSON had [] for this path (detected during Update-AllMacs)
                # We can check by looking for "path":[] pattern in the raw JSON
                if ($null -eq $value -and $securePrefsJson -match ('"' + [regex]::Escape($path) + '"\s*:\s*\[\s*\]')) {
                    $value = @()
                }
                $registryPrefs[$path] = $value
            } else {
                # Preference not found - use null value to match file MAC calculation
                $registryPrefs[$path] = $null
            }
        }

        Write-VerboseTimestamped "[Registry MAC] Updating registry MACs for $($registryPrefs.Count) paths"

        $registryResult = Set-RegistryPreferenceMacs -DeviceId $deviceId -PreferencesToSet $registryPrefs
        if ($registryResult) {
            Write-VerboseTimestamped "[Registry MAC] Registry MACs synchronized successfully ($($registryPrefs.Count) entries)"
        }
        else {
            Write-VerboseTimestamped "[Registry MAC] WARNING: Failed to update registry MACs - browser may crash"
        }

        # Update Local State with enabled_labs_experiments
        $configPath = Join-Path $PSScriptRoot "config.json"
        $config = Get-MeteorConfig -ConfigPath $configPath
        $experiments = Build-EnabledLabsExperiments -Config $config
        $localStateResult = Update-LocalStateExperiments -LocalStatePath $LocalStatePath -NewExperiments $experiments
        if ($localStateResult) {
            Write-VerboseTimestamped "[Local State] Local State updated with $($experiments.Count) Meteor experiments"
        }
        else {
            Write-VerboseTimestamped "[Local State] WARNING: Failed to update Local State"
        }

        $removedInfo = if ($updateResult.removed -gt 0) { ", cleaned $($updateResult.removed) orphaned" } else { "" }
        Write-Status "Tracked preferences updated with valid HMACs (file: $($updateResult.recalculated), registry: $($registryPrefs.Count)$removedInfo)" -Type Success
        return $true
    }
    catch {
        Write-VerboseTimestamped "[Secure Prefs] Error updating tracked preferences: $_"
        return $false
    }
}

function Get-FlattenedMacs {
    <#
    .SYNOPSIS
        Recursively flatten nested MAC structure to path->MAC hashtable.
    #>
    param(
        [object]$Node,
        [string]$Path,
        [hashtable]$Result
    )

    if ($Node -is [string]) {
        # This is a MAC value
        $Result[$Path] = $Node
    }
    elseif ($Node -is [hashtable] -or $Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            $newPath = if ($Path) { "$Path.$key" } else { $key }
            Get-FlattenedMacs -Node $Node[$key] -Path $newPath -Result $Result
        }
    }
    elseif ($Node -is [PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            $newPath = if ($Path) { "$Path.$($prop.Name)" } else { $prop.Name }
            Get-FlattenedMacs -Node $prop.Value -Path $newPath -Result $Result
        }
    }
}

function Convert-PSObjectToHashtable {
    <#
    .SYNOPSIS
        Convert PSCustomObject trees to hashtable trees for manipulation in PowerShell 5.1.

    .DESCRIPTION
        PURPOSE: PSCustomObject manipulation - enables modifying objects from ConvertFrom-Json.
        ConvertFrom-Json returns PSCustomObjects which are read-only. This function converts
        them to hashtables which can be freely modified.

        DISTINCT FROM ConvertTo-SortedObject:
        - Convert-PSObjectToHashtable: Converts TYPE (PSCustomObject -> hashtable) for modification
        - ConvertTo-SortedObject: Transforms STRUCTURE (sorts keys, prunes empties) for serialization

        WHEN TO USE:
        - After ConvertFrom-Json when you need to modify the data
        - Before re-serializing modified JSON data
        - When working with nested config structures that need updates

        TYPE HANDLING:
        +-----------------+------------------------+
        | Input Type      | Output                 |
        +-----------------+------------------------+
        | null            | @{} (empty hashtable)  |
        | string          | string (unchanged)     |
        | bool            | bool (unchanged)       |
        | numbers         | number (unchanged)     |
        | hashtable       | hashtable (unchanged)  |
        | PSCustomObject  | hashtable (converted)  |
        | array           | array (items converted)|
        +-----------------+------------------------+

        PowerShell 5.1 COMPATIBILITY:
        - Problem: Arrays in pipelines cause serialization bugs (strings become {"Length":N})
        - Solution: Use explicit foreach loops, not pipelines, for array processing
        - Problem: Empty arrays unroll to $null when returned from functions
        - Solution: Use comma operator (return ,$result) to preserve array wrapper
        - Problem: Primitives must be detected BEFORE array check (strings are arrays in PS)
        - Solution: Check primitive types first in the if-else chain

    .PARAMETER InputObject
        The object to convert. Typically a PSCustomObject from ConvertFrom-Json.

    .OUTPUTS
        Returns hashtable for PSCustomObjects, or the input unchanged for primitives/hashtables.

    .EXAMPLE
        $json = '{"nested":{"key":"value"}}'
        $obj = ConvertFrom-Json $json
        $hash = Convert-PSObjectToHashtable -InputObject $obj
        $hash['nested']['key'] = 'modified'  # Now modifiable

    .NOTES
        This function does NOT sort keys or prune empty containers.
        Use ConvertTo-SortedObject after modification if preparing for MAC calculation.
    #>
    [OutputType([object])]
    param(
        [object]$InputObject
    )

    # Null returns empty hashtable (for root-level calls)
    if ($null -eq $InputObject) { return @{} }

    # Primitives - return as-is (MUST check these before array check!)
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [bool]) { return $InputObject }
    if ($InputObject -is [int] -or $InputObject -is [int32] -or $InputObject -is [int64] -or
        $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal] -or
        $InputObject -is [float] -or $InputObject -is [single]) {
        return $InputObject
    }

    # Hashtables - return as-is (already the right type)
    if ($InputObject -is [hashtable]) { return $InputObject }

    # Arrays - check if they need conversion
    if ($InputObject -is [array]) {
        # Check if array contains objects that need conversion
        $needsConversion = $false
        foreach ($item in $InputObject) {
            if ($null -ne $item) {
                if ($item -is [PSCustomObject] -or $item -is [hashtable]) {
                    $needsConversion = $true
                    break
                }
            }
        }

        if (-not $needsConversion) {
            # Array of primitives - return as-is
            # CRITICAL: Use comma operator to preserve array in PS 5.1
            return ,$InputObject
        }

        # Array contains objects - convert each element using explicit loop (not pipeline!)
        # Pipeline can cause weird serialization issues in PS 5.1
        $result = [System.Collections.ArrayList]::new()
        foreach ($item in $InputObject) {
            $converted = Convert-PSObjectToHashtable -InputObject $item
            $null = $result.Add($converted)
        }
        # CRITICAL: Use comma operator to preserve array in PS 5.1
        return ,$result.ToArray()
    }

    # PSCustomObject - convert to hashtable
    if ($InputObject -is [PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = Convert-PSObjectToHashtable -InputObject $prop.Value
        }
        return $hash
    }

    # Unknown type - return as-is
    return $InputObject
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

function Get-PreferenceValue {
    <#
    .SYNOPSIS
        Get a preference value from a nested hashtable using a dotted path.
    .DESCRIPTION
        Given a path like "extensions.ui.developer_mode", navigates the hashtable
        and returns a result object indicating whether the path was found and its value.

        IMPORTANT: This assumes dots are path separators. Keys containing literal
        dots will NOT be found correctly (e.g., "foo.bar" as a single key name).
    .OUTPUTS
        Hashtable with:
        - Found: $true if path exists (even if value is $null), $false if not found
        - Value: The value at the path (may be $null if the value is literally null)
    #>
    param(
        [hashtable]$Preferences,
        [string]$Path,
        [switch]$Trace
    )

    $parts = $Path -split '\.'
    $current = $Preferences
    $tracePath = ""

    for ($i = 0; $i -lt $parts.Count; $i++) {
        $part = $parts[$i]
        $isLast = ($i -eq $parts.Count - 1)
        $tracePath = if ($tracePath) { "$tracePath.$part" } else { $part }

        if ($null -eq $current) {
            if ($Trace) { Write-VerboseTimestamped "[GetPrefValue] FAIL at '$tracePath': current is null" }
            return @{ Found = $false; Value = $null }
        }
        if ($current -is [hashtable]) {
            if ($current.ContainsKey($part)) {
                $current = $current[$part]
                if ($Trace) { Write-VerboseTimestamped "[GetPrefValue] OK at '$tracePath': found in hashtable$(if ($isLast -and $null -eq $current) { ' (value is null)' })" }
            }
            else {
                if ($Trace) {
                    $availableKeys = ($current.Keys | Select-Object -First 5) -join ", "
                    Write-VerboseTimestamped "[GetPrefValue] FAIL at '$tracePath': key '$part' not in hashtable (available: $availableKeys...)"
                }
                return @{ Found = $false; Value = $null }
            }
        }
        elseif ($current -is [PSCustomObject]) {
            $prop = $current.PSObject.Properties[$part]
            if ($prop) {
                $current = $prop.Value
                if ($Trace) { Write-VerboseTimestamped "[GetPrefValue] OK at '$tracePath': found in PSCustomObject$(if ($isLast -and $null -eq $current) { ' (value is null)' })" }
            }
            else {
                if ($Trace) { Write-VerboseTimestamped "[GetPrefValue] FAIL at '$tracePath': property '$part' not in PSCustomObject" }
                return @{ Found = $false; Value = $null }
            }
        }
        else {
            if ($Trace) { Write-VerboseTimestamped "[GetPrefValue] FAIL at '$tracePath': current is $($current.GetType().Name), not traversable" }
            return @{ Found = $false; Value = $null }
        }
    }

    return @{ Found = $true; Value = $current }
}

function Update-ModifiedMacs {
    <#
    .SYNOPSIS
        Update MACs ONLY for specific paths that Meteor modifies.
    .DESCRIPTION
        This function replaces Update-AllMacs to avoid JSON serialization mismatches.

        The problem: PowerShell's JSON serialization produces different output than
        Chromium's serializer (different unicode escaping, key ordering quirks, etc.).
        When we recalculate MACs for ALL paths, we get mismatches even for values we
        didn't modify, causing the browser to detect "tampering" and reset preferences.

        The solution: Only recalculate MACs for the specific paths Meteor modifies.
        Preserve original MACs for everything else.

    .PARAMETER Macs
        The existing MACs hashtable structure (nested, e.g., protection.macs).
    .PARAMETER ModifiedPaths
        Hashtable of path => value pairs that Meteor actually modified.
    .PARAMETER SeedHex
        The HMAC seed (empty for non-Chrome builds).
    .PARAMETER DeviceId
        The device ID (raw Windows SID).
    .OUTPUTS
        Hashtable with:
        - updated: Count of MACs that were updated
        - paths: Array of paths that were updated
    #>
    param(
        [hashtable]$Macs,
        [hashtable]$ModifiedPaths,
        [string]$SeedHex,
        [string]$DeviceId
    )

    $updated = 0
    $updatedPaths = @()

    foreach ($path in $ModifiedPaths.Keys) {
        $value = $ModifiedPaths[$path]

        # Calculate new MAC for this path
        $newMac = Get-PreferenceHmac -SeedHex $SeedHex -DeviceId $DeviceId -Path $path -Value $value

        # Get original MAC for logging, then set the new one
        $existing = Get-NestedValue -Object $Macs -Path $path
        $originalMac = if ($existing.Found) { $existing.Value } else { "(none)" }
        Set-NestedValue -Hashtable $Macs -Path $path -Value $newMac
        $updated++
        $updatedPaths += $path

        Write-VerboseTimestamped "[Update MACs] $path = $($newMac.Substring(0, 32))... (value: $(ConvertTo-JsonForHmac $value))"
        if ($originalMac -ne "(none)" -and $originalMac -ne $newMac) {
            Write-VerboseTimestamped "[Update MACs]   Changed from: $($originalMac.Substring(0, 32))..."
        }
    }

    return @{
        updated = $updated
        paths   = $updatedPaths
    }
}

function Update-AllMacs {
    <#
    .SYNOPSIS
        Recalculate MACs for ALL preferences and remove orphaned MACs.
    .DESCRIPTION
        When Meteor patches extensions or other data changes, the existing MACs
        become invalid because they were calculated for the old values.

        This function:
        1. Gets all existing MAC paths from the MACs structure
        2. For each path, looks up the ACTUAL current value in preferences
           (checks SecurePreferences first, then RegularPreferences)
        3. If the preference exists: recalculates the MAC using the correct formula
        4. If the preference does NOT exist in EITHER file: REMOVES the orphaned MAC entry

        Removing orphaned MACs is critical - the browser fails validation when
        it finds a MAC for a preference that doesn't exist, causing Settings
        crashes and "reset" warnings.

        This ensures ALL MACs match their current values, preventing
        "tracked_preferences_reset" entries for ANY preference.
    .PARAMETER Macs
        The existing MACs hashtable structure (nested, e.g., protection.macs).
    .PARAMETER SecurePreferences
        The Secure Preferences hashtable (checked first for values).
    .PARAMETER RegularPreferences
        The regular Preferences hashtable (checked second for values).
        Some tracked prefs like session.*, homepage, google.services.* are stored here.
    .PARAMETER SeedHex
        The HMAC seed (empty for non-Chrome builds).
    .PARAMETER DeviceId
        The device ID (raw Windows SID).
    .OUTPUTS
        Hashtable with:
        - recalculated: Count of MACs that were recalculated
        - removed: Count of orphaned MACs that were removed
        - paths: Array of paths that were recalculated
        - removedPaths: Array of paths that were removed
    #>
    param(
        [hashtable]$Macs,
        [hashtable]$SecurePreferences,
        [hashtable]$RegularPreferences,
        [string]$SeedHex,
        [string]$DeviceId,
        [string]$SecurePrefsRawJson = ""  # Raw JSON to detect empty arrays (PS 5.1 converts [] to $null)
    )

    # WORKAROUND for PowerShell 5.1: ConvertFrom-Json converts [] to $null
    # Detect top-level keys that have empty arrays in the raw JSON so we can
    # use [] instead of $null for HMAC calculation.
    # Pattern: "key_name":[] or "key_name": [] (with optional whitespace)
    $emptyArrayPaths = @{}
    if ($SecurePrefsRawJson) {
        # Match top-level keys with empty array values: "pinned_tabs":[]
        $regexMatches = [regex]::Matches($SecurePrefsRawJson, '"([^"]+)"\s*:\s*\[\s*\]')
        foreach ($match in $regexMatches) {
            $key = $match.Groups[1].Value
            $emptyArrayPaths[$key] = $true
            Write-VerboseTimestamped "[Update MACs] Detected empty array in raw JSON: $key"
        }
    }

    # Flatten existing MACs to get all paths
    $existingMacs = @{}
    Get-FlattenedMacs -Node $Macs -Path "" -Result $existingMacs

    $recalculated = 0
    $skipped = 0
    $recalculatedPaths = @()
    $skippedPaths = @()
    $traceCount = 0
    $maxTrace = 5  # Trace first 5 skipped paths in detail

    $changedMacs = @()  # Track MACs that changed from original

    foreach ($path in $existingMacs.Keys) {
        # Save original MAC for comparison
        $originalMac = $existingMacs[$path]

        # For account_values entries:
        # - VALUE lookup uses the FULL path (account_values is a DICTIONARY storing account prefs)
        # - HMAC calculation uses the FULL path including account_values prefix
        # The value for account_values.browser.show_home_button is stored at:
        #   securePrefs["account_values"]["browser"]["show_home_button"]
        # NOT at securePrefs["browser"]["show_home_button"] (that's the LOCAL value)
        $lookupPath = $path
        $hmacPath = $path  # ALWAYS use full path for HMAC
        # NOTE: We do NOT strip account_values. prefix anymore - the value is
        # stored IN the account_values dictionary, not at the root level.

        # Look up the actual value - check Secure Preferences first, then Regular Preferences
        # Many tracked prefs (session.*, homepage, google.services.*) are in Regular Preferences
        $shouldTrace = ($traceCount -lt $maxTrace)
        $lookupResult = Get-PreferenceValue -Preferences $SecurePreferences -Path $lookupPath -Trace:$shouldTrace
        $foundIn = "SecurePreferences"

        if (-not $lookupResult.Found -and $null -ne $RegularPreferences) {
            # Not found in Secure Preferences - try Regular Preferences
            $lookupResult = Get-PreferenceValue -Preferences $RegularPreferences -Path $lookupPath -Trace:$shouldTrace
            $foundIn = "RegularPreferences"
        }

        # NOTE: For account_values.* paths when not signed in, the browser expects NULL value
        # (not the local value). The account_values section doesn't exist when not signed in,
        # and the MAC should be calculated for null. Do NOT fall back to local values.

        if (-not $lookupResult.Found) {
            # Path doesn't exist in EITHER preferences file
            # DON'T remove the MAC - the browser expects MACs for all tracked preferences
            # even if they haven't been set yet. Instead, recalculate with null value.
            # Removing MACs causes the browser to detect tampering.
            Write-VerboseTimestamped "[Update MACs] $path not found - using null value for MAC"
            $value = $null
            $newMac = Get-PreferenceHmac -SeedHex $SeedHex -DeviceId $DeviceId -Path $hmacPath -Value $value

            # Update MAC in nested structure
            Set-NestedValue -Hashtable $Macs -Path $path -Value $newMac

            $recalculated++
            $recalculatedPaths += $path

            # Compare with original MAC
            if ($originalMac -ne $newMac) {
                $changedMacs += @{
                    Path = $path
                    Original = $originalMac
                    New = $newMac
                    Value = "null (not found)"
                }
                Write-VerboseTimestamped "[Update MACs] $path CHANGED: $($originalMac.Substring(0, 16))... -> $($newMac.Substring(0, 16))... (null value)"
            } else {
                Write-VerboseTimestamped "[Update MACs] $path = $($newMac.Substring(0, 16))... (null value, unchanged)"
            }
            continue
        }

        # Found the path - recalculate MAC even if value is null
        # (null is a valid value that needs a MAC)
        $value = $lookupResult.Value

        # WORKAROUND: PowerShell 5.1 converts [] to $null
        # If the value is null but the raw JSON had [], use empty array for HMAC
        if ($null -eq $value -and $emptyArrayPaths.ContainsKey($path)) {
            Write-VerboseTimestamped "[Update MACs] ${path}: value is null but raw JSON had [] - using empty array for HMAC"
            $value = @()
        }

        $newMac = Get-PreferenceHmac -SeedHex $SeedHex -DeviceId $DeviceId -Path $hmacPath -Value $value

        # Update MAC in nested structure
        Set-NestedValue -Hashtable $Macs -Path $path -Value $newMac

        $recalculated++
        $recalculatedPaths += $path

        # Compare with original MAC
        $sourceIndicator = if ($foundIn -eq "RegularPreferences") { " (from Prefs)" } else { "" }
        if ($originalMac -ne $newMac) {
            # Get truncated value for logging (avoid calling ConvertTo-JsonForHmac twice)
            $jsonValue = if ($null -eq $value) { "null" } else { ConvertTo-JsonForHmac -Value $value }
            if ([string]::IsNullOrEmpty($jsonValue)) { $jsonValue = "(empty)" }
            $truncatedValue = if ($jsonValue.Length -le 50) { $jsonValue } else { $jsonValue.Substring(0, 50) + "..." }
            $changedMacs += @{
                Path = $path
                Original = $originalMac
                New = $newMac
                Value = $truncatedValue
            }
            Write-VerboseTimestamped "[Update MACs] $path CHANGED: $($originalMac.Substring(0, 16))... -> $($newMac.Substring(0, 16))...$sourceIndicator"
        } else {
            Write-VerboseTimestamped "[Update MACs] $path = $($newMac.Substring(0, 16))...$sourceIndicator (unchanged)"
        }
    }

    # Log summary of removed orphaned MACs
    if ($skippedPaths.Count -gt 0) {
        Write-VerboseTimestamped "[Update MACs] === REMOVED ORPHANED MACs ($($skippedPaths.Count) total) ==="
        foreach ($sp in ($skippedPaths | Select-Object -First 10)) {
            Write-VerboseTimestamped "[Update MACs]   - $sp"
        }
        if ($skippedPaths.Count -gt 10) {
            Write-VerboseTimestamped "[Update MACs]   ... and $($skippedPaths.Count - 10) more"
        }
    }

    # Log summary of changed MACs (MACs that differ from browser's original calculation)
    # This helps identify which preferences have MAC mismatches
    if ($changedMacs.Count -gt 0) {
        Write-VerboseTimestamped "[Update MACs] === CHANGED MACs ($($changedMacs.Count) of $recalculated differ from original) ==="
        foreach ($change in $changedMacs) {
            Write-VerboseTimestamped "[Update MACs]   $($change.Path)"
            Write-VerboseTimestamped "[Update MACs]     Original: $($change.Original.Substring(0, 32))..."
            Write-VerboseTimestamped "[Update MACs]     New:      $($change.New.Substring(0, 32))..."
            Write-VerboseTimestamped "[Update MACs]     Value:    $($change.Value)"
        }
    } else {
        Write-VerboseTimestamped "[Update MACs] All $recalculated MACs match browser's original calculation"
    }

    return @{
        recalculated    = $recalculated
        removed         = $skipped
        paths           = $recalculatedPaths
        removedPaths    = $skippedPaths
        changed         = $changedMacs
        emptyArrayPaths = $emptyArrayPaths  # PS 5.1 workaround: paths that had [] in raw JSON
    }
}

#region Local State Management

function Build-EnabledLabsExperiments {
    <#
    .SYNOPSIS
        Build the enabled_labs_experiments array from config features.
    .DESCRIPTION
        Converts feature names from config.json enable_features and disable_features
        to chrome://flags format entries for Local State.

        Enable features get "@1" suffix (enabled)
        Disable features get "@2" suffix (disabled)

        Only features that have a mapping in $script:FeatureToFlagMapping are included.
        Features without mappings remain on the command line.
    .PARAMETER Config
        The Meteor configuration object containing browser.enable_features and
        browser.disable_features arrays.
    .OUTPUTS
        [string[]] Array of flag entries in "flag-name@N" format.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Config
    )

    $experiments = [System.Collections.ArrayList]::new()

    # Process enable features (@1 = enabled)
    $enableFeatures = $Config.browser.enable_features
    if ($enableFeatures) {
        foreach ($feature in $enableFeatures) {
            if ($script:FeatureToFlagMapping.ContainsKey($feature)) {
                $flagName = $script:FeatureToFlagMapping[$feature]
                $null = $experiments.Add("$flagName@1")
            }
        }
    }

    # Process disable features (@2 = disabled)
    $disableFeatures = $Config.browser.disable_features
    if ($disableFeatures) {
        foreach ($feature in $disableFeatures) {
            if ($script:FeatureToFlagMapping.ContainsKey($feature)) {
                $flagName = $script:FeatureToFlagMapping[$feature]
                $null = $experiments.Add("$flagName@2")
            }
        }
    }

    Write-VerboseTimestamped "[Local State] Built $($experiments.Count) enabled_labs_experiments entries"

    # CRITICAL: Use comma operator to preserve array in PS 5.1
    return ,$experiments.ToArray()
}

function Get-CommandLineOnlyFeatures {
    <#
    .SYNOPSIS
        Filter features to only those without Local State mappings.
    .DESCRIPTION
        Returns features that do NOT have chrome://flags equivalents and must
        remain on the command line (--enable-features/--disable-features).

        This includes:
        - Chromium features without chrome://flags UI
        - Comet-specific features (e.g., PerplexityAutoupdate)
        - Very new features not yet in chrome://flags
    .PARAMETER Features
        Array of feature names from config.json.
    .OUTPUTS
        [string[]] Array of feature names that should stay on command line.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $false)]
        [object]$Features
    )

    if (-not $Features -or $Features.Count -eq 0) {
        return ,@()
    }

    $commandLineOnly = [System.Collections.ArrayList]::new()

    foreach ($feature in $Features) {
        if (-not $script:FeatureToFlagMapping.ContainsKey($feature)) {
            $null = $commandLineOnly.Add($feature)
        }
    }

    # CRITICAL: Use comma operator to preserve array in PS 5.1
    return ,$commandLineOnly.ToArray()
}

function Write-LocalState {
    <#
    .SYNOPSIS
        Create or update Local State file with enabled_labs_experiments and additional prefs.
    .DESCRIPTION
        Writes the Local State file at the User Data directory root (not in profile).
        This file controls chrome://flags settings and machine-wide preferences.

        CRITICAL: If Local State already exists, this function reads it first and
        preserves existing keys (especially os_crypt.encrypted_key which is used
        to encrypt cookies and passwords). Only Meteor-managed settings are updated.

        IMPORTANT: browser.first_run_finished MUST be true or browser will
        show onboarding flow and may reset settings.
    .PARAMETER LocalStatePath
        Full path to the Local State file.
    .PARAMETER Experiments
        Array of experiment entries in "flag-name@N" format.
    .PARAMETER AdditionalPrefs
        Hashtable of additional Local State prefs (policy prefs, machine-wide settings).
    .OUTPUTS
        [bool] $true if successful, $false on failure.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LocalStatePath,

        [Parameter(Mandatory = $false)]
        [string[]]$Experiments = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$AdditionalPrefs = @{}
    )

    try {
        # CRITICAL: Read existing Local State to preserve os_crypt.encrypted_key
        # This key encrypts cookies and passwords - if lost, all encrypted data becomes unreadable
        $localState = $null
        if (Test-Path $LocalStatePath) {
            try {
                $existingJson = Get-Content -Path $LocalStatePath -Raw -ErrorAction Stop
                $existingState = $existingJson | ConvertFrom-Json -ErrorAction Stop
                $localState = Convert-PSObjectToHashtable -InputObject $existingState
                Write-VerboseTimestamped "[Local State] Read existing Local State, preserving os_crypt and other keys"
            }
            catch {
                Write-VerboseTimestamped "[Local State] Warning: Could not read existing Local State: $_"
                $localState = $null
            }
        }

        # Create new state if none exists
        if ($null -eq $localState) {
            $localState = @{}
            Write-VerboseTimestamped "[Local State] Creating new Local State"
        }

        # Ensure browser section exists and set required values
        if (-not $localState.ContainsKey('browser')) {
            $localState['browser'] = @{}
        }
        $localState['browser']['first_run_finished'] = $true
        $localState['browser']['enabled_labs_experiments'] = $Experiments

        # Ensure profile section exists and set values
        if (-not $localState.ContainsKey('profile')) {
            $localState['profile'] = @{}
        }
        $localState['profile']['picker_availability_on_startup'] = 1  # 1 = disabled
        $localState['profile']['browser_guest_enforced'] = $false
        $localState['profile']['add_person_enabled'] = $false

        # Add additional Local State prefs (policy prefs, machine-wide settings)
        foreach ($path in $AdditionalPrefs.Keys) {
            Set-NestedValue -Hashtable $localState -Path $path -Value $AdditionalPrefs[$path]
            Write-VerboseTimestamped "[Local State] Added pref: $path = $($AdditionalPrefs[$path])"
        }

        # Write using Save-JsonFile for consistent formatting
        Save-JsonFile -Path $LocalStatePath -Object $localState -Compress

        Write-VerboseTimestamped "[Local State] Wrote Local State with $($Experiments.Count) experiments to: $LocalStatePath"
        return $true
    }
    catch {
        Write-VerboseTimestamped "[Local State] Error writing Local State: $_"
        return $false
    }
}

function Update-LocalStateExperiments {
    <#
    .SYNOPSIS
        Update Local State experiments while preserving user-added flags.
    .DESCRIPTION
        Merges Meteor-managed experiments with any user-added chrome://flags entries.
        User flags that don't conflict with Meteor's managed flags are preserved.

        Meteor-managed flags are identified by being in the FeatureToFlagMapping table.
    .PARAMETER LocalStatePath
        Full path to the Local State file.
    .PARAMETER NewExperiments
        Array of Meteor-managed experiment entries to set.
    .OUTPUTS
        [bool] $true if successful, $false on failure.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LocalStatePath,

        [Parameter(Mandatory = $false)]
        [string[]]$NewExperiments = @()
    )

    try {
        # Build set of Meteor-managed flag names (without @N suffix)
        $managedFlags = @{}
        foreach ($flagName in $script:FeatureToFlagMapping.Values) {
            $managedFlags[$flagName] = $true
        }

        $existingExperiments = @()

        # Read existing Local State if it exists
        if (Test-Path $LocalStatePath) {
            $localStateJson = Get-Content -Path $LocalStatePath -Raw -ErrorAction Stop

            # PS 5.1 workaround: Check for empty arrays in raw JSON before parsing
            $hasEmptyExperiments = $localStateJson -match '"enabled_labs_experiments"\s*:\s*\[\s*\]'

            $localState = $localStateJson | ConvertFrom-Json -ErrorAction Stop
            $localStateHash = Convert-PSObjectToHashtable -InputObject $localState

            # Get existing experiments, handling PS 5.1 null conversion
            if ($localStateHash.ContainsKey('browser') -and
                $localStateHash['browser'].ContainsKey('enabled_labs_experiments')) {
                $existing = $localStateHash['browser']['enabled_labs_experiments']
                if ($null -ne $existing) {
                    $existingExperiments = @($existing)
                }
                elseif (-not $hasEmptyExperiments) {
                    # Not empty array in JSON, truly null - keep as empty
                    $existingExperiments = @()
                }
            }
        }
        else {
            $localStateHash = @{
                browser = @{
                    first_run_finished = $true
                }
            }
        }

        # Filter out Meteor-managed flags from existing experiments (preserve user flags)
        $userExperiments = [System.Collections.ArrayList]::new()
        foreach ($exp in $existingExperiments) {
            # Extract flag name (remove @N suffix)
            $flagName = $exp -replace '@\d+$', ''
            if (-not $managedFlags.ContainsKey($flagName)) {
                $null = $userExperiments.Add($exp)
            }
        }

        # Merge: Meteor experiments + user experiments
        $mergedExperiments = [System.Collections.ArrayList]::new()
        foreach ($exp in $NewExperiments) {
            $null = $mergedExperiments.Add($exp)
        }
        foreach ($exp in $userExperiments) {
            $null = $mergedExperiments.Add($exp)
        }

        # Ensure browser section exists
        if (-not $localStateHash.ContainsKey('browser')) {
            $localStateHash['browser'] = @{}
        }

        # Update experiments and ensure first_run_finished is set
        $localStateHash['browser']['enabled_labs_experiments'] = $mergedExperiments.ToArray()
        $localStateHash['browser']['first_run_finished'] = $true

        # Ensure profile settings are in Local State (browser-wide, not profile-specific)
        if (-not $localStateHash.ContainsKey('profile')) {
            $localStateHash['profile'] = @{}
        }
        $localStateHash['profile']['picker_availability_on_startup'] = 1  # 1 = disabled
        $localStateHash['profile']['browser_guest_enforced'] = $false
        $localStateHash['profile']['add_person_enabled'] = $false

        # Write updated Local State
        Save-JsonFile -Path $LocalStatePath -Object $localStateHash -Compress

        Write-VerboseTimestamped "[Local State] Updated with $($NewExperiments.Count) Meteor + $($userExperiments.Count) user experiments"
        return $true
    }
    catch {
        Write-VerboseTimestamped "[Local State] Error updating Local State: $_"
        return $false
    }
}

#endregion

#endregion

#region Browser Launch

function Test-FeatureConflicts {
    <#
    .SYNOPSIS
        Check if any features appear in both enabled and disabled lists.
    .DESCRIPTION
        Validates that there are no conflicting feature flags that would cause
        undefined browser behavior. Logs warnings for any conflicts found.
    .PARAMETER EnableFeatures
        Array of feature names to enable.
    .PARAMETER DisableFeatures
        Array of feature names to disable.
    .OUTPUTS
        [bool] $true if conflicts were found, $false otherwise.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$EnableFeatures,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DisableFeatures
    )

    # Handle null or empty arrays
    if (-not $EnableFeatures -or $EnableFeatures.Count -eq 0) {
        return $false
    }
    if (-not $DisableFeatures -or $DisableFeatures.Count -eq 0) {
        return $false
    }

    # Find features that appear in both lists
    $conflicts = $EnableFeatures | Where-Object { $DisableFeatures -contains $_ }

    if ($conflicts -and $conflicts.Count -gt 0) {
        Write-Status "Feature flag conflicts detected!" -Type Warning
        foreach ($conflict in $conflicts) {
            Write-Status "  Conflict: '$conflict' is in both enable and disable lists" -Type Warning
        }
        return $true
    }

    return $false
}

function Build-BrowserCommand {
    <#
    .SYNOPSIS
        Build the browser command line with all flags.
    .DESCRIPTION
        Constructs the complete command line for launching the browser with:
        - User data directory (for portable mode)
        - Profile directory
        - Explicit flags (privacy, debugging, experimental)
        - Extension loading
        - Feature flags (enable/disable) in flag-switches block
    .PARAMETER Config
        The Meteor configuration object containing browser settings.
    .PARAMETER BrowserExe
        Full path to the browser executable.
    .PARAMETER ExtPath
        Path to the directory containing patched extensions.
    .PARAMETER UBlockPath
        Path to the uBlock Origin extension directory.
    .PARAMETER AdGuardExtraPath
        Path to the AdGuard Extra extension directory.
    .PARAMETER UserDataPath
        Path to store browser user data (bookmarks, cache, etc.).
    .OUTPUTS
        [System.Collections.ArrayList] Command line components as an array.
    #>
    [OutputType([System.Collections.ArrayList])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$BrowserExe,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExtPath,

        [Parameter(Mandatory = $false)]
        [string]$UBlockPath,

        [Parameter(Mandatory = $false)]
        [string]$AdGuardExtraPath,

        [Parameter(Mandatory = $false)]
        [string]$UserDataPath
    )

    $cmd = [System.Collections.ArrayList]@()
    [void]$cmd.Add($BrowserExe)

    $browserConfig = $Config.browser

    # ========================================
    # Section 1: Core Browser Configuration
    # ========================================

    # User data directory - enables portable mode by isolating all browser data
    if ($UserDataPath) {
        [void]$cmd.Add("--user-data-dir=`"$UserDataPath`"")
    }

    # Profile selection - only add if explicitly configured (Chromium defaults to "Default")
    if ($browserConfig.PSObject.Properties['profile'] -and $browserConfig.profile) {
        [void]$cmd.Add("--profile-directory=$($browserConfig.profile)")
    }

    # ========================================
    # Section 2: Explicit Flags (outside flag-switches block)
    # ========================================
    # These flags control:
    # - First-run experience (--no-first-run, --skip-onboarding-for-testing)
    # - Privacy settings (--disable-client-side-phishing-detection, --no-pings)
    # - Extension APIs (--enable-experimental-extension-apis)
    # - MCP features (--enable-local-mcp, --enable-local-custom-mcp, --enable-dxt)

    foreach ($flag in $browserConfig.flags) {
        [void]$cmd.Add($flag)
    }

    # ========================================
    # Section 3: Extension Loading
    # ========================================

    $extensions = [System.Collections.ArrayList]@()

    # Add patched bundled extensions (perplexity, agents)
    # Note: comet_web_resources is loaded via external_extensions.json (no patches needed)
    foreach ($extName in $Config.extensions.bundled.PSObject.Properties.Name) {
        if ($extName -eq 'comet_web_resources') { continue }  # Loaded via external_extensions.json
        $extDir = Join-Path $ExtPath $extName
        if (Test-Path $extDir) {
            [void]$extensions.Add($extDir)
        }
    }

    # Add uBlock Origin MV2 (content blocking)
    if ($UBlockPath -and (Test-Path $UBlockPath)) {
        [void]$extensions.Add($UBlockPath)
    }

    # Add AdGuard Extra (anti-adblock circumvention)
    if ($AdGuardExtraPath -and (Test-Path $AdGuardExtraPath)) {
        [void]$extensions.Add($AdGuardExtraPath)
    }

    if ($extensions.Count -gt 0) {
        # Quote each path to handle spaces in directory names
        $quotedExtensions = $extensions | ForEach-Object { "`"$_`"" }
        $extList = $quotedExtensions -join ","
        [void]$cmd.Add("--load-extension=$extList")
    }

    # ========================================
    # Section 4: Flag Switches Block
    # ========================================
    # The --flag-switches-begin/end markers define a section that mimics
    # chrome://flags UI-enabled flags. Features in this block take precedence.

    [void]$cmd.Add("--flag-switches-begin")

    # Additional flags that work better inside the flag-switches block
    # (e.g., --extensions-on-chrome-urls, --extensions-on-extension-urls)
    if ($browserConfig.flag_switches) {
        foreach ($flag in $browserConfig.flag_switches) {
            [void]$cmd.Add($flag)
        }
    }

    # Validate feature flags before building command line
    $enableFeatures = $browserConfig.enable_features
    $disableFeatures = $browserConfig.disable_features

    $null = Test-FeatureConflicts -EnableFeatures $enableFeatures -DisableFeatures $disableFeatures

    # Filter features: Only include those WITHOUT Local State mappings on command line
    # Features WITH mappings are enforced via browser.enabled_labs_experiments in Local State
    # This avoids dual enforcement and potential conflicts
    $cmdEnableFeatures = Get-CommandLineOnlyFeatures -Features $enableFeatures
    $cmdDisableFeatures = Get-CommandLineOnlyFeatures -Features $disableFeatures

    Write-VerboseTimestamped "[Browser Command] Command-line features: enable=$($cmdEnableFeatures.Count) (of $($enableFeatures.Count)), disable=$($cmdDisableFeatures.Count) (of $($disableFeatures.Count))"

    # Enable features - includes command-line-only features:
    # - AllowLegacyMV2Extensions (no chrome://flags equivalent)
    # - ExperimentalOmniboxLabs (no chrome://flags equivalent)
    # - WebRtcHideLocalIpsWithMdns (no chrome://flags equivalent)
    # - Comet-specific features
    if ($cmdEnableFeatures -and $cmdEnableFeatures.Count -gt 0) {
        $enableFeaturesString = $cmdEnableFeatures -join ","
        [void]$cmd.Add("--enable-features=$enableFeaturesString")
    }

    # Disable features - includes command-line-only features:
    # - MV2 deprecation warning (ExtensionManifestV2DeprecationWarning - no flag)
    # - AI*API features (no chrome://flags)
    # - Glic* features (no chrome://flags)
    # - Lens* features (no chrome://flags)
    # - PerplexityAutoupdate (Comet-specific)
    if ($cmdDisableFeatures -and $cmdDisableFeatures.Count -gt 0) {
        $disableFeaturesString = $cmdDisableFeatures -join ","
        [void]$cmd.Add("--disable-features=$disableFeaturesString")
    }

    [void]$cmd.Add("--flag-switches-end")

    return $cmd
}

function Format-BrowserCommandForDisplay {
    <#
    .SYNOPSIS
        Format a browser command array for human-readable display.
    .DESCRIPTION
        Groups related flags together and formats them with one flag per line
        for easier verification during dry-run mode.
    .PARAMETER Command
        The command array from Build-BrowserCommand.
    .OUTPUTS
        [string] Formatted multi-line string representation of the command.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [array]$Command
    )

    $output = [System.Text.StringBuilder]::new()

    # Executable path
    [void]$output.AppendLine("Executable:")
    [void]$output.AppendLine("  $($Command[0])")
    [void]$output.AppendLine("")

    # Group flags by category
    $userDataFlags = @()
    $profileFlags = @()
    $privacyFlags = @()
    $extensionFlags = @()
    $mcpFlags = @()
    $flagSwitchesSection = @()
    $enableFeatures = @()
    $disableFeatures = @()
    $otherFlags = @()

    $inFlagSwitches = $false

    for ($i = 1; $i -lt $Command.Count; $i++) {
        $flag = $Command[$i]

        if ($flag -eq "--flag-switches-begin") {
            $inFlagSwitches = $true
            continue
        }
        if ($flag -eq "--flag-switches-end") {
            $inFlagSwitches = $false
            continue
        }

        if ($flag -match "^--enable-features=(.+)$") {
            $enableFeatures = $Matches[1] -split ","
            continue
        }
        if ($flag -match "^--disable-features=(.+)$") {
            $disableFeatures = $Matches[1] -split ","
            continue
        }

        if ($inFlagSwitches) {
            $flagSwitchesSection += $flag
            continue
        }

        # Categorize flags
        switch -Regex ($flag) {
            "^--user-data-dir=" { $userDataFlags += $flag }
            "^--profile-directory=" { $profileFlags += $flag }
            "^--proxy-server=" { $privacyFlags += $flag }
            "^--load-extension=" { $extensionFlags += $flag }
            "^--(enable-local-mcp|enable-local-custom-mcp|enable-dxt)" { $mcpFlags += $flag }
            "^--(disable-|no-|skip-)" { $privacyFlags += $flag }
            default { $otherFlags += $flag }
        }
    }

    # Output each category
    if ($userDataFlags.Count -gt 0) {
        [void]$output.AppendLine("User Data:")
        foreach ($f in $userDataFlags) { [void]$output.AppendLine("  $f") }
        [void]$output.AppendLine("")
    }

    if ($profileFlags.Count -gt 0) {
        [void]$output.AppendLine("Profile:")
        foreach ($f in $profileFlags) { [void]$output.AppendLine("  $f") }
        [void]$output.AppendLine("")
    }

    if ($privacyFlags.Count -gt 0) {
        [void]$output.AppendLine("Privacy Flags:")
        foreach ($f in $privacyFlags) { [void]$output.AppendLine("  $f") }
        [void]$output.AppendLine("")
    }

    if ($mcpFlags.Count -gt 0) {
        [void]$output.AppendLine("MCP Flags:")
        foreach ($f in $mcpFlags) { [void]$output.AppendLine("  $f") }
        [void]$output.AppendLine("")
    }

    if ($extensionFlags.Count -gt 0) {
        [void]$output.AppendLine("Extensions:")
        foreach ($f in $extensionFlags) {
            # Parse and list each extension path on its own line
            if ($f -match "^--load-extension=(.+)$") {
                $extPaths = $Matches[1] -split ','
                foreach ($ext in $extPaths) {
                    $extName = Split-Path -Leaf ($ext -replace '"', '')
                    [void]$output.AppendLine("  - $extName")
                }
            }
        }
        [void]$output.AppendLine("")
    }

    if ($otherFlags.Count -gt 0) {
        [void]$output.AppendLine("Other Flags:")
        foreach ($f in $otherFlags) { [void]$output.AppendLine("  $f") }
        [void]$output.AppendLine("")
    }

    if ($flagSwitchesSection.Count -gt 0) {
        [void]$output.AppendLine("Flag Switches:")
        foreach ($f in $flagSwitchesSection) { [void]$output.AppendLine("  $f") }
        [void]$output.AppendLine("")
    }

    if ($enableFeatures.Count -gt 0) {
        [void]$output.AppendLine("Enabled Features ($($enableFeatures.Count)):")
        foreach ($f in ($enableFeatures | Sort-Object)) { [void]$output.AppendLine("  + $f") }
        [void]$output.AppendLine("")
    }

    if ($disableFeatures.Count -gt 0) {
        [void]$output.AppendLine("Disabled Features ($($disableFeatures.Count)):")
        foreach ($f in ($disableFeatures | Sort-Object)) { [void]$output.AppendLine("  - $f") }
    }

    return $output.ToString()
}

function Start-Browser {
    <#
    .SYNOPSIS
        Launch the browser with the built command.
    .DESCRIPTION
        Starts the browser process with the provided command line arguments.
        In dry-run mode (WhatIf), displays a formatted summary of the command.
    .PARAMETER Command
        The command array from Build-BrowserCommand (first element is exe, rest are args).
    .OUTPUTS
        [System.Diagnostics.Process] The launched browser process, or $null in dry-run mode.
    #>
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [array]$Command
    )

    if ($WhatIfPreference) {
        Write-Host ""
        Write-Status "Would launch browser with the following configuration:" -Type DryRun
        Write-Host ""

        # Use the formatter for nice grouped output
        $formatted = Format-BrowserCommandForDisplay -Command $Command
        Write-Host $formatted

        Write-Status "Total flags: $($Command.Count - 1)" -Type Detail
        return $null
    }

    $exe = $Command[0]
    $processArgs = $Command[1..($Command.Count - 1)]

    # Show full command line in verbose mode
    $fullCommandLine = "`"$exe`" $($processArgs -join ' ')"
    Write-VerboseTimestamped "Launching browser with command line:"
    Write-VerboseTimestamped $fullCommandLine

    $process = Start-Process -FilePath $exe -ArgumentList $processArgs -PassThru
    return $process
}

#endregion

#region Main Workflow Steps

function Initialize-CometInstallation {
    <#
    .SYNOPSIS
        Step 0: Check and install Comet browser.
    .DESCRIPTION
        Finds existing Comet installation or downloads/extracts a new one.
        Handles both portable and system installation modes.
    .OUTPUTS
        Hashtable with Comet installation info, version, and FreshInstall flag.
    #>
    param(
        [PSCustomObject]$Config,
        [string]$MeteorDataPath,
        [switch]$PortableMode,
        [switch]$Force,
        [string]$PreDownloadedInstaller
    )

    Write-Status "Step 0: Checking Comet Installation" -Type Step

    if ($PortableMode) {
        Write-Status "Portable mode enabled - data path: $MeteorDataPath" -Type Detail
    }

    # Check for existing installation (portable path first if in portable mode)
    $comet = Get-CometInstallation -DataPath $(if ($PortableMode) { $MeteorDataPath } else { $null })
    $freshInstall = $false

    # In portable mode, we need a portable installation - don't use system-wide fallback
    if ($PortableMode -and $comet -and -not $comet.Portable) {
        Write-Status "Found system installation but portable mode is enabled - extracting portable version..." -Type Info
        $comet = $null
    }

    # Force re-download/extract in portable mode when -Force is used
    if ($Force -and $PortableMode -and $comet) {
        Write-Status "Force mode - re-downloading Comet browser..." -Type Info
        $comet = $null
    }

    if (-not $comet) {
        $freshInstall = $true
        if ($PortableMode) {
            $comet = Install-CometPortable -DownloadUrl $Config.comet.download_url -TargetDir $MeteorDataPath -PreDownloadedInstaller $PreDownloadedInstaller
        }
        else {
            $comet = Install-Comet -DownloadUrl $Config.comet.download_url
        }
    }

    if (-not $comet -and -not $WhatIfPreference) {
        Write-Status "Could not find or install Comet browser" -Type Error
        return $null
    }

    $cometVersion = $null
    if ($comet) {
        Write-Status "Comet found: $($comet.Executable)" -Type Success
        if ($comet.Portable) {
            Write-Status "Mode: Portable" -Type Detail
        }
        $cometVersion = Get-CometVersion -ExePath $comet.Executable
        Write-Status "Version: $cometVersion" -Type Detail
    }

    return @{
        Comet        = $comet
        CometVersion = $cometVersion
        FreshInstall = $freshInstall
    }
}

function Update-CometBrowser {
    <#
    .SYNOPSIS
        Step 1: Check for and apply Comet browser updates.
    .OUTPUTS
        Hashtable with updated Comet installation info and version.
    #>
    param(
        [PSCustomObject]$Config,
        [hashtable]$Comet,
        [string]$CometVersion,
        [string]$MeteorDataPath,
        [switch]$PortableMode
    )

    Write-Status "Step 1: Checking for Comet Updates" -Type Step

    if (-not $Config.comet.auto_update -or -not $Comet) {
        Write-Status "Auto-update disabled or Comet not installed" -Type Detail
        return @{ Comet = $Comet; CometVersion = $CometVersion }
    }

    $updateInfo = Test-CometUpdate -CurrentVersion $CometVersion -DownloadUrl $Config.comet.download_url

    if ($updateInfo) {
        Write-Status "Update available: $($updateInfo.Version) (current: $CometVersion)" -Type Warning
        if (-not $WhatIfPreference) {
            Write-Status "Downloading Comet update..." -Type Info
            $newComet = if ($PortableMode) {
                Install-CometPortable -DownloadUrl $Config.comet.download_url -TargetDir $MeteorDataPath
            }
            else {
                Install-Comet -DownloadUrl $Config.comet.download_url
            }

            if ($newComet) {
                $Comet = $newComet
                $CometVersion = Get-CometVersion -ExePath $Comet.Executable
                Write-Status "Updated to version: $CometVersion" -Type Success
            }
        }
        else {
            Write-Status "Would download and install Comet $($updateInfo.Version)" -Type DryRun
        }
    }
    else {
        Write-Status "Comet is up to date" -Type Success
    }

    return @{ Comet = $Comet; CometVersion = $CometVersion }
}

function Update-BundledExtensions {
    <#
    .SYNOPSIS
        Step 2: Check for and download bundled extension updates.
    .OUTPUTS
        $true if any extensions were updated, $false otherwise.
    #>
    param(
        [PSCustomObject]$Config,
        [hashtable]$Comet
    )

    Write-Status "Step 2: Checking for Extension Updates" -Type Step

    # If fetch_from_server is enabled, skip this step - we'll fetch latest in Step 4
    if ($Config.extensions.fetch_from_server -eq $true) {
        Write-Status "Server fetch enabled - extensions will be downloaded in Step 4" -Type Detail
        return $false
    }

    if (-not $Comet) {
        Write-Status "Extension update checking disabled" -Type Detail
        return $false
    }

    $extensionsUpdated = $false

    # Find default_apps directory (may be in version subdirectory)
    $defaultAppsDir = Get-DefaultAppsDirectory -CometDir $Comet.Directory
    if (-not $defaultAppsDir) {
        return $false
    }

    $crxFiles = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue
    foreach ($crx in $crxFiles) {
        $manifest = Get-CrxManifest -CrxPath $crx.FullName
        if (-not $manifest) { continue }

        $extId = if ($manifest.key) {
            $keyBytes = [Convert]::FromBase64String($manifest.key)
            $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($keyBytes)
            $idChars = $hash[0..15] | ForEach-Object { [char](97 + ($_ % 26)) }
            -join $idChars
        }
        else { $null }

        $updateUrl = $manifest.update_url
        $currentVersion = $manifest.version

        if (-not ($extId -and $updateUrl -and $currentVersion)) { continue }

        Write-Status "Checking $($manifest.name)..." -Type Detail
        $extUpdate = Get-ExtensionUpdateInfo -UpdateUrl $updateUrl -ExtensionId $extId -CurrentVersion $currentVersion

        if ($extUpdate -and $extUpdate.Version -and $extUpdate.Codebase) {
            $comparison = Compare-Versions -Version1 $extUpdate.Version -Version2 $currentVersion
            if ($comparison -gt 0) {
                Write-Status "  Update available: $currentVersion -> $($extUpdate.Version)" -Type Info
                if (-not $WhatIfPreference) {
                    try {
                        $tempCrx = Join-Path $env:TEMP "meteor_ext_$(Get-Random).crx"
                        $null = Invoke-MeteorWebRequest -Uri $extUpdate.Codebase -Mode Download -OutFile $tempCrx -TimeoutSec 120
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

    return $extensionsUpdated
}

function Test-SetupRequired {
    <#
    .SYNOPSIS
        Step 3: Detect if extension patching is required.
    .OUTPUTS
        $true if setup is required, $false otherwise.
    #>
    param(
        [hashtable]$Comet,
        [hashtable]$State,
        [string]$PatchedExtPath,
        [switch]$Force,
        [switch]$ExtensionsUpdated
    )

    Write-Status "Step 3: Detecting Changes" -Type Step

    $needsSetup = $Force -or $ExtensionsUpdated -or -not (Test-Path $PatchedExtPath)

    if (-not $needsSetup -and $Comet) {
        $defaultAppsDir = Get-DefaultAppsDirectory -CometDir $Comet.Directory
        if ($defaultAppsDir) {
            # Check both active CRX files and backed-up CRX files
            # Exclude comet_web_resources.crx - it's loaded directly via external_extensions.json (no patching)
            $allCrx = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx*" -ErrorAction SilentlyContinue | Where-Object {
                ($_.Extension -eq '.crx' -or $_.Name.EndsWith('.crx.meteor-backup')) -and
                $_.Name -notlike 'comet_web_resources.crx*'
            }
            foreach ($crx in $allCrx) {
                if (Test-FileChanged -FilePath $crx.FullName -State $State) {
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

    return $needsSetup
}

function Initialize-Extensions {
    <#
    .SYNOPSIS
        Step 4: Extract and patch bundled extensions.
    .DESCRIPTION
        Extracts CRX files, applies patches, clears caches, and backs up originals.
        Also applies PAK modifications if enabled.
    #>
    param(
        [PSCustomObject]$Config,
        [hashtable]$Comet,
        [hashtable]$State,
        [string]$PatchedExtPath,
        [string]$PatchesPath,
        [string]$PatchedResourcesPath,
        [string]$UserDataPath,
        [string]$CometVersion,
        [switch]$PortableMode,
        [switch]$NeedsSetup,
        [switch]$SkipPak,
        [switch]$PakInBackground,
        [switch]$FreshInstall
    )

    Write-Status "Step 4: Extracting and Patching" -Type Step

    # Configure external_extensions.json for comet_web_resources (loaded directly from CRX)
    # and backup other CRX files (which will be extracted and patched)
    if ($Comet) {
        # Find default_apps directory (may be in version subdirectory)
        $defaultAppsDir = Get-DefaultAppsDirectory -CometDir $Comet.Directory
        if ($defaultAppsDir) {
            $extJsonPath = Join-Path $defaultAppsDir "external_extensions.json"
            $extJsonBackup = "$extJsonPath.meteor-backup"

            # Build external_extensions.json with comet_web_resources entry
            # Other bundled extensions (perplexity, agents) are loaded via --load-extension
            $cometWebResourcesCrx = Join-Path $defaultAppsDir "comet_web_resources.crx"
            $externalExtensions = @{}

            if (Test-Path $cometWebResourcesCrx) {
                # Read version from CRX manifest
                $crxManifest = Get-CrxManifest -CrxPath $cometWebResourcesCrx
                if ($crxManifest -and $crxManifest.version) {
                    # Extension ID for comet_web_resources
                    $cometWebResourcesId = "mjdcklhepheaaemphcopihnmjlmjpcnh"
                    $externalExtensions[$cometWebResourcesId] = @{
                        external_crx     = "comet_web_resources.crx"
                        external_version = $crxManifest.version
                    }
                }
            }

            # Write external_extensions.json
            if ($WhatIfPreference) {
                if ($externalExtensions.Count -gt 0) {
                    Write-Status "Would configure external_extensions.json for comet_web_resources" -Type Detail
                }
                else {
                    Write-Status "Would clear external_extensions.json" -Type Detail
                }
            }
            else {
                # Backup original if not already backed up
                if ((Test-Path $extJsonPath) -and -not (Test-Path $extJsonBackup)) {
                    Copy-Item -Path $extJsonPath -Destination $extJsonBackup -Force
                }

                if ($externalExtensions.Count -gt 0) {
                    Save-JsonFile -Path $extJsonPath -Object $externalExtensions
                    Write-Status "Configured external_extensions.json for comet_web_resources" -Type Detail
                }
                else {
                    Set-Content -Path $extJsonPath -Value "{}" -Encoding UTF8
                    Write-Status "Cleared external_extensions.json" -Type Detail
                }
            }

            # Backup other .crx files (not comet_web_resources - it stays in place)
            $crxFilesToBackup = Get-ChildItem -Path $defaultAppsDir -Filter "*.crx" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne "comet_web_resources.crx" }
            foreach ($crx in $crxFilesToBackup) {
                $backupPath = "$($crx.FullName).meteor-backup"
                if (-not (Test-Path $backupPath)) {
                    if ($WhatIfPreference) {
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

    if (-not $NeedsSetup -or -not $Comet) {
        Write-Status "Using existing patched extensions" -Type Detail
        return
    }

    # Use actual browser version, or fallback from config for fresh installs
    $browserVersionForUpdate = if ($CometVersion) { $CometVersion } else { $Config.comet.fallback_version }
    if (-not $browserVersionForUpdate) { $browserVersionForUpdate = "120.0.0.0" }

    $setupResult = Initialize-PatchedExtensions `
        -CometDir $Comet.Directory `
        -OutputDir $PatchedExtPath `
        -PatchesDir $PatchesPath `
        -PatchConfig $Config.extensions.patch_config `
        -ExtensionConfig $Config.extensions `
        -BrowserVersion $browserVersionForUpdate `
        -FreshInstall:$FreshInstall

    if (-not $setupResult) {
        Write-Status "Extension patching failed" -Type Error
        return
    }

    Write-Status "Extensions patched successfully" -Type Success

    # Update state with new hashes
    if (-not $WhatIfPreference) {
        $defaultAppsDir = Get-DefaultAppsDirectory -CometDir $Comet.Directory
        if ($defaultAppsDir) {
            Get-ChildItem -Path $defaultAppsDir -Filter "*.crx*" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.crx' -or $_.Name.EndsWith('.crx.meteor-backup') } | ForEach-Object {
                Update-FileHash -FilePath $_.FullName -State $State
            }
        }
    }

    # Clear Comet's CRX caches
    $cachePaths = @()
    if ($PortableMode -and $UserDataPath) {
        $cachePaths += (Join-Path $UserDataPath "extensions_crx_cache")
        $cachePaths += (Join-Path $UserDataPath "component_crx_cache")
    }
    else {
        $cachePaths += (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data\extensions_crx_cache")
        $cachePaths += (Join-Path $env:LOCALAPPDATA "Perplexity\Comet\User Data\component_crx_cache")
    }

    foreach ($crxCachePath in $cachePaths) {
        if (Test-Path $crxCachePath) {
            if ($WhatIfPreference) {
                Write-Status "Would clear: $crxCachePath" -Type Detail
            }
            else {
                Remove-Item -Path $crxCachePath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "Cleared: $(Split-Path -Leaf $crxCachePath)" -Type Detail
            }
        }
    }

    # PAK modifications
    if ($PakInBackground) {
        Write-Status "PAK modifications running in background" -Type Detail
    }
    elseif ($SkipPak) {
        Write-Status "Skipping PAK modifications (-SkipPak specified)" -Type Detail
    }
    elseif ($Config.pak_modifications.enabled) {
        $pakResult = Initialize-PakModifications `
            -CometDir $Comet.Directory `
            -PakConfig $Config.pak_modifications `
            -PatchedResourcesPath $PatchedResourcesPath `
            -Force:$NeedsSetup `
            -State $State

        if (-not $pakResult.Success) {
            Write-Status "PAK modifications failed: $($pakResult.Error)" -Type Error
        }
        elseif (-not $pakResult.Skipped -and $pakResult.HashAfterModification) {
            # Save pak_state for subsequent runs
            $State.pak_state = @{
                hash_after_modification   = $pakResult.HashAfterModification
                modified_resources        = $pakResult.ModifiedResourceIds
                modification_config_hash  = $pakResult.ModificationConfigHash
            }
        }
    }
}

function Initialize-AdBlockExtensions {
    <#
    .SYNOPSIS
        Step 5/5.5: Download and configure ad-blocking extensions.
    .DESCRIPTION
        Downloads uBlock Origin and AdGuard Extra in parallel when both need updating,
        then configures them sequentially. Uses runspace pool for parallel downloads.
    .OUTPUTS
        Hashtable with UBlockPath and AdGuardExtraPath (may be $null if disabled).
    #>
    param(
        [PSCustomObject]$Config,
        [string]$UBlockPath,
        [string]$AdGuardExtraPath,
        [switch]$Force,
        [string]$PreDownloadedUBlock,
        [string]$PreDownloadedAdGuard
    )

    Write-Status "Step 5: Checking ad-block extensions" -Type Step

    $resultUBlockPath = $UBlockPath
    $resultAdGuardPath = $AdGuardExtraPath

    $ublockEnabled = $Config.ublock.enabled -eq $true
    $adguardEnabled = $Config.adguard_extra.enabled -eq $true

    if (-not $ublockEnabled) {
        Write-Status "uBlock Origin disabled in config" -Type Detail
        $resultUBlockPath = $null
    }
    if (-not $adguardEnabled) {
        Write-Status "AdGuard Extra disabled in config" -Type Detail
        $resultAdGuardPath = $null
    }

    # Handle dry run mode
    if ($WhatIfPreference) {
        if ($ublockEnabled) { Write-Status "Would check/download uBlock Origin" -Type Detail }
        if ($adguardEnabled) { Write-Status "Would check/download AdGuard Extra" -Type Detail }
        return @{ UBlockPath = $resultUBlockPath; AdGuardExtraPath = $resultAdGuardPath }
    }

    # Process pre-downloaded extensions first (from parallel download with installer)
    $ublockHandled = $false
    $adguardHandled = $false

    if ($PreDownloadedUBlock -and (Test-Path $PreDownloadedUBlock) -and $ublockEnabled) {
        Write-Status "Installing pre-downloaded uBlock Origin..." -Type Detail
        try {
            if (Test-Path $UBlockPath) {
                Remove-Item -Path $UBlockPath -Recurse -Force
            }
            $null = Export-CrxToDirectory -CrxPath $PreDownloadedUBlock -OutputDir $UBlockPath -InjectKey
            # Configure uBlock (add auto-import.js, patch start.js, etc.)
            $null = Get-UBlockOrigin -OutputDir $UBlockPath -UBlockConfig $Config.ublock -SkipDownload
            Write-Status "uBlock Origin installed" -Type Success
            $ublockHandled = $true
        }
        finally {
            Remove-Item -Path $PreDownloadedUBlock -Force -ErrorAction SilentlyContinue
        }
    }

    if ($PreDownloadedAdGuard -and (Test-Path $PreDownloadedAdGuard) -and $adguardEnabled) {
        Write-Status "Installing pre-downloaded AdGuard Extra..." -Type Detail
        try {
            if (Test-Path $AdGuardExtraPath) {
                Remove-Item -Path $AdGuardExtraPath -Recurse -Force
            }
            $null = Export-CrxToDirectory -CrxPath $PreDownloadedAdGuard -OutputDir $AdGuardExtraPath -InjectKey
            Write-Status "AdGuard Extra installed" -Type Success
            $adguardHandled = $true
        }
        finally {
            Remove-Item -Path $PreDownloadedAdGuard -Force -ErrorAction SilentlyContinue
        }
    }

    # If all enabled extensions were handled by pre-download, we're done
    if ((-not $ublockEnabled -or $ublockHandled) -and (-not $adguardEnabled -or $adguardHandled)) {
        return @{ UBlockPath = $resultUBlockPath; AdGuardExtraPath = $resultAdGuardPath }
    }

    # Build list of extensions to check (only those not already handled)
    $extensionsToCheck = @()
    if ($ublockEnabled -and -not $ublockHandled) {
        $ublockManifest = Join-Path $UBlockPath "manifest.json"
        $ublockCurrentVer = if ((Test-Path $UBlockPath) -and (Test-Path $ublockManifest)) {
            (Get-JsonFile -Path $ublockManifest).version
        } else { $null }

        $extensionsToCheck += @{
            Name = "uBlock Origin"
            Id = $Config.ublock.extension_id
            OutputDir = $UBlockPath
            CurrentVersion = $ublockCurrentVer
            Config = $Config.ublock
            Type = "ublock"
        }
    }
    if ($adguardEnabled -and -not $adguardHandled) {
        $adguardManifest = Join-Path $AdGuardExtraPath "manifest.json"
        $adguardCurrentVer = if ((Test-Path $AdGuardExtraPath) -and (Test-Path $adguardManifest)) {
            (Get-JsonFile -Path $adguardManifest).version
        } else { $null }

        $extensionsToCheck += @{
            Name = "AdGuard Extra"
            Id = $Config.adguard_extra.extension_id
            OutputDir = $AdGuardExtraPath
            CurrentVersion = $adguardCurrentVer
            Config = $Config.adguard_extra
            Type = "adguard"
        }
    }

    # If no extensions left to check, we're done
    if ($extensionsToCheck.Count -eq 0) {
        return @{ UBlockPath = $resultUBlockPath; AdGuardExtraPath = $resultAdGuardPath }
    }

    # If only one extension or none, use sequential path
    if ($extensionsToCheck.Count -le 1) {
        if ($ublockEnabled -and -not $ublockHandled) {
            $null = Get-UBlockOrigin -OutputDir $UBlockPath -UBlockConfig $Config.ublock -ForceDownload:$Force
        }
        if ($adguardEnabled -and -not $adguardHandled) {
            $null = Get-AdGuardExtra -OutputDir $AdGuardExtraPath -AdGuardConfig $Config.adguard_extra -ForceDownload:$Force
        }
        return @{ UBlockPath = $resultUBlockPath; AdGuardExtraPath = $resultAdGuardPath }
    }

    # Both extensions enabled - check versions and download in parallel if needed
    Write-Status "Checking versions for uBlock Origin and AdGuard Extra..." -Type Detail

    # Parallel version check using runspaces (inlined web request)
    $versionCheckScript = {
        param($ExtensionId)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $url = "https://clients2.google.com/service/update2/crx?response=updatecheck&os=win&arch=x86-64&os_arch=x86-64&prod=chromecrx&prodchannel=unknown&prodversion=120.0.0.0&acceptformat=crx3&x=id%3D$ExtensionId%26v%3D0.0.0%26uc"
            $wc = New-Object System.Net.WebClient
            $content = $wc.DownloadString($url)
            [xml]$xml = $content
            $updatecheck = $xml.gupdate.app.updatecheck
            if ($updatecheck -and $updatecheck.status -eq "ok" -and $updatecheck.version) {
                return @{ Id = $ExtensionId; Version = $updatecheck.version; Success = $true }
            }
            return @{ Id = $ExtensionId; Version = $null; Success = $false }
        }
        catch {
            return @{ Id = $ExtensionId; Version = $null; Success = $false; Error = $_.Exception.Message }
        }
    }

    $versionTasks = @()
    foreach ($ext in $extensionsToCheck) {
        $versionTasks += @{ Script = $versionCheckScript; Args = @($ext.Id) }
    }

    $versionResults = Invoke-Parallel -Tasks $versionTasks -MaxThreads 2

    # Map version results back to extensions
    $extensionsNeedingDownload = @()
    foreach ($ext in $extensionsToCheck) {
        $versionResult = $versionResults | Where-Object { $_.Id -eq $ext.Id } | Select-Object -First 1
        $latestVersion = if ($versionResult -and $versionResult.Success) { $versionResult.Version } else { $null }

        if (-not $latestVersion) {
            Write-Status "Could not get version for $($ext.Name)" -Type Warning
            continue
        }

        $needsDownload = $Force -or (-not $ext.CurrentVersion) -or
            ((Compare-Versions -Version1 $latestVersion -Version2 $ext.CurrentVersion) -gt 0)

        if ($needsDownload) {
            $currentVerDisplay = if ($ext.CurrentVersion) { $ext.CurrentVersion } else { 'not installed' }
            Write-Status "$($ext.Name): $currentVerDisplay -> $latestVersion" -Type Info
            $ext.LatestVersion = $latestVersion
            $extensionsNeedingDownload += $ext
        }
        else {
            Write-Status "$($ext.Name) is up to date ($($ext.CurrentVersion))" -Type Success
        }
    }

    # Parallel download if multiple extensions need it
    if ($extensionsNeedingDownload.Count -gt 1) {
        Write-Status "Downloading extensions in parallel..." -Type Detail

        $downloadScript = {
            param($ExtensionId, $Version, $TempDir)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $downloadUrl = "https://clients2.google.com/service/update2/crx?response=redirect&os=win&arch=x86-64&os_arch=x86-64&prod=chromecrx&prodchannel=unknown&prodversion=120.0.0.0&acceptformat=crx3&x=id%3D$ExtensionId%26uc"
                $outFile = Join-Path $TempDir "$ExtensionId`_$Version.crx"
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                $wc.Headers.Add("Referer", "https://chrome.google.com/webstore/detail/$ExtensionId")
                $wc.DownloadFile($downloadUrl, $outFile)
                if ((Get-Item $outFile -ErrorAction SilentlyContinue).Length -gt 0) {
                    return @{ Id = $ExtensionId; CrxPath = $outFile; Success = $true }
                }
                return @{ Id = $ExtensionId; CrxPath = $null; Success = $false; Error = "Empty file" }
            }
            catch {
                return @{ Id = $ExtensionId; CrxPath = $null; Success = $false; Error = $_.Exception.Message }
            }
        }

        $tempDir = Join-Path $env:TEMP "meteor_adblock_$(Get-Random)"
        New-DirectoryIfNotExists -Path $tempDir

        $downloadTasks = @()
        foreach ($ext in $extensionsNeedingDownload) {
            $downloadTasks += @{ Script = $downloadScript; Args = @($ext.Id, $ext.LatestVersion, $tempDir) }
        }

        $downloadResults = Invoke-Parallel -Tasks $downloadTasks -MaxThreads 2

        # Process download results and extract/configure sequentially
        foreach ($ext in $extensionsNeedingDownload) {
            $downloadResult = $downloadResults | Where-Object { $_.Id -eq $ext.Id } | Select-Object -First 1

            if ($downloadResult -and $downloadResult.Success -and $downloadResult.CrxPath) {
                Write-Status "Downloaded $($ext.Name), extracting..." -Type Detail

                # Extract CRX
                if (Test-Path $ext.OutputDir) {
                    Remove-Item $ext.OutputDir -Recurse -Force
                }
                $null = Export-CrxToDirectory -CrxPath $downloadResult.CrxPath -OutputDir $ext.OutputDir -InjectKey

                # Apply uBlock configuration if applicable
                if ($ext.Type -eq "ublock") {
                    $jsDir = Join-Path $ext.OutputDir "js"
                    if ((Test-Path $jsDir) -and $ext.Config.defaults) {
                        # Save settings and create auto-import.js (reuse logic from Get-UBlockOrigin)
                        $settingsPath = Join-Path $ext.OutputDir "ublock-settings.json"
                        Save-JsonFile -Path $settingsPath -Object $ext.Config.defaults -Depth 20
                        Initialize-UBlockAutoImport -UBlockDir $ext.OutputDir -UBlockConfig $ext.Config
                    }
                }

                Write-Status "$($ext.Name) $($ext.LatestVersion) installed" -Type Success
            }
            else {
                $errMsg = if ($downloadResult) { $downloadResult.Error } else { "Unknown error" }
                Write-Status "Failed to download $($ext.Name): $errMsg" -Type Warning
            }
        }

        # Cleanup temp directory
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    elseif ($extensionsNeedingDownload.Count -eq 1) {
        # Single extension needs download - use original functions
        $ext = $extensionsNeedingDownload[0]
        if ($ext.Type -eq "ublock") {
            $null = Get-UBlockOrigin -OutputDir $ext.OutputDir -UBlockConfig $ext.Config -ForceDownload:$Force
        }
        else {
            $null = Get-AdGuardExtra -OutputDir $ext.OutputDir -AdGuardConfig $ext.Config -ForceDownload:$Force
        }
    }

    return @{
        UBlockPath = $resultUBlockPath
        AdGuardExtraPath = $resultAdGuardPath
    }
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
    New-DirectoryIfNotExists -Path $meteorDataPath

    # User data path for browser profile (inside meteorDataPath)
    $userDataPath = Join-Path $meteorDataPath "User Data"

    # Load config
    $configPath = if ($Config) { $Config } else { Join-Path $baseDir "config.json" }
    $config = Get-MeteorConfig -ConfigPath $configPath
    $null = Test-MeteorConfig -Config $config

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

    if ($WhatIfPreference) {
        Write-Status "DRY RUN MODE - No changes will be made" -Type Warning
        Write-Host ""
    }

    # Kill running Comet processes if -Force is specified
    if ($Force) {
        $cometProcesses = Get-Process -Name "comet" -ErrorAction SilentlyContinue
        if ($cometProcesses) {
            if ($WhatIfPreference) {
                Write-Status "Would stop $($cometProcesses.Count) running Comet process(es)" -Type DryRun
            }
            else {
                Write-Status "Stopping $($cometProcesses.Count) running Comet process(es)..." -Type Warning
                $cometProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500  # Brief pause for file handles to release
                Write-Status "Comet processes stopped" -Type Success
            }
        }

        # Delete Comet registry key (contains MACs and other browser state)
        $registryPath = "HKCU:\SOFTWARE\Perplexity\Comet"
        if (Test-Path $registryPath) {
            if ($WhatIfPreference) {
                Write-Status "Would delete registry key: $registryPath" -Type DryRun
            }
            else {
                Remove-Item -Path $registryPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "Deleted Comet registry key" -Type Detail
            }
        }

        # Delete Comet application files (but NOT User Data)
        $cometAppPath = Join-Path $meteorDataPath "comet"
        if (Test-Path $cometAppPath) {
            if ($WhatIfPreference) {
                Write-Status "Would delete Comet application: $cometAppPath" -Type DryRun
            }
            else {
                Remove-Item -Path $cometAppPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "Deleted Comet application files" -Type Detail
            }
        }

        # Delete patched extensions (will be re-extracted)
        $patchedExtForceDelete = Join-Path $meteorDataPath "patched_extensions"
        if (Test-Path $patchedExtForceDelete) {
            if ($WhatIfPreference) {
                Write-Status "Would delete patched extensions: $patchedExtForceDelete" -Type DryRun
            }
            else {
                Remove-Item -Path $patchedExtForceDelete -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "Deleted patched extensions" -Type Detail
            }
        }

        # Delete patched resources (will be re-extracted from PAK)
        $patchedResForceDelete = Join-Path $meteorDataPath "patched_resources"
        if (Test-Path $patchedResForceDelete) {
            if ($WhatIfPreference) {
                Write-Status "Would delete patched resources: $patchedResForceDelete" -Type DryRun
            }
            else {
                Remove-Item -Path $patchedResForceDelete -Recurse -Force -ErrorAction SilentlyContinue
                Write-Status "Deleted patched resources" -Type Detail
            }
        }

        # NOTE: Preferences files are NOT deleted by -Force
        # The script properly updates preferences with MAC calculation, preserving user settings.
        # Deleting Preferences would trigger the first-run path which could lose os_crypt.encrypted_key
        # (the encryption key for cookies and passwords) if Local State was rewritten from scratch.
    }

    # ═══════════════════════════════════════════════════════════════
    # Pre-download Check: Parallelize downloads when we know we'll need them
    # ═══════════════════════════════════════════════════════════════
    # Check if we'll need to download Comet (Force or no existing installation)
    $existingComet = Get-CometInstallation -DataPath $(if ($portableMode) { $meteorDataPath } else { $null })
    $willNeedCometDownload = $Force -or -not $existingComet -or ($portableMode -and $existingComet -and -not $existingComet.Portable)

    # Pre-downloaded paths (if parallel download happens)
    $preDownloadedComet = $null
    $preDownloadedUBlock = $null
    $preDownloadedAdGuard = $null

    if ($willNeedCometDownload -and -not $WhatIfPreference -and $portableMode) {
        # Check if adblock extensions need downloading
        $ublockEnabled = $config.ublock.enabled -eq $true
        $adguardEnabled = $config.adguard_extra.enabled -eq $true

        $ublockNeedsDownload = $false
        $adguardNeedsDownload = $false

        if ($ublockEnabled) {
            $ublockManifest = Join-Path $ublockPath "manifest.json"
            $ublockNeedsDownload = $Force -or -not (Test-Path $ublockManifest)
        }
        if ($adguardEnabled) {
            $adguardManifest = Join-Path $adguardExtraPath "manifest.json"
            $adguardNeedsDownload = $Force -or -not (Test-Path $adguardManifest)
        }

        # If we need to download Comet AND at least one adblock extension, do parallel downloads
        if ($ublockNeedsDownload -or $adguardNeedsDownload) {
            Write-Status "Parallel download: Comet installer + ad-block extensions" -Type Info

            $downloadTasks = @()

            # Comet installer download task
            $cometTempPath = Join-Path $env:TEMP "meteor_comet_$(Get-Random).exe"
            $cometDownloadScript = {
                param($Url, $TempPath)
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0")
                    $wc.DownloadFile($Url, $TempPath)
                    $wc.Dispose()
                    return @{ Success = $true; Type = "comet"; Path = $TempPath }
                }
                catch {
                    return @{ Success = $false; Type = "comet"; Error = $_.ToString() }
                }
            }
            $downloadTasks += @{ Script = $cometDownloadScript; Args = @($config.comet.download_url, $cometTempPath) }

            # uBlock download task
            if ($ublockNeedsDownload) {
                $ublockTempPath = Join-Path $env:TEMP "meteor_ublock_$(Get-Random).crx"
                $extensionDownloadScript = {
                    param($ExtId, $TempPath, $ExtType)
                    try {
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                        $url = "https://clients2.google.com/service/update2/crx?response=redirect&os=win&arch=x86-64&os_arch=x86-64&prod=chromecrx&prodchannel=unknown&prodversion=120.0.0.0&acceptformat=crx3&x=id%3D$ExtId%26uc"
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0")
                        $wc.DownloadFile($url, $TempPath)
                        $wc.Dispose()
                        return @{ Success = $true; Type = $ExtType; Path = $TempPath }
                    }
                    catch {
                        return @{ Success = $false; Type = $ExtType; Error = $_.ToString() }
                    }
                }
                $downloadTasks += @{ Script = $extensionDownloadScript; Args = @($config.ublock.extension_id, $ublockTempPath, "ublock") }
            }

            # AdGuard download task
            if ($adguardNeedsDownload) {
                $adguardTempPath = Join-Path $env:TEMP "meteor_adguard_$(Get-Random).crx"
                $extensionDownloadScript = {
                    param($ExtId, $TempPath, $ExtType)
                    try {
                        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                        $url = "https://clients2.google.com/service/update2/crx?response=redirect&os=win&arch=x86-64&os_arch=x86-64&prod=chromecrx&prodchannel=unknown&prodversion=120.0.0.0&acceptformat=crx3&x=id%3D$ExtId%26uc"
                        $wc = New-Object System.Net.WebClient
                        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0")
                        $wc.DownloadFile($url, $TempPath)
                        $wc.Dispose()
                        return @{ Success = $true; Type = $ExtType; Path = $TempPath }
                    }
                    catch {
                        return @{ Success = $false; Type = $ExtType; Error = $_.ToString() }
                    }
                }
                $downloadTasks += @{ Script = $extensionDownloadScript; Args = @($config.adguard_extra.extension_id, $adguardTempPath, "adguard") }
            }

            Write-Status "Downloading $($downloadTasks.Count) file(s) in parallel..." -Type Detail
            $downloadResults = Invoke-Parallel -Tasks $downloadTasks -MaxThreads $downloadTasks.Count

            foreach ($result in $downloadResults) {
                if ($result.Success) {
                    switch ($result.Type) {
                        "comet" { $preDownloadedComet = $result.Path; Write-Status "  Comet installer downloaded" -Type Detail }
                        "ublock" { $preDownloadedUBlock = $result.Path; Write-Status "  uBlock Origin downloaded" -Type Detail }
                        "adguard" { $preDownloadedAdGuard = $result.Path; Write-Status "  AdGuard Extra downloaded" -Type Detail }
                    }
                }
                else {
                    Write-Status "  $($result.Type) download failed: $($result.Error)" -Type Warning
                }
            }
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 0: Comet Installation
    # ═══════════════════════════════════════════════════════════════
    $installResult = Initialize-CometInstallation -Config $config -MeteorDataPath $meteorDataPath -PortableMode:$portableMode -Force:$Force -PreDownloadedInstaller $preDownloadedComet
    if ($null -eq $installResult -and -not $WhatIfPreference) {
        exit 1
    }
    $comet = $installResult.Comet
    $cometVersion = $installResult.CometVersion
    $freshInstall = $installResult.FreshInstall

    # ═══════════════════════════════════════════════════════════════
    # Start Adblock Installation in Background (runs parallel with Steps 1-4)
    # ═══════════════════════════════════════════════════════════════
    $adblockTask = $null
    $ublockEnabled = $config.ublock.enabled -eq $true
    $adguardEnabled = $config.adguard_extra.enabled -eq $true

    if (-not $WhatIfPreference -and -not $NoLaunch -and ($ublockEnabled -or $adguardEnabled)) {
        # Self-contained scriptblock for adblock installation (runspaces can't access main script functions)
        $adblockScript = {
            param(
                [string]$UBlockPath,
                [string]$AdGuardPath,
                [string]$PreDownloadedUBlock,
                [string]$PreDownloadedAdGuard,
                [bool]$UBlockEnabled,
                [bool]$AdGuardEnabled,
                [string]$UBlockExtensionId,
                [string]$AdGuardExtensionId,
                [object]$UBlockDefaults,
                [bool]$ForceDownload
            )

            # Helper: Read protobuf varint
            function Read-InlineVarint {
                param([byte[]]$Bytes, [int]$Pos)
                $result = 0
                $shift = 0
                while ($Pos -lt $Bytes.Length) {
                    $b = $Bytes[$Pos]
                    $Pos++
                    $result = $result -bor (($b -band 0x7F) -shl $shift)
                    if (($b -band 0x80) -eq 0) { break }
                    $shift += 7
                }
                return @{ Value = $result; Pos = $Pos }
            }

            # Helper: Extract public key from CRX (handles CRX2 and CRX3)
            function Get-InlineCrxPublicKey {
                param([byte[]]$Bytes)
                $version = [BitConverter]::ToUInt32($Bytes, 4)

                if ($version -eq 2) {
                    # CRX2: public key at offset 16
                    $pubkeyLen = [BitConverter]::ToUInt32($Bytes, 8)
                    if ($pubkeyLen -eq 0) { return $null }
                    $pubkey = New-Object byte[] $pubkeyLen
                    [Array]::Copy($Bytes, 16, $pubkey, 0, $pubkeyLen)
                    return [Convert]::ToBase64String($pubkey)
                }
                else {
                    # CRX3: Parse protobuf header
                    $headerLen = [BitConverter]::ToUInt32($Bytes, 8)
                    $headerStart = 12
                    $headerEnd = $headerStart + $headerLen
                    $keys = [System.Collections.ArrayList]@()
                    $crxId = $null
                    $pos = $headerStart

                    while ($pos -lt $headerEnd) {
                        $r = Read-InlineVarint -Bytes $Bytes -Pos $pos
                        $tag = $r.Value; $pos = $r.Pos
                        $fieldNum = $tag -shr 3
                        $wireType = $tag -band 0x07

                        if ($wireType -eq 2) {
                            $r = Read-InlineVarint -Bytes $Bytes -Pos $pos
                            $len = $r.Value; $pos = $r.Pos
                            $fieldEnd = $pos + $len

                            if ($fieldNum -in @(2, 3)) {
                                # sha256_with_rsa or sha256_with_ecdsa - extract public_key
                                $nestedPos = $pos
                                while ($nestedPos -lt $fieldEnd) {
                                    $r = Read-InlineVarint -Bytes $Bytes -Pos $nestedPos
                                    $nestedTag = $r.Value; $nestedPos = $r.Pos
                                    if (($nestedTag -band 0x07) -eq 2) {
                                        $r = Read-InlineVarint -Bytes $Bytes -Pos $nestedPos
                                        $nestedLen = $r.Value; $nestedPos = $r.Pos
                                        if (($nestedTag -shr 3) -eq 1) {
                                            $pubkey = New-Object byte[] $nestedLen
                                            [Array]::Copy($Bytes, $nestedPos, $pubkey, 0, $nestedLen)
                                            [void]$keys.Add($pubkey)
                                        }
                                        $nestedPos += $nestedLen
                                    } else { break }
                                }
                            }
                            elseif ($fieldNum -eq 10000) {
                                # signed_header_data - contains crx_id
                                $nestedPos = $pos
                                $r = Read-InlineVarint -Bytes $Bytes -Pos $nestedPos
                                $nestedTag = $r.Value; $nestedPos = $r.Pos
                                if (($nestedTag -band 0x07) -eq 2 -and ($nestedTag -shr 3) -eq 1) {
                                    $r = Read-InlineVarint -Bytes $Bytes -Pos $nestedPos
                                    $crxIdLen = $r.Value; $nestedPos = $r.Pos
                                    $crxId = New-Object byte[] $crxIdLen
                                    [Array]::Copy($Bytes, $nestedPos, $crxId, 0, $crxIdLen)
                                }
                            }
                            $pos = $fieldEnd
                        }
                        elseif ($wireType -eq 0) { $r = Read-InlineVarint -Bytes $Bytes -Pos $pos; $pos = $r.Pos }
                        elseif ($wireType -eq 1) { $pos += 8 }
                        elseif ($wireType -eq 5) { $pos += 4 }
                        else { break }
                    }

                    # Find key matching CRX ID
                    if ($crxId -and $keys.Count -gt 0) {
                        $crxIdHex = [BitConverter]::ToString($crxId).Replace("-", "").ToLower()
                        foreach ($key in $keys) {
                            $sha = [System.Security.Cryptography.SHA256]::Create()
                            try {
                                $hash = $sha.ComputeHash($key)
                                $hashHex = [BitConverter]::ToString($hash[0..15]).Replace("-", "").ToLower()
                                if ($hashHex -eq $crxIdHex) { return [Convert]::ToBase64String($key) }
                            } finally { $sha.Dispose() }
                        }
                    }
                    if ($keys.Count -gt 0) { return [Convert]::ToBase64String($keys[0]) }
                    return $null
                }
            }

            # Helper: Get CRX ZIP offset (inline version)
            function Get-InlineCrxZipOffset {
                param([byte[]]$Bytes)
                $version = [BitConverter]::ToUInt32($Bytes, 4)
                if ($version -eq 2) {
                    $pubkeyLen = [BitConverter]::ToUInt32($Bytes, 8)
                    $sigLen = [BitConverter]::ToUInt32($Bytes, 12)
                    return (16 + $pubkeyLen + $sigLen)
                }
                else {
                    $headerLen = [BitConverter]::ToUInt32($Bytes, 8)
                    return (12 + $headerLen)
                }
            }

            # Helper: Extract CRX to directory with key injection
            function Extract-InlineCrx {
                param([string]$CrxPath, [string]$OutputDir)
                $bytes = [System.IO.File]::ReadAllBytes($CrxPath)

                # Validate CRX magic
                if ($bytes.Length -lt 16 -or $bytes[0] -ne 0x43 -or $bytes[1] -ne 0x72 -or $bytes[2] -ne 0x32 -or $bytes[3] -ne 0x34) {
                    throw "Invalid CRX magic"
                }

                # Extract public key before extracting ZIP
                $publicKey = Get-InlineCrxPublicKey -Bytes $bytes

                $zipOffset = Get-InlineCrxZipOffset -Bytes $bytes
                $zipLength = $bytes.Length - $zipOffset
                $zipBytes = New-Object byte[] $zipLength
                [Array]::Copy($bytes, $zipOffset, $zipBytes, 0, $zipLength)

                # Validate ZIP magic
                if ($zipBytes.Length -lt 4 -or $zipBytes[0] -ne 0x50 -or $zipBytes[1] -ne 0x4B) {
                    throw "Invalid ZIP magic in CRX"
                }

                # Write to temp file and extract using .NET
                $tempZip = Join-Path $env:TEMP "meteor_adblock_$(Get-Random).zip"
                try {
                    [System.IO.File]::WriteAllBytes($tempZip, $zipBytes)
                    if (Test-Path $OutputDir) { Remove-Item -Path $OutputDir -Recurse -Force }
                    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $OutputDir)
                }
                finally {
                    if (Test-Path $tempZip) { Remove-Item -Path $tempZip -Force }
                }

                # Inject public key into manifest.json
                if ($publicKey) {
                    $manifestPath = Join-Path $OutputDir "manifest.json"
                    if (Test-Path $manifestPath) {
                        $manifestContent = Get-Content -Path $manifestPath -Raw -Encoding UTF8
                        $manifest = $manifestContent | ConvertFrom-Json
                        $manifest | Add-Member -NotePropertyName "key" -NotePropertyValue $publicKey -Force
                        $manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8
                    }
                }
                return $true
            }

            # Helper: Download CRX from Chrome Web Store
            function Download-InlineCrx {
                param([string]$ExtensionId, [string]$OutputPath)
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $url = "https://clients2.google.com/service/update2/crx?response=redirect&os=win&arch=x86-64&os_arch=x86-64&prod=chromecrx&prodchannel=unknown&prodversion=120.0.0.0&acceptformat=crx3&x=id%3D$ExtensionId%26uc"
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0")
                $wc.DownloadFile($url, $OutputPath)
                $wc.Dispose()
            }

            # Helper: Configure uBlock auto-import
            function Configure-InlineUBlock {
                param([string]$UBlockDir, [object]$Defaults)
                $jsDir = Join-Path $UBlockDir "js"
                if (-not (Test-Path $jsDir) -or -not $Defaults) { return }

                # Get custom filter lists
                $customLists = @($Defaults.selectedFilterLists | Where-Object { $_ -match '^https?://' })
                $customListsJson = if ($customLists.Count -gt 0) { $customLists | ConvertTo-Json -Compress } else { "[]" }

                # Create auto-import.js
                $autoImportPath = Join-Path $jsDir "auto-import.js"
                $autoImportCode = @"
/*******************************************************************************
    Meteor - Auto-import custom defaults on first run
*******************************************************************************/
import µb from './background.js';
import io from './assets.js';
const customFilterLists = $customListsJson;
const checkAndImport = async () => {
    try {
        await µb.isReadyPromise;
        const stored = await vAPI.storage.get(['lastRestoreFile', 'importedLists']);
        if (stored.lastRestoreFile === 'meteor-auto-import') { return; }
        const importedLists = stored.importedLists || [];
        const allPresent = customFilterLists.every(url => importedLists.includes(url));
        if (allPresent) { return; }
        const response = await fetch('/ublock-settings.json');
        if (!response.ok) { return; }
        const userData = await response.json();
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
        if (userData.userFilters) { await µb.saveUserFilters(userData.userFilters); }
        if (Array.isArray(userData.selectedFilterLists)) { await µb.saveSelectedFilterLists(userData.selectedFilterLists); }
        vAPI.app.restart();
    } catch (ex) { }
};
setTimeout(checkAndImport, 3000);
"@
                Set-Content -Path $autoImportPath -Value $autoImportCode -Encoding UTF8

                # Patch start.js
                $startJsPath = Join-Path $jsDir "start.js"
                if (Test-Path $startJsPath) {
                    $startContent = Get-Content -Path $startJsPath -Raw
                    if ($startContent -notmatch "import './auto-import.js';") {
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

                # Save settings JSON
                $settingsPath = Join-Path $UBlockDir "ublock-settings.json"
                $Defaults | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding UTF8
            }

            $result = @{ UBlockPath = $null; AdGuardPath = $null; Success = $true; Error = $null }

            try {
                # Process uBlock Origin
                if ($UBlockEnabled) {
                    $ublockManifest = Join-Path $UBlockPath "manifest.json"
                    $needsInstall = $ForceDownload -or -not (Test-Path $ublockManifest)

                    if ($needsInstall) {
                        $crxPath = $PreDownloadedUBlock
                        if (-not $crxPath -or -not (Test-Path $crxPath)) {
                            $crxPath = Join-Path $env:TEMP "meteor_ublock_bg_$(Get-Random).crx"
                            Download-InlineCrx -ExtensionId $UBlockExtensionId -OutputPath $crxPath
                        }
                        Extract-InlineCrx -CrxPath $crxPath -OutputDir $UBlockPath
                        if ($PreDownloadedUBlock -and (Test-Path $PreDownloadedUBlock)) {
                            Remove-Item -Path $PreDownloadedUBlock -Force -ErrorAction SilentlyContinue
                        }
                        elseif (Test-Path $crxPath) {
                            Remove-Item -Path $crxPath -Force -ErrorAction SilentlyContinue
                        }
                    }

                    # Configure uBlock
                    Configure-InlineUBlock -UBlockDir $UBlockPath -Defaults $UBlockDefaults
                    $result.UBlockPath = $UBlockPath
                }

                # Process AdGuard Extra
                if ($AdGuardEnabled) {
                    $adguardManifest = Join-Path $AdGuardPath "manifest.json"
                    $needsInstall = $ForceDownload -or -not (Test-Path $adguardManifest)

                    if ($needsInstall) {
                        $crxPath = $PreDownloadedAdGuard
                        if (-not $crxPath -or -not (Test-Path $crxPath)) {
                            $crxPath = Join-Path $env:TEMP "meteor_adguard_bg_$(Get-Random).crx"
                            Download-InlineCrx -ExtensionId $AdGuardExtensionId -OutputPath $crxPath
                        }
                        Extract-InlineCrx -CrxPath $crxPath -OutputDir $AdGuardPath
                        if ($PreDownloadedAdGuard -and (Test-Path $PreDownloadedAdGuard)) {
                            Remove-Item -Path $PreDownloadedAdGuard -Force -ErrorAction SilentlyContinue
                        }
                        elseif (Test-Path $crxPath) {
                            Remove-Item -Path $crxPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $result.AdGuardPath = $AdGuardPath
                }
            }
            catch {
                $result.Success = $false
                $result.Error = $_.ToString()
            }

            return $result
        }

        # Convert uBlock defaults to hashtable for serialization
        $ublockDefaults = $null
        if ($config.ublock.defaults) {
            $ublockDefaults = @{}
            foreach ($prop in $config.ublock.defaults.PSObject.Properties) {
                $ublockDefaults[$prop.Name] = $prop.Value
            }
        }

        Write-Status "Starting adblock installation in background..." -Type Detail
        $adblockTask = Start-BackgroundRunspace -Script $adblockScript -Args @(
            $ublockPath,
            $adguardExtraPath,
            $preDownloadedUBlock,
            $preDownloadedAdGuard,
            $ublockEnabled,
            $adguardEnabled,
            $config.ublock.extension_id,
            $config.adguard_extra.extension_id,
            $ublockDefaults,
            $Force
        )
    }

    # ═══════════════════════════════════════════════════════════════
    # Start PAK Modifications in Background (runs parallel with Steps 1-4)
    # ═══════════════════════════════════════════════════════════════
    $pakTask = $null
    $pakEnabled = $config.pak_modifications.enabled -eq $true
    $pakHasModifications = $config.pak_modifications.modifications -and @($config.pak_modifications.modifications).Count -gt 0

    if (-not $WhatIfPreference -and -not $SkipPak -and $comet -and $pakEnabled -and $pakHasModifications) {
        # Self-contained scriptblock for PAK processing (runspaces can't access main script functions)
        $pakScript = {
            param(
                [string]$CometDir,
                [hashtable]$PakConfig,
                [hashtable]$PakState,
                [bool]$Force
            )

            $result = @{
                Success               = $false
                Skipped               = $false
                HashAfterModification = $null
                ModifiedResourceIds   = @()
                ModificationConfigHash = $null
                Error                 = $null
            }

            try {
                # Helper: Read little-endian integers
                function Read-UInt32 { param([byte[]]$B, [int]$O) [BitConverter]::ToUInt32($B, $O) }
                function Read-UInt16 { param([byte[]]$B, [int]$O) [BitConverter]::ToUInt16($B, $O) }
                function Write-UInt32 { param([uint32]$V) [BitConverter]::GetBytes($V) }
                function Write-UInt16 { param([uint16]$V) [BitConverter]::GetBytes($V) }

                # Helper: Expand gzip (returns $null on failure)
                function Expand-Gzip {
                    param([byte[]]$Bytes)
                    $inStream = $null; $gzStream = $null; $outStream = $null
                    try {
                        $inStream = New-Object System.IO.MemoryStream($Bytes, $false)
                        $gzStream = New-Object System.IO.Compression.GZipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
                        $outStream = New-Object System.IO.MemoryStream
                        $gzStream.CopyTo($outStream)
                        return $outStream.ToArray()
                    } catch { return $null }
                    finally {
                        if ($gzStream) { $gzStream.Dispose() }
                        if ($outStream) { $outStream.Dispose() }
                    }
                }

                # Helper: Compress gzip (throws on failure)
                function Compress-Gzip {
                    param([byte[]]$Bytes)
                    $outStream = $null; $gzStream = $null
                    try {
                        $outStream = New-Object System.IO.MemoryStream
                        $gzStream = New-Object System.IO.Compression.GZipStream($outStream, [System.IO.Compression.CompressionMode]::Compress)
                        $gzStream.Write($Bytes, 0, $Bytes.Length)
                        $gzStream.Close()
                        return $outStream.ToArray()
                    }
                    finally {
                        if ($gzStream) { $gzStream.Dispose() }
                        if ($outStream) { $outStream.Dispose() }
                    }
                }

                # Helper: Test binary content
                function Test-Binary {
                    param([byte[]]$Bytes)
                    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $false }
                    $len = [Math]::Min($Bytes.Length, 8192)
                    for ($i = 0; $i -lt $len; $i++) {
                        $b = $Bytes[$i]
                        if ($b -eq 0 -or ($b -lt 32 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13)) { return $true }
                    }
                    return $false
                }

                # Helper: Find version directory
                function Find-VersionDir {
                    param([string]$Path)
                    if (-not (Test-Path $Path)) { return $null }
                    $dirs = @(Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
                        Sort-Object { [Version]($_.Name -replace '^(\d+\.\d+\.\d+\.\d+).*', '$1') } -Descending)
                    if ($dirs.Count -gt 0) { return $dirs[0] }
                    return $null
                }

                # Helper: Get file hash
                function Get-Hash {
                    param([string]$Path)
                    if (-not (Test-Path $Path)) { return $null }
                    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
                }

                # Helper: Get string hash
                function Get-StrHash {
                    param([string]$Content)
                    $sha = [System.Security.Cryptography.SHA256]::Create()
                    try {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
                        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
                    } finally { $sha.Dispose() }
                }

                # Helper: Sort object for consistent hashing
                function Sort-Obj {
                    param([object]$Value)
                    if ($null -eq $Value) { return $null }
                    if ($Value -is [hashtable]) {
                        $sorted = [ordered]@{}
                        foreach ($key in ($Value.Keys | Sort-Object)) {
                            $sorted[$key] = Sort-Obj -Value $Value[$key]
                        }
                        return $sorted
                    }
                    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
                        $arr = [System.Collections.ArrayList]@()
                        foreach ($item in $Value) { [void]$arr.Add((Sort-Obj -Value $item)) }
                        return ,$arr
                    }
                    return $Value
                }

                # Helper: Read PAK file
                function Read-Pak {
                    param([string]$Path)
                    $bytes = [System.IO.File]::ReadAllBytes($Path)
                    $version = Read-UInt32 -B $bytes -O 0
                    if ($version -ne 4 -and $version -ne 5) { throw "Unsupported PAK version: $version" }

                    $pak = @{
                        Version = $version; Encoding = $bytes[4]
                        Resources = [System.Collections.ArrayList]@()
                        Aliases = [System.Collections.ArrayList]@()
                        RawBytes = $bytes
                    }
                    $offset = 5
                    if ($version -eq 4) {
                        $numResources = Read-UInt32 -B $bytes -O $offset; $offset += 4; $numAliases = 0
                    } else {
                        $offset += 3
                        $numResources = Read-UInt16 -B $bytes -O $offset; $offset += 2
                        $numAliases = Read-UInt16 -B $bytes -O $offset; $offset += 2
                    }
                    for ($i = 0; $i -le $numResources; $i++) {
                        $resId = Read-UInt16 -B $bytes -O $offset
                        $resOffset = Read-UInt32 -B $bytes -O ($offset + 2)
                        [void]$pak.Resources.Add(@{ Id = $resId; Offset = $resOffset })
                        $offset += 6
                    }
                    if ($version -eq 5 -and $numAliases -gt 0) {
                        for ($i = 0; $i -lt $numAliases; $i++) {
                            $aliasId = Read-UInt16 -B $bytes -O $offset
                            $aliasIndex = Read-UInt16 -B $bytes -O ($offset + 2)
                            [void]$pak.Aliases.Add(@{ Id = $aliasId; ResourceIndex = $aliasIndex })
                            $offset += 4
                        }
                    }
                    $pak.DataStartOffset = $offset
                    $resourceIndex = @{}
                    for ($i = 0; $i -lt $pak.Resources.Count; $i++) {
                        $resourceIndex[[int]$pak.Resources[$i].Id] = $i
                    }
                    $pak.ResourceIndex = $resourceIndex
                    return $pak
                }

                # Helper: Get PAK resource
                function Get-Resource {
                    param([hashtable]$Pak, [int]$Id)
                    if ($Pak.ResourceIndex -and $Pak.ResourceIndex.ContainsKey($Id)) {
                        $i = $Pak.ResourceIndex[$Id]
                        if ($i -ge $Pak.Resources.Count - 1) { return $null }
                        $startOffset = $Pak.Resources[$i].Offset
                        $endOffset = $Pak.Resources[$i + 1].Offset
                        $length = $endOffset - $startOffset
                        $data = New-Object byte[] $length
                        [Array]::Copy($Pak.RawBytes, $startOffset, $data, 0, $length)
                        return ,$data
                    }
                    return $null
                }

                # Helper: Write PAK with modifications using FileStream
                function Write-PakMod {
                    param([hashtable]$Pak, [string]$Path, [hashtable]$Mods)

                    $numResources = $Pak.Resources.Count - 1

                    # Calculate header size
                    if ($Pak.Version -eq 4) {
                        $headerSize = 4 + 1 + 4
                    } else {
                        $headerSize = 4 + 1 + 3 + 2 + 2
                    }

                    $resourceTableSize = $Pak.Resources.Count * 6
                    $aliasTableSize = $Pak.Aliases.Count * 4
                    $dataStartOffset = $headerSize + $resourceTableSize + $aliasTableSize

                    # Calculate offsets and track modifications
                    $currentDataOffset = $dataStartOffset
                    $resourceInfo = @{}

                    for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
                        $resourceId = $Pak.Resources[$i].Id
                        $startOffset = $Pak.Resources[$i].Offset
                        $endOffset = $Pak.Resources[$i + 1].Offset
                        $originalLength = $endOffset - $startOffset

                        if ($Mods.ContainsKey($resourceId)) {
                            $resourceInfo[$i] = @{ NewOffset = $currentDataOffset; ModData = $Mods[$resourceId] }
                            $currentDataOffset += $Mods[$resourceId].Length
                        } else {
                            $resourceInfo[$i] = @{ NewOffset = $currentDataOffset; SrcOff = $startOffset; Len = $originalLength }
                            $currentDataOffset += $originalLength
                        }
                    }
                    $sentinelOffset = $currentDataOffset

                    # Write directly to FileStream
                    $fs = [System.IO.File]::Create($Path)
                    try {
                        # Header
                        $fs.Write((Write-UInt32 -V $Pak.Version), 0, 4)
                        $fs.WriteByte($Pak.Encoding)

                        if ($Pak.Version -eq 4) {
                            $fs.Write((Write-UInt32 -V $numResources), 0, 4)
                        } else {
                            $fs.WriteByte(0); $fs.WriteByte(0); $fs.WriteByte(0)
                            $fs.Write((Write-UInt16 -V ([uint16]$numResources)), 0, 2)
                            $fs.Write((Write-UInt16 -V ([uint16]$Pak.Aliases.Count)), 0, 2)
                        }

                        # Resource table
                        for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
                            $fs.Write((Write-UInt16 -V ([uint16]$Pak.Resources[$i].Id)), 0, 2)
                            $fs.Write((Write-UInt32 -V ([uint32]$resourceInfo[$i].NewOffset)), 0, 4)
                        }
                        # Sentinel
                        $fs.Write((Write-UInt16 -V ([uint16]$Pak.Resources[$Pak.Resources.Count - 1].Id)), 0, 2)
                        $fs.Write((Write-UInt32 -V ([uint32]$sentinelOffset)), 0, 4)

                        # Aliases
                        foreach ($alias in $Pak.Aliases) {
                            $fs.Write((Write-UInt16 -V ([uint16]$alias.Id)), 0, 2)
                            $fs.Write((Write-UInt16 -V ([uint16]$alias.ResourceIndex)), 0, 2)
                        }

                        # Resource data - direct writes without intermediate copy
                        for ($i = 0; $i -lt $Pak.Resources.Count - 1; $i++) {
                            if ($null -ne $resourceInfo[$i].ModData) {  # Explicit null check
                                $d = [byte[]]$resourceInfo[$i].ModData
                                $fs.Write($d, 0, $d.Length)
                            } else {
                                $fs.Write($Pak.RawBytes, $resourceInfo[$i].SrcOff, $resourceInfo[$i].Len)
                            }
                        }
                    }
                    finally {
                        $fs.Close()
                        $fs.Dispose()
                    }
                }

                # 1. Locate resources.pak
                $pakPath = Join-Path $CometDir "resources.pak"
                if (-not (Test-Path $pakPath)) {
                    $versionDir = Find-VersionDir -Path $CometDir
                    if ($versionDir) {
                        $testPath = Join-Path $versionDir.FullName "resources.pak"
                        if (Test-Path $testPath) { $pakPath = $testPath }
                    }
                }
                if (-not (Test-Path $pakPath)) {
                    $result.Success = $true; $result.Skipped = $true
                    return $result
                }

                # 2. Restore from backup if Force
                $backupPath = "$pakPath.meteor-backup"
                if ($Force -and (Test-Path $backupPath)) {
                    Copy-Item -Path $backupPath -Destination $pakPath -Force
                }

                # 3. State-based skip check (optimized: file hash first, config hash only if needed)
                $modifications = @($PakConfig.modifications)
                $configHash = $null  # Calculate lazily

                if (-not $Force -and $PakState -and $PakState.hash_after_modification) {
                    $currentHash = Get-Hash -Path $pakPath

                    if ($PakState.hash_after_modification -eq $currentHash) {
                        # Only calculate config hash if file hash matches
                        $sortedConfig = Sort-Obj -Value $PakConfig
                        $configHash = Get-StrHash -Content ($sortedConfig | ConvertTo-Json -Compress -Depth 10)

                        if ($PakState.modification_config_hash -eq $configHash) {
                            $result.Success = $true
                            $result.Skipped = $true
                            $result.HashAfterModification = $currentHash
                            $result.ModificationConfigHash = $configHash
                            return $result
                        }
                    }
                }

                # Calculate config hash if not already done (for non-skip path)
                if ($null -eq $configHash) {
                    $sortedConfig = Sort-Obj -Value $PakConfig
                    $configHash = Get-StrHash -Content ($sortedConfig | ConvertTo-Json -Compress -Depth 10)
                }

                # 4. Read and parse PAK
                $pak = Read-Pak -Path $pakPath

                # 5. Search resources and apply modifications
                $modifiedResources = @{}
                $appliedCount = 0
                $unmatchedPatterns = New-Object 'System.Collections.Generic.HashSet[int]'
                for ($j = 0; $j -lt $modifications.Count; $j++) { [void]$unmatchedPatterns.Add($j) }
                $totalPatterns = $unmatchedPatterns.Count

                for ($i = 0; $i -lt $pak.Resources.Count - 1; $i++) {
                    $resource = $pak.Resources[$i]
                    $resourceId = $resource.Id
                    $resourceBytes = Get-Resource -Pak $pak -Id $resourceId
                    if ($null -eq $resourceBytes) { continue }
                    [byte[]]$resourceBytes = $resourceBytes
                    if ($resourceBytes.Length -lt 2) { continue }

                    $isGzipped = ($resourceBytes[0] -eq 0x1f -and $resourceBytes[1] -eq 0x8b)
                    $contentBytes = $resourceBytes
                    if ($isGzipped) {
                        $decompressed = Expand-Gzip -Bytes $resourceBytes
                        if ($null -eq $decompressed) { continue }
                        $contentBytes = $decompressed
                    }

                    if (Test-Binary -Bytes $contentBytes) { continue }
                    $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)
                    $resourceModified = $false
                    $modIndex = 0

                    foreach ($mod in $modifications) {
                        if ($content -match $mod.pattern) {
                            $content = $content -replace $mod.pattern, $mod.replacement
                            $resourceModified = $true
                            $appliedCount++
                            [void]$unmatchedPatterns.Remove($modIndex)
                        }
                        $modIndex++
                    }

                    if ($resourceModified) {
                        $modifiedResources[$resourceId] = @{ Content = $content; WasGzipped = $isGzipped }
                    }

                    if ($unmatchedPatterns.Count -eq 0 -and $totalPatterns -gt 0) { break }
                }

                # 6. Prepare byte modifications
                $byteModifications = @{}
                foreach ($resourceId in $modifiedResources.Keys) {
                    $entry = $modifiedResources[$resourceId]
                    $contentString = $entry['Content']
                    $wasGzipped = $entry['WasGzipped']
                    [byte[]]$newBytes = [System.Text.Encoding]::UTF8.GetBytes($contentString)
                    if ($wasGzipped) {
                        $compressedBytes = Compress-Gzip -Bytes $newBytes
                        $newBytes = [byte[]]$compressedBytes
                    }
                    $byteModifications[$resourceId] = $newBytes
                }

                # 7. Write modified PAK
                $modifiedResourceIds = @([int[]]$modifiedResources.Keys)
                if ($byteModifications.Count -gt 0) {
                    if (-not (Test-Path $backupPath)) {
                        Copy-Item -Path $pakPath -Destination $backupPath -Force
                    }
                    Write-PakMod -Pak $pak -Path $pakPath -Mods $byteModifications
                }

                $finalHash = Get-Hash -Path $pakPath
                $result.Success = $true
                $result.Skipped = $false
                $result.HashAfterModification = $finalHash
                $result.ModifiedResourceIds = $modifiedResourceIds
                $result.ModificationConfigHash = $configHash
            }
            catch {
                $result.Success = $false
                $result.Error = $_.ToString()
            }

            return $result
        }

        # Convert pak_state to hashtable for serialization
        $pakStateHash = $null
        if ($state.pak_state) {
            $pakStateHash = @{
                hash_after_modification   = $state.pak_state.hash_after_modification
                modified_resources        = $state.pak_state.modified_resources
                modification_config_hash  = $state.pak_state.modification_config_hash
            }
        }

        # Convert pak_modifications config to hashtable
        $pakConfigHash = @{
            enabled       = $config.pak_modifications.enabled
            modifications = @()
        }
        if ($config.pak_modifications.modifications) {
            foreach ($mod in $config.pak_modifications.modifications) {
                $pakConfigHash.modifications += @{
                    pattern     = $mod.pattern
                    replacement = $mod.replacement
                    description = $mod.description
                }
            }
        }

        Write-Status "Starting PAK modifications in background..." -Type Detail
        $pakTask = Start-BackgroundRunspace -Script $pakScript -Args @(
            $comet.Directory,
            $pakConfigHash,
            $pakStateHash,
            $Force
        )
    }

    # Track if PAK is being handled in background
    $pakInBackground = $null -ne $pakTask

    # ═══════════════════════════════════════════════════════════════
    # Step 1: Comet Update Check
    # ═══════════════════════════════════════════════════════════════
    if ($freshInstall) {
        # Skip update check - we just downloaded the latest installer
        Write-Status "Step 1: Skipping Update Check (fresh install)" -Type Step
        Write-Status "Fresh install - already have the latest version" -Type Detail
    }
    else {
        $updateResult = Update-CometBrowser -Config $config -Comet $comet -CometVersion $cometVersion -MeteorDataPath $meteorDataPath -PortableMode:$portableMode
        $comet = $updateResult.Comet
        $cometVersion = $updateResult.CometVersion
    }

    # ═══════════════════════════════════════════════════════════════
    # Step 2: Extension Update Check
    # ═══════════════════════════════════════════════════════════════
    $extensionsUpdated = Update-BundledExtensions -Config $config -Comet $comet

    # ═══════════════════════════════════════════════════════════════
    # Step 3: Change Detection
    # ═══════════════════════════════════════════════════════════════
    $needsSetup = Test-SetupRequired -Comet $comet -State $state -PatchedExtPath $patchedExtPath -Force:$Force -ExtensionsUpdated:$extensionsUpdated

    # ═══════════════════════════════════════════════════════════════
    # Step 4: Extract & Patch
    # ═══════════════════════════════════════════════════════════════
    Initialize-Extensions `
        -Config $config `
        -Comet $comet `
        -State $state `
        -PatchedExtPath $patchedExtPath `
        -PatchesPath $patchesPath `
        -PatchedResourcesPath $patchedResourcesPath `
        -UserDataPath $userDataPath `
        -CometVersion $cometVersion `
        -PortableMode:$portableMode `
        -NeedsSetup:$needsSetup `
        -SkipPak:$SkipPak `
        -PakInBackground:$pakInBackground `
        -FreshInstall:$freshInstall

    # ═══════════════════════════════════════════════════════════════
    # Step 5 & 5.5: Wait for Adblock Background Task
    # ═══════════════════════════════════════════════════════════════
    if ($adblockTask) {
        Write-Status "Step 5: Waiting for adblock installation..." -Type Step
        $adBlockResult = Wait-BackgroundRunspace -Task $adblockTask
        if ($adBlockResult.Success) {
            $ublockPath = $adBlockResult.UBlockPath
            $adguardExtraPath = $adBlockResult.AdGuardPath
            Write-Status "Adblock extensions ready" -Type Success
        }
        else {
            Write-Status "Adblock installation error: $($adBlockResult.Error)" -Type Warning
            # Fall back to existing paths if installation failed
        }
    }
    elseif ($WhatIfPreference) {
        Write-Status "Step 5: Checking ad-block extensions" -Type Step
        if ($ublockEnabled) { Write-Status "Would check/download uBlock Origin" -Type Detail }
        if ($adguardEnabled) { Write-Status "Would check/download AdGuard Extra" -Type Detail }
    }
    elseif (-not $NoLaunch -and ($ublockEnabled -or $adguardEnabled)) {
        # Fallback to sequential if background task wasn't started for some reason
        Write-Status "Step 5: Checking ad-block extensions" -Type Step
        $adBlockResult = Initialize-AdBlockExtensions `
            -Config $config `
            -UBlockPath $ublockPath `
            -AdGuardExtraPath $adguardExtraPath `
            -Force:$Force `
            -PreDownloadedUBlock $preDownloadedUBlock `
            -PreDownloadedAdGuard $preDownloadedAdGuard
        $ublockPath = $adBlockResult.UBlockPath
        $adguardExtraPath = $adBlockResult.AdGuardExtraPath
    }

    # ═══════════════════════════════════════════════════════════════
    # Wait for PAK Background Task
    # ═══════════════════════════════════════════════════════════════
    if ($pakTask) {
        Write-Status "Waiting for PAK modifications to complete..." -Type Detail
        $pakResult = Wait-BackgroundRunspace -Task $pakTask
        if ($pakResult.Success) {
            if ($pakResult.Skipped) {
                Write-Status "PAK already patched (verified via state hash)" -Type Detail
            }
            else {
                Write-Status "PAK modifications applied" -Type Success
            }
            # Update pak_state
            if ($pakResult.HashAfterModification) {
                $state.pak_state = @{
                    hash_after_modification   = $pakResult.HashAfterModification
                    modified_resources        = $pakResult.ModifiedResourceIds
                    modification_config_hash  = $pakResult.ModificationConfigHash
                }
            }
        }
        else {
            Write-Status "PAK modifications error: $($pakResult.Error)" -Type Warning
        }
    }

    # Save state
    if (-not $WhatIfPreference) {
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

    if (-not $comet -and -not $WhatIfPreference) {
        Write-Status "Cannot launch - Comet not installed" -Type Error
        exit 1
    }

    # CRITICAL: Stop any running Comet processes before launching
    # Chromium ignores command-line flags when an instance is already running -
    # it just signals the existing process to open a new window. This means
    # --no-first-run, --disable-features, etc. would all be ignored.
    $cometProcesses = Get-Process -Name "comet" -ErrorAction SilentlyContinue
    if ($cometProcesses) {
        if ($WhatIfPreference) {
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

    if ($comet -or $WhatIfPreference) {
        $browserExe = if ($comet) { $comet.Executable } else { "comet.exe" }
        $browserUserDataPath = if ($portableMode) { $userDataPath } else { $null }
        $profileName = if ($config.browser.PSObject.Properties['profile'] -and $config.browser.profile) { $config.browser.profile } else { "Default" }

        # Write Secure Preferences with valid HMACs
        # This ensures developer mode, toolbar pin, and home button are set without HMAC validation failures
        $cometDir = if ($comet) { $comet.Directory } else { $null }
        $null = Set-BrowserPreferences -UserDataPath $browserUserDataPath -ProfileName $profileName -CometDir $cometDir

        $buildParams = @{
            Config = $config
            BrowserExe = $browserExe
            ExtPath = $patchedExtPath
            UBlockPath = $ublockPath
            AdGuardExtraPath = $adguardExtraPath
            UserDataPath = $browserUserDataPath
        }
        $cmd = Build-BrowserCommand @buildParams

        $proc = Start-Browser -Command $cmd
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

