<#
.SYNOPSIS
    Fixes EXIF orientation metadata on JPG images by physically rotating the pixels
    and resetting the orientation tag to normal (1).

.DESCRIPTION
    iPhone photos store rotation in the EXIF Orientation tag (0x0112). Some apps
    ignore this tag, causing images to appear rotated. This script physically rotates
    the image pixels to match the EXIF orientation, then resets the tag to 1 (normal).

.PARAMETER Path
    Path to a folder containing JPG files, or a single JPG file.

.PARAMETER Recurse
    If specified, processes JPG files in subdirectories as well.

.PARAMETER BackupFolder
    Name of the subfolder to store original (unmodified) files. Defaults to 'originals'.

.PARAMETER WhatIf
    If specified, reports what would be changed without modifying files.

.EXAMPLE
    .\fix_image_orientation.ps1 -Path "C:\Photos"
    .\fix_image_orientation.ps1 -Path "C:\Photos" -Recurse
    .\fix_image_orientation.ps1 -Path "C:\Photos" -BackupFolder "backup"
    .\fix_image_orientation.ps1 -Path "C:\Photos\image.jpg"
    .\fix_image_orientation.ps1 -Path "C:\Photos" -WhatIf
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [switch]$Recurse,

    [string]$BackupFolder = "originals",

    [switch]$WhatIf
)

Add-Type -AssemblyName System.Drawing

# EXIF Orientation tag ID
$ORIENTATION_TAG = 0x0112

# Orientation values and their meanings
$orientationMap = @{
    1 = "Normal"
    2 = "Flipped horizontally"
    3 = "Rotated 180"
    4 = "Flipped vertically"
    5 = "Rotated 90 CW + flipped horizontally"
    6 = "Rotated 90 CW"
    7 = "Rotated 90 CCW + flipped horizontally"
    8 = "Rotated 90 CCW"
}

function Get-Orientation {
    param([System.Drawing.Image]$Image)

    try {
        $prop = $Image.GetPropertyItem($ORIENTATION_TAG)
        return [BitConverter]::ToUInt16($prop.Value, 0)
    }
    catch {
        return 1  # No orientation tag means normal
    }
}

function Set-OrientationNormal {
    param([System.Drawing.Image]$Image)

    try {
        $prop = $Image.GetPropertyItem($ORIENTATION_TAG)
        $prop.Value = [BitConverter]::GetBytes([uint16]1)
        $Image.SetPropertyItem($prop)
    }
    catch {
        # No orientation property to set
    }
}

function Apply-Rotation {
    param(
        [System.Drawing.Image]$Image,
        [int]$Orientation
    )

    switch ($Orientation) {
        2 { $Image.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX) }
        3 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
        4 { $Image.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipY) }
        5 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipX) }
        6 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
        7 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipX) }
        8 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
    }
}

# Resolve files
if (Test-Path $Path -PathType Leaf) {
    $files = @(Get-Item $Path | Where-Object { $_.Extension -match '\.jpe?g$' })
}
elseif (Test-Path $Path -PathType Container) {
    $params = @{ Path = $Path; Filter = "*.jpg" }
    if ($Recurse) { $params.Recurse = $true }
    $files = @(Get-ChildItem @params)
    # Also get .jpeg files
    $params.Filter = "*.jpeg"
    $files += @(Get-ChildItem @params)
}
else {
    Write-Error "Path not found: $Path"
    exit 1
}

if ($files.Count -eq 0) {
    Write-Host "No JPG files found in: $Path"
    exit 0
}

Write-Host "Found $($files.Count) JPG file(s) to analyze.`n"

$fixed = 0
$skipped = 0
$errors = 0

foreach ($file in $files) {
    try {
        # Load image from file bytes to avoid file lock
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $ms = New-Object System.IO.MemoryStream($bytes, $false)
        $image = [System.Drawing.Image]::FromStream($ms, $false, $false)

        $orientation = Get-Orientation -Image $image

        if ($orientation -eq 1) {
            Write-Host "[SKIP] $($file.FullName) - already normal orientation"
            $skipped++
            $image.Dispose()
            $ms.Dispose()
            continue
        }

        $desc = $orientationMap[$orientation]
        if (-not $desc) { $desc = "Unknown ($orientation)" }

        if ($WhatIf) {
            Write-Host "[WOULD FIX] $($file.FullName) - orientation: $desc"
            $fixed++
            $image.Dispose()
            $ms.Dispose()
            continue
        }

        Write-Host "[FIXING] $($file.FullName) - orientation: $desc"

        # Create backup subfolder in the same directory as the source file
        $backupDir = Join-Path $file.DirectoryName $BackupFolder
        if (-not (Test-Path $backupDir)) {
            New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        }

        # Move original to backup folder
        $backupPath = Join-Path $backupDir $file.Name
        Copy-Item -Path $file.FullName -Destination $backupPath -Force

        # Apply the physical rotation
        Apply-Rotation -Image $image -Orientation $orientation

        # Reset orientation tag to normal
        Set-OrientationNormal -Image $image

        # Save fixed file to a temp path, then replace the original
        $tempFile = "$($file.FullName).tmp"
        $image.Save($tempFile, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $image.Dispose()
        $ms.Dispose()

        # Replace original with fixed file
        Move-Item -Path $tempFile -Destination $file.FullName -Force
        $fixed++
    }
    catch {
        Write-Warning "[ERROR] $($file.FullName): $_"
        $errors++
        if ($image) { $image.Dispose() }
        if ($ms) { $ms.Dispose() }
        if (Test-Path "$($file.FullName).tmp") {
            Remove-Item "$($file.FullName).tmp" -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "`n--- Summary ---"
Write-Host "Fixed:   $fixed"
Write-Host "Skipped: $skipped (already normal)"
Write-Host "Errors:  $errors"
