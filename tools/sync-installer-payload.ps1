<#
Synchronize the standalone install.ps1 payload from canonical source files.
The generated installer remains a single offline-capable PowerShell script.
#>
param(
    [string]$InstallerPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$versionPath = Join-Path $repoRoot 'VERSION'
$publicEntryPath = Join-Path $repoRoot 'cxxforge.ps1'
$forgePath = Join-Path $repoRoot 'cxxforge\forge.ps1'
$runnerPath = Join-Path $repoRoot 'cxxforge\run_active.ps1'
$batchPath = Join-Path $repoRoot 'cxxforge\run_active.bat'
$moduleRoot = Join-Path $repoRoot 'cxxforge\modules'
$modulePaths = [ordered]@{
    moduleCoreContent = Join-Path $moduleRoot 'Core.ps1'
    moduleConfigurationContent = Join-Path $moduleRoot 'Configuration.ps1'
    moduleBuildContent = Join-Path $moduleRoot 'Build.ps1'
    moduleWatchContent = Join-Path $moduleRoot 'Watch.ps1'
}
$configPath = Join-Path $repoRoot 'cxxforge\compiler_config.default.json'

foreach ($path in @($InstallerPath, $versionPath, $publicEntryPath, $forgePath, $runnerPath, $batchPath, $configPath) + @($modulePaths.Values)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Read-SourceText {
    param([string]$Path)
    return [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($Path), [System.Text.Encoding]::UTF8)
}
function Write-SourceText {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Path), $Content, $utf8NoBom)
}

$version = (Read-SourceText -Path $versionPath).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "VERSION is not a valid semantic version: '$version'"
}

function Set-SingleQuotedAssignment {
    param(
        [string]$Text,
        [string]$VariableName,
        [string]$Value
    )

    $pattern = '(?m)^(\$' + [regex]::Escape($VariableName) + "\s*=\s*')[^']*(')$"
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one assignment for `$$VariableName; found $($matches.Count)."
    }
    return [regex]::Replace($Text, $pattern, { param($m) $m.Groups[1].Value + $Value + $m.Groups[2].Value }, 1)
}

$installer = Read-SourceText -Path $InstallerPath
$corePath = $modulePaths.moduleCoreContent
$coreRaw = Read-SourceText -Path $corePath
$coreUpdated = Set-SingleQuotedAssignment -Text $coreRaw -VariableName 'SCRIPT_VERSION' -Value $version
if ($coreUpdated -cne $coreRaw) {
    Write-SourceText -Path $corePath -Content $coreUpdated.TrimEnd("`r", "`n")
}
$config = (Read-SourceText -Path $configPath).TrimEnd("`r", "`n")

function Set-HereStringPayload {
    param(
        [string]$Text,
        [string]$VariableName,
        [string]$Payload
    )

    $pattern = '(?s)(\$' + [regex]::Escape($VariableName) + " = @'\r?\n).*?(\r?\n'@)"
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one payload block for `$$VariableName; found $($matches.Count)."
    }
    return [regex]::Replace(
        $Text,
        $pattern,
        { param($m) $m.Groups[1].Value + $Payload + $m.Groups[2].Value },
        1
    )
}

$installer = Set-SingleQuotedAssignment -Text $installer -VariableName 'INSTALLER_VERSION' -Value $version
$installer = Set-HereStringPayload -Text $installer -VariableName 'publicEntryContent' -Payload ((Read-SourceText -Path $publicEntryPath).TrimEnd("`r", "`n"))
$installer = Set-HereStringPayload -Text $installer -VariableName 'forgeContent' -Payload ((Read-SourceText -Path $forgePath).TrimEnd("`r", "`n"))
foreach ($moduleEntry in $modulePaths.GetEnumerator()) {
    $installer = Set-HereStringPayload -Text $installer -VariableName $moduleEntry.Key -Payload ((Read-SourceText -Path $moduleEntry.Value).TrimEnd("`r", "`n"))
}
$installer = Set-HereStringPayload -Text $installer -VariableName 'runActiveContent' -Payload ((Read-SourceText -Path $runnerPath).TrimEnd("`r", "`n"))
$installer = Set-HereStringPayload -Text $installer -VariableName 'batchContent' -Payload ((Read-SourceText -Path $batchPath).TrimEnd("`r", "`n"))
$installer = Set-HereStringPayload -Text $installer -VariableName 'configJson' -Payload $config
$installer = $installer.TrimEnd("`r", "`n")

Write-SourceText -Path $InstallerPath -Content $installer
Write-Host "[OK] Version $version and portable installer payload synchronized: $InstallerPath" -ForegroundColor Green
