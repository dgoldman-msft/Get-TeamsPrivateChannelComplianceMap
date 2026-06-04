@{
    RootModule        = 'Get-TeamsPrivateChannelComplianceMap.psm1'
    ModuleVersion     = '1.0'
    GUID              = 'b2c4d8f1-e376-4a9b-8c5d-1f2e3a4b5c6d'
    Author            = 'Dave Goldman'
    CompanyName       = ' '
    Copyright         = '(c) Dave Goldman. All rights reserved.'
    Description       = 'Maps a Microsoft Teams custodian''s private channel memberships to eDiscovery content locations to close the compliance gap created by MC1134737.'
    PowerShellVersion = '7.1'
    RequiredModules   = @()
    FormatsToProcess  = @()
    FunctionsToExport = @('Get-TeamsPrivateChannelComplianceMap')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('GTPCCM')
    PrivateData       = @{
        PSData = @{
            Tags         = @('M365', 'MicrosoftTeams', 'eDiscovery', 'Compliance', 'PrivateChannels', 'MC1134737', 'Purview', 'Teams')
            ProjectUri   = 'https://github.com/dgoldman-msft/Get-TeamsPrivateChannelComplianceMap'
            LicenseUri   = 'https://github.com/dgoldman-msft/Get-TeamsPrivateChannelComplianceMap/blob/main/LICENSE'
            ReleaseNotes = '1.0 - Initial release'
        }
    }
}
