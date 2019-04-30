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

This script will stop Linux servers.

Requirements and Dependencies:

- Must be run on a Hybrid Worker with local administrator privileges (to install the WinSCP module should it not be available).
- Automation Credential "SourceEnvironmentLinuxAdministrator": Credentials for managing the Linux servers. (Typically 'root'.)

Output:

- Array with all the names of stopped servers.

#>

workflow StopLinuxServers
{

    Param
    (
      [Parameter (Mandatory= $true)]
      [String[]]
      $ServerNames
    )
        
    $Credential = Get-AutomationPSCredential -Name "SourceEnvironmentLinuxAdministrator"

    Write-Verbose "Stopping Linux Servers: $($ServerNames -join ', ')"

    if (-not (Get-Module -ListAvailable -Name WinSCP)) {
        Write-Verbose "Installing module WinSCP..."
        Install-Module -Name WinSCP -Force -Verbose:$false
    }

    $Result = @()

    ForEach -Parallel ($ServerName in $ServerNames)
    {
        $Workflow:Result += InlineScript
        {
            Import-Module -Name WinSCP -Verbose:$false

            $sessionOption = New-WinSCPSessionOption -HostName $Using:ServerName -Protocol Sftp -Credential $Using:Credential -GiveUpSecurityAndAcceptAnySshHostKey
            $success = $false

            try
            {
                Write-Verbose "Stopping Linux Server $Using:ServerName"
                $session = New-WinSCPSession -SessionOption $sessionOption -ErrorAction Stop
                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo shutdown now"
                $result.Check()
            }
            catch
            {
                if ($_.Exception.Message -match "Server unexpectedly closed network connection.")
                {
                    Write-Verbose "Linux Server $Using:ServerName stopped"
                    $success = $true
                }
                else
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
            }
            finally
            {
                if ($session)
                {
                    Remove-WinSCPSession -WinSCPSession $session
                }
            }

            if ($success)
            {
                return $Using:ServerName
            }
        }
    }

    Write-Verbose "Stopped Linux Servers: $($Result -join ', ')"
    Write-Output $Result
}