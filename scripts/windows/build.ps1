$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '../build.ps1') --platform windows @args
exit $LASTEXITCODE
