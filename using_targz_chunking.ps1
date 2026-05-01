# ==============================================================================
#  Backup-AndChunk.ps1
#  Compress a large folder into a .tar.gz and split into fixed-size chunks.
#  Includes a live progress monitor and a restore routine.
#
#  Usage:
#    1. Edit the CONFIG section below.
#    2. Run in an elevated (Administrator) PowerShell window.
#    3. To restore, run the script with the -Restore switch:
#         .\Backup-AndChunk.ps1 -Restore
#
#  Requirements: Windows 10 / Server 2019 or later (tar.exe built-in)
# ==============================================================================

param(
    [switch]$Restore
)

# ── CONFIG ────────────────────────────────────────────────────────────────────

$AppPoolName  = "{Your source App pool folder/ app pool}"                              # IIS AppPool name (leave empty "" to skip)
$SourceFolder = "C:\inetpub\wwwroot\{Your source App pool folder/ app pool}\{Source-Folder}"  # Folder to compress
$SourceParent = "C:\inetpub\wwwroot\{Your source App pool folder/ app pool}"          # Parent of the folder above
$FolderName   = "{Source-Folder}"                                        # Just the folder name

$TempDir      = "C:\Temp"                                        # Temp working directory
$TarFile      = "$TempDir\{Source-Folder}.tar.gz"                        # Output tar.gz path
$ChunkDir     = "$TempDir\{Source-Folder}_Chunks"                        # Where chunks are saved
$ChunkSizeMB  = 300                                              # Chunk size in MB

# Restore-side config (edit before running -Restore)
$RestoreChunkDir = "C:\Downloads\{Source-Folder}_Chunks"                 # Folder with .tar.gz chunk files
$RestoreMerged   = "C:\Downloads\{Source-Folder}_merged.tar.gz"          # Merged tar.gz path
$RestoreTo       = "C:\Restored"                                 # Final extraction destination

# ── HELPERS ───────────────────────────────────────────────────────────────────

function Write-Step($msg) {
    Write-Host "`n[$([DateTime]::Now.ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan
}

function Write-OK($msg) {
    Write-Host "  ✔  $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "  ⚠  $msg" -ForegroundColor Yellow
}

function Stop-AppPool {
    if (-not $AppPoolName) { return }
    Write-Step "Stopping AppPool: $AppPoolName"
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    if (Get-WebAppPoolState -Name $AppPoolName -ErrorAction SilentlyContinue) {
        Stop-WebAppPool -Name $AppPoolName
        Start-Sleep 2
        Write-OK "AppPool stopped."
    } else {
        Write-Warn "AppPool '$AppPoolName' not found — skipping."
    }
}

function Start-AppPool {
    if (-not $AppPoolName) { return }
    Write-Step "Restarting AppPool: $AppPoolName"
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Start-WebAppPool -Name $AppPoolName
    Write-OK "AppPool started."
}

function Watch-Progress($filePath, $totalSourceGB) {
    # Runs in a background job — prints file size every 5 seconds
    $job = Start-Job -ScriptBlock {
        param($path, $srcGB)
        while ($true) {
            if (Test-Path $path) {
                $gb = (Get-Item $path).Length / 1GB
                $pct = if ($srcGB -gt 0) { [Math]::Min(99, [Math]::Round($gb / $srcGB * 100, 1)) } else { "?" }
                Write-Host "$([DateTime]::Now.ToString('HH:mm:ss'))  —  $([Math]::Round($gb,2)) GB  (~$pct%)"
            }
            Start-Sleep 5
        }
    } -ArgumentList $filePath, $totalSourceGB
    return $job
}

# ── RESTORE MODE ──────────────────────────────────────────────────────────────

if ($Restore) {
    Write-Step "RESTORE MODE"

    # Merge chunks
    Write-Step "Merging chunks from: $RestoreChunkDir"
    $chunks = Get-ChildItem "$RestoreChunkDir\*.tar.gz" | Sort-Object Name
    if ($chunks.Count -eq 0) {
        Write-Host "  No .tar.gz chunk files found in $RestoreChunkDir" -ForegroundColor Red
        exit 1
    }

    $out = [System.IO.File]::OpenWrite($RestoreMerged)
    foreach ($chunk in $chunks) {
        $bytes = [System.IO.File]::ReadAllBytes($chunk.FullName)
        $out.Write($bytes, 0, $bytes.Length)
        Write-OK "Merged: $($chunk.Name)"
    }
    $out.Close()
    Write-OK "Merged file: $RestoreMerged ($([Math]::Round((Get-Item $RestoreMerged).Length/1GB,2)) GB)"

    # Extract
    Write-Step "Extracting to: $RestoreTo"
    New-Item -ItemType Directory -Path $RestoreTo -Force | Out-Null
    tar -xzf $RestoreMerged -C $RestoreTo
    Write-OK "Extraction complete. Files are in: $RestoreTo"

    # Cleanup
    Remove-Item $RestoreMerged -Force
    Write-OK "Cleaned up merged tar.gz."
    exit 0
}

# ── BACKUP MODE ───────────────────────────────────────────────────────────────

Write-Host @"
╔══════════════════════════════════════════════════════╗
║           Backup-AndChunk.ps1  —  BACKUP MODE       ║
╚══════════════════════════════════════════════════════╝
  Source  : $SourceFolder
  Output  : $ChunkDir
  Chunks  : $ChunkSizeMB MB each
"@ -ForegroundColor Cyan

# Check source exists
if (-not (Test-Path $SourceFolder)) {
    Write-Host "ERROR: Source folder not found: $SourceFolder" -ForegroundColor Red
    exit 1
}

# Check free space (need ~source size × 2 for tar + chunks)
$srcBytes  = (Get-ChildItem $SourceFolder -Recurse -File | Measure-Object -Property Length -Sum).Sum
$srcGB     = [Math]::Round($srcBytes / 1GB, 2)
$freeBytes = (Get-PSDrive C).Free
$freeGB    = [Math]::Round($freeBytes / 1GB, 2)
Write-Host "  Source size : $srcGB GB"
Write-Host "  Free on C:  : $freeGB GB"

if ($freeBytes -lt $srcBytes * 1.5) {
    Write-Warn "Low disk space! You may need ~$([Math]::Round($srcGB * 1.5, 1)) GB free. Proceeding anyway..."
}

# Prepare dirs
New-Item -ItemType Directory -Path $TempDir  -Force | Out-Null
New-Item -ItemType Directory -Path $ChunkDir -Force | Out-Null

# Remove leftover tar if exists
if (Test-Path $TarFile) { Remove-Item $TarFile -Force }

# STEP 1: Compress
Write-Step "STEP 1/2 — Compressing with tar (no AppPool stop needed)..."
$progressJob = Watch-Progress $TarFile $srcGB

$sw = [System.Diagnostics.Stopwatch]::StartNew()
tar -czf $TarFile -C $SourceParent $FolderName
$sw.Stop()

Stop-Job $progressJob | Out-Null
Remove-Job $progressJob | Out-Null

$tarGB = [Math]::Round((Get-Item $TarFile).Length / 1GB, 2)
Write-OK "Compressed: $tarGB GB  (took $([Math]::Round($sw.Elapsed.TotalMinutes,1)) min)"

# STEP 2: Split into chunks
Write-Step "STEP 2/2 — Splitting into $ChunkSizeMB MB chunks..."
$chunkSize = $ChunkSizeMB * 1MB
$stream    = [System.IO.File]::OpenRead($TarFile)
$buffer    = New-Object byte[] $chunkSize
$i         = 1

while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
    $chunkPath = "$ChunkDir\{Source-Folder}.part$('{0:D3}' -f $i).tar.gz"
    $fs = [System.IO.File]::OpenWrite($chunkPath)
    $fs.Write($buffer, 0, $read)
    $fs.Close()
    Write-OK "Chunk $i — $([Math]::Round($read/1MB,1)) MB  →  $(Split-Path $chunkPath -Leaf)"
    $i++
}
$stream.Close()

# Cleanup temp tar
Remove-Item $TarFile -Force

Write-Host @"

╔══════════════════════════════════════════════════════╗
║                    ALL DONE ✔                       ║
╚══════════════════════════════════════════════════════╝
  $($i-1) chunks saved to : $ChunkDir
  Total time            : $([Math]::Round($sw.Elapsed.TotalMinutes,1)) min

  To restore on another machine:
    1. Copy the {Source-Folder}_Chunks folder
    2. Edit -RestoreChunkDir / -RestoreTo in this script
    3. Run:  .\Backup-AndChunk.ps1 -Restore
"@ -ForegroundColor Green
