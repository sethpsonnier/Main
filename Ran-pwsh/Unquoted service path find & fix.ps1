# Scheduled Unquoted Service Path Scanner and Remediation
# To be run on Monday and Friday at 11 AM
# Version: 1.2.3 - March 19, 2025

# Parameters
param(
    [Parameter(Mandatory=$false, HelpMessage="Directory to store log files")]
    [ValidateScript({Test-Path $_ -IsValid})]
    [string]$LogDir = "C:\temp",
    
    [Parameter(Mandatory=$false, HelpMessage="Fallback directory if primary is unavailable")]
    [ValidateScript({Test-Path $_ -IsValid})]
    [string]$FallbackLogDir = "C:\Windows\temp",
    
    [Parameter(Mandatory=$false, HelpMessage="Path to remediation log for restoration")]
    [ValidateScript({-not $_ -or (Test-Path $_ -IsValid)})]
    [string]$RemediationLogFile = "",
    
    [Parameter(Mandatory=$false, HelpMessage="Only scan without fixing")]
    [switch]$ScanOnly
)

#region Helper Functions

# Function to create and validate log directory
function Initialize-LogDirectory {
    param(
        [string]$PrimaryDir,
        [string]$FallbackDir
    )
    
    $actualLogDir = $PrimaryDir
    
    try {
        if (-not (Test-Path -Path $PrimaryDir -PathType Container)) {
            try {
                New-Item -Path $PrimaryDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Output "Created log directory: $($PrimaryDir)"
            }
            catch {
                Write-Output "WARNING: Could not create primary log directory: $($_.Exception.Message)"
                $actualLogDir = $FallbackDir
                
                if (-not (Test-Path -Path $FallbackDir -PathType Container)) {
                    try {
                        New-Item -Path $FallbackDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        Write-Output "Created fallback log directory: $($FallbackDir)"
                    }
                    catch {
                        Write-Output "WARNING: Could not create fallback log directory: $($_.Exception.Message)"
                        $actualLogDir = "C:\Windows\temp"
                        Write-Output "Using default Windows temp directory: $($actualLogDir)"
                    }
                }
            }
        }
    }
    catch {
        Write-Output "CRITICAL ERROR: Unable to setup logging environment: $($_.Exception.Message)"
        $actualLogDir = "C:\Windows\temp"
    }
    
    # Final verification that directory exists
    if (-not (Test-Path -Path $actualLogDir -PathType Container)) {
        try {
            New-Item -Path $actualLogDir -ItemType Directory -Force | Out-Null
        }
        catch {
            Write-Output "CRITICAL ERROR: Cannot create any log directory. Logs will not be saved."
            return $null
        }
    }
    
    return $actualLogDir
}

# Function to write remediation log entries
function Write-RemediationLog {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory=$true)]
        [string]$OldPath,
        
        [Parameter(Mandatory=$true)]
        [string]$NewPath,
        
        [Parameter(Mandatory=$true)]
        [bool]$Success,
        
        [Parameter(Mandatory=$false)]
        [string]$ErrorMessage = "",
        
        [Parameter(Mandatory=$true)]
        [string]$LogFilePath
    )
    
    $entry = [PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ServiceName = $ServiceName
        OldPath = $OldPath
        NewPath = $NewPath
        Success = $Success
        ErrorMessage = $ErrorMessage
        Username = $env:USERNAME
        ComputerName = $env:COMPUTERNAME
    }
    
    try {
        # Create the remediation log file with headers if it doesn't exist
        if (-not (Test-Path -Path $LogFilePath)) {
            $entry | Export-Csv -Path $LogFilePath -NoTypeInformation -ErrorAction Stop
        } else {
            $entry | Export-Csv -Path $LogFilePath -Append -NoTypeInformation -ErrorAction Stop
        }
    }
    catch {
        Write-Output "WARNING: Failed to write to remediation log: $($_.Exception.Message)"
    }
}

# Function to restart a service with timeout handling
function Restart-ServiceWithTimeout {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ServiceName,
        
        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 30,
        
        [Parameter(Mandatory=$true)]
        [string]$RemediationLogPath
    )
    
    try {
        Write-Output "Restarting service: $($ServiceName)"
        
        # Add timeout handling for service restarts
        $job = Start-Job -ScriptBlock {
            param($svcName)
            Restart-Service -Name $svcName -Force -ErrorAction Stop
        } -ArgumentList $ServiceName
        
        # Wait for the specified timeout period for the job to complete
        if (Wait-Job -Job $job -Timeout $TimeoutSeconds) {
            # Receive job but don't store in unused variable
            Receive-Job -Job $job -ErrorAction Stop | Out-Null
            Write-Output "  Success: Service restarted"
            
            # Log the successful restart
            Write-RemediationLog -ServiceName $ServiceName -OldPath "N/A" -NewPath "N/A" -Success $true -ErrorMessage "Service Restarted" -LogFilePath $RemediationLogPath
            return $true
        } else {
            Write-Output "  WARNING: Service restart operation timed out after $TimeoutSeconds seconds"
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            
            # Log the timeout
            Write-RemediationLog -ServiceName $ServiceName -OldPath "N/A" -NewPath "N/A" -Success $false -ErrorMessage "Restart Timeout after $TimeoutSeconds seconds" -LogFilePath $RemediationLogPath
            return $false
        }
    }
    catch {
        Write-Output "Failed to restart service $($ServiceName): $($_.Exception.Message)"
        
        # Log the failed restart
        Write-RemediationLog -ServiceName $ServiceName -OldPath "N/A" -NewPath "N/A" -Success $false -ErrorMessage "Restart Failed: $($_.Exception.Message)" -LogFilePath $RemediationLogPath
        return $false
    }
    finally {
        # Ensure job is removed
        if ($job) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

# Function to safely write to the Event Log
function Write-SecureEventLog {
    param(
        [int]$EventId,
        [System.Diagnostics.EventLogEntryType]$EntryType,
        [string]$Message
    )
    
    try {
        # Check if source exists
        if (-not [System.Diagnostics.EventLog]::SourceExists("UnquotedServicePathTool")) {
            try {
                # Try to create event source
                [System.Diagnostics.EventLog]::CreateEventSource("UnquotedServicePathTool", "Application")
            }
            catch {
                # If we can't create, fall back to System source
                Write-Output "WARNING: Could not create event source: $($_.Exception.Message)"
                Write-EventLog -LogName Application -Source "System" -EventId $EventId -EntryType $EntryType -Message $Message -ErrorAction Stop
                return
            }
        }
        
        # Write to event log with the tool source
        Write-EventLog -LogName Application -Source "UnquotedServicePathTool" -EventId $EventId -EntryType $EntryType -Message $Message -ErrorAction Stop
    }
    catch {
        Write-Output "WARNING: Could not write to Event Log: $($_.Exception.Message)"
    }
}

# Function to acquire a lock with retry
function Get-ScriptLock {
    param (
        [Parameter(Mandatory=$true)]
        [string]$LockFile,
        [int]$MaxRetries = 3,
        [int]$RetryDelayMs = 500
    )
    
    $retryCount = 0
    
    # Check if lock file exists
    while (Test-Path $LockFile) {
        try {
            $lockTime = Get-Content $LockFile -ErrorAction Stop
            $lockDateTime = [DateTime]::Parse($lockTime)
            $timeDiff = (Get-Date) - $lockDateTime
            
            # If lock is older than 1 hour, assume it's stale
            if ($timeDiff.TotalHours -lt 1) {
                # Lock is valid, decide what to do
                if ($retryCount -lt $MaxRetries) {
                    Write-Output "Another instance is running. Waiting and retrying... (Attempt $($retryCount+1))"
                    Start-Sleep -Milliseconds $RetryDelayMs
                    $retryCount++
                    continue
                }
                else {
                    Write-Output "Another instance of this script appears to be running (started at $lockTime)."
                    Write-Output "If you believe this is an error, delete the lock file: $LockFile"
                    return $false
                }
            }
            else {
                Write-Output "Removing stale lock file from previous run."
                Remove-Item $LockFile -Force -ErrorAction Stop
                break
            }
        }
        catch {
            Write-Output "WARNING: Found invalid lock file, will overwrite."
            break
        }
    }
    
    # Create a lock file
    try {
        $guid = [System.Guid]::NewGuid().ToString()
        "$(Get-Date)|$guid" | Out-File $LockFile -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Output "WARNING: Unable to create lock file: $($_.Exception.Message)"
        return $false
    }
}

# Function to release a lock
function Release-ScriptLock {
    param (
        [Parameter(Mandatory=$true)]
        [string]$LockFile
    )
    
    if (Test-Path $LockFile) {
        try {
            Remove-Item $LockFile -Force -ErrorAction Stop
            return $true
        }
        catch {
            Write-Output "WARNING: Failed to remove lock file: $($_.Exception.Message)"
            return $false
        }
    }
    return $true
}

# Function to cleanup old log files based on execution batches
function Remove-OldLogFiles {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LogDirectory,
        
        [Parameter(Mandatory=$false)]
        [int]$KeepLastNRuns = 2,
        
        [Parameter(Mandatory=$false)]
        [switch]$PreserveRemediationLogs = $false,
        
        [Parameter(Mandatory=$false)]
        [string]$FilePrefix = ""
    )
    
    Write-Output "===== LOG CLEANUP PHASE ====="
    Write-Output "Cleaning up log files, keeping the last $KeepLastNRuns execution runs"
    
    if (-not (Test-Path -Path $LogDirectory -PathType Container)) {
        Write-Output "WARNING: Log directory does not exist: $LogDirectory"
        return
    }
    
    try {
        # Get the computer name for file matching if FilePrefix is not provided
        if ([string]::IsNullOrEmpty($FilePrefix)) {
            $FilePrefix = $env:COMPUTERNAME
        }
        
        Write-Output "Using file prefix for cleanup: $FilePrefix"
        
        # Get all log files except remediation logs if preserving them, and only those matching our prefix
        $allFiles = Get-ChildItem -Path $LogDirectory -File | Where-Object {
            $_.Extension -in ".log", ".csv" -and (
                # Regular logs and results with timestamps
                $_.Name -match "^${FilePrefix}_UnquotedServicePaths_\d{8}_\d{6}" -or
                # Timestamped remediation logs (if not preserving)
                (-not $PreserveRemediationLogs -and $_.Name -match "^${FilePrefix}_RemediationLog_\d{8}_\d{6}\.csv$") -or
                # Legacy non-timestamped remediation logs (if not preserving)
                (-not $PreserveRemediationLogs -and $_.Name -eq "${FilePrefix}_RemediationLog.csv")
            )
        }
        
        # Group files by timestamp/run date
        $runBuckets = @{}
        
        foreach ($file in $allFiles) {
            # Extract timestamp from filename (YYYYMMDD_HHMMSS)
            if ($file.Name -match "_(\d{8}_\d{6})") {
                $timestamp = $matches[1]
                
                # Create a new bucket if it doesn't exist
                if (-not $runBuckets.ContainsKey($timestamp)) {
                    $runBuckets[$timestamp] = @()
                }
                
                # Add file to its bucket
                $runBuckets[$timestamp] += $file
            }
            # Handle legacy non-timestamped remediation logs by assigning to oldest bucket
            elseif ($file.Name -eq "${FilePrefix}_RemediationLog.csv") {
                # If we have any buckets, assign to the oldest one
                if ($runBuckets.Count -gt 0) {
                    $oldestTimestamp = $runBuckets.Keys | Sort-Object | Select-Object -First 1
                    $runBuckets[$oldestTimestamp] += $file
                }
                else {
                    # Create a fake "old" timestamp for this file
                    $oldTimestamp = "19700101_000000"
                    if (-not $runBuckets.ContainsKey($oldTimestamp)) {
                        $runBuckets[$oldTimestamp] = @()
                    }
                    $runBuckets[$oldTimestamp] += $file
                }
            }
        }
        
        # Sort buckets by timestamp (newest first)
        $sortedTimestamps = $runBuckets.Keys | Sort-Object -Descending
        
        # Calculate which buckets to keep and which to delete
        $bucketsToKeep = $sortedTimestamps | Select-Object -First $KeepLastNRuns
        $bucketsToDelete = $sortedTimestamps | Where-Object { $_ -notin $bucketsToKeep }
        
        # Information about what's happening
        Write-Output "Found $($sortedTimestamps.Count) distinct execution runs"
        
        if ($bucketsToKeep.Count -gt 0) {
            Write-Output "Keeping runs from: $($bucketsToKeep -join ', ')"
        }
        
        # Delete the old buckets
        $deletedCount = 0
        $totalSizeMB = 0
        
        foreach ($bucket in $bucketsToDelete) {
            $filesToDelete = $runBuckets[$bucket]
            Write-Output "Deleting $($filesToDelete.Count) files from run: $bucket"
            
            foreach ($file in $filesToDelete) {
                try {
                    $fileSizeMB = [Math]::Round(($file.Length / 1MB), 2)
                    $totalSizeMB += $fileSizeMB
                    
                    # Delete the file
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    $deletedCount++
                    Write-Output "  Deleted: $($file.Name) ($fileSizeMB MB)"
                }
                catch {
                    Write-Output "  ERROR deleting $($file.Name): $($_.Exception.Message)"
                }
            }
        }
        
        # Summary
        Write-Output ""
        Write-Output "Log Cleanup Summary:"
        Write-Output "  Total runs found: $($sortedTimestamps.Count)"
        Write-Output "  Runs kept: $($bucketsToKeep.Count)"
        Write-Output "  Runs deleted: $($bucketsToDelete.Count)"
        Write-Output "  Files deleted: $deletedCount"
        Write-Output "  Space recovered: $([Math]::Round($totalSizeMB, 2)) MB"
        
        # Write event log entry for monitoring
        $eventMessage = "Log cleanup completed. Deleted $deletedCount files ($([Math]::Round($totalSizeMB, 2)) MB) from $($bucketsToDelete.Count) runs, keeping the last $KeepLastNRuns execution runs."
        Write-SecureEventLog -EventId 1004 -EntryType Information -Message $eventMessage
    }
    catch {
        Write-Output "ERROR during log cleanup: $($_.Exception.Message)"
        Write-SecureEventLog -EventId 1005 -EntryType Error -Message "Log cleanup failed: $($_.Exception.Message)"
    }
}

#endregion Helper Functions

#region Main Script

# Initialize variables
$transcriptRunning = $false
$successCount = 0
$failureCount = 0
$results = @()
$vulnerableServices = @()
$fixedServices = @()
$restoredServices = @()

# Initialize lock file path
$lockFile = "$env:TEMP\UnquotedServicePathFix.lock"

# Try to acquire a lock
if (-not (Get-ScriptLock -LockFile $lockFile)) {
    exit 0
}

try {
    # Initialize log directory
    $LogDir = Initialize-LogDirectory -PrimaryDir $LogDir -FallbackDir $FallbackLogDir

    if (-not $LogDir) {
        Write-Output "ERROR: Cannot create any log directory. Exiting."
        exit 1
    }

    # Get computer name and generate timestamps for filenames
    $computerName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logPath = Join-Path -Path $LogDir -ChildPath "$($computerName)_UnquotedServicePaths_$($timestamp).log"
    $csvPath = Join-Path -Path $LogDir -ChildPath "$($computerName)_UnquotedServicePaths_$($timestamp).csv"
    $remediationLogPath = Join-Path -Path $LogDir -ChildPath "$($computerName)_RemediationLog_$($timestamp).csv"

    # Start logging
    try {
        Start-Transcript -Path $logPath -ErrorAction Stop
        $transcriptRunning = $true
    }
    catch {
        Write-Output "WARNING: Failed to start transcript: $($_.Exception.Message)"
    }

    Write-Output "===== Unquoted Service Path Scanner and Remediation ====="
    Write-Output "Started at: $(Get-Date)"
    Write-Output "Computer Name: $($computerName)"
    Write-Output "Log directory: $($LogDir)"
    Write-Output ""

    # Determine operation mode
    $operationMode = "Unknown"
    if (-not [string]::IsNullOrEmpty($RemediationLogFile)) {
        $operationMode = "Restore"
        
        if (-not (Test-Path -Path $RemediationLogFile -PathType Leaf)) {
            Write-Output "ERROR: Remediation log file not found: $($RemediationLogFile)"
            exit 1
        }
        
        Write-Output "Mode: Restore from remediation log"
        Write-Output "Remediation log file: $($RemediationLogFile)"
    } else {
        $operationMode = "ScanAndFix"
        Write-Output "Mode: Scan and Fix (ScanOnly=$ScanOnly)"
    }

    # Define column order for consistent CSV output
    $csvColumnOrder = @(
        "ServiceName", 
        "Key", 
        "ImagePath", 
        "Status", 
        "BadKey", 
        "FixedKey", 
        "ReasonVulnerable",
        "ServiceStatus",
        "StartupType"
    )

    #region Scan and Fix Mode
    if ($operationMode -eq "ScanAndFix") {
        # Reset counters for this mode
        $successCount = 0
        $failureCount = 0
        
        # SCAN PHASE
        Write-Output ""
        Write-Output "===== SCANNING PHASE ====="
        Write-Output "Retrieving services from registry..."

        try {
            $services = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction Stop
            Write-Output "Successfully retrieved $($services.Count) services"
        } catch {
            Write-Output "CRITICAL ERROR: Unable to access registry: $($_.Exception.Message)"
            exit 1
        }

        Write-Output "Analyzing $($services.Count) services for unquoted paths..."

        # Create a hashtable of all services status for better performance
        $serviceStatusCache = @{}
        try {
            # Get all services in one operation for better performance
            $allServiceObjects = Get-Service -ErrorAction Stop
            foreach ($svc in $allServiceObjects) {
                $serviceStatusCache[$svc.Name] = @{
                    Status = $svc.Status
                    StartType = $svc.StartType
                }
            }
        } catch {
            Write-Output "WARNING: Could not pre-fetch service statuses: $($_.Exception.Message)"
        }

        foreach ($service in $services) {
            try {
                # Get service properties
                $serviceName = $service.PSChildName
                $serviceProps = $null
                
                try {
                    $serviceProps = Get-ItemProperty $service.PSPath -ErrorAction Stop
                } catch {
                    Write-Output "Error getting properties for service $($serviceName): $($_.Exception.Message)"
                    continue
                }
                
                # Skip services without ImagePath
                if (-not $serviceProps.ImagePath) { 
                    continue 
                }
                
                # Get service status from cache or direct query
                $serviceStatus = "Unknown"
                $startupType = "Unknown"
                if ($serviceStatusCache.ContainsKey($serviceName)) {
                    $serviceStatus = $serviceStatusCache[$serviceName].Status
                    $startupType = $serviceStatusCache[$serviceName].StartType
                } else {
                    try {
                        $serviceObj = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                        if ($serviceObj) { 
                            $serviceStatus = $serviceObj.Status 
                            $startupType = $serviceObj.StartType
                        }
                    } catch {
                        Write-Output "Warning: Cannot get status for service $($serviceName): $($_.Exception.Message)"
                    }
                }
                
                $imagePath = $serviceProps.ImagePath
                $registryPath = $service.PSPath -replace 'Microsoft\.PowerShell\.Core\\Registry::', ''
                
                # Create result object
                $resultObj = [PSCustomObject]@{
                    ServiceName = $serviceName
                    Key = $registryPath
                    ImagePath = $imagePath
                    Status = "Checked"
                    BadKey = "No"
                    FixedKey = "N/A"
                    ReasonVulnerable = ""
                    ServiceStatus = $serviceStatus
                    StartupType = $startupType
                }
                
                # Skip paths that start with quotes (already properly quoted)
                if ($imagePath.StartsWith('"')) { 
                    $results += $resultObj
                    continue 
                }
                
                # Skip special system paths that don't need quotes
                if ($imagePath.StartsWith('\??\')) { 
                    $results += $resultObj
                    continue 
                }
                
                # Check if the path contains spaces
                if (-not $imagePath.Contains(' ')) { 
                    $results += $resultObj
                    continue 
                }
                
                # If we get here, we have an unquoted path with spaces
                # Before trying to fix it, verify that the EXECUTABLE PATH (not parameters) actually has spaces
                
                # First, determine if there are parameters by looking for space followed by - or /
                $pathParts = $imagePath -split '(?=\s+[-/])', 2
                
                # Get the executable path (first part)
                $executablePath = $pathParts[0].Trim()
                
                # Check if the executable path itself (not including parameters) contains spaces
                if ($executablePath.Contains(" ")) {
                    # Only then do we need to fix it
                    $parameters = ""
                    if ($pathParts.Length -gt 1) {
                        $parameters = $pathParts[1]
                    }
                    
                    # Build the fixed path - only quote the executable portion
                    $fixedPath = "`"$($executablePath)`"$($parameters)"
                    
                    # Update the result object
                    $resultObj.BadKey = "Yes"
                    $resultObj.Status = "Needs Fix"
                    $resultObj.FixedKey = $fixedPath
                    $resultObj.ReasonVulnerable = "Unquoted path with spaces"
                }
                
                # Add to results
                $results += $resultObj
            }
            catch {
                # Add error handling info
                $errorObj = [PSCustomObject]@{
                    ServiceName = $service.PSChildName
                    Key = $service.PSPath -replace 'Microsoft\.PowerShell\.Core\\Registry::', ''
                    ImagePath = "Error processing service"
                    Status = "Error"
                    BadKey = "Unknown"
                    FixedKey = "N/A"
                    ReasonVulnerable = "Error: $($_.Exception.Message)"
                    ServiceStatus = "Unknown"
                    StartupType = "Unknown"
                }
                $results += $errorObj
                Write-Output "Error processing service $($service.PSChildName): $($_.Exception.Message)"
            }
        }

        # Save scan results to CSV
        try {
            # Use the predefined column list to ensure consistent property order in CSV
            $results | Select-Object $csvColumnOrder |
            Export-Csv -Path $csvPath -NoTypeInformation -ErrorAction Stop
            Write-Output "Scan results saved to: $($csvPath)"
        } catch {
            Write-Output "ERROR: Failed to save CSV: $($_.Exception.Message)"
        }

        # Get summary numbers
        $vulnerableServices = @($results | Where-Object {$_.BadKey -eq "Yes"})
        $vulnerableCount = $vulnerableServices.Count
        $totalCount = $results.Count

        Write-Output ""
        Write-Output "===== SCAN SUMMARY ====="
        Write-Output "Total services scanned: $($totalCount)"
        Write-Output "Vulnerable services found: $($vulnerableCount)"

        if ($vulnerableCount -gt 0) {
            Write-Output ""
            Write-Output "===== VULNERABLE SERVICES ====="
            $vulnerableServices | ForEach-Object {
                Write-Output "Service: $($_.ServiceName)"
                Write-Output "  Current Path: $($_.ImagePath)"
                Write-Output "  Suggested Fix: $($_.FixedKey)"
                Write-Output ""
            }
        }

        # FIX PHASE
        # Skip remediation if ScanOnly is specified
        if ($ScanOnly) {
            Write-Output "ScanOnly mode specified. Skipping remediation phase."
        }
        elseif ($vulnerableServices.Count -gt 0) {
            Write-Output ""
            Write-Output "===== REMEDIATION PHASE ====="

            $successCount = 0
            $failureCount = 0
            $fixedServices = @()
            
            foreach ($service in $vulnerableServices) {
                Write-Output "Processing service: $($service.ServiceName)"
                Write-Output "  Current Path: $($service.ImagePath)"
                Write-Output "  Fixed Path: $($service.FixedKey)"
                
                try {
                    # Convert the registry path or build it from service name
                    $regPath = ""
                    if (-not [string]::IsNullOrEmpty($service.Key)) {
                        $regPath = $service.Key -replace 'HKEY_LOCAL_MACHINE', 'HKLM:'
                    } else {
                        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($service.ServiceName)"
                    }
                    
                    # Check if the registry key exists
                    if (-not (Test-Path -Path $regPath)) {
                        Write-Output "  WARNING: Registry key not found: $regPath"
                        $failureCount++
                        continue
                    }
                    
                    # Apply the fix
                    Set-ItemProperty -Path $regPath -Name "ImagePath" -Value $service.FixedKey -ErrorAction Stop
                    Write-Output "  Success: Path updated"
                    $successCount++
                    $fixedServices += $service.ServiceName
                    
                    # Log the successful remediation
                    Write-RemediationLog -ServiceName $service.ServiceName -OldPath $service.ImagePath -NewPath $service.FixedKey -Success $true -LogFilePath $remediationLogPath
                } catch {
                    Write-Output "  ERROR: Failed to update path: $($_.Exception.Message)"
                    $failureCount++
                    
                    # Log the failed remediation attempt
                    Write-RemediationLog -ServiceName $service.ServiceName -OldPath $service.ImagePath -NewPath $service.FixedKey -Success $false -ErrorMessage $_.Exception.Message -LogFilePath $remediationLogPath
                }
            }
            
            Write-Output ""
            Write-Output "===== REMEDIATION SUMMARY ====="
            Write-Output "Successfully fixed $($successCount) services"
            if ($failureCount -gt 0) {
                Write-Output "Failed to fix $($failureCount) services"
            }
            Write-Output "Detailed remediation log saved to: $($remediationLogPath)"
            
            # Automatically restart services that were running
            if ($fixedServices.Count -gt 0) {
                Write-Output ""
                Write-Output "===== SERVICE RESTART PHASE ====="
                Write-Output "Checking for services that need to be restarted..."
                
                foreach ($serviceName in $fixedServices) {
                    try {
                        # Get the service status from the scan results
                        $scanResult = $vulnerableServices | Where-Object { $_.ServiceName -eq $serviceName } | Select-Object -First 1
                        $shouldRestart = $false
                        
                        if ($scanResult -and $scanResult.ServiceStatus -eq "Running") {
                            $shouldRestart = $true
                        } else {
                            # If not found in scan results or status isn't recorded, check current status
                            $service = Get-Service -Name $serviceName -ErrorAction Stop
                            if ($service.Status -eq 'Running') {
                                $shouldRestart = $true
                            }
                        }
                        
                        if ($shouldRestart) {
                            # Use the helper function to restart the service
                            Restart-ServiceWithTimeout -ServiceName $serviceName -TimeoutSeconds 30 -RemediationLogPath $remediationLogPath
                        } else {
                            Write-Output "Skipping service restart for $($serviceName) (Not running)"
                        }
                    }
                    catch {
                        Write-Output "Failed to check service $($serviceName): $($_.Exception.Message)"
                        
                        # Log the failed check
                        Write-RemediationLog -ServiceName $serviceName -OldPath "N/A" -NewPath "N/A" -Success $false -ErrorMessage "Status Check Failed: $($_.Exception.Message)" -LogFilePath $remediationLogPath
                    }
                }
            }
        }
    } 
    #endregion Scan and Fix Mode

    #region Restore Mode
    elseif ($operationMode -eq "Restore") {
        # Reset counters for this mode
        $successCount = 0
        $failureCount = 0
        
        try {
            Write-Output ""
            Write-Output "===== RESTORE MODE ====="
            Write-Output "Reading remediation data from $($RemediationLogFile)..."
            
            # Add more robust CSV parsing
            $remediationData = $null
            try {
                $remediationData = Import-Csv -Path $RemediationLogFile -ErrorAction Stop
            }
            catch {
                Write-Output "ERROR: Failed to parse remediation log: $($_.Exception.Message)"
                exit 1
            }
            
            # Check if this is a valid remediation log (should have OldPath and NewPath columns)
            $requiredColumns = @("OldPath", "NewPath")
            $availableColumns = ($remediationData | Get-Member -MemberType NoteProperty).Name
            $missingColumns = $requiredColumns | Where-Object { $availableColumns -notcontains $_ }
            
            if ($missingColumns.Count -gt 0) {
                Write-Output "ERROR: The file doesn't appear to be a valid remediation log."
                Write-Output "Missing required columns: $($missingColumns -join ', ')"
                exit 1
            }
            
            # Process the remediation log
            $servicesToRestore = @()
            foreach ($entry in $remediationData) {
                #Only process entries with both paths and exclude service restart entries
                if ([string]::IsNullOrEmpty($entry.OldPath) -or [string]::IsNullOrEmpty($entry.NewPath) -or $entry.OldPath -eq "N/A") {
                    continue
                }
                
                $servicesToRestore += [PSCustomObject]@{
                    ServiceName = $entry.ServiceName
                    OldPath = $entry.OldPath
                    NewPath = $entry.NewPath
                }
            }
            
            Write-Output "Found $($servicesToRestore.Count) service paths to restore."
            $successCount = 0
            $failureCount = 0
            $restoredServices = @()
            
            foreach ($entry in $servicesToRestore) {
                $svcName = $entry.ServiceName
                if ([string]::IsNullOrEmpty($svcName)) {
                    # Try to find the service name from the path
                    try {
                        # Get all services
                        $allServices = Get-Service -ErrorAction Stop
                        
                        # Try to find matching service by comparing current ImagePath
                        $found = $false
                        foreach ($svc in $allServices) {
                            try {
                                $svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
                                if (Test-Path $svcKey) {
                                    $currentPath = (Get-ItemProperty -Path $svcKey -ErrorAction SilentlyContinue).ImagePath
                                    if ($currentPath -eq $entry.NewPath) {
                                        $svcName = $svc.Name
                                        $found = $true
                                        break
                                    }
                                }
                            } catch {
                                # Continue to next service
                            }
                        }
                        
                        if (-not $found) {
                            Write-Output "  WARNING: Could not determine service name for path: $($entry.NewPath)"
                            Write-Output "  Skipping this entry."
                            $failureCount++
                            continue
                        }
                    } catch {
                        Write-Output "  ERROR: Failed to search for service: $($_.Exception.Message)"
                        $failureCount++
                        continue
                    }
                }
                
                Write-Output "Restoring service: $svcName"
                Write-Output "  Current path: $($entry.NewPath)"
                Write-Output "  Original path: $($entry.OldPath)"
                
                try {
                    # Find the registry key for this service
                    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
                    
                    # Check if the registry key exists
                    if (-not (Test-Path -Path $regPath)) {
                        Write-Output "  WARNING: Registry key not found: $regPath"
                        $failureCount++
                        continue
                    }
                    
                    # Restore the original path
                    Set-ItemProperty -Path $regPath -Name "ImagePath" -Value $entry.OldPath -ErrorAction Stop
                    Write-Output "  Success: Path restored"
                    $successCount++
                    $restoredServices += $svcName
                    
                    # Log the restoration
                    Write-RemediationLog -ServiceName $svcName -OldPath $entry.NewPath -NewPath $entry.OldPath -Success $true -LogFilePath $remediationLogPath
                } catch {
                    Write-Output "  ERROR: Failed to restore path: $($_.Exception.Message)"
                    $failureCount++
                    
                    # Log the failed restoration
                    Write-RemediationLog -ServiceName $svcName -OldPath $entry.NewPath -NewPath $entry.OldPath -Success $false -ErrorMessage $_.Exception.Message -LogFilePath $remediationLogPath
                }
            }
            
            # Create a log of what was restored
            $restoreLogPath = Join-Path -Path $LogDir -ChildPath "$($computerName)_RestoredServices_$($timestamp).txt"
            try {
                "Restored services on $(Get-Date)" | Out-File -FilePath $restoreLogPath
                "===============================" | Out-File -FilePath $restoreLogPath -Append
                $restoredServices | ForEach-Object { $_ | Out-File -FilePath $restoreLogPath -Append }
                Write-Output "Log of restored services saved to: $($restoreLogPath)"
            } catch {
                Write-Output "Could not save log of restored services: $($_.Exception.Message)"
            }
            
            Write-Output ""
            Write-Output "===== RESTORATION SUMMARY ====="
            Write-Output "Successfully restored $($successCount) services"
            if ($failureCount -gt 0) {
                Write-Output "Failed to restore $($failureCount) services"
            }
            
            # Automatically restart services that were running
            if ($restoredServices.Count -gt 0) {
                Write-Output ""
                Write-Output "===== SERVICE RESTART PHASE ====="
                Write-Output "Checking for services that need to be restarted..."
                
                foreach ($serviceName in $restoredServices) {
                    try {
                        # Check current status - when restoring, we just check current status
                        $service = Get-Service -Name $serviceName -ErrorAction Stop
                        
                        if ($service.Status -eq 'Running') {
                            # Use the helper function to restart the service
                            Restart-ServiceWithTimeout -ServiceName $serviceName -TimeoutSeconds 30 -RemediationLogPath $remediationLogPath
                        } else {
                            Write-Output "Skipping service restart for $($serviceName) (Not running)"
                        }
                    }
                    catch {
                        Write-Output "Failed to check service $($serviceName): $($_.Exception.Message)"
                        
                        # Log the failed check
                        Write-RemediationLog -ServiceName $serviceName -OldPath "N/A" -NewPath "N/A" -Success $false -ErrorMessage "Status Check Failed: $($_.Exception.Message)" -LogFilePath $remediationLogPath
                    }
                }
            }
        }
        catch {
            Write-Output "ERROR: Failed to process remediation log: $($_.Exception.Message)"
        }
    }
    #endregion Restore Mode
    else {
        Write-Output "ERROR: Unknown operation mode: $operationMode"
    }

    # Log to Windows Event Log for better monitoring in automated environments
    try {
        if ($operationMode -eq "ScanAndFix") {
            if ($vulnerableServices.Count -gt 0) {
                $eventMessage = "Unquoted Service Path scanner found $($vulnerableServices.Count) vulnerable services. Fixed: $successCount, Failed: $failureCount. Log: $logPath"
                
                if ($ScanOnly) {
                    $eventId = 1001  # Scan only, vulnerabilities found
                    $eventType = [System.Diagnostics.EventLogEntryType]::Warning
                } else {
                    $eventId = 1002  # Fix applied
                    $eventType = [System.Diagnostics.EventLogEntryType]::Information
                }
            } else {
                $eventId = 1000  # No vulnerabilities found
                $eventType = [System.Diagnostics.EventLogEntryType]::Information
                $eventMessage = "Unquoted Service Path scanner found no vulnerable services. Log: $logPath"
            }
        }
        elseif ($operationMode -eq "Restore") {
            $eventId = 1003  # Restore operation
            $eventType = [System.Diagnostics.EventLogEntryType]::Information
            $eventMessage = "Unquoted Service Path restore operation completed. Restored: $successCount, Failed: $failureCount. Log: $logPath"
        }
        else {
            $eventId = 9000  # Unknown operation
            $eventType = [System.Diagnostics.EventLogEntryType]::Warning
            $eventMessage = "Unquoted Service Path tool completed with unknown operation mode: $operationMode. Log: $logPath"
        }
        
        Write-SecureEventLog -EventId $eventId -EntryType $eventType -Message $eventMessage
    }
    catch {
        Write-Output "WARNING: Could not write to Event Log: $($_.Exception.Message)"
    }

    # Perform log cleanup with try/catch for error handling
    try {
        Write-Output ""
        Remove-OldLogFiles -LogDirectory $LogDir -KeepLastNRuns 2 -FilePrefix $computerName

        # Only clean the fallback directory if it's different from the primary directory
        # and if it actually exists and contains our log files
        if ($LogDir -ne $FallbackLogDir -and (Test-Path -Path $FallbackLogDir -PathType Container)) {
            # Check if there are any matching log files in the fallback directory
            $fallbackFiles = Get-ChildItem -Path $FallbackLogDir -File | 
                Where-Object { $_.Name -match "^${computerName}_UnquotedServicePaths_\d{8}_\d{6}" }
            
            if ($fallbackFiles.Count -gt 0) {
                Remove-OldLogFiles -LogDirectory $FallbackLogDir -KeepLastNRuns 2 -FilePrefix $computerName
            }
        }
    }
    catch {
        Write-Output "WARNING: Error during log cleanup: $($_.Exception.Message)"
    }

    Write-Output ""
    Write-Output "Script completed at: $(Get-Date)"
    
    # Set the NinjaRMM custom field to indicate this has been checked (only if not already set)
    try {
        # Get current value
        $currentValue = & Ninja-Property-Get unquotedVulnerability
        
        # If it's null, empty, or not 1, set it to 1
        if ($null -eq $currentValue -or $currentValue -eq "" -or $currentValue -ne 1) {
            & Ninja-Property-Set unquotedVulnerability 1
            Write-Output "Successfully set NinjaRMM custom field 'unquotedVulnerability' to 1"
        } else {
            Write-Output "NinjaRMM custom field 'unquotedVulnerability' already set to 1, skipping update"
        }
    }
    catch {
        Write-Output "WARNING: Failed to get/set NinjaRMM custom field: $($_.Exception.Message)"
    }
}
catch {
    Write-Output "CRITICAL ERROR: $($_.Exception.Message)"
    Write-Output "Stack Trace: $($_.ScriptStackTrace)"
    
    # Log the error to event log
    try {
        Write-SecureEventLog -EventId 9999 -EntryType Error -Message "Unquoted Service Path Tool encountered a critical error: $($_.Exception.Message)"
    }
    catch {
        # Last resort error handling
        Write-Output "Could not write to event log: $($_.Exception.Message)"
    }
}
finally {
    # Close transcript if it was started
    if ($transcriptRunning) {
        try {
            Stop-Transcript
        }
        catch {
            Write-Output "WARNING: Failed to stop transcript: $($_.Exception.Message)"
        }
    }

    # Always release the lock file
    Release-ScriptLock -LockFile $lockFile
}

#endregion Main Script