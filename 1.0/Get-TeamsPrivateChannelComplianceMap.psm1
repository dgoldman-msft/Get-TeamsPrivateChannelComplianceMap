# Get-TeamsPrivateChannelComplianceMap.psm1
# Module loader — dot-sources all internal helpers then the public function.

# Internal helper functions
. (Join-Path $PSScriptRoot 'internal\functions\Get-TimeStamp.ps1')
. (Join-Path $PSScriptRoot 'internal\functions\Write-ToLogFile.ps1')

# Public function
. (Join-Path $PSScriptRoot 'functions\Get-TeamsPrivateChannelComplianceMap.ps1')

# Register default format view for TeamsPrivateChannelComplianceMap.Record.
# Using Update-FormatData here (rather than FormatsToProcess in the manifest)
# avoids the execution-policy signing requirement for ps1xml files when the
# module is loaded from a remote or downloaded location.
$formatFile = Join-Path $PSScriptRoot 'xml\Get-TeamsPrivateChannelComplianceMap.Format.ps1xml'
if (Test-Path $formatFile) {
    Update-FormatData -AppendPath $formatFile
}

# Export public API
Export-ModuleMember -Function 'Get-TeamsPrivateChannelComplianceMap' -Alias 'GTPCCM'
