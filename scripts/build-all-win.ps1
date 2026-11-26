<#
.SYNOPSIS
  Full release build for Windows. Run from the voicebox-app root directory.
  Backend is skipped automatically if the binary already exists.

.EXAMPLE
  .\scripts\build-all-win.ps1
  .\scripts\build-all-win.ps1 -SkipBackend
  .\scripts\build-all-win.ps1 -SkipFrontend
#>

param(
  [string]$PythonCmd  = "python",
  [switch]$SkipBackend,
  [switch]$SkipFrontend
)

$ErrorActionPreference = "Stop"

if ($PSScriptRoot) {
  $root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} else {
  $root = (Get-Location).Path
}

function Step($n, $title) {
  Write-Host ""
  Write-Host "=== Step $n -- $title ===" -ForegroundColor Cyan
}

# -- Step 1: Python backend --------------------------------------------------
$backendBin = Join-Path $root "voicebox-be\dist\voicebox_backend\voicebox_backend.exe"

if ($SkipBackend) {
  Write-Host "(Skipping backend - SkipBackend flag set)" -ForegroundColor Yellow
} elseif (Test-Path $backendBin) {
  Write-Host "(Skipping backend - binary already exists)" -ForegroundColor Yellow
  Write-Host "  Delete voicebox-be\dist\ to force a rebuild." -ForegroundColor DarkGray
} else {
  Step 1 "Build Python backend (PyInstaller)"
  & (Join-Path $root "scripts\build-backend-win.ps1") -PythonCmd $PythonCmd
}

# -- Step 2: Frontend --------------------------------------------------------
if (-not $SkipFrontend) {
  Step 2 "Build frontend (TanStack Start Vite SSR)"
  $voiceboxDir = Join-Path $root "voicebox"

  Push-Location $voiceboxDir
  try {
    Write-Host "Installing dependencies..."
    npm install --silent

    Write-Host "Building..."
    npm run build
    Remove-Item Env:NITRO_PRESET -ErrorAction SilentlyContinue

    if (-not (Test-Path (Join-Path $voiceboxDir "dist\server\server.js"))) {
      throw "Frontend build did not produce dist\server\server.js"
    }

    # Tell Node.js that all .js files in the frontend dist are ES modules.
    # Without this, Electron's Node runtime treats server.js as CommonJS and
    # chokes on the ESM 'export' syntax.
    '{"type":"module"}' | Set-Content (Join-Path $voiceboxDir "dist\package.json") -Encoding utf8
    Write-Host "Frontend build successful." -ForegroundColor Green
  } finally {
    Pop-Location
  }
}

# -- Step 3: Electron packaging ----------------------------------------------
Step 3 "Package Electron app (Windows NSIS installer)"
$electronDir = Join-Path $root "electron"

Push-Location $electronDir
try {
  Write-Host "Installing Electron dependencies..."
  npm install --silent

  Write-Host "Running electron-builder..."
  npm run build:win
  Write-Host "Electron build successful." -ForegroundColor Green
} finally {
  Pop-Location
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Build complete!" -ForegroundColor Green
Write-Host "  Installer: electron\dist\VoiceBox Setup *.exe" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
