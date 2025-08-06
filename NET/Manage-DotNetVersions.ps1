param(
    [ValidateSet("8.0", "9.0")]
    [string]$TargetVersion = "8.0",
    
    [ValidateSet("Basic", "Standard", "Deep")]
    [string]$ScanDepth = "Standard",
    
    [bool]$ForceInstall = $false,
    
    [bool]$SkipHostingBundle = $false,
    
    [bool]$UseLatestPatch = $true,
    
    [bool]$SkipUpdate = $false,

    [switch]$Help
)

#region Setup and Initialization

# Create centralized directory structure
$centralDir = "C:\temp\NET"
$logsDir = Join-Path $centralDir "logs"
$backupDir = Join-Path $centralDir "backup"
$tempDir = Join-Path $centralDir "temp"

$directories = @($centralDir, $logsDir, $backupDir, $tempDir)
foreach ($dir in $directories) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created directory: $dir" -ForegroundColor Green
    }
}

# Check for Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin -and -not $SkipUpdate) {
    Write-Host "WARNING: Not running as Administrator" -ForegroundColor Yellow
    Write-Host "Some operations (like Hosting Bundle installation) may fail without admin rights." -ForegroundColor Yellow
    Write-Host "Consider running PowerShell as Administrator for best results." -ForegroundColor Yellow
    Write-Host ""
}

# Set up logging
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logsDir "manage-dotnet-$timestamp.log"

#endregion

#region Helper Functions

# Simple help function
function Show-Help {
    Write-Host ""
    Write-Host ".NET Management Tool - Help" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "FLAGS:" -ForegroundColor Cyan
    Write-Host "  -TargetVersion       Target .NET version (8.0, 9.0) [Default: 8.0]"
    Write-Host "  -ScanDepth           Scan depth (Basic, Standard, Deep) [Default: Standard]"
    Write-Host "  -ForceInstall        Force install even if already present [Default: false]"
    Write-Host "  -SkipHostingBundle   Skip hosting bundle installation [Default: false]"
    Write-Host "  -UseLatestPatch      Use latest patch version [Default: true]"
    Write-Host "  -SkipUpdate          Only scan, don't install anything [Default: false]"
    Write-Host "  -Help                Show this help"
    Write-Host ""
    
    Write-Host "EXAMPLES:" -ForegroundColor Cyan
    Write-Host "  .\Manage-DotNet.ps1"
    Write-Host "  .\Manage-DotNet.ps1 -TargetVersion '9.0'"
    Write-Host "  .\Manage-DotNet.ps1 -SkipUpdate `$true"
    Write-Host "  .\Manage-DotNet.ps1 -ScanDepth 'Deep' -TargetVersion '8.0'"
    Write-Host "  .\Manage-DotNet.ps1 -ForceInstall `$true"
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

# Function to format .NET version from string
function Format-DotNetVersion {
    param ([string]$versionString)
    
    if ($versionString -match "(\d+\.\d+\.\d+)") {
        return $matches[1]
    }
    return $versionString
}

# Improved package detection - faster alternative to Win32_Product
function Get-DotNetPackagesFast {
    try {
        $dotNetPackages = @()
        
        # Check both 32-bit and 64-bit registry locations
        $uninstallKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        
        foreach ($keyPath in $uninstallKeys) {
            try {
                Get-ItemProperty $keyPath -ErrorAction SilentlyContinue | 
                    Where-Object { 
                        $_.DisplayName -match "\.NET|ASP\.NET|dotnet" -and
                        $_.DisplayName -ne $null -and
                        $_.DisplayVersion -ne $null
                    } | 
                    ForEach-Object {
                        $dotNetPackages += [PSCustomObject]@{
                            Name = $_.DisplayName
                            Version = $_.DisplayVersion
                            Publisher = $_.Publisher
                            InstallDate = $_.InstallDate
                        }
                    }
            } catch {
                Write-LogMessage "Warning: Could not read registry key $keyPath" -Level "WARN" -Color Yellow
            }
        }
        
        # Remove duplicates based on Name and Version
        $uniquePackages = $dotNetPackages | 
            Group-Object Name, Version | 
            ForEach-Object { $_.Group | Select-Object -First 1 }
        
        Write-LogMessage "Found $($uniquePackages.Count) .NET package(s)" -Color Green
        return $uniquePackages
        
    } catch {
        Write-LogMessage "Error retrieving .NET packages: $_" -Level "ERROR" -Color Red
        return @()
    }
}

# Helper function to get IIS application pools - FIXED
function Get-IISApplicationPools {
    try {
        # Check if IIS service exists first
        $iisService = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
        if (-not $iisService) {
            return @()
        }

        # Try to import WebAdministration module
        $webAdminModule = Get-Module -ListAvailable -Name "WebAdministration" -ErrorAction SilentlyContinue
        if (-not $webAdminModule) {
            return @()
        }
        
        Import-Module WebAdministration -ErrorAction Stop
        
        # Check if IIS:\AppPools drive is available
        if (-not (Test-Path "IIS:\AppPools" -ErrorAction SilentlyContinue)) {
            return @()
        }
        
        $appPools = Get-ChildItem IIS:\AppPools | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                State = $_.State
                ManagedRuntimeVersion = $_.managedRuntimeVersion
                ManagedPipelineMode = $_.managedPipelineMode
            }
        }
        Write-LogMessage "Found $($appPools.Count) IIS application pool(s)" -Color Green
        return $appPools
        
    } catch {
        return @()
    }
}

# Improved deep scan with better performance and safety
function Get-ApplicationReferencesImproved {
    param([int]$MaxFiles = 500)
    
    # Define focused search paths
    $searchPaths = @(
        "C:\inetpub\wwwroot",
        "C:\inetpub\vhosts", 
        "$env:ProgramFiles\IIS Express",
        "$env:USERPROFILE\source",
        "$env:USERPROFILE\Documents\Visual Studio*",
        "$env:USERPROFILE\Desktop\*Projects*"
    )
    
    # Add custom paths from environment variable
    if ($env:DOTNET_SCAN_PATHS) {
        $searchPaths += $env:DOTNET_SCAN_PATHS.Split(';') | Where-Object { $_ -ne "" }
    }
    
    # Filter and expand paths
    $validPaths = @()
    foreach ($path in $searchPaths) {
        try {
            if (Test-Path $path) {
                $validPaths += $path
            }
            # Handle wildcard paths
            $expandedPaths = Get-ChildItem $path -Directory -ErrorAction SilentlyContinue | 
                             Select-Object -First 10 -ExpandProperty FullName
            $validPaths += $expandedPaths
        } catch {
            # Skip invalid paths silently
        }
    }
    
    $references = @()
    $fileCount = 0
    
    foreach ($path in $validPaths) {
        if ($fileCount -ge $MaxFiles) {
            Write-LogMessage "Reached maximum file limit ($MaxFiles), stopping scan" -Color Yellow
            break
        }
        
        try {
            # More targeted file search with size and depth limits
            $configs = Get-ChildItem -Path $path -Recurse -Depth 3 -Include @(
                'web.config', 'app.config', '*.csproj', '*.vbproj', '*.fsproj',
                'project.json', 'global.json', '*.sln'
            ) -ErrorAction SilentlyContinue | 
            Where-Object { 
                $_.Length -lt 2MB -and 
                $_.Name -notlike "*packages*" -and
                $_.Directory.Name -notlike "*node_modules*"
            } | 
            Select-Object -First ([Math]::Min(50, $MaxFiles - $fileCount))
            
            foreach ($config in $configs) {
                if ($fileCount -ge $MaxFiles) { break }
                
                try {
                    $content = Get-Content $config.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    
                    if ($content) {
                        # More comprehensive regex for .NET version detection
                        $patterns = @(
                            'TargetFramework[^>]*>(net\d+\.\d+)',
                            'TargetFramework[^>]*>(netcoreapp\d+\.\d+)',
                            'TargetFramework[^>]*>(netstandard\d+\.\d+)',
                            'version="(\d+\.\d+\.\d+)".*Microsoft\.NetCore',
                            'Microsoft\.AspNetCore.*Version="(\d+\.\d+\.\d+)"'
                        )
                        
                        foreach ($pattern in $patterns) {
                            if ($content -match $pattern) {
                                $dotNetVersion = $matches[1]
                                $references += [PSCustomObject]@{
                                    Path = $config.FullName
                                    FileName = $config.Name
                                    DotNetReference = $dotNetVersion
                                    FileType = $config.Extension
                                    LastModified = $config.LastWriteTime
                                }
                                break
                            }
                        }
                    }
                    $fileCount++
                } catch {
                    # Skip files that can't be read
                }
            }
        } catch {
            # Skip paths that can't be accessed
        }
    }
    
    # Remove duplicates and sort by path
    $uniqueReferences = $references | 
        Group-Object Path | 
        ForEach-Object { $_.Group | Select-Object -First 1 } |
        Sort-Object Path
    
    Write-LogMessage "Found $($uniqueReferences.Count) application reference(s) (scanned $fileCount files)" -Color Green
    return $uniqueReferences
}

# Helper function to check if IIS is present
function Test-IISPresent {
    try {
        # Check if IIS service exists
        $iisService = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
        if ($iisService) {
            return $true
        }
        
        # Check if IIS features are installed (alternative method)
        try {
            $iisFeature = Get-WindowsFeature -Name "IIS-WebServer" -ErrorAction SilentlyContinue
            if ($iisFeature -and $iisFeature.InstallState -eq "Installed") {
                return $true
            }
        } catch {
            # Get-WindowsFeature not available on all systems
        }
        
        # Check if IIS directory exists
        if (Test-Path "C:\inetpub" -ErrorAction SilentlyContinue) {
            return $true
        }
        
        return $false
    } catch {
        return $false
    }
}

#endregion

#region Core Inventory Functions

# Function to perform comprehensive .NET inventory
function Get-DotNetInventory {
    param([string]$ScanDepth)
    
    Write-LogMessage "Starting .NET inventory scan (Depth: $ScanDepth)..." -Color Cyan
    
    # Initialize inventory report
    $inventory = @{
        "ComputerName" = $env:COMPUTERNAME
        "ScanDate" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "ScanDepth" = $ScanDepth
        "DotNetSDKs" = @()
        "DotNetRuntimes" = @()
        "DotNetFramework" = @()
        "RunningProcesses" = @()
        "ApplicationReferences" = @()
        "IISApplicationPools" = @()
        "InstalledPackages" = @()
        "Summary" = @{}
    }

    # Get installed SDKs
    try {
        $sdkOutput = & dotnet --list-sdks 2>$null
        if ($sdkOutput) {
            $inventory.DotNetSDKs = $sdkOutput | ForEach-Object {
                if ($_ -match "(\d+\.\d+\.\d+).*\[(.*)\]") {
                    [PSCustomObject]@{
                        Version = $matches[1]
                        Path = $matches[2]
                        MajorVersion = $matches[1].Split('.')[0]
                        MinorVersion = $matches[1].Split('.')[1]
                    }
                } else {
                    [PSCustomObject]@{
                        Version = $_
                        Path = "Unknown"
                        MajorVersion = "Unknown"
                        MinorVersion = "Unknown"
                    }
                }
            }
            Write-LogMessage "Found $($inventory.DotNetSDKs.Count) SDK(s)" -Color Green
        }
    } catch {
        Write-LogMessage "Error retrieving .NET SDKs: $_" -Level "ERROR" -Color Red
    }

    # Get installed runtimes
    try {
        $runtimeOutput = & dotnet --list-runtimes 2>$null
        if ($runtimeOutput) {
            $inventory.DotNetRuntimes = $runtimeOutput | ForEach-Object {
                if ($_ -match "(Microsoft\..*?) (\d+\.\d+\.\d+).*\[(.*)\]") {
                    [PSCustomObject]@{
                        Type = $matches[1]
                        Version = $matches[2]
                        Path = $matches[3]
                        MajorVersion = $matches[2].Split('.')[0]
                        MinorVersion = $matches[2].Split('.')[1]
                    }
                } else {
                    [PSCustomObject]@{
                        Type = "Unknown"
                        Version = $_
                        Path = "Unknown"
                        MajorVersion = "Unknown"
                        MinorVersion = "Unknown"
                    }
                }
            }
            Write-LogMessage "Found $($inventory.DotNetRuntimes.Count) runtime(s)" -Color Green
        }
    } catch {
        Write-LogMessage "Error retrieving .NET runtimes: $_" -Level "ERROR" -Color Red
    }

    # Add .NET Framework versions from registry
    try {
        $ndpKey = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP" -Recurse | 
            Get-ItemProperty -Name Version, Release -ErrorAction SilentlyContinue

        $inventory.DotNetFramework = $ndpKey | Where-Object { $_.Version -ne $null } | ForEach-Object {
            $versionValue = $_.Version
            $releaseKey = if ($_.Release -ne $null) { $_.Release } else { 0 }
            
            # Determine .NET Framework version based on release key value
            $version = switch ($releaseKey) {
                { $_ -ge 533320 } { ".NET Framework 4.8.1" }
                { $_ -ge 528040 } { ".NET Framework 4.8" }
                { $_ -ge 461808 } { ".NET Framework 4.7.2" }
                { $_ -ge 461308 } { ".NET Framework 4.7.1" }
                { $_ -ge 460798 } { ".NET Framework 4.7" }
                { $_ -ge 394802 } { ".NET Framework 4.6.2" }
                { $_ -ge 394254 } { ".NET Framework 4.6.1" }
                { $_ -ge 393295 } { ".NET Framework 4.6" }
                { $_ -ge 379893 } { ".NET Framework 4.5.2" }
                { $_ -ge 378675 } { ".NET Framework 4.5.1" }
                { $_ -ge 378389 } { ".NET Framework 4.5" }
                default { "Version $versionValue (Release $releaseKey)" }
            }
            
            [PSCustomObject]@{
                Version = $versionValue
                Release = $releaseKey
                VersionName = $version
                Path = $_.PSPath
            }
        }
        Write-LogMessage "Found $($inventory.DotNetFramework.Count) .NET Framework version(s)" -Color Green
    } catch {
        Write-LogMessage "Error retrieving .NET Framework versions: $_" -Level "ERROR" -Color Red
    }

    # Check for .NET packages using improved registry method
    $inventory.InstalledPackages = Get-DotNetPackagesFast

    # Standard and Deep scans: check running processes
    if ($ScanDepth -in "Standard", "Deep") {
        try {
            $processes = Get-Process | Where-Object { 
                $proc = $_
                try {
                    $modules = $proc.Modules | Where-Object { 
                        $_.FileName -match "aspnet|dotnet|clr|mscor"
                    }
                    return $modules -ne $null -and $modules.Count -gt 0
                } catch {
                    return $false
                }
            } | ForEach-Object {
                $proc = $_
                $netModules = try {
                    $proc.Modules | Where-Object { 
                        $_.FileName -match "aspnet|dotnet|clr|mscor"
                    } | Select-Object -First 5 | ForEach-Object { $_.FileName }
                } catch {
                    @("Unable to enumerate modules")
                }

                [PSCustomObject]@{
                    ProcessName = $proc.ProcessName
                    Id = $proc.Id
                    StartTime = if ($proc.StartTime) { $proc.StartTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "Unknown" }
                    NetModules = $netModules -join ", "
                }
            }

            $inventory.RunningProcesses = $processes
            Write-LogMessage "Found $($inventory.RunningProcesses.Count) .NET process(es)" -Color Green
        } catch {
            Write-LogMessage "Error checking running processes: $_" -Level "ERROR" -Color Red
            $inventory.RunningProcesses = @()
        }

        # Check for IIS application pools
        $inventory.IISApplicationPools = Get-IISApplicationPools
    } else {
        # For Basic scan, initialize empty arrays
        $inventory.RunningProcesses = @()
        $inventory.IISApplicationPools = @()
    }

    # Deep scan: check for application references
    if ($ScanDepth -eq "Deep") {
        $inventory.ApplicationReferences = Get-ApplicationReferencesImproved
    } else {
        $inventory.ApplicationReferences = @()
    }

    # Create summary
    $versionCounts = @{}
    $inventory.DotNetRuntimes | ForEach-Object {
        $version = $_.MajorVersion
        if ($versionCounts.ContainsKey($version)) {
            $versionCounts[$version]++
        } else {
            $versionCounts[$version] = 1
        }
    }

    $inventory.Summary = @{
        "SDKCount" = $inventory.DotNetSDKs.Count
        "RuntimeCount" = $inventory.DotNetRuntimes.Count
        "FrameworkCount" = $inventory.DotNetFramework.Count
        "PackageCount" = $inventory.InstalledPackages.Count
        "RunningProcessCount" = $inventory.RunningProcesses.Count
        "ApplicationReferenceCount" = $inventory.ApplicationReferences.Count
        "IISAppPoolCount" = $inventory.IISApplicationPools.Count
        "VersionCounts" = $versionCounts
    }

    return $inventory
}

# Function to detect installed .NET components for updates
function Get-InstalledDotNetComponents {
    Write-LogMessage "Detecting installed .NET components for update analysis..." -Color Cyan
    
    $components = @{
        "Runtime" = @()
        "AspNetCore" = @()
        "WindowsDesktop" = @()
        "HostingBundle" = @()
    }
    
    # PRIMARY SOURCE: Check dotnet --list-runtimes command output
    try {
        $dotnetRuntimes = & dotnet --list-runtimes 2>$null
        
        foreach ($line in $dotnetRuntimes) {
            if ($line -match '([a-zA-Z\.]+) (\d+\.\d+\.\d+)') {
                $runtimeType = $matches[1]
                $version = $matches[2]
                
                # Parse out major.minor version
                if ($version -match '(\d+)\.(\d+)\.') {
                    $majorMinor = "$($matches[1]).$($matches[2])"
                    
                    # Categorize by component type
                    if ($runtimeType -eq "Microsoft.NETCore.App") {
                        $components.Runtime += [PSCustomObject]@{
                            Name = "Microsoft .NET Runtime $version"
                            Version = $version
                            MajorMinor = $majorMinor
                            Source = "DotNetCommand"
                        }
                    } elseif ($runtimeType -eq "Microsoft.AspNetCore.App") {
                        $components.AspNetCore += [PSCustomObject]@{
                            Name = "Microsoft ASP.NET Core $version"
                            Version = $version
                            MajorMinor = $majorMinor
                            Source = "DotNetCommand"
                        }
                    } elseif ($runtimeType -eq "Microsoft.WindowsDesktop.App") {
                        $components.WindowsDesktop += [PSCustomObject]@{
                            Name = "Microsoft Windows Desktop Runtime $version"
                            Version = $version
                            MajorMinor = $majorMinor
                            Source = "DotNetCommand"
                        }
                    }
                }
            }
        }
    } catch {
        Write-LogMessage "Could not execute dotnet --list-runtimes. Continuing with registry search." -Level "WARN" -Color Yellow
    }
    
    # SECONDARY SOURCE: Registry - for Hosting Bundles
    try {
        $dotNetPackages = Get-DotNetPackagesFast
        
        # Process hosting bundles from registry
        foreach ($package in $dotNetPackages) {
            $name = $package.Name
            $version = $package.Version
            
            # Only process hosting bundles
            if ($name -match "Hosting Bundle|Server Hosting") {
                # Validate version format
                if ($version -match '(\d+)\.(\d+)\.(\d+)') {
                    $major = [int]$matches[1]
                    $minor = [int]$matches[2]
                    
                    # Only accept reasonable .NET versions (3-12 range)
                    if ($major -ge 3 -and $major -le 12) {
                        $majorMinor = "$major.$minor"
                        $components.HostingBundle += [PSCustomObject]@{
                            Name = $name
                            Version = $version
                            MajorMinor = $majorMinor
                            Source = "Registry"
                        }
                    }
                }
            }
        }
    } catch {
        Write-LogMessage "Warning: Could not query registry for hosting bundles: $_" -Level "WARN" -Color Yellow
    }
    
    return $components
}

#endregion

#region Dynamic Version Detection Functions

# FUTURE-PROOF: Get latest available version using multiple sources
function Get-LatestAvailableVersion {
    param([string]$MajorMinor)
    
    Write-LogMessage "Fetching latest .NET $MajorMinor version from multiple sources..." -Color Cyan
    
    # Source 1: Try GitHub Releases API (most reliable)
    $latestVersion = Get-LatestVersionFromGitHub -MajorMinor $MajorMinor
    if ($latestVersion) {
        Write-LogMessage "Latest .NET $MajorMinor from GitHub: $latestVersion" -Color Green
        return $latestVersion
    }
    
    # Source 2: Try NuGet API 
    $latestVersion = Get-LatestVersionFromNuGet -MajorMinor $MajorMinor
    if ($latestVersion) {
        Write-LogMessage "Latest .NET $MajorMinor from NuGet: $latestVersion" -Color Green
        return $latestVersion
    }
    
    # Source 3: Try Microsoft Releases API
    $latestVersion = Get-LatestVersionFromMicrosoftAPI -MajorMinor $MajorMinor
    if ($latestVersion) {
        Write-LogMessage "Latest .NET $MajorMinor from Microsoft API: $latestVersion" -Color Green
        return $latestVersion
    }
    
    # Source 4: Try scraping download page
    $latestVersion = Get-LatestVersionFromDownloadPage -MajorMinor $MajorMinor
    if ($latestVersion) {
        Write-LogMessage "Latest .NET $MajorMinor from download page: $latestVersion" -Color Green
        return $latestVersion
    }
    
    Write-LogMessage "Could not determine latest .NET $MajorMinor version from any source" -Level "ERROR" -Color Red
    return $null
}

# Get latest version from GitHub releases API
function Get-LatestVersionFromGitHub {
    param([string]$MajorMinor)
    
    try {
        $githubUrl = "https://api.github.com/repos/dotnet/core/releases"
        $headers = @{
            'User-Agent' = 'PowerShell .NET Management Script'
            'Accept' = 'application/vnd.github.v3+json'
        }
        
        $response = Invoke-WebRequest -Uri $githubUrl -Headers $headers -UseBasicParsing -TimeoutSec 30
        $releases = ($response.Content | ConvertFrom-Json)
        
        # Find latest release for the target major.minor version
        foreach ($release in $releases) {
            $tagName = $release.tag_name
            if ($tagName -match "v(\d+\.\d+\.\d+)$") {
                $version = $matches[1]
                if ($version -like "$MajorMinor.*") {
                    Write-LogMessage "Found version $version in GitHub releases" -Color DarkGray
                    return $version
                }
            }
        }
        
        return $null
    } catch {
        Write-LogMessage "GitHub API failed: $_" -Level "WARN" -Color Yellow
        return $null
    }
}

# Get latest version from NuGet API
function Get-LatestVersionFromNuGet {
    param([string]$MajorMinor)
    
    try {
        $nugetUrl = "https://api.nuget.org/v3-flatcontainer/microsoft.netcore.app/index.json"
        $response = Invoke-WebRequest -Uri $nugetUrl -UseBasicParsing -TimeoutSec 30
        $versions = ($response.Content | ConvertFrom-Json).versions
        
        # Filter for target major.minor and get latest
        $targetVersions = $versions | Where-Object { $_ -like "$MajorMinor.*" } | 
                         ForEach-Object { [version]$_ } | Sort-Object -Descending
        
        if ($targetVersions.Count -gt 0) {
            $latest = $targetVersions[0].ToString()
            Write-LogMessage "Found version $latest in NuGet API" -Color DarkGray
            return $latest
        }
        
        return $null
    } catch {
        Write-LogMessage "NuGet API failed: $_" -Level "WARN" -Color Yellow
        return $null
    }
}

# Get latest version from Microsoft releases API
function Get-LatestVersionFromMicrosoftAPI {
    param([string]$MajorMinor)
    
    try {
        $msftUrl = "https://api.dotnetfoundation.org/releases/core/current"
        $response = Invoke-WebRequest -Uri $msftUrl -UseBasicParsing -TimeoutSec 30
        $data = ($response.Content | ConvertFrom-Json)
        
        # Look for our target version in the releases
        foreach ($release in $data.releases) {
            if ($release.version -like "$MajorMinor.*") {
                Write-LogMessage "Found version $($release.version) in Microsoft API" -Color DarkGray
                return $release.version
            }
        }
        
        return $null
    } catch {
        Write-LogMessage "Microsoft API failed: $_" -Level "WARN" -Color Yellow
        return $null
    }
}

# Get latest version by scraping download page
function Get-LatestVersionFromDownloadPage {
    param([string]$MajorMinor)
    
    try {
        $downloadUrl = "https://dotnet.microsoft.com/en-us/download/dotnet/$MajorMinor"
        $headers = @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        }
        
        $response = Invoke-WebRequest -Uri $downloadUrl -Headers $headers -UseBasicParsing -TimeoutSec 30
        $content = $response.Content
        
        # Look for version patterns in the HTML
        $versionPattern = "$MajorMinor\.(\d+)"
        $matches = [regex]::Matches($content, $versionPattern)
        
        if ($matches.Count -gt 0) {
            # Get the highest patch version found
            $versions = $matches | ForEach-Object { [version]$_.Value } | Sort-Object -Descending
            $latest = $versions[0].ToString()
            Write-LogMessage "Found version $latest in download page" -Color DarkGray
            return $latest
        }
        
        return $null
    } catch {
        Write-LogMessage "Download page scraping failed: $_" -Level "WARN" -Color Yellow
        return $null
    }
}

# FUTURE-PROOF: Dynamically discover hosting bundle download URLs
function Get-HostingBundleUrls {
    param(
        [string]$TargetVersion,
        [string]$LatestPatchVersion
    )
    
    Write-LogMessage "Discovering hosting bundle URLs for .NET $LatestPatchVersion..." -Color Cyan
    
    $discoveredUrls = @()
    
    # Method 1: Try common CDN patterns
    $cdnPatterns = @(
        "https://download.visualstudio.microsoft.com/download/pr/*/dotnet-hosting-$LatestPatchVersion-win.exe",
        "https://dotnetcli.azureedge.net/dotnet/aspnetcore/Runtime/$LatestPatchVersion/dotnet-hosting-$LatestPatchVersion-win.exe"
    )
    
    foreach ($pattern in $cdnPatterns) {
        $url = $pattern -replace '\*', '*'  # Placeholder for dynamic discovery
        
        # For azureedge.net, we can construct the URL directly
        if ($pattern -like "*azureedge.net*") {
            $directUrl = "https://dotnetcli.azureedge.net/dotnet/aspnetcore/Runtime/$LatestPatchVersion/dotnet-hosting-$LatestPatchVersion-win.exe"
            $discoveredUrls += $directUrl
            Write-LogMessage "Added constructed URL: $directUrl" -Color DarkGray
        }
    }
    
    # Method 2: Try to discover actual download.visualstudio.microsoft.com URLs
    $vsUrls = Get-VisualStudioDownloadUrls -TargetVersion $TargetVersion -LatestPatchVersion $LatestPatchVersion
    $discoveredUrls += $vsUrls
    
    # Method 3: Fallback to scraping download page for direct links
    $pageUrls = Get-HostingBundleUrlsFromDownloadPage -TargetVersion $TargetVersion
    $discoveredUrls += $pageUrls
    
    # Remove duplicates and return
    $uniqueUrls = $discoveredUrls | Sort-Object -Unique
    Write-LogMessage "Discovered $($uniqueUrls.Count) hosting bundle URLs" -Color Green
    return $uniqueUrls
}

# Try to get Visual Studio download URLs
function Get-VisualStudioDownloadUrls {
    param(
        [string]$TargetVersion,
        [string]$LatestPatchVersion
    )
    
    try {
        # This is harder to discover dynamically, but we can try some heuristics
        # Visual Studio download URLs often follow patterns, but the hash part is unpredictable
        
        # For now, we'll try a few common patterns and test if they exist
        $possibleHashes = @(
            # These would need to be discovered through other means or updated occasionally
            # But much less frequently than every patch release
        )
        
        $urls = @()
        # We'll rely on the azureedge.net URL pattern for now as it's more predictable
        return $urls
    } catch {
        Write-LogMessage "Could not discover Visual Studio download URLs: $_" -Level "WARN" -Color Yellow
        return @()
    }
}

# Get hosting bundle URLs from download page
function Get-HostingBundleUrlsFromDownloadPage {
    param([string]$TargetVersion)
    
    try {
        $downloadUrl = "https://dotnet.microsoft.com/en-us/download/dotnet/$TargetVersion"
        $headers = @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        }
        
        $response = Invoke-WebRequest -Uri $downloadUrl -Headers $headers -UseBasicParsing -TimeoutSec 30
        $content = $response.Content
        
        # Look for hosting bundle download links
        $hostingBundlePattern = 'href="([^"]*hosting[^"]*\.exe)"'
        $matches = [regex]::Matches($content, $hostingBundlePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        
        $urls = @()
        foreach ($match in $matches) {
            $url = $match.Groups[1].Value
            if ($url -notmatch '^https?://') {
                # Handle relative URLs
                $url = "https://dotnet.microsoft.com" + $url
            }
            $urls += $url
            Write-LogMessage "Found hosting bundle URL in download page: $url" -Color DarkGray
        }
        
        return $urls
    } catch {
        Write-LogMessage "Could not scrape hosting bundle URLs from download page: $_" -Level "WARN" -Color Yellow
        return @()
    }
}

#endregion

#region Update Analysis Functions

function Test-UpgradeNeeded {
    param(
        [string]$TargetVersion,
        [hashtable]$InstalledComponents,
        [bool]$ForceInstall = $false
    )
    
    Write-LogMessage "Analyzing installed versions for upgrade needs..." -Color Cyan
    
    # Define EOL (End of Life) versions - anything below 8.0 is EOL
    $eolThreshold = [version]"8.0.0"
    
    # Get the latest available version for comparison
    $latestAvailable = Get-LatestAvailableVersion -MajorMinor $TargetVersion
    $latestAvailableVersion = if ($latestAvailable) { [version]$latestAvailable } else { $null }
    
    if ($ForceInstall) {
        Write-LogMessage "Force mode: Will install missing components and update existing ones" -Color Yellow
    } else {
        Write-LogMessage "Conservative mode: Will upgrade EOL versions and patch existing supported versions" -Color DarkGray
    }
    
    $needsUpgrade = $false
    $upgradeReasons = @()
    $componentsNeedingUpgrade = @()
    
    # Check each component type
    $componentTypes = @("Runtime", "AspNetCore", "WindowsDesktop", "HostingBundle")
    
    foreach ($type in $componentTypes) {
        $installedVersions = $InstalledComponents.$type
        
        if ($installedVersions.Count -eq 0) {
            # Component is not installed
            if ($ForceInstall) {
                # Force mode: Install missing components
                Write-LogMessage "$type - Not installed, will install (force mode)" -Color Yellow
                $needsUpgrade = $true
                $upgradeReasons += "$type (not installed - force mode)"
                $componentsNeedingUpgrade += $type
            } else {
                # Conservative mode: Skip missing components
                Write-LogMessage "$type - Not installed, skipping (conservative mode)" -Color Green
            }
            continue
        }
        
        # Component IS installed - analyze upgrade needs
        $highestInstalled = $null
        $hasTargetMajorMinor = $false
        $hasEolVersion = $false
        
        foreach ($component in $installedVersions) {
            try {
                $version = [version]$component.Version
                $componentMajorMinor = "$($version.Major).$($version.Minor)"
                
                # Check if we have the target major.minor version
                if ($componentMajorMinor -eq $TargetVersion) {
                    $hasTargetMajorMinor = $true
                }
                
                # Check if any installed version is EOL
                if ($version -lt $eolThreshold) {
                    $hasEolVersion = $true
                }
                
                # Track highest version
                if ($null -eq $highestInstalled -or $version -gt $highestInstalled) {
                    $highestInstalled = $version
                }
            } catch {
                # Skip invalid versions
            }
        }
        
        if ($null -ne $highestInstalled) {
            $targetMajorMinor = [version]"$TargetVersion.0"
            
            Write-LogMessage "$type - Highest installed: $highestInstalled, Target: $TargetVersion.x" -Color White
            
            # Priority 1: Check for EOL versions that need upgrading (both conservative and force mode)
            if ($hasEolVersion -and $highestInstalled -lt $eolThreshold) {
                Write-LogMessage "EOL version detected ($($highestInstalled.Major).$($highestInstalled.Minor)) - upgrading to $TargetVersion" -Color Yellow
                $needsUpgrade = $true
                $upgradeReasons += "$type (EOL version upgrade from $($highestInstalled.Major).$($highestInstalled.Minor) to $TargetVersion)"
                $componentsNeedingUpgrade += $type
            }
            # Priority 2: Same major.minor as target - check for patch updates
            elseif ($highestInstalled.Major -eq $targetMajorMinor.Major -and 
                    $highestInstalled.Minor -eq $targetMajorMinor.Minor) {
                
                # Compare against latest available version if we have it
                if ($null -ne $latestAvailableVersion -and $highestInstalled -lt $latestAvailableVersion) {
                    Write-LogMessage "Patch update available from $highestInstalled to $latestAvailableVersion" -Color Yellow
                    $needsUpgrade = $true
                    $upgradeReasons += "$type (patch update from $highestInstalled to $latestAvailableVersion)"
                    $componentsNeedingUpgrade += $type
                } else {
                    Write-LogMessage "Already have latest $TargetVersion patch version ($highestInstalled)" -Color Green
                }
            }
            # Priority 3: Newer version than target - no downgrade
            elseif ($highestInstalled.Major -gt $targetMajorMinor.Major -or 
                    ($highestInstalled.Major -eq $targetMajorMinor.Major -and $highestInstalled.Minor -gt $targetMajorMinor.Minor)) {
                
                Write-LogMessage "Already have newer version ($($highestInstalled.Major).$($highestInstalled.Minor)) than target ($TargetVersion) - no downgrade" -Color Green
            }
            # Priority 4: Older supported version (8.0+ but not target version)
            else {
                if ($ForceInstall) {
                    Write-LogMessage "Supported version upgrade from $($highestInstalled.Major).$($highestInstalled.Minor) to $TargetVersion (force mode)" -Color Yellow
                    $needsUpgrade = $true
                    $upgradeReasons += "$type (supported version upgrade - force mode)"
                    $componentsNeedingUpgrade += $type
                } else {
                    Write-LogMessage "Have supported version ($($highestInstalled.Major).$($highestInstalled.Minor)) - skipping upgrade in conservative mode" -Color Green
                    Write-LogMessage "To upgrade from $($highestInstalled.Major).$($highestInstalled.Minor) to $TargetVersion, use -ForceInstall `$true" -Color DarkGray
                }
            }
        }
    }
    
    return @{
        NeedsUpgrade = $needsUpgrade
        Reasons = $upgradeReasons
        ComponentsNeedingUpgrade = $componentsNeedingUpgrade
        LatestAvailableVersion = $latestAvailable
    }
}

#endregion

#region Installation Functions

# Function to backup current version information
function Backup-CurrentVersions {
    param([string]$BackupDir)
    
    Write-LogMessage "Creating backup of current .NET version information..." -Color Cyan
    
    try {
        $backupFile = Join-Path $BackupDir "dotnet-versions-backup-$timestamp.json"
        
        $currentVersions = @{
            "BackupDate" = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            "ComputerName" = $env:COMPUTERNAME
            "SDKs" = @()
            "Runtimes" = @()
        }
        
        # Get current SDKs
        $sdkOutput = & dotnet --list-sdks 2>$null
        if ($sdkOutput) {
            $currentVersions.SDKs = $sdkOutput
        }
        
        # Get current runtimes
        $runtimeOutput = & dotnet --list-runtimes 2>$null
        if ($runtimeOutput) {
            $currentVersions.Runtimes = $runtimeOutput
        }
        
        $currentVersions | ConvertTo-Json -Depth 3 | Out-File -FilePath $backupFile -Force -Encoding UTF8
        Write-LogMessage "Backup saved to: $backupFile" -Color Green
        return $backupFile
    } catch {
        Write-LogMessage "Warning: Could not create backup: $_" -Level "WARN" -Color Yellow
        return $null
    }
}

# Function to stop .NET processes that might interfere with installation
function Stop-DotNetProcesses {
    $processesToStop = @("dotnet", "w3wp", "iisexpress")
    $stoppedAny = $false
    
    foreach ($processName in $processesToStop) {
        $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
        if ($processes) {
            try {
                $processes | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                $stoppedAny = $true
            } catch {
                Write-LogMessage "Could not stop some $processName processes: $_" -Level "WARN" -Color Yellow
            }
        }
    }
    
    if ($stoppedAny) {
        Start-Sleep -Seconds 5
    }
}

# FUTURE-PROOF: Install hosting bundle with dynamic URL discovery
function Install-HostingBundle {
    param(
        [string]$TargetVersion,
        [string]$TempPath,
        [string]$LatestPatchVersion = $null
    )
    
    # If no patch version provided, get the latest
    if (-not $LatestPatchVersion) {
        $LatestPatchVersion = Get-LatestAvailableVersion -MajorMinor $TargetVersion
        if (-not $LatestPatchVersion) {
            Write-LogMessage "Could not determine latest patch version for .NET $TargetVersion" -Level "ERROR" -Color Red
            return $false
        }
    }
    
    # Dynamically discover hosting bundle URLs
    $urls = Get-HostingBundleUrls -TargetVersion $TargetVersion -LatestPatchVersion $LatestPatchVersion
    
    if ($urls.Count -eq 0) {
        Write-LogMessage "No hosting bundle URLs could be discovered for .NET $LatestPatchVersion" -Level "ERROR" -Color Red
        return $false
    }
    
    $maxRetries = 3
    $retryDelay = 5
    
    foreach ($url in $urls) {
        $fileName = "dotnet-hosting-$LatestPatchVersion-win.exe"
        $installerPath = Join-Path $TempPath $fileName
        $downloadSucceeded = $false
        
        Write-LogMessage "Trying download URL: $url" -Color Yellow
        
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                # Clean up any previous failed attempts
                if (Test-Path $installerPath) {
                    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                }
                
                $headers = @{
                    'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                }
                
                Invoke-WebRequest -Uri $url -OutFile $installerPath -Headers $headers -UseBasicParsing -TimeoutSec 300 -MaximumRedirection 5
                
                # Verify download
                if (-not (Test-Path $installerPath)) {
                    throw "Downloaded file is missing"
                }
                
                $fileSize = (Get-Item $installerPath).Length
                if ($fileSize -eq 0) {
                    throw "Downloaded file is empty"
                }
                
                if ($fileSize -lt 50MB) {
                    throw "Downloaded file is too small ($([math]::Round($fileSize/1MB, 2))MB) - likely incomplete"
                }
                
                Write-LogMessage "Download successful ($([math]::Round($fileSize/1MB, 2))MB)" -Color Green
                $downloadSucceeded = $true
                break
                
            } catch {
                Write-LogMessage "Download attempt $attempt failed: $($_.Exception.Message)" -Level "WARN" -Color Yellow
                
                if (Test-Path $installerPath) {
                    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                }
                
                if ($attempt -lt $maxRetries) {
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }
        
        # If download succeeded, try to install
        if ($downloadSucceeded -and (Test-Path $installerPath)) {
            try {
                if (-not $isAdmin) {
                    Write-LogMessage "Warning: Not running as Administrator - installation may fail" -Color Yellow
                }
                
                $logFile = "$TempPath\hosting-install.log"
                
                $process = Start-Process -FilePath $installerPath -ArgumentList "/install", "/quiet", "/norestart", "/log", $logFile -PassThru -Wait
                
                if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                    Write-LogMessage "Hosting Bundle $LatestPatchVersion installed successfully (Exit code: $($process.ExitCode))" -Color Green
                    
                    if (Test-Path $installerPath) {
                        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                    }
                    
                    return $true
                } else {
                    Write-LogMessage "Hosting Bundle installation failed with exit code $($process.ExitCode)" -Level "ERROR" -Color Red
                    
                    # Common exit code meanings
                    $exitCodeMeaning = switch ($process.ExitCode) {
                        1601 { "Windows Installer service could not be accessed" }
                        1602 { "User cancelled installation" }
                        1603 { "Fatal error during installation" }
                        1618 { "Another installation is already in progress" }
                        1619 { "Installation package could not be opened" }
                        1620 { "Installation package is invalid" }
                        1633 { "Installation package is not supported on this platform" }
                        3010 { "Installation succeeded but requires reboot" }
                        default { "Unknown exit code" }
                    }
                    Write-LogMessage "Exit code meaning: $exitCodeMeaning" -Color Red
                }
            }
            catch {
                Write-LogMessage "Hosting Bundle installation error: $_" -Level "ERROR" -Color Red
            }
            
            if (Test-Path $installerPath) {
                Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    Write-LogMessage "All hosting bundle download/install attempts failed" -Level "ERROR" -Color Red
    return $false
}

# Function to install .NET components using Microsoft's official script
function Install-DotNetComponents {
    param(
        [string]$TargetVersion,
        [hashtable]$DetectedComponents,
        [string]$TempPath,
        [array]$ComponentsNeedingUpgrade = @(),
        [bool]$SkipHostingBundle = $false,
        [string]$LatestPatchVersion = $null
    )
    
    Write-LogMessage "Installing .NET $TargetVersion components using Microsoft's official script..." -Color Green
    
    # Stop any processes that might interfere
    Stop-DotNetProcesses
    
    # Download the official install script
    $installScriptPath = Join-Path $TempPath "dotnet-install.ps1"
    $scriptUrl = "https://dot.net/v1/dotnet-install.ps1"
    
    try {
        $headers = @{
            'User-Agent' = 'PowerShell/7.0'
        }
        Invoke-WebRequest -Uri $scriptUrl -OutFile $installScriptPath -Headers $headers -UseBasicParsing -TimeoutSec 60
        
        Write-LogMessage "Script downloaded successfully" -Color Green
    }
    catch {
        Write-LogMessage "Failed to download dotnet-install.ps1: $_" -Level "ERROR" -Color Red
        return @{}
    }
    
    $installResults = @{}
    
    # Use standard global installation directory
    $globalInstallDir = "$env:ProgramFiles\dotnet"
    
    # Install components that need upgrading
    if ($ComponentsNeedingUpgrade -contains "Runtime") {
        Write-LogMessage "Installing .NET Runtime $TargetVersion..." -Color Yellow
        try {
            & $installScriptPath -Channel $TargetVersion -Runtime dotnet -InstallDir $globalInstallDir
            
            if ($LASTEXITCODE -eq 0) {
                Write-LogMessage ".NET Runtime installed successfully" -Color Green
                $installResults["Runtime"] = $true
            } else {
                Write-LogMessage ".NET Runtime installation failed (Exit code: $LASTEXITCODE)" -Level "ERROR" -Color Red
                $installResults["Runtime"] = $false
            }
        }
        catch {
            Write-LogMessage ".NET Runtime installation error: $_" -Level "ERROR" -Color Red
            $installResults["Runtime"] = $false
        }
    } else {
        Write-LogMessage "Skipping .NET Runtime - already have target version" -Color Green
    }
    
    if ($ComponentsNeedingUpgrade -contains "AspNetCore") {
        Write-LogMessage "Installing ASP.NET Core Runtime $TargetVersion..." -Color Yellow
        try {
            & $installScriptPath -Channel $TargetVersion -Runtime aspnetcore -InstallDir $globalInstallDir
            
            if ($LASTEXITCODE -eq 0) {
                Write-LogMessage "ASP.NET Core Runtime installed successfully" -Color Green
                $installResults["AspNetCore"] = $true
            } else {
                Write-LogMessage "ASP.NET Core Runtime installation failed (Exit code: $LASTEXITCODE)" -Level "ERROR" -Color Red
                $installResults["AspNetCore"] = $false
            }
        }
        catch {
            Write-LogMessage "ASP.NET Core Runtime installation error: $_" -Level "ERROR" -Color Red
            $installResults["AspNetCore"] = $false
        }
    } else {
        Write-LogMessage "Skipping ASP.NET Core Runtime - already have target version" -Color Green
    }
    
    if ($ComponentsNeedingUpgrade -contains "WindowsDesktop") {
        Write-LogMessage "Installing Windows Desktop Runtime $TargetVersion..." -Color Yellow
        try {
            & $installScriptPath -Channel $TargetVersion -Runtime windowsdesktop -InstallDir $globalInstallDir
            
            if ($LASTEXITCODE -eq 0) {
                Write-LogMessage "Windows Desktop Runtime installed successfully" -Color Green
                $installResults["WindowsDesktop"] = $true
            } else {
                Write-LogMessage "Windows Desktop Runtime installation failed (Exit code: $LASTEXITCODE)" -Level "ERROR" -Color Red
                $installResults["WindowsDesktop"] = $false
            }
        }
        catch {
            Write-LogMessage "Windows Desktop Runtime installation error: $_" -Level "ERROR" -Color Red
            $installResults["WindowsDesktop"] = $false
        }
    } else {
        Write-LogMessage "Skipping Windows Desktop Runtime - already have target version" -Color Green
    }
    
    # Handle Hosting Bundle separately with dynamic URL discovery
    if ($ComponentsNeedingUpgrade -contains "HostingBundle" -and -not $SkipHostingBundle) {
        Write-LogMessage "Installing .NET Hosting Bundle $TargetVersion..." -Color Yellow
        $hostingBundleResult = Install-HostingBundle -TargetVersion $TargetVersion -TempPath $TempPath -LatestPatchVersion $LatestPatchVersion
        $installResults["HostingBundle"] = $hostingBundleResult
    } elseif ($SkipHostingBundle) {
        Write-LogMessage "Skipping Hosting Bundle - SkipHostingBundle parameter set" -Color Yellow
    } else {
        Write-LogMessage "Skipping Hosting Bundle - already have target version" -Color Green
    }
    
    # Verify installations by checking if the runtimes are now available
    if ($installResults.Values -contains $true) {
        Write-LogMessage "Verifying installations..." -Color Cyan
        Start-Sleep -Seconds 3  # Give the system time to register the new installations
        
        try {
            $verifyRuntimes = & dotnet --list-runtimes 2>$null
            if ($verifyRuntimes) {
                $installedVersions = $verifyRuntimes | Where-Object { $_ -match $TargetVersion }
                if ($installedVersions) {
                    Write-LogMessage "Verification successful - .NET $TargetVersion runtimes are now available:" -Color Green
                    foreach ($runtime in $installedVersions) {
                        Write-LogMessage "  $runtime" -Color Green
                    }
                } else {
                    Write-LogMessage "Verification warning - .NET $TargetVersion runtimes not yet showing in dotnet --list-runtimes" -Color Yellow
                }
            }
        } catch {
            Write-LogMessage "Could not verify installation: $_" -Level "WARN" -Color Yellow
        }
    }
    
    return $installResults
}

#endregion

#region Comparison Functions

# Function to compare before and after inventories
function Compare-Inventories {
    param(
        [PSCustomObject]$BeforeInventory,
        [PSCustomObject]$AfterInventory
    )
    
    Write-LogMessage "Before vs After Comparison" -Color Green
    
    # Compare runtimes
    $beforeRuntimes = $BeforeInventory.DotNetRuntimes | ForEach-Object { "$($_.Type) $($_.Version)" }
    $afterRuntimes = $AfterInventory.DotNetRuntimes | ForEach-Object { "$($_.Type) $($_.Version)" }
    
    $newRuntimes = $afterRuntimes | Where-Object { $_ -notin $beforeRuntimes }
    $removedRuntimes = $beforeRuntimes | Where-Object { $_ -notin $afterRuntimes }
    
    if ($newRuntimes.Count -gt 0) {
        Write-LogMessage "New Runtimes Installed:" -Color Green
        foreach ($runtime in $newRuntimes) {
            Write-LogMessage "  + $runtime" -Color Green
        }
    }
    
    if ($removedRuntimes.Count -gt 0) {
        Write-LogMessage "Runtimes Removed:" -Color Red
        foreach ($runtime in $removedRuntimes) {
            Write-LogMessage "  - $runtime" -Color Red
        }
    }
    
    if ($newRuntimes.Count -eq 0 -and $removedRuntimes.Count -eq 0) {
        Write-LogMessage "No runtime changes detected" -Color Yellow
    }
    
    # Compare SDKs
    $beforeSDKs = $BeforeInventory.DotNetSDKs | ForEach-Object { $_.Version }
    $afterSDKs = $AfterInventory.DotNetSDKs | ForEach-Object { $_.Version }
    
    $newSDKs = $afterSDKs | Where-Object { $_ -notin $beforeSDKs }
    $removedSDKs = $beforeSDKs | Where-Object { $_ -notin $afterSDKs }
    
    if ($newSDKs.Count -gt 0) {
        Write-LogMessage "New SDKs Installed:" -Color Green
        foreach ($sdk in $newSDKs) {
            Write-LogMessage "  + SDK $sdk" -Color Green
        }
    }
    
    if ($removedSDKs.Count -gt 0) {
        Write-LogMessage "SDKs Removed:" -Color Red
        foreach ($sdk in $removedSDKs) {
            Write-LogMessage "  - SDK $sdk" -Color Red
        }
    }
    
    # Summary
    $totalChanges = $newRuntimes.Count + $removedRuntimes.Count + $newSDKs.Count + $removedSDKs.Count
    Write-LogMessage "Total Changes: $totalChanges" -Color Cyan
}

#endregion

#region Main Execution

# Check if help was requested
if ($Help) {
    Show-Help
    exit 0
}

# Main execution starts here
Write-LogMessage ".NET Management Tool" -Color Green
Write-LogMessage "Target Version: .NET $TargetVersion" -Color Cyan
Write-LogMessage "Scan Depth: $ScanDepth" -Color Cyan
Write-LogMessage "Force Install: $ForceInstall" -Color $(if ($ForceInstall) { "Yellow" } else { "White" })
Write-LogMessage "Skip Update: $SkipUpdate" -Color $(if ($SkipUpdate) { "Yellow" } else { "White" })
Write-LogMessage "Central Directory: $centralDir" -Color Cyan
Write-LogMessage "Log File: $logFile" -Color Cyan

# Step 1: Create initial inventory
Write-LogMessage "Creating initial .NET inventory..." -Color Green
$beforeInventory = Get-DotNetInventory -ScanDepth $ScanDepth

# Save initial inventory
$beforeInventoryPath = Join-Path $centralDir "DotNetInventory-Before-$timestamp.json"
$beforeInventory | ConvertTo-Json -Depth 5 | Out-File -FilePath $beforeInventoryPath -Force -Encoding UTF8
Write-LogMessage "Initial inventory saved to: $beforeInventoryPath" -Color Green

# Display initial summary
Write-LogMessage "Initial .NET Environment:" -Color Cyan
Write-LogMessage "Computer: $($beforeInventory.ComputerName)" -Color White
Write-LogMessage ".NET SDKs: $($beforeInventory.Summary.SDKCount)" -Color White
Write-LogMessage ".NET Runtimes: $($beforeInventory.Summary.RuntimeCount)" -Color White
Write-LogMessage ".NET Framework: $($beforeInventory.Summary.FrameworkCount)" -Color White

if ($ScanDepth -in "Standard", "Deep") {
    Write-LogMessage "Running .NET Processes: $($beforeInventory.Summary.RunningProcessCount)" -Color White
    if ($beforeInventory.Summary.IISAppPoolCount -gt 0) {
        Write-LogMessage "IIS Application Pools: $($beforeInventory.Summary.IISAppPoolCount)" -Color White
    }
}

if ($ScanDepth -eq "Deep") {
    Write-LogMessage "Application References: $($beforeInventory.Summary.ApplicationReferenceCount)" -Color White
}

# Initialize variables for tracking results
$script:successful = 0
$script:failed = 0
$backupFile = $null

# Step 2: Analyze what needs updating (if not skipping updates)
if (-not $SkipUpdate) {
    Write-LogMessage "Analyzing update requirements..." -Color Green
    
    # Create backup before making changes
    $backupFile = Backup-CurrentVersions -BackupDir $backupDir
    
    # Detect current components for update analysis
    $installedComponents = Get-InstalledDotNetComponents
    
    # Check if upgrade is needed (now returns latest version info)
    $upgradeAnalysis = Test-UpgradeNeeded -TargetVersion $TargetVersion -InstalledComponents $installedComponents -ForceInstall $ForceInstall
    
    if (-not $upgradeAnalysis.NeedsUpgrade -and -not $ForceInstall) {
        Write-LogMessage "No upgrade needed!" -Color Green
        Write-LogMessage "Your system already has .NET $TargetVersion or newer versions installed." -Color Green
        Write-LogMessage "Use -ForceInstall `$true to install .NET $TargetVersion regardless." -Color Yellow
        # Continue to Step 4 for optimized inventory handling
    }
    
    if ($upgradeAnalysis.NeedsUpgrade) {
        Write-LogMessage "Upgrade needed for: $($upgradeAnalysis.Reasons -join ', ')" -Color Yellow
    }
    
    # Display latest available version info
    if ($upgradeAnalysis.LatestAvailableVersion) {
        Write-LogMessage "Latest available .NET $TargetVersion version: $($upgradeAnalysis.LatestAvailableVersion)" -Color Green
    }
    
    # Step 3: Perform updates
    Write-LogMessage "Installing/updating .NET components..." -Color Green
    
    $installResults = Install-DotNetComponents -TargetVersion $TargetVersion -DetectedComponents $installedComponents -TempPath $tempDir -ComponentsNeedingUpgrade $upgradeAnalysis.ComponentsNeedingUpgrade -SkipHostingBundle $SkipHostingBundle -LatestPatchVersion $upgradeAnalysis.LatestAvailableVersion
    
    # Display installation summary
    Write-LogMessage "Installation Summary" -Color Green
    $script:successful = ($installResults.Values | Where-Object { $_ -eq $true }).Count
    $script:failed = ($installResults.Values | Where-Object { $_ -eq $false }).Count
    
    Write-LogMessage "Successfully installed: $script:successful components" -Color $(if($script:successful -gt 0) { "Green" } else { "White" })
    Write-LogMessage "Failed installations: $script:failed components" -Color $(if($script:failed -gt 0) { "Red" } else { "White" })
    
    if ($script:failed -gt 0) {
        Write-LogMessage "Some installations failed. Check the log file for details: $logFile" -Color Yellow
    }
    
    if ($script:successful -gt 0) {
        Write-LogMessage "Post-installation recommendations:" -Color Cyan
        Write-LogMessage "- IIS may need to be restarted for changes to take effect" -Color White
        Write-LogMessage "- Run 'iisreset' command if you have web applications" -Color White
        Write-LogMessage "- Restart any running applications that use .NET" -Color White
    }
} else {
    Write-LogMessage "Skipping updates (SkipUpdate = true)" -Color Yellow
}

# Step 4: Create final inventory (optimized)
$shouldCopyInventory = $false
$copyReason = ""

# Determine if we should copy the original inventory instead of re-scanning
if ($SkipUpdate) {
    $shouldCopyInventory = $true
    $copyReason = "No updates performed (SkipUpdate = true)"
} elseif ((Get-Variable -Name "upgradeAnalysis" -ErrorAction SilentlyContinue) -and -not $upgradeAnalysis.NeedsUpgrade) {
    $shouldCopyInventory = $true
    $copyReason = "No upgrades needed"
} elseif ($script:successful -eq 0 -and $script:failed -gt 0) {
    $shouldCopyInventory = $true
    $copyReason = "All installations failed - no changes made"
} elseif ($script:successful -eq 0 -and $script:failed -eq 0) {
    $shouldCopyInventory = $true
    $copyReason = "No installation attempts made"
}

if ($shouldCopyInventory) {
    Write-LogMessage "Copying original inventory (Reason: $copyReason)..." -Color Green
    
    try {
        # Copy the before inventory to after inventory
        $afterInventoryPath = Join-Path $centralDir "DotNetInventory-After-$timestamp.json"
        Copy-Item -Path $beforeInventoryPath -Destination $afterInventoryPath -Force
        
        # Load the copied inventory for use in comparisons
        $afterInventory = Get-Content -Path $afterInventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        
        Write-LogMessage "Inventory copied successfully (no re-scan needed)" -Color Green
    } catch {
        Write-LogMessage "Failed to copy inventory, falling back to full scan: $_" -Level "WARN" -Color Yellow
        Write-LogMessage "Creating final .NET inventory..." -Color Green
        $afterInventory = Get-DotNetInventory -ScanDepth $ScanDepth
        $afterInventoryPath = Join-Path $centralDir "DotNetInventory-After-$timestamp.json"
        $afterInventory | ConvertTo-Json -Depth 5 | Out-File -FilePath $afterInventoryPath -Force -Encoding UTF8
    }
} else {
    Write-LogMessage "Creating final .NET inventory..." -Color Green
    $afterInventory = Get-DotNetInventory -ScanDepth $ScanDepth
    $afterInventoryPath = Join-Path $centralDir "DotNetInventory-After-$timestamp.json"
    $afterInventory | ConvertTo-Json -Depth 5 | Out-File -FilePath $afterInventoryPath -Force -Encoding UTF8
    Write-LogMessage "Final inventory saved to: $afterInventoryPath" -Color Green
}

# Step 5: Compare before and after
if (-not $SkipUpdate -and -not $shouldCopyInventory) {
    Write-LogMessage "Comparing before and after..." -Color Green
    Compare-Inventories -BeforeInventory $beforeInventory -AfterInventory $afterInventory
}

# Final summary
Write-LogMessage "Final Summary" -Color Green

Write-LogMessage "Computer: $($afterInventory.ComputerName)" -Color White
Write-LogMessage "Completion Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color White
Write-LogMessage "Final .NET SDKs: $($afterInventory.Summary.SDKCount)" -Color White
Write-LogMessage "Final .NET Runtimes: $($afterInventory.Summary.RuntimeCount)" -Color White
Write-LogMessage "Final .NET Framework: $($afterInventory.Summary.FrameworkCount)" -Color White

if ($afterInventory.ScanDepth -in "Standard", "Deep") {
    Write-LogMessage "Final Running .NET Processes: $($afterInventory.Summary.RunningProcessCount)" -Color White
    if ($afterInventory.Summary.IISAppPoolCount -gt 0) {
        Write-LogMessage "Final IIS Application Pools: $($afterInventory.Summary.IISAppPoolCount)" -Color White
    }
}

if ($afterInventory.ScanDepth -eq "Deep") {
    Write-LogMessage "Final Application References: $($afterInventory.Summary.ApplicationReferenceCount)" -Color White
}

# Determine overall status
$overallStatus = "SUCCESS"
$statusColor = "Green"

if (-not $SkipUpdate) {
    if ($script:failed -gt 0 -and $script:successful -eq 0) {
        $overallStatus = "FAILED"
        $statusColor = "Red"
    } elseif ($script:failed -gt 0 -and $script:successful -gt 0) {
        $overallStatus = "PARTIAL SUCCESS"
        $statusColor = "Yellow"
    } elseif ($script:successful -eq 0) {
        $overallStatus = "NO CHANGES NEEDED"
        $statusColor = "Cyan"
    }
}

Write-LogMessage ".NET management completed with status: $overallStatus" -Color $statusColor

# Set exit code based on results
if ($overallStatus -eq "FAILED") {
    exit 1
} elseif ($overallStatus -eq "PARTIAL SUCCESS") {
    exit 2
} else {
    exit 0
}

#endregion