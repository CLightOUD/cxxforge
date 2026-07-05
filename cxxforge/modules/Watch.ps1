# CXXForge Watch process control, command shell, and file event loop.
# === Watch Mode ===
function ConvertTo-WindowsProcessArgument {
    param([string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$builder.Append(('\' * ($backslashes * 2 + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append(('\' * $backslashes)); $backslashes = 0 }
        [void]$builder.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Start-WatchProgram {
    param([string]$ProgramPath, [string[]]$ProgramArgs)
    $argumentLine = (@($ProgramArgs | ForEach-Object { ConvertTo-WindowsProcessArgument ([string]$_) }) -join ' ')
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ProgramPath
    $startInfo.Arguments = $argumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.RedirectStandardInput = -not $script:watchDirectConsole
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Failed to start program: $ProgramPath" }
    if ($startInfo.RedirectStandardInput) {
        $inputWriter = $process.StandardInput
        $inputWriter.AutoFlush = $true
        $process | Add-Member -MemberType NoteProperty -Name CXXForgeInput -Value $inputWriter
        $script:watchProgramInput = $inputWriter
    } else {
        $script:watchProgramInput = $null
    }
    $script:watchInputRoute = 'program'
    Write-Host "[WATCH] Program started (pid=$($process.Id)): $ProgramPath $argumentLine" -ForegroundColor Cyan
    return $process
}

function Stop-WatchProgram {
    param($Process, [string]$Reason)
    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            Write-Host "[WATCH] Stopping program (pid=$($Process.Id)): $Reason" -ForegroundColor DarkYellow
            $Process.Kill()
            if (-not $Process.WaitForExit(3000)) { Write-Host "[WARN] Program did not exit within 3 seconds." -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "[WARN] Failed to stop watched program: $_" -ForegroundColor Yellow
    } finally {
        try { if ($script:watchProgramInput) { $script:watchProgramInput.Dispose() } } catch {}
        $script:watchProgramInput = $null
        $script:watchInputRoute = 'shell'
        $Process.Dispose()
    }
}

function Write-WatchInputPrompt {
    if ($script:watchInputRoute -eq 'program') {
        if ($script:watchDirectConsole) {
            Write-Host "[WATCH] Console input is attached directly to the program until it exits." -ForegroundColor DarkGray
        } else {
            Write-Host -NoNewline "program> " -ForegroundColor DarkCyan
        }
    } else {
        Write-Host -NoNewline "cxxforge> " -ForegroundColor Cyan
    }
}

function Split-WatchCommandLine {
    param([string]$Text)
    $values = @()
    foreach ($match in [regex]::Matches($Text, '"([^"]*)"|''([^'']*)''|(\S+)')) {
        if ($match.Groups[1].Success) { $values += $match.Groups[1].Value }
        elseif ($match.Groups[2].Success) { $values += $match.Groups[2].Value }
        else { $values += $match.Groups[3].Value }
    }
    return $values
}

$watchOriginalArgs = @($script:CXXFORGE_CLI_ARGS)
function Invoke-WatchBuild {
    param([bool]$ForceRebuild)
    $buildArgs = @('--no-run')
    if ($ForceRebuild) { $buildArgs += '--rebuild' }
    foreach ($argument in $watchOriginalArgs) {
        if ($argument -notmatch '^(-w|--watch|--watch-clear|--watch-shell|--no-watch-shell|-r|--run|-n|--no-run|--rebuild|-R)$') {
            $buildArgs += $argument
        }
    }
    $buildOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script:CXXFORGE_ENTRY_PATH @buildArgs 2>&1)
    $buildExitCode = $LASTEXITCODE
    foreach ($line in $buildOutput) { Write-Host $line }
    return [int]$buildExitCode
}

function Show-WatchShellHelp {
    Write-Host "[WATCH] Commands:" -ForegroundColor Cyan
    if ($script:watchDirectConsole) {
        Write-Host "  While a program is running, it owns console input directly."
        Write-Host "  Watch commands become available again after the program exits."
        Write-Host "  File changes are still monitored and will stop/rebuild/restart it."
    } else {
        Write-Host "  While a program is running, ordinary lines go to its stdin."
        Write-Host "  Prefix Watch commands with ':' while running, for example :build or :restart."
    }
    Write-Host "  run [args...]   Start the current executable; supplied args replace saved args"
    Write-Host "  build           Stop and perform an incremental build"
    Write-Host "  rebuild         Stop and force a full rebuild"
    Write-Host "  restart         Stop, build, and run"
    Write-Host "  status          Show build target, process state, and saved arguments"
    Write-Host "  args [args...]  Replace arguments used by future run/restart commands"
    Write-Host "  clear           Clear the terminal"
    Write-Host "  help            Show this command list"
    Write-Host "  quit            Stop the program and leave Watch mode"
}

$script:watchProgramInput = $null
$script:watchInputRoute = 'shell'
$runningProcess = $null
$watchShellEnabled = if ($null -ne $WATCH_SHELL_OVERRIDE) { [bool]$WATCH_SHELL_OVERRIDE } else { -not [Console]::IsInputRedirected }
$watchUseConsoleKeys = $false
if ($watchShellEnabled) {
    try {
        # Some terminal hosts report IsInputRedirected inconsistently. KeyAvailable is
        # the capability we actually need, so probe it directly.
        $null = [Console]::KeyAvailable
        $watchUseConsoleKeys = $true
    } catch {
        $watchUseConsoleKeys = $false
    }
}
$script:watchDirectConsole = $watchShellEnabled -and $watchUseConsoleKeys
if ($DO_RUN) { $runningProcess = Start-WatchProgram -ProgramPath $OUT -ProgramArgs $RUN_ARGS }
$watchInputBuffer = New-Object System.Text.StringBuilder
$watchCommandTask = $null
if ($watchShellEnabled) {
    $watchInputBackend = if ($script:watchDirectConsole) { 'native console handoff' } else { 'ReadLineAsync (redirected)' }
    Write-Host "[WATCH] Input backend: $watchInputBackend" -ForegroundColor DarkGray
    Show-WatchShellHelp
    Write-WatchInputPrompt
    $watchCommandRoute = $script:watchInputRoute
    if (-not $watchUseConsoleKeys) { $watchCommandTask = [Console]::In.ReadLineAsync() }
} else {
    Write-Host "[WATCH] Interactive shell disabled; use --watch-shell to force it." -ForegroundColor DarkGray
}

function Test-WatchRelevantPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $leaf = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
    if ($leaf -in @('cxxforge.json', 'compiler_config.json')) { return $true }
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    return $extension -in @('.c', '.cc', '.cpp', '.cxx', '.c++', '.h', '.hh', '.hpp', '.hxx', '.inl')
}

function Get-WatchEventPaths {
    param($EventRecord)
    $paths = @()
    if ($EventRecord -and $EventRecord.SourceEventArgs) {
        if ($EventRecord.SourceEventArgs.FullPath) { $paths += [string]$EventRecord.SourceEventArgs.FullPath }
        if ($EventRecord.SourceEventArgs.PSObject.Properties.Name -contains 'OldFullPath' -and $EventRecord.SourceEventArgs.OldFullPath) {
            $paths += [string]$EventRecord.SourceEventArgs.OldFullPath
        }
    }
    return $paths
}

$watchRootCandidates = @()
if ($IS_PROJECT_MODE) {
    $watchRootCandidates += $projDir
    $watchRootCandidates += $PROJECT_INCLUDES
} else {
    $watchRootCandidates += $srcDir
}
$watchRootCandidates += (Split-Path $configPath -Parent)

$watchRoots = @()
$watchRootKeys = @{}
foreach ($candidate in $watchRootCandidates) {
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
    $resolvedRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $candidate).Path)
    $key = $resolvedRoot.ToLowerInvariant()
    if (-not $watchRootKeys.ContainsKey($key)) {
        $watchRootKeys[$key] = $true
        $watchRoots += $resolvedRoot
    }
}

Write-Host ""
Write-Host "[WATCH] Monitoring $($watchRoots.Count) root(s):" -ForegroundColor Cyan
foreach ($root in $watchRoots) { Write-Host "  $root" -ForegroundColor DarkGray }
Write-Host "[WATCH] Sources, headers, cxxforge.json, and compiler_config.json are tracked." -ForegroundColor DarkGray
Write-Host "[WATCH] Press Ctrl+C to stop." -ForegroundColor DarkGray

$watchers = @()
$sourceIdentifiers = @()
$watchSession = [guid]::NewGuid().ToString('N')
try {
    $rootIndex = 0
    foreach ($root in $watchRoots) {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $root
        $watcher.Filter = '*.*'
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, CreationTime'
        $watcher.EnableRaisingEvents = $true
        $watchers += $watcher
        foreach ($eventName in @('Changed', 'Created', 'Deleted', 'Renamed')) {
            $sourceId = "CXXForge.Watch.$watchSession.$rootIndex.$eventName"
            Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceId | Out-Null
            $sourceIdentifiers += $sourceId
        }
        $rootIndex++
    }

    while ($true) {
        $watchCommandReady = $false
        $commandLine = $null
        $programOwnsConsole = $script:watchDirectConsole -and $runningProcess -and -not $runningProcess.HasExited
        if ($watchShellEnabled -and $watchUseConsoleKeys -and -not $programOwnsConsole) {
            while ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                if (($keyInfo.Modifiers -band [ConsoleModifiers]::Control) -and $keyInfo.Key -eq [ConsoleKey]::C) {
                    Write-Host '^C'
                    $commandLine = ':quit'
                    $watchCommandReady = $true
                    break
                }
                if ($keyInfo.Key -eq [ConsoleKey]::Enter) {
                    Write-Host ''
                    $commandLine = $watchInputBuffer.ToString()
                    [void]$watchInputBuffer.Clear()
                    $watchCommandReady = $true
                    break
                }
                if ($keyInfo.Key -eq [ConsoleKey]::Backspace) {
                    if ($watchInputBuffer.Length -gt 0) {
                        $watchInputBuffer.Length--
                        Write-Host -NoNewline "`b `b"
                    }
                    continue
                }
                if (-not [char]::IsControl($keyInfo.KeyChar)) {
                    [void]$watchInputBuffer.Append($keyInfo.KeyChar)
                    Write-Host -NoNewline $keyInfo.KeyChar
                }
            }
        } elseif ($watchShellEnabled -and $watchCommandTask -and $watchCommandTask.IsCompleted) {
            $commandLine = $watchCommandTask.Result
            $watchCommandReady = $true
        }

        if ($watchShellEnabled -and $watchCommandReady) {
            if ($null -eq $commandLine) {
                $watchShellEnabled = $false
                $watchCommandTask = $null
                Write-Host "[WATCH] Command input closed; file monitoring continues." -ForegroundColor DarkGray
            } else {
                $programIsRunning = $runningProcess -and -not $runningProcess.HasExited
                $trimmedInput = $commandLine.TrimStart()
                $inputCommandName = if ($trimmedInput) { ($trimmedInput.TrimStart(':') -split '\s+', 2)[0].ToLowerInvariant() } else { '' }
                $knownWatchCommands = @('help', '?', 'clear', 'status', 'args', 'run', 'build', 'rebuild', 'restart', 'quit', 'exit')
                $explicitWatchCommand = $trimmedInput.StartsWith(':')
                $implicitWatchCommand = $inputCommandName -in $knownWatchCommands
                $routeToProgram = $watchCommandRoute -eq 'program' -and -not $explicitWatchCommand -and -not $implicitWatchCommand
                $watchExitRequested = $false
                if ($routeToProgram) {
                    try {
                        if (-not $script:watchProgramInput) { throw 'program input stream is unavailable' }
                        $script:watchProgramInput.WriteLine($commandLine)
                        $script:watchProgramInput.Flush()
                    } catch {
                        Write-Host "[WARN] Failed to forward program input: $_" -ForegroundColor Yellow
                        $script:watchInputRoute = 'shell'
                    }
                } else {
                if ($commandLine.TrimStart().StartsWith(':')) {
                    $commandLine = $commandLine.TrimStart().Substring(1)
                }
                $trimmedCommand = $commandLine.Trim()
                $commandName = if ($trimmedCommand) { ($trimmedCommand -split '\s+', 2)[0].ToLowerInvariant() } else { '' }
                $commandTail = if ($trimmedCommand -match '^\S+\s+(.+)$') { $matches[1] } else { '' }
                switch ($commandName) {
                    '' { }
                    'help' { Show-WatchShellHelp }
                    '?' { Show-WatchShellHelp }
                    'clear' { Clear-Host }
                    'status' {
                        $processState = if (-not $runningProcess) { 'stopped' } elseif ($runningProcess.HasExited) { "exited($($runningProcess.ExitCode))" } else { "running(pid=$($runningProcess.Id))" }
                        Write-Host "[WATCH] Target: $OUT" -ForegroundColor Cyan
                        Write-Host "[WATCH] Program: $processState"
                        Write-Host "[WATCH] Args: $($RUN_ARGS -join ' ')"
                    }
                    'args' {
                        $script:RUN_ARGS = @(Split-WatchCommandLine $commandTail)
                        Write-Host "[WATCH] Saved arguments: $($RUN_ARGS -join ' ')" -ForegroundColor DarkGreen
                    }
                    'run' {
                        if ($commandTail) { $script:RUN_ARGS = @(Split-WatchCommandLine $commandTail) }
                        if ($runningProcess) { Stop-WatchProgram -Process $runningProcess -Reason 'run command'; $runningProcess = $null }
                        if (Test-Path -LiteralPath $OUT) { $runningProcess = Start-WatchProgram -ProgramPath $OUT -ProgramArgs $RUN_ARGS }
                        else { Write-Host "[WARN] Executable does not exist; use build or restart first: $OUT" -ForegroundColor Yellow }
                    }
                    'build' {
                        if ($runningProcess) { Stop-WatchProgram -Process $runningProcess -Reason 'build command'; $runningProcess = $null }
                        $buildExitCode = Invoke-WatchBuild -ForceRebuild $false
                        if ($buildExitCode -eq 0) { Write-Host '[WATCH] Build completed.' -ForegroundColor DarkGreen }
                        else { Write-Host "[WATCH] Build failed with code $buildExitCode." -ForegroundColor Yellow }
                    }
                    'rebuild' {
                        if ($runningProcess) { Stop-WatchProgram -Process $runningProcess -Reason 'rebuild command'; $runningProcess = $null }
                        $buildExitCode = Invoke-WatchBuild -ForceRebuild $true
                        if ($buildExitCode -eq 0) { Write-Host '[WATCH] Full rebuild completed.' -ForegroundColor DarkGreen }
                        else { Write-Host "[WATCH] Full rebuild failed with code $buildExitCode." -ForegroundColor Yellow }
                    }
                    'restart' {
                        if ($runningProcess) { Stop-WatchProgram -Process $runningProcess -Reason 'restart command'; $runningProcess = $null }
                        $buildExitCode = Invoke-WatchBuild -ForceRebuild $false
                        if ($buildExitCode -eq 0) { $runningProcess = Start-WatchProgram -ProgramPath $OUT -ProgramArgs $RUN_ARGS }
                        else { Write-Host "[WATCH] Restart cancelled because build failed with code $buildExitCode." -ForegroundColor Yellow }
                    }
                    'quit' { $watchExitRequested = $true }
                    'exit' { $watchExitRequested = $true }
                    default { Write-Host "[WARN] Unknown Watch command '$commandName'. Type help for commands." -ForegroundColor Yellow }
                }
                }
                if ($watchExitRequested) { break }
                Write-WatchInputPrompt
                $watchCommandRoute = $script:watchInputRoute
                if (-not $watchUseConsoleKeys) { $watchCommandTask = [Console]::In.ReadLineAsync() }
            }
        }

        if ($watchUseConsoleKeys) {
            $firstEvent = Get-Event | Where-Object { $_.SourceIdentifier -in $sourceIdentifiers } | Select-Object -First 1
            if (-not $firstEvent) { Start-Sleep -Milliseconds 50 }
        } else {
            $firstEvent = Wait-Event -Timeout 1
        }
        if (-not $firstEvent) {
            if ($runningProcess -and $runningProcess.HasExited) {
                Write-Host "[WATCH] Program exited with code $($runningProcess.ExitCode); monitoring continues." -ForegroundColor DarkGray
                try { if ($script:watchProgramInput) { $script:watchProgramInput.Dispose() } } catch {}
                $script:watchProgramInput = $null
                $script:watchInputRoute = 'shell'
                $watchCommandRoute = 'shell'
                $runningProcess.Dispose()
                $runningProcess = $null
                if ($watchShellEnabled) { Write-WatchInputPrompt }
            }
            continue
        }
        if ($firstEvent.SourceIdentifier -notin $sourceIdentifiers) { continue }

        $changedPaths = @()
        foreach ($path in @(Get-WatchEventPaths $firstEvent)) {
            if (Test-WatchRelevantPath $path) { $changedPaths += $path }
        }
        Remove-Event -EventIdentifier $firstEvent.EventIdentifier -ErrorAction SilentlyContinue
        if ($changedPaths.Count -eq 0) { continue }

        # Editors commonly emit several events for one save. Allow them to settle,
        # then collapse the batch into exactly one rebuild.
        Start-Sleep -Milliseconds 350
        foreach ($queuedEvent in @(Get-Event | Where-Object { $_.SourceIdentifier -in $sourceIdentifiers })) {
            foreach ($path in @(Get-WatchEventPaths $queuedEvent)) {
                if (Test-WatchRelevantPath $path) { $changedPaths += $path }
            }
            Remove-Event -EventIdentifier $queuedEvent.EventIdentifier -ErrorAction SilentlyContinue
        }
        $changedPaths = @($changedPaths | Sort-Object -Unique)

        if ($WATCH_CLEAR) { Clear-Host }
        Write-Host ""
        Write-Host "[WATCH] Change detected ($($changedPaths.Count) file(s)); rebuilding..." -ForegroundColor Cyan
        foreach ($path in @($changedPaths | Select-Object -First 5)) { Write-Host "  $path" -ForegroundColor DarkGray }

        if ($runningProcess) {
            Stop-WatchProgram -Process $runningProcess -Reason 'source change detected'
            $runningProcess = $null
        }

        $childExitCode = Invoke-WatchBuild -ForceRebuild $false
        if ($childExitCode -ne 0) {
            Write-Host "[WATCH] Build exited with code $childExitCode; monitoring continues without restarting the program." -ForegroundColor Yellow
        } else {
            Write-Host "[WATCH] Rebuild completed." -ForegroundColor DarkGreen
            if ($DO_RUN) { $runningProcess = Start-WatchProgram -ProgramPath $OUT -ProgramArgs $RUN_ARGS }
            Write-Host "[WATCH] Monitoring continues." -ForegroundColor DarkGreen
        }
    }
} finally {
    if ($runningProcess) { Stop-WatchProgram -Process $runningProcess -Reason 'watch session ended'; $runningProcess = $null }
    foreach ($sourceId in $sourceIdentifiers) {
        Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
    }
    foreach ($watcher in $watchers) {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
    }
    foreach ($pendingEvent in @(Get-Event | Where-Object { $_.SourceIdentifier -in $sourceIdentifiers })) {
        Remove-Event -EventIdentifier $pendingEvent.EventIdentifier -ErrorAction SilentlyContinue
    }
}
