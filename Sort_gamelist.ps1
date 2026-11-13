<#
    .NOTES
    Tidies every gamelist.xml in a folder (and all its subfolders) in one go:
      1. Sorts the games and folders by name
      2. Puts the tags inside each game / folder in a set order
    The sorted gamelists are written to a new folder, keeping the subfolder
    structure - the originals are left untouched.
    Configuration: set the two folder names below - relative to where the script
    is run, or full paths (e.g. "C:\Users\email\OneDrive\Desktop\roms").

    Sorting by name:
      - Ignores upper/lower case
      - Ignores "The ", "A " and "An " at the start (The Simpsons sorts under S)
      - Roman numerals I to XX after a space count as numbers (Final Fight II = 2)
      - Numbers sort as numbers (Game 2 before Game 10)
      - Games and folders are sorted together
    Tag order:
      path, name, image, thumbnail, marquee, video, desc, developer, publisher,
      releasedate, players, genre - then any other tags, in their original order
      (listed at the end so you can add them to the order if you want)
    Also:
      - Fixes unescaped & characters (e.g. "Tom & Jerry")
      - Keeps any comments in the gamelist
      - Saved as UTF-8 with Unix (LF) line endings, tab-indented, ready for the Pi
      - Prompts before overwriting existing output files (Yes / No / All / Skip all)
      - One line per gamelist.xml and a summary at the end
#>

# --- CONFIGURATION ---
$sourceDirName = "roms"         # folder containing your gamelist.xml files
$outputDirName = "roms_sorted"  # folder to create for the sorted gamelist.xml files
# ---------------------

# Tag order inside each <game> / <folder>
[string[]]$tagOrder = @("path", "name", "image", "thumbnail", "marquee", "video", "desc",
                        "developer", "publisher", "releasedate", "players", "genre")

# --- SORTING RULES ---
# The same sorting as Sort_games.py, written in C# so it matches exactly
if (-not ("GameSorter" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
public static class GameSorter
{
    static readonly Regex Article = new Regex(@"^(the|a|an)\s+");
    static readonly Regex Roman = new Regex(@"(?<=\s)(i|ii|iii|iv|v|vi|vii|viii|ix|x|xi|xii|xiii|xiv|xv|xvi|xvii|xviii|xix|xx)\b");
    static readonly Regex Digits = new Regex(@"(\d+)");
    static readonly string[] RomanNames = { "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
        "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx" };

    // Name -> alternating text / number parts, e.g. "street fighter 2" -> ["street fighter ", "2", ""]
    public static string[] Key(string name)
    {
        if (string.IsNullOrEmpty(name)) return new string[0];
        string s = name.ToLowerInvariant().Trim();
        s = Article.Replace(s, "", 1);
        s = Roman.Replace(s, delegate (Match m) {
            return (Array.IndexOf(RomanNames, m.Groups[1].Value) + 1).ToString();
        });
        return Digits.Split(s);
    }

    static int CompareKeys(string[] x, string[] y)
    {
        int n = Math.Min(x.Length, y.Length);
        for (int k = 0; k < n; k++)
        {
            int c;
            if (k % 2 == 1)
            {
                // Number parts: compare as numbers
                string a = x[k].TrimStart('0'), b = y[k].TrimStart('0');
                c = a.Length.CompareTo(b.Length);
                if (c == 0) c = string.CompareOrdinal(a, b);
            }
            else
            {
                c = string.CompareOrdinal(x[k], y[k]);
            }
            if (c != 0) return c;
        }
        return x.Length.CompareTo(y.Length);
    }

    // Returns the positions of the names in sorted order (equal names keep their order)
    public static int[] SortOrder(string[] names)
    {
        string[][] keys = new string[names.Length][];
        List<int> order = new List<int>();
        for (int i = 0; i < names.Length; i++) { keys[i] = Key(names[i]); order.Add(i); }
        order.Sort(delegate (int p, int q) {
            int c = CompareKeys(keys[p], keys[q]);
            return c != 0 ? c : p.CompareTo(q);
        });
        return order.ToArray();
    }
}
"@
}

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

# Saves the XML: UTF-8 (no BOM), tab-indented, Unix (LF) line endings
function Save-Gamelist([System.Xml.XmlDocument]$doc, [string]$path) {
    $decl = $doc.FirstChild
    if ($decl -is [System.Xml.XmlDeclaration]) {
        $decl.Encoding = "utf-8"
    } else {
        [void]$doc.InsertBefore($doc.CreateXmlDeclaration("1.0", "utf-8", $null), $doc.FirstChild)
    }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding $false
    $settings.Indent = $true
    $settings.IndentChars = "`t"
    $settings.NewLineChars = "`n"
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::Replace
    $settings.CloseOutput = $false
    $stream = New-Object System.IO.MemoryStream
    $writer = [System.Xml.XmlWriter]::Create($stream, $settings)
    $doc.Save($writer)
    $writer.Close()
    $stream.WriteByte(10)     # end with a line break
    [IO.File]::WriteAllBytes($path, $stream.ToArray())
}

# --- FOLDERS ---
$sourcePath = Resolve-Folder $sourceDirName
$destPath = Resolve-Folder $outputDirName

Write-Host "`n================ SORTING GAMELISTS ================" -ForegroundColor Cyan

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

# -LiteralPath so folder names containing [ ] work
$xmlFiles = @(Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter "gamelist.xml" |
              Where-Object { $_.Name -eq "gamelist.xml" } | Sort-Object FullName)
$totalXmls = $xmlFiles.Count
$skipped = 0
$failed = 0
$totalGames = 0
$totalFolders = 0
$unexpectedTags = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
$tagIndex = @{}
for ($t = 0; $t -lt $tagOrder.Count; $t++) { $tagIndex[$tagOrder[$t]] = $t }
$i = 0

Write-Host "Found $totalXmls gamelist.xml files. Processing..." -ForegroundColor Cyan
Write-Host "------------------------------------------------"

foreach ($xmlFile in $xmlFiles) {
    $i++
    $relativePath = $xmlFile.DirectoryName.Substring($sourcePath.Length).TrimStart('\', '/')
    $relXml = if ($relativePath) { [IO.Path]::Combine($relativePath, $xmlFile.Name) } else { $xmlFile.Name }
    $targetDir = if ($relativePath) { Join-Path $destPath $relativePath } else { $destPath }
    $outputFile = Join-Path $targetDir $xmlFile.Name

    # 1. Check for existing output
    if (Test-Path -LiteralPath $outputFile) {
        $displayName = [IO.Path]::Combine((Split-Path $destPath -Leaf), $relXml)
        if (-not (Confirm-Overwrite $displayName)) {
            Write-Host "[$i/$totalXmls] $relXml" -NoNewline
            Write-Host " [SKIPPED]" -ForegroundColor DarkGray
            $skipped++
            continue
        }
    }

    Write-Host "[$i/$totalXmls] $relXml" -NoNewline
    try {
        # 2. Read the XML, fixing unescaped ampersands first
        $xmlText = [IO.File]::ReadAllText($xmlFile.FullName, [Text.Encoding]::UTF8)
        $xmlText = [regex]::Replace($xmlText, '&(?!(?:[a-zA-Z][a-zA-Z0-9]*|#[0-9]+|#x[0-9a-fA-F]+);)', '&amp;')
        $doc = New-Object System.Xml.XmlDocument
        $doc.PreserveWhitespace = $false
        $doc.LoadXml($xmlText)
        $root = $doc.DocumentElement

        # 3. Sort the <game> and <folder> entries by name
        $items = @($root.ChildNodes | Where-Object { $_.NodeType -eq "Element" -and ($_.LocalName -ceq "game" -or $_.LocalName -ceq "folder") })
        $names = [string[]]@($items | ForEach-Object {
            $n = $_.SelectSingleNode("name")
            if ($n) { $n.InnerText } else { "" }
        })
        if ($items.Count -gt 0) {
            $order = [GameSorter]::SortOrder($names)
            foreach ($item in $items) { [void]$root.RemoveChild($item) }
            foreach ($idx in $order) { [void]$root.AppendChild($items[$idx]) }
        }
        $games = @($items | Where-Object { $_.LocalName -ceq "game" }).Count
        $folders = $items.Count - $games

        # 4. Put the tags inside each <game> / <folder> in order
        foreach ($entry in @($root.SelectNodes("//game | //folder"))) {
            $children = @($entry.ChildNodes)
            $known = New-Object System.Collections.Generic.List[object]
            $others = New-Object System.Collections.Generic.List[object]
            foreach ($child in $children) {
                if ($child.NodeType -eq "Element" -and $tagIndex.ContainsKey($child.LocalName) -and $tagOrder -ccontains $child.LocalName) {
                    $known.Add($child)
                } else {
                    if ($child.NodeType -eq "Element") { [void]$unexpectedTags.Add($child.LocalName) }
                    $others.Add($child)
                }
            }
            # Sort-Object -Stable isn't in Windows PowerShell 5.1, so keep the order by position
            $ranked = New-Object System.Collections.Generic.List[object]
            for ($k = 0; $k -lt $known.Count; $k++) {
                $ranked.Add([pscustomobject]@{ Node = $known[$k]; Rank = $tagIndex[$known[$k].LocalName]; Pos = $k })
            }
            foreach ($child in $children) { [void]$entry.RemoveChild($child) }
            foreach ($r in ($ranked | Sort-Object Rank, Pos)) { [void]$entry.AppendChild($r.Node) }
            foreach ($child in $others) { [void]$entry.AppendChild($child) }
        }

        # 5. Save to the output folder
        if (-not (Test-Path -LiteralPath $targetDir)) {
            [void][IO.Directory]::CreateDirectory($targetDir)
        }
        Save-Gamelist $doc $outputFile

        $totalGames += $games
        $totalFolders += $folders
        Write-Host " [SORTED]" -ForegroundColor Green -NoNewline
        Write-Host " ($games games, $folders folders)"
    } catch {
        $failed++
        Write-Host " [FAILED]" -ForegroundColor Red
        Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# --- SUMMARY ---
$title = "SUMMARY"
Write-Host "`n================ $title ================" -ForegroundColor Cyan
Write-Host "Total Files: $totalXmls"
Write-Host "Processed:   $($totalXmls - $skipped - $failed)"
Write-Host "Skipped:     $skipped"
if ($failed -gt 0) {
    Write-Host "Failed:      $failed" -ForegroundColor Red
} else {
    Write-Host "Failed:      0"
}
Write-Host "Games Sorted:   $totalGames"
Write-Host "Folders Sorted: $totalFolders"
if ($unexpectedTags.Count -gt 0) {
    Write-Host "`nTags not in the tag order (kept, moved to the end of each entry):" -ForegroundColor Yellow
    foreach ($tag in $unexpectedTags) { Write-Host "  - <$tag>" -ForegroundColor Yellow }
}
Write-Host ("=" * (34 + $title.Length))

Pause
