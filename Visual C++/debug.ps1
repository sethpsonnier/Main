# Quick Dependencies.exe Download Diagnostic
# Run this single command to quickly diagnose the issue

# One-liner diagnostic (copy and paste this entire block)
try {
    Write-Host "=== Quick Dependencies.exe Diagnostic ===" -ForegroundColor Green
    
    # Test 1: Basic connectivity
    Write-Host "1. Testing GitHub connectivity..." -ForegroundColor Cyan
    $conn = Test-NetConnection -ComputerName "api.github.com" -Port 443 -WarningAction SilentlyContinue
    if ($conn.TcpTestSucceeded) { Write-Host "   ✓ GitHub reachable" -ForegroundColor Green } else { Write-Host "   ✗ Cannot reach GitHub" -ForegroundColor Red }
    
    # Test 2: TLS Setup
    Write-Host "2. Setting up TLS 1.2..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "   ✓ TLS 1.2 enabled" -ForegroundColor Green
    
    # Test 3: API Call
    Write-Host "3. Testing GitHub API..." -ForegroundColor Cyan
    $headers = @{ 'User-Agent' = 'PowerShell-Test'; 'Accept' = 'application/vnd.github.v3+json' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/lucasg/Dependencies/releases/latest" -Headers $headers -TimeoutSec 30
    Write-Host "   ✓ API working - Latest: $($release.tag_name)" -ForegroundColor Green
    
    # Test 4: Find ZIP asset
    Write-Host "4. Finding download asset..." -ForegroundColor Cyan
    $zip = $release.assets | Where-Object { $_.name -like "Dependencies_*_Release.zip" } | Select-Object -First 1
    if ($zip) {
        Write-Host "   ✓ Found: $($zip.name) ($([math]::Round($zip.size/1MB,1)) MB)" -ForegroundColor Green
        
        # Test 5: Try download
        Write-Host "5. Testing download..." -ForegroundColor Cyan
        $testPath = "C:\temp\VCPP\test_dependencies.zip"
        if (-not (Test-Path "C:\temp\VCPP")) { New-Item -ItemType Directory -Path "C:\temp\VCPP" -Force | Out-Null }
        
        Invoke-WebRequest -Uri $zip.browser_download_url -OutFile $testPath -Headers $headers -UseBasicParsing -TimeoutSec 60
        
        if (Test-Path $testPath) {
            $size = (Get-Item $testPath).Length
            Write-Host "   ✓ Download successful ($([math]::Round($size/1MB,1)) MB)" -ForegroundColor Green
            
            # Test 6: Check ZIP contents
            Write-Host "6. Testing ZIP extraction..." -ForegroundColor Cyan
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zipFile = [System.IO.Compression.ZipFile]::OpenRead($testPath)
            $depEntry = $zipFile.Entries | Where-Object { $_.Name -eq "Dependencies.exe" }
            
            if ($depEntry) {
                Write-Host "   ✓ Dependencies.exe found in ZIP" -ForegroundColor Green
                Write-Host "" -ForegroundColor White
                Write-Host "DIAGNOSIS: Download process works correctly!" -ForegroundColor Green
                Write-Host "The issue might be in the script's error handling or file placement." -ForegroundColor Yellow
                Write-Host "" -ForegroundColor White
                Write-Host "SOLUTION: Try running the script again, or manually:" -ForegroundColor Cyan
                Write-Host "1. Extract Dependencies.exe from: $testPath" -ForegroundColor White
                Write-Host "2. Place it at: C:\temp\VCPP\Dependencies.exe" -ForegroundColor White
            } else {
                Write-Host "   ✗ Dependencies.exe not found in ZIP" -ForegroundColor Red
                Write-Host "   ZIP contains: $($zipFile.Entries.Name -join ', ')" -ForegroundColor Yellow
            }
            $zipFile.Dispose()
            
            # Clean up test file
            Remove-Item $testPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "   ✗ Download failed" -ForegroundColor Red
        }
    } else {
        Write-Host "   ✗ No ZIP asset found" -ForegroundColor Red
        Write-Host "   Available: $($release.assets.name -join ', ')" -ForegroundColor Yellow
    }
    
} catch {
    Write-Host "" -ForegroundColor White
    Write-Host "DIAGNOSIS: Error occurred during test" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
    
    if ($_.Exception.Message -like "*timeout*") {
        Write-Host "LIKELY CAUSE: Network timeout or slow connection" -ForegroundColor Yellow
    } elseif ($_.Exception.Message -like "*403*") {
        Write-Host "LIKELY CAUSE: GitHub rate limiting - wait 10 minutes and try again" -ForegroundColor Yellow
    } elseif ($_.Exception.Message -like "*proxy*" -or $_.Exception.Message -like "*dns*") {
        Write-Host "LIKELY CAUSE: Corporate firewall/proxy blocking access" -ForegroundColor Yellow
    } else {
        Write-Host "LIKELY CAUSE: Network connectivity or security software interference" -ForegroundColor Yellow
    }
    
    Write-Host "" -ForegroundColor White
    Write-Host "WORKAROUND: Manual download" -ForegroundColor Cyan
    Write-Host "1. Go to: https://github.com/lucasg/Dependencies/releases" -ForegroundColor White
    Write-Host "2. Download the latest Dependencies_*_Release.zip" -ForegroundColor White
    Write-Host "3. Extract Dependencies.exe to: C:\temp\VCPP\Dependencies.exe" -ForegroundColor White
}

Write-Host "" -ForegroundColor White