param(
    [string]$BackendHost = "127.0.0.1",
    [string]$BackendPort = "8765",
    [string]$FrontendHost = "localhost"
)

$ErrorActionPreference = "Stop"

# Resolve script root robustly even when invoked from unusual contexts.
$scriptPath = $MyInvocation.MyCommand.Path
$root = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($scriptPath) {
    Split-Path -Parent $scriptPath
}
else {
    (Get-Location).Path
}

try {
    $root = (Resolve-Path -LiteralPath $root).Path
}
catch {
    throw "Could not resolve launcher root path: $root"
}

$backendDir = Join-Path $root "voicebox-be"
$frontendDir = Join-Path $root "voicebox"
$backendLauncher = Join-Path $backendDir "launch_voicebox_raw.ps1"
$backendLogFile = Join-Path $backendDir "logs\backend-launch-latest.log"

if (-not (Test-Path -LiteralPath $backendLauncher)) {
    throw "Backend launcher not found: $backendLauncher`nResolved root: $root`nExpected backend folder: $backendDir"
}

if (-not (Test-Path -LiteralPath (Join-Path $frontendDir "package.json"))) {
    throw "Frontend package.json not found: $frontendDir"
}

Write-Host "Starting VoiceBox backend..."
$backendArgs = "-NoExit -ExecutionPolicy Bypass -File `"$backendLauncher`" -HostName `"$BackendHost`" -Port `"$BackendPort`""
$backendProcess = Start-Process -FilePath "powershell.exe" `
    -WorkingDirectory $backendDir `
    -ArgumentList $backendArgs `
    -PassThru

$backendReady = $false
$backendStatusUrl = "http://$BackendHost`:$BackendPort/api/status"
$deadline = (Get-Date).AddSeconds(25)

while ((Get-Date) -lt $deadline) {
    try {
        $null = Invoke-RestMethod -Uri $backendStatusUrl -Method Get -TimeoutSec 2
        $backendReady = $true
        break
    }
    catch {
        Start-Sleep -Milliseconds 600
    }
}

if ($backendReady) {
    Write-Host "Backend is ready at $backendStatusUrl"
}
else {
    Write-Warning "Backend did not become ready at $backendStatusUrl"
    if ($backendProcess -and $backendProcess.HasExited) {
        Write-Warning "Backend process exited with code $($backendProcess.ExitCode)"
    }
    if (Test-Path -LiteralPath $backendLogFile) {
        Write-Host "Showing last 60 lines from backend log: $backendLogFile"
        Get-Content -LiteralPath $backendLogFile -Tail 60
    }
    else {
        Write-Warning "Backend log not found yet: $backendLogFile"
    }
}

Write-Host "Starting VoiceBox frontend..."
$frontendArgs = "-NoExit -ExecutionPolicy Bypass -Command `"npm.cmd run dev -- --host $FrontendHost`""
Start-Process -FilePath "powershell.exe" `
    -WorkingDirectory $frontendDir `
    -ArgumentList $frontendArgs

Write-Host ""
Write-Host "VoiceBox is launching."
Write-Host "Frontend: http://localhost:8080"
Write-Host "Backend:  http://$BackendHost`:$BackendPort"
Write-Host ""
Write-Host "Keep the opened PowerShell windows running while using the app."
