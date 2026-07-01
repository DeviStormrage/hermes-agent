# Windows ARM64 Build

> Target: Lenovo Slim 7x, Surface Pro 11, Snapdragon X Elite / X Plus · Windows 11 ARM64

This repo ships native ARM64 builds of `apps/desktop` (Electron 40.10.2). The build is a thin wrapper over the existing `npm run dist:win:nsis` flow with two changes:

1. `apps/desktop/package.json` declares `win.target` as `[{ target: "nsis", arch: ["arm64"] }]`
2. `npm_config_arch=arm64` is set in the build environment so `apps/desktop/scripts/stage-native-deps.cjs` stages the correct `win32-arm64/` prebuilds

## TL;DR

```powershell
# From repo root
pwsh -ExecutionPolicy Bypass -File scripts/build-arm64.ps1
# Output: apps\desktop\release\Hermes-{version}-win-arm64.exe
```

## Prerequisites

| Tool | Source | Notes |
| --- | --- | --- |
| Node.js 22+ ARM64 | https://nodejs.org → "Windows ARM64" | The `engines` field requires `^20.19.0 \|\| >=22.12.0`. The script rejects non-arm64 Node. |
| uv | `irm https://astral.sh/uv/install.ps1 \| iex` | Manages the Python venv and auto-installs Python 3.13 ARM64 if needed. |
| Git for Windows | https://git-scm.com/download/win (or `winget install -e --id Git.Git`) | Must install to `C:\Program Files\Git\` so the desktop app's `ensureRuntime()` check finds `bash.exe`. |

VS Build Tools and a system Python are NOT required — `node-pty 1.1.0` ships `win32-arm64` prebuilts, and `uv python install` handles the interpreter.

## CI

`.github/workflows/build-windows-installer-arm64.yml` runs on `windows-11-arm` and:
- Invokes `scripts/build-arm64.ps1 -SkipDeps`
- Verifies `Hermes.exe` PE header is `0xAA64` (ARM64)
- Verifies `node-pty\prebuilds\win32-arm64\pty.node` was staged
- Uploads the NSIS installer as an artifact

Trigger manually via `workflow_dispatch`, or automatically on pushes that touch `apps/desktop/**` / `scripts/build-arm64.ps1` / the workflow file, and on `v*` tags.

## Rebuilding after an upstream release

```powershell
# 1. Fetch the new tag
git fetch origin v2026.7.x

# 2. Create a fresh branch from the new tag
git checkout -b arm64-desktop-v2026.7.x v2026.7.x

# 3. Cherry-pick the ARM64 build commit
git cherry-pick arm64-desktop
# If apps/desktop/package.json conflicts, fix by hand and `git cherry-pick --continue`

# 4. Build
pwsh -ExecutionPolicy Bypass -File scripts/build-arm64.ps1 -SkipDeps
```

If upstream changes the electron-builder config schema in a way that breaks the patch, re-apply by hand and update the `arm64-desktop` branch so the next cherry-pick is clean.

## Installing the build on a fresh machine

The NSIS installer is **unsigned** (we set `signAndEditExecutable: false`). SmartScreen will prompt; click **"More info" → "Run anyway"**. To avoid the warning permanently, sign with `signtool.exe` and a real cert.

**Common install failure on Win11 ARM64**: Defender real-time protection can kill the unsigned NSIS installer mid-extract, leaving a partial install (registry entries + shortcuts written, but `Hermes.exe` and the GPU `.dll`s missing). The fix is either:
- Add Defender exclusions before installing: `Add-MpPreference -ExclusionPath <install dir> -ExclusionProcess "Hermes-Setup.exe"`
- Or copy the unpacked build directly: `apps\desktop\release\win-arm64-unpacked\` → `C:\Users\<you>\AppData\Local\Programs\Hermes\`

The second path is also the recommended dev workflow — it bypasses NSIS entirely and lets you iterate on rebuilds without uninstalling/reinstalling.

## Architecture

The ARM64 build chain is the same as the x64 build except for the two changes above. The `apps/desktop/scripts/stage-native-deps.cjs` already reads `process.env.npm_config_arch || process.arch` and stages the right prebuilds, so no source changes are needed in the build scripts. The desktop app's `node-pty 1.1.0` ships ARM64 prebuilts in the npm tarball, so no `node-gyp` rebuild is required.
