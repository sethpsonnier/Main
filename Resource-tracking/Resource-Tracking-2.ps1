#========================================================================
# Resource-Tracking-2
# Purpose: Report Generation Script - Creates HTML charts and manages directories
# Schedule: Every hour
# Input: CSV files from C:\temp2\logs\
# Output: HTML charts in C:\temp2\charts\current\
#========================================================================

#------------------------------------------------------------------------
# Directory Structure Setup & Legacy File Migration
#------------------------------------------------------------------------
$baseDir = "C:\temp2"
$logDir = "$baseDir\logs"
$currentDir = "$baseDir\charts\current"
$archiveDir = "$baseDir\charts\archive"

# Ensure all directories exist
@($logDir, $currentDir, $archiveDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-Host "Created directory: $_"
    }
}

# Create current year and month directories for archiving
$currentYear = (Get-Date).Year
$currentMonth = (Get-Date).ToString("MM")
$yearDir = "$archiveDir\$currentYear"
$monthDir = "$yearDir\$currentMonth"

@($yearDir, $monthDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-Host "Created archive directory: $_"
    }
}

# Migration: Move legacy CSV files from parent to logs\
$legacyCsvFiles = Get-ChildItem -Path $baseDir -Filter "*.txt" -File -ErrorAction SilentlyContinue | Where-Object { 
    $_.Name -match "(cpu|ram|disk_|custom)\.txt$" 
}

foreach ($file in $legacyCsvFiles) {
    $destination = Join-Path $logDir $file.Name
    if (-not (Test-Path $destination)) {
        try {
            Move-Item -Path $file.FullName -Destination $destination -ErrorAction Stop
            Write-Host "Migrated CSV file: $($file.Name) -> logs\"
        }
        catch {
            Write-Host "Warning: Could not migrate $($file.Name): $($_)"
        }
    }
}

# Migration: Move legacy HTML chart files from parent to charts\current\
$legacyHtmlFiles = Get-ChildItem -Path $baseDir -Filter "chart_*.html" -File -ErrorAction SilentlyContinue

foreach ($file in $legacyHtmlFiles) {
    $destination = Join-Path $currentDir $file.Name
    if (-not (Test-Path $destination)) {
        try {
            Move-Item -Path $file.FullName -Destination $destination -ErrorAction Stop
            Write-Host "Migrated HTML file: $($file.Name) -> charts\current\"
        }
        catch {
            Write-Host "Warning: Could not migrate $($file.Name): $($_)"
        }
    }
}

#------------------------------------------------------------------------
# Variable Declarations - Updated Paths
#------------------------------------------------------------------------
# Paths to the data files
$cpuDataFile = "$logDir\cpu.txt"
$ramDataFile = "$logDir\ram.txt"
$customDataFile = "$logDir\custom.txt"

# Path to custom CSS file
$customCssPath = "$baseDir\charts-custom.css"

# Custom data configuration
$customDataLabel = "Custom Data"  # Set this to the desired label for the custom data
$customIsPercentage = $false      # Set to $true if the custom data is a percentage, $false if it is a number
$customMinValue = 0               # Minimum value for custom data if it is a number
$customMaxValue = 120             # Maximum value for custom data if it is a number

# Chart configuration
$chartWidth = "80%"               # Set this to the desired width (e.g., "100%", "800px", etc.)
$chartHeight = "400px"            # Set this to the desired height (e.g., "500px", "300px", etc.)

# Choose mode: use last N days or a specific date range
$useLastNDays = $true             # Set to $true to use last N days, $false for custom date range
$lastNDays = 7                    # Default to last 7 days, modify this as needed

# Input date range and number of intervals for custom range mode
$startDate = [DateTime]"2024-05-01"
$endDate = [DateTime]"2024-06-01"
$numPoints = 10                   # Used only if $useLastNDays is $false

#------------------------------------------------------------------------
# Automatically detect disk files - Fixed Version
#------------------------------------------------------------------------
# Automatically detect disk files based on the pattern disk_[LETTER].txt
$diskFiles = @()

# Get all disk files in the logs directory
$diskFilePattern = "$logDir\disk_*.txt"
Get-ChildItem -Path $diskFilePattern -ErrorAction SilentlyContinue | ForEach-Object {
    # Extract drive letter from filename (e.g., disk_C.txt -> C)
    if ($_.Name -match "disk_([A-Z])\.txt") {
        $driveLetter = $matches[1]
        
        $diskFiles += @{
            FilePath = $_.FullName
            DriveLetter = $driveLetter
            DisplayName = "Drive $($driveLetter):"
        }
    }
}

# Get drive sizes for the detected drives
foreach ($disk in $diskFiles) {
    $driveLetter = $disk.DriveLetter
    try {
        # Use Get-CimInstance for consistency with Script 1
        $driveInfo = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($driveLetter):'" -ErrorAction Stop
        if ($driveInfo -and $driveInfo.Size) {
            $disk.SizeGB = [math]::Round($driveInfo.Size / 1GB, 2)
        } else {
            $disk.SizeGB = 0
        }
    } catch {
        $disk.SizeGB = 0
        Write-Host "Warning: Could not get size for drive $($driveLetter):"
    }
}

#------------------------------------------------------------------------
# Date Range Calculation
#------------------------------------------------------------------------
if ($useLastNDays) {
    # Calculate start and end dates based on lastNDays
    $endDate = [DateTime]::Today
    $startDate = $endDate.AddDays(-$lastNDays)
    $numPoints = $lastNDays + 1 # 1 point per day
} else {
    # Ensure end date is today if it's in the future
    if ($endDate -gt [DateTime]::Today) {
        $endDate = [DateTime]::Today
    }
}

# Only for WYSIWYG, don't modify anything here
$startDatePart = $startDate.ToString("dd/MM/yyyy")
$endDatePart = $endDate.ToString("dd/MM/yyyy")
$nowDate = Get-Date

# Calculate the interval span in ticks, ensuring the end date is respected
$totalDays = ($endDate - $startDate).Days
$intervalDays = if ($useLastNDays) { 1 } else { [Math]::Floor($totalDays / ($numPoints - 1)) }

#------------------------------------------------------------------------
# Fixed Get-AverageUsage Function
#------------------------------------------------------------------------
function Get-AverageUsage {
    param (
        [string]$filePath,
        [datetime]$fromDate,
        [datetime]$toDate,
        [bool]$isPercentage = $true,   # Default to percentage
        [double]$minValue = 0,         # Default minimum value for number data
        [double]$maxValue = 100        # Default maximum value for number data
    )
    if (-Not (Test-Path $filePath)) {
        Write-Host "File $filePath does not exist."
        return $null
    }

    $total = 0
    $count = 0

    # Read the file and filter lines within the given date range
    Get-Content $filePath | ForEach-Object {
        # Trim any extra spaces and validate the format
        $line = $_.Trim()
        
        # Skip empty lines
        if ([string]::IsNullOrWhiteSpace($line)) {
            return
        }
        
        $parts = $line -split ","

        # Ensure that the line has exactly two parts before trying to parse them
        if ($parts.Count -ne 2) {
            Write-Host "Warning: Skipping malformed line in file $filePath : `"$line`""
            return
        }

        # Skip header line
        if ($parts[0].Trim() -eq "Timestamp") {
            return
        }

        $date = $null
        $usage = $null
        try {
            # Validate the date format
            $date = [datetime]$parts[0].Trim()
            
            # Extract and process the usage value
            $rawUsage = $parts[1].Trim() -replace '%', ''

            if ($isPercentage) {
                $usage = [float]$rawUsage
            } else {
                # Calculate percentage for number data
                $rawNumber = [float]$rawUsage
                $usage = ($rawNumber - $minValue) / ($maxValue - $minValue) * 100
            }
        } catch {
            # Log a warning message and skip this line
            Write-Host "Warning: Skipping malformed line in file $filePath : `"$line`""
            return
        }
        if ($date -ge $fromDate -and $date -lt $toDate -and $null -ne $usage) {
            $total += $usage
            $count++
        }
    }

    if ($count -gt 0) {
        return $total / $count
    } else {
        return $null
    }
}

#------------------------------------------------------------------------
# Data Processing
#------------------------------------------------------------------------
# Collect results into a table
$results = @()

# Process all data points for the specified time range
for ($pointIndex = 0; $pointIndex -lt $numPoints; $pointIndex++) {
    $currentDate = if ($pointIndex -eq 0) {
        $startDate
    } elseif ($pointIndex -eq $numPoints - 1) {
        $endDate
    } else {
        $startDate.AddDays($intervalDays * $pointIndex)
    }
    
    $nextDate = $currentDate.AddDays(1)
    
    # Get CPU and RAM averages
    $cpuAverage = Get-AverageUsage -filePath $cpuDataFile -fromDate $currentDate -toDate $nextDate
    $ramAverage = Get-AverageUsage -filePath $ramDataFile -fromDate $currentDate -toDate $nextDate
    
    # Process custom data if file exists
    $customAverage = $null
    if (Test-Path $customDataFile) {
        $customAverage = Get-AverageUsage -filePath $customDataFile -fromDate $currentDate -toDate $nextDate -isPercentage $customIsPercentage -minValue $customMinValue -maxValue $customMaxValue
    }

    # Create CPU average value
    $cpuValue = "No Data"
    if ($null -ne $cpuAverage) {
        $cpuValue = "$($cpuAverage.ToString('N2'))%"
    }

    # Create RAM average value
    $ramValue = "No Data"
    if ($null -ne $ramAverage) {
        $ramValue = "$($ramAverage.ToString('N2'))%"
    }

    # Create custom average value
    $customValue = "No Data"
    if ($null -ne $customAverage) {
        $customValue = "$($customAverage.ToString('N2'))%"
    }

    # Create a result object with standard properties
    $resultObj = [PSCustomObject]@{
        Point = $pointIndex + 1
        Date = $currentDate.ToString('dd/MM/yyyy')
        CPU_Average = $cpuValue
        RAM_Average = $ramValue
        Custom_Average = $customValue
    }
    
    # Add disk properties for each detected disk file
    foreach ($disk in $diskFiles) {
        $diskAverage = Get-AverageUsage -filePath $disk.FilePath -fromDate $currentDate -toDate $nextDate
        $propName = "DISK$($disk.DriveLetter)_Average"  # e.g., DISKC_Average, DISKF_Average
        
        # Create disk average value
        $diskValue = "No Data"
        if ($null -ne $diskAverage) {
            $diskValue = "$($diskAverage.ToString('N2'))%"
        }
        
        Add-Member -InputObject $resultObj -MemberType NoteProperty -Name $propName -Value $diskValue
    }
    
    $results += $resultObj
}

# Determine if any of the data sets have "No Data" for all points
$cpuHasData = $false
if (($results | Where-Object { $_.CPU_Average -ne "No Data" } | Measure-Object).Count -gt 0) {
    $cpuHasData = $true
}

$ramHasData = $false
if (($results | Where-Object { $_.RAM_Average -ne "No Data" } | Measure-Object).Count -gt 0) {
    $ramHasData = $true
}

$customHasData = $false
if (($results | Where-Object { $_.Custom_Average -ne "No Data" } | Measure-Object).Count -gt 0) {
    $customHasData = $true
}

# Check data for each disk
$diskHasData = @{}
foreach ($disk in $diskFiles) {
    $propName = "DISK$($disk.DriveLetter)_Average"
    $diskHasData[$disk.DriveLetter] = $false
    if (($results | Where-Object { $_.$propName -ne "No Data" } | Measure-Object).Count -gt 0) {
        $diskHasData[$disk.DriveLetter] = $true
    }
}

# Display the collected data table
$results | Format-Table -AutoSize

Write-Host "Construction of Chart starts from here."

#------------------------------------------------------------------------
# HTML Chart Generation
#------------------------------------------------------------------------

# Check if custom CSS file exists, provide message if not
$customCssExists = Test-Path $customCssPath
if (-not $customCssExists) {
    Write-Host "Warning: Custom CSS file not found at $customCssPath. Using default styling."
}

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <!-- Load the official Charts.css from a CDN -->
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/charts.css/dist/charts.min.css">
    
    <!-- Load custom CSS if it exists -->
"@

if ($customCssExists) {
    # Use file:// protocol for local file
    $customCssPathForHtml = "file://" + $customCssPath.Replace("\", "/")
    $htmlContent += @"
    <link rel="stylesheet" href="$customCssPathForHtml">
"@
}

$htmlContent += @"
    <title>Resource Utilization</title>
    <style>
        /* Ensure we get proper spacing */
        body {
            font-family: Arial, sans-serif;
            margin: 0px;
        }
        .chart-title {
            font-size: 18px;
            font-weight: bold;
            margin-bottom: 5px;
        }
        .date-range {
            font-size: 14px;
            margin-bottom: 10px;
        }
        .report-date {
            font-size: 12px;
            color: #666;
            margin-top: 15px;
        }
    </style>
    
</head>
<body>
    <div class="chart-title">Resource Utilization: $startDatePart to $endDatePart</div>
    <p>Output Number Predefined: $numPoints (Daily Average Calculation)</p>
    <div class="chart-container" style="width: $chartWidth;">
        <table class='charts-css line multiple show-data-on-hover show-labels show-primary-axis show-10-secondary-axes show-heading show-data-axes'
               style="height: $chartHeight;">
            <caption>Resource Utilization</caption>
            <tbody>
"@

for ($i = 0; $i -lt $results.Count; $i++) {
    $current = $results[$i]
    if ($i -lt $results.Count - 1) {
        $next = $results[$i + 1]
    } else {
        $next = $null
    }

    # Format the date as DD.MM
    $formattedDate = [datetime]::ParseExact($current.Date, 'dd/MM/yyyy', $null).ToString('dd.MM')

    $htmlContent += @"
                <tr>
                    <th scope='row'>$formattedDate</th>
"@

    # Add CPU data point if data exists
    if ($cpuHasData) {
        $currentCpu = 0
        if ($current.CPU_Average -ne "No Data") {
            $currentCpu = [double]::Parse($current.CPU_Average.TrimEnd('%')) / 100
        }
        
        $nextCpu = $currentCpu
        if ($null -ne $next -and $next.CPU_Average -ne "No Data") {
            $nextCpu = [double]::Parse($next.CPU_Average.TrimEnd('%')) / 100
        }
        
        $htmlContent += @"
                    <td style='--start: $currentCpu; --end: $nextCpu;' data-tooltip='CPU: $($current.CPU_Average)'>
                        <span class='data'>$($current.CPU_Average)</span>
                    </td>
"@
    }
    
    # Add RAM data point if data exists
    if ($ramHasData) {
        $currentRam = 0
        if ($current.RAM_Average -ne "No Data") {
            $currentRam = [double]::Parse($current.RAM_Average.TrimEnd('%')) / 100
        }
        
        $nextRam = $currentRam
        if ($null -ne $next -and $next.RAM_Average -ne "No Data") {
            $nextRam = [double]::Parse($next.RAM_Average.TrimEnd('%')) / 100
        }
        
        $htmlContent += @"
                    <td style='--start: $currentRam; --end: $nextRam;' data-tooltip='RAM: $($current.RAM_Average)'>
                        <span class='data'>$($current.RAM_Average)</span>
                    </td>
"@
    }
    
    # Add disk data points for each disk that has data
    foreach ($disk in $diskFiles) {
        $driveLetter = $disk.DriveLetter
        if ($diskHasData[$driveLetter]) {
            $propName = "DISK$($driveLetter)_Average"
            
            $currentDisk = 0
            if ($current.$propName -ne "No Data") {
                $currentDisk = [double]::Parse($current.$propName.TrimEnd('%')) / 100
            }
            
            $nextDisk = $currentDisk
            if ($null -ne $next -and $next.$propName -ne "No Data") {
                $nextDisk = [double]::Parse($next.$propName.TrimEnd('%')) / 100
            }
            
            $htmlContent += @"
                    <td style='--start: $currentDisk; --end: $nextDisk;' data-tooltip='Disk $($driveLetter): $($current.$propName)'>
                        <span class='data'>$($current.$propName)</span>
                    </td>
"@
        }
    }
    
    # Add custom data point if data exists
    if ($customHasData) {
        $currentCustom = 0
        if ($current.Custom_Average -ne "No Data") {
            $currentCustom = [double]::Parse($current.Custom_Average.TrimEnd('%')) / 100
        }
        
        $nextCustom = $currentCustom
        if ($null -ne $next -and $next.Custom_Average -ne "No Data") {
            $nextCustom = [double]::Parse($next.Custom_Average.TrimEnd('%')) / 100
        }
        
        $htmlContent += @"
                    <td style='--start: $currentCustom; --end: $nextCustom;' data-tooltip='$($customDataLabel): $($current.Custom_Average)'>
                        <span class='data'>$($current.Custom_Average)</span>
                    </td>
"@
    }

    $htmlContent += @"
                </tr>
"@
}

$htmlContent += @"
            </tbody>
        </table>
    </div>
    
    <div class="legend-container">
        <ul class='charts-css legend legend-inline legend-rectangle'>
"@

if ($cpuHasData) {
    $htmlContent += "<li>CPU</li>`n"
}
if ($ramHasData) {
    $htmlContent += "<li>Memory</li>`n"
}

# Add legend entries for each disk
foreach ($disk in $diskFiles) {
    if ($diskHasData[$disk.DriveLetter]) {
        $sizePart = ""
        if ($disk.SizeGB -gt 0) {
            $sizePart = " ($($disk.SizeGB) GB)"
        }
        $htmlContent += "<li>Disk $($disk.DriveLetter)$sizePart</li>`n"
    }
}

if ($customHasData) {
    $htmlContent += "<li>$customDataLabel</li>`n"
}

$htmlContent += @"
        </ul>
    </div>

    <div class="report-date">Report Generation Date: $($nowDate.ToString('dd/MM/yyyy HH:mm:ss'))</div>
</body>
</html>
"@

#------------------------------------------------------------------------
# Export the HTML with a timestamp to charts\current\
#------------------------------------------------------------------------
$timestamp = $nowDate.ToString("yyyyMMdd_HHmmss")
$htmlFilePath = "$currentDir\chart_$timestamp.html"

$htmlContent | Out-File $htmlFilePath -Encoding utf8

Write-Host "Chart saved to: $htmlFilePath"

#------------------------------------------------------------------------
# Import the HTML into NinjaOne's Custom Field
#------------------------------------------------------------------------
$htmlContent | Ninja-Property-Set-Piped ltdrReport