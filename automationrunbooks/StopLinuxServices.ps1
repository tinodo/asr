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

This script will stop services on Linux servers which loose match the names defined in $ServicesNeedStopping (a string array).

Requirements and Dependencies:

- Must be run on a Hybrid Worker with local administrator privileges (to install the WinSCP module should it not be available).
- Automation Credential "SourceEnvironmentLinuxAdministrator": Credentials for managing the Linux servers. (Typically 'root'.)

Output:

- Hashtable with all servernames and the services stopped on these servers.

#>

workflow StopLinuxServices
{

    Param
    (
      [Parameter (Mandatory= $true)]
      [String[]]
      $ServerNames
    )

    [OutputType([hashtable])]
    
    $Credential = Get-AutomationPSCredential -Name "SourceEnvironmentLinuxAdministrator"
    $ServicesNeedStopping = @(
        "mysql",
        "apache2",
        "oracle"
    )

    Write-Verbose "Stopping services on $($ServerNames -join ', ')"

    if (-not (Get-Module -ListAvailable -Name WinSCP)) {
        Write-Verbose "Installing module WinSCP..."
        Install-Module -Name WinSCP -Force -Verbose:$false
    }

    $Result = @{}

    ForEach -Parallel ($ServerName in $ServerNames)
    {
        $Item = InlineScript
        {
            Write-Verbose "Stopping services on Linux Server $Using:ServerName."
            Import-Module -Name WinSCP -Verbose:$false

            $stoppedServices = @()
            $sessionOption = New-WinSCPSessionOption -HostName $Using:ServerName -Protocol Sftp -Credential $Using:Credential -GiveUpSecurityAndAcceptAnySshHostKey

            try
            {
                $session = New-WinSCPSession -SessionOption $sessionOption -ErrorAction Stop

                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo stat /var/run/reboot-required"

                if ($result.ExitCode -ne 1)
                {
                    Write-Verbose "WARNING: Server $Using:ServerName is pending a reboot."
                }

                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo systemctl list-units --type service --all|grep .service|grep running"
                $result.Check()

                $services = $result.Output.Split([Environment]::NewLine) | foreach {($_.TrimStart(" ") -Split(".service"))[0]}

                foreach ($service in $services)
                {
                    $shouldStop = $Using:ServicesNeedStopping | foreach {$isMatch = $false} {$isMatch = $isMatch -or ($service -match $_)} {$isMatch}
                    if ($shouldStop)
                    {
                        Write-Verbose "Stopping service $service on server $Using:ServerName"
                        try
                        {
                            $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo systemctl stop $service"
                            $result.Check()
                            Write-Verbose "Service $service on server $Using:ServerName was stopped."
                            $stoppedServices += $service
                        }
                        catch
                        {
                            Write-Verbose "Could not stop service $service on server $Using:ServerName"
                            Write-Error $_.Exception.Message
                        }
                    }
                }
            }
            catch
            {
                if ($_.Exception.InnerException)
                {
                    Write-Verbose $_.Exception.InnerException.Message
                    Write-Error -Message $_.Exception.InnerException.Message 
                }
                else
                {
                    Write-Verbose $_.Exception.Message
                    Write-Error -Message $_.Exception.Message
                }
            }
            finally
            {
                if ($session)
                {
                    Remove-WinSCPSession -WinSCPSession $session
                }
            }
 
            return @{$Using:ServerName = $stoppedServices}
        }

        $Workflow:Result += $Item
    }

    Write-Output $Result
}