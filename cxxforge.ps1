<# Stable public entry point for the workspace-local CXXForge runtime. #>
param()

$entry = Join-Path $PSScriptRoot 'cxxforge\forge.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    Write-Host "[ERROR] CXXForge runtime entry not found: $entry" -ForegroundColor Red
    exit 2
}

& $entry @args
exit $LASTEXITCODE
