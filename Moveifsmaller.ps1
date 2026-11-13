<#
    .NOTES
    Compares two folders (A and B). Where a file in B is smaller than the file with
    the same name in A, the B file is moved over the A file (replacing it).
    Files in B with no matching file in A, or that aren't smaller, are left alone.
    Configuration: set the two folder names below - relative to where the script
    is run, or full paths (e.g. "C:\Users\email\OneDrive\Desktop\A").

    Steps:
      1. Lists every file that would be replaced, with its size saving
      2. Asks once before moving anything (Y / N)
      3. Moves the smaller files and shows a summary
    Also:
      - Top-level files only, like movebat.bat - set $includeSubfolders to $true
        to also match files in subfolders (same subfolder path in A and B)
      - File names containing [ ] work
      - Reports per-file AND total size differences
#>

# --- CONFIGURATION ---
$folderAName = "C:\Users\email\OneDrive\Desktop\A"    # folder with the files to be replaced
$folderBName = "C:\Users\email\OneDrive\Desktop\B"    # folder with the (possibly smaller) new files
$includeSubfolders = $false                           # $true = also match files in subfolders
# ---------------------

# Get the script's current location to ensure paths are relative to where the script is run
$rootLocation = Get-Location

# A folder setting as a full path (relative names are taken from where the script is run)
function Resolve-Folder([string]$name) {
    if ([IO.Path]::IsPathRooted($name)) { $p = $name } else { $p = Join-Path $rootLocation $name }
    return [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
}

# --- SUMMARY BOX ---
function Write-Summary {
    param([string]$Title, [int]$Total, [int]$Moved, [int]$Failed, [double]$InputBytes, [double]$OutputBytes)

    $totalDiffBytes = $InputBytes - $OutputBytes
    $totalInputMB = [math]::Round($InputBytes / 1MB, 2)
    $totalOutputMB = [math]::Round($OutputBytes / 1MB, 2)
    $totalDiffMB = [math]::Round($totalDiffBytes / 1MB, 2)

    Write-Host "`n================ $Title ================" -ForegroundColor Cyan
    Write-Host "Files in B:  $Total"
    Write-Host "Moved:       $Moved"
    if ($Failed -gt 0) {
        Write-Host "Failed:      $Failed" -ForegroundColor Red
    } else {
        Write-Host "Failed:      0"
    }
    Write-Host "Original Size: $totalInputMB MB"
    Write-Host "New Size:      $totalOutputMB MB"
    if ($totalDiffBytes -gt 0) {
        Write-Host "TOTAL SAVED:   $totalDiffMB MB" -ForegroundColor Green
    } else {
        Write-Host "TOTAL CHANGE:  0 MB" -ForegroundColor Gray
    }
    Write-Host ("=" * (34 + $Title.Length))
}

# --- FOLDERS ---
$folderA = Resolve-Folder $folderAName
$folderB = Resolve-Folder $folderBName

Write-Host "`n================ MOVING SMALLER FILES ================" -ForegroundColor Cyan

foreach ($f in @(@($folderA, $folderAName), @($folderB, $folderBName))) {
    if (-not (Test-Path -LiteralPath $f[0] -PathType Container)) {
        Write-Host "Error: Folder '$($f[1])' not found." -ForegroundColor Red
        Pause
        Exit
    }
}
if ($folderA -eq $folderB) {
    Write-Host "Error: Folder A and folder B can't be the same folder." -ForegroundColor Red
    Pause
    Exit
}

# --- STEP 1: FIND THE SMALLER FILES ---
# -LiteralPath so folder/file names containing [ ] work
if ($includeSubfolders) {
    $filesB = @(Get-ChildItem -LiteralPath $folderB -File -Recurse | Sort-Object FullName)
} else {
    $filesB = @(Get-ChildItem -LiteralPath $folderB -File | Sort-Object FullName)
}
$totalFiles = $filesB.Count
$toMove = New-Object System.Collections.Generic.List[object]

foreach ($fileB in $filesB) {
    $relative = $fileB.FullName.Substring($folderB.Length).TrimStart('\', '/')
    $pathA = Join-Path $folderA $relative
    if (-not (Test-Path -LiteralPath $pathA -PathType Leaf)) { continue }
    $fileA = Get-Item -LiteralPath $pathA
    if ($fileB.Length -lt $fileA.Length) {
        $toMove.Add([pscustomobject]@{ Relative = $relative; FileB = $fileB; PathA = $pathA; SizeA = $fileA.Length; SizeB = $fileB.Length })
    }
}

Write-Host "Found $totalFiles files in B. $($toMove.Count) are smaller than the file in A." -ForegroundColor Cyan

if ($toMove.Count -eq 0) {
    Write-Host "Nothing to move." -ForegroundColor Green
    Pause
    Exit
}

Write-Host "------------------------------------------------"
$i = 0
foreach ($item in $toMove) {
    $i++
    $sizeAKB = [math]::Round($item.SizeA / 1KB, 1)
    $sizeBKB = [math]::Round($item.SizeB / 1KB, 1)
    $diffKB = [math]::Round(($item.SizeA - $item.SizeB) / 1KB, 1)
    Write-Host "[$i/$($toMove.Count)] $($item.Relative)" -NoNewline
    Write-Host " [SAVES $diffKB KB]" -ForegroundColor Green -NoNewline
    Write-Host " ($sizeAKB -> $sizeBKB KB)"
}
Write-Host "------------------------------------------------"

# --- STEP 2: ASK BEFORE MOVING ---
$ans = ""
while ($ans -ne 'Y' -and $ans -ne 'N') {
    $ans = (Read-Host "Move these $($toMove.Count) files from B over the files in A? [Y]es / [N]o").Trim().ToUpper()
}
if ($ans -eq 'N') {
    Write-Host "Cancelled. Nothing was changed." -ForegroundColor DarkGray
    Pause
    Exit
}

# --- STEP 3: MOVE ---
Write-Host ""
$moved = 0
$failed = 0
$inputBytes = 0
$outputBytes = 0
$i = 0
foreach ($item in $toMove) {
    $i++
    Write-Host "[$i/$($toMove.Count)] $($item.Relative)" -NoNewline
    try {
        Move-Item -LiteralPath $item.FileB.FullName -Destination $item.PathA -Force -ErrorAction Stop
        $moved++
        $inputBytes += $item.SizeA
        $outputBytes += $item.SizeB
        Write-Host " [MOVED]" -ForegroundColor Green
    } catch {
        $failed++
        Write-Host " [FAILED]" -ForegroundColor Red
        Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# --- SUMMARY ---
Write-Summary -Title "SUMMARY" -Total $totalFiles -Moved $moved -Failed $failed `
    -InputBytes $inputBytes -OutputBytes $outputBytes

Pause
