# Manage-VisualCpp.ps1
# Version: 1.2.1-PS7


param(
    [ValidateSet("Basic", "Standard", "Deep")]
    [string]$ScanDepth = "Standard",

    [bool]$SkipUpdate = $true, 
    
    [bool]$InstallLatest = $false, 
    
    [ValidateSet("x86", "x64", "ARM64", "All")]
    [string]$Architecture = "All", 
    
    [bool]$AutoDownloadTools = $true, 
    
    [switch]$Help
)


#region Setup and Initialization

# Create centralized directory structure
$centralDir = "C:\temp\VCPP"
$logsDir = Join-Path $centralDir "logs"
$backupDir = Join-Path $centralDir "backup"
$tempDir = Join-Path $centralDir "temp"

$directories = @($centralDir, $logsDir, $backupDir, $tempDir)
foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Check for Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

# Set up logging
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logsDir "manage-vcpp-$timestamp.log"

#endregion

#region Helper Functions

# Simple help function
function Show-Help {
    Write-Host ""
    Write-Host "Visual C++ Redistributable Management Tool - Help (v1.2.1-PS7)" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "FLAGS:" -ForegroundColor Cyan
    Write-Host "  -ScanDepth           Scan depth (Basic, Standard, Deep) [Default: Standard]"
    Write-Host "  -SkipUpdate          Only scan, don't install anything [Default: true]"
    Write-Host "  -InstallLatest       Install latest VC++ redistributables [Default: false]"
    Write-Host "  -Architecture        Target architecture (x86, x64, ARM64, All) [Default: All]"
    Write-Host "  -AutoDownloadTools   Auto-download Dependencies.exe for better accuracy [Default: true]"
    Write-Host "  -Help                Show this help"
    Write-Host ""
    
    Write-Host "EXAMPLES:" -ForegroundColor Cyan
    Write-Host "  .\Manage-VisualCpp.ps1"
    Write-Host "  .\Manage-VisualCpp.ps1 -ScanDepth 'Deep'"
    Write-Host "  .\Manage-VisualCpp.ps1 -InstallLatest `$true -SkipUpdate `$false"
    Write-Host "  .\Manage-VisualCpp.ps1 -Architecture 'x64'"
    Write-Host ""
    
    Write-Host "REQUIREMENTS:" -ForegroundColor Yellow
    Write-Host "  PowerShell 7+ (Current: $($PSVersionTable.PSVersion))" -ForegroundColor Green
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

# Function to get Visual C++ redistributables from registry
function Get-VisualCppRedistributables {
    try {
        $redistributables = @()
        
        # Check both 32-bit and 64-bit registry locations
        $uninstallKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        
        foreach ($keyPath in $uninstallKeys) {
            try {
                Get-ItemProperty $keyPath -ErrorAction SilentlyContinue | 
                    Where-Object { 
                        $_.DisplayName -match "Microsoft Visual C\+\+.*Redistributable|Visual C\+\+.*Runtime" -and
                        $null -ne $_.DisplayName -and
                        $null -ne $_.DisplayVersion
                    } | 
                    ForEach-Object {
                        # Parse architecture and year from display name
                        $displayName = $_.DisplayName
                        $version = $_.DisplayVersion
                        
                        # Determine architecture - improved detection
                        $arch = "Unknown"
                        if ($displayName -match "\(x64\)") { 
                            $arch = "x64" 
                        } elseif ($displayName -match "\(x86\)") { 
                            $arch = "x86" 
                        } elseif ($displayName -match "\(ARM64\)") { 
                            $arch = "ARM64" 
                        } elseif ($keyPath -like "*WOW6432Node*") {
                            $arch = "x86"
                        } elseif ([Environment]::Is64BitOperatingSystem -and $keyPath -notlike "*WOW6432Node*") {
                            $arch = "x64"
                        }
                        
                        # Determine year/version family
                        $yearFamily = "Unknown"
                        if ($displayName -match "2022") { $yearFamily = "2015-2022" }
                        elseif ($displayName -match "2019") { $yearFamily = "2015-2022" }
                        elseif ($displayName -match "2017") { $yearFamily = "2015-2022" }
                        elseif ($displayName -match "2015") { $yearFamily = "2015-2022" }
                        elseif ($displayName -match "2013") { $yearFamily = "2013" }
                        elseif ($displayName -match "2012") { $yearFamily = "2012" }
                        elseif ($displayName -match "2010") { $yearFamily = "2010" }
                        elseif ($displayName -match "2008") { $yearFamily = "2008" }
                        elseif ($displayName -match "2005") { $yearFamily = "2005" }
                        
                        # Determine if it's minimum, additional, or runtime
                        $packageType = "Runtime"
                        if ($displayName -match "Minimum") { $packageType = "Minimum" }
                        elseif ($displayName -match "Additional") { $packageType = "Additional" }
                        
                        $redistributables += [PSCustomObject]@{
                            Name = $displayName
                            Version = $version
                            Architecture = $arch
                            YearFamily = $yearFamily
                            PackageType = $packageType
                            Publisher = $_.Publisher
                            InstallDate = $_.InstallDate
                            UninstallString = $_.UninstallString
                            QuietUninstallString = $_.QuietUninstallString
                            EstimatedSize = $_.EstimatedSize
                            RegistryKey = $_.PSPath
                        }
                    }
            } catch {
                # Silently continue
            }
        }
        
        # Remove duplicates and sort
        $uniqueRedistributables = $redistributables | 
            Group-Object Name, Version, Architecture | 
            ForEach-Object { $_.Group | Select-Object -First 1 } |
            Sort-Object YearFamily, Architecture, PackageType
        
        Write-LogMessage "Found $($uniqueRedistributables.Count) Visual C++ redistributable(s)" -Color Green
        return $uniqueRedistributables
        
    } catch {
        return @()
    }
}

# Function to get running processes using VC++ runtime DLLs
function Get-ProcessesUsingVCRuntime {
    try {
        Write-LogMessage "Scanning running processes for VC++ dependencies (this may take a moment)..." -Color DarkGray
        $vcProcesses = @()
        
        # More precise version mapping
        $vcVersionMap = @{
            "msvcr60.dll" = "1998"
            "msvcr70.dll" = "2002"
            "msvcr71.dll" = "2003" 
            "msvcr80.dll" = "2005"
            "msvcr90.dll" = "2008"
            "msvcr100.dll" = "2010"
            "msvcr110.dll" = "2012"
            "msvcr120.dll" = "2013"
            "vcruntime140.dll" = "2015-2022"
            "msvcp60.dll" = "1998"
            "msvcp70.dll" = "2002"
            "msvcp71.dll" = "2003"
            "msvcp80.dll" = "2005"
            "msvcp90.dll" = "2008"
            "msvcp100.dll" = "2010"
            "msvcp110.dll" = "2012"
            "msvcp120.dll" = "2013"
            "msvcp140.dll" = "2015-2022"
        }
        
        $processes = Get-Process | Where-Object { $_.ProcessName -ne "Idle" }
        Write-LogMessage "Analyzing $($processes.Count) running processes..." -Color DarkGray
        
        $processCount = 0
        foreach ($process in $processes) {
            $processCount++
            if ($processCount % 20 -eq 0) {
                Write-LogMessage "  Progress: $processCount/$($processes.Count) processes analyzed..." -Color DarkGray
            }
            
            try {
                $vcModules = @()
                $yearFamiliesUsed = @()
                
                # Get only specific VC++ runtime modules with known version mappings
                $modules = $process.Modules | Where-Object { 
                    $moduleName = $_.ModuleName.ToLower()
                    $vcVersionMap.Keys -contains $moduleName -and 
                    $_.FileName -like "*system32*" -or $_.FileName -like "*syswow64*"
                }
                
                if ($modules -and $modules.Count -gt 0) {
                    $vcModules = $modules | ForEach-Object {
                        $moduleName = $_.ModuleName.ToLower()
                        $yearFamily = $vcVersionMap[$moduleName]
                        
                        if ($yearFamily -and $yearFamily -notin $yearFamiliesUsed) {
                            $yearFamiliesUsed += $yearFamily
                        }
                        
                        [PSCustomObject]@{
                            ModuleName = $_.ModuleName
                            FileName = $_.FileName
                            YearFamily = $yearFamily
                            FileVersion = try { 
                                $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_.FileName)
                                $versionInfo.FileVersion
                            } catch { "Unknown" }
                        }
                    }
                    
                    # Only include processes that use specific VC++ versions and have system DLLs
                    if ($yearFamiliesUsed.Count -gt 0 -and $vcModules.Count -gt 0) {
                        $vcProcesses += [PSCustomObject]@{
                            ProcessName = $process.ProcessName
                            Id = $process.Id
                            StartTime = if ($process.StartTime) { $process.StartTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Unknown" }
                            VCModules = $vcModules
                            YearFamiliesUsed = $yearFamiliesUsed
                            VCModuleCount = $vcModules.Count
                        }
                    }
                }
            } catch {
                # Skip processes we can't examine
            }
        }
        
        Write-LogMessage "Found $($vcProcesses.Count) process(es) using specific Visual C++ runtime versions" -Color Green
        return $vcProcesses
        
    } catch {
        Write-LogMessage "Error checking running processes for VC++ dependencies: $_" -Level "ERROR" -Color Red
        return @()
    }
}

# Function to download Dependencies.exe (simplified, no debug output)
function Install-DependenciesExe {
    param(
        [string]$DownloadPath,
        [string]$TempPath
    )
    
    try {
        # Ensure TLS 1.2 is enabled
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        # GitHub releases API to get latest version
        $releasesUrl = "https://api.github.com/repos/lucasg/Dependencies/releases/latest"
        $headers = @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            'Accept' = 'application/vnd.github.v3+json'
        }
        
        $releaseInfo = Invoke-RestMethod -Uri $releasesUrl -Headers $headers -TimeoutSec 30
        
        # Find the ZIP file in assets
        $zipAsset = $releaseInfo.assets | Where-Object { $_.name -like "Dependencies_*_Release.zip" } | Select-Object -First 1
        
        if (-not $zipAsset) {
            throw "Could not find Dependencies release ZIP file"
        }
        
        $downloadUrl = $zipAsset.browser_download_url
        $fileName = $zipAsset.name
        $zipPath = Join-Path $TempPath $fileName
        
        # Download the ZIP file
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -Headers $headers -UseBasicParsing -TimeoutSec 300
        
        # Verify download
        if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -eq 0) {
            throw "Download failed"
        }
        
        # Extract the ZIP file
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        
        # Find Dependencies.exe in the ZIP
        $dependenciesEntry = $zip.Entries | Where-Object { $_.Name -eq "Dependencies.exe" } | Select-Object -First 1
        
        if (-not $dependenciesEntry) {
            $zip.Dispose()
            throw "Dependencies.exe not found in ZIP archive"
        }
        
        # Extract Dependencies.exe to the central directory
        $targetPath = Join-Path $DownloadPath "Dependencies.exe"
        
        # Remove existing file if present
        if (Test-Path $targetPath) {
            Remove-Item $targetPath -Force -ErrorAction SilentlyContinue
        }
        
        $fileStream = [System.IO.File]::Create($targetPath)
        $entryStream = $dependenciesEntry.Open()
        $entryStream.CopyTo($fileStream)
        $fileStream.Close()
        $entryStream.Close()
        $zip.Dispose()
        
        # Clean up ZIP file
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        
        # Verify extraction
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
    
    # Check for DUMPBIN (simplified)
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

#region Core Functions

# Function to perform Visual C++ inventory
function Get-VisualCppInventory {
    param([string]$ScanDepth)
    
    Write-LogMessage "Starting Visual C++ redistributable inventory scan (Depth: $ScanDepth)..." -Color Cyan
    
    # Initialize inventory report
    $inventory = @{
        "ComputerName" = $env:COMPUTERNAME
        "ScanDate" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "ScanDepth" = $ScanDepth
        "PowerShellVersion" = $PSVersionTable.PSVersion.ToString()
        "VisualCppRedistributables" = @()
        "RunningProcesses" = @()
        "AnalysisTools" = @()
        "Summary" = @{}
    }

    # Check for available analysis tools
    Write-LogMessage "Checking for modern dependency analysis tools..." -Color Cyan
    $analysisTools = Test-DependencyAnalysisTools -AutoDownload $AutoDownloadTools -DownloadPath $centralDir -TempPath $tempDir
    $inventory.AnalysisTools = $analysisTools

    # Get installed redistributables
    Write-LogMessage "Scanning registry for Visual C++ redistributables..." -Color DarkGray
    $inventory.VisualCppRedistributables = Get-VisualCppRedistributables
    
    # Standard and Deep scans: check running processes
    if ($ScanDepth -in "Standard", "Deep") {
        $inventory.RunningProcesses = Get-ProcessesUsingVCRuntime
    } else {
        $inventory.RunningProcesses = @()
    }

    # Create summary
    $yearFamilyCounts = @{}
    $archCounts = @{}
    $totalSize = 0
    
    $inventory.VisualCppRedistributables | ForEach-Object {
        $year = $_.YearFamily
        $arch = $_.Architecture
        
        if ($yearFamilyCounts.ContainsKey($year)) {
            $yearFamilyCounts[$year]++
        } else {
            $yearFamilyCounts[$year] = 1
        }
        
        if ($archCounts.ContainsKey($arch)) {
            $archCounts[$arch]++
        } else {
            $archCounts[$arch] = 1
        }
        
        if ($_.EstimatedSize) {
            $totalSize += $_.EstimatedSize
        }
    }

    $inventory.Summary = @{
        "RedistributableCount" = $inventory.VisualCppRedistributables.Count
        "RunningProcessCount" = $inventory.RunningProcesses.Count
        "YearFamilyCounts" = $yearFamilyCounts
        "ArchitectureCounts" = $archCounts
        "TotalEstimatedSizeKB" = $totalSize
        "TotalEstimatedSizeMB" = [math]::Round($totalSize / 1024, 1)
        "EOLVersionsCount" = ($inventory.VisualCppRedistributables | Where-Object { 
            $_.YearFamily -in @("2005", "2008", "2010", "2012", "2013") 
        }).Count
        "CurrentVersionsCount" = ($inventory.VisualCppRedistributables | Where-Object { 
            $_.YearFamily -eq "2015-2022" 
        }).Count
    }

    return $inventory
}

# Function to install latest Visual C++ redistributables
function Install-LatestVisualCppRedistributables {
    param(
        [string]$Architecture,
        [string]$TempPath
    )
    
    # URLs for latest Visual C++ 2015-2022 redistributables
    $downloadUrls = @{
        "x86" = "https://aka.ms/vs/17/release/vc_redist.x86.exe"
        "x64" = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
        "ARM64" = "https://aka.ms/vs/17/release/vc_redist.arm64.exe"
    }
    
    $installResults = @{}
    $architecturesToInstall = @()
    
    if ($Architecture -eq "All") {
        $architecturesToInstall = @("x86", "x64")
        if ([Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432") -eq "ARM64" -or 
            [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") -eq "ARM64") {
            $architecturesToInstall += "ARM64"
        }
    } else {
        $architecturesToInstall = @($Architecture)
    }
    
    foreach ($arch in $architecturesToInstall) {
        if (-not $downloadUrls.ContainsKey($arch)) {
            $installResults[$arch] = $false
            continue
        }
        
        $url = $downloadUrls[$arch]
        $fileName = "vc_redist.${arch}.exe"
        $installerPath = Join-Path $TempPath $fileName
        
        try {
            # Download
            $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }
            Invoke-WebRequest -Uri $url -OutFile $installerPath -Headers $headers -UseBasicParsing -TimeoutSec 300
            
            # Verify download
            if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -eq 0) {
                throw "Download failed"
            }
            
            # Install
            $process = Start-Process -FilePath $installerPath -ArgumentList "/install", "/quiet", "/norestart" -PassThru -Wait
            
            if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                $installResults[$arch] = $true
            } else {
                $installResults[$arch] = $false
            }
            
            # Clean up installer
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            
        } catch {
            $installResults[$arch] = $false
            if (Test-Path $installerPath) {
                Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    return $installResults
}

#endregion

#region Main Execution

# Check if help was requested
if ($Help) {
    Show-Help
    exit 0
}

# Main execution starts here
Write-LogMessage "Visual C++ Redistributable Management Tool (v1.2.1-PS7)" -Color Green
Write-LogMessage "PowerShell Version: $($PSVersionTable.PSVersion)" -Color Green
Write-LogMessage "Scan Depth: $ScanDepth" -Color Cyan
Write-LogMessage "Skip Update: $SkipUpdate" -Color $(if ($SkipUpdate) { "Yellow" } else { "White" })
Write-LogMessage "Install Latest: $InstallLatest" -Color $(if ($InstallLatest) { "Yellow" } else { "White" })
Write-LogMessage "Architecture: $Architecture" -Color Cyan
Write-LogMessage "Auto-Download Tools: $AutoDownloadTools" -Color $(if ($AutoDownloadTools) { "Green" } else { "Yellow" })
Write-LogMessage "Central Directory: $centralDir" -Color Cyan
Write-LogMessage "Log File: $logFile" -Color Cyan

# Create initial inventory
Write-LogMessage "Creating initial Visual C++ redistributable inventory..." -Color Green
$beforeInventory = Get-VisualCppInventory -ScanDepth $ScanDepth

# Save initial inventory
$beforeInventoryPath = Join-Path $centralDir "VisualCppInventory-Before-$timestamp.json"
$beforeInventory | ConvertTo-Json -Depth 6 | Out-File -FilePath $beforeInventoryPath -Force -Encoding UTF8
Write-LogMessage "Initial inventory saved to: $beforeInventoryPath" -Color Green

# Display initial summary
Write-LogMessage "Initial Visual C++ Environment:" -Color Cyan
Write-LogMessage "Computer: $($beforeInventory.ComputerName)" -Color White
Write-LogMessage "VC++ Redistributables: $($beforeInventory.Summary.RedistributableCount)" -Color White
Write-LogMessage "Total estimated size: $($beforeInventory.Summary.TotalEstimatedSizeMB) MB" -Color White
Write-LogMessage "EOL versions: $($beforeInventory.Summary.EOLVersionsCount)" -Color $(if($beforeInventory.Summary.EOLVersionsCount -gt 0) { "Yellow" } else { "Green" })
Write-LogMessage "Current versions: $($beforeInventory.Summary.CurrentVersionsCount)" -Color White

if ($ScanDepth -in "Standard", "Deep") {
    Write-LogMessage "Running processes using VC++: $($beforeInventory.Summary.RunningProcessCount)" -Color White
}

Write-LogMessage ""
Write-LogMessage "Modern Dependency Analysis Tools:" -Color Cyan
$analysisTools = $beforeInventory.AnalysisTools
if ($analysisTools['Dependencies']['Found']) {
    $downloadedText = if ($analysisTools['Dependencies']['Downloaded']) { " (auto-downloaded)" } else { "" }
    Write-LogMessage "Dependencies.exe found: $($analysisTools['Dependencies']['Path'])$downloadedText" -Color Green
} else {
    Write-LogMessage "Dependencies.exe not found" -Color Yellow
    if (-not $AutoDownloadTools) {
        Write-LogMessage "   Use -AutoDownloadTools `$true to auto-download" -Color Yellow
    } else {
        Write-LogMessage "   Auto-download failed - manual download from: https://github.com/lucasg/Dependencies" -Color Yellow
    }
}

if ($analysisTools['DUMPBIN']['Found']) {
    Write-LogMessage "DUMPBIN found: $($analysisTools['DUMPBIN']['Path'])" -Color Green
} else {
    Write-LogMessage "DUMPBIN not found (Visual Studio tools)" -Color Yellow
}

if (-not $analysisTools['Dependencies']['Found'] -and -not $analysisTools['DUMPBIN']['Found']) {
    Write-LogMessage "Using basic heuristic analysis (lower confidence)" -Color Yellow
} elseif ($analysisTools['Dependencies']['Found']) {
    Write-LogMessage "High-accuracy dependency analysis enabled" -Color Green
}

# Display year family breakdown
Write-LogMessage ""
Write-LogMessage "Installed by year family:" -Color Cyan
foreach ($yearFamily in $beforeInventory.Summary.YearFamilyCounts.Keys | Sort-Object) {
    $count = $beforeInventory.Summary.YearFamilyCounts[$yearFamily]
    $eolStatus = if ($yearFamily -in @("2005", "2008", "2010", "2012", "2013")) { " (EOL)" } else { "" }
    Write-LogMessage "  ${yearFamily}: $count redistributable(s)$eolStatus" -Color White
}

# Display architecture breakdown
Write-LogMessage ""
Write-LogMessage "Installed by architecture:" -Color Cyan
foreach ($arch in $beforeInventory.Summary.ArchitectureCounts.Keys | Sort-Object) {
    $count = $beforeInventory.Summary.ArchitectureCounts[$arch]
    Write-LogMessage "  ${arch}: $count redistributable(s)" -Color White
}

# Initialize variables for tracking results
$script:successful = 0
$script:failed = 0

# Install latest redistributables (if requested)
if (-not $SkipUpdate -and $InstallLatest) {
    Write-LogMessage "Installing latest VC++ redistributables..." -Color Green
    
    $installResults = Install-LatestVisualCppRedistributables -Architecture $Architecture -TempPath $tempDir
    
    $script:successful = ($installResults.Values | Where-Object { $_ -eq $true }).Count
    $script:failed = ($installResults.Values | Where-Object { $_ -eq $false }).Count
    
    if ($script:successful -gt 0) {
        Write-LogMessage "Installed: $script:successful architecture(s)" -Color Green
    }
    if ($script:failed -gt 0) {
        Write-LogMessage "Failed: $script:failed architecture(s)" -Color Red
    }
}

# Create final inventory
if (-not $SkipUpdate -and $InstallLatest -and $script:successful -gt 0) {
    Write-LogMessage "Creating final Visual C++ redistributable inventory..." -Color Green
    $afterInventory = Get-VisualCppInventory -ScanDepth $ScanDepth
    $afterInventoryPath = Join-Path $centralDir "VisualCppInventory-After-$timestamp.json"
    $afterInventory | ConvertTo-Json -Depth 6 | Out-File -FilePath $afterInventoryPath -Force -Encoding UTF8
    Write-LogMessage "Final inventory saved to: $afterInventoryPath" -Color Green
    
    if ($afterInventory.Summary.RedistributableCount -gt $beforeInventory.Summary.RedistributableCount) {
        $newCount = $afterInventory.Summary.RedistributableCount - $beforeInventory.Summary.RedistributableCount
        Write-LogMessage "Added $newCount new redistributable(s)" -Color Green
    }
} else {
    Write-LogMessage "Copying original inventory (no changes made)..." -Color Green
    $afterInventoryPath = Join-Path $centralDir "VisualCppInventory-After-$timestamp.json"
    Copy-Item -Path $beforeInventoryPath -Destination $afterInventoryPath -Force
}

# Simple completion message
Write-LogMessage ""
if ($beforeInventory.Summary.EOLVersionsCount -gt 0) {
    Write-LogMessage "Run Get-VisualCppDependencies.ps1 to analyze $($beforeInventory.Summary.EOLVersionsCount) vulnerable version(s)" -Color Yellow
}

Write-LogMessage "Visual C++ management completed with status: SUCCESS" -Color Green
Write-LogMessage "PowerShell Version Used: $($PSVersionTable.PSVersion)" -Color Green

# Set exit code based on results
if (-not $SkipUpdate -and $InstallLatest) {
    if ($script:failed -gt 0 -and $script:successful -eq 0) {
        exit 1
    } elseif ($script:failed -gt 0 -and $script:successful -gt 0) {
        exit 2
    }
}

exit 0

#endregion