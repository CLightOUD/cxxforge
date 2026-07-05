<# Compatibility entry point. New integrations should invoke forge.ps1. #>
param()

$entry = Join-Path $PSScriptRoot 'forge.ps1'
& $entry @args
exit $LASTEXITCODE
