#************************************************************************************************************
# Disclaimer
#
# This script is not supported under any Microsoft standard support program or service. This 
# script is provided AS IS without warranty of any kind. Microsoft further disclaims all implied warranties
# including, without limitation, any implied warranties of merchantability or of fitness for a particular
# purpose. The entire risk arising out of the use or performance of this script and documentation
# remains with you. In no event shall Microsoft, its authors, or anyone else involved in the creation,
# production, or delivery of this script be liable for any damages whatsoever (including, without limitation,
# damages for loss of business profits, business interruption, loss of business information, or other
# pecuniary loss) arising out of the use of or inability to use this sample script or documentation, even
# if Microsoft has been advised of the possibility of such damages.
#
#************************************************************************************************************

<#-----------------------------------------------------------------------------
Tino Donderwinkel, Cloud Solution Architect
tinodo@microsoft.com
April, 2019

This script is provided "AS IS" with no warranties, and confers no rights.

Version 1.0
-----------------------------------------------------------------------------#>

<#

This script will stop Windows servers.

Requirements and Dependencies:

- Must be run on a Hybrid Worker.

Output:

- An array of servernames that could be stopped.

#>

workflow StopWindowsServers
{

    Param
    (
      [Parameter (Mandatory= $true)]
      [String[]]
      $ServerNames
    )

    [OutputType([String])]

    $Result = @()

    Write-Verbose "Stopping Windows Servers: $($ServerNames -join ', ')"

    Foreach -Parallel ($ServerName in $ServerNames)
    {
        $Item = InlineScript
        {
            try
            {
                Write-Verbose "Stopping Windows Server $Using:ServerName"
                Stop-Computer -ComputerName $Using:ServerName -Force -ErrorAction Stop
                return $Using:ServerName
            }
            catch
            {
                Write-Error -Message "Could not stop Windows Server $Using:ServerName"
            }
        }

        if ($Item)
        {
            [string[]]$Workflow:Result += $Item
        }
    }

    Write-Verbose "Stopped Windows Servers: $($Result -join ', ')"

    Write-Output $Result
}