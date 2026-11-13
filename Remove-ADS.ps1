# Remove-ADS.ps1
# Removes ALL alternate data streams (Zone.Identifier, shield, SmartScreen,
# com.dropbox.attrs, AFP_*, etc.) from every file and folder in the folder
# this script is in, and all its subfolders.
# The actual file contents (the :$DATA stream) are never touched.
# Read-only flags and "Date modified" timestamps are preserved.
#
# To run: right-click this file > "Run with PowerShell".
# (Double-clicking a .ps1 opens it in Notepad - that's a Windows default.)

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

# Summary counters
$filesScanned   = 0
$foldersScanned = 0
$itemsChanged   = 0
$streamsRemoved = 0
$streamsFailed  = 0
$bytesRemoved   = [int64]0

function Format-Size([int64]$bytes) {
    if ($bytes -ge 1MB) { return "{0:N0} bytes ({1:N2} MB)" -f $bytes, ($bytes / 1MB) }
    return "{0:N0} bytes ({1:N2} KB)" -f $bytes, ($bytes / 1KB)
}

function Show-Summary {
    Write-Host ""
    Write-Host "================ Summary ================" -ForegroundColor Cyan
    Write-Host ("Files scanned         : {0:N0}" -f $script:filesScanned)
    Write-Host ("Folders scanned       : {0:N0}" -f $script:foldersScanned)
    Write-Host ("Files/folders changed : {0:N0}" -f $script:itemsChanged)
    Write-Host ("Streams removed       : {0:N0}" -f $script:streamsRemoved)
    if ($script:streamsFailed -gt 0) {
        Write-Host ("Streams failed        : {0:N0}" -f $script:streamsFailed) -ForegroundColor Red
    }
    Write-Host ("Data removed          : {0}" -f (Format-Size $script:bytesRemoved))
    Write-Host "=========================================" -ForegroundColor Cyan
}

function Exit-Script([int]$code = 0) {
    Show-Summary
    Write-Host ""
    Read-Host "Press Enter to close" | Out-Null
    exit $code
}

function Get-RelPath([string]$full) {
    $rel = $full.Substring($root.Length).TrimStart('\')
    if ($rel -eq '') { return '.' }
    return $rel
}

Write-Host "Scanning: $root" -ForegroundColor Cyan
Write-Host ""

$items = @(Get-Item -LiteralPath $root -Force) +
         @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue)

$filesScanned   = @($items | Where-Object { -not $_.PSIsContainer }).Count
$foldersScanned = @($items | Where-Object { $_.PSIsContainer }).Count

$found = @(
    foreach ($item in $items) {
        $streams = Get-Item -LiteralPath $item.FullName -Stream * -ErrorAction SilentlyContinue
        foreach ($s in $streams) {
            if ($s.Stream -ne ':$DATA') {
                [pscustomobject]@{
                    Path   = $item.FullName
                    File   = Get-RelPath $item.FullName
                    Stream = $s.Stream
                    Bytes  = [int64]$s.Length
                }
            }
        }
    }
)

if ($found.Count -eq 0) {
    Write-Host "No alternate data streams found. Nothing to do." -ForegroundColor Green
    Exit-Script 0
}

# ---- Preview ----
Write-Host "Streams found:" -ForegroundColor Yellow
$found | Sort-Object File, Stream | Format-Table File, Stream, Bytes -AutoSize | Out-Host

Write-Host "Summary by stream name:" -ForegroundColor Yellow
$found | Group-Object Stream | Sort-Object Count -Descending |
    Format-Table @{n='Stream';e={$_.Name}},
                 @{n='Count';e={$_.Count}},
                 @{n='Bytes';e={($_.Group | Measure-Object Bytes -Sum).Sum}} -AutoSize | Out-Host

$fileCount  = ($found | Select-Object -ExpandProperty Path -Unique).Count
$totalBytes = [int64](($found | Measure-Object Bytes -Sum).Sum)
$answer = Read-Host "Remove $($found.Count) stream(s), $(Format-Size $totalBytes), from $fileCount item(s)? (Y/N)"
if ($answer -notmatch '^[Yy]') {
    Write-Host "Cancelled. Nothing was changed."
    Exit-Script 0
}

# ---- Remove ----
foreach ($group in ($found | Group-Object Path)) {
    $path = $group.Name
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    } catch {
        Write-Warning "Cannot access: $(Get-RelPath $path)"
        $streamsFailed += $group.Count
        continue
    }

    $isFile      = -not $item.PSIsContainer
    $wasReadOnly = $isFile -and $item.IsReadOnly
    $lastWrite   = $item.LastWriteTime
    $changed     = $false

    try {
        if ($wasReadOnly) { $item.IsReadOnly = $false }

        foreach ($s in $group.Group) {
            try {
                Remove-Item -LiteralPath $path -Stream $s.Stream -Force -ErrorAction Stop
                $streamsRemoved++
                $bytesRemoved += $s.Bytes
                $changed = $true
            } catch {
                $streamsFailed++
                Write-Warning "Failed: $($s.File) [$($s.Stream)] - $($_.Exception.Message)"
            }
        }
    } finally {
        try { $item.LastWriteTime = $lastWrite } catch { }
        if ($wasReadOnly) { try { $item.IsReadOnly = $true } catch { } }
    }

    if ($changed) { $itemsChanged++ }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Exit-Script 0