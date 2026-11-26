# VoiceBox preflight check.
#
#   powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
#
# Checks every dependency the app needs to actually start, and prints what to
# do about each failure. Read-only: it installs nothing and changes nothing.

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$beDir = Join-Path $root 'voicebox-be'
$feDir = Join-Path $root 'voicebox'

$script:problems = @()

function Say-Ok    ([string]$m) { Write-Host "  [ OK ]  $m" -ForegroundColor Green }
function Say-Warn  ([string]$m) { Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Say-Fail  ([string]$m, [string]$fix) {
    Write-Host "  [FAIL]  $m" -ForegroundColor Red
    if ($fix) { Write-Host "          fix: $fix" -ForegroundColor DarkGray }
    $script:problems += $m
}
function Section ([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

Write-Host ""
Write-Host "VoiceBox doctor" -ForegroundColor White
Write-Host "root: $root" -ForegroundColor DarkGray

# ---------------------------------------------------------------- backend python
Section "Backend Python"

$venvPython = $null
foreach ($name in @('.venv311', '.venv', 'venv')) {
    $candidate = Join-Path $beDir "$name\Scripts\python.exe"
    if (Test-Path $candidate) { $venvPython = $candidate; Say-Ok "venv found: $name"; break }
}

if (-not $venvPython) {
    Say-Fail "no backend virtual environment in voicebox-be/" `
             "cd voicebox-be; python -m venv .venv311; .venv311\Scripts\python.exe -m pip install -r requirements.txt"
} else {
    $pyver = & $venvPython -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>&1
    Say-Ok "interpreter: Python $pyver"

    # numpy must stay below 2.x for the torch + mediapipe ABI.
    $npver = & $venvPython -c "import numpy; print(numpy.__version__)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Say-Fail "numpy not importable" "$venvPython -m pip install -r voicebox-be\requirements.txt"
    } elseif ($npver -match '^2\.') {
        Say-Fail "numpy $npver is 2.x - breaks the torch/mediapipe ABI" `
                 "$venvPython -m pip install 'numpy<2'"
    } else {
        Say-Ok "numpy $npver (below 2.x, correct)"
    }

    $probe = @'
import importlib, sys
mods = ["starlette","uvicorn","cv2","numpy","sounddevice","scipy","pyttsx3",
        "faster_whisper","transformers","torch","mediapipe","skimage","hydra",
        "ollama","pydantic","pynput"]
missing = []
for m in mods:
    try: importlib.import_module(m)
    except Exception: missing.append(m)
print("MISSING:" + ",".join(missing))
'@
    $out = $probe | & $venvPython - 2>&1
    $missingLine = ($out | Select-String '^MISSING:').Line
    if ($missingLine) {
        $missing = $missingLine.Substring(8).Trim()
        if ($missing) {
            Say-Fail "missing packages: $missing" `
                     "$venvPython -m pip install -r voicebox-be\requirements.txt"
        } else {
            Say-Ok "all backend packages importable"
        }
    } else {
        Say-Warn "dependency probe produced no result"
    }

    Push-Location $beDir
    $importOut = & $venvPython -c "import raw_web_app" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Say-Ok "raw_web_app imports cleanly"
    } else {
        $tail = ($importOut | Select-Object -Last 3) -join ' | '
        Say-Fail "raw_web_app fails to import: $tail" 'cd voicebox-be, then run the import by hand to see the traceback'
    }
    Pop-Location
}

# ------------------------------------------------------------------ chaplin assets
Section "Chaplin visual model"

$chaplinDir = Join-Path $beDir 'chaplin'
if (Test-Path $chaplinDir) {
    Say-Ok "chaplin/ present"
    $cfg = Join-Path $chaplinDir 'configs\LRS3_V_WER19.1.ini'
    if (Test-Path $cfg) { Say-Ok "VSR config present" }
    else { Say-Warn "configs\LRS3_V_WER19.1.ini missing - lip reading will not load" }
    $ckpts = Get-ChildItem -Path $chaplinDir -Recurse -Include *.pth, *.ckpt -ErrorAction SilentlyContinue
    if ($ckpts) { Say-Ok "$($ckpts.Count) model checkpoint(s) found" }
    else { Say-Warn "no .pth/.ckpt checkpoints - run chaplin\setup.ps1 to download (~1 GB)" }
} else {
    Say-Fail "voicebox-be\chaplin\ missing - visual speech recognition cannot run" `
             "clone/download the chaplin assets into voicebox-be\chaplin"
}

# ------------------------------------------------------------------------- the LLM
Section "LLM correction chain"

$ollamaUp = $false
try {
    $tags = Invoke-WebRequest 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3 -UseBasicParsing
    $ollamaUp = ($tags.StatusCode -eq 200)
} catch { $ollamaUp = $false }

if ($ollamaUp) {
    $models = ($tags.Content | ConvertFrom-Json).models | ForEach-Object { $_.model }
    Say-Ok "Ollama daemon reachable"
    if ($models -match '^qwen3:4b') { Say-Ok "qwen3:4b present - best-quality correction active" }
    else { Say-Warn "qwen3:4b not pulled. Run: ollama pull qwen3:4b  (models: $($models -join ', '))" }
} else {
    Say-Warn "Ollama not reachable - the app will use the offline fill-mask backend instead"
}

if ($venvPython) {
    $null = & $venvPython -c "import transformers" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Say-Ok "transformers present - offline fill-mask fallback available"
    } else {
        Say-Fail "neither Ollama nor transformers available - no LLM correction at all" `
                 "$venvPython -m pip install transformers"
    }
}

# ------------------------------------------------------------------------ frontend
Section "Frontend"

if (Test-Path (Join-Path $feDir 'node_modules')) { Say-Ok "node_modules installed" }
else { Say-Fail "voicebox\node_modules missing" "cd voicebox; npm install" }

$envLocal = Join-Path $feDir '.env.local'
if (-not (Test-Path $envLocal)) {
    Say-Fail "voicebox\.env.local missing" "copy voicebox\.env.example to .env.local and fill it in"
} else {
    Say-Ok ".env.local present"
    $map = @{}
    Get-Content $envLocal | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $v = $Matches[2].Trim()
            if ($v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
            $map[$Matches[1]] = $v
        }
    }
    foreach ($k in @('VITE_SUPABASE_URL', 'VITE_SUPABASE_PUBLISHABLE_KEY', 'VITE_VOICEBOX_API_URL')) {
        if ($map.ContainsKey($k) -and $map[$k]) { Say-Ok "$k set" }
        else { Say-Warn "$k not set" }
    }

    # Supabase reachability - the usual cause of a login that silently fails.
    if ($map['VITE_SUPABASE_URL']) {
        $sbHost = ([System.Uri]$map['VITE_SUPABASE_URL']).Host
        try {
            $null = Resolve-DnsName -Name $sbHost -ErrorAction Stop
            try {
                $s = Invoke-WebRequest "$($map['VITE_SUPABASE_URL'])/auth/v1/settings" `
                        -Headers @{ apikey = $map['VITE_SUPABASE_PUBLISHABLE_KEY'] } `
                        -TimeoutSec 10 -UseBasicParsing
                Say-Ok "Supabase auth reachable (HTTP $($s.StatusCode)) - login should work"
            } catch {
                Say-Fail "Supabase host resolves but /auth/v1/settings failed: $($_.Exception.Message)" `
                         "check the publishable key in .env.local"
            }
        } catch {
            Say-Fail "Supabase project '$sbHost' does not resolve (paused, deleted, or wrong ref)" `
                     "create a project at supabase.com and update VITE_SUPABASE_URL + VITE_SUPABASE_PUBLISHABLE_KEY; the app still runs as guest"
        }
    }
}

# ------------------------------------------------------------------------- summary
Write-Host ""
if ($script:problems.Count -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    Write-Host "Start the backend:  cd voicebox-be; .venv311\Scripts\python.exe -m uvicorn raw_web_app:app --host 127.0.0.1 --port 8765" -ForegroundColor DarkGray
    exit 0
}
Write-Host "$($script:problems.Count) problem(s) found:" -ForegroundColor Red
foreach ($p in $script:problems) { Write-Host "  - $p" -ForegroundColor Red }
exit 1
