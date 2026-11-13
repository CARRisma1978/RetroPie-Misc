# RetroPie-Misc
Miscellaneous scripts related to RetroPie media.

Check_all_xml_links.ps1
Checks every gamelist.xml in a folder (and subfolders) for links to image, video, marquee, thumbnail and ROM files that are missing or have the wrong upper/lower case (which won't load on the Pi). Also lists orphaned media files that no gamelist links to. Saves a report file.

Check_m3u.ps1
Checks every .m3u playlist in a folder (and subfolders) for disc files that are missing or have the wrong upper/lower case. Saves a report file if anything is wrong.

CompareStrip.htm
Takes two XML game lists. For each game in File 2, finds the same game in File 1 (matched by <path>) and removes the tags from File 1 that File 2 also has. Games left with only a <path> are deleted. Shows the result to copy.

CompareSizes.ps1
Compares two folders and lists the files in folder A that are smaller than the matching file in folder B. Changes nothing.

CopySmallerPNGs.ps1
Compares PNGs in two folders and copies any from folder A that are smaller than the matching file in folder B into a third folder (SMALLER), keeping the subfolder structure.

ImageMagick.ps1
Resizes and tidies EmulationStation artwork with ImageMagick. Covers are converted to PNG, shrunk to fit 700x700 and stripped of metadata; marquees have their empty borders trimmed and are shrunk to fit 600x600. See ImageMagick.txt.

Find_similar.ps1
Looks through every gamelist.xml for games with very similar file names (e.g. different versions or discs of the same game) that could be tidied into a subfolder. Saves one results file per system in a "results" folder. Optional setting to include games already in subfolders.

Marquee_comparison.ps1
Finds games with more than one marquee (same game in different systems, regions or versions) by reading every gamelist.xml in the roms folder. Opens a report in your browser showing each group side by side, with the smallest file and highest resolution highlighted. "Use this one" copies that marquee over the others in its group (same file type only), backing up the originals first. Leave the PowerShell window open while using the report; click "Stop server" when finished.

Merge.htm
Takes two gamelist.xml files and adds the tags missing from the base file using the new file (games matched by <path>). Shows the merged XML to copy.

Moveifsmaller.ps1
Compares two folders (A and B). Where a file in B is smaller than the file with the same name in A, it moves the B file over the A file (overwriting it).

Optimise_SVG.ps1
Makes SVG files smaller by rounding long decimal numbers to 3 places. Does every .svg in a folder (and subfolders) and saves them to a new folder.

Oxipng.ps1
Shrinks the PNG covers and marquees losslessly with OxiPNG, so the pictures look exactly the same but take up less space. Normally run after ImageMagick.ps1, on its output. See Oxipng.txt.

Remove-ADS.ps1
Removes hidden alternate data streams (e.g. the "downloaded from the internet" Zone.Identifier mark) from every file and folder in the folder the script is in, and its subfolders. Shows what it found and asks before removing. File contents and dates are not changed.

Sort_gamelist.ps1
Tidies every gamelist.xml in a folder (and subfolders): sorts games and folders by name (ignoring "The"/"A"/"An", with numbers and Roman numerals in number order) and puts the tags inside each game in a set order. Saves the sorted gamelists to a new folder with Unix (LF) line endings.

stripmetadata.ps1
Removes hidden metadata from .mp4 video previews with FFmpeg. Nothing is re-encoded, so there's no quality loss and it’s quick. See stripmetadata.txt.

TitleCase.html
Opens a gamelist and suggests Title Case fixes for each <name> (e.g. "SUPER MARIO WORLD" -> "Super Mario World"). Tick the suggestions you want, or type your own, then download the updated XML.

Yuv420p.ps1
Finds .mp4 video previews that OMX Player on RetroPie can’t play (any pixel format other than yuv420p) and makes yuv420p copies of them with FFmpeg. Videos that already play are left alone. See Yuv420p.txt.
