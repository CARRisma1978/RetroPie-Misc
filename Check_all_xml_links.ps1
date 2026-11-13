<#
    .NOTES
    Checks every gamelist.xml in a folder (and all its subfolders) for links to
    files that don't exist, and for media files that no gamelist links to.
    The check is case-sensitive, like the Pi: "./images/Game.png" doesn't count as
    found if the file on disk is "game.png", or the folder is "Images".
    Configuration: set the folder and report file below - relative to where the
    script is run, or full paths (e.g. "C:\Users\email\OneDrive\Desktop\roms").

    Checks these tags: <path> <image> <marquee> <video> <thumbnail>
      - FOUND        the file exists with exactly the same upper/lower case
      - WRONG CASE   the file exists, but the case is different (won't load on the Pi)
      - MISSING      the file doesn't exist at all
      - PI PATH      full Pi paths (starting / or ~) can't be checked on Windows,
                     so they're listed separately
    Orphaned files:
      - Files in the media folders (image / marquee / video / thumbnail folders) that
        no gamelist.xml links to. ROM folders aren't checked for orphans.
    Also:
      - One line per gamelist.xml, a summary at the end, and the full details in the
        report file (overwritten each run)
#>

# --- CONFIGURATION ---
$baseDirName = "roms"                       # folder to search for gamelist.xml files
$reportFile  = "xml_links_report.txt"       # report file to create
# ---------------------

# Tags that link to files (case-sensitive, as in gamelist.xml)
[string[]]$pathTags = @("path", "image", "marquee", "video", "thumbnail")
[string[]]$mediaTags = @("image", "marquee", "video", "thumbnail")

# Files that Windows / macOS create themselves - never counted as orphans
[string[]]$ignoreFiles = @("gamelist.xml", "Thumbs.db", "desktop.ini", ".DS_Store")

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
# Walks the link one folder at a time from $startDir, checking the exact case of
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

# Key used to match links against files on disk for the orphan check: the folder
# ignoring case (Windows), the file name with its exact case (Pi)
function Get-RefKey([string]$fullPath) {
    $dir = [IO.Path]::GetDirectoryName($fullPath)
    if (-not $dir) { $dir = "" }
    return $dir.ToLowerInvariant() + "|" + [IO.Path]::GetFileName($fullPath)
}

# --- FOLDERS ---
$basePath = Resolve-Folder $baseDirName
$reportPath = Resolve-Folder $reportFile

Write-Host "`n================ CHECKING GAMELIST LINKS ================" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $basePath -PathType Container)) {
    Write-Host "Error: Folder '$baseDirName' not found." -ForegroundColor Red
    Pause
    Exit
}

# -LiteralPath so folder names containing [ ] work
$xmlFiles = @(Get-ChildItem -LiteralPath $basePath -Recurse -File -Filter "gamelist.xml" |
              Where-Object { $_.Name -eq "gamelist.xml" } | Sort-Object FullName)
$totalXmls = $xmlFiles.Count

if ($totalXmls -eq 0) {
    Write-Host "No gamelist.xml files found in '$basePath'." -ForegroundColor Yellow
    Pause
    Exit
}

Write-Host "Found $totalXmls gamelist.xml files. Checking..." -ForegroundColor Cyan
Write-Host "------------------------------------------------"

$foundCount = 0
$problems = New-Object System.Collections.Generic.List[object]      # wrong case / missing / Pi path
$failedParses = New-Object System.Collections.Generic.List[object]
$referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$mediaDirs = @{}                                                     # folder (any case) -> folder
$i = 0

foreach ($xmlFile in $xmlFiles) {
    $i++
    $xmlDir = $xmlFile.DirectoryName
    $relXml = $xmlFile.FullName.Substring($basePath.Length).TrimStart('\', '/')
    Write-Host "[$i/$totalXmls] $relXml" -NoNewline

    try {
        $xmlText = [IO.File]::ReadAllText($xmlFile.FullName, [Text.Encoding]::UTF8)
        # Fix unescaped ampersands (e.g. "Tom & Jerry") so the XML can be read
        $xmlText = [regex]::Replace($xmlText, '&(?!(?:[a-zA-Z][a-zA-Z0-9]*|#[0-9]+|#x[0-9a-fA-F]+);)', '&amp;')
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($xmlText)
    } catch {
        $failedParses.Add([pscustomobject]@{ Xml = $xmlFile.FullName; Error = $_.Exception.Message })
        Write-Host " [COULDN'T READ XML]" -ForegroundColor Red
        continue
    }

    $xmlFound = 0; $xmlWrong = 0; $xmlMissing = 0; $xmlPi = 0

    foreach ($elem in $doc.SelectNodes("//*")) {
        if ($pathTags -cnotcontains $elem.LocalName) { continue }
        $value = $elem.InnerText.Trim()
        if (-not $value) { continue }

        # Full Pi paths can't be checked on Windows
        if ($value -match '^[/~]') {
            $problems.Add([pscustomobject]@{ Xml = $xmlFile.FullName; Tag = $elem.LocalName; Value = $value
                                             Status = "PiPath"; Expected = $null; DiskPath = $null })
            $xmlPi++
            continue
        }

        try {
            if ($value -match '^[A-Za-z]:[\\/]') {
                $startDir = $value.Substring(0, 3)
                $rest = $value.Substring(3)
                $expected = [IO.Path]::GetFullPath($value)
            } else {
                $startDir = $xmlDir
                $rest = $value
                $expected = [IO.Path]::GetFullPath([IO.Path]::Combine($xmlDir, $value))
            }
        } catch {
            # Characters Windows doesn't allow in a path
            $problems.Add([pscustomobject]@{ Xml = $xmlFile.FullName; Tag = $elem.LocalName; Value = $value
                                             Status = "Missing"; Expected = "(not a valid Windows path)"; DiskPath = $null })
            $xmlMissing++
            continue
        }

        [void]$referenced.Add((Get-RefKey $expected))
        if ($mediaTags -ccontains $elem.LocalName) {
            $parentDir = [IO.Path]::GetDirectoryName($expected)
            if ($parentDir -and -not $mediaDirs.ContainsKey($parentDir)) { $mediaDirs[$parentDir] = $parentDir }
        }

        $check = Test-LinkedPath $startDir $rest
        switch ($check.Status) {
            "Found" { $foundCount++; $xmlFound++ }
            default {
                $problems.Add([pscustomobject]@{ Xml = $xmlFile.FullName; Tag = $elem.LocalName; Value = $value
                                                 Status = $check.Status; Expected = $expected; DiskPath = $check.DiskPath })
                if ($check.Status -eq "WrongCase") { $xmlWrong++ } else { $xmlMissing++ }
            }
        }
    }

    # Per-file line
    Write-Host " ($xmlFound found)" -NoNewline
    if ($xmlWrong -gt 0)   { Write-Host " [$xmlWrong WRONG CASE]" -ForegroundColor Yellow -NoNewline }
    if ($xmlMissing -gt 0) { Write-Host " [$xmlMissing MISSING]" -ForegroundColor Red -NoNewline }
    if ($xmlPi -gt 0)      { Write-Host " [$xmlPi PI PATHS]" -ForegroundColor DarkYellow -NoNewline }
    if (($xmlWrong + $xmlMissing + $xmlPi) -eq 0) { Write-Host " [OK]" -ForegroundColor Green -NoNewline }
    Write-Host ""
}

# --- ORPHANED FILES ---
Write-Host "`nChecking media folders for orphaned files..." -ForegroundColor Cyan
$orphans = New-Object System.Collections.Generic.List[string]
foreach ($dir in $mediaDirs.Values) {
    if (-not [IO.Directory]::Exists($dir)) { continue }
    foreach ($file in [IO.Directory]::GetFiles($dir)) {
        $name = [IO.Path]::GetFileName($file)
        if ($ignoreFiles -contains $name) { continue }
        if (-not $referenced.Contains((Get-RefKey $file))) { $orphans.Add($file) }
    }
}
$orphans.Sort()

$wrongList   = @($problems | Where-Object { $_.Status -eq "WrongCase" })
$missingList = @($problems | Where-Object { $_.Status -eq "Missing" })
$piList      = @($problems | Where-Object { $_.Status -eq "PiPath" })

# --- REPORT FILE ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("Gamelist Links Report for:")
[void]$sb.AppendLine($basePath)
[void]$sb.AppendLine("Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$sb.AppendLine("=" * 80)
[void]$sb.AppendLine("")

function Add-Group($title, $explanation, $items, [scriptblock]$detail) {
    if ($items.Count -eq 0) { return }
    [void]$sb.AppendLine("--- $title ($($items.Count)) ---")
    [void]$sb.AppendLine($explanation)
    [void]$sb.AppendLine("")
    foreach ($group in ($items | Group-Object Xml)) {
        [void]$sb.AppendLine("[$($group.Name)]")
        foreach ($item in $group.Group) {
            [void]$sb.AppendLine(" - <$($item.Tag)>: $($item.Value)")
            $extra = & $detail $item
            if ($extra) { [void]$sb.AppendLine("   $extra") }
        }
        [void]$sb.AppendLine("")
    }
}

if ($failedParses.Count -gt 0) {
    [void]$sb.AppendLine("--- COULDN'T READ ($($failedParses.Count)) ---")
    foreach ($f in $failedParses) {
        [void]$sb.AppendLine(" - $($f.Xml)")
        [void]$sb.AppendLine("   Error: $($f.Error)")
    }
    [void]$sb.AppendLine("")
}
Add-Group "WRONG CASE" "These files exist, but the upper/lower case doesn't match the gamelist, so they won't load on the Pi." `
    $wrongList { param($it) "On disk: $($it.DiskPath)" }
Add-Group "MISSING FILES" "These files are in your gamelists but are missing from your drive." `
    $missingList { param($it) "Expected at: $($it.Expected)" }
Add-Group "PI PATHS - NOT CHECKED" "Full Pi paths can't be checked on Windows. Relative paths (./...) can." `
    $piList { param($it) $null }
if ($orphans.Count -gt 0) {
    [void]$sb.AppendLine("--- ORPHANED FILES ($($orphans.Count)) ---")
    [void]$sb.AppendLine("These files are in your media folders but NO gamelist links to them.")
    [void]$sb.AppendLine("")
    foreach ($o in $orphans) { [void]$sb.AppendLine(" - $o") }
    [void]$sb.AppendLine("")
}
if (($failedParses.Count + $problems.Count + $orphans.Count) -eq 0) {
    [void]$sb.AppendLine("No problems found - every link was found and there are no orphaned files.")
}

$reportSaved = $true
try {
    [IO.File]::WriteAllText($reportPath, $sb.ToString().Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
} catch {
    $reportSaved = $false
    Write-Host "Error: Couldn't save the report - $($_.Exception.Message)" -ForegroundColor Red
}

# --- SUMMARY ---
$title = "SUMMARY"
Write-Host "`n================ $title ================" -ForegroundColor Cyan
Write-Host "Gamelists Checked: $($totalXmls - $failedParses.Count)"
if ($failedParses.Count -gt 0) { Write-Host "Couldn't Read:     $($failedParses.Count)" -ForegroundColor Red }
Write-Host "Links Found:       $foundCount"
if ($wrongList.Count -gt 0)   { Write-Host "Wrong Case:        $($wrongList.Count)" -ForegroundColor Yellow } else { Write-Host "Wrong Case:        0" }
if ($missingList.Count -gt 0) { Write-Host "Missing:           $($missingList.Count)" -ForegroundColor Red } else { Write-Host "Missing:           0" }
if ($piList.Count -gt 0)      { Write-Host "Pi Paths:          $($piList.Count) (not checked)" -ForegroundColor DarkYellow }
if ($orphans.Count -gt 0)     { Write-Host "Orphaned Files:    $($orphans.Count)" -ForegroundColor Yellow } else { Write-Host "Orphaned Files:    0" }
if ($reportSaved) { Write-Host "Full details in: $reportPath" }
Write-Host ("=" * (34 + $title.Length))

Pause
