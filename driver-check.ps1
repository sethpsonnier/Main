#Requires -Version 3.0

param(
    [string]$OutputPath = "C:\Temp",
    [switch]$JsonOutput,
    [switch]$SilentMode,
    [switch]$SkipFileOutput
)

function Convert-Size {
    param([long]$Size)
    
    if ($Size -gt 1TB) {
        return "{0:N2} TB" -f ($Size / 1TB)
    } elseif ($Size -gt 1GB) {
        return "{0:N2} GB" -f ($Size / 1GB)
    } elseif ($Size -gt 1MB) {
        return "{0:N2} MB" -f ($Size / 1MB)
    } elseif ($Size -gt 1KB) {
        return "{0:N2} KB" -f ($Size / 1KB)
    } else {
        return "{0} Bytes" -f $Size
    }
}

function Get-CleanDriverInfo {
    param([string]$Title)
    
    if ($Title -match '^(.+?)\s*-\s*(.+?)\s*-\s*(.+)$') {
        $manufacturer = $Matches[1].Trim()
        $component = $Matches[2].Trim()
        $version = $Matches[3].Trim()
        
        $manufacturer = $manufacturer -replace 'Corporation', 'Corp'
        $manufacturer = $manufacturer -replace 'Technologies', 'Tech'
        $manufacturer = $manufacturer -replace 'Incorporated', 'Inc'
        $manufacturer = $manufacturer -replace 'Limited', 'Ltd'
        
        return "$manufacturer - $component - $version"
    }
    
    return $Title
}

function Write-OutputMessage {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
    
    if (-not $SilentMode) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $formattedMessage = "[$timestamp] [$Type] $Message"
        
        Write-Output $formattedMessage
        
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists("DriverUpdateCheck")) {
                [System.Diagnostics.EventLog]::CreateEventSource("DriverUpdateCheck", "Application")
            }
            
            $eventType = switch ($Type) {
                "Error" { [System.Diagnostics.EventLogEntryType]::Error }
                "Warning" { [System.Diagnostics.EventLogEntryType]::Warning }
                default { [System.Diagnostics.EventLogEntryType]::Information }
            }
            
            Write-EventLog -LogName Application -Source "DriverUpdateCheck" -EventId 1000 -EntryType $eventType -Message $Message
        } catch {
            # Silently continue if event log writing fails
        }
    }
}

$results = @{
    ComputerName = $env:COMPUTERNAME
    Domain = $env:USERDOMAIN
    CheckDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    CheckDateUTC = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    RunAsUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Success = $false
    ErrorMessage = ""
    TotalDriverUpdates = 0
    TotalSizeBytes = 0
    TotalSizeFormatted = "0 MB"
    DriverUpdates = @()
}

Write-OutputMessage "Starting driver update check on $($env:COMPUTERNAME)" "Info"

try {
    $wuService = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($wuService.Status -ne 'Running') {
        Write-OutputMessage "Starting Windows Update service..." "Warning"
        Start-Service -Name wuauserv -ErrorAction Stop
        Start-Sleep -Seconds 5
    }
    
    $UpdateSession = New-Object -ComObject Microsoft.Update.Session
    $UpdateSession.ClientApplicationID = "RMM_DriverUpdateCheck"
    
    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
    $UpdateSearcher.Online = $true
    $UpdateSearcher.ServerSelection = 2
    
    Write-OutputMessage "Searching for driver updates..." "Info"
    
    $SearchResult = $UpdateSearcher.Search("IsInstalled=0 and Type='Driver'")
    
    $results.Success = $true
    $results.TotalDriverUpdates = $SearchResult.Updates.Count
    
    if ($SearchResult.Updates.Count -eq 0) {
        Write-Output ""
        Write-Output "========================================="
        Write-Output "Computer: $($env:COMPUTERNAME)"
        Write-Output "Status: No driver updates available"
        Write-Output "========================================="
    } else {
        $totalSize = 0
        $driverList = @()
        
        foreach ($Update in $SearchResult.Updates) {
            $driverInfo = @{
                Title = $Update.Title
                CleanTitle = Get-CleanDriverInfo -Title $Update.Title
                Description = if ($Update.Description) { $Update.Description.Substring(0, [Math]::Min(500, $Update.Description.Length)) } else { "" }
                DriverModel = if ($Update.DriverModel) { $Update.DriverModel } else { "" }
                DriverVerDate = if ($Update.DriverVerDate) { $Update.DriverVerDate.ToString("yyyy-MM-dd") } else { "" }
                DriverClass = if ($Update.DriverClass) { $Update.DriverClass } else { "" }
                DriverProvider = if ($Update.DriverProvider) { $Update.DriverProvider } else { "" }
                DriverManufacturer = if ($Update.DriverManufacturer) { $Update.DriverManufacturer } else { "" }
                SizeBytes = $Update.MaxDownloadSize
                SizeFormatted = Convert-Size -Size $Update.MaxDownloadSize
                IsMandatory = $Update.IsMandatory
                IsDownloaded = $Update.IsDownloaded
                RebootRequired = $Update.RebootRequired
                Severity = if ($Update.MsrcSeverity) { $Update.MsrcSeverity } else { "Unspecified" }
                LastDeploymentChangeTime = if ($Update.LastDeploymentChangeTime) { $Update.LastDeploymentChangeTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
                Categories = @($Update.Categories | ForEach-Object { $_.Name })
                KBArticleIDs = @($Update.KBArticleIDs)
                UpdateID = $Update.Identity.UpdateID
                RevisionNumber = $Update.Identity.RevisionNumber
            }
            
            $results.DriverUpdates += $driverInfo
            $driverList += $driverInfo
            $totalSize += $Update.MaxDownloadSize
        }
        
        $results.TotalSizeBytes = $totalSize
        $results.TotalSizeFormatted = Convert-Size -Size $totalSize
        
        Write-Output ""
        Write-Output "========================================="
        Write-Output "Computer: $($env:COMPUTERNAME)"
        Write-Output "Total Driver Updates: $($results.TotalDriverUpdates)"
        Write-Output "Total Download Size: $($results.TotalSizeFormatted)"
        Write-Output "========================================="
        Write-Output ""
        Write-Output "Available Driver Updates:"
        Write-Output "-----------------------------------------"
        
        $sortedDrivers = $driverList | Sort-Object SizeBytes -Descending
        
        $counter = 1
        foreach ($driver in $sortedDrivers) {
            $rebootFlag = if ($driver.RebootRequired) { " [Reboot Required]" } else { "" }
            Write-Output "$counter. $($driver.CleanTitle) - $($driver.SizeFormatted)$rebootFlag"
            $counter++
        }
        
        Write-Output "-----------------------------------------"
        
        $rebootCount = ($driverList | Where-Object { $_.RebootRequired -eq $true }).Count
        if ($rebootCount -gt 0) {
            Write-Output ""
            Write-Output "Note: $rebootCount update(s) will require a system restart"
        }
    }
    
} catch {
    $results.Success = $false
    $results.ErrorMessage = $_.Exception.Message
    
    Write-OutputMessage "Error occurred: $($_.Exception.Message)" "Error"
    
    if ($_.Exception.InnerException) {
        Write-OutputMessage "Inner Exception: $($_.Exception.InnerException.Message)" "Error"
    }
    
    Write-Output ""
    Write-Output "========================================="
    Write-Output "Computer: $($env:COMPUTERNAME)"
    Write-Output "Status: Error - $($_.Exception.Message)"
    Write-Output "========================================="
}

if (-not $SkipFileOutput -and $OutputPath -and $OutputPath -ne "") {
    try {
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }
        
        $outputFileName = "$($env:COMPUTERNAME)_DriverUpdates_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        
        if ($JsonOutput) {
            $jsonPath = Join-Path $OutputPath "$outputFileName.json"
            $results | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-OutputMessage "Results saved to: $jsonPath" "Info"
        } else {
            $csvPath = Join-Path $OutputPath "$outputFileName.csv"
            
            if ($results.DriverUpdates.Count -gt 0) {
                $csvData = $results.DriverUpdates | ForEach-Object {
                    [PSCustomObject]@{
                        ComputerName = $results.ComputerName
                        CheckDate = $results.CheckDate
                        DriverTitle = $_.CleanTitle
                        DriverClass = $_.DriverClass
                        Provider = $_.DriverProvider
                        SizeFormatted = $_.SizeFormatted
                        SizeBytes = $_.SizeBytes
                        RebootRequired = $_.RebootRequired
                        Severity = $_.Severity
                        UpdateID = $_.UpdateID
                    }
                }
                $csvData | Export-Csv -Path $csvPath -NoTypeInformation
            } else {
                [PSCustomObject]@{
                    ComputerName = $results.ComputerName
                    CheckDate = $results.CheckDate
                    TotalDriverUpdates = 0
                    Message = "No driver updates available"
                } | Export-Csv -Path $csvPath -NoTypeInformation
            }
            
            Write-OutputMessage "Results saved to: $csvPath" "Info"
        }
    } catch {
        Write-OutputMessage "Failed to save output file: $_" "Error"
    }
}

if (-not $results.Success) {
    exit 1
} elseif ($results.TotalDriverUpdates -gt 20) {
    exit 2
} elseif ($results.TotalDriverUpdates -gt 10) {
    exit 3
} elseif ($results.TotalDriverUpdates -gt 0) {
    exit 4
} else {
    exit 0
}