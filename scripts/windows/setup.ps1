$ErrorActionPreference = 'Stop'
if (-not $env:OPENVPN_BUILD_ENV_FILE -or -not $env:OPENVPN_BUILD_NODE) {
    throw 'Run node install.mjs from the repository root.'
}
. (Join-Path $PSScriptRoot 'openssl.ps1')

function Refresh-BuildPath {
    $cargoDirectory = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
    $parts = @(
        (Split-Path -Parent $env:OPENVPN_BUILD_NODE),
        (Join-Path $cargoDirectory 'bin'),
        $env:PATH,
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User'),
        (Join-Path $env:ProgramFiles 'Git\cmd')
    )
    $env:PATH = ($parts | Where-Object { $_ }) -join ';'
}

function Install-BuildTool([string]$Id) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "Installing $Id requires winget. Install Microsoft's App Installer, then rerun node install.mjs."
    }
    Write-Host "Installing missing build tool: $Id"
    & winget.exe install --id $Id --exact --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "winget failed to install $Id (exit $LASTEXITCODE)." }
    Refresh-BuildPath
}

Refresh-BuildPath
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    throw 'Install the full Node.js 22+ distribution, including npm, and rerun node install.mjs.'
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { Install-BuildTool 'Git.Git' }
if (-not (Get-Command rustup.exe -ErrorAction SilentlyContinue)) { Install-BuildTool 'Rustlang.Rustup' }
foreach ($tool in @('git.exe', 'rustup.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is unavailable after installation. Reopen the terminal and retry." }
}

$toolchain = 'stable-x86_64-pc-windows-msvc'
$installed = & rustup.exe toolchain list
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Rust toolchains.' }
if (-not ($installed | Where-Object { $_ -match ('^' + [regex]::Escape($toolchain) + '(\s|$)') })) {
    & rustup.exe toolchain install $toolchain --profile minimal
    if ($LASTEXITCODE -ne 0) { throw 'Rust MSVC toolchain installation failed.' }
}
& rustup.exe run $toolchain cargo --version
if ($LASTEXITCODE -ne 0) { throw 'The Rust MSVC toolchain is not usable.' }

# Resolve the SDK here: winget may confuse Light 4.x with the development package.
# Use an existing complete 3.x SDK or a pinned project-local portable SDK.
$openSslRoot = Ensure-OpenSslSdk
# The upstream script still prepares CMake, Visual Studio C++/SDK and Asio/fmt.
$environment = @{ PATH = $env:PATH; RUSTUP_TOOLCHAIN = $toolchain; OPENSSL_ROOT_DIR = $openSslRoot } | ConvertTo-Json
[IO.File]::WriteAllText($env:OPENVPN_BUILD_ENV_FILE, $environment, [Text.UTF8Encoding]::new($false))
Write-Host 'Git, Rust and the OpenSSL x64 SDK are ready. Remaining native dependencies are handled by the upstream build.'
