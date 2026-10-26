param([Parameter(Mandatory = $true)][string]$WorkDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/windows/openssl.ps1')

function Assert-True($Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function New-TestDll([string]$File, [uint16]$Machine = 0x8664) {
    $bytes = New-Object byte[] 128
    [BitConverter]::GetBytes([uint16]0x5A4D).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([uint32]64).CopyTo($bytes, 0x3C)
    [BitConverter]::GetBytes([uint32]0x4550).CopyTo($bytes, 64)
    [BitConverter]::GetBytes($Machine).CopyTo($bytes, 68)
    [IO.File]::WriteAllBytes($File, $bytes)
}
function New-TestSdk([string]$Root, [switch]$Light, [uint16]$Machine = 0x8664) {
    New-Item -ItemType Directory -Path (Join-Path $Root 'bin') -Force | Out-Null
    foreach ($name in @('libssl-3-x64.dll', 'libcrypto-3-x64.dll')) {
        New-TestDll (Join-Path $Root "bin\$name") $Machine
    }
    if (-not $Light) {
        New-Item -ItemType Directory -Path (Join-Path $Root 'include\openssl'), (Join-Path $Root 'lib\VC\x64\MD') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root 'include\openssl\ssl.h'), '// test header')
        foreach ($name in @('libssl.lib', 'libcrypto.lib')) {
            [IO.File]::WriteAllText((Join-Path $Root "lib\VC\x64\MD\$name"), 'test import library')
        }
    }
}

$complete = Join-Path $WorkDirectory 'Program Files\OpenSSL'
$light = Join-Path $WorkDirectory 'OpenSSL-Win64-Light'
$x86 = Join-Path $WorkDirectory 'OpenSSL-x86'
New-TestSdk $complete
New-TestSdk $light -Light
New-TestSdk $x86 -Machine 0x14C
Assert-True (Test-OpenSslSdk $complete) 'The new MSI installation directory must be accepted.'
Assert-True (-not (Test-OpenSslSdk $light)) 'Runtime-only Light packages must be rejected.'
Assert-True (-not (Test-OpenSslSdk $x86)) 'x86 DLLs must not be accepted for x64 builds.'

$version4 = Join-Path $WorkDirectory 'OpenSSL-Light-4.1'
New-TestSdk $version4 -Light
foreach ($library in @('libssl', 'libcrypto')) {
    Rename-Item -LiteralPath (Join-Path $version4 "bin\$library-3-x64.dll") -NewName "$library-4-x64.dll"
}
Assert-True (-not (Test-OpenSslSdk $version4)) 'The installed Light 4.x package must not satisfy the SDK requirement.'

$script:release = Read-OpenSslRelease
Assert-True ($script:release.version -match '^3\.') 'The production SDK must pin OpenSSL 3.'
Assert-True ($script:release.url -match '\.zip$') 'Use a portable ZIP, not a conflicting system installer.'
$script:cache = Join-Path $WorkDirectory 'Project SDK Cache With Spaces'
$script:roots = @($version4, $light, $complete)
function Get-OpenSslCandidates {
    $script:roots
    Get-OpenSslImageRoot (Join-Path $script:cache 'sdk')
}
# No global package installation is permitted in either the test or this flow.
function winget.exe { throw 'OpenSSL provisioning must not invoke winget.' }
Assert-True ((Ensure-OpenSslSdk) -eq $complete) 'An existing complete SDK must be reused.'
Assert-True (-not (Test-Path -LiteralPath $script:cache)) 'Existing SDKs must not cause downloads or extraction.'

$testPackage = Join-Path $WorkDirectory 'test-package.bin'
[IO.File]::WriteAllText($testPackage, 'test SDK ZIP payload')
$script:release.sha256 = (Get-FileHash -LiteralPath $testPackage -Algorithm SHA256).Hash
function Read-OpenSslRelease { $script:release }
function Get-OpenSslCacheDirectory($Release) { $script:cache }
$script:downloads = 0
$script:extractions = 0
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    Assert-True ($Uri -eq $script:release.url) 'Download only the configured SDK URL.'
    $script:downloads++
    Copy-Item -LiteralPath $testPackage -Destination $OutFile
}
function Expand-OpenSslPackage([string]$Package, [string]$Destination) {
    $script:extractions++
    Assert-True ((Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash -eq $script:release.sha256) 'Verify SHA-256 before extracting.'
    # An ARM SDK sorts first in the real ZIP; the resolver must choose x64.
    New-TestSdk (Join-Path $Destination 'arm64') -Machine 0xAA64
    New-TestSdk (Join-Path $Destination 'x64')
    [IO.File]::WriteAllText((Join-Path $Destination 'LICENSE.txt'), 'test distribution license')
}

$script:roots = @($version4, $light)
$expected = Join-Path $script:cache 'sdk\x64'
Assert-True ((Ensure-OpenSslSdk) -eq $expected) 'An installed Light 4.x must lead to a separate local OpenSSL 3 SDK.'
Assert-True ($script:downloads -eq 1 -and $script:extractions -eq 1) 'Download and extract exactly once.'
Assert-True (Test-Path -LiteralPath (Join-Path $expected 'license.txt')) 'Keep the license where the upstream packager copies it.'
Assert-True ((Ensure-OpenSslSdk) -eq $expected) 'A previously extracted x64 SDK must be reused.'
Assert-True ($script:downloads -eq 1 -and $script:extractions -eq 1) 'Reusing the local SDK must not download again.'

$package = Save-OpenSslPackage $script:release $script:cache
[IO.File]::WriteAllText($package, 'tampered archive')
$failed = $false
try { Save-OpenSslPackage $script:release $script:cache | Out-Null }
catch { $failed = $_.Exception.Message -match 'Cached.*SHA-256' }
Assert-True $failed 'Corrupt cached packages must not be extracted.'
Assert-True ($script:downloads -eq 1) 'A corrupt cache must produce an actionable error instead of reinstalling system packages.'

$badRelease = [pscustomobject]@{ url = $script:release.url; sha256 = ('0' * 64) }
$badCache = Join-Path $WorkDirectory 'Bad Download'
$failed = $false
try { Save-OpenSslPackage $badRelease $badCache | Out-Null }
catch { $failed = $_.Exception.Message -match 'Downloaded.*SHA-256' }
Assert-True $failed 'A downloaded hash mismatch must fail before extraction.'
Assert-True (@(Get-ChildItem -LiteralPath $badCache -Force).Count -eq 0) 'Remove only the failed temporary download.'
Assert-True ($script:extractions -eq 1) 'Invalid archives must never reach extraction.'
Write-Host 'OpenSSL regression checks passed: Light 4.x isolation, SDK reuse, x64 selection, pinned archive hashes and license staging.'
