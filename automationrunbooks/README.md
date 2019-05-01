# Azure Automation Runbooks
Most runbooks require that the Az PowerShell modules are installed on the (Hybrid and Azure) workers.  
The runbooks require that a hybrid worker is deployed, since some runbooks will only run on a Hybrid worker.
The runbooks that need to be run on the hybrid workers, need to run under local administrator credentials using a *RunAs* account.

*To be continued...*  

## PostMigrationRunbook.ps1
*To be documented...*  

## PreMigrationRunbook.ps1
This Azure Automation runbook is designed to be called from an Azure Site Recovery Plan as a *Pre-step script action*.  It tries to determine which machines are being migrated (or, better said; failing over) in this job. When the script is called from the *All groups failover: Pre-steps* section, all machines in the recovery plan are target of this runbook. Should the runbook be called from a specific *Group [x]: Pre-steps* section, only the machines in that group are target of the runbook.  
For the machines in scope of the runbook, the runbook determines whether this is a Linux or a Windows host. On these hosts, critical services are stopped by calling the `StopWindowsServices` and `StopLinuxServices` runbooks. It then waits for a new *Crash-consistent recovery point*. Last, the runbook shuts down the hosts using the `StopWindowsServers` and `StopLinuxServers` runbooks.  
It requires a single Input parameter; `RecoveryPlanContext` which should be provided automatically by the Azure Site Recovery Job running the Recovery Plan.    
It utilizes a single Azure Automation Certificate; `ASRCertificate` which should hold a valid certificate with private key. It is used to create credentials to connect to the Azure Recovery Services Vault.    
Within the script itself, the following PowerShell variables should be configured:
- **$ConnectionName**: Name of the AzureRunAsConnection in the Automation Account
- **$SubscriptionId**: Subscription Identifier of the subscription the Recovery Vault for Site Recovery is in.
- **$AsrVaultName**: Name of the Azure Recovery Services Vault for Site Recovery
- **$StartRunbookOnTest**: Indication whether to run this workbook on a test failover (`$true`) or not (`$false`).
- **$CertificateName**: Name of the Azure Automation Certificate to be used to create Recovery Vault Credentials. Could be any certificate. There is no need to change this, when you create an Azure Automation Certificate called `ASRCertificate`
- **$AutomationAccountName**: Name of the Automation Account this workbook runs under
- **$AutomationAccountResourceGroupName**: Resource Group where the Automation Account resides
- **$HybridWorkerGroupName**: Name of the Hybrid Worker Group where on-premises scripts will be executed.  

The scripts outputs all it's logging to the Output-stream. The Output-stream should not be used for other automation.  

## StopLinuxServers
This Azure Automation runbook, designed to run on a Hybrid Worker, is called from the `PreMigrationRunbook`, but can also be ran individually. It tries to shutdown on one or more Linux hosts.  
The runbook needs to run on the Hybrid Worker with local administrator privileges, since it will install a PowerShell module (`WinSCP`) whenever it's not available on the host.  
It requires a single Input parameter; `ServerNames` which should contain an array of strings with hostnames and/or IP addresses of hosts to shutdown. (e.g. `['server1','server2','10.14.22.145']`)  
The runbook will try to shutdown the Linux hosts by using Sftp. The credentials for the connection come from an Azure Automation Credential called `SourceEnvironmentLinuxAdministrator`. Typically, this is the `root` user on the host.  
The script will return, on the Output-Stream, an array of strings containing the Linux hosts that accepted the shutdown command.  

## StopLinuxServices
This Azure Automation runbook, designed to run on a Hybrid Worker, is called from the `PreMigrationRunbook`, but can also be ran individually. It tries to stop services on one or more Linux hosts.  
The runbook needs to run on the Hybrid Worker with local administrator privileges, since it will install a PowerShell module (`WinSCP`) whenever it's not available on the host.  
It requires a single Input parameter; `ServerNames` which should contain an array of strings with hostnames and/or IP addresses of hosts to stop the services on. (e.g. `['server1','server2','10.14.22.145']`)  
It utilizes a single Azure Automation Variable; `LinuxServicesToStop` which should contain a comma-seperated list of names of Linux Services. (e.g. `service1,service2,service3`)   
The runbook will try to stop services on the Linux hosts by using Sftp. The credentials for the connection come from an Azure Automation Credential called `SourceEnvironmentLinuxAdministrator`. Typically, this is the `root` user on the host.  
The match for the service names is 'loosly'; should the list of `LinuxServicesToStop` contain a string with the value `sql`, the script will stop all Linux Services that have `sql` in it's display name. For example:

- mysql

The script will return, on the Output-Stream, a hashtable which contains one key per host processed and a string array with stopped services as the value.  

## StopWindowsServers
This Azure Automation runbook, designed to run on a Hybrid Worker, is called from the `PreMigrationRunbook`, but can also be ran individually. It tries to shutdown on one or more Windows hosts.  
It requires a single Input parameter; `ServerNames` which should contain an array of strings with hostnames and/or IP addresses of hosts to shutdown. (e.g. `['server1','server2','10.14.22.145']`)  
The runbook will try to shutdown the Windows hosts by using WMI. The account the runbook runs under needs to have the appropriate permissions on the target hosts.  
The script will return, on the Output-Stream, an array of strings containing the Windows hosts that accepted the shutdown command.  

## StopWindowsServices
This Azure Automation runbook, designed to run on a Hybrid Worker, is called from the `PreMigrationRunbook`, but can also be ran individually. It tries to stop services on one or more Windows hosts.  
It requires a single Input parameter; `ServerNames` which should contain an array of strings with hostnames and/or IP addresses of hosts to stop the services on. (e.g. `['server1','server2','10.14.22.145']`)  
It utilizes a single Azure Automation Variable; `WindowsServicesToStop` which should contain a comma-seperated list of display names of Windows Services. (e.g. `service1,service2,service3`)   
The runbook will try to stop services on the Windows hosts by using WMI. The account the runbook runs under needs to have the appropriate permissions on the target hosts.  
The match for the service names is 'loosly'; should the list of `WindowsServicesToStop` contain a string with the value `sql`, the script will stop all Windows Services that have `sql` in it's display name. For example:

- SQL Full-text Filter Daemon Launcher (MSSQLSERVER)
- SQL Server (MSSQLSERVER)
- SQL Server Browser
- SQL Server Agent (MSSQLSERVER)
- SQL Server VSS Writer

The script will return, on the Output-Stream, a hashtable which contains one key per host processed and a string array with stopped services as the value.  
