# Build the VoiceBox model pack for a GitHub release.
#
#   powershell -ExecutionPolicy Bypass -File scripts\pack-models.ps1
#
# Produces three zips in dist-models\ plus their SHA-256 hashes, which you
# paste into the ASSETS table in voicebox-be\model_assets.py before cutting
# the release.
#
# Why this exists: the weights cannot go in the git repo (GitHub rejects any
# single file over 100 MB; the lip-reading model alone is 955 MB). They are
# published as GitHub *release assets* instead, which allow 2 GB per file with
# no total cap, and the app fetches them once on first run.
#
# Keep this file ASCII-only and saved UTF-8 WITH BOM - PowerShell 5.1 decodes
# a BOM-less file as CP1252, where a UTF-8 em-dash turns into a curly quote
# that PowerShell accepts as a string delimiter.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$beDir = Join-Path $root 'voicebox-be'
$outDir = Join-Path $root 'dist-models'
$staging = Join-Path $env:TEMP 'voicebox-model-staging'

$hfCache = Join-Path $env:USERPROFILE '.cache\huggingface'
$modelsHome = Join-Path $beDir 'models'

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

Write-Host ""
Write-Host "Packing VoiceBox model assets" -ForegroundColor White
Write-Host "output: $outDir" -ForegroundColor DarkGray

function Resolve-HfModel ([string]$dirName) {
    # Prefer the app's own cache; fall back to the developer default.
    foreach ($base in @($modelsHome, $hfCache)) {
        $candidate = Join-Path $base "hub\$dirName"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function New-Pack ([string]$archive, [string]$stageName, [scriptblock]$fill) {
    $stage = Join-Path $staging $stageName
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $ok = & $fill $stage
    if (-not $ok) {
        Write-Host "  [SKIP]  $archive (source not found)" -ForegroundColor Yellow
        return
    }
    $zip = Join-Path $outDir $archive
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Write-Host "  packing $archive ..." -ForegroundColor DarkGray
    # -Force so a rerun overwrites; CompressionLevel Optimal matters here,
    # model weights are already dense but metadata compresses well.
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
    $mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    $sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    Write-Host ("  [ OK ]  {0}  {1} MB" -f $archive, $mb) -ForegroundColor Green
    Write-Host "          sha256 = $sha" -ForegroundColor DarkGray
    if ($mb -gt 2000) {
        Write-Host "  [WARN]  over 2 GB - GitHub release assets cap at 2 GB per file. Split it." -ForegroundColor Yellow
    }
    [pscustomobject]@{ Archive = $archive; MB = $mb; Sha256 = $sha }
}

$results = @()

# --- 1. speech recognition (faster-whisper) --------------------------------
$results += New-Pack 'asr-faster-whisper-tiny-en.zip' 'asr' {
    param($stage)
    $src = Resolve-HfModel 'models--Systran--faster-whisper-tiny.en'
    if (-not $src) { return $false }
    $dst = Join-Path $stage 'hub\models--Systran--faster-whisper-tiny.en'
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Recurse -Force
    return $true
}

# --- 2. language repair (masked LM) ----------------------------------------
# This is the default correction backend: a masked LM is the native fit for
# "fill [MASK] from context", 40x smaller and far faster than a 4B instruct
# model, and it runs fully offline.
$results += New-Pack 'corrector-distilroberta-base.zip' 'corrector' {
    param($stage)
    $src = Resolve-HfModel 'models--distilroberta-base'
    if (-not $src) { return $false }
    $dst = Join-Path $stage 'hub\models--distilroberta-base'
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    # Drop the duplicate framework copies HF leaves behind: a cached model
    # often holds pytorch_model.bin AND model.safetensors AND tf/flax
    # variants. transformers prefers safetensors, so the rest is dead weight
    # (measured 667 MB cached vs ~330 MB for safetensors alone).
    Copy-Item $src $dst -Recurse -Force
    Get-ChildItem $dst -Recurse -File -Include *.msgpack, *.h5, tf_model*, flax_model* -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $hasSafe = Get-ChildItem $dst -Recurse -File -Filter 'model.safetensors' -ErrorAction SilentlyContinue
    if ($hasSafe) {
        Get-ChildItem $dst -Recurse -File -Filter 'pytorch_model.bin' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# --- 3. lip reading (Chaplin VSR + subword LM) -----------------------------
$results += New-Pack 'vsr-chaplin-lrs3.zip' 'vsr' {
    param($stage)
    $bench = Join-Path $beDir 'chaplin\benchmarks'
    if (-not (Test-Path $bench)) { return $false }
    $dst = Join-Path $stage 'benchmarks'
    Copy-Item $bench $dst -Recurse -Force
    return $true
}

Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue

# --- summary ---------------------------------------------------------------
Write-Host ""
if (-not $results) {
    Write-Host "Nothing packed. Run the app once so the models are cached, or" -ForegroundColor Red
    Write-Host "download the Chaplin assets into voicebox-be\chaplin\benchmarks." -ForegroundColor Red
    exit 1
}

Write-Host "Paste these into ASSETS in voicebox-be\model_assets.py:" -ForegroundColor Cyan
foreach ($r in $results) {
    Write-Host ('    {0,-38} sha256="{1}"' -f $r.Archive, $r.Sha256) -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "Then publish them as release assets:" -ForegroundColor Cyan
Write-Host "    gh release create models-v1 dist-models\*.zip --title ""VoiceBox models v1"" --notes ""Model weights fetched on first run.""" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Total: {0} MB across {1} file(s)" -f ([math]::Round(($results | Measure-Object MB -Sum).Sum, 1)), $results.Count -ForegroundColor White
