#========================================================================
# Resource-Tracking-Migration (One-Time Script)
# Purpose: Consolidate historical data from multiple file generations
# Usage: Run once manually with Script 1 paused
# IMPORTANT: This script should only be run ONCE per server
#========================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$BaseDirectory = "C:\temp2",
    
    [Parameter(Mandatory=$false)]
    [string]$TempDirectory = "C:\temp2\migration_temp",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

Write-Host "========================================================================" -ForegroundColor Yellow
Write-Host "Resource-Tracking-Migration Script" -ForegroundColor Yellow
Write-Host "IMPORTANT: Ensure Script 1 (Resource Collection) is PAUSED before running!" -ForegroundColor Red
Write-Host "========================================================================" -ForegroundColor Yellow

if (-not $WhatIf) {
    $confirmation = Read-Host "Have you paused Script 1? (yes/no)"
    if ($confirmation -ne "yes") {
        Write-Host "Please pause Script 1 first, then re-run this script." -ForegroundColor Red
        exit 1
    }
}

$logDir = "$BaseDirectory\logs"

# Create temp directory
if (-not (Test-Path $TempDirectory)) {
    New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
    Write-Host "Created temp directory: $TempDirectory"
}

#------------------------------------------------------------------------
# Function: Get current drive mapping in alphabetical order
#------------------------------------------------------------------------
function Get-DriveMapping {
    # Get current drives in alphabetical order
    $currentDrives = Get-CimInstance Win32_LogicalDisk | 
        Where-Object { $_.DriveType -eq 3 -and $_.Size -gt 0 } |
        Sort-Object DeviceID |
        ForEach-Object { $_.DeviceID.Replace(':', '') }
    
    # Find old diskX.txt files
    $oldDiskFiles = Get-ChildItem -Path $BaseDirectory -Filter "disk*.txt" | 
        Where-Object { $_.Name -match "^disk\d+\.txt$" } |
        Sort-Object { [int]($_.Name -replace "disk|\.txt", "") }
    
    $mapping = @{}
    
    Write-Host "`nDrive Mapping Detection:" -ForegroundColor Green
    Write-Host "Available drives: $($currentDrives -join ', ')" -ForegroundColor Cyan
    Write-Host "Old disk files found: $($oldDiskFiles.Name -join ', ')" -ForegroundColor Cyan
    
    for ($i = 0; $i -lt $oldDiskFiles.Count -and $i -lt $currentDrives.Count; $i++) {
        $oldFile = $oldDiskFiles[$i].Name
        $targetDrive = $currentDrives[$i]
        $mapping[$oldFile] = $targetDrive
        Write-Host "  $oldFile → drive $targetDrive" -ForegroundColor White
    }
    
    return $mapping
}

#------------------------------------------------------------------------
# Function: Consolidate data for a single drive
#------------------------------------------------------------------------
function Merge-DriveData {
    param(
        [string]$DriveLetter,
        [string]$OldDiskFile
    )
    
    $consolidatedData = @()
    $dataAdded = $false
    
    Write-Host "`nProcessing Drive $DriveLetter..." -ForegroundColor Green
    
    # File paths to merge (in chronological order)
    $filesToMerge = @(
        @{ Path = "$BaseDirectory\$OldDiskFile"; Description = "Original disk file" }
        @{ Path = "$BaseDirectory\disk_$DriveLetter.txt"; Description = "Intermediate file" }
        @{ Path = "$logDir\disk_$DriveLetter.txt"; Description = "Current log file" }
    )
    
    # Add header once
    $consolidatedData += "Timestamp,Usage"
    
    foreach ($fileInfo in $filesToMerge) {
        $filePath = $fileInfo.Path
        $description = $fileInfo.Description
        
        if (Test-Path $filePath) {
            $content = Get-Content $filePath | Where-Object { 
                $_ -and $_.Trim() -and $_ -notmatch "^Timestamp,Usage" 
            }
            
            if ($content.Count -gt 0) {
                $consolidatedData += $content
                $dataAdded = $true
                Write-Host "  ✓ Added $($content.Count) records from $description" -ForegroundColor Cyan
            } else {
                Write-Host "  ⚠ No data found in $description" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ⚠ File not found: $description ($filePath)" -ForegroundColor Yellow
        }
    }
    
    if ($dataAdded) {
        # Sort data by timestamp to ensure chronological order
        $dataLines = $consolidatedData | Where-Object { $_ -notmatch "^Timestamp,Usage" }
        $sortedData = $dataLines | Sort-Object { 
            try { 
                [DateTime]($_ -split ",")[0] 
            } catch { 
                [DateTime]::MinValue 
            }
        }
        
        # Create final consolidated file
        $finalData = @("Timestamp,Usage") + $sortedData
        $tempFile = "$TempDirectory\consolidated_disk_$DriveLetter.txt"
        
        if ($WhatIf) {
            Write-Host "  [WHATIF] Would create: $tempFile with $($finalData.Count - 1) data records" -ForegroundColor Magenta
        } else {
            $finalData | Out-File -FilePath $tempFile -Encoding utf8
            Write-Host "  ✓ Created consolidated file: $tempFile ($($finalData.Count - 1) data records)" -ForegroundColor Green
        }
        
        return $tempFile
    } else {
        Write-Host "  ✗ No data found for drive $DriveLetter" -ForegroundColor Red
        return $null
    }
}

#------------------------------------------------------------------------
# Function: Process non-disk files (CPU, RAM)
#------------------------------------------------------------------------
function Merge-SimpleFile {
    param([string]$FileName)
    
    $consolidatedData = @()
    $dataAdded = $false
    
    Write-Host "`nProcessing $FileName..." -ForegroundColor Green
    
    # File paths to merge (in chronological order)  
    $filesToMerge = @(
        @{ Path = "$BaseDirectory\$FileName"; Description = "Original file" }
        @{ Path = "$logDir\$FileName"; Description = "Current log file" }
    )
    
    # Add header once
    $consolidatedData += "Timestamp,Usage"
    
    foreach ($fileInfo in $filesToMerge) {
        $filePath = $fileInfo.Path
        $description = $fileInfo.Description
        
        if (Test-Path $filePath) {
            $content = Get-Content $filePath | Where-Object { 
                $_ -and $_.Trim() -and $_ -notmatch "^Timestamp,Usage" 
            }
            
            if ($content.Count -gt 0) {
                $consolidatedData += $content
                $dataAdded = $true
                Write-Host "  ✓ Added $($content.Count) records from $description" -ForegroundColor Cyan
            }
        } else {
            Write-Host "  ⚠ File not found: $description ($filePath)" -ForegroundColor Yellow
        }
    }
    
    if ($dataAdded) {
        # Sort data by timestamp
        $dataLines = $consolidatedData | Where-Object { $_ -notmatch "^Timestamp,Usage" }
        $sortedData = $dataLines | Sort-Object { 
            try { 
                [DateTime]($_ -split ",")[0] 
            } catch { 
                [DateTime]::MinValue 
            }
        }
        
        # Create final consolidated file
        $finalData = @("Timestamp,Usage") + $sortedData
        $tempFile = "$TempDirectory\consolidated_$FileName"
        
        if ($WhatIf) {
            Write-Host "  [WHATIF] Would create: $tempFile with $($finalData.Count - 1) data records" -ForegroundColor Magenta
        } else {
            $finalData | Out-File -FilePath $tempFile -Encoding utf8
            Write-Host "  ✓ Created consolidated file: $tempFile ($($finalData.Count - 1) data records)" -ForegroundColor Green
        }
        
        return $tempFile
    }
    
    return $null
}

#------------------------------------------------------------------------
# Main Processing
#------------------------------------------------------------------------

Write-Host "`nStarting data consolidation process..." -ForegroundColor Yellow

# Get drive mapping
$driveMapping = Get-DriveMapping

if ($driveMapping.Count -eq 0) {
    Write-Host "No old disk files found to migrate." -ForegroundColor Yellow
    exit 0
}

# Process disk files
$consolidatedFiles = @()
foreach ($oldFile in $driveMapping.Keys) {
    $driveLetter = $driveMapping[$oldFile]
    $result = Merge-DriveData -DriveLetter $driveLetter -OldDiskFile $oldFile
    if ($result) {
        $consolidatedFiles += @{ Source = $result; Target = "$logDir\disk_$driveLetter.txt" }
    }
}

# Process CPU and RAM files
$simpleFiles = @("cpu.txt", "ram.txt")
foreach ($fileName in $simpleFiles) {
    if (Test-Path "$BaseDirectory\$fileName") {
        $result = Merge-SimpleFile -FileName $fileName
        if ($result) {
            $consolidatedFiles += @{ Source = $result; Target = "$logDir\$fileName" }
        }
    }
}

#------------------------------------------------------------------------
# Final deployment
#------------------------------------------------------------------------

if ($consolidatedFiles.Count -gt 0) {
    Write-Host "`n========================================================================" -ForegroundColor Yellow
    Write-Host "Ready to deploy consolidated files:" -ForegroundColor Yellow
    
    foreach ($file in $consolidatedFiles) {
        Write-Host "  $($file.Source) → $($file.Target)" -ForegroundColor White
    }
    
    if (-not $WhatIf) {
        $deployConfirm = Read-Host "`nDeploy consolidated files to logs directory? (yes/no)"
        
        if ($deployConfirm -eq "yes") {
            foreach ($file in $consolidatedFiles) {
                # Backup existing file
                if (Test-Path $file.Target) {
                    $backupPath = "$($file.Target).backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    Move-Item -Path $file.Target -Destination $backupPath
                    Write-Host "  ✓ Backed up existing file to: $backupPath" -ForegroundColor Green
                }
                
                # Deploy consolidated file
                Move-Item -Path $file.Source -Destination $file.Target
                Write-Host "  ✓ Deployed: $($file.Target)" -ForegroundColor Green
            }
            
            Write-Host "`n✓ Migration completed successfully!" -ForegroundColor Green
            Write-Host "You can now resume Script 1 (Resource Collection)" -ForegroundColor Cyan
            Write-Host "Consider cleaning up old files in $BaseDirectory" -ForegroundColor Yellow
        } else {
            Write-Host "Migration cancelled. Consolidated files remain in $TempDirectory" -ForegroundColor Yellow
        }
    } else {
        Write-Host "`n[WHATIF] Migration preview completed. Use without -WhatIf to execute." -ForegroundColor Magenta
    }
} else {
    Write-Host "`nNo files to migrate." -ForegroundColor Yellow
}

Write-Host "`n========================================================================" -ForegroundColor Yellow