# Windows Update Download and Install Script
# This script downloads and installs Windows Updates using a provided URL
###############################################################################

###############################################################################
# 1. Helper Functions
###############################################################################

function Get-WUSAExitCodeDescription {
    param (
        [Parameter(Mandatory=$true)]
        [int]$ExitCode
    )
    
    switch ($ExitCode) {
        0 { return "Success" }
        2359302 { return "Update already installed" }
        3010 { return "Success - Reboot required" }
        2359301 { return "Update not applicable to this system" }
        2359303 { return "Update requires a newer service pack" }
        2359304 { return "Update requires other updates to be installed first" }
        -2145124329 { return "Install failed" }
        87 { return "Invalid parameter" }
        1603 { return "Fatal error during installation" }
        1641 { return "Success - Reboot initiated" }
        1642 { return "Success - Reboot required to complete" }
        1643 { return "Success - Reboot required to complete" }
        2 { return "File not found" }
        5 { return "Access denied" }
        120 { return "This update is superseded by an already installed update" }
        1618 { return "Another installation is already in progress" }
        1619 { return "Package could not be opened" }
        1620 { return "Package could not be opened" }
        1625 { return "This update is superseded by an already installed update" }
        1628 { return "Failed to apply update" }
        16389 { return "Trusted installer is not running" }
        16390 { return "Trusted installer is not running" }
        default { return "Unknown error code" }
    }
}

function Get-PendingRebootStatus {
    $pendingReboot = $false
    $rebootSources = @()
    
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $pendingReboot = $true
        $rebootSources += "Component Based Servicing"
    }
    
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $pendingReboot = $true
        $rebootSources += "Windows Update"
    }
    
    $sessionManager = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
        $pendingReboot = $true
        $rebootSources += "Session Manager"
    }
    
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client\Reboot Management\RebootData") {
        $pendingReboot = $true
        $rebootSources += "SCCM Client"
    }
    
    return @{
        RebootPending = $pendingReboot
        RebootSources = $rebootSources
    }
}

function Extract-KBNumber {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Url
    )
    
    if ($Url -match "KB(\d+)") {
        return "KB$($matches[1])"
    }
    
    $fileName = [System.IO.Path]::GetFileName($Url)
    if ($fileName -match "KB(\d+)") {
        return "KB$($matches[1])"
    }
    
    if ($Url -match "-(\d{6,})-") {
        return "KB$($matches[1])"
    }
    
    return "WindowsUpdate-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

function Get-FileExtension {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Url
    )
    
    $fileName = [System.IO.Path]::GetFileName($Url)
    $extension = [System.IO.Path]::GetExtension($fileName).ToLower()
    
    if ([string]::IsNullOrEmpty($extension) -or ($extension -ne ".msu" -and $extension -ne ".cab")) {
        return ".msu"
    }
    return $extension
}

function Download-File {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Url,
        
        [Parameter(Mandatory=$true)]
        [string]$Destination,
        
        [Parameter(Mandatory=$true)]
        [string]$LogFilePath
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp - Starting download of $Url to $Destination"
    Write-Host $entry
    Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
    
    try {
        $psVersion = $PSVersionTable.PSVersion.Major
        
        if ($psVersion -ge 3) {
            $entry = "$timestamp - Using Invoke-WebRequest to download file"
            Write-Host $entry
            Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
            
            try {
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600
            }
            catch [System.Net.WebException] {
                $entry = "$timestamp - Network error during download: $($_.Exception.Message)"
                Write-Host $entry -ForegroundColor Red
                Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
                return $false
            }
            catch {
                $entry = "$timestamp - Error during download: $($_.Exception.Message)"
                Write-Host $entry -ForegroundColor Red
                Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
                return $false
            }
        } else {
            $entry = "$timestamp - Using WebClient to download file"
            Write-Host $entry
            Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
            
            try {
                $webClient = New-Object System.Net.WebClient
                $webClient.DownloadFile($Url, $Destination)
            }
            catch [System.Net.WebException] {
                $entry = "$timestamp - Network error during download: $($_.Exception.Message)"
                Write-Host $entry -ForegroundColor Red
                Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
                return $false
            }
            catch {
                $entry = "$timestamp - Error during download: $($_.Exception.Message)"
                Write-Host $entry -ForegroundColor Red
                Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
                return $false
            }
        }
        
        if (Test-Path $Destination) {
            $fileSize = (Get-Item $Destination).Length
            $entry = "$timestamp - Download completed. File size: $fileSize bytes"
            Write-Host $entry
            Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
            return $true
        } else {
            $entry = "$timestamp - Download failed. File not found at destination"
            Write-Host $entry -ForegroundColor Red
            Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
            return $false
        }
    } catch {
        $entry = "$timestamp - Unexpected error during download: $($_.Exception.Message)"
        Write-Host $entry -ForegroundColor Red
        Add-Content -Path $LogFilePath -Value $entry -ErrorAction SilentlyContinue
        return $false
    }
}

function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [string]$ForegroundColor = "White",
        
        [Parameter(Mandatory=$true)]
        [string]$LogFile,
        
        [Parameter(Mandatory=$false)]
        [switch]$NoConsole
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp - $Message"
    
    # Only write to console if NoConsole is not specified
    if (-not $NoConsole) {
        Write-Host $entry -ForegroundColor $ForegroundColor
    }
    
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
}

function Install-CabFile {
    param (
        [Parameter(Mandatory=$true)]
        [string]$CabFilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$KbDir,
        
        [Parameter(Mandatory=$true)]
        [string]$KbNumber,
        
        [Parameter(Mandatory=$true)]
        [string]$LogFile
    )
    
    $wusaLogPath = Join-Path -Path $KbDir -ChildPath "$KbNumber-install-details.txt"
    Write-Log -Message "Processing CAB file..." -ForegroundColor "Yellow" -LogFile $LogFile
    
    $dismParams = "/online /add-package /packagepath:`"$CabFilePath`" /quiet /norestart /logpath:`"$wusaLogPath`""
    $process = Start-Process -FilePath "dism.exe" -ArgumentList $dismParams -Wait -PassThru
    $exitCode = $process.ExitCode
    
    if ($exitCode -eq 2) {
        $exitCode = Extract-AndInstallCabContents -CabFilePath $CabFilePath -KbDir $KbDir -KbNumber $KbNumber -LogFile $LogFile -WusaLogPath $wusaLogPath
    }
    
    return $exitCode
}

function Extract-AndInstallCabContents {
    param (
        [Parameter(Mandatory=$true)]
        [string]$CabFilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$KbDir,
        
        [Parameter(Mandatory=$true)]
        [string]$KbNumber,
        
        [Parameter(Mandatory=$true)]
        [string]$LogFile,
        
        [Parameter(Mandatory=$true)]
        [string]$WusaLogPath
    )
    
    Write-Log -Message "Direct CAB installation failed. Attempting to extract and install contents..." -ForegroundColor "Yellow" -LogFile $LogFile
    
    $extractDir = Join-Path -Path $KbDir -ChildPath "$KbNumber-extracted"
    if (-not (Test-Path -Path $extractDir)) {
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    }
    
    if (-not (Get-Command "expand.exe" -ErrorAction SilentlyContinue)) {
        Write-Log -Message "Error: expand.exe not found. Cannot extract CAB file." -ForegroundColor "Red" -LogFile $LogFile
        return 1603
    }
    
    Write-Log -Message "Extracting CAB file to $extractDir..." -ForegroundColor "Yellow" -LogFile $LogFile
    $expandErrorLog = Join-Path -Path $extractDir -ChildPath "expand-error.log"
    $expandParams = "`"$CabFilePath`" -F:* `"$extractDir`""
    $expandProcess = Start-Process -FilePath "expand.exe" -ArgumentList $expandParams -Wait -PassThru -NoNewWindow -RedirectStandardError $expandErrorLog
    
    if (Test-Path $expandErrorLog) {
        $errorContent = Get-Content $expandErrorLog -Raw -ErrorAction SilentlyContinue
        if ($errorContent) {
            Write-Log -Message "Expand.exe reported errors: $errorContent" -ForegroundColor "Red" -LogFile $LogFile
        }
    }
    
    $exitCode = 1603
    
    if ($expandProcess.ExitCode -eq 0) {
        Write-Log -Message "CAB extraction completed successfully" -ForegroundColor "Green" -LogFile $LogFile
        
        $exitCode = Install-ExtractedFiles -FilePattern "*.msp" -ExtractDir $extractDir -KbNumber $KbNumber -LogFile $LogFile -WusaLogPath $wusaLogPath
        
        if ($exitCode -eq 1603) {
            $exitCode = Install-ExtractedFiles -FilePattern "*.msu" -ExtractDir $extractDir -KbNumber $KbNumber -LogFile $LogFile -WusaLogPath $wusaLogPath
        }
    } else {
        Write-Log -Message "Failed to extract CAB file. Expand.exe exit code: $($expandProcess.ExitCode)" -ForegroundColor "Red" -LogFile $LogFile
    }
    
    try {
        if (Test-Path -Path $extractDir) {
            Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log -Message "Cleaned up temporary extraction directory" -ForegroundColor "Green" -LogFile $LogFile
        }
    } catch {
        Write-Log -Message "Warning: Failed to clean up extraction directory: $($_.Exception.Message)" -ForegroundColor "Yellow" -LogFile $LogFile
    }
    
    return $exitCode
}

function Install-ExtractedFiles {
    param (
        [Parameter(Mandatory=$true)]
        [string]$FilePattern,
        
        [Parameter(Mandatory=$true)]
        [string]$ExtractDir,
        
        [Parameter(Mandatory=$true)]
        [string]$KbNumber,
        
        [Parameter(Mandatory=$true)]
        [string]$LogFile,
        
        [Parameter(Mandatory=$true)]
        [string]$WusaLogPath
    )
    
    $files = Get-ChildItem -Path $ExtractDir -Filter $FilePattern -ErrorAction SilentlyContinue
    $exitCode = 1603
    
    if ($files.Count -gt 0) {
        Write-Log -Message "Found $($files.Count) $FilePattern file(s) to install" -ForegroundColor "Green" -LogFile $LogFile
        
        foreach ($file in $files) {
            $filePath = $file.FullName
            Write-Log -Message "Installing $FilePattern file: $($file.Name)..." -ForegroundColor "Yellow" -LogFile $LogFile
            
            if ($FilePattern -eq "*.msp") {
                $exitCode = Install-MspFile -MspFilePath $filePath -LogFile $LogFile -WusaLogPath $WusaLogPath
            } else {
                $exitCode = Install-MsuFile -MsuFilePath $filePath -LogFile $LogFile -WusaLogPath $WusaLogPath
            }
            
            Write-Log -Message "$FilePattern installation completed with exit code: $exitCode" -ForegroundColor "Yellow" -LogFile $LogFile
        }
    } else {
        Write-Log -Message "No $FilePattern files found in extracted content" -ForegroundColor "Yellow" -LogFile $LogFile
    }
    
    return $exitCode
}

function Install-MspFile {
    param (
        [Parameter(Mandatory=$true)]
        [string]$MspFilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$LogFile,
        
        [Parameter(Mandatory=$true)]
        [string]$WusaLogPath
    )
    
    $timeout = New-TimeSpan -Minutes 30
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    $msiexecParams = "/p `"$MspFilePath`" /qn /norestart /log:`"$WusaLogPath`""
    $exitCode = 1603
    
    try {
        $msiProcess = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiexecParams -PassThru
        $processId = $msiProcess.Id
        Write-Log -Message "Started MSP installation process with ID: $processId" -ForegroundColor "Yellow" -LogFile $LogFile
        
        $processExited = $false
        while (-not $processExited -and $stopwatch.Elapsed -lt $timeout) {
            if ($msiProcess.HasExited) {
                $processExited = $true
                continue
            }
            
            if ($stopwatch.Elapsed.TotalMinutes -ge 5 -and $stopwatch.Elapsed.TotalMinutes % 5 -eq 0) {
                Write-Log -Message "MSP installation in progress for $($stopwatch.Elapsed.TotalMinutes) minutes..." -ForegroundColor "Yellow" -LogFile $LogFile
            }
            
            Start-Sleep -Seconds 10
        }
        
        if (-not $processExited) {
            Write-Log -Message "WARNING: MSP installation timed out after $($timeout.TotalMinutes) minutes!" -ForegroundColor "Red" -LogFile $LogFile
            Write-Log -Message "Attempting to terminate the MSI process..." -ForegroundColor "Yellow" -LogFile $LogFile
            try {
                Stop-Process -Id $processId -Force -ErrorAction Stop
                Write-Log -Message "MSI process terminated" -ForegroundColor "Yellow" -LogFile $LogFile
                $exitCode = 1618
            } catch {
                Write-Log -Message "Failed to terminate MSI process: $($_.Exception.Message)" -ForegroundColor "Red" -LogFile $LogFile
            }
        } else {
            $exitCode = $msiProcess.ExitCode
            Write-Log -Message "MSP installation completed with exit code: $exitCode" -ForegroundColor "Yellow" -LogFile $LogFile
        }
    } catch {
        Write-Log -Message "Error starting MSP installation: $($_.Exception.Message)" -ForegroundColor "Red" -LogFile $LogFile
        $exitCode = 1603
    }
    
    $stopwatch.Stop()
    return $exitCode
}

function Install-MsuFile {
    param (
        [Parameter(Mandatory=$true)]
        [string]$MsuFilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$LogFile,
        
        [Parameter(Mandatory=$true)]
        [string]$WusaLogPath
    )
    
    $wusaParams = "`"$MsuFilePath`" /quiet /norestart /log:`"$WusaLogPath`""
    $wusaProcess = Start-Process -FilePath "wusa.exe" -ArgumentList $wusaParams -Wait -PassThru
    
    return $wusaProcess.ExitCode
}

function Exit-Script {
    param (
        [int]$ExitCode,
        [string]$Message,
        [string]$LogFile
    )
    
    $scriptEndTime = Get-Date
    $duration = $scriptEndTime - $scriptStartTime
    Write-Log -Message "Script execution duration: $($duration.ToString())" -ForegroundColor "Cyan" -LogFile $LogFile
    Write-Log -Message $Message -ForegroundColor $(if ($ExitCode -eq 0) { "Green" } else { "Red" }) -LogFile $LogFile
    exit $ExitCode
}

###############################################################################
# 2. Main Script
###############################################################################

$installResult = "NOT_STARTED"
$scriptStartTime = Get-Date
$overallSuccess = $false

try {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Error: This script requires administrative privileges. Please run PowerShell as Administrator." -ForegroundColor Red
        exit 1
    }

    $updateUrl = $env:downloadUrl
    if ([string]::IsNullOrEmpty($updateUrl)) {
        Write-Host "Error: No download URL provided. Please set the 'downloadUrl' environment variable." -ForegroundColor Red
        exit 1
    }

    $kbNumber = Extract-KBNumber -Url $updateUrl
    $fileExtension = Get-FileExtension -Url $updateUrl
    
    # Use C:\temp as primary path, with fallback options
    if (Test-Path "C:\temp") {
        $tempDir = "C:\temp"
    } else {
        # Try to create C:\temp if it doesn't exist
        try {
            New-Item -Path "C:\temp" -ItemType Directory -Force | Out-Null
            $tempDir = "C:\temp"
        } catch {
            # Fall back to system TEMP if we can't create C:\temp
            $tempDir = [System.Environment]::GetEnvironmentVariable("TEMP", "Machine")
            if ([string]::IsNullOrEmpty($tempDir)) {
                $tempDir = "C:\Windows\Temp"
            }
        }
    }
    
    $baseDir = Join-Path -Path $tempDir -ChildPath "WindowsUpdates"
    $kbDir = Join-Path -Path $baseDir -ChildPath $kbNumber
    $downloadPath = Join-Path -Path $kbDir -ChildPath "$kbNumber-update$fileExtension"
    $logFile = Join-Path -Path $kbDir -ChildPath "$kbNumber-install-log.txt"

    if (-not (Test-Path -Path $baseDir)) {
        Write-Host "Creating base directory: $baseDir" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    }

    if (-not (Test-Path -Path $kbDir)) {
        Write-Host "Creating KB-specific directory: $kbDir" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $kbDir -Force | Out-Null
    }

    Write-Host "Detected update: $kbNumber" -ForegroundColor Cyan
    Write-Host "Detected file type: $fileExtension" -ForegroundColor Cyan
    Write-Log -Message "Script started for update: $kbNumber" -ForegroundColor "Green" -LogFile $logFile
    Write-Log -Message "Download URL: $updateUrl" -ForegroundColor "Green" -LogFile $logFile

    Write-Log -Message "Checking if $kbNumber is already installed..." -ForegroundColor "Yellow" -LogFile $logFile
    $updateInstalled = Get-HotFix -Id $kbNumber -ErrorAction SilentlyContinue
    if ($updateInstalled) {
        Write-Log -Message "$kbNumber is already installed on this system (installed on: $($updateInstalled.InstalledOn))" -ForegroundColor "Green" -LogFile $logFile
        Exit-Script -ExitCode 0 -Message "Update already installed. No action needed." -LogFile $logFile
    }

    try {
        $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    } catch {
        Write-Log -Message "Get-CimInstance not available, falling back to Get-WmiObject" -ForegroundColor "Yellow" -LogFile $logFile
        $osInfo = Get-WmiObject -Class Win32_OperatingSystem
    }
    $osVersion = $osInfo.Version
    $osCaption = $osInfo.Caption
    Write-Log -Message "Detected OS: $osCaption (Version: $osVersion)" -ForegroundColor "Yellow" -LogFile $logFile

    Write-Log -Message "Starting download of Windows Update $kbNumber..." -ForegroundColor "Green" -LogFile $logFile

    if (Test-Path $downloadPath) {
        $existingSize = (Get-Item $downloadPath).Length
        $existingSizeMB = [Math]::Round($existingSize / 1MB, 2)
        Write-Log -Message "INFO: Update file already exists at $downloadPath" -ForegroundColor "Yellow" -LogFile $logFile
        Write-Log -Message "INFO: Existing file size: $existingSizeMB MB ($existingSize bytes)" -ForegroundColor "Yellow" -LogFile $logFile
        
        if ($existingSize -lt 1000000) {
            Write-Log -Message "WARNING: Existing file appears to be incomplete. Removing and redownloading..." -ForegroundColor "Yellow" -LogFile $logFile
            Remove-Item -Path $downloadPath -Force
        } else {
            Write-Log -Message "INFO: Using existing update file" -ForegroundColor "Green" -LogFile $logFile
        }
    }

    if (-not (Test-Path $downloadPath)) {
        $maxRetries = 3
        $retryCount = 0
        $downloadSuccess = $false
        
        while (-not $downloadSuccess -and $retryCount -lt $maxRetries) {
            $retryCount++
            Write-Log -Message "Download attempt $retryCount of $maxRetries..." -ForegroundColor "Yellow" -LogFile $logFile
            $downloadSuccess = Download-File -Url $updateUrl -Destination $downloadPath -LogFilePath $logFile
            
            if (-not $downloadSuccess -and $retryCount -lt $maxRetries) {
                $retryDelay = [math]::Pow(2, $retryCount) * 10
                Write-Log -Message "Waiting $retryDelay seconds before retry..." -ForegroundColor "Yellow" -LogFile $logFile
                Start-Sleep -Seconds $retryDelay
            }
        }
        
        if (-not $downloadSuccess) {
            Write-Log -Message "Error: Download failed after $maxRetries attempts." -ForegroundColor "Red" -LogFile $logFile
            Exit-Script -ExitCode 1 -Message "Failed to download update file" -LogFile $logFile
        }
    }

    if (Test-Path $downloadPath) {
        $fileSize = (Get-Item $downloadPath).Length
        Write-Log -Message "Update file downloaded. File size on disk: $fileSize bytes" -ForegroundColor "Green" -LogFile $logFile
        
        if ($fileSize -lt 1000000) {
            Write-Log -Message "Error: The downloaded file is too small to be a valid update package" -ForegroundColor "Red" -LogFile $logFile
            Exit-Script -ExitCode 1 -Message "Downloaded file appears to be invalid" -LogFile $logFile
        }
    } else {
        Write-Log -Message "Error: Failed to download update file" -ForegroundColor "Red" -LogFile $logFile
        Exit-Script -ExitCode 1 -Message "Downloaded file not found" -LogFile $logFile
    }

    Write-Log -Message "Starting update installation..." -ForegroundColor "Yellow" -LogFile $logFile

    try {
        $wusaLogPath = Join-Path -Path $kbDir -ChildPath "$kbNumber-install-details.txt"
        $exitCode = 0
        
        if ($fileExtension -eq ".msu") {
            Write-Log -Message "Installing MSU file using wusa.exe..." -ForegroundColor "Yellow" -LogFile $logFile
            $exitCode = Install-MsuFile -MsuFilePath $downloadPath -LogFile $logFile -WusaLogPath $wusaLogPath
        }
        elseif ($fileExtension -eq ".cab") {
            $exitCode = Install-CabFile -CabFilePath $downloadPath -KbDir $kbDir -KbNumber $kbNumber -LogFile $logFile
        }
        else {
            Write-Log -Message "Error: Unsupported file extension: $fileExtension" -ForegroundColor "Red" -LogFile $logFile
            Exit-Script -ExitCode 1 -Message "Unsupported file extension" -LogFile $logFile
        }
        
        Write-Log -Message "Installation process completed with exit code: $exitCode" -ForegroundColor "Yellow" -LogFile $logFile
        
        $exitDescription = Get-WUSAExitCodeDescription $exitCode
        
        # Set installResult based on exit code
        switch ($exitCode) {
            0 { $installResult = "SUCCESS" }
            2359302 { $installResult = "ALREADY_INSTALLED" }
            3010 { $installResult = "SUCCESS_REBOOT_REQUIRED" }
            1641 { $installResult = "SUCCESS_REBOOT_INITIATED" }
            1642 { $installResult = "SUCCESS_REBOOT_REQUIRED" }
            2359301 { $installResult = "NOT_APPLICABLE" }
            2359303 { $installResult = "FAILED_PREREQUISITES" }
            2359304 { $installResult = "FAILED_PREREQUISITES" }
            1603 { $installResult = "FATAL_ERROR" }
            default { 
                if ($exitCode -gt 0) {
                    $installResult = "FAILED"
                } else {
                    $installResult = "SUCCESS"
                }
            }
        }
        
        # Perform verification silently (log to file only)
        Write-Log -Message "Verifying installation..." -ForegroundColor "Yellow" -LogFile $logFile -NoConsole
        Start-Sleep -Seconds 5
        
        $verificationSuccess = $false
        $updateInfo = Get-HotFix -Id $kbNumber -ErrorAction SilentlyContinue
        
        if ($updateInfo) {
            Write-Log -Message "Verification: Update $kbNumber is installed (Date: $($updateInfo.InstalledOn))" -ForegroundColor "Green" -LogFile $logFile -NoConsole
            $verificationSuccess = $true
        } else {
            Write-Log -Message "Update not found via Get-HotFix. This may be normal if a reboot is pending" -ForegroundColor "Yellow" -LogFile $logFile -NoConsole
            
            if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641 -or $exitCode -eq 1642) {
                Write-Log -Message "Installation appears successful based on exit code" -ForegroundColor "Green" -LogFile $logFile -NoConsole
                $verificationSuccess = $true
            }
        }
        
        # Check reboot status silently (log to file only)
        $rebootStatus = Get-PendingRebootStatus
        $rebootRequired = $rebootStatus.RebootPending -or $installResult -eq "SUCCESS_REBOOT_REQUIRED" -or $installResult -eq "SUCCESS_REBOOT_INITIATED"
        
        if ($rebootStatus.RebootPending) {
            Write-Log -Message "Reboot pending detected from sources: $($rebootStatus.RebootSources -join ', ')" -ForegroundColor "Yellow" -LogFile $logFile -NoConsole
        }
        
        # Display only a single detailed summary
        Write-Log -Message "--------------------------------------------" -ForegroundColor "Cyan" -LogFile $logFile
        Write-Log -Message "INSTALLATION SUMMARY FOR $kbNumber" -ForegroundColor "Cyan" -LogFile $logFile
        Write-Log -Message "Status: $installResult" -ForegroundColor "Cyan" -LogFile $logFile
        Write-Log -Message "Exit Code: $exitCode ($exitDescription)" -ForegroundColor "Cyan" -LogFile $logFile
        Write-Log -Message "Verification: $(if ($verificationSuccess) {"PASSED"} else {"PENDING"})" -ForegroundColor "Cyan" -LogFile $logFile
        Write-Log -Message "Reboot Required: $(if ($rebootRequired) {"YES"} else {"NO"})" -ForegroundColor "Cyan" -LogFile $logFile
        
        # Only display reboot sources if a reboot is required
        if ($rebootRequired -and $rebootStatus.RebootSources) {
            Write-Log -Message "Reboot Required Due To: $($rebootStatus.RebootSources -join ', ')" -ForegroundColor "Cyan" -LogFile $logFile
        }
        Write-Log -Message "--------------------------------------------" -ForegroundColor "Cyan" -LogFile $logFile
        
        # Set overall success
        if ($installResult -eq "SUCCESS" -or $installResult -eq "SUCCESS_REBOOT_REQUIRED" -or 
            $installResult -eq "SUCCESS_REBOOT_INITIATED" -or $installResult -eq "ALREADY_INSTALLED" -or 
            $installResult -eq "NOT_APPLICABLE") {
            $overallSuccess = $true
        }
        
        # Perform cleanup if needed
        $cleanupAfterInstall = $true
        if ($overallSuccess -and $cleanupAfterInstall) {
            try {
                Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue
                Write-Log -Message "Cleanup: Removed downloaded update file to save disk space" -ForegroundColor "Green" -LogFile $logFile
            } catch {
                Write-Log -Message "Warning: Could not remove downloaded file: $($_.Exception.Message)" -ForegroundColor "Yellow" -LogFile $logFile -NoConsole
            }
        }
        
        # Exit with appropriate code and message
        if ($overallSuccess) {
            if ($rebootRequired) {
                # Simple exit message that doesn't repeat information in the summary
                Exit-Script -ExitCode 3010 -Message "Installation successful. Reboot required to complete." -LogFile $logFile
            } else {
                Exit-Script -ExitCode 0 -Message "Installation completed successfully." -LogFile $logFile
            }
        } else {
            Exit-Script -ExitCode $exitCode -Message "Installation failed with exit code $exitCode." -LogFile $logFile
        }
    } catch {
        Write-Log -Message "Error during installation: $($_.Exception.Message)" -ForegroundColor "Red" -LogFile $logFile
        Exit-Script -ExitCode 1 -Message "Installation failed with an unexpected error." -LogFile $logFile
    }
} catch {
    Write-Log -Message "Critical error: $($_.Exception.Message)" -ForegroundColor "Red" -LogFile $logFile
    Exit-Script -ExitCode 1 -Message "Script execution failed with an unexpected error." -LogFile $logFile
}