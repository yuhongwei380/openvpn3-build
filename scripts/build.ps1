$ErrorActionPreference = 'Stop'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error 'Node.js 22 or newer is required. Install Node.js and reopen PowerShell.'
    exit 1
}
& node (Join-Path $PSScriptRoot '../install.mjs') @args
exit $LASTEXITCODE
