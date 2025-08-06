# New Device Unquoted Service Path Check
# To be run whenever a device comes online
# Version: 1.2.3 - March 19, 2025

# Parameters
param(
    [Parameter(Mandatory=$false, HelpMessage="Directory to store log files")]
    [ValidateScript({Test-Path $_ -IsValid})]
    [string]$LogDir = "C:\temp",
    
    [Parameter(Mandatory=$false, HelpMessage="Fallback directory if primary is unavailable")]
    [ValidateScript({Test-Path $_ -IsValid})]
    [string]$FallbackLogDir = "C:\Windows\temp"
)

# Check the NinjaRMM custom field status
$customFieldValue = & Ninja-Property-Get unquotedVulnerability
Write-Output "Current unquotedVulnerability custom field value: $customFieldValue"

# Only run if the field is null or 0
if ([string]::IsNullOrEmpty($customFieldValue) -or $customFieldValue -eq 0) {
    Write-Output "Device appears to need initial remediation - running scan and fix"
    
    #region Helper Functions

    # Function to create and validate log directory
    function Initialize-LogDirectory {
        param(
            [Parameter(Mandatory=$true)]
            [string]$PrimaryDir,
            
            [Parameter(Mandatory=$true)]
            [string]$FallbackDir
        )
        
        $actualLogDir = $PrimaryDir
        $defaultTempDir = "C:\Windows\temp"
        
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
                            $actualLogDir = $defaultTempDir
                            Write-Output "Using default Windows temp directory: $($actualLogDir)"
                        }
                    }
                }
            }
        }
        catch {
            Write-Output "CRITICAL ERROR: Unable to setup logging environment: $($_.Exception.Message)"
            $actualLogDir = $defaultTempDir
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
            [Parameter(Mandatory=$true)]
            [int]$EventId,
            
            [Parameter(Mandatory=$true)]
            [System.Diagnostics.EventLogEntryType]$EntryType,
            
            [Parameter(Mandatory=$true)]
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
            
            [Parameter(Mandatory=$false)]
            [int]$MaxRetries = 3,
            
            [Parameter(Mandatory=$false)]
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
            [bool]$PreserveRemediationLogs = $false,
            
            [Parameter(Mandatory=$false)]
            [string]$FilePrefix = ""
        )
        
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
    
    # Initialize lock file path
    $lockFile = "$env:TEMP\UnquotedServicePathFix.lock"

    # Try to acquire a lock
    if (-not (Get-ScriptLock -LockFile $lockFile)) {
        Write-Output "Cannot acquire lock. Another instance may be running."
        exit 1
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

        # Always use ScanAndFix mode for this script
        $operationMode = "ScanAndFix"
        Write-Output "Mode: Scan and Fix (Running for new device)"

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
        if ($vulnerableServices.Count -gt 0) {
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
                    # Use the registry path directly from the service object
                    $regPath = $service.Key -replace 'HKEY_LOCAL_MACHINE', 'HKLM:'
                    
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
                        # Get the service directly and check if it's running
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

        # Log to Windows Event Log for better monitoring in automated environments
        try {
            if ($vulnerableServices.Count -gt 0) {
                $eventId = 1002  # Fix applied
                $eventType = [System.Diagnostics.EventLogEntryType]::Information
                $eventMessage = "Unquoted Service Path scanner found $($vulnerableServices.Count) vulnerable services. Fixed: $successCount, Failed: $failureCount. Log: $logPath"
            } else {
                $eventId = 1000  # No vulnerabilities found
                $eventType = [System.Diagnostics.EventLogEntryType]::Information
                $eventMessage = "Unquoted Service Path scanner found no vulnerable services. Log: $logPath"
            }
            
            Write-SecureEventLog -EventId $eventId -EntryType $eventType -Message $eventMessage
        }
        catch {
            Write-Output "WARNING: Could not write to Event Log: $($_.Exception.Message)"
        }

        # Perform log cleanup as the final operation
        try {
            Write-Output ""
            Write-Output "===== LOG CLEANUP PHASE ====="
            # Clean up the primary log directory
            Remove-OldLogFiles -LogDirectory $LogDir -KeepLastNRuns 2 -FilePrefix $computerName

            # Only clean the fallback directory if it's different from the primary AND we actually used it
            if ($LogDir -ne $FallbackLogDir -and 
                (Test-Path -Path $FallbackLogDir -PathType Container) -and
                (Get-ChildItem -Path $FallbackLogDir -File | Where-Object { $_.Name -match "^${computerName}_UnquotedServicePaths_" })) {
                Write-Output "Cleaning up fallback log directory..."
                Remove-OldLogFiles -LogDirectory $FallbackLogDir -KeepLastNRuns 2 -FilePrefix $computerName
            }
        }
        catch {
            Write-Output "WARNING: Error during log cleanup: $($_.Exception.Message)"
        }

        Write-Output ""
        Write-Output "Script completed at: $(Get-Date)"
        
        # Set the NinjaRMM custom field as the very last operation to indicate this has been successfully completed
        try {
            & Ninja-Property-Set unquotedVulnerability 1
            Write-Output "Successfully set NinjaRMM custom field 'unquotedVulnerability' to 1"
        }
        catch {
            Write-Output "WARNING: Failed to set NinjaRMM custom field: $($_.Exception.Message)"
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
}
else {
    Write-Output "Skipping execution - device has already been remediated (custom field value = $customFieldValue)"
    exit 0
}