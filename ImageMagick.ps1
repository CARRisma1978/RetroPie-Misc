<#
    .NOTES
    Processes covers, then marquees, with ImageMagick ("magick" must be on the PATH).
    Configuration: set the four folder names below (relative to where the script is run).

    Covers:
      - Converts .png / .jpg / .jpeg to PNG
      - Resizes to max 700x700 (only if larger, preserves aspect ratio)
      - Strips metadata (-strip)
      - Best PNG compression (-quality 95)
      - Prevents file bloat by preserving color type (-define png:preserve-colortype=true)
    Marquees:
      - .png only
      - Trims blank borders (-trim +repage)
      - Resizes to max 600x600 (only if larger, preserves aspect ratio)
    Both:
      - Keeps the subfolder structure
      - Reports per-file AND total size differences
      - Prompts before overwriting existing output files (Yes / No / All / Skip all),
        asked afresh for marquees
      - A summary for covers, one for marquees, then one for both combined
#>

# --- CONFIGURATION ---
$coverSourceDirName   = "C"     # NAME of the folder containing your original covers
$coverOutputDirName   = "C2"    # NAME of the folder to create for processed covers
$marqueeSourceDirName = "M"     # NAME of the folder containing your original marquees
$marqueeOutputDirName = "M2"    # NAME of the folder to create for processed marquees
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

# --- PROCESS ONE SET (covers or marquees) ---
# Returns the totals for the summaries. Missing source folder: a warning, and
# that set is skipped (the other still runs).
function Invoke-ImageSet {
    param(
        [string]$Label,             # "COVERS" / "MARQUEES"
        [string]$SourceDirName,
        [string]$OutputDirName,
        [string[]]$Include,         # file patterns
        [bool]$ForcePng,            # $true = output always .png
        [string[]]$MagickArgs       # ImageMagick options between input and output
    )

    $result = [pscustomobject]@{
        Label = $Label; Found = $false; Total = 0; Skipped = 0
        InputBytes = 0; OutputBytes = 0
    }

    # Overwrite answers start afresh for each set
    $script:overwriteAll = $false
    $script:skipAll = $false

    $sourcePath = Join-Path $rootLocation $SourceDirName
    $destPath = Join-Path $rootLocation $OutputDirName

    Write-Host "`n================ $Label ================" -ForegroundColor Cyan

    # Verify source exists
    if (-not (Test-Path $sourcePath)) {
        Write-Host "Error: Source folder '$SourceDirName' not found - $Label skipped." -ForegroundColor Red
        return $result
    }
    $result.Found = $true

    # Create the output root folder if it doesn't exist
    if (-not (Test-Path $destPath)) {
        New-Item -ItemType Directory -Path $destPath | Out-Null
    }

    $files = @(Get-ChildItem -Path $sourcePath -Recurse -File -Include $Include)
    $totalFiles = $files.Count
    $result.Total = $totalFiles
    $i = 0

    Write-Host "Found $totalFiles files. Processing..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------"

    foreach ($file in $files) {
        $i++

        # 1. Subfolder structure: the file's folder relative to the source folder
        $relativePath = $file.DirectoryName.Replace($sourcePath, "")
        $targetDir = Join-Path $destPath $relativePath
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir | Out-Null
        }

        # 2. Output filename (covers: always .png)
        $outName = if ($ForcePng) { $file.BaseName + ".png" } else { $file.Name }
        $outputFile = Join-Path $targetDir $outName

        # 3. Check for existing output
        if (Test-Path $outputFile) {
            $displayName = [IO.Path]::Combine($OutputDirName, $relativePath.TrimStart('\', '/'), $outName)
            if (-not (Confirm-Overwrite $displayName)) {
                Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
                Write-Host " [SKIPPED]" -ForegroundColor DarkGray
                $result.Skipped++
                continue
            }
        }

        # 4. Capture Input Size
        $inputSize = $file.Length
        $result.InputBytes += $inputSize

        # 5. Run ImageMagick
        & magick $file.FullName @MagickArgs $outputFile

        # 6. Per-file difference
        if (Test-Path $outputFile) {
            $outputSize = (Get-Item $outputFile).Length
            $result.OutputBytes += $outputSize

            $diff = $inputSize - $outputSize
            $inputKB = [math]::Round($inputSize / 1KB, 1)
            $outputKB = [math]::Round($outputSize / 1KB, 1)
            $diffKB = [math]::Round($diff / 1KB, 1)

            Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
            if ($diff -gt 0) {
                Write-Host " [SAVED $diffKB KB]" -ForegroundColor Green -NoNewline
            } elseif ($diff -lt 0) {
                Write-Host " [ADDED $([math]::Abs($diffKB)) KB]" -ForegroundColor Yellow -NoNewline
            } else {
                Write-Host " [NO CHANGE]" -ForegroundColor Gray -NoNewline
            }
            Write-Host " ($inputKB -> $outputKB KB)"
        } else {
            Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
            Write-Host " [FAILED - no output]" -ForegroundColor Red
        }
    }

    return $result
}

# --- SUMMARY BOX ---
function Write-Summary {
    param([string]$Title, [int]$Total, [int]$Skipped, [double]$InputBytes, [double]$OutputBytes)

    $totalDiffBytes = $InputBytes - $OutputBytes
    $totalInputMB = [math]::Round($InputBytes / 1MB, 2)
    $totalOutputMB = [math]::Round($OutputBytes / 1MB, 2)
    $totalDiffMB = [math]::Round($totalDiffBytes / 1MB, 2)

    Write-Host "`n================ $Title ================" -ForegroundColor Cyan
    Write-Host "Total Files: $Total"
    Write-Host "Processed:   $($Total - $Skipped)"
    Write-Host "Skipped:     $Skipped"
    Write-Host "Original Size: $totalInputMB MB"
    Write-Host "New Size:      $totalOutputMB MB"
    if ($totalDiffBytes -gt 0) {
        Write-Host "TOTAL SAVED:   $totalDiffMB MB" -ForegroundColor Green
    } elseif ($totalDiffBytes -lt 0) {
        Write-Host "TOTAL ADDED:   $([math]::Abs($totalDiffMB)) MB" -ForegroundColor Yellow
    } else {
        Write-Host "TOTAL CHANGE:  0 MB" -ForegroundColor Gray
    }
    Write-Host ("=" * (34 + $Title.Length))
}

# --- RUN: covers, then marquees ---
$covers = Invoke-ImageSet -Label "COVERS" `
    -SourceDirName $coverSourceDirName -OutputDirName $coverOutputDirName `
    -Include @("*.png", "*.jpg", "*.jpeg") -ForcePng $true `
    -MagickArgs @("-resize", "700x700>", "-strip", "-quality", "95",
                  "-define", "png:preserve-colortype=true")

$marquees = Invoke-ImageSet -Label "MARQUEES" `
    -SourceDirName $marqueeSourceDirName -OutputDirName $marqueeOutputDirName `
    -Include @("*.png") -ForcePng $false `
    -MagickArgs @("-trim", "+repage", "-resize", "600x600>")

# --- SUMMARIES: each set, then both combined ---
foreach ($r in @($covers, $marquees)) {
    if ($r.Found) {
        Write-Summary -Title "$($r.Label) SUMMARY" -Total $r.Total -Skipped $r.Skipped `
            -InputBytes $r.InputBytes -OutputBytes $r.OutputBytes
    } else {
        Write-Host "`n================ $($r.Label) SUMMARY ================" -ForegroundColor Cyan
        Write-Host "Source folder not found - nothing processed." -ForegroundColor Red
    }
}

Write-Summary -Title "COMBINED SUMMARY" `
    -Total ($covers.Total + $marquees.Total) `
    -Skipped ($covers.Skipped + $marquees.Skipped) `
    -InputBytes ($covers.InputBytes + $marquees.InputBytes) `
    -OutputBytes ($covers.OutputBytes + $marquees.OutputBytes)

Pause
