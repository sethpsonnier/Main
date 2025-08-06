#========================================================================
# Resource-Tracking-4
# Purpose: Archive Manager - Processes old HTML files into monthly archives
# Schedule: Weekly (Friday EOD)
# Input: HTML files >30 days old from C:\temp2\charts\current\
# Output: Monthly JSON data and Chart.js visualizations in archive\
#========================================================================

#------------------------------------------------------------------------
# Script 4 - Archive Manager
# Purpose: Process HTML files older than 30 days, create monthly JSON data
#          and interactive Chart.js visualizations
# Schedule: Weekly (Friday EOD)
#------------------------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$BaseDirectory = "C:\temp2",
    
    [Parameter(Mandatory=$false)]
    [int]$AgeDays = 14,
    
    [Parameter(Mandatory=$false)]
    [switch]$VerboseLogging
)

#------------------------------------------------------------------------
# Initialize paths and variables
#------------------------------------------------------------------------
$currentDir = "$BaseDirectory\charts\current"
$archiveDir = "$BaseDirectory\charts\archive"
$logFile = "$BaseDirectory\archive_log.txt"

# Ensure archive directory exists
if (-not (Test-Path $archiveDir)) {
    Write-Host "Error: Archive directory not found: $archiveDir"
    exit 1
}

#------------------------------------------------------------------------
# Logging function
#------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    
    if ($VerboseLogging -or $Level -eq "ERROR") {
        Write-Host $logLine
    }
    
    Add-Content -Path $logFile -Value $logLine
}

#------------------------------------------------------------------------
# Function: Parse filename to extract date
#------------------------------------------------------------------------
function Get-DateFromFilename {
    param([string]$Filename)
    
    # Extract date from filename like "chart_20250605_143022.html"
    if ($Filename -match "chart_(\d{8})_\d{6}\.html") {
        try {
            $dateString = $matches[1]  # 20250605
            return [DateTime]::ParseExact($dateString, "yyyyMMdd", $null)
        }
        catch {
            Write-Log "Could not parse date from filename: $Filename" "ERROR"
            return $null
        }
    }
    
    Write-Log "Filename does not match expected pattern: $Filename" "ERROR"
    return $null
}

#------------------------------------------------------------------------
# Function: Extract data from HTML file
#------------------------------------------------------------------------
function Extract-DataFromHtml {
    param([string]$FilePath)
    
    try {
        $htmlContent = Get-Content -Path $FilePath -Raw
        
        # Parse the data table from HTML - look for the results table
        # This is a simplified parser - looks for data in tooltips
        $dataExtracted = @{}
        
        # Extract date from filename for this data point
        $filename = Split-Path $FilePath -Leaf
        $fileDate = Get-DateFromFilename -Filename $filename
        
        if ($null -eq $fileDate) {
            Write-Log "Could not extract date from $filename" "ERROR"
            return $null
        }
        
        $dataExtracted.Date = $fileDate.ToString("yyyy-MM-dd")
        
        # Extract CPU data - look for data-tooltip='CPU: XX.XX%'
        if ($htmlContent -match "data-tooltip='CPU:\s*([0-9.]+)%'") {
            $dataExtracted.CPU = [double]$matches[1]
        }
        
        # Extract RAM data - look for data-tooltip='RAM: XX.XX%'
        if ($htmlContent -match "data-tooltip='RAM:\s*([0-9.]+)%'") {
            $dataExtracted.RAM = [double]$matches[1]
        }
        
        # Extract disk data - look for data-tooltip='Disk X: XX.XX%'
        $diskMatches = [regex]::Matches($htmlContent, "data-tooltip='Disk\s+([A-Z]):\s*([0-9.]+)%'")
        foreach ($match in $diskMatches) {
            $driveLetter = $match.Groups[1].Value
            $usage = [double]$match.Groups[2].Value
            $dataExtracted."Disk_$driveLetter" = $usage
        }
        
        Write-Log "Extracted data from $filename - Date: $($dataExtracted.Date)" "INFO"
        return $dataExtracted
        
    }
    catch {
        Write-Log "Error extracting data from $FilePath : $_" "ERROR"
        return $null
    }
}

#------------------------------------------------------------------------
# Function: Load or create monthly JSON data
#------------------------------------------------------------------------
function Get-MonthlyData {
    param([string]$JsonPath)
    
    if (Test-Path $JsonPath) {
        try {
            $jsonContent = Get-Content -Path $JsonPath -Raw | ConvertFrom-Json
            Write-Log "Loaded existing data from $JsonPath" "INFO"
            
            # Convert to hashtable for easier manipulation
            $dataArray = @()
            if ($jsonContent.data) {
                $dataArray = $jsonContent.data
            }
            return $dataArray
        }
        catch {
            Write-Log "Error reading JSON file $JsonPath : $_" "ERROR"
            return @()
        }
    }
    else {
        Write-Log "Creating new monthly data file: $JsonPath" "INFO"
        return @()
    }
}

#------------------------------------------------------------------------
# Function: Save monthly JSON data
#------------------------------------------------------------------------
function Save-MonthlyData {
    param([string]$JsonPath, [array]$Data, [string]$Month)
    
    try {
        $jsonObject = @{
            month = $Month
            generated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            data = $Data | Sort-Object Date
        }
        
        $jsonContent = $jsonObject | ConvertTo-Json -Depth 10
        $jsonContent | Out-File -FilePath $JsonPath -Encoding utf8
        
        Write-Log "Saved monthly data to $JsonPath with $($Data.Count) data points" "INFO"
        return $true
    }
    catch {
        Write-Log "Error saving JSON data to $JsonPath : $_" "ERROR"
        return $false
    }
}

#------------------------------------------------------------------------
# Function: Generate Chart.js HTML
#------------------------------------------------------------------------
function Generate-ChartJs {
    param([string]$JsonPath, [string]$OutputPath, [string]$Month)
    
    try {
        # Load the data
        $jsonContent = Get-Content -Path $JsonPath -Raw | ConvertFrom-Json
        $data = $jsonContent.data
        
        if ($data.Count -eq 0) {
            Write-Log "No data to generate chart for $Month" "INFO"
            return $false
        }
        
        # Prepare data for Chart.js
        $dates = $data | ForEach-Object { $_.Date }
        $cpuData = $data | ForEach-Object { if ($_.CPU) { $_.CPU } else { $null } }
        $ramData = $data | ForEach-Object { if ($_.RAM) { $_.RAM } else { $null } }
        
        # Get all disk drive letters
        $diskDrives = @()
        foreach ($dataPoint in $data) {
            $dataPoint.PSObject.Properties | Where-Object { $_.Name -like "Disk_*" } | ForEach-Object {
                $driveLetter = $_.Name -replace "Disk_", ""
                if ($diskDrives -notcontains $driveLetter) {
                    $diskDrives += $driveLetter
                }
            }
        }
        
        # Generate Chart.js datasets
        $datasets = @()
        
        # CPU dataset
        if ($null -ne $cpuData) {
            $datasets += @{
                label = "CPU %"
                data = $cpuData
                borderColor = "#e74c3c"
                backgroundColor = "rgba(231, 76, 60, 0.1)"
                yAxisID = "y"
            }
        }
        
        # RAM dataset  
        if ($null -ne $ramData) {
            $datasets += @{
                label = "RAM %"
                data = $ramData
                borderColor = "#3498db"
                backgroundColor = "rgba(52, 152, 219, 0.1)"
                yAxisID = "y"
            }
        }
        
        # Disk datasets
        $colorIndex = 0
        $diskColors = @("#2ecc71", "#f39c12", "#9b59b6", "#1abc9c", "#34495e", "#e84393")
        
        foreach ($drive in $diskDrives) {
            $diskData = $data | ForEach-Object { 
                $diskProp = "Disk_$drive"
                if ($_.PSObject.Properties.Name -contains $diskProp) { 
                    $_.$diskProp 
                } else { 
                    $null 
                }
            }
            
            $color = $diskColors[$colorIndex % $diskColors.Count]
            $datasets += @{
                label = "Disk $drive %"
                data = $diskData
                borderColor = $color
                backgroundColor = ($color + "20")  # Add transparency
                yAxisID = "y"
            }
            $colorIndex++
        }

$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <title>Resource Utilization - $Month</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom"></script>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
            background-color: white;
        }
        .chart-container {
            position: relative;
            height: 500px;
            margin: 20px 0;
        }
        .chart-title {
            font-size: 24px;
            font-weight: bold;
            text-align: center;
            margin-bottom: 20px;
            color: #333;
        }
        .chart-info {
            text-align: center;
            color: #666;
            margin-bottom: 10px;
        }
        .controls {
            text-align: center;
            margin: 10px 0;
        }
        .controls button {
            margin: 0 5px;
            padding: 5px 10px;
            background-color: #3498db;
            color: white;
            border: none;
            border-radius: 3px;
            cursor: pointer;
        }
        .controls button:hover {
            background-color: #2980b9;
        }
    </style>
</head>
<body>
    <div class="chart-title">Resource Utilization - $Month</div>
    <div class="chart-info">Interactive Chart | Mouse wheel to zoom | Click and drag to pan</div>
    <div class="controls">
        <button onclick="resetZoom()">Reset Zoom</button>
        <button onclick="chart.resetZoom()">Reset Pan</button>
    </div>
    
    <div class="chart-container">
        <canvas id="resourceChart"></canvas>
    </div>
    
    <div class="chart-info">
        Generated: $($jsonContent.generated) | Data Points: $($data.Count)
    </div>

    <script>
        const ctx = document.getElementById('resourceChart').getContext('2d');
        
        const dates = $(($dates | ConvertTo-Json));
        const datasets = $(($datasets | ConvertTo-Json));
        
        const chart = new Chart(ctx, {
            type: 'line',
            data: {
                labels: dates,
                datasets: datasets
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: {
                    mode: 'index',
                    intersect: false,
                },
                plugins: {
                    title: {
                        display: true,
                        text: 'System Resource Utilization Over Time'
                    },
                    legend: {
                        display: true,
                        position: 'top'
                    },
                    zoom: {
                        zoom: {
                            wheel: {
                                enabled: true,
                            },
                            pinch: {
                                enabled: true
                            },
                            mode: 'x',
                        },
                        pan: {
                            enabled: true,
                            mode: 'x',
                        }
                    }
                },
                scales: {
                    x: {
                        display: true,
                        title: {
                            display: true,
                            text: 'Date'
                        }
                    },
                    y: {
                        type: 'linear',
                        display: true,
                        position: 'left',
                        title: {
                            display: true,
                            text: 'Usage Percentage (%)'
                        },
                        min: 0,
                        max: 100
                    }
                }
            },
            plugins: [ChartZoom]
        });
        
        function resetZoom() {
            chart.resetZoom();
        }
    </script>
</body>
</html>
"@

        $htmlContent | Out-File -FilePath $OutputPath -Encoding utf8
        Write-Log "Generated Chart.js visualization: $OutputPath" "INFO"
        return $true
        
    }
    catch {
        Write-Log "Error generating Chart.js for $Month : $_" "ERROR"
        return $false
    }
}

#------------------------------------------------------------------------
# Main Processing Logic
#------------------------------------------------------------------------
Write-Log "Starting Archive Manager - Processing files older than $AgeDays days" "INFO"

# Find HTML files older than specified age
$cutoffDate = (Get-Date).AddDays(-$AgeDays)
$oldFiles = Get-ChildItem -Path $currentDir -Filter "chart_*.html" -File | Where-Object {
    $fileDate = Get-DateFromFilename -Filename $_.Name
    $null -ne $fileDate -and $fileDate -lt $cutoffDate
}

if ($oldFiles.Count -eq 0) {
    Write-Log "No files found older than $AgeDays days" "INFO"
    exit 0
}

Write-Log "Found $($oldFiles.Count) files to process" "INFO"

# Group files by year/month
$fileGroups = @{}
foreach ($file in $oldFiles) {
    $fileDate = Get-DateFromFilename -Filename $file.Name
    if ($null -ne $fileDate) {
        $yearMonth = $fileDate.ToString("yyyy-MM")
        
        if (-not $fileGroups.ContainsKey($yearMonth)) {
            $fileGroups[$yearMonth] = @()
        }
        $fileGroups[$yearMonth] += $file
    }
}

# Process each month group
foreach ($monthKey in $fileGroups.Keys) {
    Write-Log "Processing month: $monthKey ($($fileGroups[$monthKey].Count) files)" "INFO"
    
    # Create year/month directory if needed
    $year = $monthKey.Split('-')[0]
    $month = $monthKey.Split('-')[1]
    $monthDir = "$archiveDir\$year\$month"
    
    if (-not (Test-Path $monthDir)) {
        New-Item -ItemType Directory -Path $monthDir -Force | Out-Null
        Write-Log "Created directory: $monthDir" "INFO"
    }
    
    # Paths for this month
    $jsonPath = "$monthDir\data.json"
    $chartPath = "$monthDir\chart.html"
    
    # Load existing monthly data
    $monthlyData = Get-MonthlyData -JsonPath $jsonPath
    
    # Move files to archive FIRST to avoid reprocessing
    $movedFiles = @()
    $moveErrors = 0
    
    foreach ($file in $fileGroups[$monthKey]) {
        try {
            $destination = "$monthDir\$($file.Name)"
            if (Test-Path $destination) {
                Remove-Item $destination -Force
            }
            Move-Item -Path $file.FullName -Destination $destination -ErrorAction Stop
            $movedFiles += Get-Item $destination
            Write-Log "Moved $($file.Name) to archive" "INFO"
        }
        catch {
            Write-Log "Failed to move $($file.Name): $_" "ERROR"
            $moveErrors++
        }
    }
    
    if ($moveErrors -gt 0) {
        Write-Log "Some files failed to move for $monthKey, continuing with successfully moved files" "ERROR"
    }
    
    # Extract data from moved files
    $newDataPoints = @()
    
    foreach ($file in $movedFiles) {
        $extractedData = Extract-DataFromHtml -FilePath $file.FullName
        
        if ($null -ne $extractedData) {
            # Check if we already have this date
            $existingData = $monthlyData | Where-Object { $_.Date -eq $extractedData.Date }
            
            if ($null -eq $existingData) {
                $newDataPoints += $extractedData
                Write-Log "New data point added for $($extractedData.Date)" "INFO"
            }
            else {
                Write-Log "Data for $($extractedData.Date) already exists, skipping data extraction" "INFO"
            }
        }
        else {
            Write-Log "Failed to extract data from $($file.Name)" "ERROR"
        }
    }
    
    # Append new data points
    if ($newDataPoints.Count -gt 0) {
        $monthlyData += $newDataPoints
        Write-Log "Added $($newDataPoints.Count) new data points for $monthKey" "INFO"
    }
    
    # Save updated JSON data
    if (-not (Save-MonthlyData -JsonPath $jsonPath -Data $monthlyData -Month $monthKey)) {
        Write-Log "Failed to save data for $monthKey" "ERROR"
        continue
    }
    
    # Generate Chart.js visualization
    if (-not (Generate-ChartJs -JsonPath $jsonPath -OutputPath $chartPath -Month $monthKey)) {
        Write-Log "Failed to generate chart for $monthKey" "ERROR"
        # Continue anyway - data is saved
    }
    
    if ($moveErrors -gt 0) {
        Write-Log "Completed $monthKey with $moveErrors move errors" "ERROR"
    }
    else {
        Write-Log "Successfully completed processing for $monthKey" "INFO"
    }
}

Write-Log "Archive Manager completed" "INFO"