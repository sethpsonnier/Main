# Script to get local administrators and report to NinjaRMM custom field
# Custom field name: localadmins

try {
    # Get members of the local Administrators group with better error handling
    $adminNames = @()
    
    try {
        $adminGroup = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop
        
        foreach ($admin in $adminGroup) {
            try {
                # Try to get the name, skip if SID can't be resolved
                if ($admin.Name) {
                    $adminNames += $admin.Name
                }
            } catch {
                # Skip orphaned SIDs and continue
                Write-Warning "Skipping unresolvable SID: $($admin.SID)"
                continue
            }
        }
    } catch {
        # Fallback method using net localgroup command
        Write-Warning "Get-LocalGroupMember failed, trying net localgroup method..."
        
        try {
            $netOutput = net localgroup administrators
            $adminNames = @()
            $startCapture = $false
            
            foreach ($line in $netOutput) {
                # Start capturing after the dashed line
                if ($line -match "^-+$") {
                    $startCapture = $true
                    continue
                }
                
                # Stop at "The command completed successfully"
                if ($line -match "The command completed") {
                    break
                }
                
                # Capture member names
                if ($startCapture -and $line.Trim() -ne "") {
                    $adminNames += $line.Trim()
                }
            }
        } catch {
            Write-Error "All methods failed to get local administrators"
            throw
        }
    }
    
    # Join with newlines for proper field formatting
    $adminString = $adminNames -join "`n"
    
    # Set the NinjaRMM custom field
    Ninja-Property-Set localadmins $adminString
    
    Write-Output "Successfully reported local administrators to NinjaRMM custom field 'localadmins'"
    Write-Output "Found $($adminNames.Count) local administrators"
    
} catch {
    # Handle errors gracefully
    $errorMsg = "Error getting local administrators: $($_.Exception.Message)"
    Write-Error $errorMsg
    
    # Still try to report the error to the custom field
    try {
        Ninja-Property-Set localadmins "ERROR: $errorMsg"
    } catch {
        Write-Error "Failed to set custom field: $($_.Exception.Message)"
    }
}

# Optional: Display the results for verification
Write-Output "Local Administrators found:"
$adminNames | ForEach-Object { Write-Output "  $_" }