<#
.SYNOPSIS
  Builds the VoiceBox Python backend into a self-contained Windows executable.
  Run this from the voicebox-app root directory ONCE before packaging with electron-builder.

.OUTPUTS
  voicebox-be/dist/voicebox_backend/voicebox_backend.exe   <- main binary
  (plus _internal/ folder with all dependencies)

.NOTES
  Requires Python 3.10+, pip, and all voicebox-be dependencies installed.
  The resulting folder is bundled by electron-builder into resources/backend/.
#>

param(
  [string]$PythonCmd = "python",
  [switch]$Clean
)

$ErrorActionPreference = "Stop"

if ($PSScriptRoot) {
  $root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} else {
  $root = (Get-Location).Path
}

$beDir   = Join-Path $root "voicebox-be"
$distDir = Join-Path $beDir "dist"

Write-Host ""
Write-Host "VoiceBox -- Windows Backend Build" -ForegroundColor Cyan
Write-Host "Backend dir : $beDir"
Write-Host "Output dir  : $distDir"
Write-Host ""

# -- Prefer local venv if present ----------------------------------------------
$venvPython = Join-Path $beDir ".venv\Scripts\python.exe"
if (Test-Path $venvPython) {
  $PythonCmd = $venvPython
  Write-Host "Using venv: $venvPython" -ForegroundColor Green
} else {
  try {
    $ver = & $PythonCmd --version 2>&1
    Write-Host "Using global $ver (create voicebox-be\.venv to reduce bundle size)" -ForegroundColor Yellow
  } catch {
    Write-Error "Python not found. Install Python 3.10+ and add it to PATH."
    exit 1
  }
}

# -- Clean previous build ------------------------------------------------------
if ($Clean -and (Test-Path $distDir)) {
  Write-Host "Cleaning previous build..." -ForegroundColor Yellow
  Remove-Item $distDir -Recurse -Force
}

# -- Install / upgrade PyInstaller ---------------------------------------------
Write-Host "Checking PyInstaller..."
& $PythonCmd -m pip install --quiet --upgrade pyinstaller

# -- Run PyInstaller (from within voicebox-be so relative paths resolve) ------
Write-Host ""
Write-Host "Running PyInstaller (this can take several minutes)..." -ForegroundColor Cyan

Push-Location $beDir
try {
  # Use (Get-Location).Path to get the canonical absolute path that PowerShell
  # resolved when navigating here.  This avoids any ambiguity from '..' chars
  # in parent directory names when PyInstaller resolves --add-data sources.
  $cwd = (Get-Location).Path

  $chaplinSrc = Join-Path $cwd "chaplin"
  if (-not (Test-Path $chaplinSrc)) {
    throw "chaplin/ directory not found at: $chaplinSrc -- run chaplin\setup.ps1 first"
  }

  $taskSrc = Join-Path $cwd "face_landmarker.task"
  # Stage chaplin WITHOUT benchmarks/. That folder holds the two model.pth
  # files (955 + 205 MB); bundling it makes the installer ~2.4 GB. The weights
  # ship as the vsr-chaplin-lrs3.zip release asset and are fetched on first
  # run (model_assets.py), unpacking back into chaplin/benchmarks.
  $chaplinStage = Join-Path $cwd "build\chaplin_stage"
  if (Test-Path $chaplinStage) { Remove-Item $chaplinStage -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $chaplinStage | Out-Null
  # robocopy exit codes 0-7 mean success; 8+ means failure.
  & robocopy $chaplinSrc $chaplinStage /E /XD benchmarks __pycache__ .git /XF *.pth *.ckpt /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed staging chaplin (exit $LASTEXITCODE)" }
  $global:LASTEXITCODE = 0
  $addDataArgs = @("--add-data", "$chaplinStage;chaplin")
  if (Test-Path $taskSrc) {
    $addDataArgs += @("--add-data", "$taskSrc;.")
  }

  $pyArgs = @(
    "-m", "PyInstaller",
    "--onedir",
    "--name", "voicebox_backend",
    "--distpath", $distDir,
    "--workpath", (Join-Path $cwd "build"),
    "--specpath", (Join-Path $cwd "build"),
    "--noconfirm",
    "--hidden-import", "sounddevice",
    "--hidden-import", "pyttsx3",
    "--hidden-import", "pyttsx3.drivers",
    "--hidden-import", "pyttsx3.drivers.sapi5",
    "--hidden-import", "starlette",
    "--hidden-import", "uvicorn",
    "--hidden-import", "uvicorn.lifespan.on",
    "--hidden-import", "uvicorn.protocols.http.auto",
    "--hidden-import", "uvicorn.protocols.websockets.auto",
    "--hidden-import", "uvicorn.loops.auto",
    "--hidden-import", "ollama",
    "--hidden-import", "httpx",
    "--hidden-import", "httpx._transports.default",
    "--hidden-import", "chaplin_real_backend",
    "--collect-all", "faster_whisper",
    "--collect-all", "mediapipe",
    "--collect-all", "cv2",
    "--collect-data", "faster_whisper",
    # --- size exclusions ------------------------------------------------
    # jax/jaxlib arrive only as a transitive dependency of mediapipe and are
    # imported by nothing in this project (verified: zero `import jax` across
    # voicebox-be/ including the vendored chaplin and espnet trees). They
    # measured 209.5 MB of the 2.44 GB bundle, so excluding them is the single
    # largest free saving available.
    #
    # If a future mediapipe solution genuinely needs jax, the backend will
    # fail at import with ModuleNotFoundError: jax - drop these two lines
    # rather than guessing.
    "--exclude-module", "jax",
    "--exclude-module", "jaxlib",
    # Test suites and notebook machinery that ride along with torch/scipy and
    # are never reached at runtime.
    "--exclude-module", "torch.testing",
    "--exclude-module", "tkinter",
    "--exclude-module", "IPython",
    "--exclude-module", "notebook",
    "--exclude-module", "pytest"
  ) + $addDataArgs + @("raw_web_app.py")

  & $PythonCmd @pyArgs
  if ($LASTEXITCODE -ne 0) { throw "PyInstaller exited with code $LASTEXITCODE" }
} finally {
  Pop-Location
}

$binPath = Join-Path $distDir "voicebox_backend\voicebox_backend.exe"
if (-not (Test-Path $binPath)) {
  Write-Error "Build failed -- output binary not found at expected path: $binPath"
  exit 1
}

# -- Fix VC++ runtime DLL conflict ---------------------------------------------
# PyInstaller bundles MSVCP140.dll (v14.36, from Python) alongside
# VCRUNTIME140.dll (v14.38, from PyTorch/ctranslate2).  This version mismatch
# causes an access-violation crash (0xc0000005) on startup before Python runs.
# Windows 10/11 ships v14.38+ in System32 (backward-compatible), so we delete
# the bundled copies and let the OS supply matching DLLs at runtime.
Write-Host ""
Write-Host "Removing mismatched VC++ runtime DLLs from bundle..." -ForegroundColor Cyan
$internalDir = Join-Path $distDir "voicebox_backend\_internal"
$vcDlls = @(
  "msvcp140.dll", "MSVCP140.dll",
  "msvcp140_1.dll", "MSVCP140_1.dll",
  "msvcp140_atomic_wait.dll", "MSVCP140_ATOMIC_WAIT.dll",
  "vcruntime140.dll", "VCRUNTIME140.dll",
  "vcruntime140_1.dll", "VCRUNTIME140_1.dll"
)
foreach ($dll in $vcDlls) {
  $p = Join-Path $internalDir $dll
  if (Test-Path $p) {
    Remove-Item $p -Force
    Write-Host "  Removed: $dll" -ForegroundColor DarkGray
  }
}

Write-Host ""
Write-Host "Build successful!" -ForegroundColor Green
Write-Host "Binary : $binPath"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Build the frontend: cd voicebox && npm run build"
Write-Host "  2. Package the Electron app: cd electron && npm run build:win"
