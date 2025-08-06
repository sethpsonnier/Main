# Enhanced Dell Software Removal Script - Fixed Version
# Robust error handling and PowerShell strict mode compatibility
# 
# This script identifies and removes Dell bloatware while preserving Dell Command software
# Run with administrative privileges for best results
# Exit codes: 0 = Success, 1 = Error
#
# Usage: .\Dell-Removal.ps1 [-DryRun] [-IncludeServices] [-Verbose] [-Force]

param(
    [switch]$DryRun,
    [switch]$IncludeServices,
    [switch]$Verbose,
    [switch]$Force
)

# Set error handling preferences but disable strict mode to avoid property errors
$ErrorActionPreference = "Continue"
# Set-StrictMode -Version Latest  # Commented out to avoid property errors

# Setup logging
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = "C:\temp"
$logFile = "$logDir\Dell-Removal-$timestamp.log"

# Ensure log directory exists
if (-not (Test-Path -Path $logDir)) {
    try {
        New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Host "Created log directory: $logDir"
    }
    catch {
        Write-Host "Failed to create log directory $logDir. Using temp directory instead." -ForegroundColor Red
        $logDir = "$env:TEMP"
        $logFile = "$logDir\Dell-Removal-$timestamp.log"
    }
}

Write-Host "Log file will be created at: $logFile"
if ($DryRun) {
    Write-Host "DRY RUN MODE - No actual changes will be made" -ForegroundColor Yellow
}

# Initialize tracking arrays and stats
$global:foundSoftware = @()
$global:removalStats = @{
    AppXAttempted = 0
    AppXSucceeded = 0
    ProgramsAttempted = 0
    ProgramsSucceeded = 0
    ServicesAttempted = 0
    ServicesSucceeded = 0
}

# MSI Error Codes for better reporting
$msiErrorCodes = @{
    0 = "Success"
    1605 = "Product not installed"
    1607 = "Installation package corrupt"
    1618 = "Another installation in progress"
    1619 = "Installation package could not be opened"
    1620 = "Installation package could not be opened"
    1621 = "There was an error starting the Windows Installer service"
    1622 = "Error accessing the Windows Installer service"
    1623 = "This language is not supported"
    1624 = "Error applying transforms"
    1625 = "System policy prohibits this installation"
    3010 = "Success (restart required)"
}

# Function to safely check if property exists
function Test-PropertyExists {
    param(
        [Parameter(Mandatory=$true)]
        $Object,
        [Parameter(Mandatory=$true)]
        [string]$PropertyName
    )
    
    return ($Object.PSObject.Properties.Name -contains $PropertyName)
}

# Function to safely get property value
function Get-SafeProperty {
    param(
        [Parameter(Mandatory=$true)]
        $Object,
        [Parameter(Mandatory=$true)]
        [string]$PropertyName,
        [Parameter(Mandatory=$false)]
        $DefaultValue = $null
    )
    
    if (Test-PropertyExists -Object $Object -PropertyName $PropertyName) {
        $value = $Object.$PropertyName
        if ($value -and $value -ne "") {
            return $value
        }
    }
    return $DefaultValue
}

# Function to write to both console and log file
function Write-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [string]$Type = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Type] $Message"
    
    # Only show DEBUG messages if Verbose is enabled
    if ($Type -eq "DEBUG" -and -not $Verbose) {
        # Still log to file but don't show on console
        try {
            Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
        } catch {
            # Ignore log file errors
        }
        return
    }
    
    # Write to console
    switch ($Type) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "DEBUG" { Write-Host $logMessage -ForegroundColor Cyan }
        "ACTION" { Write-Host $logMessage -ForegroundColor Magenta }
        "DRYRUN" { Write-Host $logMessage -ForegroundColor Blue }
        "FOUND" { Write-Host $logMessage -ForegroundColor White }
        default { Write-Host $logMessage }
    }
    
    # Write to log file
    try {
        Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
    } catch {
        # Ignore log file errors
    }
}

# Enhanced exclusion function
function Should-Exclude {
    param (
        [string]$SoftwareName
    )
    
    if (-not $SoftwareName) {
        return $true
    }
    
    $excludePatterns = @(
        "*Command*",              # All Dell Command software
        "*BIOS*",                # BIOS-related software
        "*Driver*",              # Driver packages  
        "*Firmware*",            # Firmware tools
        "*Chipset*",             # Chipset drivers
        "*Audio*Driver*",        # Audio drivers
        "*Network*Driver*",      # Network drivers
        "*Graphics*Driver*",     # Graphics drivers
        "*Bluetooth*Driver*",    # Bluetooth drivers
        "*WiFi*Driver*",         # WiFi drivers
        "*Wireless*Driver*"      # Wireless drivers
    )
    
    foreach ($pattern in $excludePatterns) {
        if ($SoftwareName -like $pattern) {
            Write-Log "Excluding software: $SoftwareName (matched pattern: $pattern)" "DEBUG"
            return $true
        }
    }
    
    return $false
}

# Function to validate and parse uninstall strings
function Get-ValidUninstallCommand {
    param (
        [string]$UninstallString,
        [string]$SoftwareName
    )
    
    if ([string]::IsNullOrWhiteSpace($UninstallString)) {
        return $null
    }
    
    $UninstallString = $UninstallString.Trim()
    
    # Handle quoted paths
    if ($UninstallString.StartsWith('"')) {
        $endQuoteIndex = $UninstallString.IndexOf('"', 1)
        if ($endQuoteIndex -gt 0) {
            $executable = $UninstallString.Substring(1, $endQuoteIndex - 1)
            $arguments = $UninstallString.Substring($endQuoteIndex + 1).Trim()
        } else {
            $executable = $UninstallString.Replace('"', '')
            $arguments = ""
        }
    } else {
        # Split on first space
        $parts = $UninstallString -split '\s+', 2
        $executable = $parts[0]
        $arguments = if ($parts.Length -gt 1) { $parts[1] } else { "" }
    }
    
    # Validate executable exists
    if (-not (Test-Path $executable -ErrorAction SilentlyContinue)) {
        Write-Log "Uninstall executable not found: $executable" "DEBUG"
        return $null
    }
    
    # Enhance arguments for silent uninstall
    if ($executable -like "*msiexec*") {
        # MSI uninstaller
        if ($arguments -match "{[A-Z0-9\-]+}") {
            $guid = $matches[0]
            return @{
                Executable = "msiexec.exe"
                Arguments = "/x $guid /qn /norestart"
                Type = "MSI"
            }
        }
    } elseif ($executable -like "*uninst*" -or $executable -like "*unins*") {
        # Inno Setup
        $silentArgs = "/SILENT /NORESTART /SUPPRESSMSGBOXES"
        if ($arguments -notlike "*SILENT*") {
            $arguments = "$arguments $silentArgs".Trim()
        }
        return @{
            Executable = $executable
            Arguments = $arguments
            Type = "InnoSetup"
        }
    } elseif ($executable -like "*setup*" -or $executable -like "*install*") {
        # Generic installer
        $silentArgs = "/S /SILENT /QUIET"
        if ($arguments -notlike "*S*" -and $arguments -notlike "*SILENT*" -and $arguments -notlike "*QUIET*") {
            $arguments = "$arguments /S".Trim()
        }
        return @{
            Executable = $executable
            Arguments = $arguments
            Type = "Generic"
        }
    } else {
        # Unknown type - try as-is
        return @{
            Executable = $executable
            Arguments = $arguments
            Type = "Unknown"
        }
    }
    
    return $null
}

# Function to find all Dell software comprehensively
function Find-AllDellSoftware {
    Write-Log "Performing comprehensive scan for Dell software..." "INFO"
    
    $foundSoftware = @()
    
    # Scan registry locations
    $registryPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    
    foreach ($regPath in $registryPaths) {
        if (Test-Path $regPath) {
            Write-Log "Scanning registry path: $regPath" "DEBUG"
            
            try {
                $regItems = Get-ChildItem $regPath -ErrorAction SilentlyContinue
                foreach ($regItem in $regItems) {
                    try {
                        $item = Get-ItemProperty $regItem.PSPath -ErrorAction SilentlyContinue
                        
                        if ($item) {
                            $displayName = Get-SafeProperty -Object $item -PropertyName "DisplayName"
                            $publisher = Get-SafeProperty -Object $item -PropertyName "Publisher"
                            
                            # Check for Dell-related software
                            if ($displayName -and (
                                $displayName -like "*Dell*" -or 
                                $publisher -like "*Dell*" -or
                                $displayName -like "*SupportAssist*"
                            )) {
                                
                                if (-not (Should-Exclude -SoftwareName $displayName)) {
                                    $softwareInfo = @{
                                        Name = $displayName
                                        Publisher = Get-SafeProperty -Object $item -PropertyName "Publisher"
                                        Version = Get-SafeProperty -Object $item -PropertyName "DisplayVersion"
                                        UninstallString = Get-SafeProperty -Object $item -PropertyName "UninstallString"
                                        QuietUninstallString = Get-SafeProperty -Object $item -PropertyName "QuietUninstallString"
                                        InstallLocation = Get-SafeProperty -Object $item -PropertyName "InstallLocation"
                                        RegistryPath = $regPath
                                        ProductCode = $regItem.PSChildName
                                        Type = "Program"
                                    }
                                    
                                    $foundSoftware += $softwareInfo
                                    Write-Log "Found: $displayName [$publisher]" "FOUND"
                                }
                            }
                        }
                    } catch {
                        Write-Log "Error processing registry item: $($_.Exception.Message)" "DEBUG"
                    }
                }
            }
            catch {
                Write-Log "Error scanning $regPath : $($_.Exception.Message)" "ERROR"
            }
        }
    }
    
    # Scan AppX packages
    Write-Log "Scanning AppX packages..." "DEBUG"
    try {
        $appxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -and (
                $_.Name -like "*Dell*" -or 
                $_.Publisher -like "*Dell*" -or
                $_.Name -like "*forDell*" -or
                $_.PackageFamilyName -like "*Dell*"
            )
        }
        
        foreach ($package in $appxPackages) {
            if ($package.Name -and -not (Should-Exclude -SoftwareName $package.Name)) {
                $softwareInfo = @{
                    Name = $package.Name
                    Publisher = $package.Publisher
                    Version = $package.Version.ToString()
                    PackageFullName = $package.PackageFullName
                    Type = "AppX"
                }
                
                $foundSoftware += $softwareInfo
                Write-Log "Found AppX: $($package.Name)" "FOUND"
            }
        }
    }
    catch {
        Write-Log "Error scanning AppX packages: $($_.Exception.Message)" "ERROR"
    }
    
    # Scan services (if requested)
    if ($IncludeServices) {
        Write-Log "Scanning Dell services..." "DEBUG"
        try {
            $services = Get-Service -ErrorAction SilentlyContinue | Where-Object {
                ($_.ServiceName -like "*Dell*" -or $_.DisplayName -like "*Dell*") -and
                $_.DisplayName
            }
            
            foreach ($service in $services) {
                if (-not (Should-Exclude -SoftwareName $service.DisplayName)) {
                    $softwareInfo = @{
                        Name = $service.DisplayName
                        ServiceName = $service.ServiceName
                        Status = $service.Status.ToString()
                        Type = "Service"
                    }
                    
                    $foundSoftware += $softwareInfo
                    Write-Log "Found Service: $($service.DisplayName) [$($service.Status)]" "FOUND"
                }
            }
        }
        catch {
            Write-Log "Error scanning services: $($_.Exception.Message)" "ERROR"
        }
    }
    
    return $foundSoftware
}

# Main execution starts here
Write-Log "Starting Enhanced Dell Software Removal..." "INFO"
if ($DryRun) {
    Write-Log "DRY RUN MODE - No actual changes will be made" "DRYRUN"
}

# Find all Dell software
$global:foundSoftware = Find-AllDellSoftware

# Safe count check
$softwareCount = 0
if ($global:foundSoftware -and $global:foundSoftware.GetType().Name -eq "Object[]") {
    $softwareCount = $global:foundSoftware.Count
} elseif ($global:foundSoftware) {
    $softwareCount = 1
}

if ($softwareCount -eq 0) {
    Write-Log "No Dell software found to remove." "INFO"
    Write-Log "This could mean:" "INFO"
    Write-Log "  - No Dell bloatware is installed" "INFO"
    Write-Log "  - Software was already removed" "INFO"
    Write-Log "  - Software is in a different location" "INFO"
    Write-Log "Full log saved to: $logFile" "INFO"
    exit 0
}

Write-Log "Found $softwareCount Dell software items" "INFO"

# Group by type for organized removal
if ($softwareCount -eq 1) {
    $softwareByType = @(@{Name = $global:foundSoftware.Type; Group = @($global:foundSoftware)})
} else {
    $softwareByType = $global:foundSoftware | Group-Object Type
}

foreach ($typeGroup in $softwareByType) {
    $type = $typeGroup.Name
    $items = $typeGroup.Group
    
    $itemCount = if ($items.GetType().Name -eq "Object[]") { $items.Count } else { 1 }
    Write-Log "Processing $itemCount $type items..." "INFO"
    
    foreach ($software in $items) {
        switch ($type) {
            "AppX" {
                $global:removalStats.AppXAttempted++
                Write-Log "Removing AppX package: $($software.Name)" "ACTION"
                
                if ($DryRun) {
                    Write-Log "DRY RUN: Would remove AppX package: $($software.Name)" "DRYRUN"
                    continue
                }
                
                try {
                    Remove-AppxPackage -Package $software.PackageFullName -AllUsers -ErrorAction Stop
                    Write-Log "Successfully removed AppX package: $($software.Name)" "SUCCESS"
                    $global:removalStats.AppXSucceeded++
                }
                catch {
                    Write-Log "Failed with -AllUsers, trying current user only..." "DEBUG"
                    try {
                        Remove-AppxPackage -Package $software.PackageFullName -ErrorAction Stop
                        Write-Log "Successfully removed AppX package for current user: $($software.Name)" "SUCCESS"
                        $global:removalStats.AppXSucceeded++
                    }
                    catch {
                        Write-Log "Failed to remove AppX package $($software.Name): $($_.Exception.Message)" "ERROR"
                    }
                }
            }
            
            "Program" {
                $global:removalStats.ProgramsAttempted++
                Write-Log "Removing program: $($software.Name)" "ACTION"
                
                if ($DryRun) {
                    Write-Log "DRY RUN: Would remove program: $($software.Name)" "DRYRUN"
                    Write-Log "DRY RUN: Uninstall command would be: $($software.UninstallString)" "DEBUG"
                    continue
                }
                
                # Try QuietUninstallString first, then UninstallString
                $uninstallString = if ($software.QuietUninstallString) { 
                    $software.QuietUninstallString 
                } else { 
                    $software.UninstallString 
                }
                
                $uninstallCommand = Get-ValidUninstallCommand -UninstallString $uninstallString -SoftwareName $software.Name
                
                if ($uninstallCommand) {
                    Write-Log "Using $($uninstallCommand.Type) uninstaller: $($uninstallCommand.Executable) $($uninstallCommand.Arguments)" "DEBUG"
                    
                    try {
                        $process = Start-Process -FilePath $uninstallCommand.Executable -ArgumentList $uninstallCommand.Arguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                        
                        $exitCode = $process.ExitCode
                        $exitMessage = if ($msiErrorCodes.ContainsKey($exitCode)) { 
                            $msiErrorCodes[$exitCode] 
                        } else { 
                            "Unknown exit code" 
                        }
                        
                        if ($exitCode -eq 0 -or $exitCode -eq 3010) {
                            Write-Log "Successfully removed: $($software.Name) [Exit: $exitCode - $exitMessage]" "SUCCESS"
                            $global:removalStats.ProgramsSucceeded++
                        } elseif ($exitCode -eq 1605) {
                            Write-Log "Software not installed: $($software.Name) [Exit: $exitCode - $exitMessage]" "WARN"
                        } else {
                            Write-Log "Uninstall completed with warnings: $($software.Name) [Exit: $exitCode - $exitMessage]" "WARN"
                        }
                    }
                    catch {
                        Write-Log "Failed to remove $($software.Name): $($_.Exception.Message)" "ERROR"
                    }
                } else {
                    Write-Log "No valid uninstall command found for: $($software.Name)" "WARN"
                    Write-Log "Original uninstall string: $($software.UninstallString)" "DEBUG"
                    
                    # Try manual removal for Dell Display Manager
                    if ($software.Name -like "*Display Manager*") {
                        Write-Log "Attempting manual Dell Display Manager removal..." "INFO"
                        
                        # Check common installation paths
                        $dellPaths = @(
                            "C:\Program Files\Dell\Dell Display Manager",
                            "C:\Program Files (x86)\Dell\Dell Display Manager"
                        )
                        
                        foreach ($path in $dellPaths) {
                            if (Test-Path $path) {
                                Write-Log "Found Dell Display Manager at: $path" "INFO"
                                
                                # Look for uninstaller
                                $uninstallers = Get-ChildItem $path -Recurse -Filter "*uninstall*" -ErrorAction SilentlyContinue
                                if ($uninstallers) {
                                    foreach ($uninstaller in $uninstallers) {
                                        Write-Log "Trying uninstaller: $($uninstaller.FullName)" "DEBUG"
                                        try {
                                            $process = Start-Process -FilePath $uninstaller.FullName -ArgumentList "/S" -Wait -PassThru -WindowStyle Hidden
                                            if ($process.ExitCode -eq 0) {
                                                Write-Log "Successfully removed Dell Display Manager using: $($uninstaller.FullName)" "SUCCESS"
                                                $global:removalStats.ProgramsSucceeded++
                                                break
                                            }
                                        }
                                        catch {
                                            Write-Log "Failed with uninstaller $($uninstaller.FullName): $($_.Exception.Message)" "DEBUG"
                                        }
                                    }
                                } else {
                                    Write-Log "No uninstaller found in $path" "DEBUG"
                                }
                            }
                        }
                    }
                }
            }
            
            "Service" {
                $global:removalStats.ServicesAttempted++
                Write-Log "Removing service: $($software.Name)" "ACTION"
                
                if ($DryRun) {
                    Write-Log "DRY RUN: Would remove service: $($software.Name)" "DRYRUN"
                    continue
                }
                
                try {
                    if ($software.Status -eq "Running") {
                        Stop-Service -Name $software.ServiceName -Force -ErrorAction Stop
                        Write-Log "Stopped service: $($software.ServiceName)" "SUCCESS"
                    }
                    
                    # Use sc.exe to delete the service
                    $result = & sc.exe delete $software.ServiceName 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Successfully removed service: $($software.ServiceName)" "SUCCESS"
                        $global:removalStats.ServicesSucceeded++
                    } else {
                        Write-Log "Failed to remove service $($software.ServiceName): $result" "ERROR"
                    }
                }
                catch {
                    Write-Log "Failed to remove service $($software.ServiceName): $($_.Exception.Message)" "ERROR"
                }
            }
        }
        
        # Small delay between removals
        if (-not $DryRun) {
            Start-Sleep -Seconds 1
        }
    }
}

# Final summary
$totalAttempted = $global:removalStats.AppXAttempted + $global:removalStats.ProgramsAttempted + $global:removalStats.ServicesAttempted
$totalSucceeded = $global:removalStats.AppXSucceeded + $global:removalStats.ProgramsSucceeded + $global:removalStats.ServicesSucceeded

Write-Log "=== REMOVAL SUMMARY ===" "INFO"
Write-Log "AppX packages: Attempted $($global:removalStats.AppXAttempted), Succeeded $($global:removalStats.AppXSucceeded)" "SUMMARY"
Write-Log "Traditional programs: Attempted $($global:removalStats.ProgramsAttempted), Succeeded $($global:removalStats.ProgramsSucceeded)" "SUMMARY"
if ($IncludeServices) {
    Write-Log "Services: Attempted $($global:removalStats.ServicesAttempted), Succeeded $($global:removalStats.ServicesSucceeded)" "SUMMARY"
}
Write-Log "Total: Attempted $totalAttempted, Succeeded $totalSucceeded" "SUMMARY"

if (-not $DryRun -and $totalSucceeded -gt 0) {
    Write-Log "Removal complete. A system restart is recommended." "INFO"
} elseif ($DryRun) {
    Write-Log "DRY RUN complete. Run without -DryRun to perform actual removal." "INFO"
} else {
    Write-Log "No software was successfully removed." "INFO"
}

Write-Log "Full log saved to: $logFile" "INFO"

# Enhanced exit code logic
$success = ($totalAttempted -eq 0) -or ($totalSucceeded -gt 0) -or $DryRun

Write-Host "`nLog file saved to: $LogFile" -ForegroundColor Green

if ($DryRun) {
    exit 0
} elseif ($success) {
    exit 0
} else {
    exit 1
}