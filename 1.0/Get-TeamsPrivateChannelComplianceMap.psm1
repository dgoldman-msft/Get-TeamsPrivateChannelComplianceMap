# Get-TeamsPrivateChannelComplianceMap.psm1
# Module loader — dot-sources all internal helpers then the public function.

# Internal helper functions
. (Join-Path $PSScriptRoot 'internal\functions\Get-TimeStamp.ps1')
. (Join-Path $PSScriptRoot 'internal\functions\Write-ToLogFile.ps1')

# Public function
. (Join-Path $PSScriptRoot 'functions\Get-TeamsPrivateChannelComplianceMap.ps1')

# Export public API
Export-ModuleMember -Function 'Get-TeamsPrivateChannelComplianceMap' -Alias 'GTPCCM'
