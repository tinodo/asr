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

Version 1.1
-----------------------------------------------------------------------------#>

<#

On the taget servers, the Windows Firewall should allow File and Printer Sharing and WMI connections.
This can be configured by running the following commands on the hosts:

netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=yes
netsh advfirewall firewall set rule group="windows management instrumentation (wmi)" new enable=yes

#>
workflow InstallWindowsMobilityService
{

    Param
    (
      [Parameter (Mandatory= $true)]
      [String[]]
      $ServerNames
    )

    $ConfigurationServerIP = Get-AutomationVariable -Name "ConfigurationServerIP"
    $ConfigurationServerPassphrase = Get-AutomationVariable -Name "ConfigurationServerPassphrase"
    
    ForEach -Parallel ($ServerName in $ServerNames)
    {
        InlineScript
        {
            # 181MB = Installed version
            # 128MB = Source files
            # 134MB = Extracted files
            # 50MB = Just to be sure

            $requiredSpace = 181 + 128 + 134 + 50
            $agentInstallerLocation = "F:\Microsoft Azure Site Recovery\home\svsystems\admin\web\sw\Microsoft-ASR_UA_9.23.0.0_Windows_GA_20Feb2019_Release.exe"
            $installFile = $env:TEMP + "\install.bat"
            $skipCDrive = $false # Prevent working directory on C drive
            $workingDirectory = "\MobilityService" # Working directory on the taget server
            $parentMustExist = $true

            $installationDirectory = "\Program Files (x86)\Microsoft Azure Site Recovery"

            $configurationServerIP = $Using:ConfigurationServerIP
            $server = $Using:ServerName
            $passphrase = $Using:ConfigurationServerPassphrase

            if ($parentMustExist -and ((Split-Path "x:$workingDirectory" -Parent) -eq "x:\"))
            {
                $parentMustExist = $false
            }

            $drives=Get-WmiObject -Namespace root\cimv2 -Class Win32_LogicalDisk -ComputerName $server
            if ($?)
            {
                $done = $false
                foreach ($drive in $drives)
                {    
                    $drivename = $drive.DeviceID.ToUpper()[0]

                    if ($skipCDrive -and ($drivename -eq "C"))
                    {
                        continue
                    }

                    $freespace = [int]($drive.FreeSpace/1MB)
                    $destination = "\\$server\$drivename`$"
                    if ($freespace -gt $requiredSpace)
                    {
                        $destination += $workingDirectory
                        if ($parentMustExist -and !(Test-Path -Path (Split-Path $destination -Parent)))
                        {
                            continue
                        }

                        Write-Output "Installing to $destination..."
                
                        # Create working directory
                        $folder = New-Item -ItemType Directory -Force -Path $destination

                        # Create installation batch file in temp folder
                        Set-Content -Path $installFile -Value "$drivename`:$workingDirectory`\MobilityServiceInstaller.exe /q /x:$drivename`:$workingDirectory`\Extracted"
                        Add-Content -Path $installFile -Value "$drivename`:$workingDirectory`\Extracted\UnifiedAgent.exe /Role `"MS`" /InstallLocation `"$drivename`:$installationDirectory`" /Platform `"VmWare`" /Silent"
                        Add-Content -Path $installFile -Value "START `"`" /WAIT `"$drivename`:$installationDirectory`\agent\UnifiedAgentConfigurator.exe`" /CSEndPoint $configurationServerIP /PassphraseFilePath `"$drivename`:$workingDirectory`\passphrase.txt`""
                
                        # Copy Mobility Service Installer
                        Copy-Item $agentInstallerLocation -Destination "$destination`\MobilityServiceInstaller.exe"
                        # Copy Installation Batch File
                        Copy-Item $installFile -Destination $destination # Copy installation batch file
                        # Create Passphrase File
                        Set-Content -Path "$destination`\passphrase.txt" -Value $passphrase # Create passphrase.txt file

                        # Start Installation Batch File
                        $process = Invoke-WmiMethod -ComputerName $server -Namespace root\cimv2 -Class Win32_Process -Name Create -ArgumentList "$drivename`:$workingDirectory`\install.bat"
                        $processId = $process.ProcessId
                        Write-Output "Waiting for installation (process id $processId) on server $server to finish"
                        do
                        {
                            Start-Sleep -Seconds 5
                            $process = Get-WmiObject -Namespace root\cimv2 -Class Win32_Process -ComputerName $server -Filter "ProcessId = $processId"
                        } while ($process)
                
                        # Installation complete, check if everything worked out.

                        $service1 = Get-WmiObject -ComputerName $server -Class Win32_Service -Filter "DisplayName='InMage Scout Application Service'"
                        $service2 = Get-WmiObject -ComputerName $server -Class Win32_Service -Filter "DisplayName='InMage Scout FX Agent'"
                        $service3 = Get-WmiObject -ComputerName $server -Class Win32_Service -Filter "DisplayName='InMage Scout VX Agent - Sentinel/Outpost'"

                        if ((($service1.State -eq "Running") -and ($service1.StartMode -eq "Auto") -and ($service1.Status -eq "OK")) -and `
                            (($service2.State -eq "Stopped") -and ($service2.StartMode -eq "Manual") -and ($service2.Status -eq "OK")) -and `
                            (($service3.State -eq "Running") -and ($service3.StartMode -eq "Auto") -and ($service3.Status -eq "OK")))
                        {
                            # Clean up
                            Get-ChildItem $destination -Recurse | Remove-Item -Force -Recurse
                            Remove-Item $destination -Force
                            Write-Output "Server $server done."
                        }
                        elseif ((($service1.State -eq "Stopped") -and ($service1.StartMode -eq "Manual") -and ($service1.Status -eq "OK")) -and `
                            (($service2.State -eq "Stopped") -and ($service2.StartMode -eq "Manual") -and ($service2.Status -eq "OK")) -and `
                            (($service3.State -eq "Stopped") -and ($service3.StartMode -eq "Manual") -and ($service3.Status -eq "OK")))
                        {
                            $message = "Services are successfully installed on server $server, but the Mobility Service could not register to the Configuration Server."
                            Write-Error $message
                            Write-Output $message
                            #TODO: Uninstall the agent?
                        }
                        else
                        {
                            $message = "Installation on server $server failed."
                            Write-Error $message
                            Write-Output $message
                        }

                        $done = $true

                        break
                    } 
                }

                if (!$done)
                {
                    $message = "Could not find suitable drive on server $server"
                    Write-Error $message
                    Write-Output $message
                }
            }
            else
            {
                $message = "Unable to access server $server"
                Write-Error $message
                Write-Error $error[0].Exception
                Write-Output $message
            }

        }
    
    }
    Write-Output "Done."
}