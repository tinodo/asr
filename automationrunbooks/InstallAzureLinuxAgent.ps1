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

This script will instal the Azure VM Agent on Linux servers.
Check https://docs.microsoft.com/en-us/azure/virtual-machines/extensions/update-linux-agent
Requirements and Dependencies:

- Must be run on a Hybrid Worker with local administrator privileges (to install the WinSCP module should it not be available).
- Automation Credential "SourceEnvironmentLinuxAdministrator": Credentials for managing the Linux servers. (Typically 'root'.)

Output:

- Array of strings with servernames where the agent was installed.

#>

workflow InstallAzureLinuxAgent
{
    Param
    (
      [Parameter (Mandatory= $true)]
      [String[]]
      $ServerNames
    )

    $Credential = Get-AutomationPSCredential -Name "SourceEnvironmentLinuxAdministrator"
    $ASRInstallPath = "F:\Microsoft Azure Site Recovery" # Leave empty to copy files from below storage account.
    # copy from storage account currently not implemented. Check InstallLinuxMobilityService.ps1 for the code.

    if (-not (Get-Module -ListAvailable -Name WinSCP)) {
        Write-Verbose "Installing module WinSCP..."
        Install-Module -Name WinSCP -Force -Verbose:$false
    }

    $Result = @()

    ForEach -Parallel ($ServerName in $ServerNames)
    {
        $Success = InlineScript
        {
            try
            {
                $success = $false
                $sessionOption = New-WinSCPSessionOption -HostName $Using:ServerName -Protocol Sftp -Credential $Using:Credential -GiveUpSecurityAndAcceptAnySshHostKey
                $transferOption = New-WinSCPTransferOption -TransferMode Binary
                $session = New-WinSCPSession -SessionOption $sessionOption -ErrorAction Stop

                if ($Using:ASRInstallPath)
                {
                    $sourceFile = Join-Path $Using:ASRInstallPath "home\svsystems\pushinstallsvc\OS_details.sh"
                }
                else
                {
                    $sourceFile = Join-Path $Using:TargetFolder "OS_details.sh"
                }

                $result = Send-WinSCPItem -WinSCPSession $session -LocalPath $sourceFile -TransferOptions $transferOption
                $result.Check()

                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sh OS_details.sh foo"
                $result.Check()

                $os = $result.Output.Split(":")[0]
                if ($os -eq "Unsupported")
                {
                    Write-Error -Message "Server $($Using:ServerName) has unsupported operating system $($result.Output)"
                    return $false
                }

                #Remove-WinSCPItem lacks -Force and can therefore not be used here.
                #Remove-WinSCPItem -WinSCPSession $session -Path "OS_details.sh"
                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "rm OS_details.sh"

                Write-Verbose "OS: $os"

                if ($os -match "UBUNTU")
                {
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo apt-get -qq update"
                    $result.Check()
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo apt-get install walinuxagent"
                    $result.Check()
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo sed -i 's/# AutoUpdate.Enabled=n/AutoUpdate.Enabled=y/g' /etc/waagent.conf"
                    $result.Check()

                    if ($os -match "14.04")
                    {
                        $command = "sudo initctl restart walinuxagent"
                    }
                    else
                    {
                        $command = "sudo systemctl restart walinuxagent.service"
                    }

                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command $command
                    $result.Check()
                }
                elseif ($os -match "DEBIAN7")
                {
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo apt-get -qq update"
                    $result.Check()                    
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo apt-get install waagent"
                    $result.Check()
                }
                elseif ($os -match "DEBIAN8")
                {
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo apt-get -qq update"
                    $result.Check()                    
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo apt-get install waagent"
                    $result.Check()
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo sed -i 's/# AutoUpdate.Enabled=n/AutoUpdate.Enabled=y/g' /etc/waagent.conf"
                    $result.Check()
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo systemctl restart walinuxagent.service"
                    $result.Check() 
                }
                elseif ($os -match "RHEL6")
                {
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo yum install WALinuxAgent"
                    $result.Check() 
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo sed -i 's/\# AutoUpdate.Enabled=y/AutoUpdate.Enabled=y/g' /etc/waagent.conf"
                    $result.Check()                     
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo service waagent restart"
                    $result.Check()
                }
                elseif ($os -match "RHEL7")
                {
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo yum install WALinuxAgent"
                    $result.Check() 
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo sed -i 's/\# AutoUpdate.Enabled=y/AutoUpdate.Enabled=y/g' /etc/waagent.conf"
                    $result.Check()                     
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo systemctl restart waagent.service"
                    $result.Check()
                }
                elseif ($os -match "SLES11-SP4")
                {
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo zypper install python-azure-agent"
                    $result.Check() 
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo sed -i 's/# AutoUpdate.Enabled=n/AutoUpdate.Enabled=y/g' /etc/waagent.conf"
                    $result.Check()                     
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo /etc/init.d/waagent restart"
                    $result.Check()
                }
                elseif ($os -match "SLES12")
                {
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo zypper install python-azure-agent"
                    $result.Check() 
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo sed -i 's/# AutoUpdate.Enabled=n/AutoUpdate.Enabled=y/g' /etc/waagent.conf"
                    $result.Check()                     
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo systemctl restart waagent.service"
                    $result.Check()
                }
                elseif (($os -match "OL6") -or ($os -match "OL7"))
                {
                    # Not implemented yet. Check https://docs.microsoft.com/en-us/azure/virtual-machines/extensions/update-linux-agent
                }
                else
                {
                    # Not implemented yet. Check https://docs.microsoft.com/en-us/azure/virtual-machines/extensions/update-linux-agent
                }

                $success = $true
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

            return $success
        }

        if ($Success)
        {
            $Workflow:Result += $ServerName
        }
    }

    Write-Output $Result  
}