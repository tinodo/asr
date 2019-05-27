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

Version 1.14
-----------------------------------------------------------------------------#>

workflow PostMigrationRunbook
{
    param ( 
            [Object]$RecoveryPlanContext 
          ) 

    #region Variables - Modify accordingly

    $ConnectionName = "AzureRunAsConnection"
    $SubscriptionId = ""

    $CustomScriptExtension = @{
        Windows = @{
            Enable = $true
            StorageAccountResourceGroupName = ""
            StorageAccountName = ""
            StorageContainer = ""
            Run = "postmigrationscript.ps1"
            TypeHandlerVersion  ="1.1"
        }
        Linux = @{
            Enable = $true
            StorageAccountResourceGroupName = ""
            StorageAccountName = ""
            StorageContainer = ""
            Run = "sudo sh postmigrationscript.sh"
            Publisher = "Microsoft.Azure.Extensions"
            ExtensionType = "CustomScript"
            TypeHandlerVersion = "2.0"
        }
    }

    $Backup = @{
        Enable = $false
        Start = $false
        RecoveryVaultResourceGroupName = ""
        RecoveryVaultName = ""
        BackupPolicyName = ""
    }

    $BootDiagnostics = @{
        Enable = $true
        StorageAccountName = ""
        StorageAccountResourceGroupName = ""    
    }

    $Diagnostics = @{
        Windows = @{
            Enable = $true
            StorageAccountName = ""
            PublicConfigVariable = "WindowsDiagnosticsPublicConfig"    
        }
        Linux = @{
            Enable = $true
            StorageAccountName = ""
            StorageAccountResourceGroupName = ""
            PublicConfigVariable = "LinuxDiagnosticsPublicConfig"
            Publisher = "Microsoft.Azure.Diagnostics"
            ExtensionType = "LinuxDiagnostic"
            TypeHandlerVersion = "3.0"
        }    
    }

    $DiskEncryption = @{
        Enable = $true
        UseKEK = $true
        VolumeType = "All" # All, OS or Data
        KeyVaultResourceGroupName = ""
        KeyVaultName = ""
        EncryptionKeyName = ""
    }

    $Tagging = @{
        Enable = $false
        StorageAccountResourceGroupName = ""
        StorageAccountName = ""
        Table = "tags"
    }

    $ManagedIdentityResourceId = "/subscriptions/xxx/resourceGroups/yyy/providers/Microsoft.ManagedIdentity/userAssignedIdentities/zzz"
  
    $SAP = @{
        DiagnosticsStorageAccountName = ""
        Servers = @(
            "srv2",
            "srv2-test"
        )
    }

    $AutomationAccount = @{
        AutomationAccountName = ""
        ResourceGroupName = ""
        RunOn = "SourceEnvironment"
        InstallAzureLinuxAgentRunbookName = "InstallAzureLinuxAgent"
    }

    $Misc = @{
        EnableStaticIP = $true
        EnableAHUB = $true
        MaxTries = 3
    }

    #endregion

    #region Functions

    function PrepareCustomScriptExtension
    {
        Param(
            [Parameter(Mandatory = $true)]
            [ValidateSet("Windows", "Linux")]
            [String]
            $OsType,

            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [HashTable]
            $Configuration
        )

        try
        {
            $StorageAccountKey = Get-AzStorageAccountKey -Name $Configuration.StorageAccountName -ResourceGroupName $Configuration.StorageAccountResourceGroupName 
            $StorageKey = $StorageAccountKey[0].Value
            $StorageContext = New-AzStorageContext -StorageAccountName $Configuration.StorageAccountName -StorageAccountKey $StorageKey

            if ($OsType -eq "Windows")
            {
                $vmAgentFileName = "WindowsAzureVmAgent.msi"
                $vmAgentUri = "https://go.microsoft.com/fwlink/?LinkID=394789"
                $vmAgentFile = $env:TEMP + "\" + $vmAgentFileName
                $response = Invoke-WebRequest -Uri $vmAgentUri -OutFile $vmAgentFile
                $blob = Set-AzStorageBlobContent -Container $Configuration.StorageContainer -File $vmAgentFile -Blob $vmAgentFileName -Context $StorageContext -Force
            }

            $allFiles = Get-AzStorageBlob -Container $Configuration.StorageContainer -Context $StorageContext | where {$_.SnapshotTime -eq $null} | select -ExpandProperty Name
            $files = @()
            foreach ($file in ($Using:CustomScriptExtension).$OsType.AllFiles)
            {
                $files += "`"https://$($Configuration.StorageAccountName).blob.core.windows.net/$($Configuration.StorageContainer)/$file`""
            }

            $fileUris = $files -join (',')
        }
        catch 
        {
            if (!$StorageAccountKey)
            {
                $ErrorMessage = "Could not connect to the Storage Account $($Configuration.StorageAccountName)."
            }
            else
            {
                $ErrorMessage = $_.Exception
            }

            Write-Error -Message $ErrorMessage
            throw $ErrorMessage
        }

        return @{StorageKey = $StorageKey; AllFiles = $allFiles; FileUris = $fileUris}
    }

    function TryCatch
    {
        Param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]
            $Command,
            
            [Parameter(Mandatory = $true)]
            [ValidateRange(1, 10)]
            [int]
            $MaxTries,

            [Parameter(Mandatory = $true)]
            [bool]
            $ThrowOnFailure
        )

        $tries = 0
        $done = $false
        do
        {
            $scriptBlock = [Scriptblock]::Create($Command)

            try
            {
                $result = Invoke-Command -ScriptBlock $scriptBlock -ErrorAction Stop
                $done = $true
            }
            catch
            {
                Write-Error -Message $_.Exception
                $tries++
            }
        } while (($tries -lt $MaxTries) -and (-not $done))

        if ((-not $done) -and ($ThrowOnFailure))
        {
            throw "Failed"
        }

        return $result
    }

    #endregion

    Write-Output "Initializing..."

    #region Connect to Azure

    try
    {
       $ServicePrincipalConnection = Get-AutomationConnection -Name $ConnectionName         

       Write-Verbose "Connecting to Azure..."

       $Connection = Connect-AzAccount `
           -ServicePrincipal `
           -Tenant $ServicePrincipalConnection.TenantId `
           -ApplicationId $ServicePrincipalConnection.ApplicationId `
           -CertificateThumbprint $ServicePrincipalConnection.CertificateThumbprint `
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

    #region Connect to Azure Recovery Service Vault

    if ($Backup.Enable)
    {
        Write-Verbose "Connecting to Azure Recovery Services Vault..."

        try
        {
            $RecoveryServicesVaultId = Get-AzRecoveryServicesVault -ResourceGroupName $Backup.RecoveryVaultResourceGroupName -Name $Backup.RecoveryVaultName -ErrorAction Stop | select -ExpandProperty ID
        }
        catch 
        {
            if (!$RecoveryServicesVaultId)
            {
               $ErrorMessage = "Could not connect to the Azure Recovery Service Vault $RecoveryVaultName."
               throw $ErrorMessage
            }
            else
            {
               Write-Error -Message $_.Exception
               throw $_.Exception
            }
        }

        $Backup += @{"RecoveryServicesVaultId" = $RecoveryServicesVaultId}

        Write-Verbose "Connected to Azure Recovery Services Vault: $RecoveryServicesVaultId"
    }


    #endregion

    #region Building Custom Script Extension files 
    
    if ($CustomScriptExtension.Windows.Enable)
    {
        Write-Verbose "Preparing files for Custom Script Extensions for Windows..."
        
        $pcseResult = PrepareCustomScriptExtension Windows $CustomScriptExtension.Windows
        $CustomScriptExtension = InlineScript {
            $a = $Using:CustomScriptExtension
            $a.Windows += $Using:pcseResult
            #$a.Windows.Add("AllFiles", $Using:pcseResult.Files)
            #$a.Windows.Add("StorageKey", $Using:pcseResult.StorageKey)
            return $a
        }
    }

    if ($CustomScriptExtension.Linux.Enable)
    {
        Write-Verbose "Preparing files for Custom Script Extensions for Linux..."
        
        $pcseResult = PrepareCustomScriptExtension Linux $CustomScriptExtension.Linux
        $CustomScriptExtension = InlineScript {
            $a = $Using:CustomScriptExtension
            $a.Linux += $Using:pcseResult
            #$a.Add("AllFiles", $Using:pcseResult.Files)
            #$a.Linux.Add("StorageKey", $Using:pcseResult.StorageKey)
            return $a
        }
    }

    Write-Verbose "CustomScriptExtension Files Prepared."

    #endregion

    #region Create Diagnostics Configuration File

    if ($Diagnostics.Enable)
    {
        Write-Verbose "Preparing Diagnostics Configuration Files..."

        if ($Diagnostics.Windows.Enable)
        {
            $WindowsPublicConfig = Get-AutomationVariable -Name $Diagnostics.Windows.PublicConfigVariable
            $WindowsPublicConfigFile = $env:TEMP + "\" + "windows_diagnostics_publicconfig.json"
            Set-Content -Path $WindowsPublicConfigFile -Value $WindowsPublicConfig -Force
            $Diagnostics = InlineScript {
                $a = $Using:Diagnostics
                $a.Windows += @{"PublicConfigFile" = $Using:WindowsPublicConfigFile}
                return $a
            }
        }

        Write-Verbose "Diagnostics Configuration Files Created."
    }

    #endregion

    #region Process all migrated VMs.

    $vmMap = $RecoveryPlanContext.VmMap
    $vmInfo = $RecoveryPlanContext.VmMap | Get-Member | Where-Object MemberType -eq NoteProperty | select -ExpandProperty Name

    $Steps = 14

    Foreach -parallel ($vmID in $vmInfo)
    {
        InlineScript
        {

            $a = $Using:vmMap
            $b = $Using:vmID
            $VM = $a.$b
    
            if(!(($VM -eq $null) -Or ($VM.ResourceGroupName -eq $null) -Or ($VM.RoleName -eq $null))) 
            {
                Write-Output "Processing Virtual Machine $($VM.RoleName) in ResourceGroup $($VM.ResourceGroupName)..."

                #region Get Virtual Machine Details
                
                # Gets $azvm, $OsType, $isWindowsVm, $ip

                $tries = 0
                do
                {
                    try
                    {
                        $azvm = Get-AzVM -Name $VM.RoleName -ResourceGroupName $VM.ResourceGroupName -ErrorAction Stop
                    }
                    catch
                    {
                        Write-Error -Message "$($VM.RoleName) - $($_.Exception)"
                        Write-Output "$($VM.RoleName) - [Failed to get Virtual Machine details. Retrying.]"
                        $tries++
                    }
                } while (($tries -lt $Using:Misc.MaxTries) -and (-not $azvm))

                if (-not $azvm)
                {
                    Write-Output "$($VM.RoleName) - [Failed to get Virtual Machine details.]"
                    return
                }

                $OsType = $azvm.StorageProfile.OsDisk.OsType.ToString()
                $isWindowsVm = ($OsType -eq "Windows")
                if ($azvm.NetworkProfile.NetworkInterfaces.Length -eq 1)
                {
                    $nicId = $azvm.NetworkProfile.NetworkInterfaces[0].Id
                }
                else
                {
                    $nicId = $azvm.NetworkProfile.NetworkInterfaces | Where {$_.Primary -eq $true} | select -ExpandProperty Id
                }

                $nic = Get-AzNetworkInterface -ResourceId $nicId 
                $nicConfig = $nic.IpConfigurations | Where {$_.Primary -eq $true}
                $ip = $nicConfig.PrivateIpAddress
                $memoryInGb = [math]::Round((Get-AzVMSize -Location $azvm.Location| where {$_.Name -eq $azvm.HardwareProfile.VmSize} | Select -ExpandProperty MemoryInMb)/1024, 0)

                #endregion

                $errorCount = 0

                #region Install VM Agent on Linux

                if ($isWindowsVm)
                {
                    Write-Output "$($VM.RoleName) [1/$($Using:Steps)] - (Skipping Installing VM Agent since this is a Windows VM; these already have the agent installed.)"
                }
                else
                {
                    Write-Output "$($VM.RoleName) [1/$($Using:Steps)] - Installing VM Agent on Linux machine."
                    
                    function IsJobTerminalState([string] $status) {
                        return $status -eq "Completed" -or $status -eq "Failed" -or $status -eq "Stopped" -or $status -eq "Suspended"
                    }
                    
                    function WaitForRunbook($job)
                    {
                        $pollingSeconds = 5
                        $maxTimeout = 600
                        $waitTime = 0
                        while((IsJobTerminalState $job.Status) -eq $false -and $waitTime -lt $maxTimeout) {
                            Start-Sleep -Seconds $pollingSeconds
                            $waitTime += $pollingSeconds
                            $job = $job | Get-AzAutomationJob
                        }

                        $result = $job | Get-AzAutomationJobOutput -Stream Output | Get-AzAutomationJobOutputRecord | Select-Object -ExpandProperty Value
                        return $result
                    }

                    $job = Start-AzAutomationRunbook `
                                -AutomationAccountName $Using:AutomationAccount.AutomationAccountName `
                                -Name $Using:AutomationAccount.InstallAzureLinuxAgentRunbookName `
                                -ResourceGroupName $Using:AutomationAccount.ResourceGroupName `
                                -RunOn $Using:AutomationAccount.RunOn `
                                -Parameters @{"ServerNames"=@($ip)}
                    $jobResult = WaitForRunbook $job

                    #Write-Verbose $jobResult
                    #TODO: Check result
                }
                #endregion

                #region Enable Hybrid Use Benefit

                if ($Using:Misc.EnableAHUB)
                {
                    if ($isWindowsVm)
                    {
                        Write-Output "$($VM.RoleName) [2/$($Using:Steps)] - Enabling Hybrid Use Benefit." 

                        $azvm.LicenseType = "Windows_Server"
                        $AzVmResult = Update-AzVM -ResourceGroupName $VM.ResourceGroupName -VM $azvm
                    }
                    else
                    {
                        Write-Output "$($VM.RoleName) [2/$($Using:Steps)] - (Skipping Enabling Hybrid Use Benefit - Not applicable to $($azvm.StorageProfile.OsDisk.OsType) Virtual Machines.)" 
                    }
                }
                else
                {
                    Write-Output "$($VM.RoleName) [2/$($Using:Steps)] - (Skipping Enabling Hybrid Use Benefit as per Configuration.)" 
                }

                #endregion

                #region Enable Boot Diagnostics

                if ($Using:BootDiagnostics.Enable)
                {
                    Write-Output "$($VM.RoleName) [3/$($Using:Steps)] - Enabling Boot Diagnostics." 

                    $AzVMBootDiagnosticsResult = Set-AzVMBootDiagnostics -VM $azvm -Enable -ResourceGroupName $Using:BootDiagnostics.StorageAccountResourceGroupName -StorageAccountName $Using:BootDiagnostics.StorageAccountName
                }
                else
                {
                    Write-Output "$($VM.RoleName) [3/$($Using:Steps)] - (Skipping Enabling Boot Diagnostics as per Configuration.)" 
                }

                #endregion

                #region Install Diagnostics Extension

                if ($Using:Diagnostics.Windows.Enable -or $Using:Diagnostics.Linux.Enable)
                {
                    Write-Output "$($VM.RoleName) [4/$($Using:Steps)] - Installing Diagnostics Extension." 

                    try
                    {
                        if ($isWindowsVm -and $Using:Diagnostics.Windows.Enable)
                        {
                            $DiagnosticsConfigurationPath = $Using:Diagnostics.Windows.PublicConfigFile
                            $AzVMDiagnosticsExtensionResult = Set-AzVMDiagnosticsExtension `
                                -ResourceGroupName $VM.ResourceGroupName `
                                -VMName $VM.RoleName `
                                -DiagnosticsConfigurationPath $DiagnosticsConfigurationPath `
                                -StorageAccountName $Using:Diagnostics.Windows.StorageAccountName
                        }
                        elseif ((-not $isWindowsVm) -and $Using:Diagnostics.Linux.Enable)
                        {
                            $StorageAccountKey = Get-AzStorageAccountKey -Name $Using:Diagnostics.Linux.StorageAccountName -ResourceGroupName $Using:Diagnostics.Linux.StorageAccountResourceGroupName 
                            $StorageKey = $StorageAccountKey[0].Value
                            $StorageContext = New-AzStorageContext -StorageAccountName $Using:Diagnostics.Linux.StorageAccountName -StorageAccountKey $StorageKey
                            $sasToken = (New-AzStorageAccountSASToken -Service Blob,Table -ResourceType Container,Object -Permission wlacu -Context $StorageContext.Context).Substring(1)

                            $PublicConfig = Get-AutomationVariable -Name $Using:Diagnostics.Linux.PublicConfigVariable
                            $PublicConfig = $PublicConfig.Replace("__DIAGNOSTIC_STORAGE_ACCOUNT__", $Using:Diagnostics.Linux.StorageAccountName)
                            $PublicConfig = $PublicConfig.Replace("__VM_RESOURCE_ID__", $azvm.Id)

                            $PrivateConfig = "{'storageAccountName': '$($Using:Diagnostics.Linux.StorageAccountName)', 'storageAccountSasToken': '$sasToken'}"

                            $AzVMDExtensionResult = Set-AzVMExtension `
                                -ResourceGroupName $VM.ResourceGroupName `
                                -VMName $VM.RoleName `
                                -Publisher $Using:Diagnostics.Linux.Publisher `
                                -ExtensionType $Using:Diagnostics.Linux.ExtensionType `
                                -TypeHandlerVersion $Using:Diagnostics.Linux.TypeHandlerVersion `
                                -SettingString $PublicConfig `
                                -ProtectedSettingString $PrivateConfig `
                                -Name "DiagnosticsConfig" `
                                -Location $azvm.Location                       
                        }
                    }
                    catch
                    {
                        Write-Error -Message $_.Exception.Message
                        Write-Output $_.Exception.Message
                        Write-Output $_.Exception
                    }
                }
                else
                {
                    Write-Output "$($VM.RoleName) [4/$($Using:Steps)] - (Skipping Installing Diagnostics Extension as per Configuration.)" 
                }

                #endregion

                #region Set Private IP Addresses allocation method to 'Static'
                
                if ($Using:Misc.EnableStaticIp)
                {
                    Write-Output "$($VM.RoleName) [5/$($Using:Steps)] - Setting Private IP Address to Static." 

                    $nicConfig.PrivateIpAllocationMethod = 'Static'
                    $AzNetworkInterfaceResult = Set-AzNetworkInterface -NetworkInterface $nic
                }
                else
                {
                    Write-Output "$($VM.RoleName) [5/$($Using:Steps)] - (Skipping Setting Private IP Address to Static as per Configuration.)" 
                }

                #endregion

                #region Add a Managed User Principal to the VM
                
                Write-Output "$($VM.RoleName) [6/$($Using:Steps)] - Adding User Managed Principal." 
                
                $tries = 0
                $addedManagedIdentity = $false
                do
                {
                    try
                    {
                        $AzVmResult2 = Update-AzVM -ResourceGroupName $VM.ResourceGroupName -VM $azvm -IdentityType UserAssigned -IdentityID $Using:ManagedIdentityResourceId -ErrorAction Stop
                        $addedManagedIdentity = $true
                    }
                    catch
                    {
                        Write-Error -Message "$($VM.RoleName) [6/$($Using:Steps)] - $($_.Exception)"
                        Write-Output "$($VM.RoleName) [6/$($Using:Steps)] - [Adding User Managed Principal Failed. Retrying.]"
                        $tries++
                    }
                } while (($tries -lt $Using:Misc.MaxTries) -and (-not $addedManagedIdentity))

                if (-not $addedManagedIdentity)
                {
                    Write-Output "$($VM.RoleName) [6/$($Using:Steps)] - [Failed to Add User Managed Principal.]"
                    $errorCount++
                }

                #endregion

                #region Install the SAP Monitoring Extension on the VM (If required)

                if ($Using:SAP.Servers -contains $VM.RoleName)
                {
                    Write-Output "$($VM.RoleName) [7/$($Using:Steps)] - Installing SAP Monitoring Extension." 

                    $tries = 0
                    do
                    {
                        try
                        {
                            $AzVMAEMExtensionResult = Set-AzVMAEMExtension `
                                -ResourceGroupName $VM.ResourceGroupName `
                                -VMName $VM.RoleName `
                                -OSType $azvm.StorageProfile.OsDisk.OsType `
                                -WADStorageAccountName $Using:SAP.DiagnosticsStorageAccountName `
                                -ErrorAction Stop
                        }
                        catch
                        {
                            Write-Error -Message "$($VM.RoleName) [7/$($Using:Steps)] - $($_.Exception)"
                            Write-Output "$($VM.RoleName) [7/$($Using:Steps)] - [Installing SAP Monitoring Extension Failed. Retrying.]"
                            $tries++
                        }
                    } while (($tries -lt $Using:Misc.MaxTries) -and (-not $AzVMAEMExtensionResult))

                    if (-not $AzVMAEMExtensionResult)
                    {
                        Write-Output "$($VM.RoleName) [7/$($Using:Steps)] - [Failed to install SAP Monitoring Extension.]"
                        $errorCount++
                    }
                }
                else
                {
                    Write-Output "$($VM.RoleName) [7/$($Using:Steps)] - (Skipping SAP Monitoring Extension installation.)" 
                }

                #endregion
                
                #region Install the CustomScriptExtension on the VM

                Write-Output "$($VM.RoleName) [8/$($Using:Steps)] - Installing CustomScriptExtension."  

                if ($isWindowsVm -and $Using:CustomScriptExtension.Windows.Enable)
                {
                    $AzVMCustomScriptExtensionResult = $azvm | Set-AzVMCustomScriptExtension `
                        -Name "CustomScriptExtension" `
                        -VMName $VM.RoleName `
                        -ResourceGroupName $VM.ResourceGroupName `
                        -StorageAccountName ($Using:CustomScriptExtension).$OsType.StorageAccountName `
                        -StorageAccountKey ($Using:CustomScriptExtension).$OsType.StorageKey `
                        -ContainerName ($Using:CustomScriptExtension).$OsType.StorageContainer `
                        -FileName ($Using:CustomScriptExtension).$OsType.AllFiles `
                        -TypeHandlerVersion ($Using:CustomScriptExtension).$OsType.TypeHandlerVersion `
                        -Run ($Using:CustomScriptExtension).$OsType.Run
                }
                elseif ((-not $isWindowsVm) -and $Using:CustomScriptExtension.Linux.Enable)
                {
                    #$AzVMCustomScriptExtensionResult = $azvm | Set-AzVMCustomScriptExtension `
                    #    -Name "CustomScriptExtension" `
                    #    -VMName $VM.RoleName `
                    #    -ResourceGroupName $VM.ResourceGroupName `
                    #    -StorageAccountName ($Using:CustomScriptExtension).$OsType.StorageAccountName `
                    #    -StorageAccountKey ($Using:CustomScriptExtension).$OsType.StorageKey `
                    #    -ContainerName ($Using:CustomScriptExtension).$OsType.StorageContainer `
                    #    -FileName ($Using:CustomScriptExtension).$OsType.AllFiles `
                    #    -TypeHandlerVersion ($Using:CustomScriptExtension).$OsType.TypeHandlerVersion `
                    #    -Run ($Using:CustomScriptExtension).$OsType.Run

                    $commandToExecute = ($Using:CustomScriptExtension).$OsType.Run
                    $storageAccountName = ($Using:CustomScriptExtension).$OsType.StorageAccountName
                    $storageAccountKey = ($Using:CustomScriptExtension).$OsType.StorageKey
                    $containerName = ($Using:CustomScriptExtension).$OsType.StorageContainer

                    $fileUris = $Using:CustomScriptExtension.Linux.FileUris
                    $PublicConfig = "{`"fileUris`":[$fileUris],`"commandToExecute`":`"$commandToExecute`"}"
                    $PrivateConfig = "{`"storageAccountName`": `"$storageAccountName`",`"storageAccountKey`": `"$storageAccountKey`"}"

                    $AzVMDExtensionResult = Set-AzVMExtension `
                        -ResourceGroupName $VM.ResourceGroupName `
                        -VMName $VM.RoleName `
                        -Publisher $Using:CustomScriptExtension.Linux.Publisher `
                        -ExtensionType $Using:CustomScriptExtension.Linux.ExtensionType `
                        -TypeHandlerVersion $Using:CustomScriptExtension.Linux.TypeHandlerVersion `
                        -SettingString $PublicConfig `
                        -ProtectedSettingString $PrivateConfig `
                        -Name "CustomScriptExtension" `
                        -Location $azvm.Location
                    
                    #https://github.com/Azure/custom-script-extension-linux
                }
                #endregion

                #region Enable Disk Encryption
                # For LINUX:
                # The command will fail unless a snapshot of the managed disk is in place.
                # Keyvault needs to be in the same region as the vm
                # don't ssh into a linux machine when encryption is in progress.
                # cannot disble encryption of os disk on linux.
                # cannot switch from AAD Encryption to normal encryption
                # More: https://docs.microsoft.com/en-us/azure/security/azure-security-disk-encryption-linux
                
                if ($Using:DiskEncryption.Enable)
                {
                    if ((($Using:DiskEncryption.VolumeType -eq "All") -or ($Using:DiskEncryption.VolumeType -eq "OS")) -and ($memoryInGb -lt 7))
                    {
                        Write-Output "$($VM.RoleName) [9/$($Using:Steps)] - [Cannot enable Disk Encryption on OS volume due to insufficient memory.]"
                        Write-Error -Message "$($VM.RoleName) [9/$($Using:Steps)] - [Cannot enable Disk Encryption on OS volume due to insufficient memory.]"
                    }
                    else
                    {
                        Write-Output "$($VM.RoleName) [9/$($Using:Steps)] - Enabling Disk Encryption."

                        $KeyVault = Get-AzKeyVault -VaultName $Using:DiskEncryption.KeyVaultName -ResourceGroupName $Using:DiskEncryption.KeyVaultResourceGroupName
                        
                        $tries = 0
                        do
                        {
                            try
                            {
                                if ($Using:DiskEncryption.UseKEK)
                                {
                                    $EncryptionKeyUrl = (Get-AzKeyVaultKey -VaultName $Using:DiskEncryption.KeyVaultName -Name $Using:DiskEncryption.EncryptionKeyName).Key.kid

                                    $AzVMDiskEncryptionExtensionResult = Set-AzVMDiskEncryptionExtension `
                                        -ResourceGroupName $VM.ResourceGroupName `
                                        -VMName $VM.RoleName `
                                        -DiskEncryptionKeyVaultUrl $KeyVault.VaultUri `
                                        -DiskEncryptionKeyVaultId $KeyVault.ResourceId `
                                        -KeyEncryptionKeyUrl $EncryptionKeyUrl `
                                        -KeyEncryptionKeyVaultId $KeyVault.ResourceId `
                                        -VolumeType $Using:DiskEncryption.VolumeType `
                                        -SkipVmBackup `
                                        -Force `
                                        -ErrorAction Stop
                                }
                                else
                                {
                                    $AzVMDiskEncryptionExtensionResult = Set-AzVMDiskEncryptionExtension `
                                        -ResourceGroupName $VM.ResourceGroupName `
                                        -VMName $VM.RoleName `
                                        -DiskEncryptionKeyVaultUrl $KeyVault.VaultUri `
                                        -DiskEncryptionKeyVaultId $KeyVault.ResourceId `
                                        -VolumeType $Using:DiskEncryption.VolumeType `
                                        -SkipVmBackup `
                                        -Force `
                                        -ErrorAction Stop
                                }
                            }
                            catch
                            {
                                Write-Error -Message "$($VM.RoleName) [9/$($Using:Steps)] - $($_.Exception)"
                                Write-Output "$($VM.RoleName) [9/$($Using:Steps)] - [Enabling Disk Encryption Failed. Retrying.]"
                                $tries++
                            }
                        } while (($tries -lt $Using:Misc.MaxTries) -and (-not $AzVMDiskEncryptionExtensionResult))

                        if (-not $AzVMDiskEncryptionExtensionResult)
                        {
                            Write-Output "$($VM.RoleName) [9/$($Using:Steps)] - [Failed to Enabling Disk Encryption.]"
                            $errorCount++
                        }
                    }
                    # Linux: -SkipVmBackup
                    #-VolumeType Specifies the type of virtual machine volumes to perform the encryption operation. Allowed values for virtual machines that run the Windows operating system are as follows: All, OS, and Data. The allowed values for Linux virtual machines are as follows: Data only.
                }
                else
                {
                    Write-Output "$($VM.RoleName) [9/$($Using:Steps)] - (Skipping Disk Encryption as per Configuration.)"
                }

                #endregion

                #region Enable Azure Backup for the VM
                               
                if ($Using:Backup.Enable)
                {
                    Write-Output "$($VM.RoleName) [10/$($Using:Steps)] - Enabling Azure Backup."

                    $tries = 0
                    $enabledAzureBackup = $false
                    do
                    {
                        try
                        {
                            $BackupPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $Using:Backup.BackupPolicyName -VaultId $Using:Backup.RecoveryServicesVaultId
                            $AzRecoveryServicesBackupProtectionResult = Enable-AzRecoveryServicesBackupProtection `
                                -ResourceGroupName $VM.ResourceGroupName `
                                -Name $VM.RoleName `
                                -Policy $BackupPolicy `
                                -VaultId $Using:Backup.RecoveryServicesVaultId `
                                -ErrorAction Stop
                            $enabledAzureBackup = $true
                        }
                        catch
                        {
                            Write-Error -Message "$($VM.RoleName) [10/$($Using:Steps)] - $($_.Exception)"
                            Write-Output "$($VM.RoleName) [10/$($Using:Steps)] - [Enabling Azure Backup Failed. Retrying.]"
                            $tries++
                        }
                    } while (($tries -lt $Using:Misc.MaxTries) -and (-not $enabledAzureBackup))

                    if (-not $enabledAzureBackup)
                    {
                        Write-Output "$($VM.RoleName) [10/$($Using:Steps)] - [Failed to Enabling Azure Backup.]"
                        $errorCount++
                    }
                }
                else
                {
                    Write-Output "$($VM.RoleName) [10/$($Using:Steps)] - (Skipping Enabling Azure Backup as per Configuration)."
                }

                #endregion

                #region Remove the Managed User Principal from the VM
                
                if ($addedManagedIdentity)
                {
                    Write-Output "$($VM.RoleName) [11/$($Using:Steps)] - Removing User Managed Principal."  
                
                    $AzVmResult3 = Update-AzVM -ResourceGroupName $VM.ResourceGroupName -VM $azvm -IdentityType None
                }
                else
                {
                    Write-Output "$($VM.RoleName) [11/$($Using:Steps)] - (Skipping Removing User Managed Principal; the Identity was not added successfully previously.)" 
                }

                #endregion
                
                #region Set Tags

                if ($Using:Tagging.Enable)
                {
                    Write-Output "$($VM.RoleName) [12/$($Using:Steps)] - Setting Tags on Resources." 

                    try
                    {
                        $Tags = @{}

                        $TagsStorageAccount = Get-AzStorageAccount -ResourceGroupName $Using:Tagging.StorageAccountResourceGroupName -Name $Using:Tagging.StorageAccountName
                        $TagsStorageTable = (Get-AzStorageTable -Name $Using:Tagging.Table -Context $TagsStorageAccount.Context).CloudTable
                        $TagsRows = Get-AzTableRow -Table $TagsStorageTable -PartitionKey $VM.RoleName
                        $TagsRows | Foreach { $Tags.Add($_.tagName, $_.tagValue) }

                        if ($Tags.Count -gt 0)
                        {
                            $AzResourceResult = Set-AzResource -ResourceGroupName $VM.ResourceGroupName -Name $VM.RoleName -ResourceType "Microsoft.Compute/virtualMachines" -Tag $Tags -Force

                            $DiskNames = $azvm.StorageProfile.DataDisks.Name
                            $DiskNames += $azvm.StorageProfile.OsDisk.Name
                            $DiskNames | Foreach { $tmp = Set-AzResource -ResourceGroupName $VM.ResourceGroupName -ResourceName $_ -ResourceType "Microsoft.Compute/disks" -Tag $Tags -Force }

                            $NicNames = $azvm.NetworkProfile.NetworkInterfaces | Select -ExpandProperty Id | Foreach { $_.Split("/")[-1] }
                            $NicNames | Foreach { $tmp = Set-AzResource -ResourceGroupName $VM.ResourceGroupName -ResourceName $_ -ResourceType "Microsoft.Network/networkInterfaces" -Tag $Tags -Force }

                        }
                    }
                    catch
                    {
                        Write-Output "Failed to add Tags to Virtual Machine $($VM.RoleName)." 
                        Write-Error -Message $_.Exception
                        $errorCount++
                    }
                }
                else
                {
                    Write-Output "$($VM.RoleName) [12/$($Using:Steps)] - (Skipping Setting Tags on Resources as per Configuration.)" 
                }

                #endregion

                #region Restart Virtual Machine
                
                Write-Output "$($VM.RoleName) [13/$($Using:Steps)] - Restarting Virtual Machine." 
                
                $AzVmResult4 = Restart-AzVM -Id $azvm.Id

                #endregion

                #region Starting backup

                if ($Using.Backup.Start)
                {
                    if ($enabledAzureBackup)
                    {
                        Write-Output "$($VM.RoleName) [14/$($Using:Steps)] - Starting Backup." 
                
                        $BackupContainer = Get-AzRecoveryServicesBackupContainer -ContainerType "AzureVM" -FriendlyName $VM.RoleName -VaultId $Using:Backup.RecoveryServicesVaultId
                        $BackupItem = Get-AzRecoveryServicesBackupItem -Container $BackupContainer -WorkloadType "AzureVM" -VaultId $Using:Backup.RecoveryServicesVaultId
                        $AzRecoveryServicesBackupItemResult = Backup-AzRecoveryServicesBackupItem -Item $BackupItem -VaultId $Using:Backup.RecoveryServicesVaultId
                    }
                    else
                    {
                        Write-Output "$($VM.RoleName) [14/$($Using:Steps)] - (Skipping Starting Backup; Azure Backup was not enabled successfully previously.)" 
                    }
                }
                else
                {
                    Write-Output "$($VM.RoleName) [14/$($Using:Steps)] - (Skipping Starting Backup as per Configuration.)" 
                }

                #endregion

                if ($errorCount -eq 0)
                {
                    Write-Output "Done Processing Virtual Machine $($VM.RoleName) in ResourceGroup $($VM.ResourceGroupName)."
                }
                else
                {
                    Write-Output "Done Processing Virtual Machine $($VM.RoleName) in ResourceGroup $($VM.ResourceGroupName) with $errorCount errors."
                }
            }
        }
    }
    
    #endregion

    Write-Output "Done."

    Write-Output $RecoveryPlanContext
}