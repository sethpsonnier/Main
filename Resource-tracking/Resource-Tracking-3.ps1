#========================================================================
# Resource-Tracking-3
# Purpose: Deployment Script - Creates custom CSS styling for charts
# Schedule: Once on deployment + every startup
# Output: charts-custom.css in C:\temp2\
#========================================================================

# PowerShell script to save CSS content to c:\temp2\charts-custom.css

# Ensure the destination directory exists
$destinationPath = "c:\temp2\"
if (-not (Test-Path -Path $destinationPath)) {
    New-Item -ItemType Directory -Force -Path $destinationPath
}

# CSS content
$cssContent = @"
/* Modified CSS for fixing line overlap in charts */

/* Change color definitions to match requirements */
.charts-css {
    /* Updated colors for the specific metrics */
    --color-1: #e74c3c !important; /* CPU - Red */
    --color-2: #3498db !important; /* Memory - Blue */
    --color-3: #2ecc71 !important; /* Disk C - Green */
    --color-4: #f39c12 !important; /* Disk D - Orange */
    --color-5: #9b59b6 !important; /* Disk E - Purple */
    --color-6: #1abc9c !important; /* Disk F - Teal */
    --color-7: #34495e !important; /* Disk G - Dark Blue */
    --color-8: #e84393 !important; /* Disk H - Pink */
    --color-9: #7ed6df !important; /* Disk I - Lime */
    --color-10: #795548 !important; /* Disk J - Brown */
}

/* Update root variables to match our line colors */
:root {
    --color-1: #e74c3c !important;
    --color-2: #3498db !important;
    --color-3: #2ecc71 !important;
    --color-4: #f39c12 !important;
    --color-5: #9b59b6 !important;
    --color-6: #1abc9c !important;
    --color-7: #34495e !important;
    --color-8: #e84393 !important;
    --color-9: #7ed6df !important;
    --color-10: #795548 !important;
}

/* Critical Fix: Add z-index to control line stacking order */
.charts-css.line.multiple td:nth-of-type(1) { 
    --color: #e74c3c !important;
    z-index: 10 !important;
}
.charts-css.line.multiple td:nth-of-type(2) { 
    --color: #3498db !important;
    z-index: 9 !important;
}
.charts-css.line.multiple td:nth-of-type(3) { 
    --color: #2ecc71 !important;
    z-index: 8 !important;
}

/* Critical Fix: Vertical offset positioning to separate overlapping lines */
.charts-css.line.multiple tbody tr:nth-child(1) td {
    position: relative;
    top: -5px !important; /* Shift CPU line up */
}
.charts-css.line.multiple tbody tr:nth-child(2) td {
    position: relative;
    top: -10px !important; /* Shift Memory line up */
}
.charts-css.line.multiple tbody tr:nth-child(3) td {
    position: relative;
    top: 0 !important; /* Keep disk line at base position */
}

/* Make lines thicker and more visible */
.charts-css.line {
    --line-size: 3px !important;
}

/* Add dots at data points for better visibility */
.charts-css.line td::before {
    border-top-width: 3px !important;
    border-top-style: solid !important;
}

/* Add data points */
.charts-css.line tbody tr td::after {
    content: "" !important;
    position: absolute !important;
    width: 7px !important;
    height: 7px !important;
    border-radius: 50% !important;
    background-color: currentColor !important;
    z-index: 15 !important;
    top: 0 !important;
    left: 50% !important;
    transform: translate(-50%, -50%) !important;
}

/* Improve tooltip styling */
.charts-css .show-data-on-hover td::after {
    background-color: rgba(0, 0, 0, 0.8) !important;
    padding: 6px 10px !important;
    border-radius: 5px !important;
    box-shadow: 0 2px 5px rgba(0,0,0,0.2) !important;
    font-size: 12px !important;
    margin-bottom: 8px !important;
    z-index: 20 !important;
}

/* Update legend colors to match our data line colors */
.charts-css.legend li:nth-child(1)::before {
    background-color: #e74c3c !important; /* CPU - Red */
}
.charts-css.legend li:nth-child(2)::before {
    background-color: #3498db !important; /* Memory - Blue */
}
.charts-css.legend li:nth-child(3)::before {
    background-color: #2ecc71 !important; /* Disk C - Green */
}
.charts-css.legend li:nth-child(4)::before {
    background-color: #f39c12 !important; /* Disk D - Orange */
}
.charts-css.legend li:nth-child(5)::before {
    background-color: #9b59b6 !important; /* Disk E - Purple */
}
.charts-css.legend li:nth-child(6)::before {
    background-color: #1abc9c !important; /* Disk F - Teal */
}
.charts-css.legend li:nth-child(7)::before {
    background-color: #34495e !important; /* Disk G - Dark Blue */
}
.charts-css.legend li:nth-child(8)::before {
    background-color: #e84393 !important; /* Disk H - Pink */
}
.charts-css.legend li:nth-child(9)::before {
    background-color: #7ed6df !important; /* Disk I - Lime */
}
.charts-css.legend li:nth-child(10)::before {
    background-color: #795548 !important; /* Disk J - Brown */
}

/* Improve legend styling */
.charts-css.legend li {
    display: inline-flex !important;
    align-items: center !important;
    margin-right: 1.5em !important;
    position: relative !important;
    padding-left: 0 !important;
    width: auto !important;
    font-size: 13px !important;
}

.charts-css.legend li::before {
    content: "" !important;
    display: inline-block !important;
    width: 12px !important;
    height: 12px !important;
    margin-right: 0.5em !important;
    border-radius: 3px !important;
    position: static !important;
}

/* Add to the CSS file to ensure white background */
.charts-css {
    background-color: white !important;
}
.charts-css.line.multiple td {
    background-color: transparent !important;
    background-image: none !important;
}
"@

# Write the CSS content to the file
$cssContent | Out-File -FilePath "$destinationPath\charts-custom.css" -Encoding UTF8

# Confirm file creation
Write-Host "CSS file has been created at $destinationPath\charts-custom.css"