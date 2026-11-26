# Release runbook: from a clean checkout to a published release

Run everything from the repo root (`voicebox-app/`) in PowerShell.
The order matters. Each step lists what must already be true.

```
env -> test -> pack models -> paste hashes -> push code
    -> publish models -> build installer -> publish installer -> verify
```

Three GitHub repos are involved:

| Repo | Holds |
| --- | --- |
| `KarinaMaharani/voicebox-fe` | frontend (submodule `voicebox/`) |
| `KarinaMaharani/voicebox-be` | backend (submodule `voicebox-be/`) |
| `KarinaMaharani/voicebox-app` | shell + the live website + **both releases** |

---

## 0. One-time tools

```powershell
winget install GitHub.cli
gh auth login            # choose GitHub.com, HTTPS, "Login with a web browser"
gh auth status           # must say: Logged in to github.com as KarinaMaharani
```

No `gh`? Every `gh release create` below can be done in the browser instead
(see "Without gh" at the end).

---

## 1. Environment (Supabase)

The installer bakes `VITE_*` values in at **build time**, so this must be
correct before step 6, not after.

1. Supabase Dashboard -> **Project Settings -> API**. Copy the **anon /
   publishable** key. Never the `service_role` key.
2. Open `voicebox\.env.local` and replace both placeholders:

   ```
   VITE_SUPABASE_PUBLISHABLE_KEY="<anon key>"
   SUPABASE_PUBLISHABLE_KEY="<anon key>"
   ```

   The URL and project id already point at `mcogrujyvfwpiebuhowe`.
3. Dashboard -> **SQL Editor -> New query**. Paste all of
   `supabase\migrations\0001_init.sql` and press **Run**.
4. Dashboard -> **Authentication -> Providers -> Email**: enabled. For first
   testing also set **Confirm email** off.
5. Check it:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\verify-auth.ps1
   ```

   Expect `Auth looks ready`. A 401 means the key is wrong; "table does not
   exist" means step 3 was skipped.

`.env.local` is gitignored. It is never committed.

---

## 2. Test before you ship anything

```powershell
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
voicebox-be\.venv311\Scripts\python.exe voicebox-be\test_syllable_fusion.py
```

`doctor.ps1` should report no problems. The tests should end `37 passed, 0 failed`.

---

## 3. Pack the model weights

```powershell
powershell -ExecutionPolicy Bypass -File scripts\pack-models.ps1
```

It builds three zips in `dist-models\` from your local caches (no download):

| Zip | Roughly |
| --- | --- |
| `asr-faster-whisper-tiny-en.zip` | 156 MB |
| `corrector-distilroberta-base.zip` | ~330 MB |
| `vsr-chaplin-lrs3.zip` | ~1160 MB |

Each must be **under 2 GB** (GitHub's per-asset limit). It prints a `sha256`
for each.

## 4. Paste the hashes into the code

Open `voicebox-be\model_assets.py`. In the `ASSETS` list add the printed value
to each entry as `sha256="..."`:

```python
ModelAsset(
    key="asr",
    ...
    sha256="PASTE_HASH_FOR_asr-faster-whisper-tiny-en.zip",
),
```

Do this for `asr`, `corrector` and `vsr`. With a hash set, a corrupted or
swapped download is rejected instead of loaded. With it empty, the download
still works but is **unverified**.

---

## 5. Push the code (inner repos first)

```powershell
# Dry run. Prints what it would commit and checks for files over 100 MB.
powershell -ExecutionPolicy Bypass -File scripts\push-all.ps1

# For real: backend -> frontend (the fork) -> shell
powershell -ExecutionPolicy Bypass -File scripts\push-all.ps1 -Go
```

Order is enforced: a submodule records a commit SHA, so the inner repos must
be pushed before the shell records them. If an inner push fails the script
stops.

The first push to the fork creates `feat/connect-be` there. Git Credential
Manager opens a browser to sign you in the first time.

Never force-push `voicebox-app`: it hosts the live website at its root.

---

## 6. Publish the models release

The models must be online **before** anyone installs, because the app fetches
them on first run.

```powershell
gh release create models-v1 dist-models\*.zip `
  --repo KarinaMaharani/voicebox-app `
  --title "VoiceBox models v1" `
  --notes "Model weights, downloaded once on first run. Public weights only."
```

The tag **must** be `models-v1`. That is the URL baked into
`MODEL_CONFIG.assets_base_url`. A different tag means a 404 on first run.

---

## 7. Build the installer

```powershell
# The old 2.4 GB build is still there and the script SKIPS the backend if it
# exists, so delete it to force a rebuild without the weights.
Remove-Item voicebox-be\dist, voicebox-be\build -Recurse -Force -ErrorAction SilentlyContinue

powershell -ExecutionPolicy Bypass -File scripts\build-all-win.ps1 `
  -PythonCmd "voicebox-be\.venv311\Scripts\python.exe"
```

Output: `electron\release\VoiceBox Setup 1.0.0.exe`.

Check the size. It should be several hundred MB, not 2+ GB:

```powershell
(Get-Item "electron\release\VoiceBox Setup 1.0.0.exe").Length / 1MB
```

If it is still ~2 GB the weights got bundled. Look for `chaplin\benchmarks`
inside `voicebox-be\dist\voicebox_backend\_internal`.

## 8. Publish the installer

The website's Download button links to
`releases/latest/download/VoiceBox-Setup-x64.exe`. GitHub serves the asset
under its **file name**, so the file itself must be renamed. (`gh`'s
`file#text` syntax only sets a display label, not the name, so it will not
work here.)

```powershell
New-Item -ItemType Directory -Force dist-release | Out-Null
Copy-Item "electron\release\VoiceBox Setup 1.0.0.exe" "dist-release\VoiceBox-Setup-x64.exe"

gh release create v1.0.0 "dist-release\VoiceBox-Setup-x64.exe" `
  --repo KarinaMaharani/voicebox-app `
  --title "VoiceBox 1.0.0" `
  --notes "Windows installer. The first launch downloads about 1.8 GB of AI models once, then works offline."
```

---

## 9. Verify like a stranger

**The button resolves** (expect `302` then `200`):

```powershell
curl.exe -sIL "https://github.com/KarinaMaharani/voicebox-app/releases/latest/download/VoiceBox-Setup-x64.exe" | Select-String "HTTP/"
```

**A fresh clone gets everything:**

```powershell
cd $env:TEMP
git clone --recurse-submodules https://github.com/KarinaMaharani/voicebox-app.git vb-check
Get-ChildItem vb-check\voicebox, vb-check\voicebox-be | Select-Object -First 6
```

Both folders must be non-empty.

**First-run download works.** On a machine (or a Windows Sandbox) with no
model cache, install and launch. Expect a dialog: "VoiceBox needs to download
about 1.8 GB of AI models." Click Download, wait, and the app should open.
Launch it again with Wi-Fi off. It should open straight away.

**Login works.** Sign up at `/auth`, save a phrase, and confirm it appears on
`/profile`. Then sign up a second account and confirm it does **not** see the
first account's phrases. The app relies entirely on row-level security for
this, so this check matters.

---

## Without gh

1. Open `https://github.com/KarinaMaharani/voicebox-app/releases/new`.
2. Tag `models-v1`, title "VoiceBox models v1", drag in the three zips from
   `dist-models\`, **Publish release**.
3. Repeat with tag `v1.0.0`. Rename the installer to `VoiceBox-Setup-x64.exe`
   on disk first, then drag it in, **Publish release**.

---

## If something goes wrong

| Symptom | Cause / fix |
| --- | --- |
| Download button 404s | Asset not named `VoiceBox-Setup-x64.exe`, or the release is a draft or pre-release (`latest` skips those) |
| First run: "not found at ...models-v1" | Step 6 skipped, or the tag is not exactly `models-v1` |
| First run: "checksum mismatch" | A zip was re-packed after its hash was pasted. Re-run steps 3-4 and re-publish |
| `app.asar ... being used by another process` | Something holds a file in an old build folder (it was `Claude.exe`, the desktop app's file pane). Output now goes to a fresh `electron\release`, so it no longer matters |
| Installer ~2.4 GB | Old `voicebox-be\dist` reused. Delete it (step 7) |
| Login says "Cannot reach ..." | Wrong URL in `.env.local`, or the project is paused |
| Login says 401 / invalid key | Anon key not pasted, or from a different project |
| `git push` rejected, "file too large" | Something over 100 MB got staged. `push-all.ps1` pre-flight names it |
| Fresh clone has empty `voicebox/` | Cloned without `--recurse-submodules`. Run `git submodule update --init --recursive` |
