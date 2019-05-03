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

    This script needs to run in a Hyrbid Worker, since WinSCP can only be used there.
    Needs a fix on the hybrid servers:
    locate Orchestrator.Sandbox.exe (normally: C:\Program Files\Microsoft Monitoring Agent\Agent\AzureAutomation\7.3.396.0\HybridAgent)
    create a file there called Orchestrator.Sandbox.exe.config with this content:

    <?xml version="1.0" encoding="utf-8"?>
    <configuration>
      <runtime>
        <AppContextSwitchOverrides value="Switch.System.IO.UseLegacyPathHandling=false" />
      </runtime>
    </configuration>

    This script is designed to be ran from the Configuration Server. If this is not the case, make sure you can find and copy the scripts.

    Check https://docs.microsoft.com/en-us/azure/site-recovery/vmware-azure-mobility-install-configuration-mgr#deploy-on-linux-machines

#>

workflow InstallLinuxMobilityService
{
    Param
    (
      [Parameter (Mandatory= $true)]
      [String[]]
      $ServerNames
    )

    $RunAsConnectionName = "AzureRunAsConnection"
    $RunAsCertName = "AzureRunAsCertificate"
    $SubscriptionId = ""
    $RunAsConnection = Get-AutomationConnection -Name $RunAsConnectionName
    $Certificate = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $RunAsConnection.CertificateThumbprint }
    
    $ConfigurationServerIP = Get-AutomationVariable -Name "ConfigurationServerIP"
    $ConfigurationServerPassphrase = Get-AutomationVariable -Name "ConfigurationServerPassphrase"
    $Credential = Get-AutomationPSCredential -Name "SourceEnvironmentLinuxAdministrator"

    $ASRInstallPath = "F:\Microsoft Azure Site Recovery" # Leave empty to copy files from below storage account.

    $StorageAccountName = ""
    $StorageAccountResourceGroupName = ""
    $StorageContainerName = ""
    $SourceFiles = @(
        "OS_details.sh"
    )
    $TargetFolder = $env:TEMP
    $InstallationFolder = "/usr/local/ASR"
    $TmpFolder = "/tmp/MobSvc"

    if (-not (Get-Module -ListAvailable -Name WinSCP)) {
        Write-Verbose "Installing module WinSCP..."
        Install-Module -Name WinSCP -Force -Verbose:$false
    }

    #region Install RunAs Certificate (if required)

    if (-not $Certificate)
    {
        $RunAsCert = Get-AutomationCertificate -Name $RunAsCertName

        if ($RunAsCert.Thumbprint -ne $RunAsConnection.CertificateThumbprint)
        {
            $Message = "Certificate in the RunAsConnection ($RunAsConnectionName) does not match the AutomationCertificate ($RunAsCertName)"
            Write-Error $Message
            throw $Message
        }

        $null = Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $Password = [System.Web.Security.Membership]::GeneratePassword(25, 10)
        $CertPath = Join-Path $env:temp "AzureRunAsCertificate.pfx"
        $Cert = $RunAsCert.Export("pfx",$Password)
        Set-Content -Value $Cert -Path $CertPath -Force -Encoding Byte | Write-Verbose
        $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
        Import-PfxCertificate -FilePath $CertPath -CertStoreLocation Cert:\LocalMachine\My -Password $SecurePassword -Exportable | Write-Verbose
        Remove-Item -Path $CertPath
    }

    #endregion

    #region Connect to Azure

    try
    {
       Write-Verbose "Connecting to Azure..."

       $Connection = Connect-AzAccount `
           -ServicePrincipal `
           -Tenant $RunAsConnection.TenantId `
           -ApplicationId $RunAsConnection.ApplicationId `
           -CertificateThumbprint $RunAsConnection.CertificateThumbprint `
           -Subscription $SubscriptionId `
           -ErrorAction Stop

        Write-Verbose "Connected to Azure."
        Write-Verbose $Connection     
    }
    catch 
    {
        if (!$ServicePrincipalConnection)
        {
           $ErrorMessage = "Azure Run-As Connection $ConnectionName not found."
           throw $ErrorMessage
        }
        else
        {
           Write-Error -Message $_.Exception
           throw $_.Exception
        }
    }

    #endregion


    #region Download required libraries...
    if (-not $ASRInstallPath)
    {
        try
        {
            $StorageAccountKey = Get-AzStorageAccountKey -Name $StorageAccountName -ResourceGroupName $StorageAccountResourceGroupName 
            $StorageKey = $StorageAccountKey[0].Value
            InlineScript
            {
                $StorageContext = New-AzStorageContext -StorageAccountName $Using:StorageAccountName -StorageAccountKey $Using:StorageKey  
                foreach ($SourceFile in $Using:SourceFiles)
                {      
                    $result = Get-AzStorageBlobContent -Blob $SourceFile -Container $Using:StorageContainerName -Destination $Using:TargetFolder -Context $StorageContext.Context -Force
                }
            }
        }
        catch 
        {
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
    }

    #endregion

    Set-Content -Path "$TargetFolder`\passphrase.txt" -Value $ConfigurationServerPassphrase # Create passphrase.txt file

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

                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo cat /usr/local/.vx_version"
                    
                $install = $false
                $upgrade = $false
                $configure = $false
                if ($result.IsSuccess)
                {
                    # already installed.
                    $state = $result.Output.Split([Environment]::NewLine) | Where {$_.StartsWith("AGENT_CONFIGURATION_STATUS=")}
                    if ($state)
                    {
                        $state = $state.Split("=")[1]
                    }

                    if ($state -eq "Succeeded")
                    {
                        $install = $false
                        $upgrade = $true
                        $configure = $true
                    }
                    else
                    {
                        $install = $false
                        $upgrade = $false
                        $configure = $true
                    }
                }
                else
                {
                    $install = $true
                    $upgrade = $false
                    $configure = $true
                }

                Write-Verbose "Server $($Using:ServerName) has operating system $os. The following acion(s) will be performed: Install: $install, Upgrade: $upgrade, Configure: $configure"

                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "sudo rm -rf $($Using:TmpFolder)"
                $result.Check()

                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "mkdir -p $($Using:TmpFolder)"
                $result.Check()

                $result = Send-WinSCPItem -WinSCPSession $session -LocalPath "$Using:TargetFolder`\passphrase.txt" -RemotePath "$Using:TmpFolder`/passphrase.txt" -TransferOptions $transferOption
                $result.Check()

                if ($install -or $upgrade)
                {
                    if ($Using:ASRInstallPath)
                    {
                        $sourceFiles = Join-Path $Using:ASRInstallPath "home\svsystems\admin\web\sw\*$os*.*"
                    }
                    else
                    {
                        $sourceFiles = Join-Path $Using:TargetFolder "*$os*.*"
                    }

                    $result = Send-WinSCPItem -WinSCPSession $session -LocalPath $sourceFiles -RemotePath "$Using:TmpFolder`/" -TransferOptions $transferOption
                    $result.Check()

                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "for i in $($Using:TmpFolder)/*.tar.gz; do tar xvzf `$i -C $($Using:TmpFolder); done"
                    $result.Check()
                        
                    if ($install)
                    {
                        $command = "cd " + $Using:TmpFolder + "; sudo ./install -q -d $($Using:InstallationFolder) -r MS -v VmWare"
                        $result = Invoke-WinSCPCommand -WinSCPSession $session -Command $command
                        
                        if ($result.IsSuccess -and ($result.ExitCode -eq 0))
                        {
                            Write-Verbose "Successfully installed the Mobility Service on server $($Using:ServerName)"
                        }
                        else
                        {
                            Write-Error -Message "Cloud not install the Mobility Service on server $($Using:ServerName)"
                            Write-Error -Message "Output: $($result.ErrorOutput)"
                            Write-Error -Message "Result: $($result.Output)"
                            Write-Error -Message "IsSuccess: $($result.IsSuccess)"
                            Write-Error -Message "ExitCode: $($result.ExitCode)"
                            $configure = $false
                        }                         
                    }
                    elseif ($upgrade)
                    {
                        $command = "cd " + $Using:TmpFolder + ";sudo ./install -q -v VmWare"
                        $result = Invoke-WinSCPCommand -WinSCPSession $session -Command $command
                        if ($result.IsSuccess -and ($result.ExitCode -eq 0))
                        {
                            Write-Verbose "Successfully upgraded the Mobility Service on server $($Using:ServerName)"
                            $success = $true
                        }
                        elseif ((-not $result.IsSuccess) -and ($result.ExitCode -eq 209))
                        {
                            Write-Verbose "Successfully upgraded the Mobility Service on server $($Using:ServerName), but the server needs to be rebooted!"
                            $success = $true                            
                        }
                        else
                        {
                            Write-Error -Message "Cloud not upgrade the Mobility Service on server $($Using:ServerName)"
                            Write-Error -Message "Output: $($result.ErrorOutput)"
                            Write-Error -Message "Result: $($result.Output)"
                            Write-Error -Message "IsSuccess: $($result.IsSuccess)"
                            Write-Error -Message "ExitCode: $($result.ExitCode)"
                            $configure = $false
                        }    
                    }
                }

                if ($configure)
                {
                    $command = "sudo $($Using:InstallationFolder)/Vx/bin/UnifiedAgentConfigurator.sh -i $($Using:ConfigurationServerIP) -P $($Using:TmpFolder)/passphrase.txt"
                    $result = Invoke-WinSCPCommand -WinSCPSession $session -Command $command
                    if ($result.IsSuccess -and ($result.ExitCode -eq 0))
                    {
                        Write-Verbose "Successfully configured the Mobility Service on server $($Using:ServerName)"
                        $success = $true
                    }
                    else
                    {
                        Write-Error -Message "Cloud not configure the Mobility Service on server $($Using:ServerName)"
                        Write-Error -Message "Output: $($result.ErrorOutput)"
                        Write-Error -Message "Result: $($result.Output)"
                        Write-Error -Message "IsSuccess: $($result.IsSuccess)"
                        Write-Error -Message "ExitCode: $($result.ExitCode)"
                    }  
                }
                    
                $result = Invoke-WinSCPCommand -WinSCPSession $session -Command "rm -rf $($Using:TmpFolder)"
            }
            catch
            {
                Write-Error "$($Using:ServerName) Error: $($_.Exception.Message)"
            }
            finally
            {
                if ($session)
                {
                    $session.Dispose()
                }
            }

            return $success
        }

        if ($success)
        {
            $Workflow:Result += $ServerName
        }
    }

    Write-Output $Result   
}