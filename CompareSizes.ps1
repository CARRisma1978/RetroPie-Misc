# Update your folder paths below
$folderA = "C:\Users\email\OneDrive\Desktop\IM"
$folderB = "C:\Users\email\OneDrive\Desktop\Oxi2"

# Ensure paths exist
if (!(Test-Path $folderA) -or !(Test-Path $folderB)) {
    Write-Error "One of the folders does not exist. Check your paths."
    return
}

$filesA = Get-ChildItem -Path $folderA -File -Recurse
Write-Host "Found $($filesA.Count) files in Folder A. Starting comparison..." -ForegroundColor Cyan

$smallerFound = $false

foreach ($fileA in $filesA) {
    # Calculate the matching path in Folder B
    $relativePath = $fileA.FullName.Replace($folderA, "")
    $pathB = Join-Path $folderB $relativePath

    if (Test-Path $pathB) {
        $fileB = Get-Item $pathB
        
        # Output progress (Optional: comment out if too much text)
        # Write-Host "Checking: $($fileA.Name)" -ForegroundColor Gray

        if ($fileA.Length -lt $fileB.Length) {
            Write-Host "MATCH FOUND: '$($fileA.FullName)' is SMALLER than Folder B version." -ForegroundColor Yellow
            Write-Host "   Size A: $($fileA.Length) bytes | Size B: $($fileB.Length) bytes"
            $smallerFound = $true
        }
    }
}

if (-not $smallerFound) {
    Write-Host "Comparison complete. No files in Folder A were smaller than Folder B." -ForegroundColor Green
}
