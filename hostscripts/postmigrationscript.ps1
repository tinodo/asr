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
March, 2019

This script is provided "AS IS" with no warranties, and confers no rights.

Version 1.1
-----------------------------------------------------------------------------#>

###
### Variables - Modify accordingly
###

$computerName = $env:computername
$subscription = ""
$resourceGroup = ""
$storageAccount = ""
$container = "migrationlogs"
$localFolder = "C:\asr"
$mainOutput = $localFolder + "\" + $computerName + "-main.log"


###
### Initialization & Functions
###

New-Item -Path $localFolder -ItemType directory

Function Enable-OfflineDisk
{

    #Check for offline disks on server.
    $offlinedisk = "list disk" | diskpart | where {$_ -match "offline"}
    
    #If offline disk(s) exist
    if($offlinedisk)
    {
    
        Write-Output "Following Offline disk(s) found..Trying to bring Online."
        $offlinedisk
        
        #for all offline disk(s) found on the server
        foreach($offdisk in $offlinedisk)
        {
    
            $offdiskS = $offdisk.Substring(2,6)
            Write-Output "Enabling $offdiskS"
            #Creating command parameters for selecting disk, making disk online and setting off the read-only flag.
            $OnlineDisk = @"
select $offdiskS
attributes disk clear readonly
online disk
attributes disk clear readonly
"@
            #Sending parameters to diskpart
            $noOut = $OnlineDisk | diskpart
            Sleep 5
    
       }

        #If selfhealing failed throw the alert.
        if(($offlinedisk = "list disk" | diskpart | where {$_ -match "offline"} ))
        {
        
            Write-Output "Failed to bring the following disk(s) online"
            $offlinedisk

        }
        else
        {
    
            Write-Output "Disk(s) are now online."

        }

    }

    #If no offline disk(s) exist.
    else
    {

        #All disk(s) are online.
        Write-Output "All disk(s) are online!"

    }
}


###
### Get system information (before script)
###

$execute = "msinfo32.exe"
$parameters = ' /report "' + $localFolder + '\' + $computerName + '-msinfostart.txt"'
$process = [System.Diagnostics.Process]::Start($execute, $parameters)
$process.WaitForExit()


###
### Mount any offline disks
###

Add-Content -Path $mainOutput -Value "Checking for offline disks."

if (Get-Command "Get-Disk" -ErrorAction SilentlyContinue)
{
    $Offlinedisks = Get-Disk | ? IsOffline
    $Offlinedisks | Out-File -filepath $($localFolder + '\' + $computerName + "-offlinedisks.txt")
    $Offlinedisks | Set-Disk -IsOffline:$false
    Get-Disk | Out-File -filepath $($localFolder + '\' + $computerName + "-onlinedisks.txt")
}
else
{
    Enable-OfflineDisk | Out-File -filepath $($localFolder + '\' + $computerName + "-onlinedisks.txt")
}

Add-Content -Path $mainOutput -Value "Checking for offline disks done."


###
### Change Page File location
###

Add-Content -Path $mainOutput -Value "Changing pagefile location."
if (Get-Command "Get-Partition" -ErrorAction SilentlyContinue)
{
    $partition = Get-Partition | where {$_.DiskPath -eq "\\?\ide#diskvirtual_hd______________________________1.1.0___#5&35dc7040&0&0.1.0#{53f56307-b6bf-11d0-94f2-00a0c91efb8b}"}
    $tempDrive = $partition.DriveLetter[0]
}
else
{
    $volumes = Get-WmiObject -Query "select * from Win32_volume where Label = 'Temporary Storage'"
    $tempDrive = $volumes.DriveLetter[0]
}

if ($tempDrive)
{
    $pageFile = Get-WmiObject -Query "select * from Win32_PageFileSetting where name like '%pagefile.sys'"
    if ($pagefile)
    {
        $pageFile | Out-File $($localFolder + '\' + $computerName + "-oldpagefile.txt")
        $pageFile.delete()
    }
    Set-WMIInstance -Class Win32_PageFileSetting -Arguments @{name="$tempDrive`:\pagefile.sys"} | Out-File $($localFolder + '\' + $computerName + "-newpagefile.txt")
    Add-Content -Path $mainOutput -Value "Changed pagefile location to $tempDrive`:\pagefile.sys."
}
else
{
    Add-Content -Path $mainOutput -Value "Could not find drive for pagefile."
}


###
### Kill processes that won't stop.
###

$processesToKill = @(
    "svagentsCS",
    "appservice"
)

Stop-Process -Force -Name $processesToKill


###
### Uninstall obsolete software.
###

Add-Content -Path $mainOutput -Value "Uninstalling obsolete applications..."

$uninstallCount = 0

$uninstalls = @(
    "{181D79D7-1115-4D96-8E9B-5833DF92FBB4}", # SCCM 2012
    "{6A438387-0FF9-4620-947E-39470FB1E2E5}", # SCCM 2007
    "{275197FC-14FD-4560-A5EB-38217F80CBD1}"  # Mobility Service
)

foreach ($uninstall in $uninstalls)
{
    Add-Content -Path $mainOutput -Value "Uninstalling $uninstall"
    $uninstallCount++;
    try
    {
        $execute = "MsiExec.exe"
        $parameters = ' /qn /norestart /x ' + $uninstall + ' /L+*V "' + $localFolder + '\' + $computerName + '-Uninstall_' + $uninstallCount + '.log"'
        $process = [System.Diagnostics.Process]::Start($execute, $parameters)
        $process.WaitForExit()
        Add-Content -Path $mainOutput -Value "Uninstalled $uninstall"
    }
    catch
    {
        Add-Content -Path $mainOutput -Value "Failed to Uninstall $uninstall"
    }
}

$uninstalls = @(
    #"SMS Agent",
    "VMware Tools",
    "McAfee",
    "Microsoft Monitoring Agent"
    #"Microsoft Azure Site Recovery Mobility Service"
)

$regPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\uninstall"
$installations = Get-ChildItem $regPath

foreach ($installation in $installations)
{
    $keyPath = $installation.PSChildName
    $properties = Get-ItemProperty -Path $regPath\$keyPath -Name "DisplayName" -ErrorAction SilentlyContinue
    $isMatch = $uninstalls | foreach {$tempMatch = $false} {$tempMatch = $tempMatch -or ($properties.DisplayName -match $_)} {$tempMatch}
    if ($isMatch) 
    {
        Add-Content -Path $mainOutput -Value "Uninstalling $($properties.DisplayName)"
        $uninstallCount++;
        try
        {
            $execute = "MsiExec.exe"
            $parameters = ' /qn /norestart /x ' + $keyPath + ' /L+*V "' + $localFolder + '\' + $computerName + '-Uninstall_' + $uninstallCount + '.log"'
            $process = [System.Diagnostics.Process]::Start($execute, $parameters)
            $process.WaitForExit()
            Add-Content -Path $mainOutput -Value "Uninstalled $($properties.DisplayName)"
        }
        catch
        {
            Add-Content -Path $mainOutput -Value "Failed to Uninstall $($properties.DisplayName)"
        }
    }
}

Add-Content -Path $mainOutput -Value "Uninstalled obsolete applications."


###
### Install new applications
###

Add-Content -Path $mainOutput -Value "Installing new applications..."

$agents = @(
    "WindowsAzureVmAgent.msi"
)

foreach ($agent in $agents)
{
    try
    {
        $execute = "MsiExec.exe"
        $parameters = ' /quiet /norestart /i ' + $agent + ' /L+*V "' + $localFolder + '\' + $computerName + '-Install_' + $agent + '.log"'
        $process = [System.Diagnostics.Process]::Start($execute, $parameters)
        $process.WaitForExit()
        Add-Content -Path $mainOutput -Value "Installed $agent"
        Remove-Item $agent
    }
    catch
    {
        Add-Content -Path $mainOutput -Value $_.Exception.Message
        Add-Content -Path $mainOutput -Value "Failed to install $agent"
    }
}

Add-Content -Path $mainOutput -Value "Installed new applications."


###
### Get system information (after script)
###

Add-Content -Path $mainOutput -Value "Generating report..."

$execute = "msinfo32.exe"
$parameters = ' /report "' + $localFolder + '\' + $computerName + '-msinfoend.txt"'
$process = [System.Diagnostics.Process]::Start($execute, $parameters)
$process.WaitForExit()

Add-Content -Path $mainOutput -Value "Report generated."


###
### Upload logs to Azure Storage Account
###

Add-Content -Path $mainOutput -Value "Uploading logfiles..."

if (Get-Command "Invoke-RestMethod" -ErrorAction SilentlyContinue)
{
    # Does not work in PowerShell 2.0
    $Count = 0
    $MaxTries = 3
    do
    {
        try
        {
            $Count++
            $uri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F'
            $response = Invoke-WebRequest -Uri $uri -Method GET -Headers @{Metadata="true"} -UseBasicParsing
            $content = $response.Content | ConvertFrom-Json
            $accessToken = $content.access_token
        }
        catch
        {
            Add-Content -Path $mainOutput -Value $_.Exception.Message
            Add-Content -Path $mainOutput -Value "Could not obtain Access Token from Azure Active Directory. Retrying..."
            Start-Sleep -s 30
        }
    } while (!$accessToken -and ($Count -lt $MaxTries))

    if (!$accessToken)
    {
        throw "Could not obtain Access Token from Azure Active Directory."
    }

    $Count = 0
    do
    {
        try
        {
            $Count++
            $uri = "https://management.azure.com/subscriptions/$($subscription)/resourceGroups/$($resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($storageAccount)/listKeys/?api-version=2016-12-01"
            $keysResponse = Invoke-WebRequest -Uri $uri -Method POST -Headers @{Authorization="Bearer $accessToken"} -UseBasicParsing
            $keysContent = $keysResponse.Content | ConvertFrom-Json
            $key = $keysContent.keys[0].value
        }
        catch
        {
            Add-Content -Path $mainOutput -Value $_.Exception.Message
            Add-Content -Path $mainOutput -Value "Could not obtain Access Key from Storage Account. Retrying..."
            Start-Sleep -s 30
        }

    } while (!$key -and ($Count -lt $MaxTries))

    if (!$key)
    {
        throw "Could not obtain Access Key from Storage Account."
    }

    $files = Get-ChildItem -Path $localFolder -File -Recurse
    foreach ($file in $files)
    {
        $fileName = $file.Name
        $filePath = $file.FullName
        $size = $file.Length
        if ($size -eq 0)
        {
            $size = ""
        }

        $uri = "https://$storageAccount.blob.core.windows.net/$container/$fileName"
        $date = (Get-Date).ToUniversalTime()
        $dateStr = $date.ToString("R")

        $strToSign = "PUT`n`n`n$size`n`n`n`n`n`n`n`n`nx-ms-blob-type:BlockBlob`nx-ms-date:$dateStr`nx-ms-version:2015-04-05`n/"
        $strToSign = $strToSign + $storageAccount + "/" + $container + "/" + $fileName

        [byte[]]$bytes = ([System.Text.Encoding]::UTF8).GetBytes($strToSign)
        $hmacsha256 = New-Object System.Security.Cryptography.HMACSHA256
        $hmacsha256.Key = [Convert]::FromBase64String($key)
        $signature = [Convert]::ToBase64String($hmacsha256.ComputeHash($bytes))
        $authHeader = "SharedKey $storageAccount`:$signature"

        $reqHeader = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $reqHeader.Add("Authorization", $authHeader)
        $reqHeader.Add("x-ms-date", $dateStr)
        $reqHeader.Add("x-ms-version", "2015-04-05")
        $reqHeader.Add("x-ms-blob-type","BlockBlob")

        $response = New-Object PSObject;

        Add-Content -Path $mainOutput -Value "Uploading file $filePath to $uri"

        $response = (Invoke-RestMethod -Uri $uri -Method put -Headers $reqHeader -InFile $filePath -UseBasicParsing);
 
        Add-Content -Path $mainOutput -Value "Uploaded file $filePath to $uri"
    }
}
else
{
    $uri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F'
    $Count = 0
    $MaxTries = 3
    do
    {
        try
        {
            $Count++
            $request = [System.Net.WebRequest]::Create($uri)
            $request.ContentType = "application/json"
            $request.Method = "GET"
            $request.Headers.add('Metadata','true')
            $response = $request.GetResponse()
            $responseStream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($responseStream)
            $json = $reader.ReadToEnd()

            $start = $json.IndexOf('"access_token":"') + 16
            $end = $json.IndexOf('"', $start) - $start
            $accessToken = $json.SubString($start, $end)
        }
        catch
        {
            Add-Content -Path $mainOutput -Value $_.Exception.Message
            Add-Content -Path $mainOutput -Value "Could not obtain Access Token from Azure Active Directory. Retrying..."
            Start-Sleep -s 30
        }
    } while (!$accessToken -and ($Count -lt $MaxTries))

    if (!$accessToken)
    {
        throw "Could not obtain Access Token from Azure Active Directory."
    }

    $uri = "https://management.azure.com/subscriptions/$($subscription)/resourceGroups/$($resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($storageAccount)/listKeys/?api-version=2016-12-01"
    $Count = 0

    do
    {
        try
        {
            $Count++
            $request = [System.Net.WebRequest]::Create($uri)
            $request.ContentType = "multipart/form-data"
            $request.Method = "POST"
            $request.Headers.add('Authorization',"Bearer $accessToken")
            $request.ContentLength = 0

            $response = $request.GetResponse()
            $responseStream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($responseStream)
            $json = $reader.ReadToEnd()
    
            $start = $json.IndexOf('"value":"') + 9
            $end = $json.IndexOf('"', $start) - $start
            $key = $json.SubString($start, $end)
        }
        catch
        {
            Add-Content -Path $mainOutput -Value $_.Exception.Message
            Add-Content -Path $mainOutput -Value "Could not obtain Access Key from Storage Account. Retrying..."
            Start-Sleep -s 30
        }
    } while (!$key -and ($Count -lt $MaxTries))

    if (!$key)
    {
        throw "Could not obtain Access Key from Storage Account."
    }

    $files = Get-ChildItem -Path $localFolder | Where-Object { !$_.PSIsContainer }
    foreach ($file in $files)
    {
        $fileName = $file.Name
        $filePath = $file.FullName
        $content = [System.IO.File]::ReadAllBytes($filePath)
        $size = $content.Length
        if ($size -eq 0)
        {
            $size = ""
        }

        $uri = "https://$storageAccount.blob.core.windows.net/$container/$fileName"
        $Count = 0

        do
        {
            $done = $false;
            $date = (Get-Date).ToUniversalTime()
            $dateStr = $date.ToString("R")

            $strToSign = "PUT`n`n`n$size`n`n`n`n`n`n`n`n`nx-ms-blob-type:BlockBlob`nx-ms-date:$dateStr`nx-ms-version:2015-04-05`n/"
            $strToSign = $strToSign + $storageAccount + "/" + $container + "/" + $fileName

            [byte[]]$bytes = ([System.Text.Encoding]::UTF8).GetBytes($strToSign)
            $hmacsha256 = New-Object System.Security.Cryptography.HMACSHA256
            $hmacsha256.Key = [Convert]::FromBase64String($key)
            $signature = [Convert]::ToBase64String($hmacsha256.ComputeHash($bytes))
            $authHeader = "SharedKey $storageAccount`:$signature"
       
            Add-Content -Path $mainOutput -Value "Uploading file $filePath ($($content.Length) bytes)"

            $request = [System.Net.WebRequest]::Create($Uri)
            $request.Method = "PUT"
            $request.Headers.add('Authorization',$authHeader)
            $request.Headers.Add("x-ms-date", $dateStr)
            $request.Headers.Add("x-ms-version", "2015-04-05")
            $request.Headers.Add("x-ms-blob-type","BlockBlob")
            $Stream = $request.GetRequestStream()
            $Stream.Write($content, 0, $content.Length)
            $Stream.Flush()
            $Stream.Close()
            try
            {
                $response = $request.GetResponse()
                $responseStream = $response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($responseStream)
                $result = $reader.ReadToEnd()
                $done = $true
                Add-Content -Path $mainOutput -Value "Uploaded file $filePath to $uri"
            }
            catch [System.Net.WebException] 
            {              
                $resp = $_.Exception.Response

                if ($resp -eq $null)
                {
                    Add-Content -Path $mainOutput -Value $_.Exception
                }
                else
                {
                    $reqstream = $resp.GetResponseStream()
                    $sr = New-Object System.IO.StreamReader $reqstream
                    $body = $sr.ReadToEnd()
                    Add-Content -Path $mainOutput -Value $body            
                }                    
                $Count++
            } 
            catch {            
                Add-Content -Path $mainOutput -Value $_.Exception
                $Count++
            }
        } while (!$done -and ($Count -lt $MaxTries))

        if (!$done)
        {
            Add-Content -Path $mainOutput -Value "Unable to upload file $filePath to $uri"
        }
    }
}

Add-Content -Path $mainOutput -Value "DONE"

# The easy way, with Az module installed:
#$ctx = New-AzStorageContext -StorageAccountName $storageAccount -StorageAccountKey $key
#Get-ChildItem -Path $localFolder -File -Recurse | Set-AzStorageBlobContent -Container $container -Context $ctx
