# CXXForge compilation, incremental cache, linking, diagnostics, and normal execution.
# === Incremental build helpers ===
$script:compilerIdentityCache = @{}

function Get-StableHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-CompilerIdentity {
    param([string]$CompilerPath)
    if (-not $CompilerPath) { return '' }
    $key = [System.IO.Path]::GetFullPath($CompilerPath).ToLowerInvariant()
    if ($script:compilerIdentityCache.ContainsKey($key)) { return $script:compilerIdentityCache[$key] }
    $versionLine = ''
    try { $versionLine = [string](& $CompilerPath --version 2>$null | Select-Object -First 1) } catch {}
    $identity = "$key`n$versionLine"
    $script:compilerIdentityCache[$key] = $identity
    return $identity
}

function Get-DependencyPaths {
    param([string]$DependencyFile)
    if (-not (Test-Path -LiteralPath $DependencyFile)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $DependencyFile -Raw -ErrorAction Stop
        # Join Makefile continuation lines, then ignore -MP phony rules below the first logical rule.
        $logical = $raw -replace '\\\r?\n', ' '
        $firstRule = ($logical -split '\r?\n', 2)[0]
        $separator = $firstRule.IndexOf(': ')
        if ($separator -lt 0) { return @() }
        $body = $firstRule.Substring($separator + 2).Trim()
        $paths = @()
        foreach ($match in [regex]::Matches($body, '(?:\\ |[^\s])+')) {
            $path = $match.Value.Replace('\ ', ' ')
            if ($path) { $paths += $path }
        }
        return $paths
    } catch {
        return @()
    }
}

function Get-RebuildReason {
    param(
        [string]$SourcePath,
        [string]$ObjectPath,
        [string]$DependencyPath,
        [string]$MetadataPath,
        [string]$Fingerprint,
        [bool]$Force
    )
    if ($Force) { return 'forced rebuild' }
    if (-not (Test-Path -LiteralPath $ObjectPath)) { return 'object file missing' }
    if (-not (Test-Path -LiteralPath $MetadataPath)) { return 'build metadata missing' }
    if (-not (Test-Path -LiteralPath $DependencyPath)) { return 'dependency file missing' }
    try {
        $metadata = Get-Content -LiteralPath $MetadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($metadata.fingerprint -ne $Fingerprint) { return 'compiler or compile flags changed' }
    } catch {
        return 'build metadata invalid'
    }
    $objectTime = (Get-Item -LiteralPath $ObjectPath).LastWriteTimeUtc
    $dependencies = @(Get-DependencyPaths -DependencyFile $DependencyPath)
    if ($dependencies.Count -eq 0) { return 'dependency list empty' }
    foreach ($dependency in $dependencies) {
        if (-not (Test-Path -LiteralPath $dependency)) { return "dependency missing: $dependency" }
        if ((Get-Item -LiteralPath $dependency).LastWriteTimeUtc -gt $objectTime) {
            return "dependency changed: $dependency"
        }
    }
    return $null
}

# Build the argument list (order: flags, source, -o, output, link flags)
if ($IS_PROJECT_MODE) {
    # === Incremental Project Build ===
    $objDir = if ($OUT_DIR) { $OUT_DIR } else { $projDir }
    if (-not $CLEAN_BUILD -and -not (Test-Path $objDir)) { New-Item -ItemType Directory -Path $objDir -Force | Out-Null }
    $stateDir = Join-Path $objDir '.cxxforge'
    $objectDir = Join-Path $stateDir 'obj'
    $linkMetadataPath = Join-Path $stateDir 'link.meta.json'

    if ($CLEAN_BUILD) {
        if ((Split-Path $stateDir -Leaf) -ne '.cxxforge') { throw "Unsafe clean path: $stateDir" }
        if (Test-Path -LiteralPath $stateDir) { Remove-Item -LiteralPath $stateDir -Recurse -Force }
        if (Test-Path -LiteralPath $OUT) { Remove-Item -LiteralPath $OUT -Force }
        Write-Host "[CLEAN] Removed CXXForge outputs from: $objDir" -ForegroundColor DarkGreen
        Exit-CxxForge 0
    }

    if (-not (Test-Path $objectDir)) { New-Item -ItemType Directory -Path $objectDir -Force | Out-Null }
    $relink = $FORCE_REBUILD -or -not (Test-Path $OUT)
    $linkReason = if ($FORCE_REBUILD) { 'forced rebuild' } elseif (-not (Test-Path $OUT)) { 'executable missing' } else { $null }
    $objFiles = @()
    $compileOk = $true
    $projectOutput = @()

    # Link with the C++ driver whenever any translation unit is C++.
    $hasCxxSource = $false
    foreach ($candidate in $SRC_LIST) {
        if ((Get-LangByExt ([System.IO.Path]::GetExtension($candidate).ToLower())) -eq 'cxx') {
            $hasCxxSource = $true
            break
        }
    }
    if ($backend -eq 'clang') {
        $linkCompiler = if ($hasCxxSource) { $CLANGXX_PATH } else { $CLANG_PATH }
    } else {
        $linkCompiler = if ($hasCxxSource) { $GXX } else { $GCC }
    }

    foreach ($srcFile in $SRC_LIST) {
        $srcExt = [System.IO.Path]::GetExtension($srcFile).ToLower()
        $srcLang = Get-LangByExt $srcExt
        if (-not $srcLang) { Write-Host "[WARN] Skipping unknown extension: $srcFile" -ForegroundColor Yellow; continue }
        # Include a stable path hash so src/foo.cpp and lib/foo.cpp cannot collide.
        $normalizedSource = [System.IO.Path]::GetFullPath($srcFile).ToLowerInvariant()
        $pathHash = (Get-StableHash $normalizedSource).Substring(0, 12)
        $objBase = [System.IO.Path]::GetFileNameWithoutExtension($srcFile)
        $objName = "${objBase}.${pathHash}.o"
        $objPath = Join-Path $objectDir $objName
        $depPath = Join-Path $objectDir ("${objName}.d")
        $metadataPath = Join-Path $objectDir ("${objName}.meta.json")
        $objFiles += $objPath

        if ($srcLang -eq 'c') { $srcCompiler = if ($backend -eq 'clang') { $CLANG_PATH } else { $GCC } }
        else { $srcCompiler = if ($backend -eq 'clang') { $CLANGXX_PATH } else { $GXX } }
        $srcFlags = if ($srcLang -eq 'c') { $CFLAGS.Clone() } else { $CXXFLAGS.Clone() }
        if ($MAGIC_COMPILE_FLAGS.Count -gt 0) { $srcFlags += $MAGIC_COMPILE_FLAGS }
        if ($USE_COLOR) { $srcFlags += $COLOR_FLAG }
        foreach ($inc in $INCLUDES) { if ($inc) { $srcFlags += ('-I' + $inc) } }

        $fingerprintText = @(
            (Get-CompilerIdentity $srcCompiler),
            $srcLang,
            $normalizedSource,
            ($srcFlags -join "`n")
        ) -join "`n---`n"
        $fingerprint = Get-StableHash $fingerprintText
        $rebuildReason = Get-RebuildReason -SourcePath $srcFile -ObjectPath $objPath -DependencyPath $depPath -MetadataPath $metadataPath -Fingerprint $fingerprint -Force $FORCE_REBUILD

        if (-not $rebuildReason) {
            if ((Test-Path $OUT) -and (Get-Item $objPath).LastWriteTimeUtc -gt (Get-Item $OUT).LastWriteTimeUtc) {
                $relink = $true
                if (-not $linkReason) { $linkReason = "object newer than executable: $objName" }
            }
            $skipSuffix = if ($EXPLAIN_BUILD) { ' - dependencies and fingerprint unchanged' } else { '' }
            Write-Host "[SKIP] $srcFile$skipSuffix" -ForegroundColor DarkGray
            continue
        }

        $reasonSuffix = if ($EXPLAIN_BUILD) { " - $rebuildReason" } else { '' }
        Write-Host "[BUILD] $srcFile$reasonSuffix" -ForegroundColor DarkGreen
        $tempObjPath = "$objPath.tmp-$PID"
        $tempDepPath = "$depPath.tmp-$PID"
        $car = @()
        $car += $srcFlags
        $car += @('-MMD', '-MP', '-MF', $tempDepPath)
        $car += '-c'
        $car += $srcFile
        $car += '-o'
        $car += $tempObjPath
        try {
            $out2 = & $srcCompiler @car 2>&1
        } catch {
            if (Test-Path -LiteralPath $tempObjPath) { Remove-Item -LiteralPath $tempObjPath -Force }
            if (Test-Path -LiteralPath $tempDepPath) { Remove-Item -LiteralPath $tempDepPath -Force }
            Write-Host "[ERROR] Failed: $_" -ForegroundColor Red
            $compileOk = $false
            $rc = 5
            break
        }
        if ($out2) { $projectOutput += $out2 }
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $tempObjPath) { Remove-Item -LiteralPath $tempObjPath -Force }
            if (Test-Path -LiteralPath $tempDepPath) { Remove-Item -LiteralPath $tempDepPath -Force }
            Write-Host $out2
            Write-Host "[ERROR] Compile failed: $srcFile" -ForegroundColor Red
            $compileOk = $false; $rc = $LASTEXITCODE; break
        }
        Move-Item -LiteralPath $tempObjPath -Destination $objPath -Force
        Move-Item -LiteralPath $tempDepPath -Destination $depPath -Force
        $metadata = [ordered]@{
            fingerprint = $fingerprint
            source = $normalizedSource
            compiler = $srcCompiler
            generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Set-Content -LiteralPath $metadataPath -Value ($metadata | ConvertTo-Json -Depth 4) -Encoding UTF8
        $relink = $true
        if (-not $linkReason) { $linkReason = "object rebuilt: $objName" }
    }

    $linkFingerprintText = @(
        (Get-CompilerIdentity $linkCompiler),
        ($objFiles -join "`n"),
        ($LINK_PATH_FLAGS -join "`n"),
        ($LINKFLAGS -join "`n"),
        $OUT
    ) -join "`n---`n"
    $linkFingerprint = Get-StableHash $linkFingerprintText
    if (-not $relink) {
        if (-not (Test-Path -LiteralPath $linkMetadataPath)) {
            $relink = $true
            $linkReason = 'link metadata missing'
        } else {
            try {
                $linkMetadata = Get-Content -LiteralPath $linkMetadataPath -Raw | ConvertFrom-Json
                if ($linkMetadata.fingerprint -ne $linkFingerprint) {
                    $relink = $true
                    $linkReason = 'linker or link flags changed'
                }
            } catch {
                $relink = $true
                $linkReason = 'link metadata invalid'
            }
        }
    }

    if ($compileOk -and $relink) {
        $linkSuffix = if ($EXPLAIN_BUILD -and $linkReason) { " - $linkReason" } else { '' }
        Write-Host "[LINK] -> $OUT$linkSuffix" -ForegroundColor DarkGreen
        $tempOut = "$OUT.cxxforge-tmp-$PID.exe"
        $largs = @()
        $largs += $objFiles
        $largs += '-o'
        $largs += $tempOut
        $largs += $LINK_PATH_FLAGS
        foreach ($lf in $LINKFLAGS) { if ($lf) { $largs += $lf } }
        try {
            $linkOutput = & $linkCompiler @largs 2>&1
            $rc = $LASTEXITCODE
            if ($linkOutput) { $projectOutput += $linkOutput }
            if ($rc -eq 0) {
                Move-Item -LiteralPath $tempOut -Destination $OUT -Force
                $linkMetadata = [ordered]@{
                    fingerprint = $linkFingerprint
                    output = $OUT
                    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
                }
                Set-Content -LiteralPath $linkMetadataPath -Value ($linkMetadata | ConvertTo-Json -Depth 4) -Encoding UTF8
            } elseif (Test-Path -LiteralPath $tempOut) {
                Remove-Item -LiteralPath $tempOut -Force
            }
        } catch {
            if (Test-Path -LiteralPath $tempOut) { Remove-Item -LiteralPath $tempOut -Force }
            Write-Host "[ERROR] Link failed: $_" -ForegroundColor Red
            $rc = 5
        }
        $output = $projectOutput
    } elseif ($compileOk -and -not $relink) {
        $upToDateMessage = if ($EXPLAIN_BUILD) { '[INFO] All targets up to date; dependencies, fingerprints, and link state unchanged.' } else { '[INFO] All targets up to date.' }
        Write-Host $upToDateMessage -ForegroundColor DarkGray
        $output = @()
        $rc = 0
    } else {
        $output = $projectOutput
    }
} else {
    if ($CLEAN_BUILD) {
        if (Test-Path -LiteralPath $OUT) { Remove-Item -LiteralPath $OUT -Force }
        Write-Host "[CLEAN] Removed output: $OUT" -ForegroundColor DarkGreen
        Exit-CxxForge 0
    }
    $arglist = @()
    $arglist += $flags
    $arglist += $SRC_LIST
    $arglist += '-o'
    $arglist += $OUT
    foreach ($lf in $LINKFLAGS) { if ($lf) { $arglist += $lf } }

    # Invoke compiler and capture combined output
    try {
        $output = & $compiler @arglist 2>&1
    } catch {
        Write-Host "[ERROR] Failed to start compiler: $_" -ForegroundColor Red
        Exit-CxxForge 5
    }
    $rc = $LASTEXITCODE
}

# If compiler returned non-zero with no textual output, hint common Windows causes (DLL/path)
if (($rc -ne 0) -and ($null -eq $output -or $output.Count -eq 0)) {
    Write-Host "[WARN] Compiler exited with code $rc but emitted no diagnostics." -ForegroundColor Yellow
    Write-Host "[HINT] On Windows, missing MinGW DLLs or not having the compiler's bin dir on PATH can cause silent failures." -ForegroundColor Yellow
}

# Colorized replay of output
function Write-AnsiColored {
    param($text, $color)
    $esc = "`e"
    switch ($color) {
        'red' { "$esc[31m$text$esc[0m" }
        'yellow' { "$esc[33m$text$esc[0m" }
        default { $text }
    }
}

function Write-Info {
    param([string]$text, [ConsoleColor]$color = [ConsoleColor]::DarkGreen)
    Write-Host $text -ForegroundColor $color
}

function Write-ColoredSegments {
    param(
        [string]$text
    )
    $regex = "(''|\'[^']*\'|\[[-][^\]]+\])"
    $segMatches = [regex]::Matches($text, $regex)
    if ($segMatches.Count -eq 0) {
        Write-Host $text
        return
    }
    $pos = 0
    foreach ($m in $segMatches) {
        if ($m.Index -gt $pos) {
            $plain = $text.Substring($pos, $m.Index - $pos)
            Write-Host -NoNewline $plain
        }
        $tok = $m.Value
        if ($tok.StartsWith("'")) {
            Write-Host -NoNewline $tok -ForegroundColor Cyan
        } elseif ($tok.StartsWith("[")) {
            Write-Host -NoNewline $tok -ForegroundColor DarkYellow
        } else {
            Write-Host -NoNewline $tok
        }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $text.Length) {
        Write-Host -NoNewline ($text.Substring($pos))
    }
    Write-Host ""
}

function Write-GroupHeader {
    param([string]$file)
    if (-not $file) { return }
    if (-not $script:printedFiles.ContainsKey($file)) {
        Write-Host ""  # spacing
        Write-Host "[INFO] In file: $file" -ForegroundColor Blue
        $script:printedFiles[$file] = 1
    }
}

function Write-SourceWithCaretHighlight {
    param([string]$source, [string]$caret, [string]$sev)
    # Caret lines from clang/clang-cl usually look like: "   |     ^~~~~"
    # First, use the caret line to decide the span on the source line.
    $m = [regex]::Match($caret, '^(\s*\|?\s*)([\^~]+)')
    if ($m.Success) {
        $leadCount = $m.Groups[1].Value.Length
        $markLen = $m.Groups[2].Value.Length
        if ($leadCount -gt $source.Length) { $leadCount = $source.Length }
        $midLen = $markLen
        if ($leadCount + $midLen -gt $source.Length) { $midLen = [Math]::Max(0, $source.Length - $leadCount) }
        $before = if ($leadCount -gt 0) { $source.Substring(0,$leadCount) } else { "" }
        $mid = if ($midLen -gt 0) { $source.Substring($leadCount,$midLen) } else { "" }
        $after = $source.Substring([Math]::Min($source.Length, $leadCount + $midLen))
        if ($before.Length -gt 0) { Write-Host -NoNewline $before -ForegroundColor DarkGray }
        if ($mid.Length -gt 0) {
            if ($sev -ieq 'error') { Write-Host -NoNewline $mid -ForegroundColor Red } else { Write-Host -NoNewline $mid -ForegroundColor Yellow }
        }
        if ($after.Length -gt 0) { Write-Host -NoNewline $after -ForegroundColor DarkGray }
        Write-Host ""

        # Color caret/marker line to match severity (spaces + '|' dim, arrows bright)
        $cm = [regex]::Match($caret, '^(\s*\|?\s*)([\^~]+)(.*)$')
        if ($cm.Success) {
            $lead = $cm.Groups[1].Value
            $marks = $cm.Groups[2].Value
            $tail = $cm.Groups[3].Value
            if ($lead.Length -gt 0) { Write-Host -NoNewline $lead -ForegroundColor DarkGray }
            if ($marks.Length -gt 0) {
                if ($sev -ieq 'error') { Write-Host -NoNewline $marks -ForegroundColor Red } else { Write-Host -NoNewline $marks -ForegroundColor Yellow }
            }
            if ($tail.Length -gt 0) { Write-Host -NoNewline $tail -ForegroundColor DarkGray }
            Write-Host ""
        } else {
            if ($sev -ieq 'error') { Write-Host $caret -ForegroundColor Red } else { Write-Host $caret -ForegroundColor Yellow }
        }
    } else {
        Write-Host $source -ForegroundColor DarkGray
        Write-Host $caret -ForegroundColor Magenta
    }
}

function Write-DiagnosticLine {
    param($line)
    # Separate diagnostic blocks for readability when pretty-printing
    if ($script:expectSource -eq 0 -and $line -match '^(.*?):(\d+):(\d+):\s*(warning|error|note):') {
        if ($script:errCount -gt 0 -or $script:warnCount -gt 0) {
            Write-Host ""
        }
    }
    # If we are in caret-expected state, try to handle caret lines early
    if ($script:expectSource -eq 1 -and $line -match '^\s*\|?\s*[\^~]+') {
        Write-SourceWithCaretHighlight $script:pendingSourceLine $line $script:pendingSeverity
        $script:pendingSourceLine = $null
        $script:pendingSeverity = $null
        $script:expectSource = 0
        return
    }
    $m = [regex]::Match($line, '^(.*?):(\d+):(\d+):\s*(warning|error|note):\s*(.*)$')
    if ($m.Success) {
        $file = $m.Groups[1].Value
        $lin = $m.Groups[2].Value
        $col = $m.Groups[3].Value
        $sev = $m.Groups[4].Value
        $msg = $m.Groups[5].Value
        if ($sev -ieq 'error') { $script:errCount++ } elseif ($sev -ieq 'warning') { $script:warnCount++ }
        Write-GroupHeader $file
        Write-NormalizedDiagnostic -file $file -line $lin -col $col -sev $sev -msg $msg
        # When normalized diagnostics are enabled, the [LEVEL] line is the main view,
        # so we skip re-printing the original "warning:"/"error:" header line.
        if (-not $NORMALIZE_DIAGNOSTICS) {
            if ($FORCE_ANSI) {
                $sevColor = if ($sev -ieq 'error') { 'red' } else { 'yellow' }
                $out = "${file}:${lin}:${col}: " + (Write-AnsiColored($sev + ': ' + $msg, $sevColor))
                Write-Host $out
            } else {
                Write-Host -NoNewline $file -ForegroundColor DarkGray
                Write-Host -NoNewline (":" + $lin + ":" + $col + ": ") -ForegroundColor DarkCyan
                switch -Regex ($sev) {
                    'error'   { Write-Host -NoNewline ($sev + ": ") -ForegroundColor Red }
                    'warning' { Write-Host -NoNewline ($sev + ": ") -ForegroundColor Yellow }
                    'note'    { Write-Host -NoNewline ($sev + ": ") -ForegroundColor DarkMagenta }
                    default   { Write-Host -NoNewline ($sev + ": ") }
                }
                Write-ColoredSegments $msg
            }
        }
        $script:pendingSeverity = $sev
        $script:expectSource = 2
        return
    }
    $ctx = [regex]::Match($line, "(.*?)(In (member )?function '([^']+)':)(.*)")
    if ($ctx.Success) {
        $pre = $ctx.Groups[1].Value
        # $ctx.Groups[2].Value is the full tag; no need to store separately
        $isMember = $ctx.Groups[3].Success
        $fname = $ctx.Groups[4].Value
        $post = $ctx.Groups[5].Value
        if ($pre) { Write-Host -NoNewline $pre -ForegroundColor DarkGray }
        if ($isMember) {
            Write-Host -NoNewline "In member function '" -ForegroundColor DarkGray
        } else {
            Write-Host -NoNewline "In function '" -ForegroundColor DarkGray
        }
        Write-Host -NoNewline $fname -ForegroundColor Cyan
        Write-Host -NoNewline "':" -ForegroundColor DarkGray
        if ($post) { Write-Host -NoNewline $post -ForegroundColor DarkGray }
        Write-Host ""
        return
    }
    if ($line -match 'error:') {
        if ($NORMALIZE_DIAGNOSTICS) { return }
        if ($FORCE_ANSI) { Write-Host (Write-AnsiColored($line,'red')) } else { Write-Host $line -ForegroundColor DarkGray }
    } elseif ($line -match 'warning:') {
        if ($NORMALIZE_DIAGNOSTICS) { return }
        if ($FORCE_ANSI) { Write-Host (Write-AnsiColored($line,'yellow')) } else { Write-Host $line -ForegroundColor DarkGray }
    } elseif ($line -match 'note:') {
        if ($NORMALIZE_DIAGNOSTICS) { return }
        if ($FORCE_ANSI) { Write-Host (Write-AnsiColored($line,'yellow')) } else { Write-Host $line -ForegroundColor DarkGray }
    } else {
        if ($script:expectSource -gt 0) {
            if ($script:expectSource -eq 2) {
                $script:pendingSourceLine = $line
                $script:expectSource = 1
                return
            } elseif ($script:expectSource -eq 1) {
                if ($line -match '^\s*[\^~]+') {
                    Write-SourceWithCaretHighlight $script:pendingSourceLine $line $script:pendingSeverity
                    $script:pendingSourceLine = $null
                    $script:pendingSeverity = $null
                    $script:expectSource = 0
                    return
                } else {
                    if ($script:pendingSourceLine) { Write-Host $script:pendingSourceLine -ForegroundColor DarkGray }
                    $script:pendingSourceLine = $null
                    $script:pendingSeverity = $null
                    $script:expectSource = 0
                }
            }
        }
        Write-Host $line
    }
}

if ($PRETTY) {
    foreach ($line in $output) { Write-DiagnosticLine $line }
} elseif ($USE_COLOR) {
        foreach ($line in $output) {
            if ($line -match 'error:') {
                if ($FORCE_ANSI) { Write-Host (Write-AnsiColored($line,'red')) } else { Write-Host $line -ForegroundColor Red }
            } elseif ($line -match 'warning:') {
                if ($FORCE_ANSI) { Write-Host (Write-AnsiColored($line,'yellow')) } else { Write-Host $line -ForegroundColor Yellow }
            } else { Write-Host $line }
        }
} else {
    foreach ($line in $output) { Write-Host $line }
}

if ($rc -ne 0) {
    Write-Host ""
    if ($script:errCount -gt 0) {
        Write-Host "[ERROR] Build failed: $script:errCount error(s), $script:warnCount warning(s)" -ForegroundColor Red
    }
    Write-Host "[INFO] Summary: $script:errCount error(s), $script:warnCount warning(s)" -ForegroundColor Yellow
    Write-Host "[ERROR] Compile failed, exit=$rc" -ForegroundColor Red
    if (-not $WATCH_MODE) { Exit-CxxForge $rc }
    Write-Host "[WATCH] Compile failed. Waiting for file change..." -ForegroundColor Yellow
}

if (-not $WATCH_MODE) {
    if ($DO_RUN) {
        Write-Info "[INFO] Running: $OUT $($RUN_ARGS -join ' ')" Cyan
        if ($RUN_ARGS.Count -gt 0) {
            & $OUT @RUN_ARGS
        } else {
            & $OUT
        }
        Exit-CxxForge $LASTEXITCODE
    } else {
        Write-Info "[INFO] Build finished; skipping run (run disabled)" DarkGray
        Exit-CxxForge 0
    }
}
