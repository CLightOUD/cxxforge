param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$runner = Join-Path $repoRoot 'cxxforge.ps1'
$artifacts = Join-Path $PSScriptRoot '.artifacts'
$mixedProject = Join-Path $PSScriptRoot 'fixtures\mixed-project\cxxforge.json'
$sidecarMain = Join-Path $PSScriptRoot 'fixtures\sidecar\main.cpp'

New-Item -ItemType Directory -Path $artifacts -Force | Out-Null

function Invoke-RunnerTest {
    param(
        [string]$Name,
        [string[]]$RunnerArgs
    )

    Write-Host "[TEST] $Name" -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -File $runner @RunnerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Test failed: $Name (exit=$LASTEXITCODE)"
    }
}

$mixedOut = Join-Path $artifacts 'mixed'
Invoke-RunnerTest -Name 'mixed C/C++ project with duplicate basenames' -RunnerArgs @(
    '--no-run', '--no-color', '--rebuild', '--out-dir', $mixedOut, $mixedProject
)

$objects = @(Get-ChildItem -LiteralPath (Join-Path $mixedOut '.cxxforge\obj') -Filter '*.o')
if ($objects.Count -ne 3) {
    throw "Expected 3 unique object files, found $($objects.Count)."
}
$mixedExe = Join-Path $mixedOut 'mixed-project.exe'
if (-not (Test-Path -LiteralPath $mixedExe)) {
    throw 'Mixed project executable was not produced.'
}

Invoke-RunnerTest -Name 'incremental project rebuild' -RunnerArgs @(
    '--no-run', '--no-color', '--out-dir', $mixedOut, $mixedProject
)

[System.IO.File]::Delete($mixedExe)
Invoke-RunnerTest -Name 'missing executable triggers relink' -RunnerArgs @(
    '--no-run', '--no-color', '--out-dir', $mixedOut, $mixedProject
)
if (-not (Test-Path -LiteralPath $mixedExe)) {
    throw 'Missing executable was not relinked from current object files.'
}

$sidecarOut = Join-Path $artifacts 'sidecar'
Invoke-RunnerTest -Name 'sidecar sources resolve relative to primary source' -RunnerArgs @(
    '--no-run', '--no-color', '--out-dir', $sidecarOut, $sidecarMain
)

Write-Host '[PASS] CXXForge integration tests completed.' -ForegroundColor Green
