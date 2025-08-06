
# Version: 1.2.2


param(
    [string]$InputPath = "",  # Auto-detect if not specified
    
    [string[]]$YearFamiliesToAnalyze = @(),
    
    [ValidateScript({Test-Path (Split-Path $_ -Parent) -PathType Container})]
    [string]$OutputPath = "C:\temp\VCPP\VisualCppDependencyReport.json",
    
    [bool]$AutoDownloadTools = $true,  # Automatically download Dependencies.exe if not found
    
    [switch]$Help
)

#region Setup and Initialization

# Create centralized directory structure
$centralDir = "C:\temp\VCPP"
$logsDir = Join-Path $centralDir "logs"

$directories = @($centralDir, $logsDir)
foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Set up logging
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logsDir "vc-dependencies-$timestamp.log"

#endregion

#region Helper Functions

# Simple help function
function Show-Help {
    Write-Host ""
    Write-Host "Visual C++ Dependency Analysis Tool - Help (v1.2.2-ENHANCED)" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "DESCRIPTION:" -ForegroundColor Cyan
    Write-Host "  Analyzes Visual C++ redistributable dependencies and provides removal recommendations."
    Write-Host ""
    
    Write-Host "PARAMETERS:" -ForegroundColor Cyan
    Write-Host "  -InputPath             Path to inventory JSON file [Default: Auto-detect latest]"
    Write-Host "  -YearFamiliesToAnalyze Specific year families to analyze [Default: All detected]"
    Write-Host "  -OutputPath            Output path for dependency report"
    Write-Host "  -AutoDownloadTools     Auto-download Dependencies.exe for better accuracy [Default: true]"
    Write-Host "  -Help                  Show this help"
    Write-Host ""
    
    Write-Host "EXAMPLES:" -ForegroundColor Cyan
    Write-Host "  .\Get-VisualCppDependencies.ps1"
    Write-Host "  .\Get-VisualCppDependencies.ps1 -YearFamiliesToAnalyze @('2005', '2008', '2010')"
    Write-Host ""
}

# Function to write to both console and log
function Write-LogMessage {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = "White"
    )
    
    $logTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$logTimestamp [$Level] $Message"
    
    # Write to console with color
    Write-Host $Message -ForegroundColor $Color
    
    # Write to log file
    try {
        $logEntry | Out-File -FilePath $logFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Silently continue if logging fails
    }
}

#endregion

#region Tool Installation Functions

# Function to download Dependencies.exe (simplified)
function Install-DependenciesExe {
    param(
        [string]$DownloadPath,
        [string]$TempPath
    )
    
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        $releasesUrl = "https://api.github.com/repos/lucasg/Dependencies/releases/latest"
        $headers = @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            'Accept' = 'application/vnd.github.v3+json'
        }
        
        $releaseInfo = Invoke-RestMethod -Uri $releasesUrl -Headers $headers -TimeoutSec 30
        $zipAsset = $releaseInfo.assets | Where-Object { $_.name -like "Dependencies_*_Release.zip" } | Select-Object -First 1
        
        if (-not $zipAsset) {
            throw "Could not find Dependencies release ZIP file"
        }
        
        $downloadUrl = $zipAsset.browser_download_url
        $fileName = $zipAsset.name
        $zipPath = Join-Path $TempPath $fileName
        
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -Headers $headers -UseBasicParsing -TimeoutSec 300
        
        if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -eq 0) {
            throw "Download failed"
        }
        
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        $dependenciesEntry = $zip.Entries | Where-Object { $_.Name -eq "Dependencies.exe" } | Select-Object -First 1
        
        if (-not $dependenciesEntry) {
            $zip.Dispose()
            throw "Dependencies.exe not found in ZIP archive"
        }
        
        $targetPath = Join-Path $DownloadPath "Dependencies.exe"
        
        if (Test-Path $targetPath) {
            Remove-Item $targetPath -Force -ErrorAction SilentlyContinue
        }
        
        $fileStream = [System.IO.File]::Create($targetPath)
        $entryStream = $dependenciesEntry.Open()
        $entryStream.CopyTo($fileStream)
        $fileStream.Close()
        $entryStream.Close()
        $zip.Dispose()
        
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $targetPath) {
            return $targetPath
        } else {
            throw "Extraction failed"
        }
        
    } catch {
        return $null
    }
}

# Function to check for modern dependency analysis tools
function Test-DependencyAnalysisTools {
    param(
        [bool]$AutoDownload = $true,
        [string]$DownloadPath = "",
        [string]$TempPath = ""
    )
    
    $tools = @{
        Dependencies = @{
            Found = $false
            Path = ""
            Downloaded = $false
        }
        DUMPBIN = @{
            Found = $false
            Path = ""
        }
    }
    
    # Check for Dependencies.exe
    $dependenciesLocations = @(
        "Dependencies.exe",
        ".\Dependencies.exe",
        (Join-Path $DownloadPath "Dependencies.exe")
    )
    
    # Add PATH locations
    if ($env:PATH) {
        $pathDirs = $env:PATH.Split(';') | Where-Object { $_ -ne "" }
        foreach ($dir in $pathDirs) {
            $dependenciesLocations += Join-Path $dir "Dependencies.exe"
        }
    }
    
    foreach ($location in $dependenciesLocations) {
        try {
            if (Test-Path $location -ErrorAction SilentlyContinue) {
                $tools['Dependencies']['Found'] = $true
                $tools['Dependencies']['Path'] = (Resolve-Path $location).Path
                break
            }
        } catch { }
    }
    
    # If not found and auto-download is enabled, try to download it
    if (-not $tools['Dependencies']['Found'] -and $AutoDownload -and $DownloadPath -ne "" -and $TempPath -ne "") {
        $downloadedPath = Install-DependenciesExe -DownloadPath $DownloadPath -TempPath $TempPath
        if ($downloadedPath -and (Test-Path $downloadedPath)) {
            $tools['Dependencies']['Found'] = $true
            $tools['Dependencies']['Path'] = $downloadedPath
            $tools['Dependencies']['Downloaded'] = $true
        }
    }
    
    # Check for DUMPBIN
    try {
        $result = Get-Command "dumpbin.exe" -ErrorAction SilentlyContinue
        if ($result) {
            $tools['DUMPBIN']['Found'] = $true
            $tools['DUMPBIN']['Path'] = $result.Source
        }
    } catch { }
    
    return $tools
}

#endregion

#region Inventory Functions

# Function to auto-detect the most recent inventory file
function Find-LatestInventoryFile {
    param([string]$CentralDir)
    
    $searchPatterns = @(
        "VisualCppInventory-After-*.json",
        "VisualCppInventory-Before-*.json",
        "VisualCppInventory.json"
    )
    
    foreach ($pattern in $searchPatterns) {
        $files = Get-ChildItem -Path $CentralDir -Filter $pattern -ErrorAction SilentlyContinue | 
                 Sort-Object LastWriteTime -Descending
        
        if ($files.Count -gt 0) {
            return $files[0].FullName
        }
    }
    
    return $null
}

# Function to validate inventory file structure
function Test-InventoryFile {
    param([PSCustomObject]$Inventory)
    
    $requiredProperties = @('ComputerName', 'VisualCppRedistributables')
    $missingProperties = @()
    
    foreach ($prop in $requiredProperties) {
        if (-not $Inventory.PSObject.Properties[$prop]) {
            $missingProperties += $prop
        }
    }
    
    if ($missingProperties.Count -gt 0) {
        throw "Invalid inventory file. Missing required properties: $($missingProperties -join ', ')"
    }
    
    if (-not $Inventory.VisualCppRedistributables -or $Inventory.VisualCppRedistributables.Count -eq 0) {
        throw "Invalid inventory file. No Visual C++ redistributables found in inventory."
    }
    
    return $true
}

#endregion

#region VC++ Redistributable Removal Functions

# Function to get VC++ redistributable removal information
function Get-VCRedistRemovalInfo {
    param(
        [array]$YearFamiliesToRemove,
        [array]$InstalledRedistributables
    )
    
    $removalInfo = @()
    
    foreach ($yearFamily in $YearFamiliesToRemove) {
        $matchingRedists = $InstalledRedistributables | Where-Object { $_.YearFamily -eq $yearFamily }
        
        foreach ($redist in $matchingRedists) {
            $sizeMB = if ($redist.EstimatedSize) { [math]::Round($redist.EstimatedSize / 1024, 1) } else { 0 }
            
            $uninstallCommand = ""
            
            if ($redist.QuietUninstallString) {
                $uninstallCommand = $redist.QuietUninstallString
            } elseif ($redist.UninstallString) {
                $uninstallString = $redist.UninstallString
                if ($uninstallString -like "*MsiExec.exe*") {
                    if ($uninstallString -match "MsiExec\.exe\s+/I\{([^}]+)\}") {
                        $productCode = $matches[1]
                        $uninstallCommand = "MsiExec.exe /X{$productCode} /quiet /norestart"
                    } else {
                        $uninstallCommand = "$uninstallString /quiet /norestart"
                    }
                } else {
                    $uninstallCommand = "$uninstallString /S"
                }
            }
            
            if ([string]::IsNullOrEmpty($uninstallCommand)) {
                $uninstallCommand = "# Manual removal required - no uninstall string found"
            }
            
            $removalInfo += [PSCustomObject]@{
                YearFamily = $yearFamily
                Name = $redist.Name
                Version = $redist.Version
                Architecture = $redist.Architecture
                PackageType = $redist.PackageType
                UninstallCommand = $uninstallCommand
                SizeMB = $sizeMB
                RegistryKey = $redist.RegistryKey
            }
        }
    }
    
    return $removalInfo
}

#endregion

#region Dependency Analysis Functions

function Test-VCYearFamilyDependency {
    param (
        [string]$YearFamily,
        [PSCustomObject]$Inventory
    )
    
    $dependencies = @{
        "RunningProcesses" = @()
        "ApplicationDependencies" = @()
        "VulnerabilityRisk" = ""
        "ConfidenceLevel" = "Unknown"
    }
    
    # Enhanced process analysis
    if ($Inventory.RunningProcesses -and $Inventory.RunningProcesses.Count -gt 0) {
        foreach ($process in $Inventory.RunningProcesses) {
            if ($process.YearFamiliesUsed -and $YearFamily -in $process.YearFamiliesUsed) {
                $dependencies.RunningProcesses += $process
            }
        }
    }
    
    # Calculate confidence level
    $confidenceLevel = if ($dependencies.RunningProcesses.Count -gt 0) { "High" } else { "Low" }
    $dependencies.ConfidenceLevel = $confidenceLevel
    
    # Vulnerability risk assessment
    $vulnerabilityRisk = switch ($YearFamily) {
        "2005" { "HIGH - Multiple known CVEs, no longer supported" }
        "2008" { "HIGH - Multiple known CVEs, no longer supported" }
        "2010" { "MEDIUM-HIGH - Some known CVEs, extended support ended" }
        "2012" { "MEDIUM - Limited support, some vulnerabilities" }
        "2013" { "MEDIUM - Mainstream support ended" }
        "2015-2022" { "LOW - Current supported version" }
        default { "UNKNOWN" }
    }
    
    $dependencies.VulnerabilityRisk = $vulnerabilityRisk
    
    # Calculate active dependencies
    $activeDependencies = $dependencies.RunningProcesses.Count
    $totalDependencies = $activeDependencies + $dependencies.ApplicationDependencies.Count
    
    # Enhanced decision logic
    $isNeeded = $false
    $reason = ""
    
    if ($activeDependencies -gt 0) {
        $isNeeded = $true
        $reason = "$activeDependencies active process(es) currently using this version"
    } elseif ($YearFamily -eq "2015-2022") {
        $isNeeded = $true
        $reason = "Current version family - should not be removed"
    } else {
        $isNeeded = $false
        $reason = "No dependencies detected"
    }
    
    return @{
        YearFamily = $YearFamily
        IsNeeded = $isNeeded
        Reason = $reason
        Dependencies = $dependencies
        ActiveDependencies = $activeDependencies
        TotalDependencies = $totalDependencies
        ConfidenceLevel = $confidenceLevel
        VulnerabilityRisk = $vulnerabilityRisk
    }
}

#endregion

#region Main Execution

# Check if help was requested
if ($Help) {
    Show-Help
    exit 0
}

Write-LogMessage "VC++ Dependency Analysis v1.2.2 - $env:COMPUTERNAME" -Color Green

# Check for and potentially download analysis tools
$tempToolsDir = Join-Path $centralDir "temp"
if (-not (Test-Path $tempToolsDir)) {
    New-Item -ItemType Directory -Path $tempToolsDir -Force | Out-Null
}

$analysisTools = Test-DependencyAnalysisTools -AutoDownload $AutoDownloadTools -DownloadPath $centralDir -TempPath $tempToolsDir

if ($analysisTools['Dependencies']['Found']) {
    $downloadedText = if ($analysisTools['Dependencies']['Downloaded']) { " (downloaded)" } else { "" }
    Write-LogMessage "Dependencies.exe: Available$downloadedText" -Color Green
} else {
    Write-LogMessage "Dependencies.exe: Not available" -Color Yellow
}

# Load and validate inventory
try {
    # Auto-detect inventory file if not specified
    if ([string]::IsNullOrEmpty($InputPath)) {
        $InputPath = Find-LatestInventoryFile -CentralDir $centralDir
        
        if ([string]::IsNullOrEmpty($InputPath)) {
            throw "No inventory files found in $centralDir. Please run Manage-VisualCpp.ps1 first."
        }
    } else {
        if (-not (Test-Path $InputPath)) {
            throw "Specified inventory file not found: $InputPath"
        }
    }
    
    $inventory = Get-Content -Path $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-InventoryFile -Inventory $inventory | Out-Null
    
} catch {
    Write-LogMessage "Failed to load inventory: $_" -Level "ERROR" -Color Red
    exit 1
}

# Determine year families to analyze
if ($YearFamiliesToAnalyze.Count -eq 0) {
    $yearFamilies = $inventory.VisualCppRedistributables | ForEach-Object {
        $_.YearFamily
    } | Where-Object { $_ -ne "Unknown" } | Sort-Object -Unique
} else {
    $yearFamilies = $YearFamiliesToAnalyze | Sort-Object
}

Write-LogMessage "Analyzing: $($yearFamilies -join ', ')" -Color Cyan

# Initialize dependency report
$report = @{
    "ComputerName" = $inventory.ComputerName
    "AnalysisDate" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "YearFamiliesAnalyzed" = $yearFamilies
    "DependencyResults" = @()
    "SafeToRemove" = @()
    "NeededVersions" = @()
    "RedistributableRemovalInfo" = @()
    "TotalRemovalSizeMB" = 0
    "Summary" = @{}
}

# Analyze dependencies
foreach ($yearFamily in $yearFamilies) {
    $result = Test-VCYearFamilyDependency -YearFamily $yearFamily -Inventory $inventory
    
    if ($result) {
        $report.DependencyResults += $result
        
        if ($result.IsNeeded) {
            $report.NeededVersions += $yearFamily
        } else {
            if ($yearFamily -eq "2015-2022") {
                $report.NeededVersions += $yearFamily
            } else {
                $report.SafeToRemove += $yearFamily
            }
        }
    }
}

# Generate redistributable removal information for safe-to-remove versions
if ($report.SafeToRemove.Count -gt 0) {
    $report.RedistributableRemovalInfo = Get-VCRedistRemovalInfo -YearFamiliesToRemove $report.SafeToRemove -InstalledRedistributables $inventory.VisualCppRedistributables
    
    if ($report.RedistributableRemovalInfo.Count -gt 0) {
        $report.TotalRemovalSizeMB = ($report.RedistributableRemovalInfo | Measure-Object -Property SizeMB -Sum).Sum
    }
}

# Create summary
$report.Summary = @{
    "YearFamiliesAnalyzed" = $yearFamilies.Count
    "SafeToRemoveCount" = $report.SafeToRemove.Count
    "NeededVersionsCount" = $report.NeededVersions.Count
    "RedistributableInstallationsCount" = $report.RedistributableRemovalInfo.Count
    "TotalRemovalSizeMB" = $report.TotalRemovalSizeMB
}

# Save report
try {
    $reportForJson = @{
        "ComputerName" = $report.ComputerName
        "AnalysisDate" = $report.AnalysisDate
        "YearFamiliesAnalyzed" = $report.YearFamiliesAnalyzed
        "SafeToRemove" = $report.SafeToRemove
        "NeededVersions" = $report.NeededVersions
        "TotalRemovalSizeMB" = $report.TotalRemovalSizeMB
        "Summary" = $report.Summary
        "DependencyResults" = @()
        "RedistributableRemovalInfo" = $report.RedistributableRemovalInfo
    }
    
    foreach ($result in $report.DependencyResults) {
        $serializableResult = [PSCustomObject]@{
            "YearFamily" = $result.YearFamily
            "IsNeeded" = $result.IsNeeded
            "Reason" = $result.Reason
            "ActiveDependencies" = $result.ActiveDependencies
            "TotalDependencies" = $result.TotalDependencies
            "ConfidenceLevel" = $result.ConfidenceLevel
            "VulnerabilityRisk" = $result.VulnerabilityRisk
        }
        $reportForJson.DependencyResults += $serializableResult
    }
    
    $jsonOutput = $reportForJson | ConvertTo-Json -Depth 10 -Compress:$false
    $jsonOutput | Out-File -FilePath $OutputPath -Force -Encoding UTF8
    
} catch {
    Write-LogMessage "Error saving report: $_" -Level "ERROR" -Color Red
    exit 1
}

# Display results (ENHANCED VERSION)
Write-LogMessage ""
Write-LogMessage "Analysis Results:" -Color Green

foreach ($result in $report.DependencyResults | Sort-Object { 
    switch ($_.VulnerabilityRisk.Split(' ')[0]) {
        "HIGH" { 1 }
        "MEDIUM-HIGH" { 2 }
        "MEDIUM" { 3 }
        "LOW" { 4 }
        default { 5 }
    }
}) {
    $riskLevel = $result.VulnerabilityRisk.Split(' ')[0]
    $color = switch ($riskLevel) {
        "HIGH" { "Red" }
        "MEDIUM-HIGH" { "Magenta" }
        "MEDIUM" { "Yellow" }
        "LOW" { "Green" }
        default { "White" }
    }
    $status = if ($result.IsNeeded) { "NEEDED" } else { "SAFE TO REMOVE" }
    Write-LogMessage "  $($result.YearFamily): $riskLevel risk - $status" -Color $color
    
    # NEW: Show processes using this version
    if ($result.Dependencies.RunningProcesses -and $result.Dependencies.RunningProcesses.Count -gt 0) {
        Write-LogMessage "    └─ Used by $($result.Dependencies.RunningProcesses.Count) process(es):" -Color DarkGray
        
        # Group processes by name and show counts
        $processGroups = $result.Dependencies.RunningProcesses | Group-Object ProcessName | Sort-Object Count -Descending
        
        foreach ($group in $processGroups) {
            $processName = $group.Name
            $count = $group.Count
            $processes = $group.Group
            
            if ($count -eq 1) {
                $process = $processes[0]
                $pidInfo = if ($process.Id) { " (PID: $($process.Id))" } else { "" }
                Write-LogMessage "       • $processName$pidInfo" -Color DarkGray
            } else {
                # Multiple instances of same process
                Write-LogMessage "       • $processName ($count instances)" -Color DarkGray
                foreach ($process in $processes | Select-Object -First 3) {  # Show first 3 PIDs
                    $pidInfo = if ($process.Id) { " PID: $($process.Id)" } else { " PID: Unknown" }
                    Write-LogMessage "         └─$pidInfo" -Color DarkGray
                }
                if ($count -gt 3) {
                    Write-LogMessage "         └─ ... and $($count - 3) more" -Color DarkGray
                }
            }
        }
    } elseif ($result.IsNeeded -and $result.YearFamily -eq "2015-2022") {
        Write-LogMessage "    └─ Current version family - should not be removed" -Color DarkGray
    } else {
        Write-LogMessage "    └─ No active dependencies detected" -Color DarkGray
    }
    
    # Add confidence level indicator
    if ($result.ConfidenceLevel) {
        $confidenceColor = switch ($result.ConfidenceLevel) {
            "High" { "Green" }
            "Medium" { "Yellow" }
            "Low" { "Red" }
            default { "White" }
        }
        Write-LogMessage "    └─ Confidence: $($result.ConfidenceLevel)" -Color $confidenceColor
    }
}

# Show removal commands if any (FIXED LOGIC)
if ($report.RedistributableRemovalInfo.Count -gt 0 -and $report.SafeToRemove.Count -gt 0) {
    Write-LogMessage ""
    Write-LogMessage "VULNERABILITY CLEANUP COMMANDS ($([math]::Round($report.TotalRemovalSizeMB, 1)) MB freed):" -Color Red
    Write-LogMessage ""
    
    # Group by priority (simplified - no complex staging)
    $highPriorityRemovals = $report.RedistributableRemovalInfo | Where-Object { $_.YearFamily -in @("2005", "2008") }
    $mediumPriorityRemovals = $report.RedistributableRemovalInfo | Where-Object { $_.YearFamily -in @("2010", "2012") }
    $lowPriorityRemovals = $report.RedistributableRemovalInfo | Where-Object { $_.YearFamily -in @("2013") }
    
    if ($highPriorityRemovals.Count -gt 0) {
        Write-LogMessage "HIGH PRIORITY (Remove First):" -Color Red
        foreach ($item in $highPriorityRemovals | Sort-Object YearFamily, Architecture) {
            Write-LogMessage "# $($item.Name) - $($item.SizeMB) MB" -Color DarkGray
            Write-LogMessage "$($item.UninstallCommand)" -Color Red
            Write-LogMessage ""
        }
    }
    
    if ($mediumPriorityRemovals.Count -gt 0) {
        Write-LogMessage "MEDIUM PRIORITY (Remove After High Priority):" -Color Yellow
        foreach ($item in $mediumPriorityRemovals | Sort-Object YearFamily, Architecture) {
            Write-LogMessage "# $($item.Name) - $($item.SizeMB) MB" -Color DarkGray
            Write-LogMessage "$($item.UninstallCommand)" -Color Yellow
            Write-LogMessage ""
        }
    }
    
    if ($lowPriorityRemovals.Count -gt 0) {
        Write-LogMessage "LOW PRIORITY (Remove Last):" -Color Cyan
        foreach ($item in $lowPriorityRemovals | Sort-Object YearFamily, Architecture) {
            Write-LogMessage "# $($item.Name) - $($item.SizeMB) MB" -Color DarkGray
            Write-LogMessage "$($item.UninstallCommand)" -Color Cyan
            Write-LogMessage ""
        }
    }
    
    $highRiskCount = ($report.DependencyResults | Where-Object { $_.VulnerabilityRisk -match "HIGH" -and -not $_.IsNeeded }).Count
    $mediumRiskCount = ($report.DependencyResults | Where-Object { $_.VulnerabilityRisk -match "MEDIUM" -and -not $_.IsNeeded }).Count
    
    Write-LogMessage "Impact: Fixes $highRiskCount HIGH risk + $mediumRiskCount MEDIUM risk vulnerabilities" -Color Green
    
} else {
    Write-LogMessage ""
    Write-LogMessage "No vulnerable versions found for removal" -Color Green
    Write-LogMessage "All installed VC++ versions appear to be actively needed or are current versions." -Color Yellow
}

# Show versions that cannot be removed
$neededVulnerableVersions = $report.DependencyResults | Where-Object { $_.IsNeeded -and $_.YearFamily -ne "2015-2022" }
if ($neededVulnerableVersions.Count -gt 0) {
    Write-LogMessage ""
    Write-LogMessage "CANNOT REMOVE (Active Dependencies):" -Color Red
    foreach ($version in $neededVulnerableVersions) {
        Write-LogMessage "  VC++ $($version.YearFamily) - $($version.Reason)" -Color Red
        
        # Show which processes are preventing removal
        if ($version.Dependencies.RunningProcesses -and $version.Dependencies.RunningProcesses.Count -gt 0) {
            $processNames = ($version.Dependencies.RunningProcesses | Select-Object -ExpandProperty ProcessName | Sort-Object -Unique) -join ", "
            Write-LogMessage "    └─ Required by: $processNames" -Color Red
        }
    }
}

Write-LogMessage ""
Write-LogMessage "Analysis completed successfully!" -Color Green

#endregion