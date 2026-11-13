<#
    .NOTES
    Checks every .m3u playlist in a folder (and all its subfolders) for disc files
    that don't exist.
    The check is case-sensitive, like the Pi: "Game (Disc 1).chd" doesn't count as
    found if the file on disk is "Game (disc 1).chd".
    Configuration: set the folder and report file below - relative to where the
    script is run, or full paths (e.g. "C:\Users\email\OneDrive\Desktop\roms").

    Each line of each playlist (blank lines and # comments are ignored):
      - FOUND        the file exists with exactly the same upper/lower case
      - WRONG CASE   the file exists, but the case is different (won't load on the Pi)
      - MISSING      the file doesn't exist at all
      - PI PATH      full Pi paths (starting / or ~) can't be checked on Windows,
                     so they're listed separately
    Also:
      - Playlists saved as UTF-8 or ANSI (Windows) are both read correctly
      - One line per playlist, a summary at the end, and the full details in the
        report file (overwritten each run; deleted if there's nothing to report)
#>

# --- CONFIGURATION ---
$searchDirName = "roms"                 # folder to search for .m3u files
$reportFile    = "m3u_report.txt"       # report file to create
# ---------------------

# Get the script's current location to ensure paths are relative to where the script is run
$rootLocation = Get-Location

# A folder/file setting as a full path (relative names are taken from where the script is run)
function Resolve-Folder([string]$name) {
    if ([IO.Path]::IsPathRooted($name)) { $p = $name } else { $p = Join-Path $rootLocation $name }
    return [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
}

# --- FOLDER LISTINGS (each folder is read from disk once) ---
$script:dirCache = @{}

function Get-DirEntries([string]$dir) {
    if ($script:dirCache.ContainsKey($dir)) { return $script:dirCache[$dir] }
    $entry = $null
    if ([IO.Directory]::Exists($dir)) {
        $exact = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $loose = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in [IO.Directory]::GetFileSystemEntries($dir)) {
            $n = [IO.Path]::GetFileName($p)
            [void]$exact.Add($n)
            if (-not $loose.ContainsKey($n)) { $loose[$n] = $n }
        }
        $entry = [pscustomobject]@{ Exact = $exact; Loose = $loose }
    }
    $script:dirCache[$dir] = $entry
    return $entry
}

# --- CASE-SENSITIVE CHECK ---
# Walks the path one folder at a time from $startDir, checking the exact case of
# every folder name and the file name. Returns Found / WrongCase / Missing.
function Test-LinkedPath([string]$startDir, [string]$value) {
    $diskPath = $startDir
    $wrongCase = $false
    foreach ($part in ($value -split '[\\/]')) {
        if ($part -eq '' -or $part -eq '.') { continue }
        if ($part -eq '..') {
            $diskPath = [IO.Path]::GetDirectoryName($diskPath)
            if (-not $diskPath) { return [pscustomobject]@{ Status = "Missing"; DiskPath = $null } }
            continue
        }
        $entries = Get-DirEntries $diskPath
        if ($entries -and $entries.Exact.Contains($part)) {
            $diskPath = [IO.Path]::Combine($diskPath, $part)
        } elseif ($entries -and $entries.Loose.ContainsKey($part)) {
            $wrongCase = $true
            $diskPath = [IO.Path]::Combine($diskPath, $entries.Loose[$part])
        } else {
            return [pscustomobject]@{ Status = "Missing"; DiskPath = $null }
        }
    }
    if ($wrongCase) { return [pscustomobject]@{ Status = "WrongCase"; DiskPath = $diskPath } }
    return [pscustomobject]@{ Status = "Found"; DiskPath = $diskPath }
}

# Reads a text file as UTF-8, or as ANSI (Windows-1252) if it isn't valid UTF-8
function Read-TextFile([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)   # throws on invalid UTF-8
        $text = $utf8.GetString($bytes)
    } catch {
        try { $ansi = [Text.Encoding]::GetEncoding(1252) } catch { $ansi = [Text.Encoding]::GetEncoding(28591) }
        $text = $ansi.GetString($bytes)
    }
    return $text.TrimStart([char]0xFEFF)
}

# --- FOLDERS ---
$searchPath = Resolve-Folder $searchDirName
$reportPath = Resolve-Folder $reportFile

Write-Host "`n================ CHECKING M3U PLAYLISTS ================" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $searchPath -PathType Container)) {
    Write-Host "Error: Folder '$searchDirName' not found." -ForegroundColor Red
    Pause
    Exit
}

# -LiteralPath so folder/file names containing [ ] work
$m3uFiles = @(Get-ChildItem -LiteralPath $searchPath -Recurse -File -Filter "*.m3u" |
              Where-Object { $_.Extension -eq ".m3u" } | Sort-Object FullName)
$totalFiles = $m3uFiles.Count

Write-Host "Found $totalFiles .m3u files. Checking..." -ForegroundColor Cyan
Write-Host "------------------------------------------------"

$foundCount = 0
$problems = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($m3u in $m3uFiles) {
    $i++
    $relM3u = $m3u.FullName.Substring($searchPath.Length).TrimStart('\', '/')
    Write-Host "[$i/$totalFiles] $relM3u" -NoNewline

    $m3uFound = 0; $m3uWrong = 0; $m3uMissing = 0; $m3uPi = 0

    foreach ($rawLine in ((Read-TextFile $m3u.FullName) -split "`r?`n")) {
        $line = $rawLine.Trim()
        # Skip empty lines and M3U comments/metadata (which start with #)
        if (-not $line -or $line.StartsWith("#")) { continue }

        if ($line -match '^[/~]') {
            $problems.Add([pscustomobject]@{ M3u = $m3u.FullName; Line = $line; Status = "PiPath"; DiskPath = $null })
            $m3uPi++
            continue
        }

        # Relative paths are relative to the playlist's own folder
        if ($line -match '^[A-Za-z]:[\\/]') {
            $check = Test-LinkedPath $line.Substring(0, 3) $line.Substring(3)
        } else {
            $check = Test-LinkedPath $m3u.DirectoryName $line
        }

        if ($check.Status -eq "Found") {
            $foundCount++; $m3uFound++
        } else {
            $problems.Add([pscustomobject]@{ M3u = $m3u.FullName; Line = $line; Status = $check.Status; DiskPath = $check.DiskPath })
            if ($check.Status -eq "WrongCase") { $m3uWrong++ } else { $m3uMissing++ }
        }
    }

    # Per-file line
    Write-Host " ($m3uFound found)" -NoNewline
    if ($m3uWrong -gt 0)   { Write-Host " [$m3uWrong WRONG CASE]" -ForegroundColor Yellow -NoNewline }
    if ($m3uMissing -gt 0) { Write-Host " [$m3uMissing MISSING]" -ForegroundColor Red -NoNewline }
    if ($m3uPi -gt 0)      { Write-Host " [$m3uPi PI PATHS]" -ForegroundColor DarkYellow -NoNewline }
    if (($m3uWrong + $m3uMissing + $m3uPi) -eq 0) { Write-Host " [OK]" -ForegroundColor Green -NoNewline }
    Write-Host ""
}

$wrongList   = @($problems | Where-Object { $_.Status -eq "WrongCase" })
$missingList = @($problems | Where-Object { $_.Status -eq "Missing" })
$piList      = @($problems | Where-Object { $_.Status -eq "PiPath" })

# --- REPORT FILE (only kept if there's something to report) ---
$reportSaved = $false
if ($problems.Count -gt 0) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("M3U Playlists Report for:")
    [void]$sb.AppendLine($searchPath)
    [void]$sb.AppendLine("Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$sb.AppendLine("=" * 60)
    [void]$sb.AppendLine("")
    foreach ($group in ($problems | Group-Object M3u)) {
        [void]$sb.AppendLine("Playlist: $($group.Name)")
        foreach ($p in $group.Group) {
            switch ($p.Status) {
                "WrongCase" { [void]$sb.AppendLine("  [WRONG CASE] -> $($p.Line)")
                              [void]$sb.AppendLine("                  on disk: $($p.DiskPath)") }
                "Missing"   { [void]$sb.AppendLine("  [MISSING]    -> $($p.Line)") }
                "PiPath"    { [void]$sb.AppendLine("  [PI PATH]    -> $($p.Line) (not checked)") }
            }
        }
        [void]$sb.AppendLine("")
    }
    try {
        [IO.File]::WriteAllText($reportPath, $sb.ToString().Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
        $reportSaved = $true
    } catch {
        Write-Host "Error: Couldn't save the report - $($_.Exception.Message)" -ForegroundColor Red
    }
} elseif (Test-Path -LiteralPath $reportPath) {
    # Nothing to report: remove the old report so it isn't mistaken for this run's
    Remove-Item -LiteralPath $reportPath -Force
}

# --- SUMMARY ---
$title = "SUMMARY"
Write-Host "`n================ $title ================" -ForegroundColor Cyan
Write-Host "Playlists Checked: $totalFiles"
Write-Host "Files Found:       $foundCount"
if ($wrongList.Count -gt 0)   { Write-Host "Wrong Case:        $($wrongList.Count)" -ForegroundColor Yellow } else { Write-Host "Wrong Case:        0" }
if ($missingList.Count -gt 0) { Write-Host "Missing:           $($missingList.Count)" -ForegroundColor Red } else { Write-Host "Missing:           0" }
if ($piList.Count -gt 0)      { Write-Host "Pi Paths:          $($piList.Count) (not checked)" -ForegroundColor DarkYellow }
if ($reportSaved) {
    Write-Host "Full details in: $reportPath"
} elseif ($problems.Count -eq 0 -and $totalFiles -gt 0) {
    Write-Host "All files in all playlists exist!" -ForegroundColor Green
}
Write-Host ("=" * (34 + $title.Length))

Pause
