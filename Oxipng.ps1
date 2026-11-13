<#
    .NOTES
    Optimises PNG covers, then marquees, with oxipng. oxipng.exe is used from the
    script's own folder, then the folder the script is run from, then the PATH.
    Lossless: the pictures look exactly the same, the files just get smaller.
    Configuration: set the four folder names below - relative to where the script
    is run, or full paths (e.g. "C:\Users\email\OneDrive\Desktop\C2").

    Both sets use the same oxipng options:
      --opt max     slowest, smallest files
      --strip safe  removes metadata that doesn't affect how the image looks
      --alpha       optimises fully transparent pixels (invisible, so no visible change)
    Also:
      - PNG only (oxipng doesn't handle other formats)
      - Keeps the subfolder structure
      - Reports per-file AND total size differences
      - Prompts before overwriting existing output files (Yes / No / All / Skip all),
        asked afresh for marquees
      - A summary for covers, one for marquees, then one for both combined
#>

# --- CONFIGURATION ---
$coverSourceDirName   = "C2"    # folder containing the covers to optimise
$coverOutputDirName   = "C3"    # folder to create for the optimised covers
$marqueeSourceDirName = "M2"    # folder containing the marquees to optimise
$marqueeOutputDirName = "M3"    # folder to create for the optimised marquees
# ---------------------

# oxipng options (the output file is added per image)
$oxipngArgs = @("--opt", "max", "--strip", "safe", "--alpha")

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
    if ([IO.Path]::IsPathRooted($name)) { return $name }
    return (Join-Path $rootLocation $name)
}

# --- PROCESS ONE SET (covers or marquees) ---
# Returns the totals for the summaries. Missing source folder: a warning, and
# that set is skipped (the other still runs).
function Invoke-PngSet {
    param(
        [string]$Label,             # "COVERS" / "MARQUEES"
        [string]$SourceDirName,
        [string]$OutputDirName
    )

    $result = [pscustomobject]@{
        Label = $Label; Found = $false; Total = 0; Skipped = 0
        InputBytes = 0; OutputBytes = 0
    }

    # Overwrite answers start afresh for each set
    $script:overwriteAll = $false
    $script:skipAll = $false

    $sourcePath = Resolve-Folder $SourceDirName
    $destPath = Resolve-Folder $OutputDirName

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

    $files = @(Get-ChildItem -Path $sourcePath -Recurse -File -Include "*.png")
    $totalFiles = $files.Count
    $result.Total = $totalFiles
    $i = 0

    Write-Host "Found $totalFiles files. Processing (this can take a while)..." -ForegroundColor Cyan
    Write-Host "------------------------------------------------"

    foreach ($file in $files) {
        $i++

        # 1. Subfolder structure: the file's folder relative to the source folder
        $relativePath = $file.DirectoryName.Replace($sourcePath, "")
        $targetDir = Join-Path $destPath $relativePath
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir | Out-Null
        }
        $outputFile = Join-Path $targetDir $file.Name

        # 2. Check for existing output
        if (Test-Path $outputFile) {
            $displayName = [IO.Path]::Combine($OutputDirName, $relativePath.TrimStart('\', '/'), $file.Name)
            if (-not (Confirm-Overwrite $displayName)) {
                Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
                Write-Host " [SKIPPED]" -ForegroundColor DarkGray
                $result.Skipped++
                continue
            }
            Remove-Item -LiteralPath $outputFile -Force
        }

        # 3. Capture Input Size
        $inputSize = $file.Length
        $result.InputBytes += $inputSize

        # 4. Run oxipng (its own messages are kept quiet unless it fails)
        $oxiOutput = & $script:oxipngExe @oxipngArgs --out $outputFile $file.FullName 2>&1
        $ok = ($LASTEXITCODE -eq 0)

        # oxipng may not write a file it couldn't make any smaller: then the
        # output is a straight copy of the original
        if ($ok -and -not (Test-Path $outputFile)) {
            Copy-Item -LiteralPath $file.FullName -Destination $outputFile
        }

        # 5. Per-file difference
        Write-Host "[$i/$totalFiles] $($file.Name)" -NoNewline
        if ($ok -and (Test-Path $outputFile)) {
            $outputSize = (Get-Item $outputFile).Length
            $result.OutputBytes += $outputSize

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
            # No output: its original size isn't counted in the totals either
            $result.InputBytes -= $inputSize
            Write-Host " [FAILED]" -ForegroundColor Red
            $oxiOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
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

# --- CHECK OXIPNG ---
# oxipng.exe next to this script, or in the folder it's run from, or on the PATH
$script:oxipngExe = $null
foreach ($dir in @($PSScriptRoot, $rootLocation.Path)) {
    if (-not $dir) { continue }
    foreach ($name in @("oxipng.exe", "oxipng")) {
        $candidate = Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:oxipngExe = $candidate; break }
    }
    if ($script:oxipngExe) { break }
}
if (-not $script:oxipngExe) {
    $cmd = Get-Command oxipng -ErrorAction SilentlyContinue
    if ($cmd) { $script:oxipngExe = $cmd.Source }
}
if (-not $script:oxipngExe) {
    Write-Host "Error: oxipng.exe not found - put it in the same folder as this script" -ForegroundColor Red
    Write-Host "       ($PSScriptRoot), or install it on the PATH." -ForegroundColor Red
    Pause
    Exit
}
Write-Host "Using oxipng: $script:oxipngExe" -ForegroundColor DarkGray

# --- RUN: covers, then marquees ---
$covers = Invoke-PngSet -Label "COVERS" `
    -SourceDirName $coverSourceDirName -OutputDirName $coverOutputDirName
$marquees = Invoke-PngSet -Label "MARQUEES" `
    -SourceDirName $marqueeSourceDirName -OutputDirName $marqueeOutputDirName

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
