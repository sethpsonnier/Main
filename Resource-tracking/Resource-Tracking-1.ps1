#========================================================================
# Resource-Tracking-1
# Purpose: Resource Collection Script - Collects CPU, RAM, and Disk metrics
# Schedule: Every 5 minutes
# Output: CSV files in C:\temp2\logs\
#========================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$Directory = "C:\temp2\logs",

    [Parameter(Mandatory=$false)]
    [switch]$VerboseLogging
)

#-----------------------------------------------------------
# Helper Function: Write a log line to a CSV file.
# If the file doesn't exist, write a header first.
#-----------------------------------------------------------
function Write-LogLine {
    param(
        [string]$FilePath,
        [string]$Line
    )
    if (-not (Test-Path $FilePath)) {
        # Write CSV header
        "Timestamp,Usage" | Out-File -FilePath $FilePath -Encoding utf8
    }
    Add-Content -Path $FilePath -Value $Line
}

#-----------------------------------------------------------
# Define the base metrics (CPU and RAM) using Get-CimInstance.
#-----------------------------------------------------------
$metrics = @{
    "cpu" = @{
        "filename" = "cpu.txt"
        "getter" = {
            # No parameter needed for CPU metric.
            $cpuUsage = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
            return [math]::Round($cpuUsage, 2)
        }
    }
    "ram" = @{
        "filename" = "ram.txt"
        "getter" = {
            # No parameter needed for RAM metric.
            $memory = Get-CimInstance Win32_OperatingSystem
            $totalMemory = $memory.TotalVisibleMemorySize
            $freeMemory = $memory.FreePhysicalMemory
            $usedMemory = $totalMemory - $freeMemory
            $memoryUsage = ($usedMemory / $totalMemory) * 100
            return [math]::Round($memoryUsage, 2)
        }
    }
}

#-----------------------------------------------------------
# Dynamically add disk metrics for valid local drives.
# Uses drive letter in filename for accurate mapping.
#-----------------------------------------------------------
Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
    $driveLetter = $_.DeviceID
    if ($_.Size -gt 0) {
        # Extract just the letter (C from C:)
        $driveLetterOnly = $driveLetter.Replace(':', '')
        
        # Add disk metric with drive letter in filename
        $metrics.Add("disk_$driveLetterOnly", @{
            "filename"     = "disk_$driveLetterOnly.txt"  # e.g., disk_C.txt, disk_F.txt
            "getter"       = {
                param($driveLetterParam)
                $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$driveLetterParam'"
                if ($disk -and $disk.Size -gt 0) {
                    try {
                        $totalSpace = [decimal]$disk.Size
                        $freeSpace = [decimal]$disk.FreeSpace
                        $usedSpace = $totalSpace - $freeSpace
                        $diskUsage = ($usedSpace / $totalSpace) * 100
                        return [math]::Round($diskUsage, 2)
                    }
                    catch {
                        return $null  # Skip logging if an error occurs
                    }
                }
                return $null  # Skip logging if no valid data
            }
            "driveParam"   = $driveLetter
            "displayName"  = "Drive $driveLetter"
        })
    }
}

#-----------------------------------------------------------
# Ensure the logging directory exists.
#-----------------------------------------------------------
if (-Not (Test-Path -Path $Directory)) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
}

#-----------------------------------------------------------
# Function: Log-Metric
# Logs a single metric value to its designated file in CSV format.
#-----------------------------------------------------------
function Log-Metric {
    param (
        [string]$MetricName,
        [hashtable]$MetricConfig
    )
    
    try {
        $outputFile = Join-Path $Directory $MetricConfig.filename
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        # For metrics that require a parameter (e.g. disk), pass it to the getter.
        if ($MetricConfig.driveParam) {
            $usage = & $MetricConfig.getter $MetricConfig.driveParam
        }
        else {
            $usage = & $MetricConfig.getter
        }
        
        # Only log if a valid usage value is obtained.
        if ($null -ne $usage) {
            $line = "$timestamp,$usage%"
            Write-LogLine -FilePath $outputFile -Line $line

            $displayName = if ($MetricConfig.displayName) { $MetricConfig.displayName } else { $MetricName }
            if ($VerboseLogging) {
                Write-Output "$displayName usage logged to $outputFile"
                Write-Host "$displayName Usage is: $usage%"
            }
        }
    }
     catch {
        # Optionally, you might want to log errors to an error file.
        if ($VerboseLogging) {
            Write-Host "Error logging metric ${MetricName}: $($_)"
        }
    }
}

#-----------------------------------------------------------
# Log all defined metrics.
#-----------------------------------------------------------
foreach ($metric in $metrics.GetEnumerator()) {
    Log-Metric -MetricName $metric.Key -MetricConfig $metric.Value
}