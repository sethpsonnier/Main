param(
    [string]$InputPath = "",  # Auto-detect if not specified
    
    [string[]]$VersionsToAnalyze = @(),
    
    [ValidateScript({Test-Path (Split-Path $_ -Parent) -PathType Container})]
    [string]$OutputPath = "C:\temp\NET\DotNetDependencyReport.json",
    
    [switch]$Help
)

#region Setup and Initialization

# Create centralized directory structure
$centralDir = "C:\temp\NET"
$logsDir = Join-Path $centralDir "logs"

$directories = @($centralDir, $logsDir)
foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created directory: $dir" -ForegroundColor Green
    }
}

# Set up logging
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logsDir "dependencies-$timestamp.log"

#endregion

#region Helper Functions

# Simple help function
function Show-Help {
    Write-Host ""
    Write-Host ".NET Dependency Analysis Tool - Help" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "DESCRIPTION:" -ForegroundColor Cyan
    Write-Host "  Analyzes .NET version dependencies from inventory files created"
    Write-Host "  by Manage-DotNet.ps1 and provides cleanup recommendations."
    Write-Host ""
    
    Write-Host "PARAMETERS:" -ForegroundColor Cyan
    Write-Host "  -InputPath           Path to inventory JSON file [Default: Auto-detect latest]"
    Write-Host "  -VersionsToAnalyze   Specific versions to analyze [Default: All detected]"
    Write-Host "  -OutputPath          Output path for dependency report"
    Write-Host "  -Help                Show this help"
    Write-Host ""
    
    Write-Host "EXAMPLES:" -ForegroundColor Cyan
    Write-Host "  .\Get-DotNetDependencies.ps1"
    Write-Host "  .\Get-DotNetDependencies.ps1 -InputPath 'C:\temp\NET\DotNetInventory-After-*.json'"
    Write-Host "  .\Get-DotNetDependencies.ps1 -VersionsToAnalyze @('8.0', '9.0')"
    Write-Host ""
    
    Write-Host "WORKFLOW:" -ForegroundColor Cyan
    Write-Host "  1. Run Manage-DotNet.ps1 to create inventory"
    Write-Host "  2. Run this script to analyze dependencies"
    Write-Host "  3. Review recommendations and run cleanup commands"
    Write-Host "  4. Re-run Manage-DotNet.ps1 to verify changes"
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

# FUTURE-PROOF: Robust version parsing function
function Parse-DotNetVersion {
    param([string]$VersionString)
    
    if ([string]::IsNullOrWhiteSpace($VersionString)) {
        return $null
    }
    
    # Handle various version formats
    $patterns = @(
        '(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?',  # Standard: 8.0.18, 9.0.7.4
        '(\d+)\.(\d+)(?:\.(\d+))?',         # Short: 8.0, 9.0.7
        'v(\d+)\.(\d+)\.(\d+)',             # With v prefix: v8.0.18
        'net(\d+)\.(\d+)',                  # TFM format: net8.0
        'netcoreapp(\d+)\.(\d+)'            # Legacy TFM: netcoreapp3.1
    )
    
    foreach ($pattern in $patterns) {
        if ($VersionString -match $pattern) {
            $major = [int]$matches[1]
            $minor = [int]$matches[2]
            $patch = if ($matches[3]) { [int]$matches[3] } else { 0 }
            $build = if ($matches[4]) { [int]$matches[4] } else { 0 }
            
            return @{
                Major = $major
                Minor = $minor  
                Patch = $patch
                Build = $build
                MajorMinor = "$major.$minor"
                FullVersion = if ($build -gt 0) { "$major.$minor.$patch.$build" } else { "$major.$minor.$patch" }
                ShortVersion = "$major.$minor"
            }
        }
    }
    
    Write-LogMessage "    Could not parse version: $VersionString" -Color Yellow
    return $null
}

# FUTURE-PROOF: Dynamic dependency pattern generation
function Get-DotNetDependencyPatterns {
    param(
        [int]$MajorVersion,
        [int]$MinorVersion
    )
    
    $majorMinor = "$MajorVersion.$MinorVersion"
    
    # Generate comprehensive patterns for current and future TFM formats
    $patterns = @(
        # Current formats
        "net$MajorVersion$MinorVersion",
        "netcoreapp$MajorVersion$MinorVersion",
        "netstandard$MajorVersion$MinorVersion",
        "net$majorMinor",
        "netcoreapp$majorMinor",
        "netstandard$majorMinor",
        "$MajorVersion\.$MinorVersion",
        
        # Future-proofing: Handle potential new formats
        "dotnet$MajorVersion$MinorVersion",
        "dotnet$majorMinor",
        "aspnet$MajorVersion$MinorVersion", 
        "aspnet$majorMinor",
        "maui$MajorVersion$MinorVersion",
        "maui$majorMinor",
        
        # Version-specific patterns for edge cases
        "v$majorMinor",
        "version.*$majorMinor",
        "target.*$majorMinor",
        "framework.*$majorMinor",
        
        # Handle spaces and various delimiters
        "net\s*$MajorVersion\.\s*$MinorVersion",
        "\.NET\s*$MajorVersion\.\s*$MinorVersion",
        "Microsoft\.NET.*$majorMinor"
    )
    
    # For .NET 5+ add additional patterns
    if ($MajorVersion -ge 5) {
        $patterns += @(
            "net$MajorVersion\.0",  # net5.0, net6.0, etc.
            "net$MajorVersion-windows",
            "net$MajorVersion-linux", 
            "net$MajorVersion-macos",
            "net$MajorVersion-android",
            "net$MajorVersion-ios"
        )
    }
    
    return $patterns | Sort-Object -Unique
}

#endregion

#region Inventory Functions

# Function to auto-detect the most recent inventory file
function Find-LatestInventoryFile {
    param([string]$CentralDir)
    
    # Look for inventory files in order of preference
    $searchPatterns = @(
        "DotNetInventory-After-*.json",  # Newest format (after updates)
        "DotNetInventory-Before-*.json", # Newest format (before updates)
        "DotNetInventory.json"           # Legacy format
    )
    
    foreach ($pattern in $searchPatterns) {
        try {
            $files = Get-ChildItem -Path $CentralDir -Filter $pattern -ErrorAction SilentlyContinue | 
                     Where-Object { $_.Length -gt 0 } |  # Exclude empty files
                     Sort-Object LastWriteTime -Descending
            
            if ($files.Count -gt 0) {
                $selectedFile = $files[0].FullName
                Write-LogMessage "Found inventory pattern '$pattern': $(Split-Path $selectedFile -Leaf)" -Color DarkGray
                return $selectedFile
            }
        } catch {
            Write-LogMessage "Error checking pattern '$pattern': $_" -Level "WARN" -Color Yellow
        }
    }
    
    return $null
}

# Function to validate inventory file structure
function Test-InventoryFile {
    param([PSCustomObject]$Inventory)
    
    $requiredProperties = @('ComputerName', 'DotNetRuntimes')
    $missingProperties = @()
    
    foreach ($prop in $requiredProperties) {
        if (-not $Inventory.PSObject.Properties[$prop]) {
            $missingProperties += $prop
        }
    }
    
    if ($missingProperties.Count -gt 0) {
        throw "Invalid inventory file. Missing required properties: $($missingProperties -join ', ')"
    }
    
    if (-not $Inventory.DotNetRuntimes -or $Inventory.DotNetRuntimes.Count -eq 0) {
        throw "Invalid inventory file. No .NET runtimes found in inventory."
    }
    
    return $true
}

#endregion

#region Runtime Installation Functions

# IMPROVED: Better error handling and performance
function Get-DotNetRuntimeInstallations {
    param([string]$DotNetPath = "C:\Program Files\dotnet")
    
    $installations = @()
    $sharedPath = Join-Path $DotNetPath "shared"
    
    if (-not (Test-Path $sharedPath)) {
        Write-LogMessage "    .NET shared directory not found: $sharedPath" -Color Yellow
        return $installations
    }
    
    try {
        # Get all runtime types (Microsoft.NETCore.App, Microsoft.AspNetCore.App, Microsoft.WindowsDesktop.App)
        $runtimeTypes = Get-ChildItem -Path $sharedPath -Directory -ErrorAction SilentlyContinue
        
        foreach ($runtimeType in $runtimeTypes) {
            $runtimePath = $runtimeType.FullName
            $runtimeName = $runtimeType.Name
            
            # Get all versions for this runtime type
            $versions = Get-ChildItem -Path $runtimePath -Directory -ErrorAction SilentlyContinue
            
            foreach ($version in $versions) {
                $versionNumber = $version.Name
                $versionPath = $version.FullName
                
                # Use improved version parsing
                $parsedVersion = Parse-DotNetVersion -VersionString $versionNumber
                
                if ($parsedVersion) {
                    try {
                        # Calculate directory size more efficiently
                        $size = 0
                        $files = Get-ChildItem -Path $versionPath -Recurse -File -ErrorAction SilentlyContinue
                        if ($files) {
                            $size = ($files | Measure-Object -Property Length -Sum).Sum
                        }
                        
                        $installations += [PSCustomObject]@{
                            RuntimeType = $runtimeName
                            FullVersion = $parsedVersion.FullVersion
                            MajorMinor = $parsedVersion.MajorMinor
                            Path = $versionPath
                            Size = $size
                            ParsedVersion = $parsedVersion
                        }
                    } catch {
                        Write-LogMessage "    Error processing version directory ${versionPath}: $_" -Color Yellow
                    }
                } else {
                    Write-LogMessage "    Unable to parse version: $versionNumber" -Color DarkGray
                }
            }
        }
    } catch {
        Write-LogMessage "    Error scanning runtime installations: $_" -Level "WARN" -Color Yellow
    }
    
    return $installations
}

# IMPROVED: Better array handling and performance
function Get-DotNetCachedInstallers {
    param(
        [string]$PackageCachePath = "C:\ProgramData\Package Cache",
        [int]$MaxDirectories = 1000  # Performance limit
    )
    
    $cachedInstallers = @()
    
    if (-not (Test-Path $PackageCachePath)) {
        Write-LogMessage "    Package Cache directory not found: $PackageCachePath" -Color Yellow
        return $cachedInstallers
    }
    
    try {
        # Performance optimization: limit directory scan
        $packageDirs = Get-ChildItem -Path $PackageCachePath -Directory -ErrorAction SilentlyContinue | 
                      Select-Object -First $MaxDirectories
        
        $processedCount = 0
        foreach ($packageDir in $packageDirs) {
            $processedCount++
            if ($processedCount % 100 -eq 0) {
                Write-LogMessage "    Processed $processedCount/$($packageDirs.Count) package directories..." -Color DarkGray
            }
            
            try {
                # FIXED: Proper array initialization
                $installerExes = @()
                
                # Look for .NET installer executables with various patterns
                $searchPatterns = @("*runtime*.exe", "*dotnet*.exe", "*aspnetcore*.exe", "*windowsdesktop*.exe", "*hosting*.exe")
                
                foreach ($pattern in $searchPatterns) {
                    $foundFiles = Get-ChildItem -Path $packageDir.FullName -Filter $pattern -ErrorAction SilentlyContinue
                    if ($foundFiles) {
                        $installerExes += $foundFiles
                    }
                }
                
                # Remove duplicates
                $installerExes = $installerExes | Sort-Object FullName -Unique
                
                foreach ($exe in $installerExes) {
                    # Try to parse version from filename or directory name
                    $versionMatch = $null
                    $parsedVersion = $null
                    
                    # Try filename first
                    $parsedVersion = Parse-DotNetVersion -VersionString $exe.Name
                    if (-not $parsedVersion) {
                        # Try directory name
                        $parsedVersion = Parse-DotNetVersion -VersionString $packageDir.Name
                    }
                    
                    if ($parsedVersion) {
                        # Determine runtime type from filename using improved detection
                        $runtimeType = Get-RuntimeTypeFromFileName -FileName $exe.Name
                        
                        $cachedInstallers += [PSCustomObject]@{
                            RuntimeType = $runtimeType
                            FullVersion = $parsedVersion.FullVersion
                            MajorMinor = $parsedVersion.MajorMinor
                            ExecutablePath = $exe.FullName
                            ExecutableName = $exe.Name
                            PackageDirectory = $packageDir.FullName
                            Size = $exe.Length
                            ParsedVersion = $parsedVersion
                        }
                    }
                }
            } catch {
                Write-LogMessage "    Error processing package directory $($packageDir.Name): $_" -Color Yellow
            }
        }
        
        Write-LogMessage "    Scanned $processedCount package directories, found $($cachedInstallers.Count) .NET installers" -Color DarkGray
        
    } catch {
        Write-LogMessage "    Error scanning package cache: $_" -Level "WARN" -Color Yellow
    }
    
    return $cachedInstallers
}

# FUTURE-PROOF: Improved runtime type detection
function Get-RuntimeTypeFromFileName {
    param([string]$FileName)
    
    $fileName = $FileName.ToLower()
    
    # Comprehensive runtime type detection patterns
    $typePatterns = @{
        "ASP.NET Core Runtime" = @("aspnetcore", "hosting")
        "Windows Desktop Runtime" = @("windowsdesktop", "desktop", "winforms", "wpf")
        ".NET Runtime" = @("dotnet.*runtime", "netcore.*runtime", "^runtime")
        "SDK" = @("sdk")
        "Hosting Bundle" = @("hosting.*bundle", "server.*hosting")
    }
    
    foreach ($type in $typePatterns.Keys) {
        foreach ($pattern in $typePatterns[$type]) {
            if ($fileName -match $pattern) {
                return $type
            }
        }
    }
    
    # Fallback: try to infer from context
    if ($fileName -match "dotnet") {
        return ".NET Runtime"
    }
    
    return "Unknown .NET Component"
}

# IMPROVED: Better matching and error handling
function Get-DotNetRuntimeRemovalInfo {
    param(
        [array]$VersionsToRemove,
        [string]$DotNetPath = "C:\Program Files\dotnet"
    )
    
    $removalInfo = @()
    
    if ($VersionsToRemove.Count -eq 0) {
        return $removalInfo
    }
    
    Write-LogMessage "    Analyzing runtime installations for removal..." -Color DarkGray
    
    # Get runtime installations for size information
    $installations = Get-DotNetRuntimeInstallations -DotNetPath $DotNetPath
    
    # Get cached installer executables
    $cachedInstallers = Get-DotNetCachedInstallers
    
    foreach ($version in $VersionsToRemove) {
        Write-LogMessage "    Processing version $version for removal..." -Color DarkGray
        
        # Find matching cached installer executables
        $matchingInstallers = $cachedInstallers | Where-Object { $_.MajorMinor -eq $version }
        
        # Find matching runtime installations
        $matchingInstallations = $installations | Where-Object { $_.MajorMinor -eq $version }
        
        Write-LogMessage "      Found $($matchingInstallers.Count) cached installers, $($matchingInstallations.Count) installations" -Color DarkGray
        
        # Track what we've already processed to avoid duplicates
        $processedRuntimeTypes = @()
        
        # Prefer cached installers (proper uninstall method)
        foreach ($installer in $matchingInstallers) {
            # Find corresponding installation for size information using improved matching
            $installation = $matchingInstallations | Where-Object { 
                $_.RuntimeType -like "*$($installer.RuntimeType.Split(' ')[0])*" -or 
                $installer.RuntimeType -like "*$($_.RuntimeType.Split('.')[1])*" -or
                ($_.RuntimeType -eq "Microsoft.NETCore.App" -and $installer.RuntimeType -eq ".NET Runtime") -or
                ($_.RuntimeType -eq "Microsoft.AspNetCore.App" -and $installer.RuntimeType -eq "ASP.NET Core Runtime") -or
                ($_.RuntimeType -eq "Microsoft.WindowsDesktop.App" -and $installer.RuntimeType -eq "Windows Desktop Runtime")
            } | Select-Object -First 1
            
            $sizeMB = if ($installation) { [math]::Round($installation.Size / 1MB, 1) } else { 0 }
            
            $removalInfo += [PSCustomObject]@{
                Version = $version
                RuntimeType = $installer.RuntimeType
                FullVersion = $installer.FullVersion
                Method = "Cached Installer"
                UninstallCommand = "`"$($installer.ExecutablePath)`" /uninstall /quiet /norestart"
                ExecutablePath = $installer.ExecutablePath
                ExecutableName = $installer.ExecutableName
                RuntimePath = if ($installation) { $installation.Path } else { "Not found" }
                SizeMB = $sizeMB
                Confidence = "High"
            }
            
            # Track this runtime type as processed
            if ($installation) {
                $processedRuntimeTypes += $installation.RuntimeType
            }
        }
        
        # Add directory removal for any installations not covered by cached installers
        foreach ($installation in $matchingInstallations) {
            if ($installation.RuntimeType -notin $processedRuntimeTypes) {
                $sizeMB = [math]::Round($installation.Size / 1MB, 1)
                
                $removalInfo += [PSCustomObject]@{
                    Version = $version
                    RuntimeType = $installation.RuntimeType
                    FullVersion = $installation.FullVersion
                    Method = "Directory Removal"
                    UninstallCommand = "Remove-Item -Path `"$($installation.Path)`" -Recurse -Force"
                    ExecutablePath = "N/A"
                    ExecutableName = "N/A"
                    RuntimePath = $installation.Path
                    SizeMB = $sizeMB
                    Confidence = "Medium"
                }
            }
        }
    }
    
    return $removalInfo
}

#endregion

#region Dependency Analysis Functions

# FUTURE-PROOF: Improved dependency detection with dynamic patterns
function Test-DotNetVersionDependency {
    param (
        [string]$Version,
        [PSCustomObject]$Inventory
    )
    
    $parsedVersion = Parse-DotNetVersion -VersionString $Version
    if (-not $parsedVersion) {
        Write-LogMessage "    Invalid version format: $Version" -Color Red
        return $null
    }
    
    $majorVersion = $parsedVersion.Major
    $minorVersion = $parsedVersion.Minor
    $fullVersion = $parsedVersion.MajorMinor
    
    $dependencies = @{
        "RunningProcesses" = @()
        "ApplicationReferences" = @()
        "IISApplicationPools" = @()
        "InstalledPackages" = @()
    }
    
    Write-LogMessage "Analyzing dependencies for .NET $fullVersion..." -Color DarkGray
    
    # Get dynamic dependency patterns
    $patterns = Get-DotNetDependencyPatterns -MajorVersion $majorVersion -MinorVersion $minorVersion
    
    # Check running processes
    if ($Inventory.RunningProcesses -and $Inventory.RunningProcesses.Count -gt 0) {
        foreach ($process in $Inventory.RunningProcesses) {
            if ($process.NetModules) {
                foreach ($pattern in $patterns) {
                    if ($process.NetModules -match $pattern) {
                        $dependencies.RunningProcesses += $process
                        break
                    }
                }
            }
        }
    }
    
    # Check application references with improved pattern matching
    if ($Inventory.ApplicationReferences -and $Inventory.ApplicationReferences.Count -gt 0) {
        foreach ($ref in $Inventory.ApplicationReferences) {
            if ($ref.DotNetReference) {
                foreach ($pattern in $patterns) {
                    try {
                        if ($ref.DotNetReference -match $pattern) {
                            $dependencies.ApplicationReferences += $ref
                            break
                        }
                    } catch {
                        # Skip regex errors for complex patterns
                        continue
                    }
                }
            }
        }
    }
    
    # Check IIS application pools
    if ($Inventory.IISApplicationPools -and $Inventory.IISApplicationPools.Count -gt 0) {
        foreach ($pool in $Inventory.IISApplicationPools) {
            if ($pool.ManagedRuntimeVersion -match "v$majorVersion\.$minorVersion") {
                $dependencies.IISApplicationPools += $pool
            }
        }
    }
    
    # Check installed packages that might depend on this .NET version
    if ($Inventory.InstalledPackages -and $Inventory.InstalledPackages.Count -gt 0) {
        foreach ($pkg in $Inventory.InstalledPackages) {
            if ($pkg.Name -match "\.NET.*$majorVersion\.$minorVersion|ASP\.NET.*$majorVersion\.$minorVersion") {
                $dependencies.InstalledPackages += $pkg
            }
        }
    }
    
    # Calculate active vs total dependencies
    $activeDependencies = $dependencies.RunningProcesses.Count + 
                         $dependencies.ApplicationReferences.Count + 
                         $dependencies.IISApplicationPools.Count
    
    $totalDependencies = $activeDependencies + $dependencies.InstalledPackages.Count
    
    # Determine if the version is needed (only active dependencies matter)
    $isNeeded = $activeDependencies -gt 0
    
    return @{
        Version = $fullVersion
        IsNeeded = $isNeeded
        Dependencies = $dependencies
        ActiveDependencies = $activeDependencies
        TotalDependencies = $totalDependencies
        PatternsUsed = $patterns.Count
        ParsedVersion = $parsedVersion
    }
}

# Function to generate removal recommendations
function Get-RemovalRecommendations {
    param(
        [PSCustomObject]$Inventory,
        [array]$SafeToRemove
    )
    
    $recommendations = @()
    
    # Generate recommendations for safe-to-remove versions
    if ($SafeToRemove.Count -gt 0) {
        foreach ($version in $SafeToRemove) {
            $recommendation = [PSCustomObject]@{
                VersionCategory = $version
                Action = "Remove unused .NET version"
                DetailsKeep = @()
                DetailsRemove = @($version)
                CommandExample = @(
                    "# Manual removal commands will be provided in the RuntimeInstallations section"
                )
                Reason = "No active dependencies found - safe to remove"
                Priority = "High"
                RiskLevel = "Low"
            }
            
            $recommendations += $recommendation
        }
    }
    
    return $recommendations
}

#endregion

#region Main Execution

# Check if help was requested
if ($Help) {
    Show-Help
    exit 0
}

Write-LogMessage ".NET Dependency Analysis Tool" -Color Green
Write-LogMessage "Central Directory: $centralDir" -Color Cyan
Write-LogMessage "Log File: $logFile" -Color Cyan

# Step 1: Load and validate inventory
Write-LogMessage "Loading .NET inventory..." -Color Green

try {
    # Auto-detect inventory file if not specified
    if ([string]::IsNullOrEmpty($InputPath)) {
        $InputPath = Find-LatestInventoryFile -CentralDir $centralDir
        
        if ([string]::IsNullOrEmpty($InputPath)) {
            throw "No inventory files found in $centralDir. Please run Manage-DotNet.ps1 first to create an inventory."
        }
        
        Write-LogMessage "Auto-selected: $(Split-Path $InputPath -Leaf)" -Color Green
    } else {
        # Handle wildcard paths
        if ($InputPath.Contains('*')) {
            $matchingFiles = Get-ChildItem -Path $InputPath -ErrorAction SilentlyContinue | 
                           Sort-Object LastWriteTime -Descending | 
                           Select-Object -First 1
            
            if ($matchingFiles) {
                $InputPath = $matchingFiles.FullName
                Write-LogMessage "Resolved wildcard to: $(Split-Path $InputPath -Leaf)" -Color Green
            } else {
                throw "No files found matching pattern: $InputPath"
            }
        }
        
        # Validate specified path
        if (-not (Test-Path $InputPath)) {
            throw "Specified inventory file not found: $InputPath"
        }
        Write-LogMessage "Using specified: $(Split-Path $InputPath -Leaf)" -Color Green
    }
    
    Write-LogMessage "Auto-selected: $(Split-Path $InputPath -Leaf)" -Color Green
    
    $inventory = Get-Content -Path $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    
    # Validate inventory structure
    Test-InventoryFile -Inventory $inventory | Out-Null
    
    Write-LogMessage "Loaded inventory for: $($inventory.ComputerName)" -Color Green
    Write-LogMessage "Inventory date: $($inventory.ScanDate)" -Color Green
    
    # Check inventory freshness
    if ($inventory.ScanDate) {
        try {
            $scanDate = [DateTime]::Parse($inventory.ScanDate)
            $ageHours = ((Get-Date) - $scanDate).TotalHours
            
            if ($ageHours -gt 24) {
                Write-LogMessage "Inventory is $([math]::Round($ageHours, 1)) hours old - consider regenerating" -Color Yellow
            } elseif ($ageHours -gt 168) { # 1 week
                Write-LogMessage "Inventory is $([math]::Round($ageHours/24, 1)) days old - regeneration recommended" -Color Yellow
            }
        } catch {
            # Silently continue if date parsing fails
        }
    }
    
} catch {
    Write-LogMessage "Failed to load inventory: $_" -Level "ERROR" -Color Red
    exit 1
}

# Step 2: Determine versions to analyze
Write-LogMessage "Determining versions to analyze..." -Color Green

if ($VersionsToAnalyze.Count -eq 0) {
    # IMPROVED: Use the enhanced version parsing
    $versions = $inventory.DotNetRuntimes | ForEach-Object {
        if ($_.MajorVersion -and $_.MinorVersion) {
            "$($_.MajorVersion).$($_.MinorVersion)"
        } else {
            # Fallback to parsing the version string
            $parsed = Parse-DotNetVersion -VersionString $_.Version
            if ($parsed) {
                $parsed.MajorMinor
            }
        }
    } | Where-Object { $_ } | Sort-Object -Unique | Sort-Object { [version]("$_.0") }
    
    Write-LogMessage "Auto-detected versions: $($versions -join ', ')" -Color Yellow
} else {
    $versions = $VersionsToAnalyze | Sort-Object { [version]("$_.0") }
    Write-LogMessage "Analyzing specified versions: $($versions -join ', ')" -Color Yellow
}

if ($versions.Count -eq 0) {
    Write-LogMessage "No .NET versions found to analyze" -Level "ERROR" -Color Red
    exit 1
}

# Initialize dependency report
$report = @{
    "ComputerName" = $inventory.ComputerName
    "AnalysisDate" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "InventoryDate" = $inventory.ScanDate
    "InventoryDepth" = $inventory.ScanDepth
    "CentralDirectory" = $centralDir
    "InputPath" = $InputPath
    "InputFileName" = Split-Path $InputPath -Leaf
    "OutputPath" = $OutputPath
    "LogFile" = $logFile
    "VersionsAnalyzed" = $versions
    "DependencyResults" = @()
    "SafeToRemove" = @()
    "NeededVersions" = @()
    "RemovalRecommendations" = @()
    "RuntimeInstallations" = @()
    "TotalRemovalSizeMB" = 0
    "Summary" = @{}
    "Metadata" = @{
        "ScriptVersion" = "2.0"
        "FeaturesUsed" = @("Dynamic Pattern Generation", "Robust Version Parsing", "Performance Optimization")
        "PatternsGenerated" = 0
    }
}

# Step 3: Analyze dependencies
Write-LogMessage "Analyzing dependencies for $($versions.Count) version(s)..." -Color Green

$totalPatternsGenerated = 0
foreach ($version in $versions) {
    Write-LogMessage "  Analyzing .NET $version..." -Color Cyan
    $result = Test-DotNetVersionDependency -Version $version -Inventory $inventory
    
    if ($result) {
        $report.DependencyResults += $result
        $totalPatternsGenerated += $result.PatternsUsed
        
        if ($result.IsNeeded) {
            $report.NeededVersions += $version
            Write-LogMessage ".NET $version is NEEDED - $($result.ActiveDependencies) active dependencies" -Color Yellow
        } else {
            $report.SafeToRemove += $version
            Write-LogMessage ".NET $version is SAFE TO REMOVE - No active dependencies" -Color Green
        }
    }
}

$report.Metadata.PatternsGenerated = $totalPatternsGenerated

# Step 4: Generate recommendations and scan for runtime installations
Write-LogMessage "Generating cleanup recommendations..." -Color Green

$report.RemovalRecommendations = Get-RemovalRecommendations -Inventory $inventory -SafeToRemove $report.SafeToRemove

# Generate runtime removal information for safe-to-remove versions
if ($report.SafeToRemove.Count -gt 0) {
    Write-LogMessage "Scanning .NET runtime installations..." -Color Green
    $report.RuntimeInstallations = Get-DotNetRuntimeRemovalInfo -VersionsToRemove $report.SafeToRemove
    
    if ($report.RuntimeInstallations.Count -gt 0) {
        $report.TotalRemovalSizeMB = ($report.RuntimeInstallations | Measure-Object -Property SizeMB -Sum).Sum
        Write-LogMessage "Found $($report.RuntimeInstallations.Count) runtime installations that can be removed ($([math]::Round($report.TotalRemovalSizeMB, 1)) MB)" -Color Green
    } else {
        $report.RuntimeInstallations = @()
        $report.TotalRemovalSizeMB = 0
        Write-LogMessage "No runtime installations found for removal" -Color Yellow
    }
} else {
    $report.RuntimeInstallations = @()
    $report.TotalRemovalSizeMB = 0
}

# Create enhanced summary
$totalDependencies = ($report.DependencyResults | Measure-Object -Property TotalDependencies -Sum).Sum
$activeDependencies = ($report.DependencyResults | Measure-Object -Property ActiveDependencies -Sum).Sum

$report.Summary = @{
    "VersionsAnalyzed" = $versions.Count
    "SafeToRemoveCount" = $report.SafeToRemove.Count
    "NeededVersionsCount" = $report.NeededVersions.Count
    "RecommendationsCount" = $report.RemovalRecommendations.Count
    "RuntimeInstallationsCount" = $report.RuntimeInstallations.Count
    "TotalDependenciesFound" = $totalDependencies
    "ActiveDependenciesFound" = $activeDependencies
    "TotalRemovalSizeMB" = $report.TotalRemovalSizeMB
    "PatternsGenerated" = $totalPatternsGenerated
    "HighConfidenceRemovals" = ($report.RuntimeInstallations | Where-Object { $_.Confidence -eq "High" }).Count
}

# Step 5: Save report
Write-LogMessage "Saving dependency report..." -Color Green

try {
    $report | ConvertTo-Json -Depth 8 | Out-File -FilePath $OutputPath -Force -Encoding UTF8
    Write-LogMessage "Report saved to: $OutputPath" -Color Green
} catch {
    Write-LogMessage "Error saving report: $_" -Level "ERROR" -Color Red
    exit 1
}

# Display comprehensive summary
Write-LogMessage ""
Write-LogMessage ".NET Dependency Analysis Summary" -Color Green
Write-LogMessage "================================================================" -Color Green

Write-LogMessage "Computer: $($report.ComputerName)" -Color White
Write-LogMessage "Analysis Date: $($report.AnalysisDate)" -Color White
Write-LogMessage "Inventory Date: $($report.InventoryDate)" -Color White
Write-LogMessage "Versions analyzed: $($report.Summary.VersionsAnalyzed)" -Color White
Write-LogMessage "Versions safe to remove: $($report.Summary.SafeToRemoveCount)" -Color White
Write-LogMessage "Versions with dependencies: $($report.Summary.NeededVersionsCount)" -Color White
Write-LogMessage "Runtime installations found: $($report.Summary.RuntimeInstallationsCount)" -Color White
Write-LogMessage "Active dependencies found: $($report.Summary.ActiveDependenciesFound) (processes, apps, IIS)" -Color White
Write-LogMessage "Installation artifacts found: $($report.Summary.TotalDependenciesFound - $report.Summary.ActiveDependenciesFound) (packages)" -Color White
Write-LogMessage "Dependency patterns generated: $($report.Summary.PatternsGenerated)" -Color White
Write-LogMessage "High-confidence removals: $($report.Summary.HighConfidenceRemovals)" -Color White

if ($report.SafeToRemove.Count -gt 0) {
    Write-LogMessage ""
    Write-LogMessage "Safe to remove:" -Color Green
    foreach ($version in $report.SafeToRemove) {
        Write-LogMessage "  .NET $version" -Color White
    }
}

if ($report.NeededVersions.Count -gt 0) {
    Write-LogMessage ""
    Write-LogMessage "Required (has active dependencies):" -Color Yellow
    foreach ($version in $report.NeededVersions) {
        $result = $report.DependencyResults | Where-Object { $_.Version -eq $version }
        Write-LogMessage "  .NET $version - $($result.ActiveDependencies) active dependencies, $($result.Dependencies.InstalledPackages.Count) artifacts" -Color White
    }
}

# Enhanced runtime installation display
if ($report.RuntimeInstallations.Count -gt 0) {
    Write-LogMessage ""
    Write-LogMessage "Runtime Installations Found for Removal:" -Color Cyan
    Write-LogMessage "Total installations: $($report.RuntimeInstallations.Count)" -Color White
    Write-LogMessage "Total size: $([math]::Round($report.TotalRemovalSizeMB, 1)) MB" -Color White
    Write-LogMessage ""
    
    # Group by removal method for display
    $groupedByMethod = $report.RuntimeInstallations | Group-Object Method | Sort-Object Name
    
    foreach ($methodGroup in $groupedByMethod) {
        if ($methodGroup.Name -eq "Cached Installer") {
            Write-LogMessage "Cached Installer Commands:" -Color Green
            $sortedItems = $methodGroup.Group | Sort-Object RuntimeType, { [version]$_.FullVersion }
            foreach ($item in $sortedItems) {
                Write-LogMessage "# Uninstall $($item.RuntimeType) $($item.FullVersion)" -Color DarkGray
                Write-LogMessage "$($item.UninstallCommand)" -Color Green
            }
        } else {
            Write-LogMessage "Directory Removal Commands:" -Color Yellow
            $sortedItems = $methodGroup.Group | Sort-Object RuntimeType, { [version]$_.FullVersion }
            foreach ($item in $sortedItems) {
                Write-LogMessage "# Remove $($item.RuntimeType) $($item.FullVersion)" -Color DarkGray
                Write-LogMessage "$($item.UninstallCommand)" -Color Green
            }
        }
        Write-LogMessage ""
    }
}

Write-LogMessage ""
Write-LogMessage "Analysis completed successfully!" -Color Green
