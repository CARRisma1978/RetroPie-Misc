# --- CONFIGURATION ---
# Update these paths to your actual folder locations
$folderA = "C:\Users\email\OneDrive\Desktop\Work In Progress"
$folderB = "C:\Users\email\OneDrive\Desktop\OXIDONE"
$folderDest = "C:\Users\email\OneDrive\Desktop\SMALLER"

# Ensure source paths exist
if (!(Test-Path $folderA) -or !(Test-Path $folderB)) {
    Write-Error "One of the source folders (IMDONE or OXIDONE) does not exist. Check your paths."
    return
}

# Create the destination folder 'SMALLER' if it doesn't exist
if (!(Test-Path $folderDest)) {
    New-Item -ItemType Directory -Path $folderDest | Out-Null
    Write-Host "Created destination folder: $folderDest" -ForegroundColor Cyan
}

# Get all PNG files recursively in Folder A
$filesA = Get-ChildItem -Path $folderA -Filter "*.png" -File -Recurse
Write-Host "Found $($filesA.Count) PNG files in '$folderA'. Starting comparison..." -ForegroundColor Cyan

$countCopied = 0

foreach ($fileA in $filesA) {
    # Calculate the relative path (e.g., "\SubFolder\image.png")
    # We use [Regex]::Escape to safely handle characters like parentheses in the folder path
    $escapedFolderA = [Regex]::Escape($folderA)
    $relativePath = $fileA.FullName -replace "^$escapedFolderA", ""
    
    # define the matching path in Folder B and Destination
    $pathB = Join-Path $folderB $relativePath
    $pathDest = Join-Path $folderDest $relativePath

    # Check if the file exists in Folder B
    if (Test-Path $pathB) {
        $fileB = Get-Item $pathB
        
        # Compare sizes: If A is smaller than B
        if ($fileA.Length -lt $fileB.Length) {
            Write-Host "Found smaller version: $($fileA.Name)" -ForegroundColor Yellow
            Write-Host "   Size A: $($fileA.Length) | Size B: $($fileB.Length)" -ForegroundColor DarkGray
            
            # Ensure the subdirectory exists in 'SMALLER' before copying
            $destDir = Split-Path $pathDest -Parent
            if (!(Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir | Out-Null
            }

            # Copy the file
            Copy-Item -Path $fileA.FullName -Destination $pathDest -Force
            Write-Host "   -> Copied to: $pathDest" -ForegroundColor Green
            $countCopied++
        }
    }
}

Write-Host "------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Process Complete. Total files copied to 'SMALLER': $countCopied" -ForegroundColor Cyan