'use strict';

const { app, BrowserWindow, dialog } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const http = require('http');
const fs = require('fs');
const { pathToFileURL } = require('url');

const BACKEND_PORT = 8765;
const FRONTEND_PORT = 3456;
const isDev = !app.isPackaged;

let mainWindow = null;
let splashWindow = null;
let backendProcess = null;

// ─── Python Backend ────────────────────────────────────────────────────────────

// Locate a Python that actually has the backend's dependencies installed.
//
// Spawning a bare `python` was the long-standing cause of "backend did not
// start within 2 minutes": on a machine whose PATH python is a different
// interpreter from the project venv, `import raw_web_app` fails instantly
// (no mediapipe / faster-whisper / sounddevice, or numpy 2.x breaking the
// torch+mediapipe ABI), the process dies, and the poller below just keeps
// retrying a port nothing is listening on until it gives up. The failure is
// silent because nothing reads the child's stderr.
//
// So: prefer the project venvs, in the order the launch scripts use, and only
// fall back to PATH python as a last resort.
function resolveBackendPython(beDir) {
  const isWin = process.platform === 'win32';
  const rel = isWin ? path.join('Scripts', 'python.exe') : path.join('bin', 'python');

  const candidates = [];
  if (process.env.VOICEBOX_PYTHON) candidates.push(process.env.VOICEBOX_PYTHON);
  for (const name of ['.venv311', '.venv', 'venv']) {
    candidates.push(path.join(beDir, name, rel));
    candidates.push(path.join(__dirname, '..', name, rel));
  }

  for (const candidate of candidates) {
    try {
      if (candidate && fs.existsSync(candidate)) return { python: candidate, fromVenv: true };
    } catch {
      /* unreadable path — keep looking */
    }
  }
  return { python: isWin ? 'python' : 'python3', fromVenv: false };
}

function resolveBackendCommand() {
  if (!isDev) {
    const ext = process.platform === 'win32' ? '.exe' : '';
    // Expects: electron-builder extraResources copies voicebox-be/dist/voicebox_backend/ → resources/backend/
    const bin = path.join(process.resourcesPath, 'backend', `voicebox_backend${ext}`);
    if (fs.existsSync(bin)) {
      return { cmd: bin, args: [], cwd: path.dirname(bin), label: 'packaged exe' };
    }
  }
  // Development fallback — run uvicorn from source, using the venv interpreter.
  const beDir = path.join(__dirname, '..', 'voicebox-be');
  const { python, fromVenv } = resolveBackendPython(beDir);
  return {
    cmd: python,
    args: [
      '-m', 'uvicorn', 'raw_web_app:app',
      '--host', '127.0.0.1',
      '--port', String(BACKEND_PORT),
      '--log-level', 'warning',
    ],
    cwd: beDir,
    label: fromVenv ? `venv python (${python})` : `PATH python (${python}) — venv not found`,
    fromVenv,
  };
}

function startBackend() {
  return new Promise((resolve, reject) => {
    const { cmd, args, cwd, label, fromVenv } = resolveBackendCommand();
    console.log(`[backend] starting via ${label}`);
    console.log(`[backend] ${cmd} ${args.join(' ')}  (cwd: ${cwd})`);

    const env = { ...process.env };
    if (!isDev && !env.VOICEBOX_MODEL_DIR) {
      env.VOICEBOX_MODEL_DIR = path.join(app.getPath('userData'), 'models');
    }
    backendProcess = spawn(cmd, args, { cwd, windowsHide: true, env });

    // Keep the tail of stderr. A Python ImportError is the single most common
    // startup failure and it all goes to stderr; without this the user only
    // ever sees "did not start within 2 minutes", which says nothing about
    // the missing module that actually caused it.
    const errorLines = [];
    const keepTail = (chunk) => {
      const text = String(chunk);
      process.stderr.write(`[backend] ${text}`);
      for (const line of text.split(/\r?\n/)) {
        if (line.trim()) errorLines.push(line.trim());
      }
      while (errorLines.length > 40) errorLines.shift();
    };
    if (backendProcess.stderr) backendProcess.stderr.on('data', keepTail);
    if (backendProcess.stdout) {
      backendProcess.stdout.on('data', (c) => process.stdout.write(`[backend] ${String(c)}`));
    }

    let settled = false;
    const finish = (fn, arg) => {
      if (settled) return;
      settled = true;
      fn(arg);
    };

    const hint = () => {
      const tail = errorLines.slice(-12).join('\n');
      const lines = [];
      if (!fromVenv) {
        lines.push(
          'The backend was started with the Python on your PATH because no ' +
          'virtual environment was found at voicebox-be/.venv311 or ' +
          'voicebox-be/.venv.',
          '',
          'Create it and install the dependencies:',
          '  cd voicebox-be',
          '  python -m venv .venv311',
          '  .venv311\\Scripts\\python.exe -m pip install -r requirements.txt',
          '',
          'Or point VOICEBOX_PYTHON at an interpreter that already has them.',
        );
      }
      if (tail) lines.push('', 'Backend output:', tail);
      return lines.join('\n');
    };

    backendProcess.on('error', (e) =>
      finish(reject, new Error(`Could not launch the backend (${cmd}): ${e.message}\n\n${hint()}`)),
    );

    // An immediate exit means the interpreter rejected the import; there is no
    // point polling a port for two minutes after that.
    backendProcess.on('exit', (code, signal) => {
      if (settled) return;
      finish(
        reject,
        new Error(
          `The backend exited before it finished starting ` +
          `(code ${code}${signal ? `, signal ${signal}` : ''}).\n\n${hint()}`,
        ),
      );
    });

    let attempts = 0;
    const poll = setInterval(() => {
      if (settled) { clearInterval(poll); return; }
      if (++attempts > 240) {
        clearInterval(poll);
        finish(
          reject,
          new Error(
            'VoiceBox backend did not respond within 2 minutes.\n\n' +
            'The AI models may still be loading, or a dependency is missing.\n' +
            `${hint()}`,
          ),
        );
        return;
      }
      const req = http.get(`http://127.0.0.1:${BACKEND_PORT}/api/status`, (res) => {
        if (res.statusCode === 200) {
          clearInterval(poll);
          console.log(`[backend] ready after ~${(attempts * 0.5).toFixed(1)}s`);
          finish(resolve);
        }
        res.resume();
      });
      req.on('error', () => {});
      req.setTimeout(400, () => req.destroy());
    }, 500);
  });
}

// ─── Frontend (TanStack Start Vite SSR) ──────────────────────────────────────
//
// PRODUCTION BUILD STEPS (run once before packaging):
//   1. cd voicebox && npm run build
//      → creates voicebox/dist/server/server.js  (fetch handler)
//               and voicebox/dist/client/         (static assets)
//   2. electron-builder copies voicebox/dist → resources/frontend/
//                              voicebox/electron-serve.mjs → resources/frontend/
//
// electron-serve.mjs wraps the fetch handler in a Node.js HTTP server.

async function startFrontendServer() {
  if (isDev) {
    // Dev: run `npm run dev` in voicebox/ separately
    return 'http://localhost:5173';
  }

  const serveEntry = path.join(process.resourcesPath, 'frontend', 'electron-serve.mjs');
  if (!fs.existsSync(serveEntry)) {
    throw new Error(
      'Frontend server script not found.\n\n' +
      'Build it first:\n' +
      '  cd voicebox && npm run build\n\n' +
      'Then re-run electron-builder.',
    );
  }

  process.env.PORT = String(FRONTEND_PORT);
  process.env.HOST = '127.0.0.1';
  // Import the serve wrapper — it starts an HTTP listener on FRONTEND_PORT
  await import(pathToFileURL(serveEntry).href);

  await waitForHttp(`http://127.0.0.1:${FRONTEND_PORT}`, 20, 500);
  return `http://127.0.0.1:${FRONTEND_PORT}`;
}

function waitForHttp(url, maxAttempts, intervalMs) {
  return new Promise((resolve, reject) => {
    let n = 0;
    const poll = setInterval(() => {
      if (++n > maxAttempts) {
        clearInterval(poll);
        reject(new Error(`Frontend server at ${url} did not start.`));
        return;
      }
      const req = http.get(url, (res) => { clearInterval(poll); res.resume(); resolve(); });
      req.on('error', () => {});
      req.setTimeout(400, () => req.destroy());
    }, intervalMs);
  });
}

// ─── CORS bridge ─────────────────────────────────────────────────────────────
//
// The Starlette backend's static allow_origins list doesn't include the
// Electron frontend origin (http://127.0.0.1:3456).  Chromium enforces CORS
// and blocks every fetch() response without the header.  Inject the missing
// CORS headers on all backend responses.  For OPTIONS preflight requests that
// the backend rejects with 400 (unknown origin), also promote the status to
// 200 so Chromium accepts the preflight and sends the real request.
function injectBackendCors(win) {
  win.webContents.session.webRequest.onHeadersReceived(
    { urls: [`http://127.0.0.1:${BACKEND_PORT}/*`] },
    (details, callback) => {
      const headers = { ...details.responseHeaders };
      headers['access-control-allow-origin'] = [`http://127.0.0.1:${FRONTEND_PORT}`];
      headers['access-control-allow-methods'] = ['GET, POST, OPTIONS'];
      headers['access-control-allow-headers'] = ['Content-Type'];
      callback({
        responseHeaders: headers,
        statusLine: (details.method === 'OPTIONS' && details.statusCode >= 400)
          ? 'HTTP/1.1 200 OK'
          : details.statusLine,
      });
    }
  );
}

// ─── Windows ──────────────────────────────────────────────────────────────────

function createSplashWindow() {
  splashWindow = new BrowserWindow({
    width: 380,
    height: 240,
    frame: false,
    alwaysOnTop: true,
    resizable: false,
    center: true,
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  });
  splashWindow.loadFile(path.join(__dirname, 'splash.html'));
}

function createMainWindow(url) {
  mainWindow = new BrowserWindow({
    width: 430,
    height: 900,
    minWidth: 380,
    minHeight: 640,
    title: 'VoiceBox',
    backgroundColor: '#f4eddf',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  injectBackendCors(mainWindow);
  mainWindow.loadURL(url);

  mainWindow.once('ready-to-show', () => {
    if (splashWindow && !splashWindow.isDestroyed()) {
      splashWindow.close();
      splashWindow = null;
    }
    mainWindow.show();
  });

  mainWindow.on('closed', () => { mainWindow = null; });

  if (isDev) mainWindow.webContents.openDevTools({ mode: 'detach' });
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────


// ─── First-run model download ────────────────────────────────────────────────
//
// The installer ships NO model weights (they exceed GitHub's 100 MB per-file
// limit and would make the installer ~2.4 GB). They are fetched once from the
// models-v1 GitHub release and used offline afterwards. Nothing downloads
// without consent: the user is asked first, and told it is public model
// weights, never their audio or video.
function backendJson(method, route) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port: BACKEND_PORT, path: route, method, timeout: 5000 },
      (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => {
          try { resolve(JSON.parse(body || '{}')); } catch (e) { reject(e); }
        });
      },
    );
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('backend request timed out')));
    req.end();
  });
}

async function ensureModels() {
  const info = await backendJson('GET', '/api/models');
  const models = info.models || {};
  if (models.ready) return;

  if (models.offline) {
    throw new Error(
      'Offline mode is on and these model weights are missing: ' +
      `${(models.missing || []).join(', ')}.\n\nInstall them into ${models.model_dir} first.`,
    );
  }
  if (models.disk_sufficient === false) {
    throw new Error(
      `Not enough free disk space for the AI models: need about ${models.download_mb_required} MB, ` +
      `have ${models.disk_free_mb} MB.`,
    );
  }

  const { response } = await dialog.showMessageBox({
    type: 'question',
    buttons: ['Download', 'Quit'],
    defaultId: 0,
    cancelId: 1,
    title: 'VoiceBox — one-time download',
    message: `VoiceBox needs to download about ${(models.download_mb_required / 1024).toFixed(1)} GB of AI models.`,
    detail:
      'This happens once. Afterwards VoiceBox works fully offline.\n\n' +
      'Only public model weights are downloaded. Your audio and video never leave this computer.',
  });
  if (response !== 0) { app.quit(); return; }

  const started = await backendJson('POST', '/api/models/download');
  if (started.started === false && !(started.models && started.models.ready)) {
    throw new Error(`Could not start the download: ${started.reason || 'unknown reason'}`);
  }

  // Poll until done. Progress goes to the splash window title and the console.
  for (;;) {
    await new Promise((r) => setTimeout(r, 1000));
    const s = await backendJson('GET', '/api/models');
    const d = s.download || {};
    const line = d.message || 'downloading';
    console.log(`[models] ${line}`);
    if (splashWindow && !splashWindow.isDestroyed()) splashWindow.setTitle(`VoiceBox — ${line}`);
    if (d.error) throw new Error(`Model download failed: ${d.error}`);
    if (d.finished && !d.running) break;
  }
}

app.whenReady().then(async () => {
  createSplashWindow();

  try {
    await startBackend();
    await ensureModels();
    const frontendUrl = await startFrontendServer();
    createMainWindow(frontendUrl);
  } catch (err) {
    if (splashWindow && !splashWindow.isDestroyed()) splashWindow.close();
    dialog.showErrorBox('VoiceBox — Startup Error', String(err.message ?? err));
    app.quit();
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (!mainWindow) {
    createMainWindow(`http://127.0.0.1:${isDev ? 5173 : FRONTEND_PORT}`);
  }
});

app.on('before-quit', () => {
  if (backendProcess && !backendProcess.killed) {
    backendProcess.kill();
  }
});
