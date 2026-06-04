function Write-ToLogFile {
    <#
        .SYNOPSIS
            Save output to a log file
        .DESCRIPTION
            Overload function for Write-Output that writes a string to both the console
            and a persistent log file. Creates the log directory if it does not exist.
        .PARAMETER StringObject
            The message string to write to the console and log file.
        .PARAMETER LogDirectory
            Full path to the directory where the log file will be stored.
            Defaults to ".\Logs".
        .PARAMETER LogFile
            Full path to a specific log file. When supplied, LogDirectory is ignored.
        .PARAMETER ForegroundColor
            Optional console foreground color for the output.
        .PARAMETER LogOnly
            When specified, writes to the log file only — suppresses console output.
        .EXAMPLE
            Write-ToLogFile "$(Get-TimeStamp) Connecting to Microsoft Teams"
        .EXAMPLE
            Write-ToLogFile -StringObject "$(Get-TimeStamp) Query complete" -LogDirectory "C:\Reports\Logs"
        .NOTES
            Depends on Get-TimeStamp for formatted timestamps.
    #>
    [OutputType('System.String')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$StringObject,

        [Parameter()]
        [string]$LogDirectory = ".\Logs",

        [Parameter()]
        [string]$LogFile,

        [Parameter()]
        [System.ConsoleColor]$ForegroundColor,

        [Parameter()]
        [switch]$LogOnly
    )

    process {
        # Resolve the target log file path
        $targetFile = if ($PSBoundParameters.ContainsKey('LogFile')) {
            $LogFile
        }
        else {
            Join-Path $LogDirectory "Logging.txt"
        }

        $targetDir = Split-Path $targetFile -Parent
        if (-not (Test-Path -Path $targetDir)) {
            if ($PSCmdlet.ShouldProcess($targetDir, "Create logging directory")) {
                try {
                    New-Item -Path $targetDir -ItemType Directory -ErrorAction Stop | Out-Null
                }
                catch {
                    Write-Output "$(Get-TimeStamp) ERROR: Could not create log directory '$targetDir': $_"
                    return
                }
            }
        }

        try {
            if (-not $LogOnly -and $StringObject -ne '') {
                if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
                    Write-Host $StringObject -ForegroundColor $ForegroundColor
                }
                else {
                    Write-Host $StringObject
                }
            }
            $logEntry = if ($StringObject -ne '') { "$(Get-TimeStamp) $StringObject" } else { $StringObject }
            Out-File -FilePath $targetFile -InputObject $logEntry -Encoding utf8 -Append -ErrorAction Stop
        }
        catch {
            Write-Output "$(Get-TimeStamp) ERROR: Could not write to log file: $_"
            return
        }
    }
}
