# Define logging function
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "$Timestamp [$Level] $Message"
    $LogFile = "C:\Logs\NinjaPasswordPolicy.log"
    
    # Ensure log directory exists
    if (!(Test-Path "C:\Logs")) {
        New-Item -ItemType Directory -Path "C:\Logs" | Out-Null
    }
    
    # Write to log file
    Add-Content -Path $LogFile -Value $LogMessage

    # Display log message in console
    if ($Level -eq "ERROR") {
        Write-Error $Message
    } else {
        Write-Output $Message
    }
}



Write-Log "Starting Ninja Password Policy script execution."
Write-Log "------------------------------------------------------------"
Write-Log "Log file location: C:\Logs\NinjaPasswordPolicy.log"
Write-Log "------------------------------------------------------------"


# Getting custom configuration values from Ninja RMM
$DisableOrginzationLevel = Ninja-Property-Docs-Get 'Policy Exclusions' disableLocalAdPasswordPolicy
$ChangePasswordExpiration = Ninja-Property-Docs-Get 'Policy Exclusions' changeNumberOfDaysForPasswordResetFromEvery90Days
$ninjaLockoutAmount = Ninja-Property-Docs-Get 'Policy Exclusions' lockoutamount

# Early exit check
if ($DisableOrginzationLevel -eq 1) {
    Write-Log "Password policy is disabled at the organization level. Exiting script." "INFO"
    exit
}

# Default password policy settings
$DefaultPasswordExpirationLocalUser = 999
$DefaultPasswordExpirationADUser = "0"
$Defaultlockoutamount = 10
$Defaultminpasswordlength = 8
$DefaultuniquepasswordLength = 24 
$DefaultLockoutDuration = [TimeSpan]"0.00:30:00"
$DefaultLockoutObservationWindow = [TimeSpan]"0.00:30:00"
$Defaultminpassworgage = 0 
$DefaultPasswordHistoryCount = 24


# Set lockout threshold
if ([string]::IsNullOrEmpty($ninjaLockoutAmount) -or $ninjaLockoutAmount -eq 0) {
    $lockoutamount = $Defaultlockoutamount 
} else {
    $lockoutamount = $ninjaLockoutAmount
}

# Password expiration configuration
$PasswordExpirationLocalUser = $DefaultPasswordExpirationLocalUser
$PasswordExpirationADUser = $DefaultPasswordExpirationADUser

Write-Log "Local Password Policy Default: $PasswordExpirationLocalUser"
Write-Log "AD Password Policy Default: $PasswordExpirationADUser"


Write-Log "------------------------------------------------------------"
# Override password expiration if custom value is provided
if ($ChangePasswordExpiration -ne $null ) {
    $PasswordExpirationLocalUser = $ChangePasswordExpiration
    # Format the AD password expiration as a proper TimeSpan (D.H:M:S)
    $PasswordExpirationADUser = [TimeSpan]"$ChangePasswordExpiration.00:00:00"
    Write-Log "Custom password expiration is in place: $ChangePasswordExpiration days"
}

Write-Log "New Local Password Policy Default: $PasswordExpirationLocalUser"
Write-Log "New AD Password Policy Default: $PasswordExpirationADUser"

# Domain detection
$OS = Get-CimInstance -ClassName Win32_OperatingSystem
$Domain = if ($OS.ProductType -eq 2) { (Get-ADDomain).DNSRoot } else { "" }

# Administrative privileges check function
function Test-IsElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Verify administrative privileges
if (-not (Test-IsElevated)) {
    Write-Log "Access Denied. Please run with Administrator privileges." "ERROR"
    exit 1
}

Write-Log "------------------------------------------------------------"
# Domain Controller policy configuration
if ($Domain) {
    Write-Log "System is a Domain Controller. Applying AD password policy."

    if ($OS.ProductType -ne 2) {
        Write-Log "This script must be run on a Domain Controller. Exiting." "ERROR"
        exit 1
    }

    # Check and import Active Directory module
    if (Get-Module -Name ActiveDirectory -ListAvailable -ErrorAction SilentlyContinue) {
        try {
            Import-Module -Name ActiveDirectory -ErrorAction Stop
            Write-Log "Active Directory module imported successfully."
        } catch {
            Write-Log "Failed to import Active Directory module. RSAT may not be installed or the agent lacks necessary permissions." "ERROR"
            exit 5
        }

        # Configure AD password policy
        try {
            Set-ADDefaultDomainPasswordPolicy -Identity (Get-ADDomain).DNSRoot `
                -ComplexityEnabled $true `
                -LockoutObservationWindow $DefaultLockoutObservationWindow `
                -LockoutThreshold $Defaultlockoutamount `
                -MaxPasswordAge $PasswordExpirationADUser `
                -MinPasswordLength $Defaultminpasswordlength `
                -PasswordHistoryCount $DefaultPasswordHistoryCount `
                -LockoutDuration $DefaultLockoutDuration
            
            Write-Log "Applied AD password policy. Waiting for replication."
            Start-Sleep -Seconds 60
            
            Write-Log "------------------------------------------------------------"
            
            # Verify policy application
            $Results = Get-ADDefaultDomainPasswordPolicy -Identity $Domain
            if ($Results -and $Results.ComplexityEnabled -eq $true) {
                Write-Log "Password policy successfully applied to Active Directory." "INFO"
                Write-Log "Final settings:"
                Write-Log "  - Lockout Threshold: $($Results.LockoutThreshold)"
                Write-Log "  - Lockout Duration: $($Results.LockoutDuration)"
                Write-Log "  - Observation Window: $($Results.LockoutObservationWindow)"
                Write-Log "  - Max Password Age: $($Results.MaxPasswordAge)"
                Write-Log "  - Min Password Length: $($Results.MinPasswordLength)"
                Write-Log "  - Password History Count: $($Results.PasswordHistoryCount)"
                exit 0
            } else {
                Write-Log "Failed to set password complexity for Active Directory." "ERROR"
                exit 1
            }
        } catch {
            Write-Log "An error occurred while applying AD password policy: $_" "ERROR"
            exit 1
        }
    }
} 
# Local machine policy configuration
else {
    Write-Log "System is a standalone machine. Applying local password policy."

    # Set local password policy
    net accounts /minpwlen:8 /minpwage:0 /maxpwage:$PasswordExpirationLocalUser /uniquepw:24 /lockoutthreshold:$lockoutamount

    Write-Log "Local password policies configured successfully." "INFO"
    Write-Log "Final settings:"
    Write-Log "  - Minimum Password Length: 8"
    Write-Log "  - Minimum Password Age: 0"
    Write-Log "  - Maximum Password Age: $PasswordExpirationLocalUser"
    Write-Log "  - Unique Password Count: 24"
    Write-Log "  - Lockout Threshold: $lockoutamount"
}