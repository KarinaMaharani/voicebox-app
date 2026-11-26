#!/usr/bin/env bash
# Build VoiceBox Python backend for macOS.
# Run from the voicebox-app root directory.
#
# Output: voicebox-be/dist/voicebox_backend/voicebox_backend
# electron-builder copies this folder into resources/backend/.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BE_DIR="$ROOT_DIR/voicebox-be"
DIST_DIR="$BE_DIR/dist"

echo ""
echo "VoiceBox — macOS Backend Build"
echo "Backend dir : $BE_DIR"
echo "Output dir  : $DIST_DIR"
echo ""

PYTHON="${PYTHON:-python3}"

# Verify Python
if ! command -v "$PYTHON" &>/dev/null; then
  echo "Error: Python 3 not found. Install via 'brew install python' or from python.org." >&2
  exit 1
fi
echo "Using: $($PYTHON --version)"

# Install / upgrade PyInstaller
"$PYTHON" -m pip install --quiet --upgrade pyinstaller

echo ""
echo "Running PyInstaller..."

cd "$BE_DIR"
"$PYTHON" -m PyInstaller \
  --onedir \
  --name voicebox_backend \
  --distpath "$DIST_DIR" \
  --workpath "$BE_DIR/build" \
  --specpath "$BE_DIR/build" \
  --noconfirm \
  --hidden-import sounddevice \
  --hidden-import pyttsx3 \
  --hidden-import pyttsx3.drivers \
  --hidden-import pyttsx3.drivers.nsss \
  --hidden-import starlette \
  --hidden-import uvicorn \
  --hidden-import uvicorn.lifespan.on \
  --hidden-import uvicorn.protocols.http.auto \
  --hidden-import uvicorn.protocols.websockets.auto \
  --hidden-import uvicorn.loops.auto \
  --collect-all faster_whisper \
  --collect-all mediapipe \
  --collect-all cv2 \
  --collect-data faster_whisper \
  raw_web_app.py

BIN="$DIST_DIR/voicebox_backend/voicebox_backend"
if [ -f "$BIN" ]; then
  echo ""
  echo "Build successful!"
  echo "Binary: $BIN"
  echo ""
  echo "Next steps:"
  echo "  1. cd voicebox && NITRO_PRESET=node-server npm run build"
  echo "  2. cd electron && npm install && npm run build:mac"
else
  echo "Build failed — binary not found at $BIN" >&2
  exit 1
fi
