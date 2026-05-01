# ==============================================================================
#  Compress-AndChunk.ps1
#  1. Opens a NEW PowerShell window that polls tar.gz size every 5 seconds
#  2. Compresses the source folder using tar
#  3. Splits the tar.gz into fixed-size chunks
#  4. Cleans up the temp tar.gz
#
#  Run this on the SOURCE machine (e.g. your Windows Server).
#  Usage:  .\Compress-AndChunk.ps1
#  Requirements: Windows 10 / Server 2019 or later (tar.exe built-in)
# ==============================================================================

# ── CONFIG (edit these) ───────────────────────────────────────────────────────

$SourceParent = "C:\inetpub\wwwroot\SriRudra_Prod_API"   # Parent of the folder
$FolderName   = "Uploads"                                 # Folder name to compress
$TempDir      = "C:\Temp"                                 # Working directory
$ChunkDir     = "C:\Temp\Uploads_Chunks"                  # Where chunks are saved
$ChunkSizeMB  = 300                                       # Chunk size in MB

# ── DERIVED ───────────────────────────────────────────────────────────────────

$SourceFolder = Join-Path $SourceParent $FolderName
$TarFile      = "$TempDir\Uploads.tar.gz"

# ── PREFLIGHT ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         Compress-AndChunk.ps1               ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Source  : $SourceFolder"
Write-Host "  Chunks  : $ChunkDir  ($ChunkSizeMB MB each)"
Write-Host ""

if (-not (Test-Path $SourceFolder)) {
    Write-Host "ERROR: Source folder not found: $SourceFolder" -ForegroundColor Red
    exit 1
}

$srcBytes = (Get-ChildItem $SourceFolder -Recurse -File | Measure-Object -Property Length -Sum).Sum
$srcGB    = [Math]::Round($srcBytes / 1GB, 2)
$freeGB   = [Math]::Round((Get-PSDrive C).Free / 1GB, 2)

Write-Host "  Source size : $srcGB GB"
Write-Host "  Free on C:  : $freeGB GB"

if ((Get-PSDrive C).Free -lt $srcBytes * 1.5) {
    Write-Host "  !! Low disk space -- need ~$([Math]::Round($srcGB * 1.5,1)) GB free." -ForegroundColor Yellow
}

# ── PREP ──────────────────────────────────────────────────────────────────────

New-Item -ItemType Directory -Path $TempDir  -Force | Out-Null
New-Item -ItemType Directory -Path $ChunkDir -Force | Out-Null
if (Test-Path $TarFile) { Remove-Item $TarFile -Force }

# ── OPEN LIVE MONITOR IN A NEW WINDOW ─────────────────────────────────────────

Write-Host ""
Write-Host "[$( Get-Date -Format 'HH:mm:ss')] Opening live progress monitor in a new window..." -ForegroundColor Cyan

# Build the monitor script as a single encoded command so quoting is clean
$monitorBlock = {
    param($tf, $sg)
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║   Live Compression Progress Monitor  ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "  Source: $sg GB   Polling every 5s..." -ForegroundColor Cyan
    Write-Host ""
    while ($true) {
        if (Test-Path $tf) {
            $gb  = [Math]::Round((Get-Item $tf).Length / 1GB, 2)
            $pct = if ($sg -gt 0) { [Math]::Min(99, [Math]::Round($gb / $sg * 100, 1)) } else { "?" }
            Write-Host "$( Get-Date -Format 'HH:mm:ss' )  --  $gb GB written  (~$pct% done)"
        } else {
            Write-Host "$( Get-Date -Format 'HH:mm:ss' )  --  Waiting for tar.gz to appear..."
        }
        Start-Sleep 5
    }
}

$encoded = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes(
        "& { $monitorBlock } -tf '$TarFile' -sg $srcGB"
    )
)
Start-Process powershell.exe -ArgumentList "-NoExit", "-EncodedCommand", $encoded

# ── STEP 1: COMPRESS ──────────────────────────────────────────────────────────

Write-Host "[$( Get-Date -Format 'HH:mm:ss')] STEP 1/2 -- Compressing with tar (AppPool can stay running)..." -ForegroundColor Cyan
Write-Host ""

$sw = [System.Diagnostics.Stopwatch]::StartNew()
tar -czf $TarFile -C $SourceParent $FolderName
$sw.Stop()

$tarGB = [Math]::Round((Get-Item $TarFile).Length / 1GB, 2)
Write-Host ""
Write-Host "  OK  Compression done: $tarGB GB  (took $([Math]::Round($sw.Elapsed.TotalMinutes,1)) min)" -ForegroundColor Green
Write-Host "  You can close the monitor window now." -ForegroundColor DarkGray
Write-Host ""

# ── STEP 2: SPLIT ─────────────────────────────────────────────────────────────

Write-Host "[$( Get-Date -Format 'HH:mm:ss')] STEP 2/2 -- Splitting into $ChunkSizeMB MB chunks..." -ForegroundColor Cyan
Write-Host ""

$chunkSize = $ChunkSizeMB * 1MB
$stream    = [System.IO.File]::OpenRead($TarFile)
$buffer    = New-Object byte[] $chunkSize
$i         = 1

while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
    $chunkPath = "$ChunkDir\Uploads.part$( '{0:D3}' -f $i ).tar.gz"
    $fs = [System.IO.File]::OpenWrite($chunkPath)
    $fs.Write($buffer, 0, $read)
    $fs.Close()
    Write-Host "  OK  Chunk $i -- $([Math]::Round($read/1MB,1)) MB  ->  $( Split-Path $chunkPath -Leaf )"
    $i++
}
$stream.Close()

# ── CLEANUP ───────────────────────────────────────────────────────────────────

Remove-Item $TarFile -Force
Write-Host ""
Write-Host "  Temp tar.gz removed." -ForegroundColor DarkGray

# ── DONE ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║               ALL DONE                      ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "  $($i-1) chunk(s) saved to : $ChunkDir"
Write-Host "  Total time             : $([Math]::Round($sw.Elapsed.TotalMinutes,1)) min"
Write-Host ""
Write-Host "  Next: Copy the Uploads_Chunks folder to your local machine"
Write-Host "        and run  Restore-FromChunks.ps1"
Write-Host ""
