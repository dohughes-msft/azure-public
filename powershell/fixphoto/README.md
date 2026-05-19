# Fix Image Orientation

## The Problem

When you take photos on an iPhone and transfer them via OneDrive to a Windows PC, some applications display the images rotated (90°, 180°, or 270°). Windows Explorer and Photos show them correctly, but other apps don't.

This happens because iPhones don't physically rotate the image pixels when you hold the phone in different orientations. Instead, they store an **EXIF Orientation tag** (tag `0x0112`) in the image metadata that tells apps how to rotate the image for display. Apps that respect this tag show the image correctly; apps that ignore it show the raw (unrotated) pixels.

### EXIF Orientation Values

| Value | Meaning |
|-------|---------|
| 1 | Normal (no rotation needed) |
| 2 | Flipped horizontally |
| 3 | Rotated 180° |
| 4 | Flipped vertically |
| 5 | Rotated 90° CW + flipped horizontally |
| 6 | Rotated 90° clockwise |
| 7 | Rotated 90° CCW + flipped horizontally |
| 8 | Rotated 90° counter-clockwise |

## The Solution

`fix_image_orientation.ps1` physically rotates the image pixels to match the orientation tag, then resets the tag to `1` (normal). After this, all applications will display the image correctly regardless of whether they read EXIF metadata.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- No external modules required (uses built-in `System.Drawing` .NET assembly)
- Script execution must be enabled (see below)

## Enabling Script Execution

By default, Windows blocks PowerShell scripts from running. The safest way to allow local scripts while still blocking untrusted scripts from the internet is to set the execution policy to **RemoteSigned** for the current PowerShell session only:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
```

This means:
- **Local scripts** (like this one) will run without restriction
- **Downloaded scripts** must be digitally signed by a trusted publisher to run
- The `-Scope Process` flag applies this only to the current PowerShell session — once you close the window, the policy reverts automatically

To verify your current policy:

```powershell
Get-ExecutionPolicy -List
```

If you prefer an even more restrictive one-time approach, you can bypass the policy for a single session without permanently changing it:

```powershell
powershell -ExecutionPolicy Bypass -File .\fix_image_orientation.ps1 -Path "C:\Photos"
```

> **Note:** `Bypass` disables all restrictions for that single invocation. Use `RemoteSigned` for a safer persistent setting.

## Usage

```powershell
# Fix all JPGs in a folder
.\fix_image_orientation.ps1 -Path "C:\Photos"

# Include subfolders
.\fix_image_orientation.ps1 -Path "C:\Photos" -Recurse

# Fix a single file
.\fix_image_orientation.ps1 -Path "C:\Photos\IMG_1234.jpg"

# Preview changes without modifying anything
.\fix_image_orientation.ps1 -Path "C:\Photos" -WhatIf

# Use a custom backup folder name
.\fix_image_orientation.ps1 -Path "C:\Photos" -BackupFolder "backup"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Path` | Yes | — | Path to a folder containing JPG files, or a single JPG file |
| `-Recurse` | No | Off | Process JPG files in subdirectories |
| `-BackupFolder` | No | `originals` | Name of the subfolder for storing backup copies of original files |
| `-WhatIf` | No | Off | Report what would be changed without modifying files |

## How It Works

1. Scans the target path for `.jpg` / `.jpeg` files
2. Reads the EXIF Orientation tag from each image
3. Skips images that already have orientation = 1 (normal)
4. For images that need fixing:
   - Creates a backup subfolder (default: `originals`) in the same directory as the source file
   - Copies the original file into the backup folder
   - Physically rotates the image pixels to match the orientation
   - Resets the EXIF orientation tag to 1
   - Saves the corrected image in the original location
5. Prints a summary of fixed, skipped, and errored files

## Backup & Safety

- Original files are **always backed up** before modification
- Backups are stored in a subfolder (default `originals`) relative to each image's directory
- The script writes to a temp file first and only replaces the original on successful save
- Use `-WhatIf` to preview which files would be affected before committing

## Example Output

```
Found 5 JPG file(s) to analyze.

[SKIP] C:\Photos\IMG_001.jpg - already normal orientation
[FIXING] C:\Photos\IMG_002.jpg - orientation: Rotated 90 CW
[FIXING] C:\Photos\IMG_003.jpg - orientation: Rotated 180
[SKIP] C:\Photos\IMG_004.jpg - already normal orientation
[FIXING] C:\Photos\IMG_005.jpg - orientation: Rotated 90 CCW

--- Summary ---
Fixed:   3
Skipped: 2 (already normal)
Errors:  0
```

After running, the folder structure looks like:

```
C:\Photos\
├── IMG_001.jpg          (unchanged - was already normal)
├── IMG_002.jpg          (fixed - pixels rotated, tag reset)
├── IMG_003.jpg          (fixed)
├── IMG_004.jpg          (unchanged)
├── IMG_005.jpg          (fixed)
└── originals\
    ├── IMG_002.jpg      (original backup)
    ├── IMG_003.jpg      (original backup)
    └── IMG_005.jpg      (original backup)
```
