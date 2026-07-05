# CXXForge core state, CLI parsing, and shared discovery helpers.
<#
PowerShell compile-and-run helper for C/C++

Usage:
    cxxforge.ps1 [options] <source-file> [-- <program-args>]

Options:
    -r, --run            Compile then run (default)
    -n, --no-run         Only compile, don't run
    -h, --help           Show help
    --raw | --pretty     Raw lines or structured diagnostics (default: --pretty)
    --color | --no-color Enable/disable color (default: --color)
    --force-ansi         Force ANSI color sequences (rarely needed on PS)
    --out-dir <dir>      Optional output directory (default: source dir)
    --out-name <name>    Optional output base name (default: source base)
    --clean              Remove CXXForge build outputs and exit
    --explain            Explain incremental build decisions
    --watch-clear        Watch and clear the terminal before rebuilding
    --watch-shell        Force interactive Watch commands (run/build/restart/...)
    --no-watch-shell     Disable interactive Watch commands
    --utf8-init          Initialize console to UTF-8 (for direct invocation)

Exit codes:
    0   Success
    2   Bad arguments / missing source
    3   Source not found
    4   Compiler not found (gcc/g++)
    5   Failed to start compiler process
    10  Unsupported extension
    N   Compiler's own non-zero exit code
#>

param()

# Defaults (may be overridden by args and config)
$USE_COLOR = $true
$FORCE_ANSI = $false
$PRETTY = $true
$DO_RUN = $true
$UTF8_INIT = $false
$DEBUG_MODE = $false
$PROFILE_NAME = $null
$BACKEND_OVERRIDE = $null
$WATCH_MODE = $false
$WATCH_CLEAR = $false
$WATCH_SHELL_OVERRIDE = $null
$IS_PROJECT_MODE = $false
$projDir = $null
$FORCE_REBUILD = $false
$CLEAN_BUILD = $false
$EXPLAIN_BUILD = $false
$OUT_DIR = $null
$OUT_NAME = $null
$SRC = $null
$RUN_ARGS = @()
$PROJECT_INCLUDES = @()
$PROJECT_LINKS = @()

# Diagnostics normalization toggle (optional unified log-style view)
$NORMALIZE_DIAGNOSTICS = $false

# Basic script banner (version / entry info)
$SCRIPT_VERSION = '2.0.0-dev.8'
Write-Host "[INFO] CXXForge C/C++ compile-and-run helper (v$SCRIPT_VERSION)" -ForegroundColor DarkCyan
Write-Host "[INFO] PowerShell: $($PSVersionTable.PSVersion)  Host: $($Host.Name)" -ForegroundColor DarkGray

# Env hardening toggles (can be overridden via compiler_config.json)
$INJECT_COMPILER_BIN = $true    # Prepend compiler's bin dir to PATH so gcc can find cc1/ld/DLLs
$FORCE_ASCII_TEMP    = $true    # Use ASCII-only TEMP/TMP to avoid Unicode path issues in some toolchains

# State for pretty-mode multi-line diagnostics
$script:expectSource = 0  # 0 none, 2 expect source line, 1 expect caret line
$script:pendingSourceLine = $null
$script:pendingSeverity = $null
$script:lastGroupFile = $null
$script:printedFiles = @{}
$script:errCount = 0
$script:warnCount = 0

function Write-NormalizedDiagnostic {
    param(
        [string]$file,
        [string]$line,
        [string]$col,
        [string]$sev,
        [string]$msg
    )
    if (-not $NORMALIZE_DIAGNOSTICS) { return }
    $level = switch -Regex ($sev) {
        'error'   { 'ERROR' }
        'warning' { 'WARN' }
        'note'    { 'INFO' }
        default   { 'INFO' }
    }
    $loc = if ($file) { "${file}:${line}:${col}" } else { "${line}:${col}" }
    # Color scheme similar to the original compiler header lines
    $levelColor = switch ($level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'INFO'  { 'DarkMagenta' }
        default { 'DarkGray' }
    }
    Write-Host -NoNewline "[" -ForegroundColor DarkGray
    Write-Host -NoNewline $level -ForegroundColor $levelColor
    Write-Host -NoNewline "] " -ForegroundColor DarkGray
    # file:line:col part similar to previous pretty header (file gray, position cyan)
    if ($file) {
        Write-Host -NoNewline $file -ForegroundColor DarkGray
        Write-Host -NoNewline (":" + $line + ":" + $col + ": ") -ForegroundColor DarkCyan
    } else {
        Write-Host -NoNewline "${loc}: " -ForegroundColor DarkCyan
    }
    # severity text and message, colored like original compiler line
    switch ($level) {
        'ERROR' { Write-Host -NoNewline "" -ForegroundColor Red }
        'WARN'  { Write-Host -NoNewline "" -ForegroundColor Yellow }
        'INFO'  { Write-Host -NoNewline "" -ForegroundColor DarkMagenta }
        default { }
    }
    Write-ColoredSegments $msg
}

# --- Auto include discovery helper ---
function Get-AutoIncludePaths {
    param([string]$compilerPath)
    $paths = @()
    try {
        if (-not $compilerPath) { return $paths }
        $binDir = Split-Path -Parent $compilerPath
        $root = Split-Path -Parent $binDir
        $candidates = @()
        $candidates += (Join-Path $root 'include')
        $candidates += (Join-Path $root 'x86_64-w64-mingw32\include')
        $candidates += (Join-Path $root 'mingw32\include')
        $gccRoot = Join-Path $root 'lib\gcc'
        if (Test-Path $gccRoot) {
            Get-ChildItem -Path $gccRoot -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.FullName -match '\\include$') { $candidates += $_.FullName }
            }
        }
        foreach ($c in $candidates) {
            if (-not $c) { continue }
            if ($paths -contains $c) { continue }
            if (Test-Path $c) {
                # Heuristic: only add if a common header exists
                if (Test-Path (Join-Path $c 'stdio.h')) { $paths += $c }
            }
        }
    } catch { }
    return $paths
}

# --- Auto lib discovery helper ---
function Get-AutoLibPaths {
    param([string]$compilerPath)
    $paths = @()
    try {
        if (-not $compilerPath) { return $paths }
        $binDir = Split-Path -Parent $compilerPath
        $root = Split-Path -Parent $binDir
        $candidates = @()
        $candidates += (Join-Path $root 'lib')
        $candidates += (Join-Path $root 'lib64')
        $candidates += (Join-Path $root 'x86_64-w64-mingw32\lib')
        $candidates += (Join-Path $root 'mingw32\lib')
        $gccRoot = Join-Path $root 'lib\gcc'
        if (Test-Path $gccRoot) {
            Get-ChildItem -Path $gccRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $verLib = Join-Path $_.FullName ''
                if (Test-Path $verLib) { $candidates += $verLib }
            }
        }
        foreach ($c in $candidates) {
            if (-not $c) { continue }
            if ($paths -contains $c) { continue }
            if (Test-Path $c) {
                # Heuristic: only add if a common runtime or lib exists
                $hasMarker = (Test-Path (Join-Path $c 'libgcc.a')) -or (Test-Path (Join-Path $c 'libstdc++.a')) -or (Test-Path (Join-Path $c 'crt2.o'))
                if ($hasMarker) { $paths += $c }
            }
        }
    } catch { }
    return $paths
}

function Show-Help {
    Write-Host "Usage: cxxforge.ps1 [options] <source-file> [-- <program-args>]"
    Write-Host ""
    Write-Host "[INFO] Options:"
    Write-Host "  -r, --run           Compile then run (default)"
    Write-Host "  -n, --no-run        Only compile, do not run"
    Write-Host "  -d, --debug         Enable debug mode (-g -O0 -D_DEBUG)"
    Write-Host "  -p, --profile <n>  Select build profile (debug/release/release-with-debug)"
    Write-Host "  -b, --backend <n>  Select compiler backend (gcc/clang/auto)"
    Write-Host "  -w, --watch         Watch source file and recompile on changes"
    Write-Host "  --watch-clear       Watch and clear the terminal before rebuilding"
    Write-Host "  --watch-shell       Force the interactive Watch command shell"
    Write-Host "  --no-watch-shell    Disable the interactive Watch command shell"
    Write-Host "  --clean             Remove CXXForge build outputs and exit"
    Write-Host "  --explain           Explain why project files rebuild or skip"
    Write-Host "  -h, --help          Show this help and exit"
    Write-Host "  --raw               Show raw compiler output lines"
    Write-Host "  --pretty            Structured, colorized diagnostics (default)"
    Write-Host "  --normalized-diag   Also print normalized [LEVEL] file:line:col: message lines"
    Write-Host "  --color             Enable colored output (default)"
    Write-Host "  --no-color          Disable colored output"
    Write-Host "  --force-ansi        Force ANSI escape colors (rarely needed on PS)"
    Write-Host "  --out-dir <dir>     Output directory (default: source directory)"
    Write-Host "  --out-name <name>   Output base name without extension"
    Write-Host "  --utf8-init         Initialize console to UTF-8 (for direct invocation)"
    Write-Host "  -- <program-args>   Arguments after -- are passed to the compiled program"
    Write-Host ""
    Write-Host "[INFO] Examples:" -ForegroundColor DarkCyan
    Write-Host "  # Compile and run a C file" -ForegroundColor DarkGray
    Write-Host "  cxxforge.ps1 main.c" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  # Only compile, no run" -ForegroundColor DarkGray
    Write-Host "  cxxforge.ps1 --no-run main.cpp" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  # Specify output directory and program arguments" -ForegroundColor DarkGray
    Write-Host "  cxxforge.ps1 --out-dir build main.c -- 1 2 3" -ForegroundColor DarkGray
}

function Parse-Args {
    param([string[]]$argv)
    $i = 0
    while ($i -lt $argv.Count) {
        $a = $argv[$i]
        switch -Regex ($a) {
            '^--$' {
                $i++
                while ($i -lt $argv.Count) { $script:RUN_ARGS += $argv[$i]; $i++ }
                break
            }
            '^(-h|--help)$' { Show-Help; Exit-CxxForge 0 }
            '^(--color)$' { $script:USE_COLOR = $true; $i++; continue }
            '^(--no-color)$' { $script:USE_COLOR = $false; $i++; continue }
            '^(--force-ansi)$' { $script:FORCE_ANSI = $true; $i++; continue }
            '^(--raw)$' { $script:PRETTY = $false; $i++; continue }
            '^(--pretty)$' { $script:PRETTY = $true; $i++; continue }
            '^(--normalized-diag)$' { $script:NORMALIZE_DIAGNOSTICS = $true; $i++; continue }
            '^(-n|--no-run)$' { $script:DO_RUN = $false; $i++; continue }
            '^(-d|--debug)$' { $script:DEBUG_MODE = $true; $i++; continue }
            '^(-p|--profile)$' {
                if ($i + 1 -ge $argv.Count) { Write-Error "--profile requires a value"; Exit-CxxForge 2 }
                $script:PROFILE_NAME = $argv[$i+1]; $i += 2; continue
            }
            '^(-b|--backend)$' {
                if ($i + 1 -ge $argv.Count) { Write-Error "--backend requires a value"; Exit-CxxForge 2 }
                $script:BACKEND_OVERRIDE = $argv[$i+1]; $i += 2; continue
            }
            '^(-w|--watch)$' { $script:WATCH_MODE = $true; $i++; continue
            }
            '^(--watch-clear)$' { $script:WATCH_MODE = $true; $script:WATCH_CLEAR = $true; $i++; continue }
            '^(--watch-shell)$' { $script:WATCH_MODE = $true; $script:WATCH_SHELL_OVERRIDE = $true; $i++; continue }
            '^(--no-watch-shell)$' { $script:WATCH_SHELL_OVERRIDE = $false; $i++; continue }
            '^(--rebuild|-R)$' { $script:FORCE_REBUILD = $true; $i++; continue
            }
            '^(--clean)$' { $script:CLEAN_BUILD = $true; $script:DO_RUN = $false; $i++; continue }
            '^(--explain)$' { $script:EXPLAIN_BUILD = $true; $i++; continue }
            '^(-r|--run)$' { $script:DO_RUN = $true; $i++; continue }
            '^(--utf8-init)$' { $script:UTF8_INIT = $true; $i++; continue }
            '^(--out-dir)$' {
                if ($i + 1 -ge $argv.Count) { Write-Error "--out-dir requires a value. Use -h/--help for usage."; Exit-CxxForge 2 }
                $script:OUT_DIR = $argv[$i+1]; $i += 2; continue
            }
            '^(--out-name)$' {
                if ($i + 1 -ge $argv.Count) { Write-Error "--out-name requires a value. Use -h/--help for usage."; Exit-CxxForge 2 }
                $script:OUT_NAME = $argv[$i+1]; $i += 2; continue
            }
            default {
                if (-not $script:SRC) { $script:SRC = $a; $i++; continue }
                Write-Error "Unexpected extra argument: $a. Use -h/--help for usage."; Exit-CxxForge 2
            }
        }
    }
}

Parse-Args -argv $script:CXXFORGE_CLI_ARGS

if (-not $SRC) {
    Write-Host "No source file specified. Use -h for help."
    Exit-CxxForge 2
}

# Normalize possible extra quotes injected by outer runners (e.g., Code Runner expands "$fullFileName" inside quotes)
function Resolve-PathArg {
    param([string]$s)
    if (-not $s) { return $s }
    $t = $s.Trim()
    if ($t.Length -ge 2) {
        if (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'"))) {
            $t = $t.Substring(1, $t.Length - 2)
        }
    }
    return $t
}

$SRC = Resolve-PathArg $SRC
