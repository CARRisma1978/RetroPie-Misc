<#
    .NOTES
    Finds games that have more than one marquee image (the same game in different
    systems, regions or versions), shows them side by side in your web browser, and
    lets you copy the best one over the others with one click.
    Replaces the whole "Marquee Comparison" folder of Python scripts and server.py.
    Configuration: set the folders below - relative to where the script is run, or
    full paths (e.g. "C:\Users\email\OneDrive\Desktop\roms").

    1. Reads every gamelist.xml in the roms folder (and all its subfolders)
    2. Groups the marquees by game name, ignoring (...) and [...] text, upper/lower
       case, spaces and punctuation - "Spider-Man (USA)" and "Spiderman [!]" match
    3. Gets each marquee's file size and dimensions, and highlights the smallest
       file and the highest resolution in each group
    4. Opens the report in your browser, sorted A-Z, with the pictures shown
    5. "Use this one" copies that marquee over the others in its group
       - Only over files of the same type (a .png isn't copied over a .jpg)
       - The files it replaces are backed up first (see $backupDirName)
       - The page reloads to show the new sizes; files that are now the same
         are marked IDENTICAL
    Leave this PowerShell window open while you use the report. Click
    "Stop server" in the report (or press Ctrl+C here) when you've finished.

    Also:
      - Groups where every file is already identical are hidden (tick box in the
        report to show them)
      - Marquee paths starting ./ (relative to the gamelist), full Windows paths,
        and Pi paths containing /roms/ (e.g. /home/pi/RetroPie/roms/...) all work
      - Marquees that can't be found are listed at the bottom of the report
      - The report only works on this computer (localhost)
#>

# --- CONFIGURATION ---
$romsDirName   = "roms"               # folder containing your system folders (with gamelist.xml files)
$backupDirName = "Marquee backups"    # folder for copies of replaced files ("" = no backups)
$port          = 8000                 # port for the report (http://localhost:8000)
# ---------------------

# --- IMAGE SIZE READER ---
# Reads the width and height from the start of PNG, JPG, GIF, BMP and WebP files
# (quick, and doesn't lock the file)
if (-not ("MarqueeImageInfo" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
public static class MarqueeImageInfo
{
    static int BE32(byte[] b, int i) { return (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]; }
    static int LE32(byte[] b, int i) { return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24); }

    public static int[] GetSize(string path)
    {
        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                byte[] h = new byte[32];
                int n = fs.Read(h, 0, 32);
                // PNG
                if (n >= 24 && h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47)
                    return new int[] { BE32(h, 16), BE32(h, 20) };
                // GIF
                if (n >= 10 && h[0] == 'G' && h[1] == 'I' && h[2] == 'F')
                    return new int[] { h[6] | (h[7] << 8), h[8] | (h[9] << 8) };
                // BMP
                if (n >= 26 && h[0] == 'B' && h[1] == 'M')
                    return new int[] { LE32(h, 18), Math.Abs(LE32(h, 22)) };
                // WebP
                if (n >= 30 && h[0] == 'R' && h[1] == 'I' && h[2] == 'F' && h[3] == 'F' &&
                    h[8] == 'W' && h[9] == 'E' && h[10] == 'B' && h[11] == 'P')
                {
                    string chunk = Encoding.ASCII.GetString(h, 12, 4);
                    if (chunk == "VP8X")
                        return new int[] { 1 + (h[24] | (h[25] << 8) | (h[26] << 16)), 1 + (h[27] | (h[28] << 8) | (h[29] << 16)) };
                    if (chunk == "VP8L")
                        return new int[] { 1 + (((h[22] & 0x3F) << 8) | h[21]),
                                           1 + (((h[24] & 0x0F) << 10) | (h[23] << 2) | ((h[22] & 0xC0) >> 6)) };
                    if (chunk == "VP8 ")
                        return new int[] { (h[26] | (h[27] << 8)) & 0x3FFF, (h[28] | (h[29] << 8)) & 0x3FFF };
                    return null;
                }
                // JPEG: look for the frame header
                if (n >= 4 && h[0] == 0xFF && h[1] == 0xD8)
                {
                    fs.Position = 2;
                    while (true)
                    {
                        int b = fs.ReadByte();
                        if (b < 0) return null;
                        if (b != 0xFF) continue;
                        int marker = fs.ReadByte();
                        while (marker == 0xFF) marker = fs.ReadByte();
                        if (marker < 0 || marker == 0xD9 || marker == 0xDA) return null;
                        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) continue;
                        int len = (fs.ReadByte() << 8) | fs.ReadByte();
                        if (len < 2) return null;
                        if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC)
                        {
                            byte[] s = new byte[5];
                            if (fs.Read(s, 0, 5) < 5) return null;
                            return new int[] { (s[3] << 8) | s[4], (s[1] << 8) | s[2] };
                        }
                        fs.Position += len - 2;
                    }
                }
            }
        }
        catch { }
        return null;
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

# Game name -> grouping key: no (...) / [...], lower case, letters and numbers only
function Get-NameKey([string]$name) {
    $n = [regex]::Replace($name, '\(.*?\)|\[.*?\]', '')
    return [regex]::Replace($n.ToLowerInvariant(), '[^a-z0-9]', '')
}

# Marquee path from a gamelist -> full Windows path ($null if it can't be worked out)
function Resolve-Marquee([string]$value, [string]$xmlDir) {
    $v = $value.Trim()
    if (-not $v) { return $null }
    try {
        if ($v -match '^[/~]') {
            # Pi path: map everything after /roms/ onto the roms folder
            $m = [regex]::Match($v, '/roms/(.+)$')
            if (-not $m.Success) { return $null }
            return [IO.Path]::GetFullPath([IO.Path]::Combine($script:romsPath, $m.Groups[1].Value))
        }
        if ($v -match '^[A-Za-z]:[\\/]') { return [IO.Path]::GetFullPath($v) }
        return [IO.Path]::GetFullPath([IO.Path]::Combine($xmlDir, $v))
    } catch {
        return $null
    }
}

# Path shown in the report: relative to the roms folder where possible
function Get-DisplayPath([string]$fullPath) {
    if ($fullPath.StartsWith($script:romsPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($script:romsPath.Length + 1).Replace('\', '/')
    }
    return $fullPath
}

# File size as text, e.g. 49.489 KB
function Format-Size([long]$bytes) {
    $c = [Globalization.CultureInfo]::InvariantCulture
    if ($bytes -lt 1KB) { return "$bytes B" }
    if ($bytes -lt 1MB) { return ($bytes / 1KB).ToString("0.000", $c) + " KB" }
    return ($bytes / 1MB).ToString("0.000", $c) + " MB"
}

# Size, dimensions and content fingerprint of a file
$script:md5 = [System.Security.Cryptography.MD5]::Create()
function Update-FileStats($f) {
    $info = New-Object IO.FileInfo $f.FullPath
    $f.Size = $info.Length
    $dims = [MarqueeImageInfo]::GetSize($f.FullPath)
    if ($dims) { $f.W = $dims[0]; $f.H = $dims[1] } else { $f.W = 0; $f.H = 0 }
    $bytes = [IO.File]::ReadAllBytes($f.FullPath)
    $f.Hash = [BitConverter]::ToString($script:md5.ComputeHash($bytes)).Replace("-", "")
}

function Encode([string]$s) { return [System.Net.WebUtility]::HtmlEncode($s) }

# --- FOLDERS ---
$script:romsPath = Resolve-Folder $romsDirName
$backupPath = if ($backupDirName) { Resolve-Folder $backupDirName } else { $null }

Write-Host "`n================ MARQUEE COMPARISON ================" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $script:romsPath -PathType Container)) {
    Write-Host "Error: Folder '$romsDirName' not found." -ForegroundColor Red
    Pause
    Exit
}

# ============ STEP 1: READ THE GAMELISTS ============
# -LiteralPath so folder names containing [ ] work
$xmlFiles = @(Get-ChildItem -LiteralPath $script:romsPath -Recurse -File -Filter "gamelist.xml" |
              Where-Object { $_.Name -eq "gamelist.xml" } | Sort-Object FullName)
$totalXmls = $xmlFiles.Count
Write-Host "Found $totalXmls gamelist.xml files. Reading..." -ForegroundColor Cyan
Write-Host "------------------------------------------------"

$files = New-Object System.Collections.Generic.List[object]    # every marquee file found (Id = position)
$fileByPath = @{}                                               # full path (any case) -> file
$groupMap = @{}                                                 # name key -> group
$missing = New-Object System.Collections.Generic.List[object]
$failedXmls = 0
$marqueeLinks = 0
$i = 0

foreach ($xmlFile in $xmlFiles) {
    $i++
    $system = $xmlFile.DirectoryName.Substring($script:romsPath.Length).TrimStart('\', '/').Replace('\', '/')
    if (-not $system) { $system = "(roms folder)" }
    Write-Host "[$i/$totalXmls] $system" -NoNewline

    try {
        $xmlText = [IO.File]::ReadAllText($xmlFile.FullName, [Text.Encoding]::UTF8)
        # Fix unescaped ampersands (e.g. "Tom & Jerry") so the XML can be read
        $xmlText = [regex]::Replace($xmlText, '&(?!(?:[a-zA-Z][a-zA-Z0-9]*|#[0-9]+|#x[0-9a-fA-F]+);)', '&amp;')
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($xmlText)
    } catch {
        $failedXmls++
        Write-Host " [COULDN'T READ XML]" -ForegroundColor Red
        Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
        continue
    }

    $count = 0
    foreach ($game in $doc.SelectNodes("//game")) {
        $nameNode = $game.SelectSingleNode("name")
        $marqueeNode = $game.SelectSingleNode("marquee")
        if (-not $nameNode -or -not $marqueeNode) { continue }
        $name = $nameNode.InnerText.Trim()
        $marquee = $marqueeNode.InnerText.Trim()
        if (-not $name -or -not $marquee) { continue }
        $marqueeLinks++
        $count++

        $key = Get-NameKey $name
        if (-not $key) { continue }

        $fullPath = Resolve-Marquee $marquee $xmlFile.DirectoryName
        if (-not $fullPath -or -not [IO.File]::Exists($fullPath)) {
            $missing.Add([pscustomobject]@{ System = $system; Game = $name; Marquee = $marquee })
            continue
        }

        # One entry per file, even if several games use it
        if ($fileByPath.ContainsKey($fullPath)) {
            $f = $fileByPath[$fullPath]
        } else {
            $f = [pscustomobject]@{
                Id = $files.Count; FullPath = $fullPath; Display = (Get-DisplayPath $fullPath)
                Ext = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()
                Games = (New-Object System.Collections.Generic.List[string])
                Size = 0; W = 0; H = 0; Hash = ""
            }
            $files.Add($f)
            $fileByPath[$fullPath] = $f
        }
        $label = "$system - $name"
        if (-not $f.Games.Contains($label)) { $f.Games.Add($label) }

        if (-not $groupMap.ContainsKey($key)) {
            $title = ([regex]::Replace($name, '\(.*?\)|\[.*?\]', '') -replace '\s+', ' ').Trim()
            if (-not $title) { $title = $name }
            $groupMap[$key] = [pscustomobject]@{
                Key = $key; Title = $title
                FileIds = (New-Object System.Collections.Generic.List[int])
                StartIdentical = $false; Message = ""
            }
        }
        $g = $groupMap[$key]
        if (-not $g.FileIds.Contains($f.Id)) { $g.FileIds.Add($f.Id) }
    }
    Write-Host " ($count marquees)"
}

# ============ STEP 2: FILE SIZES AND DIMENSIONS ============
$groups = @($groupMap.Values | Where-Object { $_.FileIds.Count -gt 1 } | Sort-Object Title, Key)
$groupedIds = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($g in $groups) { foreach ($id in $g.FileIds) { [void]$groupedIds.Add($id) } }

Write-Host "`nReading sizes and dimensions of $($groupedIds.Count) marquees in $($groups.Count) groups..." -ForegroundColor Cyan
$n = 0
foreach ($id in $groupedIds) {
    $n++
    if ($n % 50 -eq 0) {
        Write-Progress -Activity "Reading marquees" -Status "$n of $($groupedIds.Count)" -PercentComplete ([math]::Floor($n * 100 / $groupedIds.Count))
    }
    try { Update-FileStats $files[$id] } catch { }
}
Write-Progress -Activity "Reading marquees" -Completed

$identicalGroups = 0
foreach ($g in $groups) {
    # Sort each group's files by path, and note groups that are identical already
    $sortedIds = @($g.FileIds | Sort-Object { $files[$_].Display })
    $g.FileIds.Clear()
    foreach ($id in $sortedIds) { $g.FileIds.Add($id) }
    $hashes = @($g.FileIds | ForEach-Object { $files[$_].Hash } | Select-Object -Unique)
    if ($hashes.Count -eq 1) { $g.StartIdentical = $true; $identicalGroups++ }
}

# --- SUMMARY ---
$title = "SUMMARY"
Write-Host "`n================ $title ================" -ForegroundColor Cyan
Write-Host "Gamelists Read:     $($totalXmls - $failedXmls)"
if ($failedXmls -gt 0) { Write-Host "Couldn't Read:      $failedXmls" -ForegroundColor Red }
Write-Host "Marquee Links:      $marqueeLinks"
if ($missing.Count -gt 0) { Write-Host "Not Found:          $($missing.Count)" -ForegroundColor Yellow } else { Write-Host "Not Found:          0" }
Write-Host "Duplicate Groups:   $($groups.Count)" -ForegroundColor Yellow
Write-Host "  Already Identical: $identicalGroups (hidden in the report)"
Write-Host "Marquees in Groups: $($groupedIds.Count)"
Write-Host ("=" * (34 + $title.Length))

if ($groups.Count -eq 0) {
    Write-Host "`nNo games with more than one marquee - nothing to compare." -ForegroundColor Green
    Pause
    Exit
}

# ============ STEP 3: THE REPORT ============
# Random code the report sends back with each request, so no other web page can use the server
$token = [Guid]::NewGuid().ToString("N")

$pageTop = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Marquee Comparison</title>
<style>
  :root { --bg:#f4f5f7; --card:#fff; --text:#1d2330; --muted:#667085; --line:#e3e6eb;
          --hi:#ffe14d; --ok:#1f8a4c; --okbg:#e6f6ec; --btn:#2457c5; }
  * { box-sizing: border-box; }
  body { margin:0; font-family: Segoe UI, Arial, sans-serif; background:var(--bg); color:var(--text); font-size:14px; }
  header { position:sticky; top:0; z-index:5; background:#1d2330; color:#fff; padding:10px 16px;
           display:flex; flex-wrap:wrap; gap:12px; align-items:center; }
  header h1 { font-size:18px; margin:0 12px 0 0; }
  header .stats { color:#c5cad3; }
  header input[type=search] { padding:6px 8px; border-radius:4px; border:0; min-width:200px; }
  header label { color:#c5cad3; cursor:pointer; }
  header button { margin-left:auto; }
  main { max-width:1100px; margin:0 auto; padding:16px; }
  .group { background:var(--card); border:1px solid var(--line); border-radius:6px; margin:0 0 14px; padding:10px 14px; }
  .group h2 { font-size:16px; margin:2px 0 8px; }
  .group h2 .count { color:var(--muted); font-weight:normal; font-size:13px; margin-left:6px; }
  .msg { background:var(--okbg); color:var(--ok); border-radius:4px; padding:6px 8px; margin:0 0 8px; }
  .msg.err { background:#fdecec; color:#b42318; }
  table { width:100%; border-collapse:collapse; }
  td { border-top:1px solid var(--line); padding:6px 8px; vertical-align:middle; }
  td.thumb { width:240px; }
  td.thumb img { max-width:220px; max-height:80px; display:block;
                 background: repeating-conic-gradient(#ddd 0% 25%, #fff 0% 50%) 50% / 12px 12px; }
  .games { font-weight:600; }
  .path { color:var(--muted); font-size:12px; word-break:break-all; }
  td.num { white-space:nowrap; text-align:right; width:110px; }
  .best { background:var(--hi); padding:1px 4px; border-radius:3px; }
  .tag { display:inline-block; font-size:11px; padding:1px 6px; border-radius:10px; background:#e8ecf3; color:#344054; margin-left:4px; }
  .tag.same { background:var(--okbg); color:var(--ok); }
  button { background:var(--btn); color:#fff; border:0; border-radius:4px; padding:6px 10px; cursor:pointer; font-size:13px; }
  button:disabled { background:#b8c0cc; cursor:default; }
  header button { background:#c4320a; }
  .hidden { display:none; }
  details { background:var(--card); border:1px solid var(--line); border-radius:6px; padding:10px 14px; }
  details li { margin:2px 0; }
  @media (max-width:700px) { td.thumb { width:auto; } td.thumb img { max-width:140px; } }
</style>
</head>
<body>
'@

$pageScript = @'
<script>
const TOKEN = "__TOKEN__";
const BACKUPS = __BACKUPS__;
function useThis(g, id, others) {
  let text = "Copy this marquee over the other " + others + " file(s) of the same type in this group?";
  text += BACKUPS ? "\n\nThe files it replaces are backed up first." : "\n\nBackups are switched off - this can't be undone.";
  if (!confirm(text)) return;
  fetch("/overwrite", { method: "POST", headers: { "Content-Type": "application/json" },
                        body: JSON.stringify({ token: TOKEN, group: g, src: id }) })
    .then(r => r.text().then(t => { if (!r.ok) throw new Error(t); location.reload(); }))
    .catch(e => alert("Couldn't copy the file: " + e.message + "\n\nIs the PowerShell window still open?"));
}
function stopServer() {
  if (!confirm("Stop the server? The buttons won't work after this.")) return;
  fetch("/stop", { method: "POST", body: JSON.stringify({ token: TOKEN }) }).finally(() => {
    document.querySelector("main").innerHTML = "<h2>Server stopped.</h2><p>You can close this tab and the PowerShell window.</p>";
  });
}
function applyFilter() {
  const q = document.getElementById("q").value.toLowerCase().replace(/[^a-z0-9]/g, "");
  const showSame = document.getElementById("showSame").checked;
  let shown = 0;
  document.querySelectorAll(".group").forEach(el => {
    const hide = (!showSame && el.dataset.startSame === "1") || (q && el.dataset.key.indexOf(q) < 0);
    el.classList.toggle("hidden", hide);
    if (!hide) shown++;
  });
  document.getElementById("shown").textContent = shown;
  try { sessionStorage.setItem("mq", JSON.stringify({ q: document.getElementById("q").value, s: showSame })); } catch (e) {}
}
try {
  const saved = JSON.parse(sessionStorage.getItem("mq") || "null");
  if (saved) { document.getElementById("q").value = saved.q; document.getElementById("showSame").checked = saved.s; }
} catch (e) {}
document.getElementById("q").addEventListener("input", applyFilter);
document.getElementById("showSame").addEventListener("change", applyFilter);
applyFilter();
</script>
</body>
</html>
'@

# Builds the report page from the current state of the files
function Get-ReportHtml {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($pageTop)
    [void]$sb.Append("<header><h1>Marquee Comparison</h1>")
    [void]$sb.Append("<span class=""stats""><span id=""shown"">0</span> of $($groups.Count) groups shown</span>")
    [void]$sb.Append("<input type=""search"" id=""q"" placeholder=""Search game names..."">")
    [void]$sb.Append("<label><input type=""checkbox"" id=""showSame""> Show groups that were identical at the start ($identicalGroups)</label>")
    [void]$sb.Append("<button type=""button"" onclick=""stopServer()"">Stop server</button></header><main>")

    $gi = 0
    foreach ($g in $groups) {
        $members = @($g.FileIds | ForEach-Object { $files[$_] })
        $sizes = @($members | Where-Object { $_.Size -gt 0 } | ForEach-Object { $_.Size })
        $areas = @($members | Where-Object { $_.W -gt 0 } | ForEach-Object { $_.W * $_.H })
        $minSize = if ($sizes.Count) { ($sizes | Measure-Object -Minimum).Minimum } else { -1 }
        $maxArea = if ($areas.Count) { ($areas | Measure-Object -Maximum).Maximum } else { -1 }
        $hashCounts = @{}
        foreach ($m in $members) { $hashCounts[$m.Hash] = 1 + [int]$hashCounts[$m.Hash] }
        $allSame = ($hashCounts.Count -eq 1)

        $startSame = if ($g.StartIdentical) { "1" } else { "0" }
        [void]$sb.Append("<section class=""group"" data-key=""$(Encode $g.Key)"" data-start-same=""$startSame"">")
        [void]$sb.Append("<h2>$(Encode $g.Title)<span class=""count"">$($members.Count) files</span>")
        if ($allSame) { [void]$sb.Append("<span class=""tag same"">ALL IDENTICAL</span>") }
        [void]$sb.Append("</h2>")
        if ($g.Message) {
            $cls = if ($g.Message.StartsWith("!")) { "msg err" } else { "msg" }
            [void]$sb.Append("<div class=""$cls"">$(Encode $g.Message.TrimStart('!'))</div>")
        }
        [void]$sb.Append("<table>")
        foreach ($m in $members) {
            $sizeText = Encode (Format-Size $m.Size)
            if ($m.Size -eq $minSize) { $sizeText = "<span class=""best"" title=""Smallest file"">$sizeText</span>" }
            $dimsText = if ($m.W -gt 0) { "$($m.W)x$($m.H)" } else { "Dims unknown" }
            if ($m.W -gt 0 -and ($m.W * $m.H) -eq $maxArea) { $dimsText = "<span class=""best"" title=""Highest resolution"">$dimsText</span>" }

            # Other files of the same type that aren't already identical to this one
            $targets = @($members | Where-Object { $_.Id -ne $m.Id -and $_.Ext -eq $m.Ext -and $_.Hash -ne $m.Hash }).Count
            $sameTag = if ($hashCounts[$m.Hash] -gt 1) { "<span class=""tag same"">IDENTICAL</span>" } else { "" }
            $extTag = "<span class=""tag"">$(Encode $m.Ext.TrimStart('.').ToUpper())</span>"
            $btn = if ($targets -gt 0) {
                "<button type=""button"" onclick=""useThis($gi, $($m.Id), $targets)"">Use this one</button>"
            } else {
                "<button type=""button"" disabled title=""No other files of the same type to replace"">Use this one</button>"
            }

            [void]$sb.Append("<tr><td class=""thumb""><img loading=""lazy"" alt="""" src=""/img?id=$($m.Id)&amp;v=$($m.Hash)""></td>")
            [void]$sb.Append("<td><div class=""games"">$((($m.Games | ForEach-Object { Encode $_ }) -join '<br>'))</div>")
            [void]$sb.Append("<div class=""path"">$(Encode $m.Display)$extTag$sameTag</div></td>")
            [void]$sb.Append("<td class=""num"">$sizeText</td><td class=""num"">$dimsText</td><td>$btn</td></tr>")
        }
        [void]$sb.Append("</table></section>")
        $gi++
    }

    if ($missing.Count -gt 0) {
        [void]$sb.Append("<details><summary>Marquees not found ($($missing.Count))</summary><ul>")
        foreach ($mi in $missing) {
            [void]$sb.Append("<li>$(Encode $mi.System) - $(Encode $mi.Game): <span class=""path"">$(Encode $mi.Marquee)</span></li>")
        }
        [void]$sb.Append("</ul></details>")
    }
    [void]$sb.Append("</main>")
    $backups = if ($backupPath) { "true" } else { "false" }
    [void]$sb.Append($pageScript.Replace("__TOKEN__", $token).Replace("__BACKUPS__", $backups))
    return $sb.ToString()
}

# Copies one marquee over the others of the same type in its group
function Invoke-Overwrite([int]$groupIndex, [int]$srcId) {
    if ($groupIndex -lt 0 -or $groupIndex -ge $groups.Count) { throw "Unknown group." }
    $g = $groups[$groupIndex]
    if (-not $g.FileIds.Contains($srcId)) { throw "That file isn't in this group." }
    $src = $files[$srcId]
    if (-not [IO.File]::Exists($src.FullPath)) { throw "The file no longer exists: $($src.FullPath)" }

    $copied = 0; $failedCopies = 0; $skippedType = 0
    foreach ($id in $g.FileIds) {
        if ($id -eq $srcId) { continue }
        $dest = $files[$id]
        if ($dest.Ext -ne $src.Ext) { $skippedType++; continue }
        if ($dest.Hash -eq $src.Hash) { continue }
        try {
            # Back up the original first (an earlier backup of the same file is kept)
            if ($backupPath -and [IO.File]::Exists($dest.FullPath)) {
                $rel = if ($dest.FullPath.StartsWith($script:romsPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $dest.FullPath.Substring($script:romsPath.Length).TrimStart('\', '/')
                } else {
                    $dest.FullPath.Replace(':', '')
                }
                $backupFile = [IO.Path]::Combine($backupPath, $rel)
                if (-not [IO.File]::Exists($backupFile)) {
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backupFile))
                    [IO.File]::Copy($dest.FullPath, $backupFile)
                }
            }
            Write-Host "Overwriting: $($dest.Display)" -ForegroundColor Yellow
            Write-Host "       with: $($src.Display)" -ForegroundColor DarkGray
            [IO.File]::Copy($src.FullPath, $dest.FullPath, $true)
            Update-FileStats $dest
            $copied++
        } catch {
            $failedCopies++
            Write-Host "  [FAILED] $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $msg = "Copied $(Split-Path $src.FullPath -Leaf) over $copied file(s)."
    if ($skippedType -gt 0) { $msg += " $skippedType of a different file type left alone." }
    if ($failedCopies -gt 0) { $msg = "!" + $msg + " $failedCopies failed - see the PowerShell window." }
    elseif ($copied -gt 0 -and $backupPath) { $msg += " Originals backed up to: $backupPath" }
    $g.Message = $msg
}

function Send-Response($ctx, [int]$status, [string]$contentType, [byte[]]$bytes) {
    try {
        $ctx.Response.StatusCode = $status
        $ctx.Response.ContentType = $contentType
        $ctx.Response.Headers.Add("Cache-Control", "no-store")
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch { }
    try { $ctx.Response.OutputStream.Close() } catch { }
}

function Send-Text($ctx, [int]$status, [string]$text, [string]$contentType = "text/plain; charset=utf-8") {
    Send-Response $ctx $status $contentType ([Text.Encoding]::UTF8.GetBytes($text))
}

function Read-JsonBody($ctx) {
    $reader = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    $data = $body | ConvertFrom-Json
    if ($data.token -ne $token) { throw "Wrong token - reload the report page." }
    return $data
}

$mimeTypes = @{ ".png" = "image/png"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"; ".gif" = "image/gif"
                ".bmp" = "image/bmp"; ".webp" = "image/webp"; ".svg" = "image/svg+xml" }

# ============ STEP 4: SERVE THE REPORT ============
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try {
    $listener.Start()
} catch {
    Write-Host "`nError: Couldn't start the report on port $port - $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       Is another copy of this script (or server.py) still running? Or change `$port at the top." -ForegroundColor Red
    Pause
    Exit
}

$url = "http://localhost:$port/"
Write-Host "`nReport ready: $url" -ForegroundColor Green
Write-Host "Leave this window open while you use the report." -ForegroundColor Green
Write-Host "Click 'Stop server' in the report, or press Ctrl+C here, when you've finished.`n" -ForegroundColor Green
try { Start-Process $url } catch { Write-Host "Open $url in your web browser." -ForegroundColor Yellow }

$running = $true
try {
    while ($running) {
        $task = $listener.GetContextAsync()
        # Wait in short steps so Ctrl+C still works
        while (-not $task.AsyncWaitHandle.WaitOne(500)) { }
        try { $ctx = $task.GetAwaiter().GetResult() } catch { continue }

        $path = $ctx.Request.Url.AbsolutePath
        $method = $ctx.Request.HttpMethod
        try {
            if ($method -eq "GET" -and ($path -eq "/" -or $path -eq "/index.html")) {
                Send-Text $ctx 200 (Get-ReportHtml) "text/html; charset=utf-8"
            }
            elseif ($method -eq "GET" -and $path -eq "/img") {
                $id = -1
                if (-not [int]::TryParse($ctx.Request.QueryString["id"], [ref]$id) -or $id -lt 0 -or $id -ge $files.Count -or
                    -not [IO.File]::Exists($files[$id].FullPath)) {
                    Send-Text $ctx 404 "Not found"
                } else {
                    $f = $files[$id]
                    $type = $mimeTypes[$f.Ext]
                    if (-not $type) { $type = "application/octet-stream" }
                    Send-Response $ctx 200 $type ([IO.File]::ReadAllBytes($f.FullPath))
                }
            }
            elseif ($method -eq "POST" -and $path -eq "/overwrite") {
                $data = Read-JsonBody $ctx
                Invoke-Overwrite ([int]$data.group) ([int]$data.src)
                Send-Text $ctx 200 "Success"
            }
            elseif ($method -eq "POST" -and $path -eq "/stop") {
                [void](Read-JsonBody $ctx)
                Send-Text $ctx 200 "Stopped"
                $running = $false
            }
            elseif ($path -eq "/favicon.ico") {
                Send-Text $ctx 404 "Not found"
            }
            else {
                Send-Text $ctx 404 "Not found"
            }
        } catch {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            Send-Text $ctx 500 $_.Exception.Message
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "`nServer stopped." -ForegroundColor Cyan
}

Pause
