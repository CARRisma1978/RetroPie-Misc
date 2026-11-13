<#
    .NOTES
    Finds RetroPie video previews that OMX Player won't play (any pixel format
    other than yuv420p, e.g. yuv444p) and makes yuv420p copies of them with FFmpeg.
    ffmpeg.exe and ffprobe.exe are used from the script's own folder, then the
    folder the script is run from, then the PATH.
    Configuration: set the two folder names below - relative to where the script
    is run, or full paths (e.g. "C:\Users\email\OneDrive\Desktop\All").

    Step 1 - Scan:
      - Looks through the source folder and all its subfolders for .mp4 files
      - ffprobe reads each video's pixel format
      - yuv420p videos are fine and are left alone (not copied)
    Step 2 - Convert (only the videos that aren't yuv420p):
      ffmpeg -i "input" -pix_fmt yuv420p -map_metadata -1 -c:a copy -preset veryslow -crf 25 "output"
        -pix_fmt yuv420p   pixel format to yuv420p
        -map_metadata -1   removes unnecessary metadata
        -c:a copy          copies the audio stream rather than re-encoding it
        -preset veryslow   smaller file, takes longer
        -crf 25            smaller file with no noticeable quality loss (default 23)
    Also:
      - Converted videos keep the source folder's subfolder structure, ready to
        copy over the old files on the Pi
      - Reports per-file AND total size differences
      - Prompts before overwriting existing output files (Yes / No / All / Skip all)
      - FFmpeg's own messages are kept quiet unless it fails
#>

# --- CONFIGURATION ---
$sourceDirName = "V2"      # folder containing your original videos
$outputDirName = "V3"      # folder to create for the converted videos
# ---------------------

# ffprobe options: print only the first video stream's pixel format (the file is added per video)
$ffprobeArgs = @("-v", "error", "-select_streams", "v:0", "-show_entries", "stream=pix_fmt",
                 "-of", "default=noprint_wrappers=1:nokey=1")

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

# --- FIND FFMPEG / FFPROBE ---
# next to this script, or in the folder it's run from, or on the PATH
function Find-Tool([string]$tool) {
    foreach ($dir in @($PSScriptRoot, $rootLocation.Path)) {
        if (-not $dir) { continue }
        foreach ($name in @("$tool.exe", $tool)) {
            $candidate = Join-Path $dir $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$ffmpegExe = Find-Tool "ffmpeg"
$ffprobeExe = Find-Tool "ffprobe"
foreach ($t in @(@("ffmpeg", $ffmpegExe), @("ffprobe", $ffprobeExe))) {
    if (-not $t[1]) {
        Write-Host "Error: $($t[0]).exe not found - put it in the same folder as this script" -ForegroundColor Red
        Write-Host "       ($PSScriptRoot), or install it on the PATH." -ForegroundColor Red
        Pause
        Exit
    }
}
Write-Host "Using ffmpeg:  $ffmpegExe" -ForegroundColor DarkGray
Write-Host "Using ffprobe: $ffprobeExe" -ForegroundColor DarkGray

# --- FOLDERS ---
$sourcePath = Resolve-Folder $sourceDirName
$destPath = Resolve-Folder $outputDirName

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

# ============ STEP 1: SCAN ============
Write-Host "`n================ SCANNING ================" -ForegroundColor Cyan

# -LiteralPath so folder/file names containing [ ] (e.g. "Game (USA) [!].mp4") work
$files = @(Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter "*.mp4" |
           Where-Object { $_.Extension -eq ".mp4" } | Sort-Object FullName)
$totalFiles = $files.Count
Write-Host "Found $totalFiles .mp4 files. Checking pixel formats..." -ForegroundColor Cyan
Write-Host "------------------------------------------------"

$toConvert = New-Object System.Collections.Generic.List[object]
$okCount = 0
$probeFailed = 0
$i = 0

foreach ($file in $files) {
    $i++
    Write-Progress -Activity "Scanning pixel formats" -Status "[$i/$totalFiles] $($file.Name)" `
        -PercentComplete ([math]::Floor($i * 100 / [math]::Max($totalFiles, 1)))

    $probeOut = & $ffprobeExe @ffprobeArgs $file.FullName 2>&1
    $probeOk = ($LASTEXITCODE -eq 0)
    $pixFmt = ($probeOut | Where-Object { $_ -is [string] } | Select-Object -First 1)
    if ($pixFmt) { $pixFmt = $pixFmt.Trim() }

    if (-not $probeOk -or -not $pixFmt) {
        $probeFailed++
        Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
        Write-Host " [PROBE FAILED - not converted]" -ForegroundColor Red
        $probeOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } elseif ($pixFmt -eq "yuv420p") {
        $okCount++
    } else {
        $toConvert.Add([pscustomobject]@{ File = $file; PixFmt = $pixFmt })
        Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
        Write-Host " [$pixFmt]" -ForegroundColor Yellow
    }
}
Write-Progress -Activity "Scanning pixel formats" -Completed

Write-Host "------------------------------------------------"
Write-Host "Already yuv420p (OK):  $okCount"
Write-Host "Need converting:       $($toConvert.Count)" -ForegroundColor Yellow
if ($probeFailed -gt 0) { Write-Host "Couldn't be read:      $probeFailed" -ForegroundColor Red }

# ============ STEP 2: CONVERT ============
$convertTotal = $toConvert.Count
$converted = 0
$skipped = 0
$failed = 0
$inputBytes = 0
$outputBytes = 0

if ($convertTotal -gt 0) {
    Write-Host "`n================ CONVERTING ================" -ForegroundColor Cyan
    Write-Host "Converting $convertTotal videos (-preset veryslow, this can take a while)..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------"

    if (-not (Test-Path -LiteralPath $destPath)) {
        [void][IO.Directory]::CreateDirectory($destPath)
    }

    $i = 0
    foreach ($item in $toConvert) {
        $i++
        $file = $item.File

        # 1. Subfolder structure: the file's folder relative to the source folder
        $relativePath = $file.DirectoryName.Substring($sourcePath.Length).TrimStart('\', '/')
        $targetDir = if ($relativePath) { Join-Path $destPath $relativePath } else { $destPath }
        if (-not (Test-Path -LiteralPath $targetDir)) {
            [void][IO.Directory]::CreateDirectory($targetDir)
        }
        $outputFile = Join-Path $targetDir $file.Name

        # 2. Check for existing output (deleted first if overwriting, so FFmpeg doesn't ask too)
        if (Test-Path -LiteralPath $outputFile) {
            $displayName = [IO.Path]::Combine($outputDirName, $relativePath, $file.Name)
            if (-not (Confirm-Overwrite $displayName)) {
                Write-Host "[$i/$convertTotal] $($file.Name)" -NoNewline
                Write-Host " [SKIPPED]" -ForegroundColor DarkGray
                $skipped++
                continue
            }
            Remove-Item -LiteralPath $outputFile -Force
        }

        # 3. Capture Input Size
        $inputSize = $file.Length

        # 4. Run FFmpeg - the exact command line (its messages are kept quiet unless it fails)
        Write-Host "[$i/$convertTotal] $($file.Name) ($($item.PixFmt))" -NoNewline
        $ffOutput = & $ffmpegExe -i $file.FullName -pix_fmt yuv420p -map_metadata -1 -c:a copy -preset veryslow -crf 25 $outputFile 2>&1
        $ok = ($LASTEXITCODE -eq 0)

        # 5. Per-file difference
        if ($ok -and (Test-Path -LiteralPath $outputFile)) {
            $converted++
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
            Write-Host " ($inputKB -> $outputKB KB)"
        } else {
            # Failed: remove any half-written output; its size isn't counted in the totals
            $failed++
            if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile -Force }
            Write-Host " [FAILED]" -ForegroundColor Red
            $ffOutput | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }
}

# ============ SUMMARY ============
$totalDiffBytes = $inputBytes - $outputBytes
$totalInputMB = [math]::Round($inputBytes / 1MB, 2)
$totalOutputMB = [math]::Round($outputBytes / 1MB, 2)
$totalDiffMB = [math]::Round($totalDiffBytes / 1MB, 2)

$title = "SUMMARY"
Write-Host "`n================ $title ================" -ForegroundColor Cyan
Write-Host "Videos Scanned:   $totalFiles"
Write-Host "Already yuv420p:  $okCount"
if ($probeFailed -gt 0) { Write-Host "Couldn't Read:    $probeFailed" -ForegroundColor Red }
Write-Host "Need Converting:  $convertTotal"
Write-Host "  Converted:      $converted"
Write-Host "  Skipped:        $skipped"
if ($failed -gt 0) {
    Write-Host "  Failed:         $failed" -ForegroundColor Red
} else {
    Write-Host "  Failed:         0"
}
if ($converted -gt 0) {
    Write-Host "Original Size: $totalInputMB MB"
    Write-Host "New Size:      $totalOutputMB MB"
    if ($totalDiffBytes -gt 0) {
        Write-Host "TOTAL SAVED:   $totalDiffMB MB" -ForegroundColor Green
    } elseif ($totalDiffBytes -lt 0) {
        Write-Host "TOTAL ADDED:   $([math]::Abs($totalDiffMB)) MB" -ForegroundColor Yellow
    } else {
        Write-Host "TOTAL CHANGE:  0 MB" -ForegroundColor Gray
    }
    Write-Host "Converted videos are in: $destPath"
} elseif ($convertTotal -eq 0 -and $probeFailed -eq 0) {
    Write-Host "All videos are already yuv420p - nothing to convert." -ForegroundColor Green
}
Write-Host ("=" * (34 + $title.Length))

Pause