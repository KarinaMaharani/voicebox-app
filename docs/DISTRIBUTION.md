# Shipping VoiceBox from a free GitHub repo

## The constraint, stated precisely

GitHub's "100 MB" is a **per-file limit inside the git repository**, not a
storage cap on your account. Three separate limits matter:

| Limit | Value | Applies to |
| --- | --- | --- |
| Single file in a git repo | **100 MB hard** (warning at 50 MB) | anything you `git add` |
| Repository size | ~1 GB recommended, ~5 GB before GitHub contacts you | the whole clone |
| **Release asset** | **2 GB per file, no total cap** | files attached to a release |
| Git LFS (free tier) | 1 GB storage + 1 GB/month bandwidth | LFS-tracked files |

The lip-reading model alone is **955 MB** and the subword LM is **205 MB**, so
they can never go in the repo. Git LFS does not rescue this either: 1 GB of
free bandwidth is roughly *one* user downloading the pack once.

Release assets are the answer, and they are what this project uses.

## The split

```
git repository  (a few MB, clones instantly)
├── voicebox/            frontend source
├── voicebox-be/         backend source
├── electron/            shell source
├── scripts/             build + diagnostics
├── supabase/            migration SQL
└── docs/

GitHub Release "v1.0.0"        <- the installer
└── VoiceBox-Setup-x64.exe     ~700-900 MB (see below)

GitHub Release "models-v1"     <- the weights, fetched on first run
├── asr-faster-whisper-tiny-en.zip    ~156 MB
├── corrector-distilroberta-base.zip  ~330 MB
└── vsr-chaplin-lrs3.zip             ~1160 MB
```

Nothing over 2 GB, nothing over 100 MB in git, and the repo stays clonable.

## Where the 2.44 GB currently goes

Measured from `electron/dist/win-unpacked/resources/backend/_internal`:

| Component | Size | Verdict |
| --- | --- | --- |
| `chaplin/` | 1179.7 MB | **1160 MB is two `model.pth` files** -> move to release asset |
| `torch/` | 359.6 MB | needed (already CPU-only) |
| `jaxlib/` | 209.5 MB | **dead weight** - nothing imports jax -> excluded |
| `cv2/` | 122.9 MB | needed |
| `mediapipe/` | 95.5 MB | needed |
| `av.libs/` | 62.0 MB | needed (video decode) |
| `ctranslate2/` | 58.8 MB | needed (faster-whisper runtime) |
| `scipy/` | 52.4 MB | needed |
| `transformers/` | 35.6 MB | needed |
| `onnxruntime/` | 33.7 MB | arrives with mediapipe |

Two changes shrink the installer from **2443 MB to roughly 1070 MB uncompressed**:

1. **Weights out** (-1160 MB): they move to the `models-v1` release.
2. **jax excluded** (-209 MB): verified unused - zero `import jax` anywhere in
   `voicebox-be/`, including the vendored `chaplin/` and `espnet/` trees.
   Already applied in `scripts/build-backend-win.ps1`.

NSIS compresses that to roughly **500-700 MB** as a `.exe`. Comfortably inside
the 2 GB release-asset limit.

> I have not rebuilt the installer to confirm the compressed figure - that
> number is an estimate from the uncompressed total and typical NSIS ratios on
> binary-heavy payloads. The 2443 -> 1070 MB reduction is arithmetic on
> measured directory sizes, so that part is solid.

## First-run flow

```
user runs installer                 ~600 MB download, normal install
  |
app starts, backend boots           no weights yet
  |
GET /api/status -> models.ready:false, download_mb_required: ~1800
  |
UI shows: "VoiceBox needs to download 1.8 GB of AI models once.
           After this it works entirely offline."   [Download]
  |
POST /api/models/download           progress via /api/status.model_download
  |
weights land in voicebox-be/models/ and chaplin/benchmarks/
  |
offline forever after
```

Why download rather than bundle: a 2.4 GB installer is a download many people
on a mobile connection simply never complete, and it is the whole install
whether or not they ever use lip-reading. Splitting it means the app starts
fast, and the big VSR pack can be deferred.

Why not stream weights per use: the privacy promise. Once fetched, nothing
leaves the device - the only network traffic in VoiceBox's life is this
one-time fetch of **public model weights**, never user audio or video.

## Publishing

```powershell
# 1. Build the model pack from your local caches (no re-download)
powershell -ExecutionPolicy Bypass -File scripts\pack-models.ps1

# 2. Paste the printed sha256 values into ASSETS in
#    voicebox-be\model_assets.py, then commit that change.

# 3. Publish the weights
gh release create models-v1 dist-models\*.zip --repo KarinaMaharani/voicebox-app `
  --title "VoiceBox models v1" `
  --notes "Model weights, fetched once on first run."

# 4. Build and publish the installer
powershell -ExecutionPolicy Bypass -File scripts\build-all-win.ps1
# The download page links to releases/latest/download/VoiceBox-Setup-x64.exe,
# and GitHub serves an asset under its FILE NAME, so rename the file first.
# (gh's "file#text" only sets a display label.) Full steps: docs/RELEASE.md
New-Item -ItemType Directory -Force dist-release | Out-Null
Copy-Item "electron\release\VoiceBox Setup 1.0.0.exe" "dist-release\VoiceBox-Setup-x64.exe"
gh release create v1.0.0 "dist-release\VoiceBox-Setup-x64.exe" `
  --repo KarinaMaharani/voicebox-app `
  --title "VoiceBox 1.0.0" --notes "See README for install steps."
```

`model_assets.py` resolves its download URL from
`MODEL_CONFIG.assets_base_url`, which defaults to the `models-v1` release.
Override it with `VOICEBOX_ASSETS_BASE_URL` to test against a local server or
a mirror.

## Checksums matter here

Each asset carries an expected SHA-256. A download is written to a `.part`
file, verified, and only then renamed and unpacked. A truncated or substituted
weight file fails loudly instead of loading.

Until you fill in the hashes, `status()` reports `verified: false` for that
asset and `doctor.ps1` surfaces it. The download still works - it is just
unverified, which is worth fixing before anyone else installs the app.

## Air-gapped installs

Set `VOICEBOX_OFFLINE=1` and place the unpacked weights yourself:

```
voicebox-be/models/hub/models--Systran--faster-whisper-tiny.en/...
voicebox-be/models/hub/models--distilroberta-base/...
voicebox-be/chaplin/benchmarks/LRS3/...
```

In offline mode the backend never touches the network: missing weights are
reported as not-ready rather than fetched, and `transformers` is loaded with
`local_files_only=True` so it cannot quietly reach out either.

## Verifying before you publish

```powershell
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
```

It reports which weight packs are present, how much the first run would need
to download, and whether there is disk space for it.

## What this does not solve

The installer is still ~600 MB because `torch` + `cv2` + `mediapipe` are
~580 MB of libraries. Getting meaningfully below that means running inference
on ONNX Runtime instead of torch and dropping mediapipe for a lighter face
detector - a real refactor, not a build flag. Worth it only if installer size
turns out to be what actually blocks adoption.
