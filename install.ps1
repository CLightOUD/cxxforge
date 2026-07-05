<#
Install script for setting up compile-and-run workflow.
- This file contains generated portable payload blocks; update them with tools/sync-installer-payload.ps1.
- Generates forge.ps1, runtime modules, compatibility shims, and compiler_config.json
- Creates or merges VS Code tasks in .vscode/tasks.json to use the PowerShell runner
- Pure PowerShell, offline-capable, and manifest-driven
- Supports -Upgrade, -Repair, -Uninstall, -NoVSCode, -Force, and -WhatIf
#>
param(
    [string]$TargetDir = 'cxxforge',
    [string]$Workspace,
    [switch]$Force,
    [switch]$WhatIf,
    [switch]$Upgrade,
    [switch]$Repair,
    [switch]$Uninstall,
    [switch]$NoVSCode
)

$ErrorActionPreference = 'Stop'
$IS_DRY = [bool]$WhatIf
$targetDirExplicit = $PSBoundParameters.ContainsKey('TargetDir')
$INSTALLER_VERSION = '2.0.0-dev.8'
$script:BACKUP_ROOT = $null

$modeCount = @(@($Upgrade, $Repair, $Uninstall) | Where-Object { [bool]$_ }).Count
if ($modeCount -gt 1) { throw 'Choose only one lifecycle mode: -Upgrade, -Repair, or -Uninstall.' }

function Write-Info {
    param([string]$msg, [ConsoleColor]$color = [ConsoleColor]::DarkCyan)
    Write-Host $msg -ForegroundColor $color
}

function New-DirectoryIfMissing {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($IS_DRY) { Write-Info "[WHATIF] Create directory: $Path" DarkYellow } else { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    }
}

function Save-FileBackup {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        if ($script:BACKUP_ROOT) {
            $safeName = ([System.IO.Path]::GetFullPath($Path) -replace '[:\\/]+', '_').Trim('_')
            $bak = Join-Path $script:BACKUP_ROOT "$safeName.$stamp.bak"
        } else {
            $bak = "$Path.$stamp.bak"
        }
        if ($IS_DRY) {
            Write-Info "[WHATIF] Backup $Path -> $bak" DarkYellow
        } else {
            New-DirectoryIfMissing (Split-Path -Parent $bak)
            Copy-Item -LiteralPath $Path -Destination $bak -Force
        }
    }
}

function Set-FileContent {
    param(
        [string]$Path,
        [string]$Content,
        [switch]$Overwrite
    )
    $exists = Test-Path -LiteralPath $Path
    if ($exists -and -not $Overwrite) {
        Write-Info "[INFO] Skip (exists): $Path" 'DarkGray'
        return
    }
    if ($exists -and $Overwrite) { Save-FileBackup -Path $Path }
    $action = if ($exists) { 'Overwrite file' } else { 'Create file' }
    if ($IS_DRY) {
        Write-Info ("[WHATIF] {0}: {1}" -f $action, $Path) DarkYellow
    } else {
        $dir = Split-Path -Parent $Path
        New-DirectoryIfMissing $dir
        Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
        Write-Info "[INFO] Wrote: $Path" 'DarkGreen'
    }
}

function Read-TextFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        return $strictUtf8.GetString($bytes)
    } catch [System.Text.DecoderFallbackException] {
        return [System.Text.Encoding]::Default.GetString($bytes)
    }
}

function Remove-JsoncComments {
    param([string]$Text)
    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($lineComment) {
            if ($ch -eq "`n") { $lineComment = $false; [void]$builder.Append($ch) }
            continue
        }
        if ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') { $blockComment = $false; $i++; continue }
            if ($ch -eq "`r" -or $ch -eq "`n") { [void]$builder.Append($ch) }
            continue
        }
        if ($inString) {
            [void]$builder.Append($ch)
            if ($escaped) { $escaped = $false; continue }
            if ($ch -eq '\') { $escaped = $true; continue }
            if ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$builder.Append($ch); continue }
        if ($ch -eq '/' -and $next -eq '/') { $lineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }
        [void]$builder.Append($ch)
    }
    return $builder.ToString()
}

function Read-JsonWithComments {
    param([string]$Path)
    return (Remove-JsoncComments (Read-TextFile -Path $Path)) | ConvertFrom-Json
}

function ConvertFrom-JsoncText {
    param([string]$Text)
    return (Remove-JsoncComments $Text) | ConvertFrom-Json
}

function Find-JsoncMatchingBracket {
    param([string]$Text, [int]$OpenIndex, [char]$OpenChar, [char]$CloseChar)
    $depth = 0
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($lineComment) {
            if ($ch -eq "`n") { $lineComment = $false }
            continue
        }
        if ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') { $blockComment = $false; $i++ }
            continue
        }
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ($ch -eq '\') { $escaped = $true; continue }
            if ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '/' -and $next -eq '/') { $lineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }
        if ($ch -eq '"') { $inString = $true; continue }
        if ($ch -eq $OpenChar) { $depth++ }
        elseif ($ch -eq $CloseChar) {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return -1
}

function Get-JsoncNextTokenIndex {
    param([string]$Text, [int]$StartIndex)
    $i = $StartIndex
    while ($i -lt $Text.Length) {
        while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
        if ($i + 1 -ge $Text.Length -or $Text[$i] -ne '/') { return $i }
        if ($Text[$i + 1] -eq '/') {
            $i += 2
            while ($i -lt $Text.Length -and $Text[$i] -ne "`r" -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($Text[$i + 1] -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2, [System.StringComparison]::Ordinal)
            if ($end -lt 0) { return $Text.Length }
            $i = $end + 2
            continue
        }
        return $i
    }
    return $i
}

function Get-JsoncPropertyContainerSpan {
    param([string]$Text, [string]$PropertyName, [char]$OpenChar, [char]$CloseChar)
    $objectDepth = 0
    $arrayDepth = 0
    $lineComment = $false
    $blockComment = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($lineComment) {
            if ($ch -eq "`n") { $lineComment = $false }
            continue
        }
        if ($blockComment) {
            if ($ch -eq '*' -and $next -eq '/') { $blockComment = $false; $i++ }
            continue
        }
        if ($ch -eq '/' -and $next -eq '/') { $lineComment = $true; $i++; continue }
        if ($ch -eq '/' -and $next -eq '*') { $blockComment = $true; $i++; continue }

        if ($ch -eq '"') {
            $stringStart = $i
            $escaped = $false
            $stringEnd = -1
            for ($j = $i + 1; $j -lt $Text.Length; $j++) {
                $stringChar = $Text[$j]
                if ($escaped) { $escaped = $false; continue }
                if ($stringChar -eq '\') { $escaped = $true; continue }
                if ($stringChar -eq '"') { $stringEnd = $j; break }
            }
            if ($stringEnd -lt 0) { return $null }

            if ($objectDepth -eq 1 -and $arrayDepth -eq 0) {
                $name = $Text.Substring($stringStart + 1, $stringEnd - $stringStart - 1)
                if ($name -ceq $PropertyName) {
                    $colonIndex = Get-JsoncNextTokenIndex -Text $Text -StartIndex ($stringEnd + 1)
                    if ($colonIndex -ge $Text.Length -or $Text[$colonIndex] -ne ':') { return $null }
                    $openIndex = Get-JsoncNextTokenIndex -Text $Text -StartIndex ($colonIndex + 1)
                    if ($openIndex -ge $Text.Length -or $Text[$openIndex] -ne $OpenChar) { return $null }
                    $closeIndex = Find-JsoncMatchingBracket -Text $Text -OpenIndex $openIndex -OpenChar $OpenChar -CloseChar $CloseChar
                    if ($closeIndex -lt 0) { return $null }
                    return [pscustomobject]@{ Open = $openIndex; Close = $closeIndex }
                }
            }
            $i = $stringEnd
            continue
        }

        if ($ch -eq '{') { $objectDepth++; continue }
        if ($ch -eq '}') { $objectDepth--; continue }
        if ($ch -eq '[') { $arrayDepth++; continue }
        if ($ch -eq ']') { $arrayDepth--; continue }
    }
    return $null
}

function Remove-JsoncManagedBlockText {
    param([string]$Text, [string]$Marker)
    $escapedMarker = [regex]::Escape($Marker)
    $pattern = '(?ms)\s*,?\s*// CXXForge:' + $escapedMarker + ':BEGIN\s*.*?\s*// CXXForge:' + $escapedMarker + ':END\s*'
    return [regex]::Replace($Text, $pattern, '')
}

function Format-JsoncManagedPayload {
    param([array]$Values, [string]$Indent)
    $formatted = @()
    foreach ($value in $Values) {
        $json = $value | ConvertTo-Json -Depth 12
        $lines = $json -split '\r?\n'
        $formatted += (($lines | ForEach-Object { $Indent + $_ }) -join "`r`n")
    }
    return $formatted -join ",`r`n"
}

function Set-JsoncArrayManagedBlock {
    param(
        [string]$Path,
        [string]$PropertyName,
        [string]$Marker,
        [array]$Values,
        [string]$DefaultText
    )
    $text = if (Test-Path -LiteralPath $Path) { Read-TextFile -Path $Path } else { $DefaultText }
    $text = Remove-JsoncManagedBlockText -Text $text -Marker $Marker
    $span = Get-JsoncPropertyContainerSpan -Text $text -PropertyName $PropertyName -OpenChar '[' -CloseChar ']'
    if (-not $span) { throw "JSONC property '$PropertyName' is missing or is not an array: $Path" }
    $parsed = ConvertFrom-JsoncText $text
    $existingValues = @($parsed.$PropertyName)
    $lineStart = $text.LastIndexOf("`n", $span.Close)
    $closingIndent = if ($lineStart -ge 0) { $text.Substring($lineStart + 1, $span.Close - $lineStart - 1) } else { '' }
    if ($closingIndent -notmatch '^\s*$') { $closingIndent = '' }
    $itemIndent = $closingIndent + '    '
    $payload = Format-JsoncManagedPayload -Values $Values -Indent $itemIndent
    $separator = if ($existingValues.Count -gt 0) { ',' } else { '' }
    $block = "$separator`r`n$itemIndent// CXXForge:${Marker}:BEGIN`r`n$payload`r`n$itemIndent// CXXForge:${Marker}:END`r`n$closingIndent"
    $updated = $text.Insert($span.Close, $block)
    if ($IS_DRY) { Write-Info "[WHATIF] Update JSONC managed block: $Path" DarkYellow; return }
    if (Test-Path -LiteralPath $Path) { Save-FileBackup $Path }
    New-DirectoryIfMissing (Split-Path -Parent $Path)
    Set-Content -LiteralPath $Path -Value $updated.TrimEnd("`r", "`n") -Encoding UTF8
    Write-Info "[INFO] Updated JSONC managed block: $Path" DarkGreen
}

function Set-JsoncRootManagedBlock {
    param([string]$Path, [string]$Marker, [array]$PropertyFragments, [string]$DefaultText = "{`r`n}")
    $text = if (Test-Path -LiteralPath $Path) { Read-TextFile -Path $Path } else { $DefaultText }
    $text = Remove-JsoncManagedBlockText -Text $text -Marker $Marker
    $rootStart = $text.IndexOf('{')
    $rootEnd = if ($rootStart -ge 0) { Find-JsoncMatchingBracket -Text $text -OpenIndex $rootStart -OpenChar '{' -CloseChar '}' } else { -1 }
    if ($rootEnd -lt 0) { throw "Invalid JSONC root object: $Path" }
    $parsed = ConvertFrom-JsoncText $text
    $propertyCount = @($parsed.PSObject.Properties).Count
    $payload = ($PropertyFragments | ForEach-Object { '    ' + $_ }) -join ",`r`n"
    $separator = if ($propertyCount -gt 0) { ',' } else { '' }
    $block = "$separator`r`n    // CXXForge:${Marker}:BEGIN`r`n$payload`r`n    // CXXForge:${Marker}:END`r`n"
    $updated = $text.Insert($rootEnd, $block)
    if ($IS_DRY) { Write-Info "[WHATIF] Update JSONC managed block: $Path" DarkYellow; return }
    if (Test-Path -LiteralPath $Path) { Save-FileBackup $Path }
    New-DirectoryIfMissing (Split-Path -Parent $Path)
    Set-Content -LiteralPath $Path -Value $updated.TrimEnd("`r", "`n") -Encoding UTF8
    Write-Info "[INFO] Updated JSONC managed block: $Path" DarkGreen
}

function Remove-JsoncManagedBlockFile {
    param([string]$Path, [string]$Marker)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = Read-TextFile -Path $Path
    $updated = Remove-JsoncManagedBlockText -Text $text -Marker $Marker
    if ($updated -eq $text) { return $false }
    if ($IS_DRY) { Write-Info "[WHATIF] Remove JSONC managed block: $Path" DarkYellow }
    else { Set-Content -LiteralPath $Path -Value $updated.TrimEnd("`r", "`n") -Encoding UTF8 }
    return $true
}

function Set-TasksJson {
    param(
        [string]$TasksPath,
        [array]$TasksToEnsure
    )
    $defaultText = "{`r`n    `"version`": `"2.0.0`",`r`n    `"tasks`": []`r`n}"
    Set-JsoncArrayManagedBlock -Path $TasksPath -PropertyName 'tasks' -Marker 'TASKS' -Values $TasksToEnsure -DefaultText $defaultText
    return
    $obj = $null
    $exists = Test-Path -LiteralPath $TasksPath
    if ($exists) {
        try { $obj = Read-JsonWithComments -Path $TasksPath } catch {
            Write-Info "[WARN] Existing tasks.json not parseable, backing up and recreating..." Yellow
            Save-FileBackup -Path $TasksPath
            $obj = $null
        }
    }
    if (-not $obj) { $obj = [ordered]@{ version = '2.0.0'; tasks = @() } }
    # Normalize tasks to a mutable ArrayList for safe add/replace
    $existingTasks = @()
    if ($obj.PSObject.Properties['tasks']) { $existingTasks = @($obj.tasks) }
    $obj.tasks = New-Object System.Collections.ArrayList
    if ($existingTasks.Count -gt 0) { [void]$obj.tasks.AddRange($existingTasks) }

    foreach ($t in $TasksToEnsure) {
        $label = $t.label
        $index = -1
        for ($i = 0; $i -lt $obj.tasks.Count; $i++) { if ($obj.tasks[$i].label -eq $label) { $index = $i; break } }
        if ($index -ge 0) {
            $found = $obj.tasks[$index]
            $found.type = $t.type
            $found.command = $t.command
            $found.args = $t.args
            $found.options = $t.options
            if ($t.group) { $found.group = $t.group } elseif ($found.PSObject.Properties['group']) { $found.PSObject.Properties.Remove('group') }
            if ($t.problemMatcher) {
                if ($found.PSObject.Properties['problemMatcher']) {
                    $found.problemMatcher = $t.problemMatcher
                } else {
                    $found | Add-Member -MemberType NoteProperty -Name problemMatcher -Value $t.problemMatcher
                }
            } elseif ($found.PSObject.Properties['problemMatcher']) {
                $found.PSObject.Properties.Remove('problemMatcher')
            }
            Write-Info "Task updated: $label" DarkGray
        } else {
            [void]$obj.tasks.Add([pscustomobject]$t)
            Write-Info "[INFO] Task added: $label" DarkGreen
        }
    }

    $json = $obj | ConvertTo-Json -Depth 10
    if ($IS_DRY) {
        Write-Info "[WHATIF] Write tasks.json: $TasksPath" DarkYellow
    } else {
        New-DirectoryIfMissing (Split-Path -Parent $TasksPath)
        Set-Content -LiteralPath $TasksPath -Value $json -Encoding UTF8
        Write-Info "[INFO] Wrote: $TasksPath" DarkGreen
    }
}

# Detect Code Runner settings and update to use our runner
function Test-CodeRunnerSettingsPresent {
    param([string]$SettingsPath)
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return $false }
    try {
        $raw = Read-TextFile -Path $SettingsPath
        if ($raw -match '"code-runner\.' -or $raw -match "'code-runner\.") { return $true }
    } catch { }
    return $false
}

function Set-CodeRunnerSettings {
    param(
        [string]$SettingsPath,
        [string]$TargetDir
    )
    $existingText = if (Test-Path -LiteralPath $SettingsPath) { Read-TextFile -Path $SettingsPath } else { '{}' }
    $hasManagedMarker = $existingText -match '// CXXForge:SETTINGS:BEGIN'
    $obj = $null
    $exists = Test-Path -LiteralPath $SettingsPath
    if ($exists) {
        try { $obj = Read-JsonWithComments -Path $SettingsPath } catch { $obj = $null }
    }
    if (-not $obj) { $obj = [ordered]@{} }
    $hadExecutorMap = $obj.PSObject.Properties.Name -contains 'code-runner.executorMap'

    # Ensure executorMap object
    $execPropName = 'code-runner.executorMap'
    $execMap = $null
    if ($obj.PSObject.Properties.Name -contains $execPropName) {
        $execMap = $obj.$execPropName
    } else {
        $execMap = [ordered]@{}
        $obj | Add-Member -MemberType NoteProperty -Name $execPropName -Value $execMap
    }

    # Build command for Code Runner:
    # - Force UTF-8 code page via chcp 65001
    # - Set PowerShell input/output encoding to UTF-8 to avoid garbled characters
    # - Then invoke our runner with the expanded $fullFileName
    # Simpler stable mapping: rely on Code Runner's variable expansion ($workspaceRoot / $fullFileName)
    # We mirror the workspace's own settings style and pass --pretty --normalized-diag
    # so Code Runner output matches the Tasks-based runs.
    $scriptRel = "cxxforge.ps1"
    # Use a single scriptblock matching the generated .vscode/settings.json structure
    # and add --pretty --normalized-diag for formatted diagnostics.
    $runner = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "& { chcp.com 65001 2>&1 | Out-Null; [Console]::InputEncoding=[System.Text.Encoding]::UTF8; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & ''$workspaceRoot/' + $scriptRel + ''' --pretty --normalized-diag ''$fullFileName'' }"'
    if ($hasManagedMarker -or -not $hadExecutorMap) {
        $mapJson = ([ordered]@{ c = $runner; cpp = $runner } | ConvertTo-Json -Compress)
        Set-JsoncRootManagedBlock -Path $SettingsPath -Marker 'SETTINGS' -PropertyFragments @(
            ('"code-runner.executorMap": ' + $mapJson),
            '"code-runner.runInTerminal": true'
        )
        return
    }

    $existingMap = $obj.'code-runner.executorMap'
    $existingC = if ($existingMap.PSObject.Properties.Name -contains 'c') { [string]$existingMap.c } else { '' }
    $existingCpp = if ($existingMap.PSObject.Properties.Name -contains 'cpp') { [string]$existingMap.cpp } else { '' }
    if ($existingC -notmatch '(?:run_active|forge)\.ps1' -or $existingCpp -notmatch '(?:run_active|forge)\.ps1') {
        Write-Info '[WARN] Existing Code Runner C/C++ mappings are user-owned; CXXForge left them unchanged.' Yellow
        return
    }
    $execMap.c = $runner
    $execMap.cpp = $runner

    # Make it run in terminal to see interactive I/O
    $runInTermName = 'code-runner.runInTerminal'
    if ($obj.PSObject.Properties.Name -contains $runInTermName) {
        $obj.$runInTermName = $true
    } else {
        $obj | Add-Member -MemberType NoteProperty -Name $runInTermName -Value $true
    }

    $json = $obj | ConvertTo-Json -Depth 10
    if ($IS_DRY) {
        Write-Info "[WHATIF] Write settings.json with Code Runner mapping: $SettingsPath" DarkYellow
    } else {
        Save-FileBackup -Path $SettingsPath
        New-DirectoryIfMissing (Split-Path -Parent $SettingsPath)
        Set-Content -LiteralPath $SettingsPath -Value $json -Encoding UTF8
        Write-Info "[INFO] Updated Code Runner settings: $SettingsPath" DarkGreen
    }
}

function Set-CppProperties {
    param([string]$CppPropsPath, [string]$CompilerPath, [array]$IncludePaths)
    $mode = if ($CompilerPath -match 'clang') { 'windows-clang-x64' } else { 'windows-gcc-x64' }
    $managedConfig = [ordered]@{ name = "CXXForge"; includePath = @('${workspaceFolder}/**') + $IncludePaths; defines = @(); compilerPath = $CompilerPath; cStandard = "c99"; cppStandard = "c++14"; intelliSenseMode = $mode }
    $defaultText = "{`r`n    `"configurations`": [],`r`n    `"version`": 4`r`n}"
    Set-JsoncArrayManagedBlock -Path $CppPropsPath -PropertyName 'configurations' -Marker 'CPP' -Values @($managedConfig) -DefaultText $defaultText
    return
    $existing = $null
    if (Test-Path -LiteralPath $CppPropsPath) { try { $existing = Read-JsonWithComments $CppPropsPath } catch {} }
    $configs = @()
    if ($existing -and $existing.configurations) { $configs += @($existing.configurations | Where-Object { $_.name -ne 'CXXForge' }) }
    $configs += [pscustomobject]$managedConfig
    $props = [ordered]@{ configurations = $configs; version = 4 }
    $json = $props | ConvertTo-Json -Depth 10
    if ($IS_DRY) { Write-Info "[WHATIF] Write c_cpp_properties.json: $CppPropsPath" DarkYellow } else { Save-FileBackup -Path $CppPropsPath; New-DirectoryIfMissing (Split-Path -Parent $CppPropsPath); Set-Content -LiteralPath $CppPropsPath -Value $json -Encoding UTF8; Write-Info "[INFO] Wrote: $CppPropsPath" DarkGreen }
}

function Get-FileHashValue {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ManifestRecord {
    param($Manifest, [string]$RelativePath)
    if (-not $Manifest -or -not $Manifest.files) { return $null }
    return @($Manifest.files | Where-Object { $_.path -eq $RelativePath } | Select-Object -First 1)[0]
}

function Test-FileContentEquivalent {
    param([string]$Path, [string]$Content)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $existing = (Read-TextFile -Path $Path).TrimEnd("`r", "`n")
    return $existing -ceq $Content.TrimEnd("`r", "`n")
}

function Install-ManagedContent {
    param(
        [string]$Path,
        [string]$RelativePath,
        [string]$Content,
        $PreviousRecord,
        [switch]$PreserveOnUpgrade
    )

    $exists = Test-Path -LiteralPath $Path
    $currentHash = Get-FileHashValue $Path
    $previousHash = if ($PreviousRecord) { [string]$PreviousRecord.hash } else { $null }
    $managed = $false
    $installedHash = $previousHash

    if (-not $exists) {
        Set-FileContent -Path $Path -Content $Content -Overwrite
        if (-not $IS_DRY) { $installedHash = Get-FileHashValue $Path }
        $managed = $true
    } elseif ($PreserveOnUpgrade -and ($Upgrade -or $Repair) -and -not $Force) {
        Write-Info "[INFO] Preserve user configuration: $Path" DarkGray
        $managed = [bool]$PreviousRecord.managed
    } elseif ($Force -or $Repair) {
        Set-FileContent -Path $Path -Content $Content -Overwrite
        if (-not $IS_DRY) { $installedHash = Get-FileHashValue $Path }
        $managed = $true
    } elseif ($Upgrade) {
        if ($PreviousRecord -and [bool]$PreviousRecord.managed -and $previousHash -and $currentHash -eq $previousHash) {
            Set-FileContent -Path $Path -Content $Content -Overwrite
            if (-not $IS_DRY) { $installedHash = Get-FileHashValue $Path }
            $managed = $true
        } elseif (Test-FileContentEquivalent -Path $Path -Content $Content) {
            Write-Info "[INFO] Preserve matching user-owned file: $Path" DarkGray
            $installedHash = $currentHash
            $managed = if ($PreviousRecord) { [bool]$PreviousRecord.managed } else { $false }
        } else {
            $candidatePath = "$Path.cxxforge-new"
            Set-FileContent -Path $candidatePath -Content $Content -Overwrite
            Write-Info "[WARN] Modified file preserved; new candidate written: $candidatePath" Yellow
            $managed = if ($PreviousRecord) { [bool]$PreviousRecord.managed } else { $false }
        }
    } else {
        Write-Info "[INFO] Skip (exists): $Path" DarkGray
        $installedHash = $currentHash
        $managed = if ($PreviousRecord) { [bool]$PreviousRecord.managed } else { $false }
    }

    return [ordered]@{
        path = $RelativePath
        hash = $installedHash
        managed = $managed
        userConfig = [bool]$PreserveOnUpgrade
    }
}

function Write-InstallManifest {
    param([string]$Path, [array]$Files, [string]$TargetDirectory, [bool]$VSCodeEnabled, [string]$MigratedFrom)
    $manifest = [ordered]@{
        schemaVersion = 2
        installerVersion = $INSTALLER_VERSION
        targetDir = $TargetDirectory
        publicEntry = 'cxxforge.ps1'
        migratedFrom = $MigratedFrom
        vscodeEnabled = $VSCodeEnabled
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        files = $Files
    }
    $json = $manifest | ConvertTo-Json -Depth 8
    if ($IS_DRY) {
        Write-Info "[WHATIF] Write manifest: $Path" DarkYellow
    } else {
        New-DirectoryIfMissing (Split-Path -Parent $Path)
        Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
        Write-Info "[INFO] Wrote manifest: $Path" DarkGreen
    }
}

function Set-LaunchJson {
    param([string]$LaunchPath, [string]$TaskLabel, [string]$GdbPath)
    if (-not $GdbPath) { $gdb = Get-Command gdb -ErrorAction SilentlyContinue; if ($gdb) { $GdbPath = $gdb.Path } else { $GdbPath = 'gdb.exe' } }
    $managedConfig = [ordered]@{ name = "CXXForge: Debug Active File"; type = "cppdbg"; request = "launch"; program = '${fileDirname}/${fileBasenameNoExtension}.exe'; args = @(); stopAtEntry = $false; cwd = '${fileDirname}'; environment = @(); externalConsole = $true; MIMode = "gdb"; miDebuggerPath = $GdbPath; preLaunchTask = $TaskLabel }
    $defaultText = "{`r`n    `"version`": `"0.2.0`",`r`n    `"configurations`": []`r`n}"
    Set-JsoncArrayManagedBlock -Path $LaunchPath -PropertyName 'configurations' -Marker 'LAUNCH' -Values @($managedConfig) -DefaultText $defaultText
    return
    $existing = $null
    if (Test-Path -LiteralPath $LaunchPath) { try { $existing = Read-JsonWithComments $LaunchPath } catch {} }
    $configs = @()
    if ($existing -and $existing.configurations) {
        $configs += @($existing.configurations | Where-Object { $_.name -ne 'CXXForge: Debug Active File' -and -not ($_.name -eq 'C/C++: Debug Active File' -and $_.preLaunchTask -eq 'Debug Active (PS)') })
    }
    $configs += [pscustomobject]$managedConfig
    $launch = [ordered]@{ version = "0.2.0"; configurations = $configs }
    $json = $launch | ConvertTo-Json -Depth 10
    if ($IS_DRY) { Write-Info "[WHATIF] Write launch.json: $LaunchPath" DarkYellow } else { Save-FileBackup -Path $LaunchPath; New-DirectoryIfMissing (Split-Path -Parent $LaunchPath); Set-Content -LiteralPath $LaunchPath -Value $json -Encoding UTF8; Write-Info "[INFO] Wrote: $LaunchPath" DarkGreen }
}

function Remove-CxxForgeVSCodeEntries {
    param([string]$VSCodeDirectory, [string]$InstalledTargetDir)
    $managedLabels = @('Run Active (PS)', 'Compile Active (PS)', 'Debug Active (PS)', 'Watch Active (PS)')

    $taskFile = Join-Path $VSCodeDirectory 'tasks.json'
    if (Test-Path -LiteralPath $taskFile) {
        if (Remove-JsoncManagedBlockFile -Path $taskFile -Marker 'TASKS') {
            Write-Info "[INFO] Removed CXXForge JSONC task block: $taskFile" DarkGreen
        } else { try {
            $obj = Read-JsonWithComments $taskFile
            $obj.tasks = @($obj.tasks | Where-Object { $_.label -notin $managedLabels })
            if ($IS_DRY) { Write-Info "[WHATIF] Remove CXXForge tasks from: $taskFile" DarkYellow }
            else { Set-Content -LiteralPath $taskFile -Value ($obj | ConvertTo-Json -Depth 10) -Encoding UTF8 }
        } catch { Write-Info "[WARN] Could not update tasks.json during uninstall: $_" Yellow } }
    }

    $launchFile = Join-Path $VSCodeDirectory 'launch.json'
    if (Test-Path -LiteralPath $launchFile) {
        if (Remove-JsoncManagedBlockFile -Path $launchFile -Marker 'LAUNCH') {
            Write-Info "[INFO] Removed CXXForge JSONC launch block: $launchFile" DarkGreen
        } else { try {
            $obj = Read-JsonWithComments $launchFile
            $obj.configurations = @($obj.configurations | Where-Object { $_.name -ne 'CXXForge: Debug Active File' -and -not ($_.name -eq 'C/C++: Debug Active File' -and $_.preLaunchTask -eq 'Debug Active (PS)') })
            if ($IS_DRY) { Write-Info "[WHATIF] Remove CXXForge launch entry from: $launchFile" DarkYellow }
            else { Set-Content -LiteralPath $launchFile -Value ($obj | ConvertTo-Json -Depth 10) -Encoding UTF8 }
        } catch { Write-Info "[WARN] Could not update launch.json during uninstall: $_" Yellow } }
    }

    $cppFile = Join-Path $VSCodeDirectory 'c_cpp_properties.json'
    if (Test-Path -LiteralPath $cppFile) {
        if (Remove-JsoncManagedBlockFile -Path $cppFile -Marker 'CPP') {
            Write-Info "[INFO] Removed CXXForge JSONC IntelliSense block: $cppFile" DarkGreen
        } else { try {
            $obj = Read-JsonWithComments $cppFile
            $obj.configurations = @($obj.configurations | Where-Object { $_.name -ne 'CXXForge' })
            if ($IS_DRY) { Write-Info "[WHATIF] Remove CXXForge IntelliSense entry from: $cppFile" DarkYellow }
            else { Set-Content -LiteralPath $cppFile -Value ($obj | ConvertTo-Json -Depth 10) -Encoding UTF8 }
        } catch { Write-Info "[WARN] Could not update c_cpp_properties.json during uninstall: $_" Yellow } }
    }

    $settingsFile = Join-Path $VSCodeDirectory 'settings.json'
    if (Test-Path -LiteralPath $settingsFile) {
        if (Remove-JsoncManagedBlockFile -Path $settingsFile -Marker 'SETTINGS') {
            Write-Info "[INFO] Removed CXXForge JSONC settings block: $settingsFile" DarkGreen
        } else { try {
            $obj = Read-JsonWithComments $settingsFile
            $prop = 'code-runner.executorMap'
            $settingsChanged = $false
            if ($obj.PSObject.Properties.Name -contains $prop) {
                $map = $obj.$prop
                foreach ($language in @('c', 'cpp')) {
                    if ($map.PSObject.Properties.Name -contains $language) {
                        $value = [string]$map.$language
                        $legacyRunner = [regex]::Escape("$InstalledTargetDir/run_active.ps1")
                        $modularRunner = [regex]::Escape("$InstalledTargetDir/forge.ps1")
                        if ($value -match $legacyRunner -or $value -match $modularRunner -or $value -match [regex]::Escape('cxxforge.ps1')) { $map.PSObject.Properties.Remove($language); $settingsChanged = $true }
                    }
                }
            }
            if ($settingsChanged) {
                if ($IS_DRY) { Write-Info "[WHATIF] Remove legacy CXXForge Code Runner mappings from: $settingsFile" DarkYellow }
                else { Set-Content -LiteralPath $settingsFile -Value ($obj | ConvertTo-Json -Depth 10) -Encoding UTF8 }
            }
        } catch { Write-Info "[WARN] Could not update settings.json during uninstall: $_" Yellow } }
    }
}

# Resolve paths
$repoRoot = if ($Workspace) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Workspace) } else { $PSScriptRoot }
$repoRoot = [System.IO.Path]::GetFullPath($repoRoot)
$workspacePrefix = $repoRoot.TrimEnd('\') + '\'
$targetPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $TargetDir))
if ($targetPath -eq $repoRoot -or -not $targetPath.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Info "[ERROR] TargetDir must resolve to a child directory of Workspace: $TargetDir" Red
    exit 2
}
$publicEntryPath = Join-Path $repoRoot 'cxxforge.ps1'
$vscodeDir = Join-Path $repoRoot '.vscode'
$tasksPath = Join-Path $vscodeDir 'tasks.json'
$settingsPath = Join-Path $vscodeDir 'settings.json'
$manifestDir = Join-Path $repoRoot '.cxxforge'
$manifestPath = Join-Path $manifestDir 'manifest.json'
$script:BACKUP_ROOT = Join-Path $manifestDir 'backups'
$previousManifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    try { $previousManifest = Read-TextFile -Path $manifestPath | ConvertFrom-Json }
    catch { Write-Info "[WARN] Existing manifest is invalid: $manifestPath" Yellow }
}

$legacyMigration = $false
if ($previousManifest -and -not $targetDirExplicit -and $TargetDir -eq 'cxxforge' -and [string]$previousManifest.targetDir -eq 'files') {
    $legacyMigration = $true
    Write-Info '[INFO] Legacy layout detected; preparing safe migration: files -> cxxforge.' Cyan
}

if (($Upgrade -or $Repair) -and -not $previousManifest) {
    Write-Info '[WARN] No valid manifest found; lifecycle operation will behave like a safe first install.' Yellow
}

if ($Uninstall) {
    if (-not $previousManifest) {
        Write-Info "[ERROR] Cannot uninstall safely without a valid manifest: $manifestPath" Red
        exit 2
    }
    $workspacePrefix = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\') + '\'
    foreach ($record in @($previousManifest.files)) {
        if (-not $record.managed) { continue }
        $relativeNative = ([string]$record.path).Replace('/', '\')
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $relativeNative))
        if (-not $fullPath.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Info "[WARN] Refusing unsafe manifest path: $($record.path)" Yellow
            continue
        }
        if (-not (Test-Path -LiteralPath $fullPath)) { continue }
        $currentHash = Get-FileHashValue $fullPath
        if ($record.hash -and $currentHash -eq [string]$record.hash) {
            if ($IS_DRY) { Write-Info "[WHATIF] Remove managed file: $fullPath" DarkYellow }
            else { Remove-Item -LiteralPath $fullPath -Force; Write-Info "[INFO] Removed: $fullPath" DarkGreen }
        } else {
            Write-Info "[WARN] Modified managed file preserved: $fullPath" Yellow
        }
    }
    if ($previousManifest.vscodeEnabled -and -not $NoVSCode) {
        Remove-CxxForgeVSCodeEntries -VSCodeDirectory $vscodeDir -InstalledTargetDir ([string]$previousManifest.targetDir)
    }
    if ($IS_DRY) { Write-Info "[WHATIF] Remove manifest: $manifestPath" DarkYellow }
    elseif (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    Write-Info '[INFO] CXXForge uninstall completed; modified user files were preserved.' Green
    exit 0
}

$publicRelative = 'cxxforge.ps1'
$publicRecord = Get-ManifestRecord $previousManifest $publicRelative

# Prepare generated runtime payloads. Canonical sources live under cxxforge/ and
# are synchronized by tools/sync-installer-payload.ps1.
$publicEntryContent = @'
<# Stable public entry point for the workspace-local CXXForge runtime. #>
param()

$entry = Join-Path $PSScriptRoot 'cxxforge\forge.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    Write-Host "[ERROR] CXXForge runtime entry not found: $entry" -ForegroundColor Red
    exit 2
}

& $entry @args
exit $LASTEXITCODE
'@
$forgeContent = @'
<#
CXXForge modular entry point.

The ordered modules execute in one script scope so the current behavior remains
compatible while implementation responsibilities are separated by phase.
#>
param()

$script:CXXFORGE_ROOT = $PSScriptRoot
$script:CXXFORGE_ENTRY_PATH = $PSCommandPath
$script:CXXFORGE_CLI_ARGS = @($args)

function Exit-CxxForge {
    param([int]$Code)
    $exception = New-Object System.OperationCanceledException("CXXForge requested exit code $Code")
    $exception.Data['CXXForgeExitCode'] = $Code
    throw $exception
}

$moduleRoot = Join-Path $PSScriptRoot 'modules'
$moduleOrder = @(
    'Core.ps1',
    'Configuration.ps1',
    'Build.ps1',
    'Watch.ps1'
)

try {
    foreach ($moduleName in $moduleOrder) {
        $modulePath = Join-Path $moduleRoot $moduleName
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            Write-Host "[ERROR] Required CXXForge module not found: $modulePath" -ForegroundColor Red
            Exit-CxxForge 2
        }
        . $modulePath
    }
} catch {
    if ($_.Exception.Data.Contains('CXXForgeExitCode')) {
        exit [int]$_.Exception.Data['CXXForgeExitCode']
    }
    throw
}
'@
$moduleCoreContent = @'
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
'@
$moduleConfigurationContent = @'
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
'@
$moduleBuildContent = @'
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
'@
$moduleWatchContent = @'
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
'@
$runActiveContent = @'
<# Compatibility entry point. New integrations should invoke forge.ps1. #>
param()

$entry = Join-Path $PSScriptRoot 'forge.ps1'
& $entry @args
exit $LASTEXITCODE
'@
$configJson = @'
{
    "gccPath": "",
    "gxxPath": "",
    "cFlags": ["-std=c99", "-Wall", "-finput-charset=UTF-8", "-fexec-charset=UTF-8"],
    "cxxFlags": ["-std=c++14", "-Wall", "-finput-charset=UTF-8", "-fexec-charset=UTF-8"],
    "colorFlag": "-fdiagnostics-color=always",
    "includePaths": [],
    "libPaths": [],
    "linkFlags": [],
    "injectCompilerBinToPath": true,
    "forceAsciiTemp": true,
    "autoDiscoverIncludes": true,
    "autoDiscoverLibs": true,
    "compilerBackend": "auto",
    "clangPath": "",
    "clangXxPath": "",
    "activeProfile": "release",
    "profiles": {
        "debug": {
            "cFlags": ["-g", "-O0"],
            "cxxFlags": ["-g", "-O0"],
            "defines": ["_DEBUG"]
        },
        "release": {
            "cFlags": ["-O2"],
            "cxxFlags": ["-O2"],
            "defines": ["NDEBUG"]
        },
        "release-with-debug": {
            "cFlags": ["-O2", "-g"],
            "cxxFlags": ["-O2", "-g"],
            "defines": ["NDEBUG"]
        }
    }
}
'@
$batchContent = @'
@echo off
rem CXXForge batch redirect — forwards to PowerShell runner
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0forge.ps1" %*
exit /b %ERRORLEVEL%
'@
$targetNative = $TargetDir.Replace('/', '\').Trim('\')
$targetEntryLiteral = ($targetNative.Replace("'", "''") + '\forge.ps1')
$publicEntryForTarget = $publicEntryContent.Replace("'cxxforge\forge.ps1'", "'$targetEntryLiteral'")
if ($publicEntryForTarget -eq $publicEntryContent -and $targetNative -ne 'cxxforge') {
    throw 'Could not specialize the public entry payload for TargetDir.'
}

if ((Test-Path -LiteralPath $publicEntryPath) -and -not $publicRecord -and -not $Force) {
    if (Test-FileContentEquivalent -Path $publicEntryPath -Content $publicEntryForTarget) {
        Write-Info "[INFO] Existing public entry matches this CXXForge version; preserving user ownership: $publicEntryPath" DarkGray
    } else {
        Write-Info "[ERROR] Public entry already exists and is not managed by CXXForge: $publicEntryPath" Red
        Write-Info '[HINT] Preserve or rename that file, or rerun with -Force to back it up and replace it.' Yellow
        exit 2
    }
}

$configContent = $configJson
if ($legacyMigration) {
    $legacyConfigPath = Join-Path $repoRoot ([string]$previousManifest.targetDir + '\compiler_config.json')
    if (Test-Path -LiteralPath $legacyConfigPath -PathType Leaf) {
        $configContent = (Read-TextFile -Path $legacyConfigPath).TrimEnd("`r", "`n")
        Write-Info "[INFO] Preserving legacy compiler configuration: $legacyConfigPath" DarkGreen
    }
}

# Ensure directories
New-DirectoryIfMissing $targetPath
if (-not $NoVSCode) { New-DirectoryIfMissing $vscodeDir }

# Write files
$runActivePath = Join-Path $targetPath 'run_active.ps1'
$forgePath = Join-Path $targetPath 'forge.ps1'
$modulesPath = Join-Path $targetPath 'modules'
$batchPath = Join-Path $targetPath 'run_active.bat'
$configPath = Join-Path $targetPath 'compiler_config.json'
$targetRelative = $TargetDir.Replace('\', '/').TrimEnd('/')
$managedFiles = @()
$managedFiles += [pscustomobject](Install-ManagedContent -Path $publicEntryPath -RelativePath $publicRelative -Content $publicEntryForTarget -PreviousRecord $publicRecord)
$forgeRelative = "$targetRelative/forge.ps1"
$runnerRelative = "$targetRelative/run_active.ps1"
$batchRelative = "$targetRelative/run_active.bat"
$configRelative = "$targetRelative/compiler_config.json"
$managedFiles += [pscustomobject](Install-ManagedContent -Path $forgePath -RelativePath $forgeRelative -Content $forgeContent -PreviousRecord (Get-ManifestRecord $previousManifest $forgeRelative))
$modulePayloads = [ordered]@{
    'Core.ps1' = $moduleCoreContent
    'Configuration.ps1' = $moduleConfigurationContent
    'Build.ps1' = $moduleBuildContent
    'Watch.ps1' = $moduleWatchContent
}
foreach ($moduleEntry in $modulePayloads.GetEnumerator()) {
    $moduleRelative = "$targetRelative/modules/$($moduleEntry.Key)"
    $modulePath = Join-Path $modulesPath $moduleEntry.Key
    $managedFiles += [pscustomobject](Install-ManagedContent -Path $modulePath -RelativePath $moduleRelative -Content $moduleEntry.Value -PreviousRecord (Get-ManifestRecord $previousManifest $moduleRelative))
}
$managedFiles += [pscustomobject](Install-ManagedContent -Path $runActivePath -RelativePath $runnerRelative -Content $runActiveContent -PreviousRecord (Get-ManifestRecord $previousManifest $runnerRelative))
$managedFiles += [pscustomobject](Install-ManagedContent -Path $batchPath -RelativePath $batchRelative -Content $batchContent -PreviousRecord (Get-ManifestRecord $previousManifest $batchRelative))
$managedFiles += [pscustomobject](Install-ManagedContent -Path $configPath -RelativePath $configRelative -Content $configContent -PreviousRecord (Get-ManifestRecord $previousManifest $configRelative) -PreserveOnUpgrade)

# Prepare VS Code tasks
$scriptPath = '${workspaceFolder}\cxxforge.ps1'
$fileVar = '${file}'
$wsVar = '${workspaceFolder}'
$utf8Init = 'chcp.com 65001 2>&1 | Out-Null; [Console]::InputEncoding=[System.Text.Encoding]::UTF8; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8;'
$runCmd = ('{0} & "{1}" --pretty --normalized-diag "{2}"' -f $utf8Init, $scriptPath, $fileVar)
$compileCmd = ('{0} & "{1}" --no-run --raw "{2}"' -f $utf8Init, $scriptPath, $fileVar)
$debugCompileCmd = ('{0} & "{1}" --profile debug --no-run --raw "{2}"' -f $utf8Init, $scriptPath, $fileVar)

$runTask = [ordered]@{
    type = 'shell'
    label = 'Run Active (PS)'
    command = 'powershell'
    args = @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $runCmd)
    options = [ordered]@{ cwd = $wsVar }
}
$watchCmd = ('{0} & "{1}" --pretty --normalized-diag --watch "{2}"' -f $utf8Init, $scriptPath, $fileVar)
$watchTask = [ordered]@{
    type = 'shell'
    label = 'Watch Active (PS)'
    command = 'powershell'
    args = @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $watchCmd)
    options = [ordered]@{ cwd = $wsVar }
}

$compileTask = [ordered]@{
    type = 'shell'
    label = 'Compile Active (PS)'
    command = 'powershell'
    args = @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $compileCmd)
    options = [ordered]@{ cwd = $wsVar }
    group = 'build'
}

$debugCompileTask = [ordered]@{
    type = 'shell'
    label = 'Debug Active (PS)'
    command = 'powershell'
    args = @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $debugCompileCmd)
    options = [ordered]@{ cwd = $wsVar }
}

# Add problemMatcher for better error surfacing in VS Code
$runTask.problemMatcher = @('$gcc')
$compileTask.problemMatcher = @('$gcc')
$debugCompileTask.problemMatcher = @('$gcc')
$watchTask.problemMatcher = @('$gcc')

if (-not $NoVSCode) {
    Set-TasksJson -TasksPath $tasksPath -TasksToEnsure @($runTask, $compileTask, $debugCompileTask, $watchTask)

    # Always ensure Code Runner mapping exists (create or update settings.json)
    Set-CodeRunnerSettings -SettingsPath $settingsPath -TargetDir $TargetDir

    # Generate IntelliSense configuration (c_cpp_properties.json)
    $cppPropsPath = Join-Path $vscodeDir 'c_cpp_properties.json'
    $tmpCfg = $configContent | ConvertFrom-Json
    $compilerForIntelliSense = $null
    foreach ($candidate in @($tmpCfg.gxxPath, $tmpCfg.gccPath, $tmpCfg.clangXxPath, $tmpCfg.clangPath)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $compilerForIntelliSense = $candidate; break }
    }
    if (-not $compilerForIntelliSense) {
        foreach ($name in @('g++', 'gcc', 'clang++', 'clang')) {
            $found = Get-Command $name -ErrorAction SilentlyContinue
            if ($found) { $compilerForIntelliSense = $found.Path; break }
        }
    }
    if (-not $compilerForIntelliSense) {
        $compilerForIntelliSense = 'g++.exe'
        Write-Info '[WARN] No compiler was detected on PATH; configure compiler_config.json before building.' Yellow
    }
    Set-CppProperties -CppPropsPath $cppPropsPath -CompilerPath $compilerForIntelliSense -IncludePaths @()

    # Generate debug configuration (launch.json)
    $launchPath = Join-Path $vscodeDir 'launch.json'
    Set-LaunchJson -LaunchPath $launchPath -TaskLabel 'Debug Active (PS)' -GdbPath ''
} else {
    Write-Info '[INFO] VS Code integration skipped (-NoVSCode).' DarkGray
}

$migrationSource = $null
if ($legacyMigration) {
    $migrationSource = [string]$previousManifest.targetDir
    foreach ($record in @($previousManifest.files)) {
        $legacyRelative = ([string]$record.path).Replace('\', '/')
        if (-not $record.managed -or -not $legacyRelative.StartsWith('files/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $legacyFullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $legacyRelative.Replace('/', '\')))
        if (-not $legacyFullPath.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Info "[WARN] Refusing unsafe legacy path during migration: $legacyRelative" Yellow
            continue
        }
        if (-not (Test-Path -LiteralPath $legacyFullPath -PathType Leaf)) { continue }
        $legacyHash = Get-FileHashValue $legacyFullPath
        if ($record.hash -and $legacyHash -eq [string]$record.hash) {
            if ($IS_DRY) { Write-Info "[WHATIF] Remove migrated legacy file: $legacyFullPath" DarkYellow }
            else { Remove-Item -LiteralPath $legacyFullPath -Force; Write-Info "[INFO] Removed migrated legacy file: $legacyFullPath" DarkGreen }
        } else {
            Write-Info "[WARN] Modified legacy file preserved: $legacyFullPath" Yellow
        }
    }
    if (-not $IS_DRY) {
        $legacyRoot = Join-Path $repoRoot 'files'
        foreach ($legacyDir in @((Join-Path $legacyRoot 'modules'), $legacyRoot)) {
            if ((Test-Path -LiteralPath $legacyDir -PathType Container) -and @(Get-ChildItem -LiteralPath $legacyDir -Force).Count -eq 0) {
                Remove-Item -LiteralPath $legacyDir -Force
            }
        }
    }
}

Write-InstallManifest -Path $manifestPath -Files $managedFiles -TargetDirectory $TargetDir -VSCodeEnabled (-not $NoVSCode) -MigratedFrom $migrationSource

if ($IS_DRY) { Write-Info "[INFO] Dry-run complete (WHATIF). TargetDir=$TargetDir" Green } else { Write-Info "[INFO] Installation completed. TargetDir=$TargetDir" Green }