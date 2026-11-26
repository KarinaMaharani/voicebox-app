# VoiceBox

Desktop accessibility tool for people who have lost their voice — dysphonia, aphonia, ALS, laryngectomy. VoiceBox watches your lip movements through your webcam, reconstructs the words you're trying to say using AI, lets you correct them word-by-word, then speaks them aloud. Everything runs locally on your device. No internet required.

---

## Features

- **Visual lip-reading AI** — Chaplin VSR model reads mouth movements in real time
- **Audio fusion** — optional microphone input blended with lip-reading for higher accuracy
- **Editable output** — correct predicted words before playback
- **Text-to-speech** — speaks the final text aloud via system voice
- **Phrase history** — saves and learns from your corrections over time
- **Fully offline** — no data leaves your machine

---

## Platform support

| Platform | Status |
|----------|--------|
| Windows 10 / 11 (64-bit) | Available |
| macOS | Planned |
| Linux | Planned |

---

## Download

Go to the [Releases page](https://github.com/KarinaMaharani/voicebox-app/releases) and download `VoiceBox-Setup-x64.exe`.

Or visit the download page: **https://KarinaMaharani.github.io/voicebox-app/**

---

## Requirements

- Windows 10 or 11 (64-bit)
- 8 GB RAM minimum
- Any webcam
- ~3 GB free disk space

---

## Building from source

You need Python 3.10+, Node.js 18+, and npm.

Before debugging anything by hand, run the preflight — it checks the backend
venv, numpy version, every import, the Chaplin model assets, the LLM chain,
`node_modules`, and your env keys, and prints the fix for whatever it finds:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
```

### 1. Install Python dependencies

Install into a **virtual environment**, not your system Python. The app looks
for `voicebox-be/.venv311` (then `.venv`, then `venv`); a bare `python` on
PATH usually lacks mediapipe/faster-whisper and ships numpy 2.x, which breaks
the torch/mediapipe ABI and makes the backend exit before it serves.

```powershell
cd voicebox-be
python -m venv .venv311
.venv311\Scripts\python.exe -m pip install -r requirements.txt
```

To use an interpreter somewhere else, point `VOICEBOX_PYTHON` at it.

### 1b. Sign-in (optional)

The app works fully as a guest. For cross-device phrase sync, follow
[`supabase/README.md`](supabase/README.md) — create a project, paste two keys,
run one SQL migration — then check it with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify-auth.ps1
```

### 2. Build everything (Windows)

From the repo root:

```powershell
.\scripts\build-all-win.ps1
```

This runs three steps automatically:
1. Packages the Python backend into a self-contained executable using PyInstaller
2. Builds the React/TanStack Start frontend with the Nitro `node-server` preset
3. Packages both into a Windows installer using Electron + electron-builder

Output: `electron/dist/VoiceBox Setup *.exe`

### 3. Individual build steps (optional)

**Backend only:**
```powershell
.\scripts\build-backend-win.ps1
```

**Frontend only:**
```powershell
cd voicebox
npm install
$env:NITRO_PRESET = "node-server"
npm run build
```

**Electron packaging only** (after backend + frontend are built):
```powershell
cd electron
npm install
npm run build:win
```

### macOS build

```bash
./scripts/build-backend-mac.sh
cd voicebox && NITRO_PRESET=node-server npm run build
cd ../electron && npm install && npm run build:mac
```

---

## Project structure

```
voicebox-app/
├── voicebox/          # React + TanStack Start frontend
├── voicebox-be/       # Python backend (Starlette, Chaplin VSR, faster-whisper)
├── electron/          # Electron wrapper + electron-builder config
├── download-page/     # GitHub Pages download landing page
└── scripts/           # Build scripts (PyInstaller + full pipeline)
```

---

## Tech stack

| Layer | Tech |
|-------|------|
| Frontend | React 19, TanStack Start, TanStack Router, Tailwind CSS v4 |
| Backend | Python, Starlette, uvicorn, Chaplin VSR, faster-whisper, OpenCV, sounddevice |
| Desktop | Electron, electron-builder, PyInstaller |
| Auth / sync | Supabase (phrase history, optional) |

---

## License

MIT — free and open source.
