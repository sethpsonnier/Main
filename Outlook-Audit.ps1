<#
.SYNOPSIS
    Detects Outlook installation location, bitness, and version.
.DESCRIPTION
    Checks registry for authoritative Office bitness, then verifies file presence.
    Targets PowerShell 5.1 for NinjaRMM compatibility.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-OutlookInstallInfo {
    $result = [PSCustomObject]@{
        Installed       = $false
        Bitness         = $null
        InstallPath     = $null
        ExecutablePath  = $null
        FileExists      = $false
        FileBitness     = $null
        Version         = $null
        ProductVersion  = $null
        ClickToRun      = $false
        OfficeBitness   = $null
        DetectionMethod = $null
    }

    # Method 1: Click-to-Run registry (most modern installs - M365, Office 2019/2021/2024)
    $c2rPath = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (Test-Path $c2rPath) {
        try {
            $c2r = Get-ItemProperty -Path $c2rPath -ErrorAction Stop
            $result.ClickToRun    = $true
            $result.OfficeBitness = $c2r.Platform   # 'x64' or 'x86'
            $result.InstallPath   = $c2r.InstallationPath
            $result.DetectionMethod = 'ClickToRun'
        } catch {}
    }

    # Method 2: Outlook App Paths (works for MSI installs and older Office)
    $appPathKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE'
    )
    foreach ($key in $appPathKeys) {
        if (Test-Path $key) {
            try {
                $appPath = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
                if ($appPath -and (Test-Path $appPath)) {
                    if (-not $result.ExecutablePath) {
                        $result.ExecutablePath = $appPath
                        if (-not $result.DetectionMethod) {
                            $result.DetectionMethod = 'AppPaths'
                        }
                    }
                }
            } catch {}
        }
    }

    # Method 3: Derive EXE path from C2R InstallationPath if not yet found
    if (-not $result.ExecutablePath -and $result.InstallPath) {
        $candidate = Join-Path $result.InstallPath 'OUTLOOK.EXE'
        if (Test-Path $candidate) {
            $result.ExecutablePath = $candidate
        }
    }

    # Method 4: Brute-force common install locations as last resort
    if (-not $result.ExecutablePath) {
        $commonPaths = @(
            "${env:ProgramFiles}\Microsoft Office\root\Office16\OUTLOOK.EXE",
            "${env:ProgramFiles}\Microsoft Office\Office16\OUTLOOK.EXE",
            "${env:ProgramFiles}\Microsoft Office\root\Office15\OUTLOOK.EXE",
            "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16\OUTLOOK.EXE",
            "${env:ProgramFiles(x86)}\Microsoft Office\Office16\OUTLOOK.EXE",
            "${env:ProgramFiles(x86)}\Microsoft Office\root\Office15\OUTLOOK.EXE"
        )
        foreach ($p in $commonPaths) {
            if (Test-Path $p) {
                $result.ExecutablePath = $p
                $result.DetectionMethod = 'PathScan'
                break
            }
        }
    }

    # Inspect the file we found
    if ($result.ExecutablePath -and (Test-Path $result.ExecutablePath)) {
        $result.Installed     = $true
        $result.FileExists    = $true
        $fileInfo             = Get-Item $result.ExecutablePath
        $result.Version       = $fileInfo.VersionInfo.FileVersion
        $result.ProductVersion= $fileInfo.VersionInfo.ProductVersion

        # Determine bitness of the EXE itself by reading the PE header
        # This is the ground truth, regardless of what the registry says
        try {
            $bytes = [System.IO.File]::ReadAllBytes($result.ExecutablePath)[0..4095]
            # PE header offset is at 0x3C (little-endian 4 bytes)
            $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
            # Machine type is 4 bytes after 'PE\0\0' signature
            $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
            switch ($machine) {
                0x014c { $result.FileBitness = '32-bit (x86)' }
                0x8664 { $result.FileBitness = '64-bit (x64)' }
                0xAA64 { $result.FileBitness = '64-bit (ARM64)' }
                default { $result.FileBitness = "Unknown (0x{0:X4})" -f $machine }
            }
        } catch {
            $result.FileBitness = "Error reading PE header: $($_.Exception.Message)"
        }

        # Path-based heuristic as cross-check
        if ($result.ExecutablePath -like '*Program Files (x86)*') {
            $result.Bitness = '32-bit'
        } elseif ($result.ExecutablePath -like '*Program Files*') {
            $result.Bitness = '64-bit'
        }
    }

    return $result
}

# --- Run and report ---
$info = Get-OutlookInstallInfo

Write-Output "============================================"
Write-Output " Outlook Installation Detection - $env:COMPUTERNAME"
Write-Output "============================================"
Write-Output "Installed:        $($info.Installed)"
Write-Output "Detection Method: $($info.DetectionMethod)"
Write-Output "Executable Path:  $($info.ExecutablePath)"
Write-Output "Path Bitness:     $($info.Bitness)"
Write-Output "PE Header Bitness:$($info.FileBitness)   <-- authoritative"
Write-Output "Office (C2R):     Platform=$($info.OfficeBitness)  ClickToRun=$($info.ClickToRun)"
Write-Output "File Version:     $($info.Version)"
Write-Output "Product Version:  $($info.ProductVersion)"
Write-Output "Install Path:     $($info.InstallPath)"
Write-Output "============================================"

# Optional: write to NinjaRMM custom field if you want fleet visibility
# Ninja-Property-Set outlookBitness $info.FileBitness
# Ninja-Property-Set outlookVersion $info.Version