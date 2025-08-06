#========================================================================
# Resource-Tracking-Cleanup (Automated for RMM)
# Purpose: Remove only old legacy files after successful migration
# Target: *.txt in parent directory and *.txt.backup* in logs directory
# Usage: Automated execution via RMM - no user interaction required
#========================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$BaseDirectory = "C:\temp2",
    
    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

Write-Host "========================================================================" -ForegroundColor Yellow
Write-Host "Resource-Tracking-Cleanup Script (Automated)" -ForegroundColor Yellow
Write-Host "Removing old legacy files after migration" -ForegroundColor Yellow
Write-Host "========================================================================" -ForegroundColor Yellow

$logDir = "$BaseDirectory\logs"

# Verify directories exist
if (-not (Test-Path $BaseDirectory)) {
    Write-Host "ERROR: Base directory not found: $BaseDirectory" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $logDir)) {
    Write-Host "ERROR: Logs directory not found: $logDir" -ForegroundColor Red
    exit 1
}

#------------------------------------------------------------------------
# Function: Safe file removal with verification
#------------------------------------------------------------------------
function Remove-FilesSafely {
    param(
        [string]$Path,
        [string]$Filter,
        [string]$Description
    )
    
    try {
        $filesToRemove = Get-ChildItem -Path $Path -Filter $Filter -File -ErrorAction SilentlyContinue
        
        if ($filesToRemove.Count -eq 0) {
            Write-Host "  No $Description files found" -ForegroundColor Gray
            return 0
        }
        
        Write-Host "  Found $($filesToRemove.Count) $Description files to remove:" -ForegroundColor Cyan
        
        $successCount = 0
        foreach ($file in $filesToRemove) {
            if ($WhatIf) {
                Write-Host "    [WHATIF] Would remove: $($file.FullName)" -ForegroundColor Magenta
                $successCount++
            } else {
                try {
                    Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                    Write-Host "    ✓ Removed: $($file.Name)" -ForegroundColor Green
                    $successCount++
                }
                catch {
                    Write-Host "    ✗ Failed to remove $($file.Name): $_" -ForegroundColor Red
                }
            }
        }
        
        Write-Host "  Result: $successCount of $($filesToRemove.Count) files processed successfully" -ForegroundColor White
        return $successCount
    }
    catch {
        Write-Host "  ERROR scanning for $Description files: $_" -ForegroundColor Red
        return 0
    }
}

#------------------------------------------------------------------------
# Cleanup Phase 1: Remove *.txt files from parent directory ONLY
#------------------------------------------------------------------------
Write-Host "`nPhase 1: Removing legacy *.txt files from parent directory" -ForegroundColor Yellow
Write-Host "Location: $BaseDirectory" -ForegroundColor Gray
Write-Host "Target: All *.txt files (cpu.txt, ram.txt, disk*.txt, etc.)" -ForegroundColor Gray

# Show what we're targeting first
$parentTxtFiles = Get-ChildItem -Path $BaseDirectory -Filter "*.txt" -File -ErrorAction SilentlyContinue
if ($parentTxtFiles.Count -gt 0) {
    Write-Host "Files to be removed:" -ForegroundColor Cyan
    foreach ($file in $parentTxtFiles) {
        Write-Host "  - $($file.Name) ($([math]::Round($file.Length/1KB, 1)) KB)" -ForegroundColor White
    }
    
    # Automated removal - no prompts
    $phase1Results = Remove-FilesSafely -Path $BaseDirectory -Filter "*.txt" -Description "legacy TXT"
    Write-Host "Phase 1 completed: $phase1Results files removed" -ForegroundColor Green
} else {
    Write-Host "No *.txt files found in parent directory" -ForegroundColor Gray
}

#------------------------------------------------------------------------
# Cleanup Phase 2: Remove *.txt.backup* files from logs directory
#------------------------------------------------------------------------
Write-Host "`nPhase 2: Removing backup files from logs directory" -ForegroundColor Yellow
Write-Host "Location: $logDir" -ForegroundColor Gray
Write-Host "Target: *.txt.backup* files (migration backup files)" -ForegroundColor Gray

# Show what we're targeting
$backupFiles = Get-ChildItem -Path $logDir -Filter "*.txt.backup*" -File -ErrorAction SilentlyContinue
if ($backupFiles.Count -gt 0) {
    Write-Host "Backup files to be removed:" -ForegroundColor Cyan
    foreach ($file in $backupFiles) {
        Write-Host "  - $($file.Name) ($([math]::Round($file.Length/1KB, 1)) KB)" -ForegroundColor White
    }
    
    # Automated removal - no prompts
    $phase2Results = Remove-FilesSafely -Path $logDir -Filter "*.txt.backup*" -Description "backup"
    Write-Host "Phase 2 completed: $phase2Results backup files removed" -ForegroundColor Green
} else {
    Write-Host "No backup files found in logs directory" -ForegroundColor Gray
}

#------------------------------------------------------------------------
# Verification: Show what remains
#------------------------------------------------------------------------
Write-Host "`n========================================================================" -ForegroundColor Yellow
Write-Host "Cleanup Summary" -ForegroundColor Yellow

if (-not $WhatIf) {
    Write-Host "`nRemaining files in parent directory:" -ForegroundColor Green
    $remainingParent = Get-ChildItem -Path $BaseDirectory -File -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -notlike "chart_*" }
    
    if ($remainingParent.Count -gt 0) {
        foreach ($file in $remainingParent) {
            $fileType = if ($file.Extension -eq ".css") { "CSS" } 
                       elseif ($file.Extension -eq ".txt") { "TXT (should be cleaned)" } 
                       else { "OTHER" }
            Write-Host "  ✓ $($file.Name) [$fileType]" -ForegroundColor White
        }
    } else {
        Write-Host "  (Only chart files remain in parent directory)" -ForegroundColor Gray
    }
    
    Write-Host "`nCurrent files in logs directory:" -ForegroundColor Green
    $remainingLogs = Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue
    
    if ($remainingLogs.Count -gt 0) {
        foreach ($file in $remainingLogs) {
            $fileType = if ($file.Name -like "*.backup*") { "BACKUP (should be cleaned)" } 
                       elseif ($file.Extension -eq ".txt") { "ACTIVE LOG" }
                       else { "OTHER" }
            Write-Host "  ✓ $($file.Name) [$fileType]" -ForegroundColor White
        }
    } else {
        Write-Host "  (No files in logs directory)" -ForegroundColor Gray
    }
    
    # Summary statistics
    $totalParentFiles = (Get-ChildItem -Path $BaseDirectory -File -ErrorAction SilentlyContinue).Count
    $totalLogFiles = (Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue).Count
    
    Write-Host "`nFinal counts:" -ForegroundColor Cyan
    Write-Host "  Parent directory: $totalParentFiles files" -ForegroundColor White
    Write-Host "  Logs directory: $totalLogFiles files" -ForegroundColor White
    
} else {
    Write-Host "`n[WHATIF] Preview completed. Use without -WhatIf to execute cleanup." -ForegroundColor Magenta
}

Write-Host "`n✓ Automated cleanup process completed!" -ForegroundColor Green
Write-Host "========================================================================" -ForegroundColor Yellow