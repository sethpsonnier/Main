[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter()]
    [int]$DaysInactive = 60
)

# Suppress WhatIf output for certain operations
$WhatIfPreferenceBackup = $WhatIfPreference
$WhatIfPreference = $false
# Import module without showing alias whatif messages
Import-Module CimCmdlets -DisableNameChecking
# Restore WhatIf preference
$WhatIfPreference = $WhatIfPreferenceBackup

#region Helper Functions

function Test-ValidProfilePath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    # Normalize paths for comparison
    $usersFolder = Join-Path -Path $env:SystemDrive -ChildPath "Users"
    $normalizedUsersFolder = $usersFolder.TrimEnd('\').ToLower()
    $normalizedPath = $Path.TrimEnd('\').ToLower()
    
    # Check if path exists
    if (-not $Path -or -not (Test-Path -Path $Path)) {
        Write-Verbose "Path does not exist: $Path"
        return $false
    }
    
    # Verify path is a subdirectory of Users folder and not the Users folder itself
    if (-not $normalizedPath.StartsWith($normalizedUsersFolder) -or $normalizedPath -eq $normalizedUsersFolder) {
        Write-Warning "Path validation failed: $Path is not a valid profile path"
        return $false
    }
    
    # Verify it's a direct child of the Users folder (not a deeper subfolder)
    $pathDepth = ($normalizedPath.Substring($normalizedUsersFolder.Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries)).Count
    if ($pathDepth -ne 1) {
        Write-Warning "Path validation failed: $Path is not a direct child of $usersFolder"
        return $false
    }
    
    return $true
}

function Convert-RegistryTimeToDateTime {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        $HighPart,
        
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        $LowPart
    )
    
    try {
        # Check if either part is null, empty, or zero
        if ([string]::IsNullOrEmpty($HighPart) -or [string]::IsNullOrEmpty($LowPart) -or 
            $HighPart -eq 0 -or $LowPart -eq 0) {
            Write-Verbose "Missing or zero high/low part for time conversion"
            return $null
        }
        
        # Use direct bit manipulation - more reliable than hex string conversion
        $fileTime = ([long]$HighPart -shl 32) -bor [long]$LowPart
        return [datetime]::FromFileTime($fileTime)
    }
    catch {
        Write-Verbose "Failed to convert registry time: $_"
        return $null
    }
}

function Get-ProfileLastUseTime {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$ProfilePath,
        [Parameter(Mandatory = $false)]
        [Nullable[datetime]]$LoadTime,
        [Parameter(Mandatory = $false)]
        [Nullable[datetime]]$UnloadTime
    )
    
    # Only use registry times - no file system fallbacks
    if ($LoadTime -and $UnloadTime) {
        if ($LoadTime -gt $UnloadTime) {
            Write-Verbose "Using LoadTime for profile ${ProfilePath}: $LoadTime"
            return $LoadTime
        } else {
            Write-Verbose "Using UnloadTime for profile ${ProfilePath}: $UnloadTime"
            return $UnloadTime
        }
    }
    elseif ($LoadTime) {
        Write-Verbose "Using LoadTime for profile ${ProfilePath} $LoadTime"
        return $LoadTime
    }
    elseif ($UnloadTime) {
        Write-Verbose "Using UnloadTime for profile ${ProfilePath}: $UnloadTime"
        return $UnloadTime
    }
    
    # If no registry times available, return null
    Write-Verbose "No registry times available for profile $ProfilePath"
    return $null
}

function Get-UsernameFromSid {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Sid
    )
    
    try {
        $ntAccount = (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount])
        return $ntAccount.Value.Split('\')[-1]
    }
    catch {
        Write-Verbose "Failed to translate SID $Sid to username: $_"
        return "[UNKNOWN]"
    }
}

function Get-UsernameFromPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path
    )
    
    if (-not $Path) { return "[UNKNOWN]" }
    
    try {
        $pathUsername = Split-Path -Path $Path -Leaf
        if ($pathUsername -and $pathUsername -ne "") {
            return $pathUsername
        }
    }
    catch {
        Write-Verbose "Failed to extract username from path ${Path}: $_"
    }
    
    return "[UNKNOWN]"
}

function Remove-ProfileDirectory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$Username
    )
    
    if (-not (Test-ValidProfilePath -Path $Path)) {
        Write-Error "  Safety check failed: Invalid profile path for $Username"
        return $false
    }
    
    if (-not $PSCmdlet.ShouldProcess($Path, "Remove profile directory")) {
        Write-Host "  WhatIf: Would remove directory for: $Username"
        return $true
    }
    
    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-Host "  Successfully removed directory for: $Username"
        return $true
    }
    catch {
        Write-Verbose "  Standard removal failed, attempting robocopy method for: $Username"
        $tempDir = $null
        
        try {
            # Create a unique temporary directory
            $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([Guid]::NewGuid().ToString())
            New-Item -Path $tempDir -ItemType Directory -Force -WhatIf:$false | Out-Null
            
            # Use robocopy to mirror empty directory (effectively deleting contents)
            $robocopyParams = @(
                "`"$tempDir`"", 
                "`"$Path`"", 
                "/MIR", "/NFL", "/NDL", "/NJH", "/NJS", "/R:0", "/W:0"
            )
            $robocopyResult = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyParams -NoNewWindow -Wait -PassThru
            
            # Check if profile directory was successfully removed
            if (-not (Test-Path -Path $Path) -or (Get-ChildItem -Path $Path -Force).Count -eq 0) {
                # Final cleanup attempt
                if (Test-Path -Path $Path) {
                    Remove-Item -Path $Path -Force -Recurse -ErrorAction SilentlyContinue
                }
                
                Write-Host "  Successfully removed directory for: $Username using robocopy method"
                return $true
            }
            else {
                Write-Error "  Failed to remove directory for ${Username}: Robocopy method unsuccessful"
                return $false
            }
        }
        catch {
            Write-Error "  Failed to remove directory for ${Username}: $_"
            return $false
        }
        finally {
            # Always clean up the temporary directory
            if ($tempDir -and (Test-Path -Path $tempDir)) {
                Remove-Item -Path $tempDir -Force -Recurse -ErrorAction SilentlyContinue -WhatIf:$false
            }
        }
    }
}

function Remove-UserProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Profile
    )
    
    $username = $Profile.Username
    $sid = $Profile.SID
    $success = $true
    
    try {
        # 1. Remove registry key if it exists
        if ($Profile.RegistryPath -and (Test-Path -Path $Profile.RegistryPath)) {
            if ($PSCmdlet.ShouldProcess($Profile.RegistryPath, "Remove registry key")) {
                try {
                    Remove-Item -Path $Profile.RegistryPath -Recurse -Force -ErrorAction Stop
                    Write-Host "  Successfully removed profile registry key for: $username"
                }
                catch {
                    Write-Warning "  Failed to remove registry key for ${username}: $_"
                    $success = $false
                }
            }
            else {
                Write-Host "  WhatIf: Would remove registry key for: $username"
            }
        }
        
        # 2. Remove profile directory if it exists
        if ($Profile.LocalPath -and (Test-Path -Path $Profile.LocalPath)) {
            $dirSuccess = Remove-ProfileDirectory -Path $Profile.LocalPath -Username $username
            if (-not $dirSuccess) {
                $success = $false
                # Error counting handled here, not double-counted
            }
        }
        
        # 3. Remove CIM instance if it exists
        if ($Profile.CimInstance) {
            if ($PSCmdlet.ShouldProcess("CIM Profile for $username", "Remove")) {
                try {
                    Remove-CimInstance -InputObject $Profile.CimInstance -ErrorAction Stop
                    Write-Host "  Successfully removed CIM profile for: $username"
                }
                catch {
                    Write-Verbose "  CIM profile for $username may have already been removed: $_"
                }
            }
            else {
                Write-Host "  WhatIf: Would remove CIM profile for: $username"
            }
        }
        
        return $success
    }
    catch {
        Write-Error "  Failed to remove profile $username`: $_"
        return $false
    }
}

function Test-ShouldRemoveProfile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Profile,
        [Parameter(Mandatory = $true)]
        [datetime]$ThresholdDate,
        [Parameter(Mandatory = $true)]
        [string[]]$ProtectedUsernamesLower,
        [Parameter(Mandatory = $false)]
        [string[]]$AdminSids = @(),
        [switch]$OrphanedFolder = $false
    )
    
    $username = $Profile.Username
    $sid = $Profile.SID
    
    if ($Profile.Special) {
        return @{ ShouldRemove = $false; Reason = "Special profile" }
    }
    
    if ($Profile.Loaded) {
        return @{ ShouldRemove = $false; Reason = "Currently loaded" }
    }
    
    # Simple case-insensitive protected username check
    if ($ProtectedUsernamesLower -contains $username.ToLower()) {
        return @{ ShouldRemove = $false; Reason = "Protected username" }
    }
    
    # Also check if the username (without domain) matches any protected names
    # This handles cases where username might include domain prefix
    $usernameWithoutDomain = if ($username -contains '\') { 
        $username.Split('\')[-1] 
    } else { 
        $username 
    }
    if ($ProtectedUsernamesLower -contains $usernameWithoutDomain.ToLower()) {
        return @{ ShouldRemove = $false; Reason = "Protected username (domain stripped)" }
    }
    
    if ($AdminSids -and $sid -and $AdminSids -contains $sid) {
        return @{ ShouldRemove = $false; Reason = "Administrator account" }
    }
    
    if ($OrphanedFolder) {
        return @{ ShouldRemove = $true; Reason = "Orphaned profile folder (not in registry or CIM)" }
    }
    
    if ($null -eq $Profile.LastUseTime) {
        return @{ ShouldRemove = $true; Reason = "No activity timestamp available" }
    }
    
    $daysSinceLastUse = [math]::Round((New-TimeSpan -Start $Profile.LastUseTime -End (Get-Date)).TotalDays, 1)
    
    if ($Profile.LastUseTime -lt $ThresholdDate) {
        return @{ 
            ShouldRemove = $true
            Reason = "Inactive for $daysSinceLastUse days (threshold: $DaysInactive days)"
            DaysSinceLastUse = $daysSinceLastUse
        }
    }
    
    return @{ 
        ShouldRemove = $false
        Reason = "Active within $DaysInactive days (last used $daysSinceLastUse days ago)"
        DaysSinceLastUse = $daysSinceLastUse
    }
}

function Write-ProfileInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Profile,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter(Mandatory = $false)]
        [string]$Reason = "Unknown",
        [string]$DaysSinceLastUse = "Unknown"
    )
    
    $username = $Profile.Username
    $sid = $Profile.SID
    
    Write-Host "Profile: $username" 
    Write-Host "  SID: $sid"
    Write-Host "  Path: $($Profile.LocalPath)"
    Write-Host "  Last Use Time: $($Profile.LastUseTime)"
    Write-Host "  Days Since Last Use: $DaysSinceLastUse"
    Write-Host "  Special: $($Profile.Special)"
    Write-Host "  Loaded: $($Profile.Loaded)"
    Write-Host "  Status: $Status - $Reason"
}

#endregion Helper Functions

#region Main Script

# Initialize counters and paths
$result = @{
    RemovedCount = 0
    ProtectedCount = 0
    ErrorCount = 0
    OrphanedCount = 0
}

$tempFolder = "C:\temp"
$logFolder = "C:\temp\ProfileCleanupLogs"

if (-not (Test-Path -Path $tempFolder)) {
    New-Item -Path $tempFolder -ItemType Directory -Force -WhatIf:$false | Out-Null
}
    
if (-not (Test-Path -Path $logFolder)) {
    New-Item -Path $logFolder -ItemType Directory -Force -WhatIf:$false | Out-Null
}

$logFile = Join-Path -Path $logFolder -ChildPath "ProfileCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Always start transcript for auditing (including WhatIf runs)
Start-Transcript -Path $logFile

$thresholdDate = (Get-Date).AddDays(-$DaysInactive)
Write-Host "Removing profiles not used since: $thresholdDate | Today's date: $(Get-Date)"
Write-Host "---------------------------------------------------------"

# Initialize $adminSids to an empty array
$adminSids = @()

# Get administrator SIDs - exit if we can't enumerate them safely
try {
    $adminMembers = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue
    if ($adminMembers) {
        $adminSids = $adminMembers | 
            Select-Object -ExpandProperty SID | 
            ForEach-Object { $_.Value }
    }
} catch {
    Write-Error "Could not retrieve administrators list: $_"
    Write-Error "Cannot safely proceed without administrator account information. Exiting."
    Stop-Transcript
    exit 1
}

# Additional safety check - exit if no admin accounts found (shouldn't happen on normal systems)
if (-not $adminSids -or $adminSids.Count -eq 0) {
    Write-Error "No administrator accounts found. This is unexpected and unsafe."
    Write-Error "Cannot safely proceed without administrator account information. Exiting."
    Stop-Transcript
    exit 1
}

Write-Host "Found $(($adminSids | Measure-Object).Count) administrators"

$protectedUsernames = @(
    "Administrator", 
    "Public", 
    "Default", 
    "defaultuser0", 
    "All Users", 
    "Default User",
    "adm-gcblocal",
    "Nessus Local Access",
    "GULFCAPITAL\Nessus Local Access"
)

# Convert to lowercase once for efficient case-insensitive comparisons
$protectedUsernamesLower = $protectedUsernames | ForEach-Object { $_.ToLower() }

Write-Host "Retrieving profile information..."

# Get all profiles from both registry and CIM
$allProfiles = @{}
$cimProfilesBySid = @{}

# First get CIM profiles for lookup (only for Loaded and Special properties)
$cimProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue
if ($cimProfiles) {
    Write-Verbose "Found $($cimProfiles.Count) profiles in CIM"
    foreach ($cimProfile in $cimProfiles) {
        $cimProfilesBySid[$cimProfile.SID] = $cimProfile
    }
}

# Get registry profiles and create merged profile objects
$profileRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$profileList = Get-ChildItem $profileRegistryPath -ErrorAction SilentlyContinue

if ($profileList) {
    foreach ($p in $profileList) {
        try {
            $sid = $p.PSChildName
            
            # Get username - first from SID, then from path if needed
            $username = Get-UsernameFromSid -Sid $sid
            $profileImagePath = (Get-ItemProperty -Path $p.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            
            if ($username -eq "[UNKNOWN]" -and $profileImagePath) {
                $username = Get-UsernameFromPath -Path $profileImagePath
            }
            
            # Get load/unload times
            $loadTimeHigh = (Get-ItemProperty -Path $p.PSPath -Name LocalProfileLoadTimeHigh -ErrorAction SilentlyContinue).LocalProfileLoadTimeHigh
            $loadTimeLow = (Get-ItemProperty -Path $p.PSPath -Name LocalProfileLoadTimeLow -ErrorAction SilentlyContinue).LocalProfileLoadTimeLow
            $unloadTimeHigh = (Get-ItemProperty -Path $p.PSPath -Name LocalProfileUnloadTimeHigh -ErrorAction SilentlyContinue).LocalProfileUnloadTimeHigh
            $unloadTimeLow = (Get-ItemProperty -Path $p.PSPath -Name LocalProfileUnloadTimeLow -ErrorAction SilentlyContinue).LocalProfileUnloadTimeLow
            
            # Added verbose logging to help diagnose issues
            Write-Verbose "SID: $sid - Load High: $loadTimeHigh, Load Low: $loadTimeLow"
            Write-Verbose "SID: $sid - Unload High: $unloadTimeHigh, Unload Low: $unloadTimeLow"
            
            $loadTime = $null
            $unloadTime = $null
            
            # Only attempt conversion if we have actual values
            if (($null -ne $loadTimeHigh -and $loadTimeHigh -ne 0) -and 
                ($null -ne $loadTimeLow -and $loadTimeLow -ne 0)) {
                $loadTime = Convert-RegistryTimeToDateTime -HighPart $loadTimeHigh -LowPart $loadTimeLow
                Write-Verbose "SID: $sid - Converted LoadTime: $loadTime"
            }
            
            if (($null -ne $unloadTimeHigh -and $unloadTimeHigh -ne 0) -and 
                ($null -ne $unloadTimeLow -and $unloadTimeLow -ne 0)) {
                $unloadTime = Convert-RegistryTimeToDateTime -HighPart $unloadTimeHigh -LowPart $unloadTimeLow
                Write-Verbose "SID: $sid - Converted UnloadTime: $unloadTime"
            }
            
            # Determine if profile is loaded and/or special
            $isLoaded = $false
            $isSpecial = $false
            $cimProfile = $null
            
            if ($cimProfilesBySid.ContainsKey($sid)) {
                $cimProfile = $cimProfilesBySid[$sid]
                $isLoaded = $cimProfile.Loaded
                $isSpecial = $cimProfile.Special
            }
            else {
                # Fallback logic if not in CIM
                if ($loadTime -and (-not $unloadTime -or $loadTime -gt $unloadTime)) {
                    $isLoaded = $true
                }
                
                $state = (Get-ItemProperty -Path $p.PSPath -Name State -ErrorAction SilentlyContinue).State
                if ($state -eq 0) {
                    $isSpecial = $true
                }
            }
            
            # Get last activity time using our helper function
            $lastUseTime = Get-ProfileLastUseTime -ProfilePath $profileImagePath -LoadTime $loadTime -UnloadTime $unloadTime
            
            # Create a unified profile object with all data
            $userProfile = [PSCustomObject]@{
                User = if ($username -ne "[UNKNOWN]") { "DOMAIN\$username" } else { "[UNKNOWN]" }
                Username = $username
                SID = $sid
                LoadTime = $loadTime
                UnloadTime = $unloadTime
                LastUseTime = $lastUseTime
                LocalPath = $profileImagePath
                Loaded = $isLoaded
                Special = $isSpecial
                RegistryPath = $p.PSPath
                Source = "Registry"
                CimInstance = $cimProfile
                IsOrphaned = $false
            }
            
            $allProfiles[$sid] = $userProfile
        } 
        catch {
            Write-Warning "Error processing registry profile $($p.PSChildName): $_"
        }
    }
}

# Add CIM-only profiles that weren't found in registry
foreach ($sid in $cimProfilesBySid.Keys) {
    if (-not $allProfiles.ContainsKey($sid)) {
        $cimProfile = $cimProfilesBySid[$sid]
        
        # Get username from SID or path
        $username = Get-UsernameFromSid -Sid $sid
        if ($username -eq "[UNKNOWN]" -and $cimProfile.LocalPath) {
            $username = Get-UsernameFromPath -Path $cimProfile.LocalPath
        }
        
        # Use our helper function to get last use time
        $lastUseTime = Get-ProfileLastUseTime -ProfilePath $cimProfile.LocalPath -LoadTime $null -UnloadTime $null
        
        # Create profile object
        $userProfile = [PSCustomObject]@{
            User = if ($username -ne "[UNKNOWN]") { "DOMAIN\$username" } else { "[UNKNOWN]" }
            Username = $username
            SID = $sid
            LoadTime = $null
            UnloadTime = $null
            LastUseTime = $lastUseTime
            LocalPath = $cimProfile.LocalPath
            Loaded = $cimProfile.Loaded
            Special = $cimProfile.Special
            RegistryPath = $null
            Source = "CIM"
            CimInstance = $cimProfile
            IsOrphaned = $false
        }
        
        $allProfiles[$sid] = $userProfile
    }
}

# Output profile counts
$totalUniqueProfiles = $allProfiles.Count
$registryProfileCount = ($allProfiles.Values | Where-Object { $_.Source -eq "Registry" }).Count
$cimProfileCount = $cimProfilesBySid.Count

Write-Host "Found $totalUniqueProfiles unique profiles ($registryProfileCount in registry, $cimProfileCount in CIM)"

# Create lookup for profile paths
$profilePaths = @{}
foreach ($profile in $allProfiles.Values) {
    if ($profile.LocalPath) {
        $profilePaths[$profile.LocalPath] = $profile
    }
}

# Process all registry/CIM profiles
Write-Host "Processing profiles..."
Write-Host "---------------------------------------------------------"

$profileCount = $allProfiles.Count
$currentProfile = 0

foreach ($profile in $allProfiles.Values) {
    $currentProfile++
    $percentComplete = [math]::Round(($currentProfile / $profileCount) * 100)
    $status = "Processing $($profile.Username) ($currentProfile of $profileCount)"
    
    Write-Progress -Activity "Processing Profiles" -Status $status -PercentComplete $percentComplete

    # Determine if profile should be removed
    $evalResult = $null
    try {
        $evalResult = Test-ShouldRemoveProfile -Profile $profile -ThresholdDate $thresholdDate `
            -ProtectedUsernamesLower $protectedUsernamesLower -AdminSids $adminSids
    } catch {
        Write-Warning "Error evaluating profile $($profile.Username): $_"
        # Set default values for missing evaluation results
        $evalResult = @{ 
            ShouldRemove = $false
            Reason = "Error during evaluation"
        }
    }

    # Handle evalResult safely
    $shouldRemove = $false
    $reason = "Unknown"
    $daysSinceLastUse = "Unknown"
    
    if ($evalResult) {
        $shouldRemove = $evalResult.ShouldRemove
        if ($evalResult.Reason) {
            $reason = $evalResult.Reason
        }
        if ($evalResult.ContainsKey('DaysSinceLastUse')) {
            $daysSinceLastUse = $evalResult.DaysSinceLastUse
        }
    }
    
    # Determine status text based on removal decision and WhatIf preference
    $status = if ($shouldRemove) { 
        if ($WhatIfPreference) { "Will be removed" } else { "Removing" } 
    } else { 
        "Will be kept" 
    }
    
    # Display profile information
    Write-ProfileInfo -Profile $profile -Status $status -Reason $reason -DaysSinceLastUse $daysSinceLastUse
    
    # Handle profile based on removal decision
    if ($shouldRemove) {
        if ($WhatIfPreference) {
            Write-Host "  WhatIf: Would remove profile for: $($profile.Username)"
            $result.RemovedCount++
        }
        else {
            $success = Remove-UserProfile -Profile $profile
            if ($success) {
                $result.RemovedCount++
            }
            else {
                $result.ErrorCount++
            }
        }
    }
    else {
        $result.ProtectedCount++
    }
    
    Write-Host "---------------------------------------------------------"
}

# Clear the progress bar when done
Write-Progress -Activity "Processing Profiles" -Completed

# Process orphaned profile folders
$usersFolder = Join-Path -Path $env:SystemDrive -ChildPath "Users"
Write-Host "`nChecking for orphaned profile folders in $usersFolder..."
Write-Host "---------------------------------------------------------"

$userFolders = Get-ChildItem -Path $usersFolder -Directory -ErrorAction SilentlyContinue | 
    Where-Object { $protectedUsernamesLower -notcontains $_.Name.ToLower() }

$orphanedFolders = $userFolders | Where-Object { 
    $folderPath = $_.FullName
    -not $profilePaths.ContainsKey($folderPath) 
}

Write-Host "Found $($orphanedFolders.Count) orphaned profile folders"

$folderCount = $orphanedFolders.Count
$currentFolder = 0

foreach ($folder in $orphanedFolders) {
    $currentFolder++
    $percentComplete = if ($folderCount -eq 0) { 100 } else { [math]::Round(($currentFolder / $folderCount) * 100) }
    $status = "Processing $($folder.Name) ($currentFolder of $folderCount)"
    
    Write-Progress -Activity "Processing Orphaned Folders" -Status $status -PercentComplete $percentComplete
    
    $username = $folder.Name
    $folderPath = $folder.FullName
    
    # Skip protected usernames - using case-insensitive comparison
    if ($protectedUsernamesLower -contains $username.ToLower()) {
        Write-Host "Orphaned folder for protected username: $username - Will be kept"
        $result.ProtectedCount++
        Write-Host "---------------------------------------------------------"
        continue
    }
    
    # Validate the path first
    if (-not (Test-ValidProfilePath -Path $folderPath)) {
        Write-Warning "Skipping invalid profile path: $folderPath"
        continue
    }
    
    # Create a profile object for the orphaned folder
    $orphanedProfile = [PSCustomObject]@{
        User = "UNKNOWN\$username"
        Username = $username
        SID = $null
        LoadTime = $null
        UnloadTime = $null
        LastUseTime = $null # No timestamp for orphaned folders
        LocalPath = $folderPath
        Loaded = $false
        Special = $false
        RegistryPath = $null
        Source = "Orphaned"
        CimInstance = $null
        IsOrphaned = $true
    }
    
    # Use the same evaluation function but mark as orphaned
    $evalResult = $null
    try {
        $evalResult = Test-ShouldRemoveProfile -Profile $orphanedProfile -ThresholdDate $thresholdDate `
            -ProtectedUsernamesLower $protectedUsernamesLower -AdminSids $adminSids -OrphanedFolder
    } catch {
        Write-Warning "Error evaluating orphaned profile ${username}: $_"
        $evalResult = @{ 
            ShouldRemove = $true  # Default to remove for orphaned folders per client requirement
            Reason = "Orphaned profile folder (error during evaluation)"
        }
    }
    
    # Handle evalResult safely
    $shouldRemove = $true  # Default to remove for orphaned folders
    $reason = "Orphaned profile folder"
    $daysSinceLastUse = "Unknown"
    
    if ($evalResult) {
        $shouldRemove = $evalResult.ShouldRemove
        if ($evalResult.Reason) {
            $reason = $evalResult.Reason
        }
        if ($evalResult.ContainsKey('DaysSinceLastUse')) {
            $daysSinceLastUse = $evalResult.DaysSinceLastUse
        }
    }
    
    $status = if ($WhatIfPreference) { "Will be removed" } else { "Removing" }
    
    # Display orphaned profile information
    Write-ProfileInfo -Profile $orphanedProfile -Status $status -Reason $reason -DaysSinceLastUse $daysSinceLastUse
    
    if ($WhatIfPreference) {
        Write-Host "  WhatIf: Would remove orphaned profile folder: $username"
        $result.OrphanedCount++
    }
    else {
        $success = Remove-ProfileDirectory -Path $folderPath -Username $username
        if ($success) {
            $result.OrphanedCount++
        }
        else {
            $result.ErrorCount++
        }
    }
    
    Write-Host "---------------------------------------------------------"
}

# Clear the progress bar when done
Write-Progress -Activity "Processing Orphaned Folders" -Completed

# Summary
Write-Host "`nProfile Cleanup Summary:" 
Write-Host "Total unique profiles: $totalUniqueProfiles"
Write-Host "Total orphaned profile folders: $($orphanedFolders.Count)"

if ($WhatIfPreference) {
    Write-Host "Profiles that would be removed: $($result.RemovedCount)"
    Write-Host "Orphaned folders that would be removed: $($result.OrphanedCount)"
}
else {
    Write-Host "Profiles removed: $($result.RemovedCount)"
    Write-Host "Orphaned folders removed: $($result.OrphanedCount)"
}

Write-Host "Profiles/folders protected: $($result.ProtectedCount)"
Write-Host "Errors encountered: $($result.ErrorCount)"

Stop-Transcript

# Exit with error count (0 = success, >0 = errors occurred)
exit $result.ErrorCount

#endregion Main Script