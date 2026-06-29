# M365 All Users Report Script

Write-Host "=== M365 All Users Report ===" -ForegroundColor Cyan
Write-Host "Generating comprehensive organizational report..." -ForegroundColor Gray

# Import required modules
try {
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    Import-Module Microsoft.Graph.Reports -ErrorAction Stop  
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
} catch {
    Write-Error "Failed to import required modules. Please install:"
    Write-Host "Install-Module Microsoft.Graph -Scope CurrentUser -Force"
    Write-Host "Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force"
    exit
}

# Connect to services
Write-Host "`nConnecting to services..." -ForegroundColor Green
try {
    Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All", "Reports.Read.All" -NoWelcome -ErrorAction Stop
} catch {
    Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    exit
}

try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
} catch {
    Write-Error "Failed to connect to Exchange Online: $($_.Exception.Message)"
    exit
}

# Improved function to parse mailbox size strings accurately (using working script method)
function Parse-MailboxSize {
    param ([string]$SizeString)
    
    if ([string]::IsNullOrEmpty($SizeString)) { return 0 }
    
    try {
        # Use the same regex pattern as the working script for better accuracy
        if ($SizeString -match "^.*\(([\d,]+) bytes\)") {
            $sizeInBytes = [long]($Matches[1] -replace ',','')
            return [math]::Round($sizeInBytes / 1GB, 2)
        }
        # Fallback patterns
        if ($SizeString -match '([0-9.]+)\s*GB') {
            return [math]::Round([double]$matches[1], 2)
        }
        if ($SizeString -match '([0-9.]+)\s*MB') {
            return [math]::Round([double]$matches[1] / 1024, 2)
        }
        if ($SizeString -match '([0-9.]+)\s*KB') {
            return [math]::Round([double]$matches[1] / 1024 / 1024, 2)
        }
        return 0
    } catch {
        return 0
    }
}

# Get organization info
Write-Host "`nRetrieving organization data..." -ForegroundColor Yellow
try {
    $orgInfo = Get-MgOrganization | Select-Object -First 1
    $tenantName = $orgInfo.DisplayName
} catch {
    $tenantName = "Unknown Organization"
}

# Pre-cache license information
Write-Host "Loading license information..." -ForegroundColor Yellow
$licenseCache = @{}
try {
    $allLicenses = Get-MgSubscribedSku
    foreach ($license in $allLicenses) {
        $licenseCache[$license.SkuId] = $license.SkuPartNumber
    }
} catch {
    Write-Warning "Could not cache license information"
}

# Get users
Write-Host "Retrieving user data..." -ForegroundColor Yellow
try {
    $users = Get-MgUser -All -Property "Id,DisplayName,UserPrincipalName,UserType,AssignedLicenses,AccountEnabled" | 
        Where-Object { $_.UserType -eq "Member" -or $_.UserType -eq "Guest" }
    
    $totalUsers = $users.Count
    Write-Host "Found $totalUsers users to process" -ForegroundColor Green
} catch {
    Write-Error "Failed to retrieve users: $($_.Exception.Message)"
    exit
}

# Confirm processing
$confirm = Read-Host "`nContinue processing $totalUsers users? (y/n)"
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-Host "Operation cancelled." -ForegroundColor Yellow
    exit
}

# Filter users likely to have mailboxes
$usersToCheck = $users | Where-Object { 
    $_.AssignedLicenses.Count -gt 0 -or 
    $_.UserPrincipalName -like "*@*.onmicrosoft.com" -or
    $_.DisplayName -like "*shared*" -or
    $_.DisplayName -like "*room*" -or
    $_.DisplayName -like "*resource*"
}

# Determine optimal processing threads
$optimalThreads = [Math]::Min([Environment]::ProcessorCount * 2, 10)

# Initialize results and counters
$results = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
$processedCount = [ref] 0
$totalToProcess = $users.Count

Write-Host "`nProcessing users..." -ForegroundColor Cyan

# Process users in parallel
$users | ForEach-Object -Parallel {
    # Import the functions into each parallel thread
    function Parse-MailboxSize {
        param ([string]$SizeString)
        if ([string]::IsNullOrEmpty($SizeString)) { return 0 }
        try {
            # Use the same regex pattern as the working script for better accuracy
            if ($SizeString -match "^.*\(([\d,]+) bytes\)") {
                $sizeInBytes = [long]($Matches[1] -replace ',','')
                return [math]::Round($sizeInBytes / 1GB, 2)
            }
            # Fallback patterns
            if ($SizeString -match '([0-9.]+)\s*GB') {
                return [math]::Round([double]$matches[1], 2)
            }
            if ($SizeString -match '([0-9.]+)\s*MB') {
                return [math]::Round([double]$matches[1] / 1024, 2)
            }
            return 0
        } catch { return 0 }
    }
    
    $user = $_
    $licenseCache = $using:licenseCache
    $results = $using:results
    $processedCount = $using:processedCount
    $totalToProcess = $using:totalToProcess
    
    # Show progress every 50 users
    $current = [System.Threading.Interlocked]::Increment($processedCount)
    if ($current % 50 -eq 0) {
        $percent = [math]::Round(($current / $totalToProcess) * 100, 1)
        Write-Host "Processed $current / $totalToProcess users ($percent%)" -ForegroundColor Yellow
    }
    
    # Initialize user object
    $userInfo = [PSCustomObject]@{
        UserPrincipalName = $user.UserPrincipalName
        DisplayName = $user.DisplayName
        UserType = $user.UserType
        AccountEnabled = $user.AccountEnabled
        Licenses = "No licenses"
        MailboxSize = "No mailbox"
        MaxMailboxSize = "No mailbox"
        ArchiveEnabled = "No mailbox"
        ArchiveSize = "No mailbox"
    }
    
    try {
        # Process licenses using cached data
        if ($user.AssignedLicenses.Count -gt 0) {
            $licenseNames = @()
            foreach ($license in $user.AssignedLicenses) {
                $licenseNames += if ($licenseCache.ContainsKey($license.SkuId)) { 
                    $licenseCache[$license.SkuId] 
                } else { 
                    $license.SkuId 
                }
            }
            $userInfo.Licenses = ($licenseNames -join "; ")
        }
        
        # Check for mailboxes if user is likely to have one
        $shouldCheckMailbox = $user.AssignedLicenses.Count -gt 0 -or 
                             $user.UserPrincipalName -like "*@*.onmicrosoft.com" -or
                             $user.DisplayName -like "*shared*" -or
                             $user.DisplayName -like "*room*"
        
        if ($shouldCheckMailbox) {
            # Find mailbox
            $mailbox = $null
            $mailboxFound = $false
            
            # Try Get-EXOMailbox first
            try {
                $mailbox = Get-EXOMailbox -Identity $user.UserPrincipalName -ErrorAction Stop
                $mailboxFound = $true
            } catch {
                try {
                    $mailbox = Get-Mailbox -Identity $user.UserPrincipalName -ErrorAction Stop
                    $mailboxFound = $true
                } catch {
                    # No mailbox found
                }
            }
            
            if ($mailboxFound -and $mailbox) {
                # Update user type for shared mailboxes
                if ($mailbox.RecipientTypeDetails -eq "SharedMailbox") {
                    $userInfo.UserType = "Shared"
                }
                
                # Get mailbox statistics - using same method as working script
                try {
                    # Try Get-MailboxStatistics first (consistent with working script approach)
                    $mailboxStats = Get-MailboxStatistics -Identity $user.UserPrincipalName -ErrorAction Stop
                } catch {
                    try {
                        $mailboxStats = Get-EXOMailboxStatistics -Identity $user.UserPrincipalName -ErrorAction Stop
                    } catch {
                        $mailboxStats = $null
                    }
                }
                
                if ($mailboxStats -and $mailboxStats.TotalItemSize) {
                    # Use the same direct parsing method as the working script
                    $sizeString = $mailboxStats.TotalItemSize.ToString()
                    if ($sizeString -match "^.*\(([\d,]+) bytes\)") {
                        $sizeInBytes = [long]($Matches[1] -replace ',','')
                        $mailboxSizeGB = [math]::Round($sizeInBytes / 1GB, 2)
                        $userInfo.MailboxSize = "$mailboxSizeGB GB"
                    } else {
                        # Fallback to function parsing if format is different
                        $sizeGB = Parse-MailboxSize -SizeString $sizeString
                        $userInfo.MailboxSize = "$sizeGB GB"
                    }
                } else {
                    $userInfo.MailboxSize = "0 GB"
                }
                
                # Get quota
                $quota = $mailbox.ProhibitSendReceiveQuota
                if (-not $quota -or $quota -eq "Unlimited") {
                    $quota = $mailbox.ProhibitSendQuota
                }
                
                if ($quota -and $quota -ne "Unlimited") {
                    $quotaString = $quota.ToString()
                    if ($quotaString -match '([0-9.]+)\s*GB') {
                        $userInfo.MaxMailboxSize = "$([math]::Round([double]$matches[1], 2)) GB"
                    } else {
                        $userInfo.MaxMailboxSize = $quotaString
                    }
                } else {
                    $userInfo.MaxMailboxSize = "50 GB"
                }
                
                # ARCHIVE CHECKING - using exact same approach as working script
                # Just try to get archive statistics directly (like working script does)
                try {
                    # Try Get-MailboxStatistics directly (as used in working script)
                    $archiveStats = Get-MailboxStatistics -Identity $user.UserPrincipalName -Archive -ErrorAction Stop
                    
                    if ($archiveStats -and $archiveStats.TotalItemSize) {
                        # Archive exists and has data
                        $userInfo.ArchiveEnabled = "Enabled"
                        
                        # Use the same parsing method as the working script
                        $sizeString = $archiveStats.TotalItemSize.ToString()
                        if ($sizeString -match "^.*\(([\d,]+) bytes\)") {
                            $sizeInBytes = [long]($Matches[1] -replace ',','')
                            $archiveSizeGB = [math]::Round($sizeInBytes / 1GB, 2)
                            $userInfo.ArchiveSize = "$archiveSizeGB GB"
                        } else {
                            # Fallback to original parsing if the format is different
                            $archiveSizeGB = Parse-MailboxSize -SizeString $sizeString
                            $userInfo.ArchiveSize = "$archiveSizeGB GB"
                        }
                    } else {
                        # Archive exists but is empty
                        $userInfo.ArchiveEnabled = "Enabled"
                        $userInfo.ArchiveSize = "0 GB"
                    }
                } catch {
                    # Try EXO method as fallback
                    try {
                        $archiveStats = Get-EXOMailboxStatistics -Identity $user.UserPrincipalName -Archive -ErrorAction Stop
                        
                        if ($archiveStats -and $archiveStats.TotalItemSize) {
                            # Archive exists and has data
                            $userInfo.ArchiveEnabled = "Enabled"
                            
                            $sizeString = $archiveStats.TotalItemSize.ToString()
                            if ($sizeString -match "^.*\(([\d,]+) bytes\)") {
                                $sizeInBytes = [long]($Matches[1] -replace ',','')
                                $archiveSizeGB = [math]::Round($sizeInBytes / 1GB, 2)
                                $userInfo.ArchiveSize = "$archiveSizeGB GB"
                            } else {
                                $archiveSizeGB = Parse-MailboxSize -SizeString $sizeString
                                $userInfo.ArchiveSize = "$archiveSizeGB GB"
                            }
                        } else {
                            # Archive exists but is empty
                            $userInfo.ArchiveEnabled = "Enabled"
                            $userInfo.ArchiveSize = "0 GB"
                        }
                    } catch {
                        # No archive or can't access it
                        $userInfo.ArchiveEnabled = "Disabled"
                        $userInfo.ArchiveSize = "N/A"
                    }
                }
            }
        }
        
    } catch {
        # Error processing user - keep defaults
    }
    
    $results.Add($userInfo)
    
} -ThrottleLimit $optimalThreads

# Convert results and sort
Write-Host "`nFinalizing results..." -ForegroundColor Yellow
$finalResults = $results.ToArray() | Sort-Object UserPrincipalName

# Generate report
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath = "M365_AllUsers_Report_$timestamp.csv"

$finalResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# Calculate summary statistics
$usersWithMailboxes = ($finalResults | Where-Object { $_.MailboxSize -ne "No mailbox" }).Count
$licensedUsers = ($finalResults | Where-Object { $_.Licenses -ne "No licenses" }).Count
$archiveEnabledUsers = ($finalResults | Where-Object { $_.ArchiveEnabled -eq "Enabled" }).Count
$sharedMailboxes = ($finalResults | Where-Object { $_.UserType -eq "Shared" }).Count

$totalMailboxSizeGB = ($finalResults | Where-Object { $_.MailboxSize -match "GB$" } | 
    ForEach-Object { [double]($_.MailboxSize -replace " GB", "") } | Measure-Object -Sum).Sum

$totalArchiveSizeGB = ($finalResults | Where-Object { $_.ArchiveSize -match "GB$" } | 
    ForEach-Object { [double]($_.ArchiveSize -replace " GB", "") } | Measure-Object -Sum).Sum

# Display summary
Write-Host "`n=== SUMMARY STATISTICS ===" -ForegroundColor Cyan
Write-Host "Organization: $tenantName" -ForegroundColor White
Write-Host "Report Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host ""
Write-Host "USERS:" -ForegroundColor Yellow
Write-Host "  Total Users: $($finalResults.Count)" -ForegroundColor White
Write-Host "  Licensed Users: $licensedUsers" -ForegroundColor White
Write-Host "  Users with Mailboxes: $usersWithMailboxes" -ForegroundColor White
Write-Host "  Shared Mailboxes: $sharedMailboxes" -ForegroundColor White
Write-Host "  Archive Enabled: $archiveEnabledUsers" -ForegroundColor White
Write-Host ""
Write-Host "STORAGE:" -ForegroundColor Yellow
Write-Host "  Total Mailbox Usage: $([math]::Round($totalMailboxSizeGB, 2)) GB" -ForegroundColor White
Write-Host "  Total Archive Usage: $([math]::Round($totalArchiveSizeGB, 2)) GB" -ForegroundColor White

# Top 5 mailbox users
$topUsers = $finalResults | Where-Object { $_.MailboxSize -match "GB$" } | 
    Sort-Object @{Expression={[double]($_.MailboxSize -replace " GB", "")}} -Descending | Select-Object -First 5

if ($topUsers.Count -gt 0) {
    Write-Host ""
    Write-Host "TOP 5 MAILBOX USERS:" -ForegroundColor Yellow
    foreach ($user in $topUsers) {
        Write-Host "  $($user.DisplayName): $($user.MailboxSize)" -ForegroundColor White
    }
}

# Disconnect
Disconnect-MgGraph | Out-Null
Disconnect-ExchangeOnline -Confirm:$false

Write-Host "`n✓ Report completed successfully!" -ForegroundColor Green
Write-Host "Report location: $((Get-Location).Path)\$csvPath" -ForegroundColor Cyan