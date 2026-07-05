# CXXForge project/configuration resolution and effective toolchain setup.
# === Project Mode Detection ===
if ($SRC -and (Test-Path $SRC) -and (Get-Item $SRC -ErrorAction SilentlyContinue).PSIsContainer) {
    $pf = Join-Path $SRC 'cxxforge.json'
    if (Test-Path $pf) { $SRC = $pf }
}
if ($SRC -and ($SRC -match 'cxxforge\.json$') -and (Test-Path $SRC)) {
    try {
        $proj = Get-Content -LiteralPath $SRC -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host "[ERROR] Invalid project file '$SRC': $_" -ForegroundColor Red
        Exit-CxxForge 2
    }
    $projDir = Split-Path $SRC -Parent
    Write-Host "[INFO] Project: $SRC" -ForegroundColor Cyan
    $IS_PROJECT_MODE = $true

    if ($proj.sources) {
        $SRC_LIST = @()
        foreach ($s in $proj.sources) {
            $full = Join-Path $projDir $s
            if (Test-Path $full) { $SRC_LIST += $full }
            else { Write-Host "[WARN] Source not found: $s" -ForegroundColor Yellow }
        }
        if ($SRC_LIST.Count -eq 0) {
            Write-Host "[ERROR] Project contains no valid source files: $SRC" -ForegroundColor Red
            Exit-CxxForge 3
        }
        $SRC = $SRC_LIST[0]
    } else {
        Write-Host "[ERROR] Project must define a non-empty 'sources' array: $SRC" -ForegroundColor Red
        Exit-CxxForge 2
    }
    if ($proj.outName) { $OUT_NAME = $proj.outName } else { $OUT_NAME = (Split-Path $projDir -Leaf) }
    if ($proj.outDir)  { $OUT_DIR = Join-Path $projDir $proj.outDir }
    if ($proj.includes) {
        foreach ($inc in $proj.includes) {
            $PROJECT_INCLUDES += (Join-Path $projDir $inc)
        }
    }
    if ($proj.links) {
        foreach ($l in $proj.links) { $PROJECT_LINKS += $l }
    }
}

if (-not (Test-Path $SRC)) {
    Write-Host "Source file not found: $SRC"
    Exit-CxxForge 3
}

# Optional UTF-8 initialization for direct invocations
if ($UTF8_INIT) {
    try {
        chcp.com 65001 2>&1 | Out-Null
        [Console]::InputEncoding = [System.Text.Encoding]::UTF8
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {}
}

# Toolchain configuration via fixed JSON (fallback to PATH if missing)
$configPath = Join-Path $script:CXXFORGE_ROOT 'compiler_config.json'
$GCC = $null
$GXX = $null
$CFLAGS = @()
$CXXFLAGS = @()
$COLOR_FLAG = '-fdiagnostics-color=always'
$INCLUDES = @()
$LIBPATHS = @()
$LINKFLAGS = @()
$LINK_PATH_FLAGS = @()
$AUTO_INC = $true
$AUTO_LIB = $true
$PROFILES = $null
$ACTIVE_PROFILE = $null
$COMPILER_BACKEND = 'gcc'
$CLANG_PATH = $null
$CLANGXX_PATH = $null

if (Test-Path $configPath) {
    try {
        $cfgRaw = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
        $cfg = $cfgRaw | ConvertFrom-Json -ErrorAction Stop
        if ($cfg.gccPath) { $GCC = [string]$cfg.gccPath }
        if ($cfg.gxxPath) { $GXX = [string]$cfg.gxxPath }
        if ($cfg.cFlags) { $CFLAGS = @($cfg.cFlags) }
        if ($cfg.cxxFlags) { $CXXFLAGS = @($cfg.cxxFlags) }
    if ($cfg.colorFlag) { $COLOR_FLAG = [string]$cfg.colorFlag }
    if ($cfg.includePaths) { $INCLUDES = @($cfg.includePaths) }
    if ($cfg.libPaths) { $LIBPATHS = @($cfg.libPaths) }
    if ($cfg.linkFlags) { $LINKFLAGS = @($cfg.linkFlags) }
    if ($cfg.PSObject.Properties.Name -contains 'injectCompilerBinToPath') { $INJECT_COMPILER_BIN = [bool]$cfg.injectCompilerBinToPath }
    if ($cfg.PSObject.Properties.Name -contains 'forceAsciiTemp') { $FORCE_ASCII_TEMP = [bool]$cfg.forceAsciiTemp }
    if ($cfg.PSObject.Properties.Name -contains 'autoDiscoverIncludes') { $AUTO_INC = [bool]$cfg.autoDiscoverIncludes }
    if ($cfg.PSObject.Properties.Name -contains 'autoDiscoverLibs') { $AUTO_LIB = [bool]$cfg.autoDiscoverLibs }
    if ($cfg.PSObject.Properties.Name -contains 'profiles') { $PROFILES = $cfg.profiles }
    if ($cfg.PSObject.Properties.Name -contains 'activeProfile') { $ACTIVE_PROFILE = [string]$cfg.activeProfile }
    if ($cfg.PSObject.Properties.Name -contains 'compilerBackend') { $COMPILER_BACKEND = [string]$cfg.compilerBackend }
    if ($cfg.clangPath) { $CLANG_PATH = [string]$cfg.clangPath }
    if ($cfg.clangXxPath) { $CLANGXX_PATH = [string]$cfg.clangXxPath }
    } catch {
        Write-Host "[WARN] Failed to read config '$configPath': $_" -ForegroundColor DarkYellow
    }
} else {
    Write-Host "[WARN] Config file not found: $configPath. Falling back to environment compilers." -ForegroundColor DarkYellow
}

# Apply portable project settings after the machine-local toolchain config.
# This order prevents compiler_config.json initialization from erasing them.
if ($PROJECT_INCLUDES.Count -gt 0) { $INCLUDES += $PROJECT_INCLUDES }
if ($PROJECT_LINKS.Count -gt 0) { $LINKFLAGS += $PROJECT_LINKS }

# Reasonable defaults if flags not provided by config
if ($CFLAGS.Count -eq 0) {
    $CFLAGS = @('-std=c99','-Wall','-finput-charset=UTF-8','-fexec-charset=UTF-8')
}
if ($CXXFLAGS.Count -eq 0) {
    $CXXFLAGS = @('-std=c++14','-Wall','-finput-charset=UTF-8','-fexec-charset=UTF-8')
}

# Profile resolution: --profile > --debug (maps to "debug") > activeProfile config
if ($DEBUG_MODE -and -not $PROFILE_NAME) { $PROFILE_NAME = 'debug' }
if (-not $PROFILE_NAME -and $ACTIVE_PROFILE) { $PROFILE_NAME = $ACTIVE_PROFILE }

if ($PROFILE_NAME -and $PROFILES) {
    $profile = $PROFILES.$PROFILE_NAME
    if ($profile) {
        if ($profile.cFlags)   { $CFLAGS += @($profile.cFlags) }
        if ($profile.cxxFlags) { $CXXFLAGS += @($profile.cxxFlags) }
        if ($profile.defines)  { $defFlags = $profile.defines | ForEach-Object { "-D$_" }; $CFLAGS += $defFlags; $CXXFLAGS += $defFlags }
        Write-Host "[INFO] Profile: $PROFILE_NAME" -ForegroundColor DarkGray
    } else {
        Write-Host "[WARN] Profile not found: '$PROFILE_NAME' (ignored)" -ForegroundColor DarkYellow
    }
}

# Resolve backend: command-line > config > default 'gcc'
if ($BACKEND_OVERRIDE) { $backend = $BACKEND_OVERRIDE } else { $backend = $COMPILER_BACKEND }

if ($backend -notin @('auto', 'gcc', 'clang')) {
    Write-Host "[ERROR] Unsupported backend '$backend'. Expected auto, gcc, or clang." -ForegroundColor Red
    Exit-CxxForge 2
}

# Auto-mode: try gcc first, fall back to clang
if ($backend -eq 'auto') {
    $hasGcc = ($GCC -and (Test-Path $GCC)) -or (Get-Command gcc -ErrorAction SilentlyContinue)
    if ($hasGcc) { $backend = 'gcc' } else { $backend = 'clang' }
}

# Resolve GCC paths: prefer configured path; else search PATH
if (-not $GCC -or -not (Test-Path $GCC)) {
    $g = Get-Command gcc -ErrorAction SilentlyContinue
    if ($g) { $GCC = $g.Path }
}
if (-not $GXX -or -not (Test-Path $GXX)) {
    $g = Get-Command g++ -ErrorAction SilentlyContinue
    if ($g) { $GXX = $g.Path }
}

# Resolve Clang paths
if (-not $CLANG_PATH -or -not (Test-Path $CLANG_PATH)) {
    $g = Get-Command clang -ErrorAction SilentlyContinue
    if ($g) { $CLANG_PATH = $g.Path }
}
if (-not $CLANGXX_PATH -or -not (Test-Path $CLANGXX_PATH)) {
    $g = Get-Command clang++ -ErrorAction SilentlyContinue
    if ($g) { $CLANGXX_PATH = $g.Path }
}

# --- Magic Comments Scanner (ra-link / ra-flags) ---
$MAGIC_COMPILE_FLAGS = @()
if (-not $IS_PROJECT_MODE) { $SRC_LIST = @($SRC) }

# Sidecar paths are relative to the primary source, not the caller's cwd.
$srcDir = [System.IO.Path]::GetDirectoryName((Resolve-Path $SRC).Path)

# 1. Check for Sidecar JSON Config
$sidecarJson = [System.IO.Path]::ChangeExtension($SRC, '.json')
if (Test-Path $sidecarJson) {
    try {
        Write-Host "[INFO] Found sidecar config: $sidecarJson" -ForegroundColor Cyan
        $jsonContent = Get-Content -LiteralPath $sidecarJson -Raw | ConvertFrom-Json
        if ($jsonContent.sources) {
            $SRC_LIST = @()
            foreach ($s in $jsonContent.sources) {
                $fullS = Join-Path $srcDir $s
                if (Test-Path $fullS) { $SRC_LIST += $fullS }
                else { Write-Host "[WARN] Source file in JSON not found: $s" -ForegroundColor Yellow }
            }
            if ($SRC_LIST.Count -eq 0) {
                Write-Host "[WARN] JSON sources list was empty or invalid. Falling back to $SRC" -ForegroundColor Yellow
                if (-not $IS_PROJECT_MODE) { $SRC_LIST = @($SRC) }
            }
        }
        if ($jsonContent.flags) {
            foreach ($f in $jsonContent.flags) { $MAGIC_COMPILE_FLAGS += $f }
            Write-Host "[INFO] JSON: Added compile flags" -ForegroundColor Cyan
        }
        if ($jsonContent.link) {
            foreach ($l in $jsonContent.link) { $LINKFLAGS += $l }
            Write-Host "[INFO] JSON: Added link flags" -ForegroundColor Cyan
        }
    } catch {
        Write-Host "[WARN] Failed to parse sidecar JSON: $_" -ForegroundColor Yellow
    }
}

# 2. Fallback to Magic Comments if no JSON sources override (or additive?)
# We scan the *primary* file ($SRC) for magic comments regardless, for backward compatibility.
try {
    # Scan first 50 lines for magic comments
    $headLines = Get-Content -LiteralPath $SRC -TotalCount 50 -ErrorAction SilentlyContinue
    foreach ($line in $headLines) {
        # Match: // ra-link: lib1 lib2 ...
        if ($line -match '^\s*//\s*ra-link:\s*(.+)$') {
            $argsStr = $matches[1].Trim()
            if ($argsStr) {
                $parts = $argsStr -split '\s+'
                $LINKFLAGS += $parts
                Write-Host "[INFO] Magic comment: Added link flags: $argsStr" -ForegroundColor Cyan
            }
        }
        # Match: // ra-flags: -flag1 -flag2 ...
        if ($line -match '^\s*//\s*ra-flags:\s*(.+)$') {
            $argsStr = $matches[1].Trim()
            if ($argsStr) {
                $parts = $argsStr -split '\s+'
                $MAGIC_COMPILE_FLAGS += $parts
                Write-Host "[INFO] Magic comment: Added compile flags: $argsStr" -ForegroundColor Cyan
            }
        }
    }
} catch {}
# ---------------------------------------------------

$ext = [System.IO.Path]::GetExtension($SRC).ToLower()
$srcBase = [System.IO.Path]::GetFileNameWithoutExtension($SRC)

function Resolve-OutputPath {
    $dir = if ($OUT_DIR) { $OUT_DIR } else { $srcDir }
    $name = if ($OUT_NAME) { $OUT_NAME } else { $srcBase }
    if (-not $CLEAN_BUILD -and -not (Test-Path -LiteralPath $dir)) { try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {} }
    return (Join-Path $dir ($name + '.exe'))
}
$OUT = Resolve-OutputPath

Write-Host "Building: $SRC" -ForegroundColor DarkGreen
Write-Host "[INFO] Building source file: $SRC" -ForegroundColor DarkGreen

function Get-LangByExt {
    param([string]$e)
    switch ($e) {
        '.c' { return 'c' }
        '.cpp' { return 'cxx' }
        '.cc' { return 'cxx' }
        '.cxx' { return 'cxx' }
        '.c++' { return 'cxx' }
        default { return $null }
    }
}

$lang = Get-LangByExt $ext
if (-not $lang) { Write-Host "Unsupported extension: $ext"; Exit-CxxForge 10 }

switch ($lang) {
    'c' {
        if ($backend -eq 'clang') {
            if (-not (Test-Path $CLANG_PATH)) { Write-Host "Clang not found: $CLANG_PATH"; Exit-CxxForge 4 }
            $compiler = $CLANG_PATH
        } else {
            if (-not (Test-Path $GCC)) { Write-Host "GCC not found: $GCC"; Exit-CxxForge 4 }
            $compiler = $GCC
        }
        $flags = $CFLAGS.Clone()
    }
    'cxx' {
        if ($backend -eq 'clang') {
            if (-not (Test-Path $CLANGXX_PATH)) { Write-Host "Clang++ not found: $CLANGXX_PATH"; Exit-CxxForge 4 }
            $compiler = $CLANGXX_PATH
        } else {
            if (-not (Test-Path $GXX)) { Write-Host "G++ not found: $GXX"; Exit-CxxForge 4 }
            $compiler = $GXX
        }
        $flags = $CXXFLAGS.Clone()
    }
}
Write-Host "[INFO] Backend: $backend" -ForegroundColor DarkGray


# Append magic compile flags detected earlier
if ($MAGIC_COMPILE_FLAGS.Count -gt 0) {
    $flags += $MAGIC_COMPILE_FLAGS
}

if ($USE_COLOR) { $flags += $COLOR_FLAG }

# Environment hardening: ensure compiler's bin dir is in PATH and TEMP/TMP are ASCII-only if requested
function Add-PathFrontIfMissing {
    param([string]$dir)
    if (-not $dir) { return }
    $current = [System.Environment]::GetEnvironmentVariable('Path','Process')
    $parts = ($current -split ';')
    if ($parts -notcontains $dir) {
        $newPath = if ($current) { $dir + ';' + $current } else { $dir }
        [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'Process')
        Write-Host "[DEBUG] PATH extended with compiler bin: $dir" -ForegroundColor DarkGray
    }
}

function Ensure-AsciiTemp {
    param([string]$fallback)
    try {
        $need = $false
        $check = $env:TEMP + '|' + $env:TMP
        if ($check -match "[^\x00-\x7F]") { $need = $true }
        if (-not $env:TEMP -or -not $env:TMP) { $need = $true }
        if ($need) {
            if (-not $fallback) { $fallback = Join-Path $env:USERPROFILE '.cpp_tmp' }
            if (-not (Test-Path $fallback)) { New-Item -ItemType Directory -Path $fallback -Force | Out-Null }
            $env:TEMP = $fallback
            $env:TMP = $fallback
            Write-Host "[DEBUG] TEMP/TMP redirected to ASCII path: $fallback" -ForegroundColor DarkGray
        }
    } catch {}
}

if ($INJECT_COMPILER_BIN) {
    $binDir = Split-Path -Parent $compiler
    Add-PathFrontIfMissing $binDir
}
if ($FORCE_ASCII_TEMP) { Ensure-AsciiTemp -fallback (Join-Path $env:LOCALAPPDATA 'cpp-tmp') }

# Apply include paths (-I) early for compilation, library paths (-L) for linking; link flags appended later.
if ($AUTO_INC -and $INCLUDES.Count -eq 0) {
    $autoInc = Get-AutoIncludePaths $compiler
    if ($autoInc.Count -gt 0) {
                Write-Host "[INFO] Auto-discovered include paths:" -ForegroundColor DarkGreen
                foreach ($p in $autoInc) { Write-Host "  $p" -ForegroundColor DarkGray }
        $INCLUDES = $autoInc
    } else {
                Write-Host "[WARN] No include paths auto-discovered (set includePaths in compiler_config.json to suppress this message)" -ForegroundColor DarkYellow
    }
}
foreach ($inc in $INCLUDES) { if ($inc) { $flags += ('-I' + $inc) } }
foreach ($lp in $LIBPATHS) {
    if ($lp) {
        $linkPathFlag = '-L' + $lp
        $flags += $linkPathFlag
        $LINK_PATH_FLAGS += $linkPathFlag
    }
}

# Auto-discover lib paths if none specified
if ($AUTO_LIB -and $LIBPATHS.Count -eq 0) {
    $autoLib = Get-AutoLibPaths $compiler
    if ($autoLib.Count -gt 0) {
                Write-Host "[INFO] Auto-discovered lib paths:" -ForegroundColor DarkGreen
                foreach ($p in $autoLib) { Write-Host "  $p" -ForegroundColor DarkGray }
        foreach ($p in $autoLib) {
            $linkPathFlag = '-L' + $p
            $flags += $linkPathFlag
            $LINK_PATH_FLAGS += $linkPathFlag
        }
    } else {
                Write-Host "[WARN] No lib paths auto-discovered (set libPaths in compiler_config.json to suppress this message)" -ForegroundColor DarkYellow
    }
}
