#Requires -Version 7.1

function Get-TeamsPrivateChannelComplianceMap {
    <#
    .SYNOPSIS
        Maps a Teams custodian's private channel membership to eDiscovery content
        locations to close the compliance gap created by the MC1134737 migration.

    .DESCRIPTION
        Get-TeamsPrivateChannelComplianceMap is an advanced function that addresses
        the compliance gap introduced by Microsoft Message Center notification
        MC1134737 (Teams private channel migration, rolling out from late October 2025).

        MC1134737 COMPLIANCE GAP
        ────────────────────────
        BEFORE MIGRATION
          Compliance copies of private channel messages were delivered to the Exchange
          mailbox of every individual channel member as hidden items. An eDiscovery
          search of a user's mailbox surfaced all private channel activity.

        AFTER MIGRATION
          Compliance copies are delivered exclusively to the PARENT TEAM's Exchange
          group mailbox, with the channel name embedded in the message subject.
          Individual user mailboxes no longer contain private channel messages.

        THE GAP
          The Microsoft 365 Admin Center does not expose private channel membership
          for compliance review. Opening a Purview eDiscovery case and adding a
          custodian's UPN will miss all private channel content because the messages
          are in a group mailbox and the files are in a dedicated SharePoint site —
          neither of which appears when looking up the user.

        This function automates the mapping by:
          1. Checking the tenant-wide MC1134737 migration status via
             Get-TenantPrivateChannelMigrationStatus and indexing any ownerless
             channels that were skipped (these still use the old model).
          2. Calling Get-Team -User <UPN> to retrieve only the teams the user
             belongs to.
          3. For each team, calling Get-TeamChannel to enumerate all channels.
          4. For each private channel, calling Get-TeamChannelUser to confirm the
             user is actually a member (private channel membership is independent
             of team membership).
          5. Resolving the parent team's group mailbox address and the private
             channel's dedicated SharePoint site URL.
          6. Tagging each channel with an MC1134737_Status and a ComplianceTarget
             field that tells legal exactly which data sources to add to the
             eDiscovery case.
          7. Producing a color-coded Compliance Gap Report on screen.

        Ref: https://learn.microsoft.com/en-us/microsoftteams/private-channels
        Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-tenantprivatechannelmigrationstatus

    .PARAMETER UserPrincipalName
        One or more UPNs of the custodians to investigate, e.g. jdoe@contoso.com.
        Accepts an array — each UPN is processed in sequence within the same session.
        Prompted interactively if omitted; invalid UPNs are flagged and re-prompted.

    .PARAMETER LoggingDirectory
        Directory where the timestamped log file is written.
        Defaults to $env:TEMP\Get-TeamsPrivateChannelComplianceMap.

    .PARAMETER TenantId
        Tenant ID or domain. Mandatory for ServicePrincipal auth; optional for
        Interactive, Credential, and AccessTokens.

    .PARAMETER UseDeviceAuthentication
        (Interactive set) Use device-code flow instead of a browser pop-up.
        Useful for headless or remote sessions.

    .PARAMETER TeamsAdminCredential
        (Credential set) PSCredential for organizational-ID accounts without MFA.

    .PARAMETER ApplicationId
        (ServicePrincipal set) Azure app registration Application (client) ID.
        Requires MicrosoftTeams 4.7.1-preview or later.

    .PARAMETER CertificateThumbprint
        (ServicePrincipal set) Thumbprint of the certificate in the local cert store.
        Provide this or -Certificate.

    .PARAMETER Certificate
        (ServicePrincipal set) X509Certificate2 object loaded from a .pfx file.
        Provide this or -CertificateThumbprint.

    .PARAMETER AccessTokens
        (AccessTokens set) Two-element array.
        Index [0] = MS Graph token. Index [1] = Skype and Teams Tenant Admin API token.

    .PARAMETER ManagedIdentity
        (ManagedIdentity set) Connect using the Azure managed service identity
        assigned to the current host. Requires MicrosoftTeams 5.8.1-preview or later.

    .PARAMETER StayConnected
        When specified, the Microsoft Teams session is NOT disconnected after the
        function completes. Useful when chaining multiple Teams operations.
        If a Teams session is already active (detected via Get-CsTenant), the
        function reuses it and skips the Connect-MicrosoftTeams call entirely.

    .PARAMETER FullDetails
        When specified, the final summary displays all record properties as a
        Format-List for every UPN. Suppresses the default table. Cannot be used
        together with -MediumDetails.

    .PARAMETER MediumDetails
        When specified, the final summary displays the six-column compliance table
        (UPN, TeamName, GroupMailbox, ChannelName, MC1134737_Status, ComplianceTarget)
        for all records across all UPNs. Cannot be used together with -FullDetails.

    .PARAMETER HoldSummary
        When specified, prints a per-custodian Purview eDiscovery Hold Summary after
        the MC1134737 gap reports. The summary lists every location that must be added
        to the Purview custodian hold:
          - Always-required: custodian's Exchange mailbox and OneDrive.
          - Private channel Exchange locations (group mailboxes, deduplicated per team).
          - Private channel SharePoint site URLs (one per channel).
          - A CRITICAL warning for OwnerlessPending channels still on the old model.
          - Standard and Shared channel group mailboxes (deduplicated per team) —
            add as non-custodial data sources to capture all standard channel messages.
          - Parent team SharePoint URLs (constructed from group mailbox MailNickName
            per Microsoft eDiscovery guidance) — add as non-custodial data sources.
            Labelled [Constructed] — verify if the site was manually renamed.
        OneDrive URLs are constructed from the UPN and may need verification for
        tenants that use custom SharePoint domain names.

    .PARAMETER ExportToCsv
        When specified, exports all collected records to a timestamped CSV file
        in -LoggingDirectory named ComplianceMap_yyyyMMdd_HHmmss.csv.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com

        Interactive browser/MFA. Maps all of jdoe's Teams private channel memberships
        and prints the per-user MC1134737 Compliance Gap Report.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap `
            -UserPrincipalName jdoe@contoso.com, jane@contoso.com, bob@contoso.com

        Investigate multiple custodians in a single run. Each UPN is scanned in
        sequence; gap reports and summary lines are printed for each user.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -MediumDetails

        After the per-user gap reports, prints a consolidated six-column table
        (UPN, TeamName, GroupMailbox, ChannelName, MC1134737_Status, ComplianceTarget)
        for all records across all UPNs.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -FullDetails

        After the per-user gap reports, prints every record property as a
        Format-List for all UPNs.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -UseDeviceAuthentication -TenantId contoso.onmicrosoft.com

        Device-code flow for headless or remote sessions. Suitable for Azure
        Automation or SSH sessions where a browser is unavailable.

    .EXAMPLE
        C:\PS> $cred = Get-Credential
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -TeamsAdminCredential $cred

        PSCredential authentication.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -ApplicationId '00000000-0000-0000-0000-000000000000' `
            -TenantId 'contoso.onmicrosoft.com' `
            -CertificateThumbprint 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'

        Service principal authentication using a certificate thumbprint.

    .EXAMPLE
        C:\PS> $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                    'C:\certs\app.pfx', (Read-Host -AsSecureString 'PFX password'))
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -ApplicationId '00000000-0000-0000-0000-000000000000' `
            -TenantId 'contoso.onmicrosoft.com' `
            -Certificate $cert

        Service principal authentication using a certificate object.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -AccessTokens @($graphToken, $teamsToken)

        Pre-acquired access token authentication.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -ManagedIdentity -LoggingDirectory 'D:\ComplianceLogs'

        Managed identity authentication with a custom log directory.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -ExportToCsv

        Exports the full result set to a CSV file for legal review.

    .EXAMPLE
        C:\PS> GTPCCM -UserPrincipalName jdoe@contoso.com

        Uses the GTPCCM alias.

    .EXAMPLE
        C:\PS> $map = Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com
        C:\PS> $map | Where-Object MC1134737_Status -eq 'OwnerlessPending' | Select-Object TeamName, ChannelName, ChannelThreadId

        Pipeline use — filter to only the critical-gap channels.

    .EXAMPLE
        C:\PS> Get-TeamsPrivateChannelComplianceMap -UserPrincipalName jdoe@contoso.com `
            -HoldSummary

        After the MC1134737 gap report, prints a consolidated Purview eDiscovery Hold
        Summary listing every location to add to the custodian hold:
          - Always-required: Exchange mailbox and OneDrive for the custodian.
          - Private channel group mailboxes (deduplicated per team).
          - Private channel SharePoint site URLs.
          - Critical warning for OwnerlessPending channels.
          - Manual-action note for parent team SharePoint sites.

    .INPUTS
        None. This function does not accept pipeline input.

    .OUTPUTS
        None (display only).
        Console output is controlled by the -MediumDetails, -FullDetails, and -HoldSummary switches.
        Use -ExportToCsv to capture all records to a CSV file.
        Record fields:
          UserPrincipalName, TeamName, GroupId, GroupMailbox, ChannelName,
          ChannelThreadId, MembershipType, IsPrivateChannel, SharePointSiteUrl,
          ParentTeamSharePointUrl, UserRole, MC1134737_Status, ComplianceTarget.

        ParentTeamSharePointUrl: Graph-resolved (labelled [Graph-resolved]) when
          -ResolveSharePointUrls is specified and the Graph call succeeds; otherwise
          constructed from GroupMailbox MailNickName (labelled [Constructed]).
          Written to the CSV export and used by the dashboard Hold Summary tab.

    .NOTES
        Alias: GTPCCM
        Requires PowerShell 7.1 or later.
        The MicrosoftTeams module is installed automatically from PSGallery if absent.
        ServicePrincipal auth requires MicrosoftTeams 4.7.1-preview or later.
        ManagedIdentity auth requires MicrosoftTeams 5.8.1-preview or later.
        Each run creates a separate timestamped log file in -LoggingDirectory.

        Display modes:
          (default)        Per-user gap report + summary lines only
          -MediumDetails   Adds a consolidated six-column table after the summaries
          -FullDetails     Adds a full Format-List of every property after the summaries
          -ResolveSharePointUrls  Queries Microsoft Graph for authoritative parent team
                                   SharePoint URLs. Resolved per team in the process block
                                   and stored in ParentTeamSharePointUrl on every record.
                                   Graph is called once per unique GroupId and cached.
          -ResolveSharePointUrls  Queries Microsoft Graph for authoritative parent team
                                   SharePoint URLs. Resolved per team in the process block
                                   and stored in ParentTeamSharePointUrl on every record.
                                   Graph is called once per unique GroupId and cached.

        MC1134737_Status values:
          NotApplicable    Standard/Shared channels — not affected by migration
          Migrated         Private channel fully migrated — eDiscovery in group mailbox
          OwnerlessPending CRITICAL GAP — channel skipped (no owner); old model still active
          MigrationPending Not yet processed — verify before eDiscovery
          NotStarted       Migration has not begun for this tenant
          Unknown          Migration status could not be retrieved

        Session reuse: when -StayConnected is specified and an active Teams session is
        detected (via Get-CsTenant), Connect-MicrosoftTeams is skipped entirely.

        Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/connect-microsoftteams
    #>

    [Alias('GTPCCM')]
    [CmdletBinding(DefaultParameterSetName = 'Interactive', SupportsShouldProcess)]
    param (
        # ── Common ────────────────────────────────────────────────────────────
        [Parameter(Mandatory = $false, HelpMessage = 'UPN(s) of the custodian(s) to investigate')]
        [string[]]$UserPrincipalName,

        [Parameter(Mandatory = $false, HelpMessage = 'Directory for log files')]
        [string]$LoggingDirectory = (Join-Path $env:TEMP 'Get-TeamsPrivateChannelComplianceMap'),

        [Parameter()]
        [switch]$StayConnected,

        [Parameter()]
        [switch]$ExportToCsv,

        [Parameter()]
        [switch]$FullDetails,

        [Parameter()]
        [switch]$MediumDetails,

        [Parameter()]
        [switch]$HoldSummary,

        [Parameter()]
        [switch]$ResolveSharePointUrls,

        # ── TenantId ──────────────────────────────────────────────────────────
        [Parameter(ParameterSetName = 'Interactive',      Mandatory = $false)]
        [Parameter(ParameterSetName = 'Credential',       Mandatory = $false)]
        [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory = $true)]
        [Parameter(ParameterSetName = 'AccessTokens',     Mandatory = $false)]
        [string]$TenantId,

        # ── Interactive (default) ─────────────────────────────────────────────
        # Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/connect-microsoftteams
        [Parameter(ParameterSetName = 'Interactive', Mandatory = $false)]
        [switch]$UseDeviceAuthentication,

        # ── Credential ────────────────────────────────────────────────────────
        [Parameter(ParameterSetName = 'Credential', Mandatory = $true)]
        [System.Management.Automation.PSCredential]$TeamsAdminCredential,

        # ── ServicePrincipal ──────────────────────────────────────────────────
        # Requires MicrosoftTeams 4.7.1-preview or later
        [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory = $true)]
        [string]$ApplicationId,

        [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory = $false)]
        [string]$CertificateThumbprint,

        [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory = $false)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,

        # ── AccessTokens ──────────────────────────────────────────────────────
        # Element [0] = MS Graph token, [1] = Skype and Teams Tenant Admin API token
        [Parameter(ParameterSetName = 'AccessTokens', Mandatory = $true)]
        [ValidateCount(2, 2)]
        [string[]]$AccessTokens,

        # ── ManagedIdentity ───────────────────────────────────────────────────
        # Requires MicrosoftTeams 5.8.1-preview or later
        [Parameter(ParameterSetName = 'ManagedIdentity', Mandatory = $true)]
        [switch]$ManagedIdentity
    )

    begin {
        #region ── Initialize log file ────────────────────────────────────────

        if (-not (Test-Path -Path $LoggingDirectory)) {
            New-Item -Path $LoggingDirectory -ItemType Directory -Force | Out-Null
        }

        $runStamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $logFile   = Join-Path $LoggingDirectory "Logging_$runStamp.txt"
        $separator = '-' * 80

        Write-ToLogFile -StringObject $separator -LogFile $logFile
        Write-ToLogFile -StringObject 'Starting Get-TeamsPrivateChannelComplianceMap' -LogFile $logFile
        Write-ToLogFile -StringObject "Log file: $logFile" -LogFile $logFile -ForegroundColor DarkGray

        #endregion

        #region ── Module bootstrap ───────────────────────────────────────────

        $requiredModule = 'MicrosoftTeams'

        Write-ToLogFile -StringObject "Checking for module: $requiredModule" -LogFile $logFile
        $installed = Get-Module -ListAvailable -Name $requiredModule |
                     Sort-Object Version -Descending |
                     Select-Object -First 1

        if (-not $installed) {
            Write-ToLogFile -StringObject "$requiredModule not found. Installing from PSGallery..." `
                -LogFile $logFile -ForegroundColor Yellow
            try {
                Install-Module -Name $requiredModule -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                Write-ToLogFile -StringObject "$requiredModule installed successfully." -LogFile $logFile
            }
            catch {
                Write-ToLogFile -StringObject "ERROR: $requiredModule installation failed. $($_.Exception.Message)" `
                    -LogFile $logFile -ForegroundColor Red
                throw "[$requiredModule] installation failed: $($_.Exception.Message)"
            }
        }
        else {
            Write-ToLogFile -StringObject "$requiredModule found v$($installed.Version)." -LogFile $logFile
        }

        if (-not (Get-Module -Name $requiredModule)) {
            try {
                Import-Module -Name $requiredModule -ErrorAction Stop
                Write-ToLogFile -StringObject "$requiredModule imported." -LogFile $logFile
            }
            catch {
                Write-ToLogFile -StringObject "ERROR: $requiredModule import failed. $($_.Exception.Message)" `
                    -LogFile $logFile -ForegroundColor Red
                throw "[$requiredModule] import failed: $($_.Exception.Message)"
            }
        }
        else {
            Write-ToLogFile -StringObject "$requiredModule already loaded." -LogFile $logFile
        }

        #endregion

        #region ── Teams connection ───────────────────────────────────────────
        # Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/connect-microsoftteams

        # Check for an existing session — skip reconnect if -StayConnected and already connected.
        # Get-CsTenant is a fast single-object call; it throws when no active session exists.
        # NOTE: session reuse only works if the PREVIOUS run also used -StayConnected (so it
        # did not disconnect). If the previous run did not use -StayConnected, a new connection
        # is required regardless.
        $alreadyConnected = $false
        if ($StayConnected) {
            try {
                $null = Get-CsTenant -ErrorAction Stop
                $alreadyConnected = $true
                Write-ToLogFile -StringObject 'Active Teams session detected — skipping Connect-MicrosoftTeams (-StayConnected).' `
                    -LogFile $logFile -ForegroundColor Cyan
            }
            catch {
                $alreadyConnected = $false
                Write-ToLogFile -StringObject 'No active Teams session found. A new connection will be established.' `
                    -LogFile $logFile -ForegroundColor DarkGray
                Write-ToLogFile -StringObject 'Tip: use -StayConnected on every run in a chain to avoid repeated sign-in prompts.' `
                    -LogFile $logFile -ForegroundColor DarkGray
            }
        }

        if ($alreadyConnected) {
            Write-ToLogFile -StringObject 'Reusing existing Microsoft Teams session (-StayConnected).' -LogFile $logFile -ForegroundColor Cyan
        }
        else {
            Write-ToLogFile -StringObject 'Connecting to Microsoft Teams...' -LogFile $logFile -ForegroundColor Cyan
            Write-ToLogFile -StringObject "Auth method: $($PSCmdlet.ParameterSetName)" -LogFile $logFile
        }

        if (-not $alreadyConnected -and $PSCmdlet.ShouldProcess('Microsoft Teams', 'Connect')) {
            try {
                switch ($PSCmdlet.ParameterSetName) {

                    'Interactive' {
                        $connectParams = @{}
                        if ($TenantId)                { $connectParams['TenantId']               = $TenantId }
                        if ($UseDeviceAuthentication) { $connectParams['UseDeviceAuthentication'] = $true }
                        Connect-MicrosoftTeams @connectParams -ErrorAction Stop | Out-Null
                    }

                    'Credential' {
                        $connectParams = @{ Credential = $TeamsAdminCredential }
                        if ($TenantId) { $connectParams['TenantId'] = $TenantId }
                        Connect-MicrosoftTeams @connectParams -ErrorAction Stop | Out-Null
                    }

                    'ServicePrincipal' {
                        if (-not $CertificateThumbprint -and -not $Certificate) {
                            throw 'ServicePrincipal auth requires -CertificateThumbprint or -Certificate.'
                        }
                        $connectParams = @{
                            ApplicationId = $ApplicationId
                            TenantId      = $TenantId
                        }
                        if ($CertificateThumbprint) { $connectParams['CertificateThumbprint'] = $CertificateThumbprint }
                        if ($Certificate)           { $connectParams['Certificate']           = $Certificate }
                        Connect-MicrosoftTeams @connectParams -ErrorAction Stop | Out-Null
                    }

                    'AccessTokens' {
                        $connectParams = @{ AccessTokens = $AccessTokens }
                        if ($TenantId) { $connectParams['TenantId'] = $TenantId }
                        Connect-MicrosoftTeams @connectParams -ErrorAction Stop | Out-Null
                    }

                    'ManagedIdentity' {
                        Connect-MicrosoftTeams -Identity -ErrorAction Stop | Out-Null
                    }
                }

                Write-ToLogFile -StringObject 'Successfully connected to Microsoft Teams.' -LogFile $logFile -ForegroundColor Green
            }
            catch {
                Write-ToLogFile -StringObject "ERROR: Teams connection failed. $($_.Exception.Message)" `
                    -LogFile $logFile -ForegroundColor Red
                throw "Could not connect to Microsoft Teams: $($_.Exception.Message)"
            }
        }

        #endregion

        #region ── Microsoft Graph connection (optional — for -ResolveSharePointUrls) ──
        # Ref: https://learn.microsoft.com/en-us/graph/api/group-list-sites
        # Requires Sites.Read.All granted to the auth identity.

        $mgGraphConnected   = $false
        $graphTokenDirect   = $null     # used only for the AccessTokens parameter set

        if ($ResolveSharePointUrls) {

            if ($PSCmdlet.ParameterSetName -eq 'Credential') {
                Write-ToLogFile -StringObject 'WARN: -ResolveSharePointUrls is not supported with PSCredential auth. Parent team SharePoint URLs will use the [Constructed] fallback.' `
                    -LogFile $logFile -ForegroundColor Yellow
            }
            elseif ($PSCmdlet.ParameterSetName -eq 'AccessTokens') {
                # AccessTokens[0] is the MS Graph token — use Invoke-RestMethod directly.
                # No separate module or Connect-MgGraph call required.
                $graphTokenDirect = $AccessTokens[0]
                $mgGraphConnected = $true
                Write-ToLogFile -StringObject 'Graph: using pre-acquired access token for SharePoint URL resolution.' `
                    -LogFile $logFile -ForegroundColor Cyan
            }
            else {
                # All other sets: use Microsoft.Graph.Authentication module.
                $graphModule = 'Microsoft.Graph.Authentication'
                $graphInstalled = Get-Module -ListAvailable -Name $graphModule |
                                  Sort-Object Version -Descending | Select-Object -First 1

                if (-not $graphInstalled) {
                    Write-ToLogFile -StringObject "$graphModule not found. Installing from PSGallery..." `
                        -LogFile $logFile -ForegroundColor Yellow
                    try {
                        Install-Module -Name $graphModule -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                        Write-ToLogFile -StringObject "$graphModule installed." -LogFile $logFile
                    }
                    catch {
                        Write-ToLogFile -StringObject "ERROR: $graphModule installation failed. $($_.Exception.Message)" `
                            -LogFile $logFile -ForegroundColor Red
                        Write-ToLogFile -StringObject 'Falling back to [Constructed] SharePoint URLs.' `
                            -LogFile $logFile -ForegroundColor Yellow
                    }
                }

                if (-not (Get-Module -Name $graphModule)) {
                    try {
                        Import-Module -Name $graphModule -ErrorAction Stop
                    }
                    catch {
                        Write-ToLogFile -StringObject "ERROR: $graphModule import failed. $($_.Exception.Message)" `
                            -LogFile $logFile -ForegroundColor Red
                    }
                }

                if (Get-Module -Name $graphModule) {
                    Write-ToLogFile -StringObject 'Connecting to Microsoft Graph for SharePoint URL resolution (Sites.Read.All)...' `
                        -LogFile $logFile -ForegroundColor Cyan
                    try {
                        switch ($PSCmdlet.ParameterSetName) {

                            'Interactive' {
                                $mgParams = @{ Scopes = @('Sites.Read.All'); NoWelcome = $true }
                                if ($TenantId)                { $mgParams['TenantId']     = $TenantId }
                                if ($UseDeviceAuthentication) { $mgParams['UseDeviceCode'] = $true }
                                Connect-MgGraph @mgParams -ErrorAction Stop | Out-Null
                            }

                            'ServicePrincipal' {
                                $mgParams = @{
                                    ClientId  = $ApplicationId
                                    TenantId  = $TenantId
                                    NoWelcome = $true
                                }
                                if ($CertificateThumbprint) { $mgParams['CertificateThumbprint'] = $CertificateThumbprint }
                                if ($Certificate)           { $mgParams['Certificate']           = $Certificate }
                                Connect-MgGraph @mgParams -ErrorAction Stop | Out-Null
                            }

                            'ManagedIdentity' {
                                Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop | Out-Null
                            }
                        }

                        $mgGraphConnected = $true
                        Write-ToLogFile -StringObject 'Graph connection established.' -LogFile $logFile -ForegroundColor Green
                    }
                    catch {
                        Write-ToLogFile -StringObject "WARN: Graph connection failed. $($_.Exception.Message). Falling back to [Constructed] URLs." `
                            -LogFile $logFile -ForegroundColor Yellow
                    }
                }
            }
        }

        #endregion

        #region ── Resolve UPN(s) ───────────────────────────────────────────────

        if (-not $UserPrincipalName) {
            # Interactive: keep prompting until at least one valid UPN is entered
            do {
                $upnInput    = Read-Host 'Enter one or more UPNs (comma-separated) to investigate'
                $candidates  = @($upnInput -split '\s*,\s*' | Where-Object { $_ -ne '' })
                $invalidUpns = @($candidates | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
                foreach ($bad in $invalidUpns) {
                    Write-ToLogFile -StringObject "'$bad' is not a valid User Principal Name — expected format: user@domain.com. Please try again." `
                        -LogFile $logFile -ForegroundColor Red
                }
                $UserPrincipalName = @($candidates | Where-Object { $_ -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
            } until ($UserPrincipalName.Count -gt 0)
        }
        else {
            # Parameter provided: validate and filter out any malformed entries
            $invalidUpns = @($UserPrincipalName | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
            foreach ($bad in $invalidUpns) {
                Write-ToLogFile -StringObject "'$bad' is not a valid User Principal Name — expected format: user@domain.com" `
                    -LogFile $logFile -ForegroundColor Red
            }
            $UserPrincipalName = @($UserPrincipalName | Where-Object { $_ -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
            if ($UserPrincipalName.Count -eq 0) {
                throw 'No valid User Principal Names were provided.'
            }
        }

        Write-ToLogFile -StringObject "Investigating $($UserPrincipalName.Count) user(s): $($UserPrincipalName -join ', ')" -LogFile $logFile -ForegroundColor Cyan

        #endregion

        #region ── Graph SharePoint URL cache ────────────────────────────────
        # GroupId → resolved SharePoint URL (populated during the process block).
        # Avoids duplicate Graph calls when multiple custodians share the same team.
        $graphSpCache = [System.Collections.Generic.Dictionary[string,string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        #endregion

        #region ── MC1134737: Tenant private channel migration status ─────────
        # Get-TenantPrivateChannelMigrationStatus reports whether private channels
        # have been moved to the new group-based compliance model.
        # Channels flagged ownerless were SKIPPED — still deliver compliance copies
        # to individual user mailboxes (old model) — active compliance gaps.
        # Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-tenantprivatechannelmigrationstatus

        $migrationStatus     = 'Unknown'
        $ownerlessChannelIds = @{}      # hashtable: channelThreadId → teamId for O(1) lookup
        $migrationDetails    = $null

        Write-ToLogFile -StringObject 'Checking tenant private channel migration status (MC1134737)' `
            -LogFile $logFile
        try {
            $migrationResult  = Get-TenantPrivateChannelMigrationStatus -ErrorAction Stop
            $migrationStatus  = $migrationResult.MigrationStatus
            Write-ToLogFile -StringObject "MC1134737 migration status: $migrationStatus" -LogFile $logFile

            if ($migrationResult.Details) {
                $migrationDetails = $migrationResult.Details | ConvertFrom-Json
                $d = $migrationDetails
                Write-ToLogFile -StringObject ("MC1134737 details — " +
                    "Total: $($d.totalChannels)  Migrated: $($d.migratedChannels)  " +
                    "Failed: $($d.failedChannels)  Ownerless: $($d.ownerlessChannels)  " +
                    "Remaining: $($d.remainingChannels)") -LogFile $logFile

                if ($d.ownerlessChannelsDetails) {
                    foreach ($ownerless in $d.ownerlessChannelsDetails) {
                        $ownerlessChannelIds[$ownerless.channelThreadId] = $ownerless.teamId
                    }
                    Write-ToLogFile -StringObject "$($ownerlessChannelIds.Count) ownerless channel(s) — NOT migrated, active compliance gaps." `
                        -LogFile $logFile -ForegroundColor Red
                }
            }

            if ($migrationStatus -ne 'Completed') {
                Write-ToLogFile -StringObject "`n[MC1134737] Migration status: $migrationStatus" -LogFile $logFile -ForegroundColor Yellow
                Write-ToLogFile -StringObject '  One or more private channels may still use the OLD compliance model' -LogFile $logFile -ForegroundColor Yellow
                Write-ToLogFile -StringObject '  (compliance copies in individual user mailboxes, not the group mailbox).' -LogFile $logFile -ForegroundColor Yellow
            }
            else {
                Write-ToLogFile -StringObject "`n[MC1134737] Migration: Completed — all private channels use group mailbox compliance." -LogFile $logFile -ForegroundColor Green
            }
        }
        catch {
            Write-ToLogFile -StringObject "WARN: Could not retrieve MC1134737 migration status. Gap flags will show as Unknown. $($_.Exception.Message)" `
                -LogFile $logFile -ForegroundColor Yellow
        }

        #endregion
    }

    process {
        #region ── Initialise combined result collection ──────────────────────
        $allResults    = [System.Collections.Generic.List[PSCustomObject]]::new()
        $processedUpns = [System.Collections.Generic.List[string]]::new()
        #endregion

        foreach ($upn in $UserPrincipalName) {
            #region ── Get Teams this user belongs to ─────────────────────────
            # Get-Team -User <UPN> returns only the teams the user is a member of.
            # Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-team

            Write-ToLogFile -StringObject "Retrieving Teams membership for $upn..." -LogFile $logFile -ForegroundColor Cyan
            try {
                $userTeams = Get-Team -User $upn -ErrorAction Stop
            }
            catch {
                Write-ToLogFile -StringObject "ERROR: Get-Team failed for '$upn': $($_.Exception.Message)" -LogFile $logFile -ForegroundColor Red
                continue
            }

            if (-not $userTeams) {
                Write-ToLogFile -StringObject "No Teams membership found for $upn." -LogFile $logFile -ForegroundColor Yellow
                continue
            }

            Write-ToLogFile -StringObject "Found $($userTeams.Count) team(s) for $upn" -LogFile $logFile

            #endregion

            #region ── Enumerate channels per team ────────────────────────────

            $upnResults = [System.Collections.Generic.List[PSCustomObject]]::new()
            $teamCount  = $userTeams.Count
            $teamIndex  = 0

            foreach ($team in $userTeams) {
                $teamIndex++
                $groupId      = $team.GroupId
                $teamName     = $team.DisplayName
                $mailNick     = $team.MailNickName
                # Group mailbox: <MailNickName>@<tenant domain>
                # Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-team
                $tenantDomain = ($upn -split '@')[1]
                $groupMailbox = "$mailNick@$tenantDomain"

                Write-Progress -Activity "Scanning channels for $upn" `
                               -Status "$teamName ($teamIndex / $teamCount)" `
                               -PercentComplete (($teamIndex / $teamCount) * 100)

                Write-ToLogFile -StringObject "Processing team: $teamName" -LogFile $logFile -LogOnly

                # ── Get user's role in this team ──────────────────────────────
                # Get-TeamUser returns: User (UPN), UserId, Name, Role
                # Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-teamuser
                try {
                    $teamUsers = Get-TeamUser -GroupId $groupId -ErrorAction Stop
                }
                catch {
                    Write-ToLogFile -StringObject "WARN: Could not retrieve users for team '$teamName': $($_.Exception.Message)" `
                        -LogFile $logFile -ForegroundColor Yellow
                    continue
                }

                $userInTeam = $teamUsers | Where-Object { $_.User -eq $upn }

                # ── Get all channels for this team ────────────────────────────
                # Get-TeamChannel returns DisplayName, MembershipType (Standard|Private|Shared)
                # Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-teamchannel
                try {
                    $channels = Get-TeamChannel -GroupId $groupId -ErrorAction Stop
                }
                catch {
                    Write-ToLogFile -StringObject "WARN: Could not retrieve channels for '$teamName': $($_.Exception.Message)" `
                        -LogFile $logFile -ForegroundColor Yellow
                    $channels = @()
                }

                foreach ($channel in $channels) {
                    $channelName    = $channel.DisplayName
                    $membershipType = $channel.MembershipType   # Standard | Private | Shared
                    $isPrivate      = $membershipType -eq 'Private'

                    # ── For private channels, verify user membership ──────────
                    # Get-TeamChannelUser: -GroupId and -DisplayName are both mandatory
                    # Ref: https://learn.microsoft.com/en-us/powershell/module/microsoftteams/get-teamchanneluser
                    $channelMembers = $null
                    if ($isPrivate) {
                        try {
                            $channelMembers = Get-TeamChannelUser -GroupId $groupId `
                                                                  -DisplayName $channelName `
                                                                  -ErrorAction Stop
                        }
                        catch {
                            Write-ToLogFile -StringObject "WARN: Could not retrieve members for '$channelName' in '$teamName': $($_.Exception.Message)" `
                                -LogFile $logFile -ForegroundColor Yellow
                            continue
                        }

                        $userInChannel = $channelMembers | Where-Object { $_.User -eq $upn }
                        if (-not $userInChannel) { continue }   # user is not a member of this private channel
                    }

                    # ── Resolve parent team SharePoint URL ───────────────────
                    # Resolved once per unique GroupId and cached in $graphSpCache.
                    # Used as ParentTeamSharePointUrl on every record for this team.
                    $parentSpUrl = $null
                    if (-not $graphSpCache.TryGetValue($groupId, [ref]$parentSpUrl)) {
                        $mailNickForSp  = ($groupMailbox -split '@')[0]
                        $constructedSp  = "https://$tenantName.sharepoint.com/sites/$mailNickForSp"

                        if ($mgGraphConnected -or $graphTokenDirect) {
                            try {
                                if ($graphTokenDirect) {
                                    $spHeaders  = @{ Authorization = "Bearer $graphTokenDirect" }
                                    $spResponse = Invoke-RestMethod `
                                        -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/sites/root" `
                                        -Headers $spHeaders -ErrorAction Stop
                                    $parentSpUrl = $spResponse.webUrl
                                }
                                else {
                                    $spResponse = Invoke-MgGraphRequest `
                                        -Method GET `
                                        -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/sites/root" `
                                        -ErrorAction Stop
                                    $parentSpUrl = $spResponse.webUrl
                                }
                                Write-ToLogFile -StringObject "Graph: resolved SharePoint for '$teamName': $parentSpUrl [Graph-resolved]" `
                                    -LogFile $logFile -LogOnly
                            }
                            catch {
                                $parentSpUrl = $constructedSp
                                Write-ToLogFile -StringObject "WARN: Graph call failed for '$teamName'. Using [Constructed]: $constructedSp. $($_.Exception.Message)" `
                                    -LogFile $logFile -ForegroundColor Yellow -LogOnly
                            }
                        }
                        else {
                            $parentSpUrl = $constructedSp
                        }
                        $graphSpCache[$groupId] = $parentSpUrl
                    }

                    # ── Build SharePoint URL for private channels ─────────────
                    # Each private channel has its own dedicated SharePoint site.
                    # Ref: https://learn.microsoft.com/en-us/microsoftteams/private-channels#private-channel-sharepoint-sites
                    $sharePointUrl = $null
                    if ($isPrivate) {
                        if ($channel.PSObject.Properties['SharePointSiteUrl'] -and $channel.SharePointSiteUrl) {
                            $sharePointUrl = $channel.SharePointSiteUrl
                        }
                        else {
                            $tenantName   = $tenantDomain -replace '\..*$', ''
                            $safeSiteName = ($teamName + '-' + $channelName) -replace '[^A-Za-z0-9\-]', ''
                            $sharePointUrl = "https://$tenantName.sharepoint.com/sites/$safeSiteName"
                        }
                    }

                    # ── Determine MC1134737 status and eDiscovery target ──────
                    $mc1134737Status = if (-not $isPrivate) {
                        'NotApplicable'
                    }
                    elseif ($ownerlessChannelIds.ContainsKey($channel.Id)) {
                        'OwnerlessPending'
                    }
                    elseif ($migrationStatus -eq 'Completed') {
                        'Migrated'
                    }
                    elseif ($migrationStatus -in 'InProgress', 'RequiresAdminAttention') {
                        'MigrationPending'
                    }
                    elseif ($migrationStatus -eq 'NotStarted') {
                        'NotStarted'
                    }
                    else {
                        'Unknown'
                    }

                    $complianceTarget = if (-not $isPrivate) {
                        "GroupMailbox: $groupMailbox"
                    }
                    elseif ($ownerlessChannelIds.ContainsKey($channel.Id)) {
                        'OLD MODEL — Individual user mailboxes (channel NOT migrated; assign owner via Add-TeamChannelUser to unblock)'
                    }
                    elseif ($migrationStatus -eq 'Completed') {
                        "GroupMailbox: $groupMailbox (filter subject containing '$channelName') + SharePoint: $sharePointUrl"
                    }
                    else {
                        "GroupMailbox: $groupMailbox (migration pending — verify before eDiscovery) + SharePoint: $sharePointUrl"
                    }

                    $record = [PSCustomObject]@{
                        UserPrincipalName      = $upn
                        TeamName               = $teamName
                        GroupId                = $groupId
                        GroupMailbox           = $groupMailbox       # Parent team Exchange group mailbox
                        ChannelName            = $channelName
                        ChannelThreadId        = $channel.Id         # Unique thread ID (19:xxx@thread.tacv2)
                        MembershipType         = $membershipType
                        IsPrivateChannel       = $isPrivate
                        SharePointSiteUrl      = $sharePointUrl      # Private channel's dedicated SharePoint site
                        ParentTeamSharePointUrl = $parentSpUrl        # Parent team SharePoint (Graph-resolved or Constructed)
                        UserRole               = if ($isPrivate -and $channelMembers) {
                                                     ($channelMembers | Where-Object { $_.User -eq $upn }).Role
                                                 } else {
                                                     $userInTeam.Role
                                                 }
                        MC1134737_Status       = $mc1134737Status
                        ComplianceTarget       = $complianceTarget
                    }

                    $record.PSObject.TypeNames.Insert(0, 'TeamsPrivateChannelComplianceMap.Record')
                    $upnResults.Add($record)

                    # Log each result to file
                    Write-ToLogFile -StringObject "" -LogFile $logFile -LogOnly
                    Write-ToLogFile -StringObject 'RESULT —' -LogFile $logFile -LogOnly
                    foreach ($prop in $record.PSObject.Properties) {
                        Write-ToLogFile -StringObject "    $($prop.Name): $($prop.Value)" -LogFile $logFile -LogOnly
                    }
                }
            }

            Write-Progress -Activity "Scanning channels for $upn" -Completed

            #endregion

            #region ── Console output ─────────────────────────────────────────

            Write-ToLogFile -StringObject "Results for: $upn" -LogFile $logFile -ForegroundColor Green
            $processedUpns.Add($upn)

            #endregion

            # Accumulate results across all UPNs
            foreach ($r in $upnResults) { $allResults.Add($r) }
        }

        # Pipeline return suppressed — display is controlled via -MediumDetails / -FullDetails in the end block
        # $allResults
    }

    end {
        Write-Progress -Activity 'Scanning channels' -Completed -ErrorAction SilentlyContinue

        #region ── Disconnect ─────────────────────────────────────────────────

        if (-not $StayConnected) {
            try {
                Disconnect-MicrosoftTeams -ErrorAction Stop | Out-Null
                Write-ToLogFile -StringObject 'Disconnected from Microsoft Teams.' -LogFile $logFile
            }
            catch {
                Write-ToLogFile -StringObject "WARN: Disconnect failed. $($_.Exception.Message)" -LogFile $logFile -ForegroundColor Yellow
            }
        }
        else {
            Write-ToLogFile -StringObject 'Session left open (-StayConnected specified).' -LogFile $logFile
        }

        #endregion

        #region ── CSV export ─────────────────────────────────────────────────

        if ($ExportToCsv) {
            if ($allResults -and $allResults.Count -gt 0) {
                $csvPath = Join-Path $LoggingDirectory "ComplianceMap_$runStamp.csv"
                try {
                    $allResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
                    Write-ToLogFile -StringObject "CSV exported to: $csvPath" -LogFile $logFile -ForegroundColor Green
                }
                catch {
                    Write-ToLogFile -StringObject "ERROR: CSV export failed: $($_.Exception.Message)" `
                        -LogFile $logFile -ForegroundColor Red
                }
            }
            else {
                Write-ToLogFile -StringObject 'No records to export — skipping CSV export.' -LogFile $logFile -ForegroundColor Yellow
            }
        }

        #endregion

        # ── MC1134737 Compliance Gap Report (one section per UPN) ──────────────

        $gapSummaries = [System.Collections.Generic.List[string]]::new()

        foreach ($upn in $processedUpns) {
            $upnRecords      = $allResults | Where-Object { $_.UserPrincipalName -eq $upn }
            $privateChannels = $upnRecords  | Where-Object { $_.IsPrivateChannel }

            $ownerlessPending = $privateChannels | Where-Object { $_.MC1134737_Status -eq 'OwnerlessPending' }
            $migrated         = $privateChannels | Where-Object { $_.MC1134737_Status -eq 'Migrated' }
            $pending          = $privateChannels | Where-Object { $_.MC1134737_Status -eq 'MigrationPending' }
            $unknown          = $privateChannels | Where-Object { $_.MC1134737_Status -in 'Unknown', 'NotStarted' }

            Write-ToLogFile -StringObject ('─' * 72) -LogFile $logFile -ForegroundColor DarkGray
            Write-ToLogFile -StringObject 'MC1134737 COMPLIANCE GAP REPORT' -LogFile $logFile -ForegroundColor Cyan
            Write-ToLogFile -StringObject "Custodian: $upn" -LogFile $logFile -ForegroundColor Cyan
            Write-ToLogFile -StringObject "Tenant migration status: $migrationStatus" -LogFile $logFile -ForegroundColor Cyan
            if ($migrationDetails) {
                $d = $migrationDetails
                Write-ToLogFile -StringObject ("Total private channels: $($d.totalChannels)  |  " +
                            "Migrated: $($d.migratedChannels)  |  " +
                            "Ownerless/blocked: $($d.ownerlessChannels)  |  " +
                            "Failed (auto-retry): $($d.failedChannels)  |  " +
                            "Remaining: $($d.remainingChannels)") -LogFile $logFile -ForegroundColor DarkCyan
            }
            Write-ToLogFile -StringObject ('─' * 72) -LogFile $logFile -ForegroundColor DarkGray

            if ($ownerlessPending) {
                Write-ToLogFile -StringObject "`n[CRITICAL GAP] The following private channels were SKIPPED during migration" -LogFile $logFile -ForegroundColor Red
                Write-ToLogFile -StringObject 'because they have no owner. Compliance copies still go to INDIVIDUAL USER MAILBOXES.' -LogFile $logFile -ForegroundColor Red
                Write-ToLogFile -StringObject 'Action required: assign an owner via Add-TeamChannelUser to unblock migration.' -LogFile $logFile -ForegroundColor Red
                $ownerlessPending | Format-Table -AutoSize TeamName, ChannelName, ChannelThreadId, GroupId | Out-Host
            }

            if ($migrated) {
                Write-ToLogFile -StringObject "`n[MIGRATED — search group mailbox] These private channels use the NEW compliance model:" -LogFile $logFile -ForegroundColor Green
                Write-ToLogFile -StringObject '  eDiscovery target: parent team group mailbox (filter subject by channel name)' -LogFile $logFile -ForegroundColor Green
                Write-ToLogFile -StringObject '  File target: private channel SharePoint site' -LogFile $logFile -ForegroundColor Green
                $migrated | Format-Table -AutoSize TeamName, ChannelName, GroupMailbox, SharePointSiteUrl | Out-Host
            }

            if ($pending) {
                Write-ToLogFile -StringObject "`n[MIGRATION PENDING] These private channels have not yet been processed:" -LogFile $logFile -ForegroundColor Yellow
                Write-ToLogFile -StringObject '  Compliance copies may still be in user mailboxes OR group mailbox — verify before eDiscovery.' -LogFile $logFile -ForegroundColor Yellow
                $pending | Format-Table -AutoSize TeamName, ChannelName, GroupMailbox, SharePointSiteUrl | Out-Host
            }

            if ($unknown) {
                Write-ToLogFile -StringObject "`n[UNKNOWN] Migration status could not be determined for these channels:" -LogFile $logFile -ForegroundColor DarkYellow
                $unknown | Format-Table -AutoSize TeamName, ChannelName, GroupMailbox | Out-Host
            }

            if (-not $privateChannels) {
                Write-ToLogFile -StringObject "`nNo private channel memberships found — no MC1134737 compliance gap for this user." -LogFile $logFile -ForegroundColor Green
            }

            $gapSummaries.Add("MC1134737 gap summary for $upn — Migrated: $($migrated.Count)  OwnerlessPending: $($ownerlessPending.Count)  MigrationPending: $($pending.Count)  Unknown: $($unknown.Count)")
        }

        Write-ToLogFile -StringObject ('─' * 72) -LogFile $logFile -ForegroundColor DarkGray
        foreach ($summary in $gapSummaries) {
            Write-ToLogFile -StringObject $summary -LogFile $logFile
        }

        if ($HoldSummary -and $processedUpns.Count -gt 0) {
            Write-ToLogFile -StringObject '' -LogFile $logFile
            Write-ToLogFile -StringObject ('━' * 72) -LogFile $logFile -ForegroundColor Cyan
            Write-ToLogFile -StringObject 'PURVIEW EDISCOVERY HOLD SUMMARY' -LogFile $logFile -ForegroundColor Cyan
            Write-ToLogFile -StringObject 'Add all locations listed below to the custodian hold in Microsoft Purview.' -LogFile $logFile -ForegroundColor DarkCyan
            Write-ToLogFile -StringObject ('━' * 72) -LogFile $logFile -ForegroundColor Cyan

            foreach ($upn in $processedUpns) {
                $upnRecords      = $allResults | Where-Object { $_.UserPrincipalName -eq $upn }
                $privateChannels = $upnRecords  | Where-Object { $_.IsPrivateChannel }

                $tenantDomain = ($upn -split '@')[1]
                $tenantName   = $tenantDomain -replace '\..*$', ''
                $odUpn        = $upn -replace '@', '_' -replace '\.', '_'
                $oneDriveUrl  = "https://$tenantName-my.sharepoint.com/personal/$odUpn"

                Write-ToLogFile -StringObject '' -LogFile $logFile
                Write-ToLogFile -StringObject "  CUSTODIAN: $upn" -LogFile $logFile -ForegroundColor White
                Write-ToLogFile -StringObject ('  ' + ('─' * 68)) -LogFile $logFile -ForegroundColor DarkGray
                Write-ToLogFile -StringObject '  ALWAYS REQUIRED (add as custodian data sources in Purview):' -LogFile $logFile -ForegroundColor Yellow
                Write-ToLogFile -StringObject "    Exchange mailbox : $upn" -LogFile $logFile
                Write-ToLogFile -StringObject "    OneDrive         : $oneDriveUrl" -LogFile $logFile
                Write-ToLogFile -StringObject '    (Covers: 1:1 chats, group chats, standard/shared channel messages, pre-migration private channel messages, and shared files.)' -LogFile $logFile -ForegroundColor DarkGray

                if ($privateChannels) {
                    $ownerlessChannels = $privateChannels | Where-Object { $_.MC1134737_Status -eq 'OwnerlessPending' }
                    $otherPrivate      = $privateChannels | Where-Object { $_.MC1134737_Status -ne 'OwnerlessPending' }

                    if ($ownerlessChannels) {
                        Write-ToLogFile -StringObject '' -LogFile $logFile
                        Write-ToLogFile -StringObject '  CRITICAL — OWNERLESS CHANNELS (OLD MODEL — compliance copies in individual mailboxes):' -LogFile $logFile -ForegroundColor Red
                        foreach ($ch in $ownerlessChannels) {
                            Write-ToLogFile -StringObject "    $($ch.TeamName) >> $($ch.ChannelName) — individual member mailboxes (assign owner via Add-TeamChannelUser to unblock)" -LogFile $logFile -ForegroundColor Red
                        }
                    }

                    $addedGroupMailboxes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    $exchangeLines       = [System.Collections.Generic.List[string]]::new()
                    $sharePointLines     = [System.Collections.Generic.List[string]]::new()

                    foreach ($ch in $privateChannels) {
                        if ($ch.SharePointSiteUrl) {
                            $spLabel = switch ($ch.MC1134737_Status) {
                                'Migrated'         { '[Migrated]        ' }
                                'OwnerlessPending'  { '[OwnerlessPending]' }
                                'MigrationPending'  { '[MigrationPending]' }
                                default             { '[Unknown]         ' }
                            }
                            $sharePointLines.Add("    $spLabel $($ch.SharePointSiteUrl)  ($($ch.TeamName) >> $($ch.ChannelName))")
                        }
                    }

                    foreach ($ch in $otherPrivate) {
                        if ($addedGroupMailboxes.Add($ch.GroupMailbox)) {
                            $exLabel = switch ($ch.MC1134737_Status) {
                                'Migrated'         { '[Migrated]        ' }
                                'MigrationPending'  { '[MigrationPending]' }
                                default             { '[Unknown]         ' }
                            }
                            $suffix = if ($ch.MC1134737_Status -eq 'MigrationPending') { '  — verify after migration completes' } else { '' }
                            $exchangeLines.Add("    $exLabel $($ch.GroupMailbox)  ($($ch.TeamName))$suffix")
                        }
                    }

                    if ($exchangeLines.Count -gt 0) {
                        Write-ToLogFile -StringObject '' -LogFile $logFile
                        Write-ToLogFile -StringObject '  PRIVATE CHANNEL — EXCHANGE LOCATIONS (add as non-custodial data sources):' -LogFile $logFile -ForegroundColor Green
                        foreach ($line in $exchangeLines) { Write-ToLogFile -StringObject $line -LogFile $logFile }
                    }

                    if ($sharePointLines.Count -gt 0) {
                        Write-ToLogFile -StringObject '' -LogFile $logFile
                        Write-ToLogFile -StringObject '  PRIVATE CHANNEL — SHAREPOINT LOCATIONS (add as non-custodial data sources):' -LogFile $logFile -ForegroundColor Green
                        foreach ($line in $sharePointLines) { Write-ToLogFile -StringObject $line -LogFile $logFile }
                    }
                }
                else {
                    Write-ToLogFile -StringObject '  No private channel memberships found — no additional private channel locations required.' -LogFile $logFile -ForegroundColor DarkGreen
                }

                # ── Standard / Shared channel group mailboxes ─────────────────
                # These group mailboxes hold all standard and shared channel messages
                # via the TeamsMessagesData substrate folder. Adding them as
                # non-custodial Exchange data sources is required for complete coverage.
                $stdChannelRecords = $upnRecords | Where-Object { -not $_.IsPrivateChannel }
                $addedStdMailboxes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $stdExchangeLines  = [System.Collections.Generic.List[string]]::new()
                foreach ($ch in $stdChannelRecords) {
                    if ($addedStdMailboxes.Add($ch.GroupMailbox)) {
                        $stdExchangeLines.Add("    $($ch.GroupMailbox)  ($($ch.TeamName))")
                    }
                }

                if ($stdExchangeLines.Count -gt 0) {
                    Write-ToLogFile -StringObject '' -LogFile $logFile
                    Write-ToLogFile -StringObject '  STANDARD/SHARED CHANNEL — EXCHANGE LOCATIONS (add as non-custodial data sources):' -LogFile $logFile -ForegroundColor Green
                    Write-ToLogFile -StringObject '  (Captures all standard and shared channel messages via TeamsMessagesData substrate.)' -LogFile $logFile -ForegroundColor DarkGray
                    foreach ($line in $stdExchangeLines) { Write-ToLogFile -StringObject $line -LogFile $logFile }
                }

                $teamsWithStdChannels = $stdChannelRecords | Select-Object -ExpandProperty TeamName -Unique
                if ($teamsWithStdChannels) {
                    Write-ToLogFile -StringObject '' -LogFile $logFile
                    Write-ToLogFile -StringObject '  PARENT TEAM SHAREPOINT — FILE STORAGE (add as non-custodial data sources):' -LogFile $logFile -ForegroundColor Green
                    Write-ToLogFile -StringObject '  (Ref: https://learn.microsoft.com/en-us/purview/ediscovery-teams-investigation)' -LogFile $logFile -ForegroundColor DarkGray

                    $seenTeamSP = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($ch in $stdChannelRecords) {
                        if (-not $seenTeamSP.Add($ch.GroupId)) { continue }

                        $spUrl = $ch.ParentTeamSharePointUrl
                        $isGraphResolved = $graphSpCache.ContainsKey($ch.GroupId) -and
                                           ($mgGraphConnected -or $graphTokenDirect)
                        $label = if ($isGraphResolved) { '[Graph-resolved]' } else { '[Constructed — verify if site was renamed]' }

                        Write-ToLogFile -StringObject "    $spUrl  ($($ch.TeamName)) $label" -LogFile $logFile

                        if (-not $isGraphResolved) {
                            Write-ToLogFile -StringObject '    Tip: add -ResolveSharePointUrls to obtain authoritative URLs via Microsoft Graph.' `
                                -LogFile $logFile -ForegroundColor DarkGray
                        }
                    }
                }
            }

            Write-ToLogFile -StringObject '' -LogFile $logFile
            Write-ToLogFile -StringObject ('━' * 72) -LogFile $logFile -ForegroundColor Cyan
        }

        if ($MediumDetails -and $allResults.Count -gt 0) {
            Write-ToLogFile -StringObject '' -LogFile $logFile
            $allResults | Format-Table -AutoSize -Property `
                UserPrincipalName, TeamName, GroupMailbox, ChannelName, MC1134737_Status, ComplianceTarget |
                Out-Host
        }
        elseif ($FullDetails -and $allResults.Count -gt 0) {
            Write-ToLogFile -StringObject '' -LogFile $logFile
            $allResults | Format-List | Out-Host
        }

        Write-ToLogFile -StringObject 'Get-TeamsPrivateChannelComplianceMap completed.' -LogFile $logFile
        Write-ToLogFile -StringObject $separator -LogFile $logFile
        Write-ToLogFile -StringObject 'Done.' -LogFile $logFile -ForegroundColor Green
        Write-ToLogFile -StringObject "Log file written to: $logFile" -LogFile $logFile -ForegroundColor Cyan
    }
}
