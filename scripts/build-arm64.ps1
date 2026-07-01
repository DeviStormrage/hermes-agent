#Requires -Version 5.1
<#
.SYNOPSIS
    Build Hermes Agent desktop app natively for Windows 11 ARM64.
.DESCRIPTION
    One-shot build script for the Lenovo Slim 7x (Snapdragon X Plus) target.
    Validates prerequisites, applies the arm64 electron-builder patch,
    installs dependencies, and produces Hermes-Setup-arm64.exe.
.NOTES
    Run from the repo root:
        pwsh -ExecutionPolicy Bypass -File .\build-arm64.ps1
#>

[CmdletBinding()]
param(
    [switch]$SkipPatch,         # Skip applying the electron-builder patch (already applied)
    [switch]$SkipDeps,          # Skip npm ci / uv sync
    [switch]$DevMode,           # Run dev mode instead of building installer
    [switch]$OpenReleaseFolder  # Open the release folder when done
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Style helpers ----------------------------------------------------------
function Write-Step($msg)   { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)     { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg)   { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)    { Write-Host "  [ERROR] $msg" -ForegroundColor Red }

# --- Python interpreter selection -------------------------------------------
# pyproject.toml requires >=3.11,<3.14. We never want to fight the user over
# which Python is on PATH -- uv manages its own. But we DO want to detect
# "user has nothing usable" early and offer uv-managed install.
function Resolve-Python {
    # If `uv python find` succeeds for the project's range, we're done.
    & uv python find 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $found = (& uv python find).Trim()
        Write-Ok "uv-managed Python: $found"
        return $found
    }
    # No compatible Python in the uv-managed set. Auto-install 3.13.
    Write-Step "No uv-managed Python in [3.11, 3.14) range. Installing 3.13 ARM64"
    & uv python install 3.13
    if ($LASTEXITCODE -ne 0) { throw "uv python install 3.13 failed" }
    $found = (& uv python find).Trim()
    Write-Ok "uv-managed Python: $found"
    return $found
}

# --- Prerequisite checks ----------------------------------------------------
function Test-Command($name) {
    $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Assert-NodeArm64 {
    if (-not (Test-Command 'node')) {
        throw "Node.js not found. Install Node 22 ARM64 from https://nodejs.org (Windows ARM64 variant)."
    }
    $arch = (& node -e "console.log(process.arch)").Trim()
    if ($arch -ne 'arm64') {
        throw "Node.js reports arch=$arch. Install the Windows ARM64 variant explicitly (not x64 via Prism)."
    }
    $ver = (& node --version).Trim()
    Write-Ok "Node.js $ver (arm64)"
}

function Assert-Uv {
    if (-not (Test-Command 'uv')) {
        throw "uv not found. Install: irm https://astral.sh/uv/install.ps1 | iex"
    }
    $ver = (& uv --version).Trim()
    Write-Ok "uv $ver"
}

function Assert-RepoRoot {
    $pkgJson = Join-Path $script:repoRoot 'package.json'
    if (-not (Test-Path -LiteralPath $pkgJson)) {
        throw "Run this script from the hermes-agent repo root. Current dir: $PWD. Found no package.json at $pkgJson"
    }
    $pkg = Get-Content -Raw -LiteralPath $pkgJson | ConvertFrom-Json
    if ($pkg.name -ne 'hermes-agent') {
        throw "Expected package.json name 'hermes-agent', got '$($pkg.name)'. Wrong directory?"
    }
    Write-Ok "Repo root verified: $script:repoRoot"
}

# --- Patch application ------------------------------------------------------
function Apply-ElectronBuilderPatch {
    $pkgPath = Join-Path $script:repoRoot 'apps\desktop\package.json'
    if (-not (Test-Path -LiteralPath $pkgPath)) {
        throw "Expected $pkgPath. Did you clone the repo?"
    }

    $pkg = Get-Content -Raw -LiteralPath $pkgPath | ConvertFrom-Json
    $currentArch = $pkg.build.win.target[0].arch
    if ($currentArch -contains 'arm64') {
        Write-Ok "apps/desktop/package.json already declares arm64 target"
        return
    }

    Write-Step "Patching apps/desktop/package.json to declare arm64 target"
    $pkg.build.win.target = @(
        @{ target = 'nsis'; arch = @('arm64') }
    )
    $json = $pkg | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $pkgPath -Value $json -Encoding utf8NoBOM
    Write-Ok "Patched. New win.target: nsis/arm64"
}

# --- Build ------------------------------------------------------------------
function Invoke-NpmCi {
    Write-Step "Installing Node workspaces (npm ci)"
    & npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE" }
    Write-Ok "npm ci complete"
}

function Invoke-UvSync {
    Write-Step "Installing Python backend (uv sync --locked)"
    & uv sync --locked
    if ($LASTEXITCODE -ne 0) { throw "uv sync failed with exit code $LASTEXITCODE" }
    Write-Ok "uv sync complete"
}

function Invoke-DevMode {
    Write-Step "Launching dev mode (Vite + Electron)"
    Write-Host "  Press Ctrl+C in this window to stop." -ForegroundColor DarkGray
    & npm run dev --workspace=apps/desktop
}

function Invoke-ProdBuild {
    Write-Step "Building production installer (arm64)"
    $env:npm_config_arch = 'arm64'
    & npm run dist:win:nsis --workspace=apps/desktop
    if ($LASTEXITCODE -ne 0) { throw "Production build failed with exit code $LASTEXITCODE" }
    Write-Ok "Build complete"

    $releaseDir = Join-Path $script:repoRoot 'apps\desktop\release'
    # electron-builder uses artifactName="Hermes-${version}-${os}-${arch}.${ext}"
    # so the file is e.g. Hermes-0.15.1-win-arm64.exe -- not "Hermes-Setup-...".
    $installer = Get-ChildItem -Path $releaseDir -Filter 'Hermes-*-arm64.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($installer) {
        Write-Host ""
        Write-Host "  Installer: " -NoNewline -ForegroundColor Green
        Write-Host $installer.FullName
        Write-Host "  Size:      " -NoNewline -ForegroundColor Green
        Write-Host ("{0:N1} MB" -f ($installer.Length / 1MB))
        if ($OpenReleaseFolder) {
            & explorer.exe $releaseDir
        }
    } else {
        Write-Warn "No arm64 installer found in $releaseDir"
        Write-Warn "Files present in release dir:"
        Get-ChildItem -Path $releaseDir -Filter '*.exe' -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Warn "  $($_.Name)" }
    }
}

# --- Main -------------------------------------------------------------------
try {
    # Use the directory the user ran the script from as the repo root.
    # We expect them to be in the hermes-agent repo root (per the header NOTES).
    $script:repoRoot = (Get-Location).Path

    Write-Step "Hermes Agent - Native Windows 11 ARM64 Build"
    Write-Host "  Repo:    $script:repoRoot"
    Write-Host "  Date:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "  PSVer:   $($PSVersionTable.PSVersion)"
    Write-Host ""

    Assert-NodeArm64
    Assert-Uv
    Assert-RepoRoot
    Resolve-Python

    if (-not $SkipPatch)  { Apply-ElectronBuilderPatch }
    if (-not $SkipDeps)   { Invoke-NpmCi ; Invoke-UvSync }

    if ($DevMode) {
        Invoke-DevMode
    } else {
        Invoke-ProdBuild
    }
}
catch {
    Write-Err $_.Exception.Message
    Write-Host ""
    Write-Host "  See BUILD-ARM64.md for the full runbook and troubleshooting." -ForegroundColor DarkGray
    exit 1
}
