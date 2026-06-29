# Set the user identities
$Users = @(
    "f495bf45-9839-4928-94cc-981406fe8017"  # Replace with the second user's GUID
)

# Set the duration to run (1 hour)
$duration = New-TimeSpan -Hours 1
$endTime = (Get-Date).Add($duration)

while ((Get-Date) -lt $endTime) {
    foreach ($User in $Users) {
        # Start the Managed Folder Assistant
        Start-ManagedFolderAssistant -Identity $User

        # Get archive statistics
        $archiveStats = Get-MailboxStatistics -Identity $User -Archive

        # Convert TotalItemSize to MB
        if ($archiveStats.TotalItemSize -match "^.*\(([\d,]+) bytes\)") {
            $sizeInBytes = [long]($Matches[1] -replace ',','')
            $sizeInMB = [math]::Round($sizeInBytes / 1MB, 2)
        } else {
            $sizeInMB = "Unable to calculate"
        }

        # Output results
        Write-Host "User: $User"
        Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Host "Archive Total Item Size (MB): $sizeInMB"
        Write-Host "Archive Total Item Count: $($archiveStats.ItemCount)"
        Write-Host "--------------------------------------------------------------------------------------"
    }

    # Wait for 15 seconds before the next iteration
    Start-Sleep -Seconds 15
}