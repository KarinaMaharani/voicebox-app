# Repository layout and release order

VoiceBox is three repositories: an outer shell repo plus two submodules.

```
voicebox-app/                 outer repo  (electron shell, scripts, docs, SQL)
├── voicebox/      submodule  github.com/KarinaMaharani/voicebox-fe   @ feat/connect-be  (fork of woriion/voicebox)
└── voicebox-be/   submodule  github.com/KarinaMaharani/voicebox-be  @ main
```

Both submodule remotes are **public and clone without authentication**
(verified with `git ls-remote`), so anyone can:

```powershell
git clone --recurse-submodules https://github.com/<you>/voicebox-app.git
```

If someone clones without `--recurse-submodules`, the two directories come
down empty. They fix it with:

```powershell
git submodule update --init --recursive
```

## The one rule that matters

**A submodule records a commit, not your working files.**

The outer repo stores a 40-character SHA per submodule. Anything uncommitted
inside `voicebox/` or `voicebox-be/` is invisible to everyone else, and
anything committed but not *pushed* makes a fresh clone fail with
`fatal: remote error: upload-pack: not our ref`.

So the order is always: **inner first, outer second.**

## Release order

```powershell
# 1. Backend: commit and push inside the submodule
cd voicebox-be
git add -A
git commit -m "Syllable-level audio/visual fusion, LLM corrector, model assets"
git push origin main
cd ..

# 2. Frontend: same
cd voicebox
git add -A
git commit -m "Actionable auth errors, backend wiring"
git push origin feat/connect-be
cd ..

# 3. Outer repo: record the NEW submodule commits plus its own files
git add -A
git commit -m "VoiceBox app shell: submodules, build scripts, distribution docs"
git push origin main
```

Step 3 is what moves the recorded SHAs forward. Skip it and the outer repo
still points at the old commits, so a fresh clone gets stale code even though
you pushed the submodules.

## Checking before you push

```powershell
git submodule status
```

| Prefix | Meaning |
| --- | --- |
| (space) | matches the recorded commit - clean |
| `+` | submodule HEAD differs from what the outer repo records - run `git add <path>` in the outer repo |
| `-` | not initialized - run `git submodule update --init` |
| `U` | merge conflict inside the submodule |

And to confirm a recorded commit actually exists on its remote:

```powershell
git -C voicebox-be branch -r --contains HEAD
```

Empty output means it is local-only and a clone will break.

## Why build output must be ignored twice

Each submodule has its own `.gitignore`; the outer repo's does **not** apply
inside them. Before this was fixed, `git add -A` inside `voicebox-be/` staged
**2,995 MB across ~6,250 files**, including five over GitHub's 100 MB
per-file hard limit:

```
955 MB  dist/.../chaplin/benchmarks/LRS3/models/LRS3_V_WER19.1/model.pth
294 MB  dist/.../torch/lib/torch_cpu.dll
316 MB  models/hub/models--distilroberta-base/blobs/2b11ca9c...
208 MB  dist/.../jaxlib/jax_common.dll
205 MB  dist/.../chaplin/benchmarks/LRS3/language_models/lm_en_subword/model.pth
```

GitHub rejects the whole push on any one of those. `voicebox-be/.gitignore`
now covers `dist/`, `build/`, `models/` and the weight extensions, bringing it
to **3.8 MB across 15 files**.

If you add a build step to either submodule later, add its output directory to
*that submodule's* `.gitignore`, not the parent's.

## Branch tracking

`.gitmodules` records a `branch` per submodule, so this follows the right one:

```powershell
git submodule update --remote --merge
```

`voicebox` currently tracks `feat/connect-be`, which is where its work lives.
Its remote also has `main` and `feat/connect-supabase`. Before a public
release you probably want that work merged to `main` and the tracking branch
changed:

```powershell
git config -f .gitmodules submodule.voicebox.branch main
```

## The frontend fork

`voicebox` is now **your fork**, `KarinaMaharani/voicebox-fe`, so you have push
access. In that checkout `origin` is the fork and `upstream` is
`woriion/voicebox`, so you can still pull their changes:

```powershell
git -C voicebox fetch upstream
git -C voicebox merge upstream/main
```

The fork only had `main`. Pushing `feat/connect-be` creates that branch there;
the fork's `main` is an ancestor of it, so the push is a clean fast-forward.

## The outer repo shares a repo with the live website

`KarinaMaharani/voicebox-app` already hosts the GitHub Pages download site
(`index.html`, `windows-platform-logo.svg`, `LICENSE`, `.nojekyll` at the root,
13 commits). The local shell repo is built **on top of that history**, so the
push is a normal fast-forward and the site files stay untouched. Never
force-push this repo: it would take the live site down.

`download-page/` in the shell is an older copy of the root `index.html`. The
root one is live; treat it as the source of truth and delete the copy when
convenient.

**The release asset name is load-bearing.** The site's button links to
`releases/latest/download/VoiceBox-Setup-x64.exe`, but electron-builder
produces `VoiceBox Setup 1.0.0.exe`. Rename it before uploading or the button
404s.

## What goes in a release, not the repo

Nothing large is committed anywhere. The installer and the model weights are
published as **GitHub release assets** (2 GB per file, no total cap) — see
[DISTRIBUTION.md](DISTRIBUTION.md). The outer repo stages 0.3 MB; the two
submodules add 4.2 MB between them.
