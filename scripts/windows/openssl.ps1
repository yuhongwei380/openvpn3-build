# Functions only: safe to dot-source from setup and regression tests.
# Node can inherit PowerShell 7's PSModulePath when launching Windows PowerShell.
# Load the matching built-in modules explicitly instead of resolving those copies.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Archive/Microsoft.PowerShell.Archive.psd1') -ErrorAction Stop

function Test-OpenSslX64Dll([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::OpenRead($File)
        $reader = [IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { return $false }
        $stream.Position = 0x3C
        $offset = $reader.ReadUInt32()
        if ($offset -lt 64 -or $offset + 6 -gt $stream.Length) { return $false }
        $stream.Position = $offset
        return ($reader.ReadUInt32() -eq 0x4550 -and $reader.ReadUInt16() -eq 0x8664)
    }
    catch { return $false }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Test-OpenSslSdk([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'include\openssl\ssl.h') -PathType Leaf)) { return $false }
    $hasLibraries = $false
    foreach ($directory in @('lib', 'lib\VC', 'lib\VC\x64', 'lib\VC\x64\MD', 'lib\VC\x64\MT')) {
        $libraryDirectory = Join-Path $Root $directory
        if ((Test-Path -LiteralPath (Join-Path $libraryDirectory 'libssl.lib') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $libraryDirectory 'libcrypto.lib') -PathType Leaf)) {
            $hasLibraries = $true
            break
        }
    }
    if (-not $hasLibraries) { return $false }
    foreach ($library in @('libssl', 'libcrypto')) {
        $valid = $false
        foreach ($name in @("$library-3-x64.dll", "$library-3.dll")) {
            if (Test-OpenSslX64Dll (Join-Path $Root "bin\$name")) { $valid = $true; break }
        }
        if (-not $valid) { return $false }
    }
    return $true
}

function Get-OpenSslCandidates {
    $env:OPENSSL_ROOT_DIR
    [Environment]::GetEnvironmentVariable('OPENSSL_ROOT_DIR', 'User')
    [Environment]::GetEnvironmentVariable('OPENSSL_ROOT_DIR', 'Machine')
    foreach ($name in @('OpenSSL', 'OpenSSL-Win64')) {
        Join-Path $env:ProgramFiles $name
        Join-Path ($env:SystemDrive + '\') $name
    }
    $openssl = Get-Command openssl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($openssl) { Split-Path -Parent (Split-Path -Parent $openssl.Source) }
    $release = Read-OpenSslRelease
    Get-OpenSslImageRoot (Join-Path (Get-OpenSslCacheDirectory $release) 'sdk')
    # Custom destinations may be registered by either the MSI or EXE installer.
    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'OpenSSL*' -and $_.InstallLocation } |
        ForEach-Object { $_.InstallLocation }
}

function Find-OpenSslSdk {
    foreach ($candidate in @(Get-OpenSslCandidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-OpenSslSdk $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

function Read-OpenSslRelease {
    $release = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../config/windows-openssl.json') -Raw | ConvertFrom-Json
    if ($release.version -notmatch '^3\.\d+\.\d+$' -or $release.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        $release.url -notmatch '^https://download\.firedaemon\.com/FireDaemon-OpenSSL/openssl-3\.[0-9]+\.[0-9]+\.zip$' -or
        $release.url -notlike ('*/openssl-' + $release.version + '.zip')) {
        throw 'Invalid OpenSSL 3 x64 SDK lock in config/windows-openssl.json.'
    }
    return $release
}

function Get-OpenSslCacheDirectory($Release) {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../../.work/windows/deps/openssl-$($Release.version)"))
}

function Get-OpenSslImageRoot([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    # The portable ZIP contains several architectures; accept only an x64 SDK.
    foreach ($header in @(Get-ChildItem -LiteralPath $Directory -Filter ssl.h -File -Recurse -ErrorAction SilentlyContinue)) {
        if ($header.Directory.Name -ine 'openssl' -or $header.Directory.Parent.Name -ine 'include') { continue }
        $root = $header.Directory.Parent.Parent.FullName
        if (Test-OpenSslSdk $root) { return $root }
    }
    return $null
}

function Save-OpenSslPackage($Release, [string]$Directory) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $package = Join-Path $Directory ([IO.Path]::GetFileName(([Uri]$Release.url).AbsolutePath))
    if (Test-Path -LiteralPath $package -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ine $Release.sha256) {
            throw "Cached OpenSSL package failed SHA-256 verification. Remove this file and retry: $package"
        }
        return $package
    }
    $download = $package + '.' + [Guid]::NewGuid().ToString('N') + '.download'
    try {
        Write-Host "Downloading pinned OpenSSL $($Release.version) x64 SDK..."
        # Windows PowerShell 5.1 may otherwise use an obsolete TLS default.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $previousProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Release.url -OutFile $download -UseBasicParsing
        }
        finally { $ProgressPreference = $previousProgress }
        if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ine $Release.sha256) {
            throw 'Downloaded OpenSSL SDK failed SHA-256 verification; it will not be extracted.'
        }
        Move-Item -LiteralPath $download -Destination $package
        return $package
    }
    finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
    }
}

function Expand-OpenSslPackage([string]$Package, [string]$Destination) {
    Expand-Archive -LiteralPath $Package -DestinationPath $Destination -Force
}

function Invoke-OpenSslInstall {
    $release = Read-OpenSslRelease
    $directory = Get-OpenSslCacheDirectory $release
    $package = Save-OpenSslPackage $release $directory
    Write-Host "Extracting OpenSSL $($release.version) SDK into the project cache..."
    Expand-OpenSslPackage $package (Join-Path $directory 'sdk')
    $root = Get-OpenSslImageRoot (Join-Path $directory 'sdk')
    if (-not $root) { throw "Extracted OpenSSL SDK is incomplete. Inspect $(Join-Path $directory 'sdk')." }
    # Preserve the distribution license in the location the upstream packager copies.
    $license = Join-Path $directory 'sdk\LICENSE.txt'
    if (Test-Path -LiteralPath $license -PathType Leaf) {
        Copy-Item -LiteralPath $license -Destination (Join-Path $root 'license.txt') -Force
    }
}

function Ensure-OpenSslSdk {
    $root = Find-OpenSslSdk
    if (-not $root) {
        Invoke-OpenSslInstall
        $root = Find-OpenSslSdk
    }
    if (-not $root) {
        throw 'A complete OpenSSL 3 x64 SDK was not found. Inspect the project SDK cache or set OPENSSL_ROOT_DIR to a complete OpenSSL 3 x64 SDK.'
    }
    Write-Host "Using OpenSSL x64 development files: $root"
    return $root
}
