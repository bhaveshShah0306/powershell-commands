# ==============================================================================
#  Restore-FromChunks.ps1
#  1. Scans the chunk folder for all .tar.gz parts
#  2. Merges them back into a single tar.gz
#  3. Extracts to the destination folder (preserving folder structure)
#  4. Cleans up the merged tar.gz
#
#  Run this on the DESTINATION machine (your local PC).
#  Usage:  .\Restore-FromChunks.ps1
#  Requirements: Windows 10 / 11 (tar.exe built-in)
# ==============================================================================

# ── CONFIG (edit these) ───────────────────────────────────────────────────────

$ChunkDir   = "C:\Downloads\Uploads_Chunks"    # Folder containing the chunk files
$MergedFile = "C:\Temp\Uploads_merged.tar.gz"  # Temp path for the merged tar.gz
$ExtractTo  = "C:\Restored"                    # Final extraction destination
                                               # Result: C:\Restored\Uploads\AdvBanners, Banners, Images, PDF...

# ── PREFLIGHT ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        Restore-FromChunks.ps1               ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Chunks  : $ChunkDir"
Write-Host "  Extract : $ExtractTo"
Write-Host ""

if (-not (Test-Path $ChunkDir)) {
    Write-Host "ERROR: Chunk folder not found: $ChunkDir" -ForegroundColor Red
    exit 1
}

$chunks = Get-ChildItem "$ChunkDir\*.tar.gz" | Sort-Object Name

if ($chunks.Count -eq 0) {
    Write-Host "ERROR: No .tar.gz chunk files found in: $ChunkDir" -ForegroundColor Red
    exit 1
}

Write-Host "  Found $($chunks.Count) chunk(s):"
Write-Host ""
$chunks | ForEach-Object {
    Write-Host "    $($_.Name)  ($([Math]::Round($_.Length/1MB,1)) MB)"
}

$totalMB = [Math]::Round(($chunks | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
Write-Host ""
Write-Host "  Total size : $totalMB MB  ($([Math]::Round($totalMB/1024,2)) GB)"
Write-Host ""

# Check free space
$freeGB = [Math]::Round((Get-PSDrive ($ExtractTo[0])).Free / 1GB, 2)
Write-Host "  Free on $($ExtractTo[0]): : $freeGB GB"
Write-Host ""

# ── STEP 1: MERGE CHUNKS ──────────────────────────────────────────────────────

Write-Host "[$( Get-Date -Format 'HH:mm:ss')] STEP 1/2 -- Merging $($chunks.Count) chunks..." -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Path (Split-Path $MergedFile) -Force | Out-Null
if (Test-Path $MergedFile) { Remove-Item $MergedFile -Force }

$sw  = [System.Diagnostics.Stopwatch]::StartNew()
$out = [System.IO.File]::OpenWrite($MergedFile)

foreach ($chunk in $chunks) {
    $bytes = [System.IO.File]::ReadAllBytes($chunk.FullName)
    $out.Write($bytes, 0, $bytes.Length)
    Write-Host "  OK  Merged: $($chunk.Name)"
}
$out.Close()

$mergedGB = [Math]::Round((Get-Item $MergedFile).Length / 1GB, 2)
Write-Host ""
Write-Host "  OK  Merged file: $mergedGB GB" -ForegroundColor Green
Write-Host ""

# ── STEP 2: EXTRACT ───────────────────────────────────────────────────────────

Write-Host "[$( Get-Date -Format 'HH:mm:ss')] STEP 2/2 -- Extracting..." -ForegroundColor Cyan
Write-Host "  (This may take several minutes for large archives)"
Write-Host ""

New-Item -ItemType Directory -Path $ExtractTo -Force | Out-Null
tar -xzf $MergedFile -C $ExtractTo

$sw.Stop()

# ── CLEANUP ───────────────────────────────────────────────────────────────────

Remove-Item $MergedFile -Force
Write-Host "  Temp merged file removed." -ForegroundColor DarkGray

# ── VERIFY ────────────────────────────────────────────────────────────────────

$extractedFiles   = (Get-ChildItem $ExtractTo -Recurse -File).Count
$extractedFolders = (Get-ChildItem $ExtractTo -Recurse -Directory).Count

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║               ALL DONE                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "  Extracted to  : $ExtractTo"
Write-Host "  Files          : $extractedFiles"
Write-Host "  Folders        : $extractedFolders"
Write-Host "  Total time     : $([Math]::Round($sw.Elapsed.TotalMinutes,1)) min"
Write-Host ""
