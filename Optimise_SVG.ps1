<#
    .NOTES
    Makes SVG files smaller by rounding long decimal numbers (e.g. 12.3456789
    becomes 12.346). The pictures look the same - the extra decimal places are far
    too small to see.
    Configuration: set the two folder names below - relative to where the script
    is run, or full paths (e.g. "C:\Users\email\OneDrive\Desktop\SVG").

    Rounding:
      - Numbers with 4 or more decimal places are rounded to 3
      - Trailing zeros are removed (1.500 -> 1.5, 2.000 -> 2)
      - Also handles numbers written without a leading 0 (.123456 -> .123), which
        SVG editors often use to save space
      - Never joins two numbers together: a space is added where needed
        (e.g. "1.5.99999" -> "1.5 1")
    Also:
      - All .svg files in the source folder and its subfolders
      - Keeps the subfolder structure
      - Reports per-file AND total size differences
      - Prompts before overwriting existing output files (Yes / No / All / Skip all)
#>

# --- CONFIGURATION ---
$sourceDirName = "SVG"      # folder containing your original SVG files
$outputDirName = "SVG2"     # folder to create for the optimised SVG files
$decimals      = 3          # decimal places to keep
# ---------------------

# --- OVERWRITE PROMPT ---
$script:overwriteAll = $false
$script:skipAll = $false

function Confirm-Overwrite([string]$displayName) {
    if ($script:overwriteAll) { return $true }
    if ($script:skipAll) { return $false }
    while ($true) {
        $ans = Read-Host "  '$displayName' already exists. Overwrite? [Y]es / [N]o / [A]ll / [S]kip all"
        switch ($ans.Trim().ToUpper()) {
            'Y' { return $true }
            'N' { return $false }
            'A' { $script:overwriteAll = $true; return $true }
            'S' { $script:skipAll = $true; return $false }
        }
    }
}
# ------------------------

# Get the script's current location to ensure paths are relative to where the script is run
$rootLocation = Get-Location

# A folder setting as a full path (relative names are taken from where the script is run)
function Resolve-Folder([string]$name) {
    if ([IO.Path]::IsPathRooted($name)) { $p = $name } else { $p = Join-Path $rootLocation $name }
    return [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
}

# --- ROUNDING ---
$culture = [Globalization.CultureInfo]::InvariantCulture
$format = "0." + ("#" * $decimals)
$minDigits = $decimals + 1
$numberPattern = "-?(?:(?<![\d.])\d+\.\d{$minDigits,}|\.\d{$minDigits,})"

# Returns the SVG text with its long numbers rounded; $script:rounded counts them
function Optimize-Svg([string]$svgData) {
    $script:rounded = 0
    $evaluator = {
        param($m)
        $value = [double]::Parse($m.Value, $culture)
        $text = [math]::Round($value, $decimals, [MidpointRounding]::AwayFromZero).ToString($format, $culture)
        if ($text -eq "-0") { $text = "0" }
        # Keep the space-saving style: .123 rather than 0.123
        if ($m.Value -match '^-?\.') { $text = $text -replace '^(-?)0\.', '$1.' }
        # Don't let the new number join onto the one before it...
        if ($m.Index -gt 0 -and $text -match '^\d') {
            $before = $svgData[$m.Index - 1]
            if ([char]::IsDigit($before) -or $before -eq '.') { $text = " " + $text }
        }
        # ...or the one after it (e.g. ".99999.5" -> "1 .5", not "1.5")
        $afterIndex = $m.Index + $m.Length
        if ($text -notmatch '\.' -and $afterIndex -lt $svgData.Length -and $svgData[$afterIndex] -eq '.') {
            $text = $text + " "
        }
        $script:rounded++
        return $text
    }
    return [regex]::Replace($svgData, $numberPattern, [Text.RegularExpressions.MatchEvaluator]$evaluator)
}

# --- SUMMARY BOX ---
function Write-Summary {
    param([string]$Title, [int]$Total, [int]$Skipped, [int]$Failed, [double]$InputBytes, [double]$OutputBytes)

    $totalDiffBytes = $InputBytes - $OutputBytes
    $totalInputKB = [math]::Round($InputBytes / 1KB, 1)
    $totalOutputKB = [math]::Round($OutputBytes / 1KB, 1)
    $totalDiffKB = [math]::Round($totalDiffBytes / 1KB, 1)

    Write-Host "`n================ $Title ================" -ForegroundColor Cyan
    Write-Host "Total Files: $Total"
    Write-Host "Processed:   $($Total - $Skipped - $Failed)"
    Write-Host "Skipped:     $Skipped"
    if ($Failed -gt 0) {
        Write-Host "Failed:      $Failed" -ForegroundColor Red
    } else {
        Write-Host "Failed:      0"
    }
    Write-Host "Original Size: $totalInputKB KB"
    Write-Host "New Size:      $totalOutputKB KB"
    if ($totalDiffBytes -gt 0) {
        Write-Host "TOTAL SAVED:   $totalDiffKB KB" -ForegroundColor Green
    } elseif ($totalDiffBytes -lt 0) {
        Write-Host "TOTAL ADDED:   $([math]::Abs($totalDiffKB)) KB" -ForegroundColor Yellow
    } else {
        Write-Host "TOTAL CHANGE:  0 KB" -ForegroundColor Gray
    }
    Write-Host ("=" * (34 + $Title.Length))
}

# --- FOLDERS ---
$sourcePath = Resolve-Folder $sourceDirName
$destPath = Resolve-Folder $outputDirName

Write-Host "`n================ OPTIMISING SVG FILES ================" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    Write-Host "Error: Source folder '$sourceDirName' not found." -ForegroundColor Red
    Pause
    Exit
}
if ($destPath -eq $sourcePath -or $destPath.StartsWith($sourcePath + "\")) {
    Write-Host "Error: The destination folder can't be the source folder or inside it." -ForegroundColor Red
    Pause
    Exit
}

# Create the output root folder if it doesn't exist
if (-not (Test-Path -LiteralPath $destPath)) {
    [void][IO.Directory]::CreateDirectory($destPath)
}

# -LiteralPath so folder/file names containing [ ] work
$files = @(Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter "*.svg" |
           Where-Object { $_.Extension -eq ".svg" } | Sort-Object FullName)
$totalFiles = $files.Count
$skipped = 0
$failed = 0
$inputBytes = 0
$outputBytes = 0
$i = 0

Write-Host "Found $totalFiles .svg files. Processing..." -ForegroundColor Cyan
Write-Host "------------------------------------------------"

foreach ($file in $files) {
    $i++

    # 1. Subfolder structure: the file's folder relative to the source folder
    $relativePath = $file.DirectoryName.Substring($sourcePath.Length).TrimStart('\', '/')
    $targetDir = if ($relativePath) { Join-Path $destPath $relativePath } else { $destPath }
    if (-not (Test-Path -LiteralPath $targetDir)) {
        [void][IO.Directory]::CreateDirectory($targetDir)
    }
    $outputFile = Join-Path $targetDir $file.Name

    # 2. Check for existing output
    if (Test-Path -LiteralPath $outputFile) {
        $displayName = [IO.Path]::Combine((Split-Path $destPath -Leaf), $relativePath, $file.Name)
        if (-not (Confirm-Overwrite $displayName)) {
            Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
            Write-Host " [SKIPPED]" -ForegroundColor DarkGray
            $skipped++
            continue
        }
    }

    # 3. Read, round and save
    Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
    try {
        $svgData = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
        $optimisedSvg = Optimize-Svg $svgData
        [IO.File]::WriteAllText($outputFile, $optimisedSvg, (New-Object System.Text.UTF8Encoding $false))
    } catch {
        $failed++
        if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile -Force }
        Write-Host " [FAILED]" -ForegroundColor Red
        Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
        continue
    }

    # 4. Per-file difference
    $inputSize = $file.Length
    $outputSize = (Get-Item -LiteralPath $outputFile).Length
    $inputBytes += $inputSize
    $outputBytes += $outputSize

    $diff = $inputSize - $outputSize
    $inputKB = [math]::Round($inputSize / 1KB, 1)
    $outputKB = [math]::Round($outputSize / 1KB, 1)
    $diffKB = [math]::Round($diff / 1KB, 1)

    if ($diff -gt 0) {
        Write-Host " [SAVED $diffKB KB]" -ForegroundColor Green -NoNewline
    } elseif ($diff -lt 0) {
        Write-Host " [ADDED $([math]::Abs($diffKB)) KB]" -ForegroundColor Yellow -NoNewline
    } else {
        Write-Host " [NO CHANGE]" -ForegroundColor Gray -NoNewline
    }
    Write-Host " ($inputKB -> $outputKB KB, $($script:rounded) numbers rounded)"
}

# --- SUMMARY ---
Write-Summary -Title "SUMMARY" -Total $totalFiles -Skipped $skipped -Failed $failed `
    -InputBytes $inputBytes -OutputBytes $outputBytes

Pause
