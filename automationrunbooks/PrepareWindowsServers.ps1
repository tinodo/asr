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

workflow PrepareWindowsServers
{
    Param
    (
      [Parameter (Mandatory= $true)]
      [String[]]
      $ServerNames
    )

    ForEach -Parallel ($ServerName in $ServerNames)
    {
        InlineScript
        {
            $maxRunningTime = 60
            $server = $Using:Servername

            # Diskpart
            $inputFilename = [guid]::NewGuid().ToString().Replace("-", "") + ".txt"
            $outputFilename = [guid]::NewGuid().ToString().Replace("-", "") + ".txt"
            $errorFilename = [guid]::NewGuid().ToString().Replace("-", "") + ".txt"
            Set-Content -Path "\\$server`\C$\$inputFilename" -Value "SAN POLICY=ONLINEALL"
            $process = Invoke-WmiMethod -ComputerName $server -Namespace root\cimv2 -Class Win32_Process -Name Create -ArgumentList "cmd /c diskpart /s C:\$inputFilename > C:\$outputFilename 2>C:\$errorFilename"
            $processId = $process.ProcessId
            Write-Output "Waiting for diskpart (process id $processId) on server $server to finish"

            $start = Get-Date
            $runningTime = 0
            do
            {
                Start-Sleep -Milliseconds 500
                $process = Get-WmiObject -Namespace root\cimv2 -Class Win32_Process -ComputerName $server -Filter "ProcessId = $processId"
                $now = Get-Date
                $age = New-TimeSpan –Start $start –End $now
                $runningTime = $age.TotalSeconds
            } while ($process -and ($runningTime -le $maxRunningTime))

            $errorMessage = Get-Content -Path "\\$server`\C$\$errorFilename"
            if ($errorMessage.Length -gt 0)
            {
                Write-Error "Diskpart Failed:"
                Write-Error $errorMessage
            }
            else
            {
                Get-Content -Path "\\$server`\C$\$outputFilename"
            }

            Remove-Item "\\$server`\C$\$inputFilename" -Force
            Remove-Item "\\$server`\C$\$outputFilename" -Force
            Remove-Item "\\$server`\C$\$errorFilename" -Force

            # Remote Desktop
            $rdp = Get-WmiObject -Namespace root\cimv2\TerminalServices -Class Win32_TerminalServiceSetting -ComputerName $server
            $result = $rdp.SetAllowTsConnections(1,1)
            if ($result.ReturnValue -ne 0) {
                Write-Error "Could not enable Remote Desktop on server $server."
            }
        }
    }

    Write-Output "Done."
}
