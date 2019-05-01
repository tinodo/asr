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

This runbook should be executed before an actual failover happens.
It automates the process of shutting down critical services on the servers to migrate and wait for replication.
It also shuts down the servers before the migration.

This is mostly imporant when migration Windows Server 2008 workloads, or other workloads that cannot use App-Consistent Snapshots.
This process makes sure we have a 0% dataloss migration. 

The script's output stream is used to display progress. It is not intended to be used in any other automation.

#>

param ( 
    [Object]$RecoveryPlanContext 
    ) 

# Name of the AzureRunAsConnection in the Automation Account
$ConnectionName = "AzureRunAsConnection"

# Subscription Identifier of the subscription the Recovery Vault for Site Recovery is in
$SubscriptionId = ""

# Name of the Azure Recovery Services Vault for Site Recovery
$AsrVaultName = ""

# Indication whether to run this workbook on a test failover ($true) or not ($false).
$StartRunbookOnTest = $true

# Name of the Certificate to be used to create Recovery Vault Credentials. Could be any certificate.
$CertificateName = "ASRCertificate"

# Name of the Automation Account this workbook runs under
$AutomationAccountName = ""

# Resource Group where the Automation Account resides
$AutomationAccountResourceGroupName = ""

# Name of the Hybrid Worker Group where on-premises scripts will be executed.
$HybridWorkerGroupName = ""



$RecoveryPlanName = $RecoveryPlanContext.RecoveryPlanName;
$GroupId = $RecoveryPlanContext.GroupId

#$RecoveryPlanName = "part2"
#$GroupId = "Group 1"


if (($RecoveryPlanContext.FailoverType -eq "Test") -and (-not $StartRunbookOnTest))
{
    Write-Output "Not processing runbook because this is a test failover."
    return
}

if ($RecoveryPlanContext.FailoverDirection -ne "PrimaryToSecondary")
{
    Write-Output "Not processing runbook because this is a failback."
    return 
}

#region Connect to Azure...

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

#region Connection to Recovery Services Vault...

try
{
    $Vault = Get-AzRecoveryServicesVault -Name $AsrVaultName
    $Certificate = Get-AutomationCertificate -Name $CertificateName
    $cert = [System.Convert]::ToBase64String($Certificate.Export("Cert"))
    $VaultCredentialsFile = Get-AzRecoveryServicesVaultSettingsFile -Vault $Vault -Path $env:TEMP -Certificate $cert -SiteRecovery
    $tmp = Import-AzRecoveryServicesAsrVaultSettingsFile -Path $VaultCredentialsFile.FilePath
}
catch
{
    $message = "Could not connect to Recovery Services Vault $AsrVaultName"
    Write-Output $message
    Write-Error -Message $message
    Write-Error -Message $_.Exception
    throw $_.Exception
}

#endregion

#region Get Replication Protected Items...

$ReplicationProtectedItems = @()
$ProtectableItems = @()

$Fabrics = Get-AzRecoveryServicesAsrFabric
foreach ($Fabric in $Fabrics)
{
    Write-Output "Processing fabric $($Fabric.FriendlyName)"
    $ProtectionContainers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $Fabric
    foreach ($ProtectionContainer in $ProtectionContainers)
    {
        Write-Output "Processing container $($ProtectionContainer.FriendlyName) ($($ProtectionContainer.FabricType))"
        $ProtectableItems += Get-AzRecoveryServicesAsrProtectableItem -ProtectionContainer $ProtectionContainer
        $ReplicationProtectedItems += Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $ProtectionContainer
    }
}

Write-Output "Found $($ReplicationProtectedItems.Length) protected items."

#endregion

#region Find servers that are being migrated...

$RecoveryPlan = Get-AzRecoveryServicesAsrRecoveryPlan -Name $RecoveryPlanName
if ($GroupId -eq "FailoverAllActionGroup")
{
    $Group = $RecoveryPlan.Groups
}
else
{
    $Group = $RecoveryPlan.Groups | where {$_.Name -eq $GroupId}
}

$RelevantReplicationProtectedItems = @()

$ReplicationProtectedItemIDs = $Group.ReplicationProtectedItems | select -ExpandProperty ID
$ReplicationProtectedItemIDs | foreach {
    $y = $_
    $RelevantReplicationProtectedItems += $ReplicationProtectedItems | where {$_.ID -eq $y}
}

#endregion

#region Distinguish between Windows and Linux

$windowsServers = @()
$linuxServers = @()
foreach ($RelevantReplicationProtectedItem in $RelevantReplicationProtectedItems)
{
    $ProtectableItem = $ProtectableItems | where {$_.ID -eq $RelevantReplicationProtectedItem.ProtectableItemId}
    $friendlyName = $RelevantReplicationProtectedItem | select -ExpandProperty FriendlyName
    if ($ProtectableItem.OS -eq "WINDOWS")
    {
        $windowsServers += $friendlyName
    }
    else
    {
        $linuxServers += $friendlyName
    }
}

Write-Output "Windows Servers: $($windowsServers -join ', ')"
Write-Output "Linux Servers: $($linuxServers -join ', ')"

#endregion

#region Functions...

function IsJobTerminalState([string] $status) {
    return $status -eq "Completed" -or $status -eq "Failed" -or $status -eq "Stopped" -or $status -eq "Suspended"
}

function WaitForRunbook($job)
{
    $pollingSeconds = 5
    $maxTimeout = 10800
    $waitTime = 0
    while((IsJobTerminalState $job.Status) -eq $false -and $waitTime -lt $maxTimeout) {
        Start-Sleep -Seconds $pollingSeconds
        $waitTime += $pollingSeconds
        $job = $job | Get-AzAutomationJob
    }

    $result = $job | Get-AzAutomationJobOutput -Stream Output | Get-AzAutomationJobOutputRecord | Select-Object -ExpandProperty Value
    return $result
}

function WaitForReplication()
{
    $start = Get-Date
    $future = $start + (New-TimeSpan -Hours 2)
    $stop = $start + (New-TimeSpan -Minutes 30)
    Write-Output "Waiting for replication (max. until $stop)..."

    do
    {
        $done = $true
        foreach ($ReplicationProtectedItem in $RelevantReplicationProtectedItems)
        {
            $RecoveryPoints = Get-AzRecoveryServicesAsrRecoveryPoint -ReplicationProtectedItem $ReplicationProtectedItem
            $AppConsistentRecoveryPoints = $RecoveryPoints | where {$_.RecoveryPointType -eq "AppConsistent"} |  Sort-Object -Property RecoveryPointTime -Descending
            $CrashConsistentRecoveryPoints = $RecoveryPoints | where {$_.RecoveryPointType -eq "CrashConsistent"} |  Sort-Object -Property RecoveryPointTime -Descending

            $LatestAppConsistentRecoveryPoint = if ($AppConsistentRecoveryPoints.Count -eq 0) { $future } else { $AppConsistentRecoveryPoints[0].RecoveryPointTime}
            $LatestCrashConsistentRecoveryPoint = if ($CrashConsistentRecoveryPoints.Count -eq 0) { $future } else { $CrashConsistentRecoveryPoints[0].RecoveryPointTime}

            $done = ($done -and ($LatestAppConsistentRecoveryPoint -ge $start) -and ($LatestCrashConsistentRecoveryPoint -ge $start))
            if (-not $done)
            {
                Start-Sleep -Seconds 10
                break
            }
        }
    } while ((-not $done) -and ((Get-Date) -lt $stop))

    if (-not $done)
    {
        Write-Output "Timeout occurred!"
    }
}

#endregion

#TODO: This could be done in parallel.

Write-Output "Starting to stop services on servers..."

$job1a = Start-AzAutomationRunbook `
            -AutomationAccountName $AutomationAccountName `
            -Name "StopWindowsServices" `
            -ResourceGroupName $AutomationAccountResourceGroupName `
            -RunOn $HybridWorkerGroupName `
            -Parameters @{"ServerNames"=$windowsServers}
$job1b = Start-AzAutomationRunbook `
            -AutomationAccountName $AutomationAccountName `
            -Name "StopLinuxServices" `
            -ResourceGroupName $AutomationAccountResourceGroupName `
            -RunOn $HybridWorkerGroupName `
            -Parameters @{"ServerNames"=$linuxServers}

$result1a = WaitForRunbook $job1a
$result1b = WaitForRunbook $job1b

Write-Output $result1a
Write-Output $result1b

WaitForReplication 

Write-Output "Starting to stop servers..."

$job2a = Start-AzAutomationRunbook `
            -AutomationAccountName $AutomationAccountName `
            -Name "StopWindowsServers" `
            -ResourceGroupName $AutomationAccountResourceGroupName `
            -RunOn $HybridWorkerGroupName `
            -Parameters @{"ServerNames"=$windowsServers}
$job2b = Start-AzAutomationRunbook `
            -AutomationAccountName $AutomationAccountName `
            -Name "StopLinuxServers" `
            -ResourceGroupName $AutomationAccountResourceGroupName `
            -RunOn $HybridWorkerGroupName `
            -Parameters @{"ServerNames"=$linuxServers}

$result2a = WaitForRunbook $job2a
$result2b = WaitForRunbook $job2b

Write-Output $result2a
Write-Output $result2b

#WaitForReplication 

Write-Output "Done."