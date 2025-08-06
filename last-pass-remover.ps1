# LastPass Direct Removal Tool
# This script removes LastPass completely from your system

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$WhatIf = $false,

    [Parameter()]
    [string]$LogPath = "C:\temp\LastPassRemoval_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

# Create C:\temp directory if it doesn't exist
if (-not (Test-Path -Path "C:\temp")) {
    try {
        New-Item -Path "C:\temp" -ItemType Directory -Force | Out-Null
        Write-Host "Created log directory at C:\temp" -ForegroundColor Green
    } catch {
        Write-Host "Error creating C:\temp directory: $($_.Exception.Message)" -ForegroundColor Red
        $LogPath = "$env:TEMP\LastPassRemoval_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        Write-Host "Falling back to log path: $LogPath" -ForegroundColor Yellow
    }
}

# Initialize log file
try {
    $logHeader = "===== LastPass Removal =====" + [Environment]::NewLine +
                 "Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" + [Environment]::NewLine +
                 "Computer Name: $env:COMPUTERNAME" + [Environment]::NewLine +
                 "User Context: $env:USERNAME" + [Environment]::NewLine +
                 "WhatIf Mode: $WhatIf" + [Environment]::NewLine +
                 "========================================"

    Set-Content -Path $LogPath -Value $logHeader -ErrorAction Stop
    Write-Host "Log file initialized at: $LogPath" -ForegroundColor Cyan
} catch {
    Write-Host "Failed to initialize log file at $LogPath. Will log to console only." -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

# Logging function
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter()]
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White
    )

    # Get timestamp
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # Format log message
    $logMessage = "[$timestamp] $Message"

    # Always write to log file
    Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue

    # Write to console
    Write-Host $logMessage -ForegroundColor $ForegroundColor
}

# Locked item removal function
function Remove-LockedItem {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,

        [Parameter()]
        [switch]$IsDirectory = $false
    )

    # First try standard removal
    try {
        Remove-Item -Path $Path -Recurse:$IsDirectory -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Log "  - Standard removal failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Try .NET methods
    try {
        if ($IsDirectory) {
            [System.IO.Directory]::Delete($Path, $true)
        } else {
            [System.IO.File]::Delete($Path)
        }
        return $true
    } catch {
        Write-Log "  - .NET removal failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Try using handle.exe if available
    $handleTools = @(
        "C:\Tools\Handle.exe",
        "C:\Tools\Sysinternals\Handle.exe",
        "C:\Windows\System32\handle.exe",
        "${env:ProgramFiles}\Handle\handle.exe",
        "${env:ProgramFiles(x86)}\Handle\handle.exe"
    )

    $handleExe = $null
    foreach ($tool in $handleTools) {
        if (Test-Path $tool) {
            $handleExe = $tool
            break
        }
    }

    if ($handleExe) {
        Write-Log "  - Attempting to use Handle.exe to unlock file" -ForegroundColor Yellow
        try {
            $handleOutput = & $handleExe -a $Path 2>&1
            $handleLines = $handleOutput | Where-Object { $_ -match "pid: (\d+)\s.*\s$([regex]::Escape($Path))" }

            foreach ($line in $handleLines) {
                if ($line -match "pid: (\d+)") {
                    $pid = $matches[1]
                    Write-Log "  - Attempting to kill process $pid that is locking the file" -ForegroundColor Yellow
                    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                }
            }

            # Try removal again
            Remove-Item -Path $Path -Recurse:$IsDirectory -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Log "  - Handle.exe method failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    return $false
}

# Step 0: Stop LastPass processes
Write-Log "Step 0: Stopping LastPass processes..." -ForegroundColor Cyan

# Define LastPass process names to terminate
$lastPassProcesses = @(
    "LastPass",
    "LastPassBroker",
    "lpwinmetro",
    "lpass",
    "lastpass_ff",
    "lastpass_ff_x64",
    "lastpass_binary",
    "lastpass_binary_x64",
    "lastpassauthd",
    "LastPassAuthenticator"
)

# Track found processes
$foundProcesses = @()

# Search for LastPass processes
foreach ($processName in $lastPassProcesses) {
    $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue

    if ($processes) {
        foreach ($process in $processes) {
            $foundProcesses += $process
        }
    }
}

# Additional search for generic LastPass processes
$otherProcesses = Get-Process | Where-Object { 
    $_.Name -like "*lastpass*" -or $_.Name -like "*lpass*" 
}

if ($otherProcesses) {
    foreach ($process in $otherProcesses) {
        if ($foundProcesses.Id -notcontains $process.Id) {
            $foundProcesses += $process
        }
    }
}

# Process termination
if ($foundProcesses.Count -gt 0) {
    Write-Log "Found the following LastPass processes:" -ForegroundColor Cyan
    
    foreach ($process in $foundProcesses) {
        Write-Log "  - $($process.Name) (PID: $($process.Id))" -ForegroundColor Yellow

        try {
            if (-not $WhatIf) {
                # Attempt to stop the process
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Start-Sleep -Milliseconds 500

                # Verify process termination
                $processStillRunning = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                
                if (-not $processStillRunning) {
                    Write-Log "    - Verified: Process stopped successfully" -ForegroundColor Green
                } else {
                    Write-Log "    - Warning: Process could not be stopped" -ForegroundColor Red
                }
            } else {
                Write-Log "    - WhatIf: Would have stopped process" -ForegroundColor Yellow
            }
        } catch {
            Write-Log "    - Error stopping process: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} else {
    Write-Log "No LastPass processes found" -ForegroundColor Yellow
}

# Step 1: Find LastPass installation locations
Write-Log "Step 1: Locating LastPass installations..." -ForegroundColor Cyan

# Track installed LastPass locations
$installedLPLocations = @()

# Function to find LastPass installations in registry
function Find-LastPassInstallations {
    param([string]$RegistryPath)
    
    # Search for LastPass entries in the specified registry path
    $registryEntries = Get-ItemProperty -Path "$RegistryPath\*" -ErrorAction SilentlyContinue | 
        Where-Object {
            ($_.DisplayName -like "*LastPass*") -or 
            ($_.Publisher -like "*LastPass*") -or 
            ($_.DisplayName -like "*LogMeIn*" -and $_.DisplayName -like "*Password*")
        }
    
    return $registryEntries
}

# Registry paths to search for LastPass installations
$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

Write-Log "Found the following LastPass installations in registry:" -ForegroundColor Cyan
$foundInstallations = @()

# Search through registry paths
foreach ($regPath in $registryPaths) {
    $installations = Find-LastPassInstallations -RegistryPath $regPath
    
    if ($installations) {
        foreach ($entry in $installations) {
            # Log installation details
            Write-Log "  - Registry Path: $regPath\$($entry.PSChildName)" -ForegroundColor Yellow
            Write-Log "    DisplayName: $($entry.DisplayName) (Version: $($entry.DisplayVersion))" -ForegroundColor Yellow
            
            # Attempt to find installation path
            $installPath = $null
            
            # Try InstallLocation first
            if ($entry.InstallLocation -and (Test-Path $entry.InstallLocation)) {
                $installPath = $entry.InstallLocation
            } 
            # Then try extracting path from UninstallString
            elseif ($entry.UninstallString -and $entry.UninstallString -match '/I"?([^"]*)"?') {
                $installPath = $matches[1]
            }
            
            # Add valid installation path
            if ($installPath) {
                Write-Log "    InstallLocation: $installPath" -ForegroundColor Yellow
                $installedLPLocations += $installPath
            }
            
            $foundInstallations += $entry
        }
    }
}

# Predefined common LastPass installation locations
$commonLocations = @(
    "C:\Program Files\LastPass",
    "C:\Program Files (x86)\LastPass",
    "C:\Program Files\Common Files\LastPass",
    "C:\Program Files (x86)\Common Files\LastPass",
    "C:\Program Files (x86)\LogMeIn\LastPass",
    "C:\Program Files\LogMeIn\LastPass"
)

# If no installations found in registry, check common locations
if ($installedLPLocations.Count -eq 0) {
    foreach ($location in $commonLocations) {
        if (Test-Path $location) {
            Write-Log "  - Found installation in common location: $location" -ForegroundColor Yellow
            $installedLPLocations += $location
        }
    }
}

# Log total number of installations found
Write-Log "Total LastPass installations found: $($installedLPLocations.Count)" -ForegroundColor Cyan

# Step 2: Remove LastPass common installation directories
Write-Log "Step 2: Removing LastPass common installation directories..." -ForegroundColor Cyan

# Comprehensive list of LastPass directory locations to remove
$commonLocations = @(
    "C:\Program Files\LastPass",
    "C:\Program Files (x86)\LastPass",
    "C:\Program Files\Common Files\LastPass",
    "C:\Program Files (x86)\Common Files\LastPass",
    "C:\ProgramData\LastPass",
    "C:\Program Files (x86)\LogMeIn\LastPass*",
    "C:\Program Files\LogMeIn\LastPass*",
    "C:\Windows\System32\config\systemprofile\AppData\Local\LastPass",
    "C:\Windows\SysWOW64\config\systemprofile\AppData\Local\LastPass",
    "C:\Windows\System32\LastPass*",
    "C:\Windows\SysWOW64\LastPass*",
    "C:\Windows\LastPass*",
    "C:\Windows\Temp\*LastPass*",
    "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\LastPass",
    "C:\ProgramData\Package Cache\*LastPass*",
    "C:\Windows\Prefetch\LASTPASS*"
)

# Add any discovered custom locations from previous installation search
foreach ($location in $installedLPLocations) {
    if ($commonLocations -notcontains $location) {
        $commonLocations += $location
    }
}

Write-Log "Found the following LastPass directories:" -ForegroundColor Cyan
$foundDirectories = @()

# Track removal statistics
$successfulDirectoryRemovals = 0
$failedDirectoryRemovals = 0

# Identify LastPass directories
foreach ($location in $commonLocations) {
    $paths = Get-Item -Path $location -ErrorAction SilentlyContinue

    if ($paths) {
        if ($paths -is [array]) {
            foreach ($path in $paths) {
                $foundDirectories += $path
                Write-Log "  - $($path.FullName)" -ForegroundColor Yellow
            }
        } else {
            $foundDirectories += $paths
            Write-Log "  - $($paths.FullName)" -ForegroundColor Yellow
        }
    }
}

# Remove found directories
if ($foundDirectories.Count -eq 0) {
    Write-Log "  No LastPass directories found" -ForegroundColor Yellow
} else {
    Write-Log "Removing $($foundDirectories.Count) LastPass directories..." -ForegroundColor Cyan
    
    foreach ($path in $foundDirectories) {
        Write-Log "Removing directory: $($path.FullName)" -ForegroundColor Yellow

        try {
            if (-not $WhatIf) {
                # Attempt standard removal
                Remove-Item -Path $path.FullName -Recurse -Force -ErrorAction Stop

                # Verify removal
                if (-not (Test-Path -Path $path.FullName)) {
                    Write-Log "  - Verified: Directory removed successfully" -ForegroundColor Green
                    $successfulDirectoryRemovals++
                } else {
                    # Try alternative removal method for locked files
                    try {
                        # Try with .NET method as alternative
                        [System.IO.Directory]::Delete($path.FullName, $true)

                        if (-not (Test-Path -Path $path.FullName)) {
                            Write-Log "  - Removed successfully using alternative method" -ForegroundColor Green
                            $successfulDirectoryRemovals++
                        } else {
                            Write-Log "  - Failed to remove directory" -ForegroundColor Red
                            $failedDirectoryRemovals++
                        }
                    } catch {
                        Write-Log "  - Error with alternative removal: $($_.Exception.Message)" -ForegroundColor Red
                        $failedDirectoryRemovals++
                    }
                }
            } else {
                Write-Log "  - WhatIf: Would have removed directory" -ForegroundColor Yellow
            }
        } catch {
            Write-Log "  - Error removing directory: $($_.Exception.Message)" -ForegroundColor Red
            $failedDirectoryRemovals++
        }
    }

    # Log removal summary
    Write-Log "Directory Removal Summary:" -ForegroundColor Cyan
    Write-Log "  - Total Directories: $($foundDirectories.Count)" -ForegroundColor White
    Write-Log "  - Successfully Removed: $successfulDirectoryRemovals" -ForegroundColor Green
    Write-Log "  - Failed Removals: $failedDirectoryRemovals" -ForegroundColor Red
}

# Step 3: Remove LastPass registry keys
Write-Log "Step 3: Removing LastPass registry keys..." -ForegroundColor Cyan

# Track found and removed registry keys
$foundRegistryKeys = @()
$successfulRegistryRemovals = 0
$failedRegistryRemovals = 0

# Function to normalize registry paths
function Normalize-RegistryPath {
    param([string]$Path)

    # Replace HKEY_LOCAL_MACHINE with HKLM:
    $normalizedPath = $Path -replace "^HKEY_LOCAL_MACHINE\\", "HKLM:\" `
                            -replace "^HKEY_CURRENT_USER\\", "HKCU:\" `
                            -replace "^HKEY_CLASSES_ROOT\\", "HKCR:\" `
                            -replace "^HKEY_USERS\\", "HKU:\" `
                            -replace "^HKEY_CURRENT_CONFIG\\", "HKCU:\"

    return $normalizedPath
}

# Preliminary search for LastPass registry keys
Write-Log "Searching for LastPass registry keys..." -ForegroundColor Cyan

# Broad search across potential locations
$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

# Find LastPass-related registry keys
foreach ($regPath in $registryPaths) {
    try {
        $keys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | 
            Where-Object { 
                ($_.GetValue("DisplayName") -like "*LastPass*") -or 
                ($_.GetValue("Publisher") -like "*LastPass*") 
            }

        if ($keys) {
            foreach ($key in $keys) {
                $fullKeyPath = $key.PSPath -replace "Microsoft.PowerShell.Core\\Registry::", ""
                Write-Log "  - Found key: $fullKeyPath" -ForegroundColor Yellow
                $foundRegistryKeys += $fullKeyPath
            }
        }
    } catch {
        Write-Log ("  - Error searching path " + $regPath + ": " + $_.Exception.Message) -ForegroundColor Red
    }
}

# Remove found registry keys
if ($foundRegistryKeys.Count -eq 0) {
    Write-Log "  No LastPass registry keys found" -ForegroundColor Yellow
} else {
    Write-Log "Removing $($foundRegistryKeys.Count) LastPass registry keys..." -ForegroundColor Cyan
    
    foreach ($regKey in $foundRegistryKeys) {
        Write-Log "Attempting to remove registry key: $regKey" -ForegroundColor Yellow

        # Normalize the path
        $normalizedRegKey = Normalize-RegistryPath $regKey

        # Verify and remove
        if ($normalizedRegKey) {
            try {
                # Check if the path exists using normalized path
                if (Test-Path $normalizedRegKey) {
                    Remove-Item -Path $normalizedRegKey -Recurse -Force -ErrorAction Stop
                    Write-Log "  - Successfully removed registry key" -ForegroundColor Green
                    $successfulRegistryRemovals++
                } else {
                    Write-Log "  - Registry key not found: $normalizedRegKey" -ForegroundColor Yellow
                    $failedRegistryRemovals++
                }
            } catch {
                Write-Log "  - Failed to remove key: $($_.Exception.Message)" -ForegroundColor Red
                $failedRegistryRemovals++
            }
        }
    }
}

# Step 4: Remove LastPass browser extensions (Chrome and Edge only)
Write-Log "Step 4: Removing LastPass browser extensions from Chrome and Edge..." -ForegroundColor Cyan

# Define LastPass extension IDs for Chrome and Edge
$lastPassExtensions = @{
    "Chrome" = @("hdokiejnpimakedhajhdlcegeplioahd")
    "Edge" = @("bbcinlkgjjkejfdpemiealijmmooekmp")
}

# Track extension removal statistics
$foundExtensions = 0
$successfulExtensionRemovals = 0
$failedExtensionRemovals = 0

# Get all user profiles on the system
$userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -ne "Public" -and $_.Name -ne "Default" -and $_.Name -ne "Default User" }

Write-Log "Scanning for LastPass browser extensions in user profiles..." -ForegroundColor Cyan

# Chrome and Edge extensions path patterns
$browserExtensionsPaths = @(
    "\AppData\Local\Google\Chrome\User Data\*\Extensions\*",
    "\AppData\Local\Microsoft\Edge\User Data\*\Extensions\*"
)

# Process each user profile for Chrome/Edge browser extensions
foreach ($profile in $userProfiles) {
    Write-Log "Scanning user profile: $($profile.Name)" -ForegroundColor Cyan
    
    foreach ($extensionPathPattern in $browserExtensionsPaths) {
        $fullPathPattern = Join-Path -Path $profile.FullName -ChildPath $extensionPathPattern
        
        # Find LastPass extension directories
        $extensionDirs = Get-ChildItem -Path $fullPathPattern -ErrorAction SilentlyContinue | 
            Where-Object { 
                $extensionId = $_.Name
                $lastPassExtensions.Values | Where-Object { $_ -contains $extensionId }
            }
        
        foreach ($extensionDir in $extensionDirs) {
            $foundExtensions++
            $browserType = "Unknown"
            
            # Identify browser type from path
            if ($extensionDir.FullName -like "*\Google\Chrome\*") { $browserType = "Chrome" }
            elseif ($extensionDir.FullName -like "*\Microsoft\Edge\*") { $browserType = "Edge" }
            
            Write-Log "  - Found LastPass extension for ${browserType} in: $($extensionDir.FullName)" -ForegroundColor Yellow
            
            # Remove extension directory
            try {
                if (-not $WhatIf) {
                    Remove-Item -Path $extensionDir.FullName -Recurse -Force -ErrorAction Stop
                    
                    # Verify removal
                    if (-not (Test-Path -Path $extensionDir.FullName)) {
                        Write-Log "    - Successfully removed extension" -ForegroundColor Green
                        $successfulExtensionRemovals++
                    } else {
                        # Try alternate removal for locked files
                        if (Remove-LockedItem -Path $extensionDir.FullName -IsDirectory) {
                            Write-Log "    - Successfully removed extension using alternate method" -ForegroundColor Green
                            $successfulExtensionRemovals++
                        } else {
                            Write-Log "    - Failed to remove extension" -ForegroundColor Red
                            $failedExtensionRemovals++
                        }
                    }
                } else {
                    Write-Log "    - WhatIf: Would have removed extension" -ForegroundColor Yellow
                }
            } catch {
                Write-Log "    - Error removing extension: $($_.Exception.Message)" -ForegroundColor Red
                $failedExtensionRemovals++
            }
        }
    }
}

# Look for extension preferences files and remove LastPass entries
Write-Log "Checking for browser preferences files with LastPass entries..." -ForegroundColor Cyan

$preferencesFound = 0
$preferencesModified = 0
$preferencesFailed = 0

# Process Chrome and Edge browser preference files
foreach ($profile in $userProfiles) {
    # Chrome and Edge preferences files patterns
    $preferencesPatterns = @(
        "\AppData\Local\Google\Chrome\User Data\*\Preferences",
        "\AppData\Local\Microsoft\Edge\User Data\*\Preferences"
    )
    
    foreach ($pattern in $preferencesPatterns) {
        $fullPattern = Join-Path -Path $profile.FullName -ChildPath $pattern
        $preferencesFiles = Get-ChildItem -Path $fullPattern -ErrorAction SilentlyContinue
        
        foreach ($preferencesFile in $preferencesFiles) {
            try {
                $preferencesFound++
                $browserType = "Unknown"
                
                # Identify browser type from path
                if ($preferencesFile.FullName -like "*\Google\Chrome\*") { $browserType = "Chrome" }
                elseif ($preferencesFile.FullName -like "*\Microsoft\Edge\*") { $browserType = "Edge" }
                
                Write-Log "  - Found preferences file for ${browserType}: $($preferencesFile.FullName)" -ForegroundColor Yellow
                
                # Read preferences file content
                $preferencesContent = Get-Content -Path $preferencesFile.FullName -Raw -ErrorAction Stop
                
                # Check for LastPass entries using Chrome/Edge extension IDs
                $containsLastPass = $preferencesContent -match "lastpass" -or 
                                   $preferencesContent -match "hdokiejnpimakedhajhdlcegeplioahd" -or 
                                   $preferencesContent -match "bbcinlkgjjkejfdpemiealijmmooekmp"
                
                if ($containsLastPass) {
                    Write-Log "    - Found LastPass entries in preferences file" -ForegroundColor Yellow
                    
                    # Modifying these files directly can be risky, so log the finding
                    Write-Log "    - Note: Manual preferences file cleanup may be required" -ForegroundColor Yellow
                    Write-Log "    - Browser will automatically clean up extension references on next start" -ForegroundColor Yellow
                }
            } catch {
                Write-Log "    - Error processing preferences file: $($_.Exception.Message)" -ForegroundColor Red
                $preferencesFailed++
            }
        }
    }
}

# Log extension removal summary
Write-Log "Browser Extension Removal Summary:" -ForegroundColor Cyan
Write-Log "  - Total Extensions Found: $foundExtensions" -ForegroundColor White
Write-Log "  - Successfully Removed: $successfulExtensionRemovals" -ForegroundColor Cyan