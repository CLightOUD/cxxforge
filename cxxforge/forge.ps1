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
