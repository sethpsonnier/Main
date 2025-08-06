[CmdletBinding()]
param(
    [int]$DaysBack = 7,
    [string]$ComputerName = $env:COMPUTERNAME,
    [switch]$Detailed,
    [switch]$Help,
    [int]$TopCount = 10,
    [string]$ExportPath = "C:\Temp"
)

# Help function
function Show-Help {
    Write-Host @"

NTLM AUDIT SCRIPT - HELP
========================

SYNOPSIS:
    Analyzes NTLM authentication events in Windows Security logs to identify
    usage patterns, security risks, and remediation opportunities.

PARAMETERS:
    -DaysBack <int>         Number of days to analyze (default: 7)
    -ComputerName <string>  Target computer to analyze (default: local computer)
    -Detailed              Show detailed information about accounts and objects
    -Help                  Show this help message
    -TopCount <int>        Number of top results to display (default: 10)
    -ExportPath <string>   Path for exported CSV files (default: C:\Temp)

EXAMPLES:
    .\NTLM-audit.ps1
    .\NTLM-audit.ps1 -DaysBack 30 -Detailed
    .\NTLM-audit.ps1 -ComputerName DC01 -TopCount 20
    .\NTLM-audit.ps1 -Detailed -ExportPath "D:\Reports"

OUTPUT:
    - Console analysis with statistics and top users/computers
    - CSV export with detailed event data
    - With -Detailed: Additional Active Directory account information

REQUIREMENTS:
    - Run as Administrator or user with Security log read permissions
    - Active Directory PowerShell module (for -Detailed flag)
    - Appropriate NTLM logging enabled via Group Policy

"@ -ForegroundColor Cyan
}

# Show help and exit if requested
if ($Help) {
    Show-Help
    return
}

# Function to get detailed AD object information
function Get-DetailedAccountInfo {
    param(
        [string[]]$AccountNames,
        [string]$ObjectType = "User"
    )
    
    if (-not $Detailed -or -not $AccountNames) { 
        return @() 
    }
    
    Write-Host "    Gathering detailed Active Directory information..." -ForegroundColor Yellow
    
    $DetailedInfo = @()
    
    try {
        # Check if AD module is available
        if (-not (Get-Module -ListAvailable ActiveDirectory)) {
            Write-Host "    Warning: ActiveDirectory module not available. Install RSAT for detailed info." -ForegroundColor Yellow
            return @()
        }
        
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        
        foreach ($Account in $AccountNames) {
            if ([string]::IsNullOrWhiteSpace($Account)) { continue }
            
            try {
                $ADObject = $null
                if ($ObjectType -eq "User") {
                    $ADObject = Get-ADUser $Account -Properties Description, LastLogonDate, PasswordLastSet, Enabled, LockedOut, ServicePrincipalNames, MemberOf, Created, Modified -ErrorAction SilentlyContinue
                } else {
                    $ADObject = Get-ADComputer $Account -Properties Description, LastLogonDate, Enabled, ServicePrincipalNames, MemberOf, Created, Modified, OperatingSystem -ErrorAction SilentlyContinue
                }
                
                if ($ADObject) {
                    $MemberOfGroups = ""
                    if ($ADObject.MemberOf) {
                        try {
                            $MemberOfGroups = ($ADObject.MemberOf | Get-ADGroup -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join "; "
                        } catch {
                            Write-Verbose "Could not resolve group memberships for $Account"
                        }
                    }
                    
                    $DetailedInfo += [PSCustomObject]@{
                        Name = $ADObject.Name
                        SamAccountName = $ADObject.SamAccountName
                        ObjectType = $ObjectType
                        Description = $ADObject.Description
                        LastLogonDate = $ADObject.LastLogonDate
                        PasswordLastSet = if ($ObjectType -eq "User") { $ADObject.PasswordLastSet } else { "N/A" }
                        Enabled = $ADObject.Enabled
                        LockedOut = if ($ObjectType -eq "User") { $ADObject.LockedOut } else { "N/A" }
                        ServicePrincipalNames = ($ADObject.ServicePrincipalNames -join "; ")
                        MemberOf = $MemberOfGroups
                        DistinguishedName = $ADObject.DistinguishedName
                        Created = $ADObject.Created
                        Modified = $ADObject.Modified
                        OperatingSystem = if ($ObjectType -eq "Computer") { $ADObject.OperatingSystem } else { "N/A" }
                    }
                }
            } catch {
                Write-Verbose "Could not get details for ${Account}: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Host "    Error accessing Active Directory: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    return $DetailedInfo
}

# Function to analyze service accounts
function Show-ServiceAccountAnalysis {
    param($AccountList)
    
    if (-not $AccountList) { return }
    
    Write-Host "`n    Service Account Analysis:" -ForegroundColor Cyan
    
    $ServiceAccounts = $AccountList | Where-Object {
        $_.Name -like "*svc*" -or 
        $_.Name -like "*service*" -or 
        $_.Name -like "*$" -or
        $_.Name -match "^[a-zA-Z]+_[a-zA-Z]+$"
    }
    
    if ($ServiceAccounts) {
        Write-Host "    Potential service accounts detected:" -ForegroundColor Yellow
        foreach ($Account in $ServiceAccounts) {
            Write-Host "      - $($Account.Name): $($Account.Count) NTLM attempts" -ForegroundColor White
            
            if ($Detailed -and $Account.Name -notlike "*$") {
                $Details = Get-DetailedAccountInfo -AccountNames @($Account.Name) -ObjectType "User"
                if ($Details) {
                    foreach ($Detail in $Details) {
                        Write-Host "        Description: $($Detail.Description)" -ForegroundColor Gray
                        Write-Host "        Last Logon: $($Detail.LastLogonDate)" -ForegroundColor Gray
                        Write-Host "        SPNs: $($Detail.ServicePrincipalNames)" -ForegroundColor Gray
                        if ($Detail.ServicePrincipalNames) {
                            Write-Host "        [PASS] Has SPNs (can potentially use Kerberos)" -ForegroundColor Green
                        } else {
                            Write-Host "        [WARNING] No SPNs configured (NTLM only)" -ForegroundColor Red
                        }
                    }
                }
            }
        }
    } else {
        Write-Host "    No obvious service accounts detected in top users" -ForegroundColor Green
    }
}

# Function to analyze computer accounts
function Show-ComputerAccountAnalysis {
    param($ComputerList)
    
    if (-not $ComputerList) { return }
    
    Write-Host "`n    Computer Account Analysis:" -ForegroundColor Cyan
    
    $ComputerAccounts = $ComputerList | Where-Object {$_.Name -like "*$"}
    
    if ($ComputerAccounts) {
        Write-Host "    Computer accounts using NTLM:" -ForegroundColor Yellow
        foreach ($Computer in $ComputerAccounts) {
            Write-Host "      - $($Computer.Name): $($Computer.Count) NTLM attempts" -ForegroundColor White
            
            if ($Detailed) {
                $CleanName = $Computer.Name -replace '\$$', ''
                $Details = Get-DetailedAccountInfo -AccountNames @($CleanName) -ObjectType "Computer"
                if ($Details) {
                    foreach ($Detail in $Details) {
                        Write-Host "        Description: $($Detail.Description)" -ForegroundColor Gray
                        Write-Host "        Last Logon: $($Detail.LastLogonDate)" -ForegroundColor Gray
                        if ($Detail.OperatingSystem -ne "N/A") {
                            Write-Host "        OS: $($Detail.OperatingSystem)" -ForegroundColor Gray
                        }
                    }
                }
            }
        }
    } else {
        Write-Host "    No computer accounts found in top NTLM users" -ForegroundColor Green
    }
}

# Function to show detailed source analysis
function Show-SourceAnalysis {
    param($TopSources, $AllEvents)
    
    if (-not $Detailed -or -not $TopSources -or -not $AllEvents) { return }
    
    Write-Host "`n    Source Workstation Analysis:" -ForegroundColor Cyan
    
    $TopSources | Select-Object -First 5 | ForEach-Object {
        $SourceName = $_.Name
        $SourceCount = $_.Count
        Write-Host "    - $SourceName ($SourceCount attempts)" -ForegroundColor White
        
        # Try to get computer info if it looks like a computer name
        if ($SourceName -match '^[A-Z0-9-]+$' -and $SourceName -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            $CompDetails = Get-DetailedAccountInfo -AccountNames @($SourceName) -ObjectType "Computer"
            if ($CompDetails) {
                foreach ($Detail in $CompDetails) {
                    Write-Host "      Description: $($Detail.Description)" -ForegroundColor Gray
                    Write-Host "      Last Logon: $($Detail.LastLogonDate)" -ForegroundColor Gray
                }
            }
        }
        
        # Show which users authenticate from this source
        $UsersFromSource = $AllEvents | Where-Object {$_.SourceWorkstation -eq $SourceName} | 
                          Group-Object UserName | Sort-Object Count -Descending | Select-Object -First 3
        if ($UsersFromSource) {
            Write-Host "      Top users from this source:" -ForegroundColor Gray
            $UsersFromSource | ForEach-Object { 
                Write-Host "        - $($_.Name): $($_.Count) attempts" -ForegroundColor DarkGray 
            }
        }
    }
}

# Function to provide remediation recommendations
function Show-RemediationRecommendations {
    param(
        [double]$NTLMPercent,
        $TopUsers,
        $TopSources
    )
    
    if (-not $Detailed) { return }
    
    Write-Host "`nREMEDIATION RECOMMENDATIONS:" -ForegroundColor Cyan
    
    if ($NTLMPercent -gt 50) {
        Write-Host "  PRIORITY 1 - CRITICAL: $NTLMPercent% NTLM usage is extremely high" -ForegroundColor Red
        Write-Host "  - Focus on top 3 accounts - they likely drive most usage" -ForegroundColor Yellow
        Write-Host "  - DO NOT implement NTLM restrictions until major accounts are fixed" -ForegroundColor Red
    } elseif ($NTLMPercent -gt 20) {
        Write-Host "  PRIORITY 2 - HIGH: $NTLMPercent% NTLM usage needs attention" -ForegroundColor Yellow
        Write-Host "  - Target service accounts first" -ForegroundColor Yellow
        Write-Host "  - Plan gradual NTLM restriction rollout" -ForegroundColor Yellow
    } elseif ($NTLMPercent -gt 5) {
        Write-Host "  PRIORITY 3 - MEDIUM: $NTLMPercent% NTLM usage is manageable" -ForegroundColor Yellow
        Write-Host "  - Safe to begin careful NTLM restrictions" -ForegroundColor Green
        Write-Host "  - Monitor specific use cases" -ForegroundColor Yellow
    } else {
        Write-Host "  PRIORITY 4 - LOW: $NTLMPercent% NTLM usage is minimal" -ForegroundColor Green
        Write-Host "  - Consider implementing NTLM restrictions" -ForegroundColor Green
        Write-Host "  - Focus on remaining edge cases" -ForegroundColor Green
    }
    
    if ($TopUsers -and $TopSources) {
        Write-Host "`n  Next Steps:" -ForegroundColor White
        $TopUserNames = ($TopUsers | Select-Object -First 3).Name -join ', '
        $TopSourceNames = ($TopSources | Select-Object -First 3).Name -join ', '
        Write-Host "  1. Analyze top users: $TopUserNames" -ForegroundColor White
        Write-Host "  2. Check application configurations on: $TopSourceNames" -ForegroundColor White
        Write-Host "  3. Configure SPNs for service accounts" -ForegroundColor White
        Write-Host "  4. Test Kerberos authentication in lab environment" -ForegroundColor White
        Write-Host "  5. Implement gradual NTLM restrictions with monitoring" -ForegroundColor White
    }
}

# Function to get and parse events
function Get-NTLMEvents {
    param(
        [int]$EventID,
        [string]$LogName = 'Security',
        [datetime]$StartTime,
        [string]$ComputerName
    )
    
    try {
        $Events = Get-WinEvent -FilterHashtable @{
            LogName = $LogName
            ID = $EventID
            StartTime = $StartTime
        } -ComputerName $ComputerName -ErrorAction SilentlyContinue
        
        return $Events
    } catch {
        Write-Verbose "Error querying Event $EventID`: $($_.Exception.Message)"
        return $null
    }
}

# Main script execution
Write-Host "=== NTLM Audit Analysis for $ComputerName ===" -ForegroundColor Cyan
Write-Host "Analyzing last $DaysBack days of logs..." -ForegroundColor Yellow
if ($Detailed) {
    Write-Host "(Detailed mode enabled - gathering AD information)" -ForegroundColor Green
}

$StartTime = (Get-Date).AddDays(-$DaysBack)
$TopUsers = @()
$TopSources = @()
$NTLMPercent = 0
$AllNTLMEvents = @()

# ============================================
# 1. EVENT ID 4776 - NTLM Authentication
# ============================================
Write-Host "`n[1] Event ID 4776 - Direct NTLM Authentication Attempts" -ForegroundColor Green

$Events4776 = Get-NTLMEvents -EventID 4776 -StartTime $StartTime -ComputerName $ComputerName

if ($Events4776) {
    Write-Host "Found $($Events4776.Count) NTLM authentication events" -ForegroundColor White
    
    # Parse events
    $NTLM4776 = foreach ($Event in $Events4776) {
        try {
            $EventXML = [xml]$Event.ToXml()
            [PSCustomObject]@{
                TimeCreated = $Event.TimeCreated
                UserName = $EventXML.Event.EventData.Data[1].'#text'
                SourceWorkstation = $EventXML.Event.EventData.Data[2].'#text'
                ErrorCode = $EventXML.Event.EventData.Data[3].'#text'
                AuthPackage = $EventXML.Event.EventData.Data[0].'#text'
                Result = if($EventXML.Event.EventData.Data[3].'#text' -eq '0x0') {'Success'} else {'Failed'}
                EventID = 4776
            }
        } catch {
            Write-Verbose "Error parsing event: $($_.Exception.Message)"
        }
    }
    
    if ($NTLM4776) {
        $AllNTLMEvents += $NTLM4776
        
        # Top users analysis
        $TopUsers = $NTLM4776 | Group-Object UserName | Sort-Object Count -Descending | Select-Object -First $TopCount
        Write-Host "`nTop $TopCount Users (Event 4776):" -ForegroundColor Yellow
        $TopUsers | ForEach-Object { Write-Host "  $($_.Name): $($_.Count) attempts" }
        
        # Service account analysis
        Show-ServiceAccountAnalysis -AccountList $TopUsers
        
        # Top source workstations
        $TopSources = $NTLM4776 | Where-Object {$_.SourceWorkstation -ne '-'} | 
                     Group-Object SourceWorkstation | Sort-Object Count -Descending | Select-Object -First $TopCount
        Write-Host "`nTop $TopCount Source Workstations (Event 4776):" -ForegroundColor Yellow
        $TopSources | ForEach-Object { Write-Host "  $($_.Name): $($_.Count) attempts" }
        
        # Detailed source analysis
        Show-SourceAnalysis -TopSources $TopSources -AllEvents $NTLM4776
    }
} else {
    Write-Host "No Event 4776 found - NTLM logging may not be enabled" -ForegroundColor Red
}

# ============================================
# 2. EVENT ID 4624 - Successful Logons (NTLM)
# ============================================
Write-Host "`n[2] Event ID 4624 - Successful Logons (NTLM only)" -ForegroundColor Green

$Events4624 = Get-NTLMEvents -EventID 4624 -StartTime $StartTime -ComputerName $ComputerName

if ($Events4624) {
    # Filter for NTLM only
    $NTLM4624 = foreach ($Event in $Events4624) {
        try {
            $EventXML = [xml]$Event.ToXml()
            $AuthPackage = $EventXML.Event.EventData.Data[10].'#text'
            
            if ($AuthPackage -eq 'NTLM') {
                [PSCustomObject]@{
                    TimeCreated = $Event.TimeCreated
                    UserName = $EventXML.Event.EventData.Data[5].'#text'
                    Domain = $EventXML.Event.EventData.Data[6].'#text'
                    LogonType = $EventXML.Event.EventData.Data[8].'#text'
                    AuthPackage = $AuthPackage
                    SourceWorkstation = $EventXML.Event.EventData.Data[11].'#text'
                    SourceIP = $EventXML.Event.EventData.Data[18].'#text'
                    EventID = 4624
                }
            }
        } catch {
            Write-Verbose "Error parsing 4624 event: $($_.Exception.Message)"
        }
    }
    
    if ($NTLM4624) {
        $AllNTLMEvents += $NTLM4624
        Write-Host "Found $($NTLM4624.Count) successful NTLM logons" -ForegroundColor White
        
        # Logon types breakdown
        $LogonTypeBreakdown = $NTLM4624 | Group-Object LogonType | Sort-Object Count -Descending
        Write-Host "`nLogon Types:" -ForegroundColor Yellow
        $LogonTypeBreakdown | ForEach-Object { 
            $LogonTypeDesc = switch($_.Name) {
                '2' {'Interactive (Local)'}
                '3' {'Network (Remote)'}
                '4' {'Batch (Scheduled)'}
                '5' {'Service (Windows Service)'}
                '7' {'Unlock (Screen Unlock)'}
                '8' {'NetworkCleartext (IIS Basic Auth)'}
                '9' {'NewCredentials (RunAs)'}
                '10' {'RemoteInteractive (RDP/TS)'}
                '11' {'CachedInteractive (Offline)'}
                default {'Unknown'}
            }
            Write-Host "  Type $($_.Name) ($LogonTypeDesc): $($_.Count) logons"
        }
        
        # Detailed logon analysis
        if ($Detailed) {
            Write-Host "`n    Detailed Logon Analysis:" -ForegroundColor Cyan
            
            # Show top users for successful NTLM logons
            $Top4624Users = $NTLM4624 | Group-Object UserName | Sort-Object Count -Descending | Select-Object -First 5
            Write-Host "    Top users (successful NTLM logons):" -ForegroundColor Yellow
            $Top4624Users | ForEach-Object { Write-Host "      - $($_.Name): $($_.Count) logons" -ForegroundColor White }
            
            # Show source IP patterns
            $SourceIPs = $NTLM4624 | Where-Object {$_.SourceIP -ne '-' -and $_.SourceIP -ne '127.0.0.1'} | 
                        Group-Object SourceIP | Sort-Object Count -Descending | Select-Object -First 5
            if ($SourceIPs) {
                Write-Host "    Top source IPs:" -ForegroundColor Yellow
                $SourceIPs | ForEach-Object { Write-Host "      - $($_.Name): $($_.Count) logons" -ForegroundColor White }
            }
            
            # Identify potential security concerns
            $RemoteInteractive = $NTLM4624 | Where-Object {$_.LogonType -eq '10'}
            if ($RemoteInteractive) {
                Write-Host "    [WARNING] Remote Desktop NTLM logons detected: $($RemoteInteractive.Count)" -ForegroundColor Yellow
                Write-Host "      Consider enabling NLA (Network Level Authentication) for RDP" -ForegroundColor Gray
            }
            
            $CleartextAuth = $NTLM4624 | Where-Object {$_.LogonType -eq '8'}
            if ($CleartextAuth) {
                Write-Host "    [CRITICAL] Cleartext authentication detected: $($CleartextAuth.Count)" -ForegroundColor Red
                Write-Host "      Review IIS/web application authentication settings" -ForegroundColor Gray
            }
        }
    } else {
        Write-Host "No NTLM logons found in Event 4624" -ForegroundColor Yellow
    }
}

# ============================================
# 3. EVENT ID 4625 - Failed Logons (NTLM)
# ============================================
Write-Host "`n[3] Event ID 4625 - Failed Logons (NTLM only)" -ForegroundColor Green

$Events4625 = Get-NTLMEvents -EventID 4625 -StartTime $StartTime -ComputerName $ComputerName

if ($Events4625) {
    # Filter for NTLM failures
    $NTLM4625 = foreach ($Event in $Events4625) {
        try {
            $EventXML = [xml]$Event.ToXml()
            $AuthPackage = $EventXML.Event.EventData.Data[10].'#text'
            
            if ($AuthPackage -eq 'NTLM') {
                [PSCustomObject]@{
                    TimeCreated = $Event.TimeCreated
                    UserName = $EventXML.Event.EventData.Data[5].'#text'
                    FailureReason = $EventXML.Event.EventData.Data[8].'#text'
                    SourceWorkstation = $EventXML.Event.EventData.Data[13].'#text'
                    SourceIP = $EventXML.Event.EventData.Data[19].'#text'
                    EventID = 4625
                }
            }
        } catch {
            Write-Verbose "Error parsing 4625 event: $($_.Exception.Message)"
        }
    }
    
    if ($NTLM4625) {
        $AllNTLMEvents += $NTLM4625
        Write-Host "Found $($NTLM4625.Count) failed NTLM logons" -ForegroundColor White
        
        # Top failed users
        $TopFailedUsers = $NTLM4625 | Group-Object UserName | Sort-Object Count -Descending | Select-Object -First $TopCount
        Write-Host "`nTop Failed NTLM Users:" -ForegroundColor Yellow
        $TopFailedUsers | ForEach-Object { Write-Host "  $($_.Name): $($_.Count) failures" }
        
        # Detailed failure analysis
        if ($Detailed) {
            Write-Host "`n    Failed Logon Analysis:" -ForegroundColor Cyan
            
            # Failure reason analysis
            $FailureReasons = $NTLM4625 | Group-Object FailureReason | Sort-Object Count -Descending | Select-Object -First 5
            Write-Host "    Top failure reasons:" -ForegroundColor Yellow
            $FailureReasons | ForEach-Object {
                $ReasonDesc = switch($_.Name) {
                    '0xC000006A' {'Wrong password'}
                    '0xC000006D' {'Wrong username or authentication info'}
                    '0xC000006E' {'User account restriction'}
                    '0xC0000072' {'Account disabled'}
                    '0xC000006F' {'Outside allowed logon hours'}
                    '0xC0000070' {'Workstation restriction'}
                    '0xC0000071' {'Password expired'}
                    '0xC0000234' {'Account locked out'}
                    default {"Unknown ($($_.Name))"}
                }
                Write-Host "      - $ReasonDesc`: $($_.Count) failures" -ForegroundColor White
            }
            
            # Source IP analysis for failures
            $FailureIPs = $NTLM4625 | Where-Object {$_.SourceIP -ne '-'} | 
                         Group-Object SourceIP | Sort-Object Count -Descending | Select-Object -First 5
            if ($FailureIPs) {
                Write-Host "    Top failure source IPs (potential attacks):" -ForegroundColor Red
                $FailureIPs | ForEach-Object { Write-Host "      - $($_.Name): $($_.Count) failures" -ForegroundColor White }
            }
            
            # Security assessment
            if ($NTLM4625.Count -gt 100) {
                Write-Host "    [ALERT] HIGH failure count detected - possible brute force attack" -ForegroundColor Red
                Write-Host "      Review source IPs and consider implementing account lockout policies" -ForegroundColor Gray
            } elseif ($NTLM4625.Count -gt 20) {
                Write-Host "    [WARNING] Moderate failures detected - monitor for attack patterns" -ForegroundColor Yellow
            }
        }
    }
}

# ============================================
# 4. EVENT ID 8004/8005 - NTLM Blocked Events
# ============================================
Write-Host "`n[4] Event ID 8004/8005 - NTLM Blocked Events" -ForegroundColor Green

$BlockedEvents8004 = Get-NTLMEvents -EventID 8004 -LogName 'System' -StartTime $StartTime -ComputerName $ComputerName
$BlockedEvents8005 = Get-NTLMEvents -EventID 8005 -LogName 'System' -StartTime $StartTime -ComputerName $ComputerName

$AllBlockedEvents = @()
if ($BlockedEvents8004) { $AllBlockedEvents += $BlockedEvents8004 }
if ($BlockedEvents8005) { $AllBlockedEvents += $BlockedEvents8005 }

if ($AllBlockedEvents) {
    Write-Host "Found $($AllBlockedEvents.Count) NTLM blocked events" -ForegroundColor Red
    
    $AllBlockedEvents | Group-Object Id | ForEach-Object {
        $EventType = if($_.Name -eq '8004') {'Server Blocked'} else {'Client Blocked'}
        Write-Host "  Event $($_.Name) ($EventType): $($_.Count) blocks"
    }
} else {
    Write-Host "No NTLM blocked events found (restrictions not active or no blocks)" -ForegroundColor Yellow
}

# ============================================
# 5. Kerberos Events (for comparison)
# ============================================
Write-Host "`n[5] Kerberos Events (for comparison)" -ForegroundColor Green

$KerbEvents = Get-NTLMEvents -EventID 4768 -StartTime $StartTime -ComputerName $ComputerName

if ($KerbEvents) {
    Write-Host "Found $($KerbEvents.Count) Kerberos TGT requests (good!)" -ForegroundColor Green
}

# Calculate ratio and show recommendations
if ($Events4776 -and $KerbEvents) {
    $NTLMCount = $Events4776.Count
    $KerbCount = $KerbEvents.Count
    $TotalAuth = $NTLMCount + $KerbCount
    $NTLMPercent = [math]::Round(($NTLMCount / $TotalAuth) * 100, 2)
    
    Write-Host "`n=== Authentication Summary ===" -ForegroundColor Cyan
    Write-Host "NTLM Authentications: $NTLMCount ($NTLMPercent%)" -ForegroundColor Red
    Write-Host "Kerberos Authentications: $KerbCount ($([math]::Round(100-$NTLMPercent,2))%)" -ForegroundColor Green
    
    if ($NTLMPercent -gt 20) {
        Write-Host "[WARNING] HIGH NTLM USAGE - Review before implementing restrictions" -ForegroundColor Yellow
    } elseif ($NTLMPercent -gt 5) {
        Write-Host "[WARNING] MODERATE NTLM USAGE - Identify dependencies before restrictions" -ForegroundColor Yellow
    } else {
        Write-Host "[PASS] LOW NTLM USAGE - May be safe to implement restrictions" -ForegroundColor Green
    }
    
    # Show remediation recommendations
    Show-RemediationRecommendations -NTLMPercent $NTLMPercent -TopUsers $TopUsers -TopSources $TopSources
}

# ============================================
# 6. Export Results
# ============================================
Write-Host "`n[6] Exporting results..." -ForegroundColor Green

# Ensure export directory exists
if (!(Test-Path $ExportPath)) {
    try {
        New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
    } catch {
        Write-Host "Could not create export directory: $ExportPath" -ForegroundColor Red
        $ExportPath = $env:TEMP
    }
}

if ($AllNTLMEvents) {
    $ExportFile = "$ExportPath\NTLM_Audit_$($ComputerName)_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    try {
        $AllNTLMEvents | Sort-Object TimeCreated | Export-Csv -Path $ExportFile -NoTypeInformation -ErrorAction Stop
        Write-Host "Event details exported to: $ExportFile" -ForegroundColor Green
    } catch {
        Write-Host "Could not export to $ExportFile`: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Export detailed AD information if available
    if ($Detailed -and $TopUsers) {
        Write-Host "Exporting detailed Active Directory information..." -ForegroundColor Yellow
        
        # User account details
        $UserNames = $TopUsers | Where-Object {$_.Name -notlike "*$"} | Select-Object -First 20 -ExpandProperty Name
        if ($UserNames) {
            $UserDetails = Get-DetailedAccountInfo -AccountNames $UserNames -ObjectType "User"
            if ($UserDetails) {
                $UserDetailsFile = "$ExportPath\NTLM_UserDetails_$($ComputerName)_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
                try {
                    $UserDetails | Export-Csv -Path $UserDetailsFile -NoTypeInformation -ErrorAction Stop
                    Write-Host "User details exported to: $UserDetailsFile" -ForegroundColor Green
                } catch {
                    Write-Host "Could not export user details: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        
        # Computer account details
        if ($TopSources) {
            $ComputerNames = $TopSources | Where-Object {$_.Name -match '^[A-Z0-9-]+$' -and $_.Name -notmatch '^\d+\.\d+\.\d+\.\d+$'} | 
                            Select-Object -First 10 -ExpandProperty Name
            if ($ComputerNames) {
                $ComputerDetails = Get-DetailedAccountInfo -AccountNames $ComputerNames -ObjectType "Computer"
                if ($ComputerDetails) {
                    $ComputerDetailsFile = "$ExportPath\NTLM_ComputerDetails_$($ComputerName)_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
                    try {
                        $ComputerDetails | Export-Csv -Path $ComputerDetailsFile -NoTypeInformation -ErrorAction Stop
                        Write-Host "Computer details exported to: $ComputerDetailsFile" -ForegroundColor Green
                    } catch {
                        Write-Host "Could not export computer details: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }
    }
} else {
    Write-Host "No NTLM events found to export" -ForegroundColor Yellow
}

Write-Host "`n=== NTLM Audit Complete ===" -ForegroundColor Cyan

if ($Detailed) {
    Write-Host "Detailed analysis completed with Active Directory information" -ForegroundColor Green
}

Write-Host "Run this script on all Domain Controllers for complete visibility" -ForegroundColor White

# Final recommendations based on results
if ($Events4776 -and $Events4776.Count -gt 100) {
    Write-Host "`nRECOMMENDATIONS:" -ForegroundColor Yellow
    Write-Host "- High NTLM usage detected - prioritize remediation planning" -ForegroundColor White
    Write-Host "- Focus on top 3-5 accounts for maximum impact" -ForegroundColor White
    if (-not $Detailed) {
        Write-Host "- Run with -Detailed flag for comprehensive Active Directory analysis" -ForegroundColor Cyan
    }
    Write-Host "- Monitor weekly during remediation phase" -ForegroundColor White
} elseif ($Events4776 -and $Events4776.Count -gt 10) {
    Write-Host "`nRECOMMENDATIONS:" -ForegroundColor Yellow
    Write-Host "- Moderate NTLM usage - plan gradual restrictions" -ForegroundColor White
    Write-Host "- Identify application dependencies before implementing restrictions" -ForegroundColor White
    if (-not $Detailed) {
        Write-Host "- Consider running with -Detailed flag for more information" -ForegroundColor Cyan
    }
} elseif ($Events4776 -and $Events4776.Count -gt 0) {
    Write-Host "`nRECOMMENDATIONS:" -ForegroundColor Green
    Write-Host "- Low NTLM usage - consider implementing restrictions carefully" -ForegroundColor White
    Write-Host "- Monitor for 2-4 weeks before full restriction deployment" -ForegroundColor White
} else {
    Write-Host "`n[PASS] No NTLM usage detected - safe to implement restrictions" -ForegroundColor Green
}

# Show usage examples if this was a basic run
if (-not $Detailed -and $Events4776 -and $Events4776.Count -gt 50) {
    Write-Host "`nUSAGE EXAMPLES:" -ForegroundColor Cyan
    Write-Host "For detailed analysis: .\NTLM-audit.ps1 -Detailed" -ForegroundColor Gray
    Write-Host "Longer timeframe: .\NTLM-audit.ps1 -DaysBack 30 -Detailed" -ForegroundColor Gray
    Write-Host "Help information: .\NTLM-audit.ps1 -Help" -ForegroundColor Gray
}