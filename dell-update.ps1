# Create temp directory for downloads
$workdir = "C:\Temp\DellUtilities"
if (-not (Test-Path -Path $workdir -PathType Container)) {
    New-Item -Path $workdir -ItemType Directory -Force | Out-Null
}
Set-Location $workdir

# Log function
function Write-Log {
    param (
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    Add-Content -Path "$workdir\DellInstall.log" -Value $logMessage
}

Write-Log "Starting Dell utilities installation script"


# Function to download files with user agent
function Download-File {
    param (
        [string]$Url,
        [string]$DestinationPath
    )
    try {
        Write-Log "Downloading from $Url to $DestinationPath"
        
        # Common browser user agent string
        $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
        Write-Log "Using user agent: $userAgent"
        
        if (Get-Command 'Invoke-WebRequest' -ErrorAction SilentlyContinue) {
            $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $webSession.UserAgent = $userAgent
            
            Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -WebSession $webSession
        } else {
            $WebClient = New-Object System.Net.WebClient
            $WebClient.Headers.Add("User-Agent", $userAgent)
            $WebClient.DownloadFile($Url, $DestinationPath)
        }
        
        if (Test-Path -Path $DestinationPath) {
            Write-Log "Successfully downloaded to $DestinationPath"
            return $true
        } else {
            Write-Log "Failed to download file to $DestinationPath"
            return $false
        }
    } catch {
        Write-Log "Error downloading file: $_"
        return $false
    }
}

# Function to execute process and wait for completion
function Execute-Process {
    param (
        [string]$FilePath,
        [string]$Arguments,
        [string]$Description
    )
    try {
        Write-Log "Starting process: $Description"
        Write-Log "Command: $FilePath $Arguments"
        
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru -Wait
        $exitCode = $process.ExitCode
        
        Write-Log "$Description completed with exit code: $exitCode"
        return $exitCode
    } catch {
        Write-Log "Error executing process: $_"
        return -1
    }
}

# 1. Install/Update Dell SupportAssist
Write-Log "=============== Installing/Updating Dell SupportAssist ==============="
$supportAssistUrl = "https://downloads.dell.com/serviceability/catalog/SupportAssistInstaller.exe"
$supportAssistInstaller = "$workdir\SupportAssistInstaller.exe"

if (Download-File -Url $supportAssistUrl -DestinationPath $supportAssistInstaller) {
    Execute-Process -FilePath $supportAssistInstaller -Arguments "/S /NORESTART" -Description "Dell SupportAssist Installation (v4.8.2.29006)"
    Write-Log "Note: Current version being installed is 4.8.2.29006 (May 2025)"
} else {
    Write-Log "Skipping Dell SupportAssist installation due to download failure"
}

# 2. Install/Update Dell Peripheral Manager
Write-Log "=============== Installing/Updating Dell Peripheral Manager ==============="
$dpmUrl = "https://dl.dell.com/FOLDER12250940M/1/DPeM_7MGJH_1.7.7_WN64_A00.exe"
$dpmInstaller = "$workdir\DPeM_7MGJH_1.7.7_WN64_A00.exe"

if (Download-File -Url $dpmUrl -DestinationPath $dpmInstaller) {
    Execute-Process -FilePath $dpmInstaller -Arguments "/S /NORESTART" -Description "Dell Peripheral Manager Installation"
} else {
    Write-Log "Skipping Dell Peripheral Manager installation due to download failure"
}

# 3. Install/Update Dell Command | Update
Write-Log "=============== Installing/Updating Dell Command | Update ==============="
# For Dell Command Update, let's modify the installation approach
$dcuUrl = "https://dl.dell.com/FOLDER11914075M/1/Dell-Command-Update-Application_6VFWW_WIN_5.4.0_A00.EXE"
$dcuInstaller = "$workdir\Dell-Command-Update-Application_5.4.0.exe"
$dcuExtractPath = "$workdir\dcu_exe"

if (Download-File -Url $dcuUrl -DestinationPath $dcuInstaller) {
    if (-not (Test-Path -Path $dcuExtractPath -PathType Container)) {
        New-Item -Path $dcuExtractPath -ItemType Directory -Force | Out-Null
    }
    
    Execute-Process -FilePath $dcuInstaller -Arguments "/s /e=$dcuExtractPath" -Description "Dell Command Update Extraction"
    
    $setupFile = Get-ChildItem -Path $dcuExtractPath -Filter "*Setup*.exe" | Select-Object -First 1
    
    if ($setupFile) {
        # First try to uninstall any existing version
        Write-Log "Attempting to uninstall any existing Dell Command Update versions"
        
        # Try to find the uninstaller for Dell Command Update in registry
        $uninstallKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        
        $dellCmdUpdateApp = Get-ItemProperty $uninstallKeys | Where-Object { 
            $_.DisplayName -like "*Dell Command*Update*" -or $_.DisplayName -like "*Dell Command | Update*" 
        }
        
        if ($dellCmdUpdateApp) {
            Write-Log "Found existing Dell Command Update installation, attempting to uninstall"
            $uninstallString = $dellCmdUpdateApp.UninstallString
            
            if ($uninstallString -match "msiexec") {
                # If it's an MSI uninstaller, we can extract the product code and use it
                $productCode = $uninstallString -replace ".*({[A-Z0-9-]+}).*", '$1'
                if ($productCode -match "{[A-Z0-9-]+}") {
                    Execute-Process -FilePath "msiexec.exe" -Arguments "/x $productCode /qn REBOOT=ReallySuppress" -Description "Dell Command Update Uninstallation"
                } else {
                    # Use the full uninstall string
                    $uninstallCommand = $uninstallString -replace "msiexec.exe", ""
                    Execute-Process -FilePath "msiexec.exe" -Arguments "$uninstallCommand /qn REBOOT=ReallySuppress" -Description "Dell Command Update Uninstallation"
                }
            } else {
                # If it's an EXE uninstaller, run it silently
                $uninstallArgs = $uninstallString -replace "^.*\.exe\s*", ""
                $uninstallExe = $uninstallString -replace "\s+.*$", ""
                Execute-Process -FilePath $uninstallExe -Arguments "$uninstallArgs /S /NORESTART" -Description "Dell Command Update Uninstallation"
            }
            
            # Wait a few seconds after uninstall
            Start-Sleep -Seconds 5
        }
        
        # Now try installation with modified parameters and logging
        Write-Log "Installing Dell Command Update with detailed logging"
        $msiLogPath = "$workdir\dcu_install.log"
        # Add REBOOT=ReallySuppress parameter to prevent automatic reboots
        Execute-Process -FilePath $setupFile.FullName -Arguments "/S /v`" /qn REBOOT=ReallySuppress /L*v $msiLogPath`"" -Description "Dell Command Update Installation"
        
        # Check log file for errors
        if (Test-Path $msiLogPath) {
            $logErrors = Select-String -Path $msiLogPath -Pattern "error|return value 3|return value 1602"
            if ($logErrors) {
                Write-Log "Found errors in MSI log file:"
                foreach ($error in $logErrors) {
                    Write-Log "MSI Log: $($error.Line)"
                }
            }
        }
    } else {
        Write-Log "Could not find Dell Command Update setup file after extraction"
    }
} else {
    Write-Log "Skipping Dell Command | Update installation due to download failure"
}

# 4. Install/Update Dell Display Manager
Write-Log "=============== Installing/Updating Dell Display Manager ==============="
$ddmUrl = "https://dl.dell.com/FOLDER12722073M/1/ddmsetup.exe"
$ddmInstaller = "$workdir\ddmsetup.exe"

if (Download-File -Url $ddmUrl -DestinationPath $ddmInstaller) {
    $prerequisitesPath = "$workdir\ddm_prerequisites"
    if (-not (Test-Path -Path $prerequisitesPath -PathType Container)) {
        New-Item -Path $prerequisitesPath -ItemType Directory -Force | Out-Null
    }
    
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ddmInstaller)
        $entries = $zip.Entries | Where-Object { $_.FullName -like "Prerequisites*" }
        if ($entries.Count -gt 0) {
            Write-Log "Found prerequisites in the installer, attempting to extract"
            foreach ($entry in $entries) {
                $targetPath = [System.IO.Path]::Combine($prerequisitesPath, $entry.FullName)
                $targetDir = [System.IO.Path]::GetDirectoryName($targetPath)
                if (-not (Test-Path -Path $targetDir -PathType Container)) {
                    New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
                }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            }
            Write-Log "Prerequisites extracted to $prerequisitesPath"
            
            $dotnetRuntime = Get-ChildItem -Path $prerequisitesPath -Filter "windowsdesktop-runtime-*.exe" -Recurse | Select-Object -First 1
            if ($dotnetRuntime) {
                Write-Log "Installing .NET Desktop Runtime prerequisite"
                Execute-Process -FilePath $dotnetRuntime.FullName -Arguments "/install /quiet /norestart" -Description ".NET Runtime Installation"
            }
        }
        $zip.Dispose()
    } catch {
        Write-Log "Error extracting prerequisites (may not be needed): $_"
    }
    
    Execute-Process -FilePath $ddmInstaller -Arguments "/S /NORESTART" -Description "Dell Display Manager Installation"
} else {
    Write-Log "Skipping Dell Display Manager installation due to download failure"
}

# 5. Install/Update Dell OS Recovery Tool
Write-Log "=============== Installing/Updating Dell OS Recovery Tool ==============="
$osRecoveryUrl = "https://dl.dell.com/FOLDER12632844M/1/Dell-OS-Recovery-Tool_WFFJR_WIN64_2.4.2.2193_A00.EXE"
$osRecoveryInstaller = "$workdir\Dell-OS-Recovery-Tool_2.4.2.2193.exe"

if (Download-File -Url $osRecoveryUrl -DestinationPath $osRecoveryInstaller) {
    # Using /S for silent install and /v parameter to pass MSI arguments that prevent reboot
    Execute-Process -FilePath $osRecoveryInstaller -Arguments "/S /v`" /qn REBOOT=ReallySuppress`"" -Description "Dell OS Recovery Tool Installation"
} else {
    Write-Log "Skipping Dell OS Recovery Tool installation due to download failure"
}

Write-Log "====================================================================="
Write-Log "Installation script completed. No reboots were scheduled."
Write-Log "====================================================================="