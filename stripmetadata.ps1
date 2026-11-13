<#
    .NOTES
    Strips metadata from .mp4 videos with FFmpeg, writing clean copies to a new folder.
    Nothing is re-encoded: the picture and sound are copied exactly as they are,
    so there's no quality loss and it's quick.
    ffmpeg.exe is used from the script's own folder, then the folder the script
    is run from, then the PATH.
    Configuration: set the two folder names below - relative to where the script
    is run, or full paths (e.g. "C:\Users\email\OneDrive\Desktop\done").

    FFmpeg command:
      ffmpeg -i "input" -map_metadata -1 -c copy "output"
        -map_metadata -1   removes the metadata
        -c copy            copies the video and audio streams without re-encoding
    Also:
      - .mp4 files in the source folder and its subfolders
      - Keeps the subfolder structure
      - Reports per-file AND total size differences
      - Prompts before overwriting existing output files (Yes / No / All / Skip all)
      - FFmpeg's own messages are kept quiet unless it fails
#>

# --- CONFIGURATION ---
$sourceDirName = "C:\Users\email\OneDrive\Desktop\V"    # folder containing the original videos
$outputDirName = "C:\Users\email\OneDrive\Desktop\V2"   # folder to create for the stripped videos
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

# --- SUMMARY BOX ---
function Write-Summary {
    param([string]$Title, [int]$Total, [int]$Skipped, [int]$Failed, [double]$InputBytes, [double]$OutputBytes)

    $totalDiffBytes = $InputBytes - $OutputBytes
    $totalInputMB = [math]::Round($InputBytes / 1MB, 2)
    $totalOutputMB = [math]::Round($OutputBytes / 1MB, 2)
    $totalDiffMB = [math]::Round($totalDiffBytes / 1MB, 2)

    Write-Host "`n================ $Title ================" -ForegroundColor Cyan
    Write-Host "Total Files: $Total"
    Write-Host "Processed:   $($Total - $Skipped - $Failed)"
    Write-Host "Skipped:     $Skipped"
    if ($Failed -gt 0) {
        Write-Host "Failed:      $Failed" -ForegroundColor Red
    } else {
        Write-Host "Failed:      0"
    }
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

# --- CHECK FFMPEG ---
# ffmpeg.exe next to this script, or in the folder it's run from, or on the PATH
$script:ffmpegExe = $null
foreach ($dir in @($PSScriptRoot, $rootLocation.Path)) {
    if (-not $dir) { continue }
    foreach ($name in @("ffmpeg.exe", "ffmpeg")) {
        $candidate = Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:ffmpegExe = $candidate; break }
    }
    if ($script:ffmpegExe) { break }
}
if (-not $script:ffmpegExe) {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { $script:ffmpegExe = $cmd.Source }
}
if (-not $script:ffmpegExe) {
    Write-Host "Error: ffmpeg.exe not found - put it in the same folder as this script" -ForegroundColor Red
    Write-Host "       ($PSScriptRoot), or install it on the PATH." -ForegroundColor Red
    Pause
    Exit
}
Write-Host "Using ffmpeg: $script:ffmpegExe" -ForegroundColor DarkGray

# --- FOLDERS ---
$sourcePath = Resolve-Folder $sourceDirName
$destPath = Resolve-Folder $outputDirName

Write-Host "`n================ STRIPPING METADATA ================" -ForegroundColor Cyan

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

# -LiteralPath so folder/file names containing [ ] (e.g. "Game (USA) [!].mp4") work
$files = @(Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter "*.mp4" |
           Where-Object { $_.Extension -eq ".mp4" } | Sort-Object FullName)
$totalFiles = $files.Count
$skipped = 0
$failed = 0
$inputBytes = 0
$outputBytes = 0
$i = 0

Write-Host "Found $totalFiles .mp4 files. Processing..." -ForegroundColor Cyan
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

    # 2. Check for existing output (deleted first if overwriting, so FFmpeg doesn't ask too)
    if (Test-Path -LiteralPath $outputFile) {
        $displayName = [IO.Path]::Combine((Split-Path $destPath -Leaf), $relativePath, $file.Name)
        if (-not (Confirm-Overwrite $displayName)) {
            Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
            Write-Host " [SKIPPED]" -ForegroundColor DarkGray
            $skipped++
            continue
        }
        Remove-Item -LiteralPath $outputFile -Force
    }

    # 3. Capture Input Size
    $inputSize = $file.Length

    # 4. Run FFmpeg (its own messages are kept quiet unless it fails)
    $ffOutput = & $script:ffmpegExe -i $file.FullName -map_metadata -1 -c copy $outputFile 2>&1
    $ok = ($LASTEXITCODE -eq 0)

    # 5. Per-file difference
    Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
    if ($ok -and (Test-Path -LiteralPath $outputFile)) {
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

# --- SUMMARY ---
Write-Summary -Title "SUMMARY" -Total $totalFiles -Skipped $skipped -Failed $failed `
    -InputBytes $inputBytes -OutputBytes $outputBytes

Pause