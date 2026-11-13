<#
    .NOTES
    Looks through every gamelist.xml in a folder (and all its subfolders) for games
    with very similar file names - e.g. different versions or discs of the same game
    that could be tidied into a subfolder.
    Configuration: set the folders below - relative to where the script is run, or
    full paths (e.g. "C:\Users\email\OneDrive\Desktop\roms").

    Two games count as similar when:
      - they're not already in a subfolder (path like "./Game.zip", not "./Sub/Game.zip"),
        unless $includeSubfolders is set to $true below - see "Including subfolders"
      - the first word of the file name is the same (ignoring upper/lower case)
      - the file names are no more than 10 characters different in length
      - the file names are at least 85% the same (same measure as Python's difflib)
      - <folder> entries are ignored, only <game> entries are compared
    Including subfolders ($includeSubfolders = $true):
      - Games in subfolders are compared too - handy for spotting a game that
        belongs in a subfolder you've already made
      - Only the file names are compared (not the folders), so
        "./Mega Man X/Mega Man X (USA).sfc" can match "./Mega Man X2 (USA).sfc"
      - Two games already in the same subfolder are skipped - they're tidied already
    Also:
      - One results file per system (e.g. results\arcade.txt), most similar first
      - A system with no similar games has its old results file removed, so the
        results folder only ever shows this run's findings
      - One line per gamelist.xml and a summary at the end
#>

# --- CONFIGURATION ---
$rootDirName    = "roms"        # folder to search for gamelist.xml files
$resultsDirName = "results"     # folder to create for the results files
$threshold      = 0.85          # how similar the names must be (0.85 = 85%)
$maxLengthDiff  = 10            # names further apart in length than this are skipped
$includeSubfolders = $false     # $true = also compare games already in subfolders
# ---------------------

# --- SIMILARITY MEASURE ---
# The same calculation as Python's difflib.SequenceMatcher(None, a, b).ratio(),
# written in C# so it's quick even with thousands of games
if (-not ("SimilarMatcher" -as [type])) {
    Add-Type -TypeDefinition @"
using System.Collections.Generic;
public static class SimilarMatcher
{
    public static double Ratio(string a, string b)
    {
        int la = a.Length, lb = b.Length;
        if (la + lb == 0) return 1.0;
        int matches = 0;
        Stack<int[]> queue = new Stack<int[]>();
        queue.Push(new int[] { 0, la, 0, lb });
        while (queue.Count > 0)
        {
            int[] q = queue.Pop();
            int alo = q[0], ahi = q[1], blo = q[2], bhi = q[3];
            int besti = alo, bestj = blo, bestsize = 0;
            int[] prev = new int[lb + 1];
            for (int i = alo; i < ahi; i++)
            {
                int[] cur = new int[lb + 1];
                for (int j = blo; j < bhi; j++)
                {
                    if (a[i] != b[j]) continue;
                    int k = (j > blo ? prev[j] : 0) + 1;
                    cur[j + 1] = k;
                    if (k > bestsize) { besti = i - k + 1; bestj = j - k + 1; bestsize = k; }
                }
                prev = cur;
            }
            if (bestsize > 0)
            {
                matches += bestsize;
                if (alo < besti && blo < bestj) queue.Push(new int[] { alo, besti, blo, bestj });
                if (besti + bestsize < ahi && bestj + bestsize < bhi)
                    queue.Push(new int[] { besti + bestsize, ahi, bestj + bestsize, bhi });
            }
        }
        return 2.0 * matches / (la + lb);
    }
}
"@
}

# Get the script's current location to ensure paths are relative to where the script is run
$rootLocation = Get-Location

# A folder setting as a full path (relative names are taken from where the script is run)
function Resolve-Folder([string]$name) {
    if ([IO.Path]::IsPathRooted($name)) { $p = $name } else { $p = Join-Path $rootLocation $name }
    return [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
}

# First word of the file name (letters, numbers and hyphens), in lower case
function Get-FirstWord([string]$path) {
    $fileName = ($path -split '[\\/]')[-1]
    $m = [regex]::Match($fileName, '[a-zA-Z0-9\-]+')
    if ($m.Success) { return $m.Value.ToLowerInvariant() }
    return ""
}

# --- FOLDERS ---
$rootPath = Resolve-Folder $rootDirName
$resultsPath = Resolve-Folder $resultsDirName

Write-Host "`n================ FINDING SIMILAR GAMES ================" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    Write-Host "Error: Folder '$rootDirName' not found." -ForegroundColor Red
    Pause
    Exit
}
if (-not (Test-Path -LiteralPath $resultsPath)) {
    [void][IO.Directory]::CreateDirectory($resultsPath)
}

# -LiteralPath so folder names containing [ ] work
$xmlFiles = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Filter "gamelist.xml" |
              Where-Object { $_.Name -eq "gamelist.xml" } | Sort-Object FullName)
$totalXmls = $xmlFiles.Count
$totalPairs = 0
$systemsWithPairs = 0
$i = 0

Write-Host "Found $totalXmls gamelist.xml files. Comparing..." -ForegroundColor Cyan
Write-Host "Results will be saved to: $resultsPath"
Write-Host "------------------------------------------------"

$thresholdPct = [math]::Round($threshold * 100, 1)

foreach ($xmlFile in $xmlFiles) {
    $i++
    # Name of the folder this gamelist.xml is in (e.g. arcade)
    $systemName = $xmlFile.Directory.Name
    $outputFile = Join-Path $resultsPath "$systemName.txt"
    Write-Host "[$i/$totalXmls] $systemName" -NoNewline

    $content = [IO.File]::ReadAllText($xmlFile.FullName, [Text.Encoding]::UTF8)

    # 1. Paths from <game> entries only (<folder> entries are ignored)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($block in [regex]::Matches($content, '(?is)<game\b[^>]*>.*?</game>')) {
        $m = [regex]::Match($block.Value, '(?is)<path>(.*?)</path>')
        if (-not $m.Success) { continue }
        $path = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value.Trim())

        # 2. Keep only games that aren't already in a subfolder (unless including subfolders)
        $rest = $path
        while ($rest.StartsWith("./") -or $rest.StartsWith(".\")) { $rest = $rest.Substring(2) }
        if ($includeSubfolders -or $rest -notmatch '[\\/]') { $paths.Add($path) }
    }

    # 3. Group by first word, then compare every pair within each group
    $groups = @{}
    foreach ($p in $paths) {
        $fw = Get-FirstWord $p
        if (-not $groups.ContainsKey($fw)) { $groups[$fw] = New-Object System.Collections.Generic.List[object] }
        # Including subfolders: compare the file names only, and note each game's folder
        $parts = $p -split '[\\/]'
        $folder = ""
        if ($parts.Count -gt 1) { $folder = (@($parts[0..($parts.Count - 2)]) | Where-Object { $_ -ne "." -and $_ -ne "" }) -join "/" }
        # (keeping a leading "./" so games not in a subfolder score the same either way)
        $compare = $p
        if ($includeSubfolders -and $folder) {
            $compare = if ($p -match '^\.[\\/]') { "./" + $parts[-1] } else { $parts[-1] }
        }
        $groups[$fw].Add([pscustomobject]@{ Path = $p; Compare = $compare; Folder = $folder })
    }

    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($group in $groups.Values) {
        $n = $group.Count
        for ($a = 0; $a -lt $n; $a++) {
            for ($b = $a + 1; $b -lt $n; $b++) {
                $g1 = $group[$a]
                $g2 = $group[$b]
                # Two games already in the same subfolder are tidied already
                if ($g1.Folder -and $g1.Folder -eq $g2.Folder) { continue }
                if ([math]::Abs($g1.Compare.Length - $g2.Compare.Length) -gt $maxLengthDiff) { continue }
                $ratio = [SimilarMatcher]::Ratio($g1.Compare, $g2.Compare)
                if ($ratio -ge $threshold) {
                    $pairs.Add([pscustomobject]@{ Ratio = $ratio; P1 = $g1.Path; P2 = $g2.Path })
                }
            }
        }
    }

    # 4. Write the results, most similar first
    if ($pairs.Count -gt 0) {
        $sorted = $pairs | Sort-Object @{ Expression = "Ratio"; Descending = $true }, P1, P2
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("--- Similar Paths Found in '$systemName' ---")
        if ($includeSubfolders) {
            [void]$sb.AppendLine("Criteria: First word matches, >= $thresholdPct% file name similarity, games in subfolders included (pairs already in the same subfolder skipped).")
        } else {
            [void]$sb.AppendLine("Criteria: First word matches, >= $thresholdPct% overall similarity, AND game is not already in a subfolder.")
        }
        [void]$sb.AppendLine("")
        foreach ($pair in $sorted) {
            [void]$sb.AppendLine(("[Match: {0:0.0}%]" -f ($pair.Ratio * 100)).Replace(",", "."))
            [void]$sb.AppendLine("  1: $($pair.P1)")
            [void]$sb.AppendLine("  2: $($pair.P2)")
            [void]$sb.AppendLine("")
        }
        [void]$sb.AppendLine("Total similar pairs found: $($pairs.Count)")
        [IO.File]::WriteAllText($outputFile, $sb.ToString().Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))

        $totalPairs += $pairs.Count
        $systemsWithPairs++
        Write-Host " [$($pairs.Count) SIMILAR PAIRS]" -ForegroundColor Yellow -NoNewline
        Write-Host " ($($paths.Count) games compared)"
    } else {
        # No similar games: remove the old results file from an earlier run
        if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile -Force }
        Write-Host " [NONE]" -ForegroundColor Green -NoNewline
        Write-Host " ($($paths.Count) games compared)"
    }
}

# --- SUMMARY ---
$title = "SUMMARY"
Write-Host "`n================ $title ================" -ForegroundColor Cyan
Write-Host "Gamelists Checked:     $totalXmls"
Write-Host "Systems With Matches:  $systemsWithPairs"
if ($totalPairs -gt 0) {
    Write-Host "Similar Pairs Found:   $totalPairs" -ForegroundColor Yellow
    Write-Host "Results are in: $resultsPath"
} else {
    Write-Host "Similar Pairs Found:   0" -ForegroundColor Green
}
Write-Host ("=" * (34 + $title.Length))

Pause
