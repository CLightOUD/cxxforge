param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$runner = Join-Path $repoRoot 'cxxforge.ps1'
$installer = Join-Path $repoRoot 'install.ps1'
$syncTool = Join-Path $repoRoot 'tools\sync-installer-payload.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cxxforge comprehensive " + [guid]::NewGuid().ToString('N'))
$script:passed = 0
$script:failed = 0

function Write-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    if ($Passed) {
        $script:passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "[FAIL] $Name${Detail}" -ForegroundColor Red
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    Write-TestResult -Name $Name -Passed $Condition -Detail $(if ($Detail) { ": $Detail" } else { '' })
}

function Invoke-ProcessCase {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments,
        [int]$ExpectedExit = 0,
        [string]$OutputPattern = ''
    )

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $text = $lines -join "`n"
    $ok = $exitCode -eq $ExpectedExit
    if ($OutputPattern) { $ok = $ok -and $text.Contains($OutputPattern) }
    $detail = "expected exit=$ExpectedExit, actual=$exitCode"
    if ($OutputPattern) { $detail += ", expected output='$OutputPattern'" }
    Write-TestResult -Name $Name -Passed $ok -Detail $(if ($ok) { '' } else { ": $detail`n$text" })
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $text; Passed = $ok }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $parent = Split-Path $Path -Parent
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-JsoncFile {
    param([string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    $builder = New-Object System.Text.StringBuilder
    $inString = $false; $escaped = $false; $lineComment = $false; $blockComment = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        $next = if ($i + 1 -lt $text.Length) { $text[$i + 1] } else { [char]0 }
        if ($lineComment) { if ($ch -eq "`n") { $lineComment = $false; [void]$builder.Append($ch) }; continue }
        if ($blockComment) { if ($ch -eq '*' -and $next -eq '/') { $blockComment = $false; $i++; continue }; if ($ch -eq "`r" -or $ch -eq "`n") { [void]$builder.Append($ch) }; continue }
        if ($inString) { [void]$builder.Append($ch); if ($escaped) { $escaped = $false; continue }; if ($ch -eq '\') { $escaped = $true; continue }; if ($ch -eq '"') { $inString = $false }; continue }
        if ($ch -eq '"') { $inString = $true; [void]$builder.Append($ch); continue }
        if ($ch -eq '/' -and $next -eq '/') { $lineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }
        [void]$builder.Append($ch)
    }
    return $builder.ToString() | ConvertFrom-Json
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    Write-Host "[INFO] Isolated test root: $testRoot" -ForegroundColor DarkCyan

    # Static syntax and JSON validation.
    foreach ($relative in @('cxxforge.ps1', 'cxxforge\forge.ps1', 'cxxforge\run_active.ps1', 'cxxforge\modules\Core.ps1', 'cxxforge\modules\Configuration.ps1', 'cxxforge\modules\Build.ps1', 'cxxforge\modules\Watch.ps1', 'install.ps1', 'tools\sync-installer-payload.ps1', 'tests\integration.ps1', 'tests\comprehensive.ps1')) {
        $path = Join-Path $repoRoot $relative
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-True -Name "PowerShell syntax: $relative" -Condition ($errors.Count -eq 0) -Detail ($errors -join '; ')
    }
    foreach ($relative in @('cxxforge\compiler_config.json', 'cxxforge\compiler_config.default.json')) {
        $path = Join-Path $repoRoot $relative
        $valid = $true
        try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json | Out-Null }
        catch { $valid = $false }
        Assert-True -Name "JSON parse: $relative" -Condition $valid
    }

    # CLI validation and documented exit codes.
    Invoke-ProcessCase -Name 'help exits successfully' -ScriptPath $runner -Arguments @('--help') -OutputPattern 'Usage:' | Out-Null
    Invoke-ProcessCase -Name 'legacy run_active shim forwards to forge' -ScriptPath (Join-Path $repoRoot 'cxxforge\run_active.ps1') -Arguments @('--help') -OutputPattern 'Usage: cxxforge.ps1' | Out-Null
    Invoke-ProcessCase -Name 'missing source argument returns 2' -ScriptPath $runner -Arguments @() -ExpectedExit 2 | Out-Null
    Invoke-ProcessCase -Name 'nonexistent source returns 3' -ScriptPath $runner -Arguments @((Join-Path $testRoot 'missing.cpp')) -ExpectedExit 3 | Out-Null
    Invoke-ProcessCase -Name 'missing profile value returns 2' -ScriptPath $runner -Arguments @('--profile') -ExpectedExit 2 | Out-Null
    Invoke-ProcessCase -Name 'missing output directory value returns 2' -ScriptPath $runner -Arguments @('--out-dir') -ExpectedExit 2 | Out-Null
    $unsupported = Join-Path $testRoot 'unsupported.txt'
    Write-Utf8File $unsupported 'not C or C++'
    Invoke-ProcessCase -Name 'unsupported extension returns 10' -ScriptPath $runner -Arguments @($unsupported) -ExpectedExit 10 | Out-Null

    # Single-file C: argument forwarding, spaces in paths, custom output path/name.
    $singleC = Join-Path $testRoot 'single files\argument test.c'
    Write-Utf8File $singleC @'
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "hello world") != 0) return 9;
    puts("ARGS_OK");
    return 0;
}
'@
    $singleOut = Join-Path $testRoot 'custom output'
    Invoke-ProcessCase -Name 'single C compile/run and argument forwarding' -ScriptPath $runner -Arguments @('--no-color', '--out-dir', $singleOut, '--out-name', 'custom-c', $singleC, '--', 'hello world') -OutputPattern 'ARGS_OK' | Out-Null
    Assert-True -Name 'custom C output path created' -Condition (Test-Path -LiteralPath (Join-Path $singleOut 'custom-c.exe'))

    # Single-file C++ and profile handling.
    $singleCpp = Join-Path $testRoot 'single.cpp'
    Write-Utf8File $singleCpp @'
#include <algorithm>
#include <iostream>
#include <vector>
int main() {
    std::vector<int> values{3, 1, 2};
    std::sort(values.begin(), values.end());
    std::cout << "CPP_OK:" << values.front() << values.back() << '\n';
    return 0;
}
'@
    Invoke-ProcessCase -Name 'single C++ debug profile' -ScriptPath $runner -Arguments @('--no-color', '--profile', 'debug', '--out-dir', $singleOut, $singleCpp) -OutputPattern 'CPP_OK:13' | Out-Null
    Invoke-ProcessCase -Name 'invalid backend is rejected' -ScriptPath $runner -Arguments @('--backend', 'not-a-compiler', '--no-run', $singleCpp) -ExpectedExit 2 -OutputPattern 'Unsupported backend' | Out-Null

    $badProject = Join-Path $testRoot 'bad project\cxxforge.json'
    Write-Utf8File $badProject '{ this is not valid JSON'
    Invoke-ProcessCase -Name 'malformed project JSON is rejected cleanly' -ScriptPath $runner -Arguments @($badProject) -ExpectedExit 2 -OutputPattern 'Invalid project file' | Out-Null

    # Magic flags and program exit-code propagation.
    $magicC = Join-Path $testRoot 'magic.c'
    Write-Utf8File $magicC @'
// ra-flags: -DMAGIC_VALUE=42
#ifndef MAGIC_VALUE
#error MAGIC_VALUE missing
#endif
int main(void) { return MAGIC_VALUE == 42 ? 0 : 1; }
'@
    Invoke-ProcessCase -Name 'ra-flags magic comment' -ScriptPath $runner -Arguments @('--no-color', $magicC) | Out-Null
    $exitC = Join-Path $testRoot 'exit-code.c'
    Write-Utf8File $exitC 'int main(void) { return 7; }'
    Invoke-ProcessCase -Name 'program exit code is propagated' -ScriptPath $runner -Arguments @('--no-color', $exitC) -ExpectedExit 7 | Out-Null

    # Normalized diagnostics.
    $warningC = Join-Path $testRoot 'warning.c'
    Write-Utf8File $warningC 'int main(void) { int unused = 1; return 0; }'
    Invoke-ProcessCase -Name 'normalized warning diagnostics' -ScriptPath $runner -Arguments @('--no-run', '--no-color', '--normalized-diag', $warningC) -OutputPattern '[WARN]' | Out-Null

    # Explicit Clang backend when available.
    if (Get-Command clang++ -ErrorAction SilentlyContinue) {
        Invoke-ProcessCase -Name 'explicit Clang backend' -ScriptPath $runner -Arguments @('--backend', 'clang', '--no-run', '--no-color', '--out-dir', (Join-Path $testRoot 'clang'), $singleCpp) | Out-Null
    } else {
        Write-Host '[SKIP] explicit Clang backend: clang++ not available' -ForegroundColor Yellow
    }

    # Existing project/sidecar integration suite.
    Invoke-ProcessCase -Name 'repository integration suite' -ScriptPath (Join-Path $repoRoot 'tests\integration.ps1') -Arguments @() -OutputPattern '[PASS] CXXForge integration tests completed.' | Out-Null

    # 2.0 dependency tracking, fingerprints, clean, and atomic linking.
    $dependencyRoot = Join-Path $testRoot 'dependency project'
    $dependencySource = Join-Path $dependencyRoot 'main.cpp'
    $dependencyHeader = Join-Path $dependencyRoot 'include\value.hpp'
    $dependencyProject = Join-Path $dependencyRoot 'cxxforge.json'
    $dependencyOut = Join-Path $dependencyRoot 'build output'
    Write-Utf8File $dependencySource @'
#include <value.hpp>
int main() { return project_value == 2 ? 0 : 1; }
'@
    Write-Utf8File $dependencyHeader '#pragma once
constexpr int project_value = 1;
'
    Write-Utf8File $dependencyProject @'
{
    "sources": ["main.cpp"],
    "outName": "dependency-test",
    "includes": ["include"]
}
'@
    Invoke-ProcessCase -Name '2.0 initial dependency build' -ScriptPath $runner -Arguments @('--no-run', '--no-color', '--explain', '--out-dir', $dependencyOut, $dependencyProject) -OutputPattern 'object file missing' | Out-Null
    $dependencyObject = @(Get-ChildItem -LiteralPath $dependencyOut -Filter 'main.*.o' -Recurse)[0]
    $objectTimeBeforeHeader = $dependencyObject.LastWriteTimeUtc
    Start-Sleep -Milliseconds 1100
    Write-Utf8File $dependencyHeader '#pragma once
constexpr int project_value = 2;
'
    $headerResult = Invoke-ProcessCase -Name 'header change triggers dependency rebuild' -ScriptPath $runner -Arguments @('--no-run', '--no-color', '--explain', '--out-dir', $dependencyOut, $dependencyProject) -OutputPattern 'dependency changed:'
    $objectTimeAfterHeader = (Get-Item -LiteralPath $dependencyObject.FullName).LastWriteTimeUtc
    Assert-True -Name 'header rebuild refreshes object timestamp' -Condition ($objectTimeAfterHeader -gt $objectTimeBeforeHeader)
    $dependencyExe = Join-Path $dependencyOut 'dependency-test.exe'
    $dependencyRunLines = @(& $dependencyExe 2>&1)
    Assert-True -Name 'header rebuild updates executable behavior' -Condition ($LASTEXITCODE -eq 0) -Detail ($dependencyRunLines -join "`n")

    $objectTimeBeforeProfile = (Get-Item -LiteralPath $dependencyObject.FullName).LastWriteTimeUtc
    Start-Sleep -Milliseconds 1100
    Invoke-ProcessCase -Name 'profile change invalidates compile fingerprint' -ScriptPath $runner -Arguments @('--profile', 'debug', '--no-run', '--no-color', '--explain', '--out-dir', $dependencyOut, $dependencyProject) -OutputPattern 'compiler or compile flags changed' | Out-Null
    Assert-True -Name 'profile rebuild refreshes object timestamp' -Condition ((Get-Item -LiteralPath $dependencyObject.FullName).LastWriteTimeUtc -gt $objectTimeBeforeProfile)

    $watchStdout = Join-Path $dependencyRoot 'watch.stdout.log'
    $watchStderr = Join-Path $dependencyRoot 'watch.stderr.log'
    $watchArgumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" --watch --no-watch-shell --no-run --no-color --explain --out-dir `"$dependencyOut`" `"$dependencyProject`""
    $watchProcess = Start-Process -FilePath 'powershell' -ArgumentList $watchArgumentLine -WindowStyle Hidden -RedirectStandardOutput $watchStdout -RedirectStandardError $watchStderr -PassThru
    try {
        $watchReady = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
            if (Test-Path -LiteralPath $watchStdout) {
                $watchText = Get-Content -LiteralPath $watchStdout -Raw -ErrorAction SilentlyContinue
                if ($watchText -match '\[WATCH\] Monitoring') { $watchReady = $true; break }
            }
            if ($watchProcess.HasExited) { break }
        }
        Assert-True -Name 'Watch 2.0 reaches monitoring state' -Condition $watchReady -Detail $(if (Test-Path $watchStderr) { Get-Content $watchStderr -Raw } else { '' })

        Write-Utf8File $dependencyHeader '#pragma once
// watch-trigger
constexpr int project_value = 2;
'
        $watchRebuilt = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
            $watchText = if (Test-Path -LiteralPath $watchStdout) { Get-Content -LiteralPath $watchStdout -Raw -ErrorAction SilentlyContinue } else { '' }
            if ($watchText -match '\[WATCH\] Change detected' -and $watchText -match 'dependency changed:' -and $watchText -match '\[WATCH\] Rebuild completed') { $watchRebuilt = $true; break }
            if ($watchProcess.HasExited) { break }
        }
        Assert-True -Name 'Watch 2.0 rebuilds after header change' -Condition $watchRebuilt -Detail $watchText
        Assert-True -Name 'Watch 2.0 remains active after rebuild' -Condition (-not $watchProcess.HasExited)
    } finally {
        if (-not $watchProcess.HasExited) { $watchProcess.Kill(); $watchProcess.WaitForExit() }
    }

    $runtimeWatchRoot = Join-Path $testRoot 'runtime watch project'
    $runtimeWatchSource = Join-Path $runtimeWatchRoot 'main.cpp'
    $runtimeWatchHeader = Join-Path $runtimeWatchRoot 'version.hpp'
    $runtimeWatchProject = Join-Path $runtimeWatchRoot 'cxxforge.json'
    $runtimeWatchOut = Join-Path $runtimeWatchRoot 'build'
    Write-Utf8File $runtimeWatchSource @'
#include "version.hpp"
#include <chrono>
#include <iostream>
#include <thread>
int main() {
    std::cout << "RUN_VERSION=" << WATCH_VERSION << std::endl;
#if WATCH_VERSION == 1
    for (;;) std::this_thread::sleep_for(std::chrono::milliseconds(100));
#endif
    return 0;
}
'@
    Write-Utf8File $runtimeWatchHeader '#pragma once
#define WATCH_VERSION 1
'
    Write-Utf8File $runtimeWatchProject '{"sources":["main.cpp"],"outName":"runtime-watch","includes":["."]}'
    $runtimeWatchStdout = Join-Path $runtimeWatchRoot 'watch.stdout.log'
    $runtimeWatchStderr = Join-Path $runtimeWatchRoot 'watch.stderr.log'
    $runtimeWatchArgumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" --watch --no-watch-shell --no-color --explain --out-dir `"$runtimeWatchOut`" `"$runtimeWatchProject`""
    $runtimeWatchProcess = Start-Process -FilePath 'powershell' -ArgumentList $runtimeWatchArgumentLine -WindowStyle Hidden -RedirectStandardOutput $runtimeWatchStdout -RedirectStandardError $runtimeWatchStderr -PassThru
    try {
        $initialRuntimeStarted = $false
        $oldRuntimePid = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
            $runtimeText = if (Test-Path $runtimeWatchStdout) { Get-Content $runtimeWatchStdout -Raw -ErrorAction SilentlyContinue } else { '' }
            if ($runtimeText -match 'RUN_VERSION=1' -and $runtimeText -match '\[WATCH\] Monitoring') {
                $pidMatch = [regex]::Match($runtimeText, 'Program started \(pid=(\d+)\)')
                if ($pidMatch.Success) { $oldRuntimePid = [int]$pidMatch.Groups[1].Value }
                $initialRuntimeStarted = $true
                break
            }
            if ($runtimeWatchProcess.HasExited) { break }
        }
        Assert-True -Name 'Watch starts long-running program asynchronously' -Condition $initialRuntimeStarted -Detail $runtimeText

        Write-Utf8File $runtimeWatchHeader '#pragma once
#define WATCH_VERSION 2
'
        $runtimeRestarted = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
            $runtimeText = if (Test-Path $runtimeWatchStdout) { Get-Content $runtimeWatchStdout -Raw -ErrorAction SilentlyContinue } else { '' }
            if ($runtimeText -match 'Stopping program' -and $runtimeText -match 'RUN_VERSION=2' -and $runtimeText -match 'Program exited with code 0') {
                $runtimeRestarted = $true
                break
            }
            if ($runtimeWatchProcess.HasExited) { break }
        }
        Assert-True -Name 'Watch interrupts running program and launches rebuilt version' -Condition $runtimeRestarted -Detail $runtimeText
        if ($oldRuntimePid) {
            $oldProcessAlive = $null -ne (Get-Process -Id $oldRuntimePid -ErrorAction SilentlyContinue)
            Assert-True -Name 'previous long-running program process is terminated' -Condition (-not $oldProcessAlive)
        }
        Assert-True -Name 'Watch remains active after restarted program exits' -Condition (-not $runtimeWatchProcess.HasExited)
    } finally {
        if (-not $runtimeWatchProcess.HasExited) { $runtimeWatchProcess.Kill(); $runtimeWatchProcess.WaitForExit() }
    }

    $shellCommands = Join-Path $runtimeWatchRoot 'shell.commands.txt'
    Write-Utf8File $shellCommands ":status`r`n:run`r`n:run`r`n:quit`r`n"
    $shellStdout = Join-Path $runtimeWatchRoot 'shell.stdout.log'
    $shellStderr = Join-Path $runtimeWatchRoot 'shell.stderr.log'
    $shellArgumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" --watch --watch-shell --no-color --out-dir `"$runtimeWatchOut`" `"$runtimeWatchProject`""
    $shellProcess = Start-Process -FilePath 'powershell' -ArgumentList $shellArgumentLine -WindowStyle Hidden -RedirectStandardInput $shellCommands -RedirectStandardOutput $shellStdout -RedirectStandardError $shellStderr -PassThru
    $shellExited = $shellProcess.WaitForExit(25000)
    if (-not $shellExited) { $shellProcess.Kill(); $shellProcess.WaitForExit() }
    $shellText = if (Test-Path $shellStdout) { Get-Content $shellStdout -Raw } else { '' }
    $runCount = [regex]::Matches($shellText, 'RUN_VERSION=2').Count
    Assert-True -Name 'Watch subshell can run the same executable repeatedly' -Condition ($shellExited -and $runCount -ge 3) -Detail $shellText
    Assert-True -Name 'Watch subshell status command reports target' -Condition ($shellText -match '\[WATCH\] Target:')

    $stdinRoot = Join-Path $testRoot 'watch stdin project'
    $stdinSource = Join-Path $stdinRoot 'main.cpp'
    $stdinProject = Join-Path $stdinRoot 'cxxforge.json'
    $stdinOut = Join-Path $stdinRoot 'build'
    Write-Utf8File $stdinSource @'
#include <algorithm>
#include <iostream>
#include <vector>
int main() {
    int n = 0;
    if (!(std::cin >> n)) return 2;
    std::vector<int> values(n);
    for (int &value : values) std::cin >> value;
    std::sort(values.begin(), values.end());
    std::cout << "PROGRAM_INPUT=";
    for (int value : values) std::cout << value;
    std::cout << std::endl;
    return 0;
}
'@
    Write-Utf8File $stdinProject '{"sources":["main.cpp"],"outName":"stdin-watch"}'
    $stdinArgumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$runner`" --watch --watch-shell --no-color --out-dir `"$stdinOut`" `"$stdinProject`""
    $stdinStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $stdinStartInfo.FileName = (Get-Command powershell).Source
    $stdinStartInfo.Arguments = $stdinArgumentLine
    $stdinStartInfo.UseShellExecute = $false
    $stdinStartInfo.CreateNoWindow = $true
    $stdinStartInfo.RedirectStandardInput = $true
    $stdinStartInfo.RedirectStandardOutput = $true
    $stdinStartInfo.RedirectStandardError = $true
    $stdinWatchProcess = New-Object System.Diagnostics.Process
    $stdinWatchProcess.StartInfo = $stdinStartInfo
    [void]$stdinWatchProcess.Start()
    $stdinOutputTask = $stdinWatchProcess.StandardOutput.ReadToEndAsync()
    $stdinErrorTask = $stdinWatchProcess.StandardError.ReadToEndAsync()
    Start-Sleep -Seconds 5
    $stdinWatchProcess.StandardInput.WriteLine('run')
    $stdinWatchProcess.StandardInput.Flush()
    Start-Sleep -Seconds 2
    $stdinWatchProcess.StandardInput.WriteLine('4')
    $stdinWatchProcess.StandardInput.Flush()
    Start-Sleep -Milliseconds 300
    $stdinWatchProcess.StandardInput.WriteLine('4 1 3 2')
    $stdinWatchProcess.StandardInput.Flush()
    Start-Sleep -Seconds 2
    $stdinWatchProcess.StandardInput.WriteLine(':quit')
    $stdinWatchProcess.StandardInput.Flush()
    $stdinShellExited = $stdinWatchProcess.WaitForExit(25000)
    if (-not $stdinShellExited) { $stdinWatchProcess.Kill(); $stdinWatchProcess.WaitForExit() }
    $stdinText = $stdinOutputTask.Result
    $stdinErrorText = $stdinErrorTask.Result
    $stdinProgramStarts = [regex]::Matches($stdinText, 'Program started \(pid=').Count
    Assert-True -Name 'Watch handles run then delayed multi-line cin input' -Condition ($stdinShellExited -and $stdinProgramStarts -ge 2 -and $stdinText -match 'PROGRAM_INPUT=1234' -and $stdinText -notmatch "Unknown Watch command '4'") -Detail ($stdinText + $stdinErrorText)
    $stdinWatchProcess.Dispose()

    $goodExeHash = (Get-FileHash -LiteralPath $dependencyExe -Algorithm SHA256).Hash
    Write-Utf8File $dependencyProject @'
{
    "sources": ["main.cpp"],
    "outName": "dependency-test",
    "includes": ["include"],
    "links": ["-lthis_library_must_not_exist"]
}
'@
    $badLinkResult = Invoke-ProcessCase -Name 'invalid link fails without replacing output' -ScriptPath $runner -Arguments @('--no-run', '--no-color', '--explain', '--out-dir', $dependencyOut, $dependencyProject) -ExpectedExit 1 -OutputPattern 'find'
    Assert-True -Name 'atomic link preserves previous executable' -Condition ((Test-Path -LiteralPath $dependencyExe) -and ((Get-FileHash -LiteralPath $dependencyExe -Algorithm SHA256).Hash -eq $goodExeHash))

    Invoke-ProcessCase -Name 'project clean command' -ScriptPath $runner -Arguments @('--clean', '--no-color', '--out-dir', $dependencyOut, $dependencyProject) -OutputPattern '[CLEAN]' | Out-Null
    Assert-True -Name 'clean removes executable' -Condition (-not (Test-Path -LiteralPath $dependencyExe))
    Assert-True -Name 'clean removes CXXForge state' -Condition (-not (Test-Path -LiteralPath (Join-Path $dependencyOut '.cxxforge')))

    # Installer payload generation must be deterministic.
    Invoke-ProcessCase -Name 'synchronize installer payload' -ScriptPath $syncTool -Arguments @() -OutputPattern '[OK]' | Out-Null
    $hash1 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    Invoke-ProcessCase -Name 'repeat installer payload synchronization' -ScriptPath $syncTool -Arguments @() -OutputPattern '[OK]' | Out-Null
    $hash2 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    Assert-True -Name 'installer generation is byte-idempotent' -Condition ($hash1 -eq $hash2)

    # WhatIf must not create the target workspace.
    $whatIfRoot = Join-Path $testRoot 'whatif workspace'
    Invoke-ProcessCase -Name 'installer WhatIf mode' -ScriptPath $installer -Arguments @('-Workspace', $whatIfRoot, '-WhatIf') -OutputPattern 'Dry-run complete' | Out-Null
    Assert-True -Name 'WhatIf leaves no workspace behind' -Condition (-not (Test-Path -LiteralPath $whatIfRoot))

    # Real offline portable installation and installed-runner smoke test.
    $installRoot = Join-Path $testRoot 'installed workspace'
    $utf8ChineseDetail = -join @([char]0x8C03, [char]0x8BD5, [char]0x5668, [char]0x751F, [char]0x6210, [char]0x7684, [char]0x4EFB, [char]0x52A1, [char]0x3002)
    $taskFixture = @'
{
  // USER_TASK_COMMENT_KEEP_EXACTLY
  // USER_TASK_DECOY_KEEP_EXACTLY: example "tasks": {}
  "version": "2.0.0",
  "tasks": [
    { "label": "User Task", "type": "shell", "command": "echo user", "detail": "__UTF8_CHINESE_DETAIL__" }
  ]
}
'@
    Write-Utf8File (Join-Path $installRoot '.vscode\tasks.json') ($taskFixture.Replace('__UTF8_CHINESE_DETAIL__', $utf8ChineseDetail))
    Write-Utf8File (Join-Path $installRoot '.vscode\launch.json') @'
{
  // USER_LAUNCH_COMMENT_KEEP_EXACTLY
  "version": "0.2.0",
  "configurations": [
    { "name": "User Launch", "type": "cppdbg", "request": "launch", "program": "user.exe" }
  ]
}
'@
    Write-Utf8File (Join-Path $installRoot '.vscode\c_cpp_properties.json') @'
{
  // USER_CPP_COMMENT_KEEP_EXACTLY
  "version": 4,
  "configurations": [
    { "name": "User IntelliSense", "includePath": ["${workspaceFolder}/user"] }
  ]
}
'@
    Write-Utf8File (Join-Path $installRoot '.vscode\settings.json') @'
{
  // USER_SETTINGS_COMMENT_KEEP_EXACTLY
  "editor.tabSize": 7, // INLINE_COMMENT_KEEP_EXACTLY
  "example.url": "https://example.invalid/a//b"
}
'@
    Invoke-ProcessCase -Name 'real portable installation' -ScriptPath $installer -Arguments @('-Workspace', $installRoot) -OutputPattern 'Installation completed' | Out-Null
    foreach ($relative in @('cxxforge.ps1', 'cxxforge\forge.ps1', 'cxxforge\run_active.ps1', 'cxxforge\run_active.bat', 'cxxforge\modules\Core.ps1', 'cxxforge\modules\Configuration.ps1', 'cxxforge\modules\Build.ps1', 'cxxforge\modules\Watch.ps1', 'cxxforge\compiler_config.json', '.vscode\tasks.json', '.vscode\launch.json')) {
        Assert-True -Name "installed file exists: $relative" -Condition (Test-Path -LiteralPath (Join-Path $installRoot $relative))
    }
    $installedRunner = Join-Path $installRoot 'cxxforge.ps1'
    Invoke-ProcessCase -Name 'installed portable runner compiles C' -ScriptPath $installedRunner -Arguments @('--no-run', '--no-color', '--out-dir', (Join-Path $installRoot 'build'), $singleC) | Out-Null

    $sourceRunnerText = (Get-Content -LiteralPath $runner -Raw).TrimEnd()
    $installedRunnerText = (Get-Content -LiteralPath $installedRunner -Raw).TrimEnd()
    Assert-True -Name 'installed public entry matches canonical source' -Condition ($sourceRunnerText -eq $installedRunnerText)
    $sourceInternalForge = (Get-Content -LiteralPath (Join-Path $repoRoot 'cxxforge\forge.ps1') -Raw).TrimEnd()
    $installedInternalForge = (Get-Content -LiteralPath (Join-Path $installRoot 'cxxforge\forge.ps1') -Raw).TrimEnd()
    Assert-True -Name 'installed internal forge payload matches canonical source' -Condition ($sourceInternalForge -eq $installedInternalForge)
    foreach ($moduleName in @('Core.ps1', 'Configuration.ps1', 'Build.ps1', 'Watch.ps1')) {
        $sourceModule = (Get-Content -LiteralPath (Join-Path $repoRoot "cxxforge\modules\$moduleName") -Raw).TrimEnd()
        $installedModule = (Get-Content -LiteralPath (Join-Path $installRoot "cxxforge\modules\$moduleName") -Raw).TrimEnd()
        Assert-True -Name "installed module payload matches: $moduleName" -Condition ($sourceModule -eq $installedModule)
    }
    $manifestPath = Join-Path $installRoot '.cxxforge\manifest.json'
    Assert-True -Name 'installer writes lifecycle manifest' -Condition (Test-Path -LiteralPath $manifestPath)
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $expectedVersion = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
    Assert-True -Name 'manifest records version from VERSION' -Condition ($manifest.installerVersion -eq $expectedVersion)
    Assert-True -Name 'manifest uses schema 2' -Condition ($manifest.schemaVersion -eq 2)
    Assert-True -Name 'manifest records public entry' -Condition ($manifest.publicEntry -eq 'cxxforge.ps1')
    Assert-True -Name 'manifest records nine managed runtime files' -Condition (@($manifest.files).Count -eq 9)

    $installedTasks = Read-JsoncFile (Join-Path $installRoot '.vscode\tasks.json')
    $installedLaunch = Read-JsoncFile (Join-Path $installRoot '.vscode\launch.json')
    $installedCpp = Read-JsoncFile (Join-Path $installRoot '.vscode\c_cpp_properties.json')
    Assert-True -Name 'installation preserves existing user task' -Condition ('User Task' -in @($installedTasks.tasks.label))
    Assert-True -Name 'installation preserves UTF-8 no-BOM task text' -Condition ($utf8ChineseDetail -in @($installedTasks.tasks.detail))
    Assert-True -Name 'installation preserves existing launch configuration' -Condition ('User Launch' -in @($installedLaunch.configurations.name))
    Assert-True -Name 'installation preserves existing IntelliSense configuration' -Condition ('User IntelliSense' -in @($installedCpp.configurations.name))
    foreach ($comment in @('USER_TASK_COMMENT_KEEP_EXACTLY', 'USER_TASK_DECOY_KEEP_EXACTLY', 'USER_LAUNCH_COMMENT_KEEP_EXACTLY', 'USER_CPP_COMMENT_KEEP_EXACTLY', 'USER_SETTINGS_COMMENT_KEEP_EXACTLY')) {
        $allVSCodeText = @('tasks.json', 'launch.json', 'c_cpp_properties.json', 'settings.json') | ForEach-Object { Get-Content -LiteralPath (Join-Path $installRoot ".vscode\$_") -Raw }
        Assert-True -Name "installation preserves JSONC comment: $comment" -Condition (($allVSCodeText -join "`n").Contains($comment))
    }
    $installedSettingsRaw = Get-Content -LiteralPath (Join-Path $installRoot '.vscode\settings.json') -Raw
    Assert-True -Name 'installation preserves exact user indentation and inline comment' -Condition ($installedSettingsRaw.Contains('  "editor.tabSize": 7, // INLINE_COMMENT_KEEP_EXACTLY'))

    # A normal reinstall must preserve user-owned compiler_config.json.
    $installedConfig = Join-Path $installRoot 'cxxforge\compiler_config.json'
    $configBefore = Get-Content -LiteralPath $installedConfig -Raw
    Invoke-ProcessCase -Name 'portable reinstall without Force' -ScriptPath $installer -Arguments @('-Workspace', $installRoot) -OutputPattern 'Skip (exists)' | Out-Null
    $configAfter = Get-Content -LiteralPath $installedConfig -Raw
    Assert-True -Name 'reinstall preserves compiler configuration' -Condition ($configBefore -eq $configAfter)

    # Upgrade preserves modifications, Repair restores core files, Uninstall removes only proven managed content.
    Add-Content -LiteralPath $installedRunner -Value '# user-modified forge entry'
    Add-Content -LiteralPath $installedConfig -Value ' '
    $modifiedRunnerHash = (Get-FileHash -LiteralPath $installedRunner -Algorithm SHA256).Hash
    $modifiedConfigHash = (Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash
    Invoke-ProcessCase -Name 'upgrade preserves modified core file' -ScriptPath $installer -Arguments @('-Workspace', $installRoot, '-Upgrade') -OutputPattern 'Modified file preserved' | Out-Null
    Assert-True -Name 'upgrade keeps modified forge entry in place' -Condition ((Get-FileHash -LiteralPath $installedRunner -Algorithm SHA256).Hash -eq $modifiedRunnerHash)
    Assert-True -Name 'upgrade emits forge replacement candidate' -Condition (Test-Path -LiteralPath "$installedRunner.cxxforge-new")
    Assert-True -Name 'upgrade preserves compiler configuration' -Condition ((Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash -eq $modifiedConfigHash)

    Invoke-ProcessCase -Name 'repair restores managed forge entry' -ScriptPath $installer -Arguments @('-Workspace', $installRoot, '-Repair') -OutputPattern 'Installation completed' | Out-Null
    Assert-True -Name 'repair restores canonical forge payload' -Condition (((Get-Content -LiteralPath $installedRunner -Raw).TrimEnd()) -eq $sourceRunnerText)
    Assert-True -Name 'repair still preserves compiler configuration' -Condition ((Get-FileHash -LiteralPath $installedConfig -Algorithm SHA256).Hash -eq $modifiedConfigHash)

    Invoke-ProcessCase -Name 'manifest-driven uninstall' -ScriptPath $installer -Arguments @('-Workspace', $installRoot, '-Uninstall') -OutputPattern 'uninstall completed' | Out-Null
    Assert-True -Name 'uninstall removes public entry' -Condition (-not (Test-Path -LiteralPath $installedRunner))
    Assert-True -Name 'uninstall removes internal forge entry' -Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot 'cxxforge\forge.ps1')))
    Assert-True -Name 'uninstall removes runtime modules' -Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot 'cxxforge\modules\Core.ps1')))
    Assert-True -Name 'uninstall removes unmodified batch shim' -Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot 'cxxforge\run_active.bat')))
    Assert-True -Name 'uninstall preserves modified compiler configuration' -Condition (Test-Path -LiteralPath $installedConfig)
    Assert-True -Name 'uninstall removes manifest' -Condition (-not (Test-Path -LiteralPath $manifestPath))

    $uninstalledTasks = Read-JsoncFile (Join-Path $installRoot '.vscode\tasks.json')
    $uninstalledLaunch = Read-JsoncFile (Join-Path $installRoot '.vscode\launch.json')
    $uninstalledCpp = Read-JsoncFile (Join-Path $installRoot '.vscode\c_cpp_properties.json')
    $uninstalledSettings = Read-JsoncFile (Join-Path $installRoot '.vscode\settings.json')
    Assert-True -Name 'uninstall preserves user task' -Condition ('User Task' -in @($uninstalledTasks.tasks.label))
    Assert-True -Name 'uninstall preserves UTF-8 task text' -Condition ($utf8ChineseDetail -in @($uninstalledTasks.tasks.detail))
    Assert-True -Name 'uninstall removes CXXForge tasks' -Condition ('Run Active (PS)' -notin @($uninstalledTasks.tasks.label))
    Assert-True -Name 'uninstall preserves user launch configuration' -Condition ('User Launch' -in @($uninstalledLaunch.configurations.name))
    Assert-True -Name 'uninstall removes CXXForge launch configuration' -Condition ('CXXForge: Debug Active File' -notin @($uninstalledLaunch.configurations.name))
    Assert-True -Name 'uninstall preserves user IntelliSense configuration' -Condition ('User IntelliSense' -in @($uninstalledCpp.configurations.name))
    Assert-True -Name 'uninstall removes CXXForge IntelliSense configuration' -Condition ('CXXForge' -notin @($uninstalledCpp.configurations.name))
    Assert-True -Name 'uninstall preserves unrelated VS Code setting' -Condition ($uninstalledSettings.'editor.tabSize' -eq 7)
    Assert-True -Name 'JSONC parser preserves URL-like string content' -Condition ($uninstalledSettings.'example.url' -eq 'https://example.invalid/a//b')
    $uninstalledVSCodeText = @('tasks.json', 'launch.json', 'c_cpp_properties.json', 'settings.json') | ForEach-Object { Get-Content -LiteralPath (Join-Path $installRoot ".vscode\$_") -Raw }
    Assert-True -Name 'uninstall preserves all user JSONC comments' -Condition ((@('USER_TASK_COMMENT_KEEP_EXACTLY', 'USER_TASK_DECOY_KEEP_EXACTLY', 'USER_LAUNCH_COMMENT_KEEP_EXACTLY', 'USER_CPP_COMMENT_KEEP_EXACTLY', 'USER_SETTINGS_COMMENT_KEEP_EXACTLY', 'INLINE_COMMENT_KEEP_EXACTLY') | Where-Object { ($uninstalledVSCodeText -join "`n").Contains($_) }).Count -eq 6)
    Assert-True -Name 'uninstall removes all CXXForge JSONC markers' -Condition (-not (($uninstalledVSCodeText -join "`n").Contains('// CXXForge:')))
    Assert-True -Name 'uninstall preserves exact user indentation and inline comment' -Condition ((Get-Content -LiteralPath (Join-Path $installRoot '.vscode\settings.json') -Raw).Contains('  "editor.tabSize": 7, // INLINE_COMMENT_KEEP_EXACTLY'))

    $noVSCodeRoot = Join-Path $testRoot 'no vscode workspace'
    Invoke-ProcessCase -Name 'NoVSCode portable installation' -ScriptPath $installer -Arguments @('-Workspace', $noVSCodeRoot, '-NoVSCode') -OutputPattern 'VS Code integration skipped' | Out-Null
    Assert-True -Name 'NoVSCode creates no VS Code directory' -Condition (-not (Test-Path -LiteralPath (Join-Path $noVSCodeRoot '.vscode')))
    Invoke-ProcessCase -Name 'NoVSCode manifest uninstall' -ScriptPath $installer -Arguments @('-Workspace', $noVSCodeRoot, '-Uninstall', '-NoVSCode') -OutputPattern 'uninstall completed' | Out-Null

    $conflictRoot = Join-Path $testRoot 'user code runner workspace'
    $conflictSettings = Join-Path $conflictRoot '.vscode\settings.json'
    Write-Utf8File $conflictSettings @'
{
  // USER_CODE_RUNNER_MAPPING_MUST_WIN
  "code-runner.executorMap": {
    "c": "user-c-command",
    "cpp": "user-cpp-command"
  },
  "example.url": "https://example.invalid/code-runner"
}
'@
    $conflictHashBefore = (Get-FileHash -LiteralPath $conflictSettings -Algorithm SHA256).Hash
    Invoke-ProcessCase -Name 'user Code Runner mappings are not overwritten' -ScriptPath $installer -Arguments @('-Workspace', $conflictRoot) -OutputPattern 'user-owned' | Out-Null
    Assert-True -Name 'Code Runner conflict preserves settings byte-for-byte' -Condition ((Get-FileHash -LiteralPath $conflictSettings -Algorithm SHA256).Hash -eq $conflictHashBefore)
    Invoke-ProcessCase -Name 'uninstall preserves user Code Runner mappings' -ScriptPath $installer -Arguments @('-Workspace', $conflictRoot, '-Uninstall') -OutputPattern 'uninstall completed' | Out-Null
    Assert-True -Name 'Code Runner settings remain byte-identical after uninstall' -Condition ((Get-FileHash -LiteralPath $conflictSettings -Algorithm SHA256).Hash -eq $conflictHashBefore)

    # Public entry, custom target, path safety, and legacy layout migration.
    $customTargetRoot = Join-Path $testRoot 'custom target workspace'
    Invoke-ProcessCase -Name 'custom TargetDir installation' -ScriptPath $installer -Arguments @('-Workspace', $customTargetRoot, '-TargetDir', 'tools\forge runtime', '-NoVSCode') -OutputPattern 'Installation completed' | Out-Null
    $customEntryText = Get-Content -LiteralPath (Join-Path $customTargetRoot 'cxxforge.ps1') -Raw
    Assert-True -Name 'public entry points to custom TargetDir' -Condition ($customEntryText -match [regex]::Escape('tools\forge runtime\forge.ps1'))
    Invoke-ProcessCase -Name 'custom TargetDir public entry works' -ScriptPath (Join-Path $customTargetRoot 'cxxforge.ps1') -Arguments @('--help') -OutputPattern 'Usage: cxxforge.ps1' | Out-Null
    $customManifest = Get-Content -LiteralPath (Join-Path $customTargetRoot '.cxxforge\manifest.json') -Raw | ConvertFrom-Json
    Assert-True -Name 'custom TargetDir recorded in manifest' -Condition ($customManifest.targetDir -eq 'tools\forge runtime')
    Invoke-ProcessCase -Name 'custom TargetDir uninstall' -ScriptPath $installer -Arguments @('-Workspace', $customTargetRoot, '-Uninstall', '-NoVSCode') -OutputPattern 'uninstall completed' | Out-Null

    $escapeRoot = Join-Path $testRoot 'target escape workspace'
    Invoke-ProcessCase -Name 'TargetDir cannot escape workspace' -ScriptPath $installer -Arguments @('-Workspace', $escapeRoot, '-TargetDir', '..\outside', '-WhatIf', '-NoVSCode') -ExpectedExit 2 -OutputPattern 'must resolve to a child directory' | Out-Null

    $matchingPublicRoot = Join-Path $testRoot 'matching public entry workspace'
    $matchingPublicPath = Join-Path $matchingPublicRoot 'cxxforge.ps1'
    Write-Utf8File $matchingPublicPath (Get-Content -LiteralPath (Join-Path $repoRoot 'cxxforge.ps1') -Raw).TrimEnd("`r", "`n")
    $matchingPublicHash = (Get-FileHash -LiteralPath $matchingPublicPath -Algorithm SHA256).Hash
    Invoke-ProcessCase -Name 'matching unmanaged public entry is accepted' -ScriptPath $installer -Arguments @('-Workspace', $matchingPublicRoot, '-WhatIf', '-NoVSCode') -OutputPattern 'Dry-run complete' | Out-Null
    Assert-True -Name 'matching unmanaged public entry remains unchanged' -Condition ((Get-FileHash -LiteralPath $matchingPublicPath -Algorithm SHA256).Hash -eq $matchingPublicHash)

    $publicConflictRoot = Join-Path $testRoot 'public entry conflict workspace'
    $publicConflictPath = Join-Path $publicConflictRoot 'cxxforge.ps1'
    Write-Utf8File $publicConflictPath '# USER_PUBLIC_ENTRY_MUST_SURVIVE'
    $publicConflictHash = (Get-FileHash -LiteralPath $publicConflictPath -Algorithm SHA256).Hash
    Invoke-ProcessCase -Name 'unmanaged public entry blocks installation' -ScriptPath $installer -Arguments @('-Workspace', $publicConflictRoot, '-NoVSCode') -ExpectedExit 2 -OutputPattern 'not managed by CXXForge' | Out-Null
    Assert-True -Name 'unmanaged public entry is preserved' -Condition ((Get-FileHash -LiteralPath $publicConflictPath -Algorithm SHA256).Hash -eq $publicConflictHash)
    Invoke-ProcessCase -Name 'Force replaces conflicting public entry' -ScriptPath $installer -Arguments @('-Workspace', $publicConflictRoot, '-NoVSCode', '-Force') -OutputPattern 'Installation completed' | Out-Null
    Assert-True -Name 'Force backs up conflicting public entry' -Condition (@(Get-ChildItem -LiteralPath (Join-Path $publicConflictRoot '.cxxforge\backups') -File -ErrorAction SilentlyContinue).Count -gt 0)
    Invoke-ProcessCase -Name 'forced public entry install uninstalls cleanly' -ScriptPath $installer -Arguments @('-Workspace', $publicConflictRoot, '-Uninstall', '-NoVSCode') -OutputPattern 'uninstall completed' | Out-Null

    $legacyRoot = Join-Path $testRoot 'legacy files workspace'
    $legacyPayloads = [ordered]@{
        'files/forge.ps1' = '# legacy forge'
        'files/modules/Core.ps1' = '# legacy core'
        'files/modules/Configuration.ps1' = '# legacy configuration'
        'files/modules/Build.ps1' = '# legacy build'
        'files/modules/Watch.ps1' = '# legacy watch'
        'files/run_active.ps1' = '# legacy compatibility entry'
        'files/run_active.bat' = '@echo off'
        'files/compiler_config.json' = '{"activeProfile":"release"}'
    }
    $legacyRecords = @()
    foreach ($legacyEntry in $legacyPayloads.GetEnumerator()) {
        $legacyPath = Join-Path $legacyRoot $legacyEntry.Key.Replace('/', '\')
        Write-Utf8File $legacyPath $legacyEntry.Value
        $legacyRecords += [ordered]@{ path = $legacyEntry.Key; hash = (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash.ToLowerInvariant(); managed = $true; userConfig = ($legacyEntry.Key -eq 'files/compiler_config.json') }
    }
    $legacyManifestPath = Join-Path $legacyRoot '.cxxforge\manifest.json'
    $legacyManifest = [ordered]@{ schemaVersion = 1; installerVersion = '2.0.0-dev.7'; targetDir = 'files'; vscodeEnabled = $false; installedAtUtc = [DateTime]::UtcNow.ToString('o'); files = $legacyRecords }
    Write-Utf8File $legacyManifestPath ($legacyManifest | ConvertTo-Json -Depth 8)
    Add-Content -LiteralPath (Join-Path $legacyRoot 'files\run_active.ps1') -Value '# USER_LEGACY_MODIFICATION'
    Write-Utf8File (Join-Path $legacyRoot 'files\compiler_config.json') '{"activeProfile":"debug"}'

    Invoke-ProcessCase -Name 'schema 1 files layout migrates to cxxforge' -ScriptPath $installer -Arguments @('-Workspace', $legacyRoot, '-Upgrade', '-NoVSCode') -OutputPattern 'Legacy layout detected' | Out-Null
    $migratedManifest = Get-Content -LiteralPath $legacyManifestPath -Raw | ConvertFrom-Json
    $migratedConfig = Get-Content -LiteralPath (Join-Path $legacyRoot 'cxxforge\compiler_config.json') -Raw | ConvertFrom-Json
    Assert-True -Name 'migration writes schema 2 manifest' -Condition ($migratedManifest.schemaVersion -eq 2 -and $migratedManifest.targetDir -eq 'cxxforge' -and $migratedManifest.migratedFrom -eq 'files')
    Assert-True -Name 'migration preserves compiler configuration in new runtime' -Condition ($migratedConfig.activeProfile -eq 'debug')
    Assert-True -Name 'migration removes unmodified legacy runtime' -Condition (-not (Test-Path -LiteralPath (Join-Path $legacyRoot 'files\forge.ps1')))
    Assert-True -Name 'migration preserves modified legacy entry' -Condition (Test-Path -LiteralPath (Join-Path $legacyRoot 'files\run_active.ps1'))
    Assert-True -Name 'migration preserves modified legacy config' -Condition (Test-Path -LiteralPath (Join-Path $legacyRoot 'files\compiler_config.json'))
    Invoke-ProcessCase -Name 'migrated layout uninstall' -ScriptPath $installer -Arguments @('-Workspace', $legacyRoot, '-Uninstall', '-NoVSCode') -OutputPattern 'uninstall completed' | Out-Null
    Assert-True -Name 'uninstall preserves migrated legacy modifications' -Condition (Test-Path -LiteralPath (Join-Path $legacyRoot 'files\run_active.ps1'))
    Write-Host "[SUMMARY] passed=$script:passed failed=$script:failed" -ForegroundColor $(if ($script:failed) { 'Red' } else { 'Green' })
    if ($script:failed -gt 0) { exit 1 }
    exit 0
} finally {
    # Only remove the unique test directory created under D:\tmp.
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    $safePrefix = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'cxxforge comprehensive '))
    if ($resolved.StartsWith($safePrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
