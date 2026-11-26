# Commit and push all three VoiceBox repos in submodule order.
#
#   powershell -ExecutionPolicy Bypass -File scripts\push-all.ps1          # dry run
#   powershell -ExecutionPolicy Bypass -File scripts\push-all.ps1 -Go      # actually do it
#
# Order matters: a submodule records a COMMIT, so the inner repos must be
# committed AND pushed before the outer repo records their new SHAs. If an
# inner push fails, this stops rather than recording a pointer that nobody
# else can resolve ("fatal: remote error: upload-pack: not our ref").
#
# Keep this file ASCII-only and saved UTF-8 WITH BOM - PowerShell 5.1 decodes
# a BOM-less file as CP1252, where a UTF-8 em-dash becomes a curly quote that
# PowerShell accepts as a string delimiter.

[CmdletBinding()]
param(
    # Without -Go this only reports what it would do.
    [switch]$Go,
    [string]$BackendMessage = "Syllable-level audio/visual clash fusion, LLM corrector with offline fallback, model asset manager",
    [string]$FrontendMessage = "Actionable auth error messages, env example rewrite",
    [string]$ShellMessage = "App shell: submodules, build scripts, distribution and auth docs"
)

# 'Continue', not 'Stop'. In Windows PowerShell 5.1, redirecting a native
# command's stderr (git) wraps every stderr line in an ErrorRecord and
# sets $? to false even when git exits 0 - so git's harmless
# "LF will be replaced by CRLF" notice aborts the whole script under 'Stop'.
# This script therefore never redirects git's stderr and checks $LASTEXITCODE
# explicitly instead.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step ([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Info ([string]$t) { Write-Host "   $t" -ForegroundColor DarkGray }
function Good ([string]$t) { Write-Host "   $t" -ForegroundColor Green }
function Bad  ([string]$t) { Write-Host "   $t" -ForegroundColor Red }

if (-not $Go) {
    Write-Host ""
    Write-Host "DRY RUN - nothing will be committed or pushed. Add -Go to proceed." -ForegroundColor Yellow
}

# --- safety: refuse if anything oversized would be staged -------------------
Step "Pre-flight: checking for files over GitHub's 100 MB limit"
$oversize = @()
foreach ($repo in @('.', 'voicebox', 'voicebox-be')) {
    $candidates = @(git -C $repo ls-files --others --exclude-standard) +
                  @(git -C $repo diff --name-only)
    foreach ($f in ($candidates | Where-Object { $_ })) {
        $full = if ($repo -eq '.') { $f } else { Join-Path $repo $f }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $len = (Get-Item -LiteralPath $full).Length
            if ($len -gt 100MB) {
                $oversize += ("{0,8:N0} MB  {1}" -f ($len / 1MB), $full)
            }
        }
    }
}
if ($oversize) {
    Bad "These files exceed 100 MB and GitHub will reject the whole push:"
    $oversize | ForEach-Object { Bad $_ }
    Bad "Add them to the relevant .gitignore first. Aborting."
    exit 1
}
Good "no oversized files"

# --- one repo ---------------------------------------------------------------
function Publish-Repo {
    param(
        [string]$Path,       # '.' for the outer repo
        [string]$Label,
        [string]$Message,
        [string]$Branch
    )

    Step "$Label  ($Branch)"

    $changes = @(git -C $Path status --porcelain)
    if (-not $changes) {
        # Nothing new to commit does NOT mean nothing to push: the work may
        # already be committed locally but never pushed (e.g. committed by
        # hand). Pushing only when there were changes left such a commit
        # local-only, and the outer repo then recorded a SHA nobody else can
        # fetch. So: if HEAD is not on any remote branch, push it.
        $onRemote = @(git -C $Path branch -r --contains HEAD)
        if ($onRemote) {
            Info "nothing to commit, already on a remote"
            return $true
        }
        Info "nothing to commit, but HEAD is not on any remote branch yet"
        if (-not $Go) {
            Info "would push  : origin $Branch"
            return $true
        }
        git -C $Path push -u origin $Branch
        if ($LASTEXITCODE -ne 0) { Bad "git push failed for $Label."; return $false }
        Good "pushed to origin/$Branch"
        return $true
    }

    $bytes = 0
    foreach ($line in $changes) {
        $f = $line.Substring(3).Trim('"')
        $full = if ($Path -eq '.') { $f } else { Join-Path $Path $f }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $bytes += (Get-Item -LiteralPath $full).Length
        }
    }
    Info ("{0} change(s), {1:N1} MB" -f $changes.Count, ($bytes / 1MB))
    $changes | Select-Object -First 12 | ForEach-Object { Info "  $_" }
    if ($changes.Count -gt 12) { Info ("  ... and {0} more" -f ($changes.Count - 12)) }

    if (-not $Go) {
        Info "would commit: $Message"
        Info "would push  : origin $Branch"
        return $true
    }

    git -C $Path add -A
    if ($LASTEXITCODE -ne 0) { Bad "git add failed"; return $false }

    git -C $Path commit -m $Message
    if ($LASTEXITCODE -ne 0) { Bad "git commit failed"; return $false }
    Good "committed"

    git -C $Path push origin $Branch
    if ($LASTEXITCODE -ne 0) {
        Bad "git push failed for $Label."
        Bad "If this is 'voicebox' and you lack write access to woriion/voicebox,"
        Bad "fork it and repoint the submodule - see docs/REPO_LAYOUT.md."
        return $false
    }
    Good "pushed to origin/$Branch"
    return $true
}

# --- 1 and 2: the submodules, innermost first -------------------------------
$beBranch = (git -C voicebox-be rev-parse --abbrev-ref HEAD).Trim()
$feBranch = (git -C voicebox rev-parse --abbrev-ref HEAD).Trim()

if (-not (Publish-Repo -Path 'voicebox-be' -Label 'Backend (voicebox-be)' `
                       -Message $BackendMessage -Branch $beBranch)) {
    Bad "Stopping: the outer repo must not record an unpushed backend commit."
    exit 1
}

if (-not (Publish-Repo -Path 'voicebox' -Label 'Frontend (voicebox)' `
                       -Message $FrontendMessage -Branch $feBranch)) {
    Bad "Stopping: the outer repo must not record an unpushed frontend commit."
    exit 1
}

# --- verify the recorded commits are reachable on their remotes -------------
Step "Verifying submodule commits exist on their remotes"
$unreachable = @()
foreach ($sm in @('voicebox-be', 'voicebox')) {
    $sha = (git -C $sm rev-parse HEAD).Trim()
    $onRemote = @(git -C $sm branch -r --contains $sha)
    if ($onRemote) {
        Good ("{0,-12} {1} on {2}" -f $sm, $sha.Substring(0, 8), (($onRemote -join ',').Trim()))
    } else {
        if ($Go) { $unreachable += $sm } else { Info "$sm not pushed yet (dry run)" }
    }
}
if ($unreachable) {
    Bad ("Not on any remote: {0}. A fresh clone would fail. Aborting." -f ($unreachable -join ', '))
    exit 1
}

# --- 3: the outer repo, recording the new pointers --------------------------
# symbolic-ref, not rev-parse: the outer repo may have no commits yet, and
# `rev-parse --abbrev-ref HEAD` prints a fatal error on an unborn branch while
# symbolic-ref resolves it fine.
$shellBranch = (git symbolic-ref --short HEAD)
if (-not $shellBranch -or $shellBranch -eq 'HEAD') { $shellBranch = 'master' }

if (-not (Publish-Repo -Path '.' -Label 'App shell (voicebox-app)' `
                       -Message $ShellMessage -Branch $shellBranch.Trim())) {
    Bad "The submodules are pushed but the outer repo is not."
    Bad "Re-run this script, or commit the outer repo by hand."
    exit 1
}

# --- summary ---------------------------------------------------------------
Step "Result"
git submodule status | ForEach-Object { Info $_ }
Write-Host ""
if ($Go) {
    Good "All three repos committed and pushed."
    Info "Verify a consumer can get it:"
    Info "  git clone --recurse-submodules <your outer repo url>"
} else {
    Write-Host "Dry run complete. Re-run with -Go to commit and push." -ForegroundColor Yellow
}
