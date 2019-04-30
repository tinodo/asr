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
Apri, 2019

This script is provided "AS IS" with no warranties, and confers no rights.

Version 1.0
-----------------------------------------------------------------------------#>


<#

This script will stop services on Windows servers which loose match the names defined in $ServicesNeedStopping (a string array).

Requirements and Dependencies:

- Must be run on a Hybrid Worker with local administrator privileges (to install the PendingReboot module should it not be available).

Output:

- Hashtable with all servernames and the services stopped on these servers.

#>

workflow StopWindowsServices
{

    Param
    (
      [Parameter (Mandatory= $true)]
      [String[]]
      $ServerNames
    )

    [OutputType([hashtable])]

    $ServicesNeedStopping = @(
        "SQL",
        "NFS",
        "SAP",
        "World Wide Web Publishing",
        "JBoss",
        "MySQL"
    )

    Write-Verbose "Stopping services on $($ServerNames -join ', ')"

    if (-not (Get-Module -ListAvailable -Name PendingReboot)) {
        Write-Verbose "Installing module PendingReboot..."
        Install-Module -Name PendingReboot -Force -Verbose:$false
    }

    $Result = @{}

    ForEach -Parallel ($ServerName in $ServerNames)
    {
        $Item = InlineScript
        {
            Write-Verbose "Stopping services on Windows Server $Using:ServerName."
            Import-Module -Name PendingReboot -Verbose:$false

            $maxRunningTime = 60
            $stoppedServices = @()

            try
            {
                $rebootPending = Test-PendingReboot -ComputerName $Using:ServerName -SkipConfigurationManagerClientCheck -WarningAction SilentlyContinue
                if ($rebootPending -and $rebootPending.IsRebootPending)
                {
                    Write-Verbose "WARNING: Server $Using:ServerName is pending a reboot."
                }

                $services = Get-Service -ComputerName $Using:ServerName | where {$_.Status -eq "Running"}

                foreach ($service in $services)
                {
                    $shouldStop = $Using:ServicesNeedStopping | foreach {$isMatch = $false} {$isMatch = $isMatch -or ($service.DisplayName -match $_)} {$isMatch}
                    if ($shouldStop)
                    {
                        Write-Verbose "Stopping service $($service.DisplayName) on server $Using:ServerName"
                        try
                        {
                            $service | Stop-Service -Force
                        }
                        catch
                        {
                            Write-Verbose "Could not stop service $($service.DisplayName) on server $Using:ServerName"
                            Write-Error $_.Exception.Message
                            continue
                        }

                        $start = Get-Date
                        $runningTime = 0
                        while (($service.Status.ToString() -ne "Stopped") -and ($runningTime -le $maxRunningTime))
                        {
                            Start-Sleep -Seconds 1
                            $service.Refresh()
                            $now = Get-Date
                            $age = New-TimeSpan -Start $start -End $now
                            $runningTime = $age.TotalSeconds
                        }

                        if ($service.Status.ToString() -ne "Stopped")
                        {
                            $message = "Could not stop service $($service.DisplayName) on server $Using:ServerName. The request timed out after $maxRunningTime seconds. Current state: $($service.Status)"
                            Write-Verbose $message
                            Write-Error $message
                        }
                        else
                        {
                            Write-Verbose "Service $($service.DisplayName) on server $Using:ServerName was stopped."
                            $stoppedServices += $service.DisplayName
                        }
                    }
                }
            }
            catch
            {
                Write-Verbose "Failed to process server $Using:ServerName."
                Write-Error $_.Exception.Message
            }

            return @{$Using:ServerName = $stoppedServices}
        }

        $Workflow:Result += $Item
    }

    Write-Output $Result
}