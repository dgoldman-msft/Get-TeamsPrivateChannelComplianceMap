function Get-TimeStamp {
    <#
        .SYNOPSIS
            Get a time stamp
        .DESCRIPTION
            Get a date and time to create a custom time stamp
        .EXAMPLE
            Get-TimeStamp
            Returns a formatted timestamp string like "[06/03/26 14:22:01] -"
        .NOTES
            Internal function
    #>
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    param()
    return "[{0:MM/dd/yy} {0:HH:mm:ss}] -" -f (Get-Date)
}
