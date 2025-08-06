#========================================================================
# Resource-Tracking-3
# Purpose: Deployment Script - Creates complete custom CSS for charts
# Schedule: Once on deployment + every startup
# Output: charts-custom.css in C:\temp2\
#========================================================================

# PowerShell script to save complete custom CSS content to c:\temp2\charts-custom.css

# Ensure the destination directory exists
$destinationPath = "c:\temp2\"
if (-not (Test-Path -Path $destinationPath)) {
    New-Item -ItemType Directory -Force -Path $destinationPath
}

# Complete Custom CSS content - replaces Charts.css CDN entirely
$cssContent = @"
/* ===================================================================
   Custom Resource Chart CSS - Replaces Charts.css CDN
   Highly distinguishable colors for drive identification
   =================================================================== */

/* CSS Custom Properties for Colors */
:root {
    /* System Resource Colors */
    --cpu-color: #e74c3c;        /* Bright Red - CPU */
    --memory-color: #3498db;     /* Blue - Memory */
    
    /* Highly Distinguishable Drive Colors */
    --disk-c-color: #00ff00;     /* Bright Green - C Drive */
    --disk-d-color: #ff8c00;     /* Dark Orange - D Drive */  
    --disk-e-color: #8a2be2;     /* Blue Violet - E Drive */
    --disk-f-color: #00ffff;     /* Cyan - F Drive */
    --disk-g-color: #ff1493;     /* Deep Pink - G Drive */
    --disk-h-color: #ffd700;     /* Gold - H Drive */
    --disk-i-color: #4169e1;     /* Royal Blue - I Drive */
    --disk-j-color: #8b4513;     /* Saddle Brown - J Drive */
    
    /* Chart styling */
    --grid-color: rgba(0, 0, 0, 0.15);
    --axis-color: #000;
    --background-color: white;
    --line-width: 3px;
}

/* ===================================================================
   BASE CHART CONTAINER SETUP
   =================================================================== */

.charts-css {
    display: block;
    width: 100%;
    height: 100%;
    position: relative;
    background-color: var(--background-color);
    margin: 0 auto;
    padding: 0;
    border: 0;
    box-sizing: border-box;
}

.charts-css *,
.charts-css *::before,
.charts-css *::after {
    box-sizing: border-box;
}

/* ===================================================================
   TABLE STRUCTURE FOR LINE CHARTS
   =================================================================== */

table.charts-css {
    border-collapse: collapse;
    border-spacing: 0;
    empty-cells: show;
    background-color: transparent;
    overflow: initial;
}

table.charts-css caption,
table.charts-css tbody,
table.charts-css tr,
table.charts-css th,
table.charts-css td {
    display: block;
    margin: 0;
    padding: 0;
    border: 0;
    background-color: transparent;
}

/* ===================================================================
   LINE CHART SPECIFIC STYLING
   =================================================================== */

.charts-css.line tbody {
    display: flex;
    justify-content: space-between;
    align-items: stretch;
    width: 100%;
    aspect-ratio: 21/9; /* Wide chart format */
    position: relative;
}

.charts-css.line tbody tr {
    display: flex;
    flex-direction: row;
    flex-grow: 1;
    flex-shrink: 1;
    flex-basis: 0;
    justify-content: flex-start;
    position: relative;
    overflow-wrap: anywhere;
}

.charts-css.line tbody tr th {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    top: 0;
    height: 1.5rem;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-end;
}

.charts-css.line tbody tr td {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    top: 0;
    width: 100%;
    height: 100%;
    display: flex;
    flex-flow: column;
    justify-content: flex-end;
    align-items: flex-end;
    z-index: 0;
}

.charts-css.line tbody tr td::before {
    content: "";
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    top: 0;
    z-index: -1;
}

/* ===================================================================
   COLOR ASSIGNMENTS FOR DATA SERIES
   =================================================================== */

/* CPU - First data series (td:nth-of-type(1)) */
.charts-css.line tbody tr td:nth-of-type(1)::before {
    background: var(--cpu-color);
}

/* Memory - Second data series (td:nth-of-type(2)) */
.charts-css.line tbody tr td:nth-of-type(2)::before {
    background: var(--memory-color);
}

/* Disk C - Third data series (td:nth-of-type(3)) */
.charts-css.line tbody tr td:nth-of-type(3)::before {
    background: var(--disk-c-color);
}

/* Disk D - Fourth data series (td:nth-of-type(4)) */
.charts-css.line tbody tr td:nth-of-type(4)::before {
    background: var(--disk-d-color);
}

/* Disk E - Fifth data series (td:nth-of-type(5)) */
.charts-css.line tbody tr td:nth-of-type(5)::before {
    background: var(--disk-e-color);
}

/* Disk F - Sixth data series (td:nth-of-type(6)) */
.charts-css.line tbody tr td:nth-of-type(6)::before {
    background: var(--disk-f-color);
}

/* Disk G - Seventh data series (td:nth-of-type(7)) */
.charts-css.line tbody tr td:nth-of-type(7)::before {
    background: var(--disk-g-color);
}

/* Disk H - Eighth data series (td:nth-of-type(8)) */
.charts-css.line tbody tr td:nth-of-type(8)::before {
    background: var(--disk-h-color);
}

/* Disk I - Ninth data series (td:nth-of-type(9)) */
.charts-css.line tbody tr td:nth-of-type(9)::before {
    background: var(--disk-i-color);
}

/* Disk J - Tenth data series (td:nth-of-type(10)) */
.charts-css.line tbody tr td:nth-of-type(10)::before {
    background: var(--disk-j-color);
}

/* ===================================================================
   LINE DRAWING USING CLIP-PATH
   =================================================================== */

.charts-css.line {
    --line-size: var(--line-width);
}

/* Draw lines using CSS clip-path for connected line segments */
.charts-css.line tbody tr td::before {
    clip-path: polygon(
        0 calc(100% * (1 - var(--start, var(--end, var(--size))))),
        100% calc(100% * (1 - var(--end, var(--size)))),
        100% calc(100% * (1 - var(--end, var(--size))) - var(--line-size)),
        0 calc(100% * (1 - var(--start, var(--end, var(--size)))) - var(--line-size))
    );
}

/* ===================================================================
   DATA POINTS (DOTS ON LINES)
   =================================================================== */

.charts-css.line tbody tr td::after {
    content: "";
    position: absolute;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background-color: currentColor;
    z-index: 15;
    top: calc(100% * (1 - var(--end, var(--size))));
    left: 50%;
    transform: translate(-50%, -50%);
}

/* Set currentColor for data points to match line colors */
.charts-css.line tbody tr td:nth-of-type(1) { color: var(--cpu-color); }
.charts-css.line tbody tr td:nth-of-type(2) { color: var(--memory-color); }
.charts-css.line tbody tr td:nth-of-type(3) { color: var(--disk-c-color); }
.charts-css.line tbody tr td:nth-of-type(4) { color: var(--disk-d-color); }
.charts-css.line tbody tr td:nth-of-type(5) { color: var(--disk-e-color); }
.charts-css.line tbody tr td:nth-of-type(6) { color: var(--disk-f-color); }
.charts-css.line tbody tr td:nth-of-type(7) { color: var(--disk-g-color); }
.charts-css.line tbody tr td:nth-of-type(8) { color: var(--disk-h-color); }
.charts-css.line tbody tr td:nth-of-type(9) { color: var(--disk-i-color); }
.charts-css.line tbody tr td:nth-of-type(10) { color: var(--disk-j-color); }

/* ===================================================================
   GRID LINES AND AXES
   =================================================================== */

/* Primary axis (bottom border) */
.charts-css.show-primary-axis tbody tr {
    border-bottom: 1px solid var(--axis-color);
}

/* Secondary axes (horizontal grid lines) */
.charts-css.show-10-secondary-axes tbody tr {
    background-image: linear-gradient(
        var(--grid-color) 1px,
        transparent 1px
    );
    background-size: 100% calc(100% / 10);
}

/* Data axes (vertical grid lines) */
.charts-css.show-data-axes tbody tr {
    border-right: 1px solid var(--grid-color);
}

.charts-css.show-data-axes tbody tr:first-of-type {
    border-left: 1px solid var(--grid-color);
}

/* ===================================================================
   HOVER TOOLTIPS
   =================================================================== */

.charts-css .data {
    display: flex;
}

.charts-css.show-data-on-hover .data {
    opacity: 0;
    transition: opacity 0.3s;
}

.charts-css.show-data-on-hover tr:hover .data {
    opacity: 1;
    transition: opacity 0.3s;
}

/* Tooltip positioning */
.charts-css.line tbody tr td .data {
    transform: translateX(50%);
    position: absolute;
    bottom: calc(100% * var(--end, var(--size)) - 20px);
    left: 50%;
    background-color: rgba(0, 0, 0, 0.8);
    color: white;
    padding: 4px 8px;
    border-radius: 4px;
    font-size: 12px;
    white-space: nowrap;
    z-index: 20;
}

/* ===================================================================
   LEGEND STYLING
   =================================================================== */

.charts-css.legend {
    list-style: none;
    padding: 1rem;
    border: 1px solid #c8c8c8;
    font-size: 1rem;
}

.charts-css.legend li {
    display: flex;
    align-items: center;
    line-height: 2;
}

.charts-css.legend li::before {
    content: "";
    display: inline-block;
    width: 14px;
    height: 14px;
    margin-right: 0.5rem;
    border-radius: 3px;
    border: 2px solid #000;
}

/* Horizontal legend layout */
.charts-css.legend-inline {
    display: flex;
    flex-direction: row;
    flex-wrap: wrap;
}

.charts-css.legend-inline li {
    margin-right: 1.5rem;
}

/* Legend color assignments */
.charts-css.legend li:nth-child(1)::before { background-color: var(--cpu-color); }
.charts-css.legend li:nth-child(2)::before { background-color: var(--memory-color); }
.charts-css.legend li:nth-child(3)::before { background-color: var(--disk-c-color); }
.charts-css.legend li:nth-child(4)::before { background-color: var(--disk-d-color); }
.charts-css.legend li:nth-child(5)::before { background-color: var(--disk-e-color); }
.charts-css.legend li:nth-child(6)::before { background-color: var(--disk-f-color); }
.charts-css.legend li:nth-child(7)::before { background-color: var(--disk-g-color); }
.charts-css.legend li:nth-child(8)::before { background-color: var(--disk-h-color); }
.charts-css.legend li:nth-child(9)::before { background-color: var(--disk-i-color); }
.charts-css.legend li:nth-child(10)::before { background-color: var(--disk-j-color); }

/* ===================================================================
   RESPONSIVE AND ACCESSIBILITY
   =================================================================== */

@media (max-width: 768px) {
    .charts-css.legend-inline {
        flex-direction: column;
    }
    
    .charts-css.legend-inline li {
        margin-right: 0;
        margin-bottom: 0.5rem;
    }
}

/* Ensure chart is accessible */
.charts-css[role="img"] {
    alt: "Resource utilization line chart";
}

/* ===================================================================
   CAPTION AND LABELS
   =================================================================== */

.charts-css.show-heading caption {
    display: block;
    width: 100%;
    font-weight: bold;
    text-align: center;
    margin-bottom: 1rem;
}

/* Labels positioning */
.charts-css.show-labels tbody tr {
    margin-bottom: 1.5rem;
}

.charts-css.show-labels tbody tr th {
    margin-bottom: calc(-1 * 1.5rem - 1px);
    margin-top: auto;
}
"@

# Write the CSS content to the file
$cssContent | Out-File -FilePath "$destinationPath\charts-custom.css" -Encoding UTF8

# Confirm file creation
Write-Host "Complete custom CSS file has been created at $destinationPath\charts-custom.css"
Write-Host "This CSS replaces the Charts.css CDN dependency entirely"
Write-Host "Colors configured:"
Write-Host "  - CPU: Bright Red"
Write-Host "  - Memory: Blue" 
Write-Host "  - Disk C: Bright Green"
Write-Host "  - Disk D: Dark Orange"
Write-Host "  - Disk E: Blue Violet"
Write-Host "  - Disk F: Cyan"
Write-Host "  - Disk G: Deep Pink"
Write-Host "  - Disk H: Gold"
Write-Host "  - Disk I: Royal Blue"
Write-Host "  - Disk J: Saddle Brown"