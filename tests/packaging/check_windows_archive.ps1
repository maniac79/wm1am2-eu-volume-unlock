# Exercise the exact CI candidate ZIP under Windows PowerShell 5.1 and 7.
# NVPTOOL_ADB is pinned to a repository mock; no physical adb is called.
[CmdletBinding()]
param([ValidateSet('powershell', 'pwsh')][string]$PowerShellHost = 'powershell')
$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Profile = Get-Content -LiteralPath (Join-Path $Root 'src/org/maniac79/nvptool/Profile.java') -Raw
$Match = [regex]::Match($Profile, 'TOOL_VERSION\s*=\s*"([^"]+)"')
if (-not $Match.Success) { throw 'cannot read source version' }
$Version = $Match.Groups[1].Value
$Variant = if ($env:NVPTOOL_ARCHIVE_VARIANT) { $env:NVPTOOL_ARCHIVE_VARIANT } else { 'official' }
if (@('official','ci','local','dirty','candidate','ci-dirty','local-dirty') -notcontains $Variant) {
    throw "invalid NVPTOOL_ARCHIVE_VARIANT: $Variant"
}
$Suffix = if ($Variant -eq 'official') { '' } else { "-$Variant" }
$Zip = Join-Path $Root "dist/wm1am2-nvptool-windows-$Version$Suffix.zip"
if (-not (Test-Path -LiteralPath $Zip)) { throw "missing candidate archive: $Zip" }
$T = Join-Path ([System.IO.Path]::GetTempPath()) ('nvp-win-archive-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $T | Out-Null
try {
    Expand-Archive -LiteralPath $Zip -DestinationPath $T
    $Pkg = Join-Path $T 'wm1am2-nvptool-windows'
    $Apk = Join-Path $Pkg 'nvptool.apk'
    $Manifest = Join-Path $Pkg 'SHA256SUMS.txt'
    foreach ($Line in (Get-Content -LiteralPath $Manifest)) {
        $Parts = $Line -split '  ', 2
        if ($Parts.Count -ne 2) { throw "bad manifest line: $Line" }
        $Actual = (Get-FileHash -LiteralPath (Join-Path $Pkg $Parts[1]) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Actual -ne $Parts[0]) { throw "archive hash mismatch: $($Parts[1])" }
    }
    $Source = Get-Content -LiteralPath (Join-Path $Pkg 'SOURCE-COMMIT.txt')
    $ApkHash = (Get-FileHash -LiteralPath $Apk -Algorithm SHA256).Hash.ToLowerInvariant()
    if (@($Source | Where-Object { $_ -eq "apk_sha256=$ApkHash" }).Count -ne 1) {
        throw 'SOURCE-COMMIT.txt does not bind the packaged APK exactly once'
    }
    $ExpectedMode = if ($Variant -match '^ci') { 'ci' } elseif ($Variant -match '^local') { 'local' } else { 'release' }
    $ExpectedEligibility = if ($Variant -eq 'official') { 'true' } else { 'false' }
    if (@($Source | Where-Object { $_ -eq "signing_mode=$ExpectedMode" }).Count -ne 1 -or
        @($Source | Where-Object { $_ -eq "release_eligible=$ExpectedEligibility" }).Count -ne 1 -or
        @($Source | Where-Object { $_ -match '^certificate_sha256=[0-9a-f]{64}$' }).Count -ne 1) {
        throw 'archive signing/eligibility metadata does not match selected variant'
    }
    $Inputs = Get-Content -LiteralPath (Join-Path $Pkg 'PACKAGE-INPUTS.json') -Raw | ConvertFrom-Json
    if ($Inputs.files.'out/nvptool.apk' -ne $ApkHash) { throw 'package input APK hash mismatch' }
    if (@($Source | Where-Object { $_ -eq "package_inputs_sha256=$($Inputs.files_sha256)" }).Count -ne 1) {
        throw 'SOURCE-COMMIT.txt does not bind package inputs'
    }

    $PS = (Get-Command $PowerShellHost -ErrorAction Stop).Source
    $Nv = Join-Path $Pkg 'nvptool.ps1'
    $Menu = Join-Path $Pkg 'menu.ps1'
    $Fake = Join-Path $Root 'tests/host/fakebin-ps/fake-adb.ps1'

    # Execute the real resolver function, extracted from the unpacked script,
    # with a placeholder sibling adb.exe and no adb in PATH. The placeholder is
    # never executed: this verifies only the path decision, independent of the
    # functional simulated-adb tests below.
    $SiblingDir = Join-Path $Pkg 'platform-tools'
    New-Item -ItemType Directory -Path $SiblingDir | Out-Null
    $SiblingAdb = Join-Path $SiblingDir 'adb.exe'
    [System.IO.File]::WriteAllText($SiblingAdb, 'resolver-only placeholder')
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Nv, [ref]$null, [ref]$Errors)
    if ($Errors) { throw 'packaged PowerShell script did not parse' }
    $Resolver = @($Ast.FindAll({ param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $Node.Name -eq 'Get-AdbCommand'
    }, $true))
    if ($Resolver.Count -ne 1) { throw 'expected exactly one Get-AdbCommand function' }
    $Probe = Join-Path $Pkg 'resolver-probe.ps1'
    [System.IO.File]::WriteAllText($Probe, "function Fail { throw 'resolver failed' }`n" + $Resolver[0].Extent.Text + "`nGet-AdbCommand`n")
    $OldPath = $env:PATH
    $OldOverride = $env:NVPTOOL_ADB
    try {
        Remove-Item Env:NVPTOOL_ADB -ErrorAction SilentlyContinue
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        $Chosen = (& $PS -NoProfile -ExecutionPolicy Bypass -File $Probe 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $Chosen -ne $SiblingAdb) {
            throw "packaged resolver did not select sibling adb.exe (got: $Chosen)"
        }
    } finally {
        $env:PATH = $OldPath
        if ($null -ne $OldOverride) { $env:NVPTOOL_ADB = $OldOverride }
        Remove-Item -LiteralPath $Probe,$SiblingAdb -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $SiblingDir -Force -ErrorAction SilentlyContinue
    }

    $env:NVPTOOL_ADB = $Fake
    $env:FAKE_BUNDLED_APK = $Apk
    $env:FAKE_APP_MISSING = '1'
    $env:FAKE_STATE_DIR = Join-Path $T 'state'
    $env:NVPTOOL_BACKUP_DIR = Join-Path $T 'backups'
    New-Item -ItemType Directory -Path $env:FAKE_STATE_DIR | Out-Null

    function Run-Nv([string]$Action) {
        # Windows PowerShell 5.1 turns redirected native stderr into a
        # NativeCommandError under Stop. The missing-helper read is expected to
        # fail; keep its stderr and exit code for the strict assertion below.
        $prior = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $Output = @(& $PS -NoProfile -ExecutionPolicy Bypass -File $Nv $Action 2>&1)
            $Rc = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prior
        }
        return [pscustomobject]@{ Rc = $Rc; Output = ($Output -join "`n") }
    }
    $Result = Run-Nv 'status'
    if ($Result.Rc -ne 0 -or $Result.Output -notmatch 'NW-WM1AM2') {
        throw "archive status failed: $($Result.Output)"
    }
    $Calls = Get-Content -LiteralPath (Join-Path $env:FAKE_STATE_DIR 'calls.log') -Raw
    if ($Calls -match 'pm path| install ') { throw 'status inspected/installed the helper' }
    $Result = Run-Nv 'read'
    if ($Result.Rc -eq 0 -or $Result.Output -notmatch 'helper app is not installed') {
        throw "read without helper did not refuse: $($Result.Output)"
    }
    if (Test-Path -LiteralPath (Join-Path $env:FAKE_STATE_DIR 'installed')) {
        throw 'read implicitly installed the helper'
    }
    $Declined = ((@('7', 'no', '0') | & $PS -NoProfile -ExecutionPolicy Bypass -File $Menu) 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath (Join-Path $env:FAKE_STATE_DIR 'installed'))) {
        throw "declined packaged menu installation changed app state: $Declined"
    }
    $Calls = Get-Content -LiteralPath (Join-Path $env:FAKE_STATE_DIR 'calls.log') -Raw
    if ($Calls -match '(?m)^-s SER123 install -r ') { throw 'declined packaged menu called adb install' }

    $Approved = ((@('7', 'yes', '', '2', '', '0') |
        & $PS -NoProfile -ExecutionPolicy Bypass -File $Menu) 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $Approved -notmatch 'helper installed' -or $Approved -notmatch 'read OK') {
        throw "packaged menu did not install then read: $Approved"
    }
    $Installed = Join-Path $env:FAKE_STATE_DIR 'installed.apk'
    if (-not (Test-Path -LiteralPath $Installed)) { throw 'fake did not record installed APK' }
    if ((Get-FileHash -LiteralPath $Installed -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ApkHash) {
        throw 'installed APK differs from packaged APK'
    }
    $StarterStatus = 'starter skipped on non-Windows host'
    if ($env:OS -eq 'Windows_NT') {
        $Bat = Join-Path $Pkg 'START-windows.bat'
        $StarterOutput = ((@('1', '', '0') | & cmd.exe /c "`"$Bat`"") 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $StarterOutput -notmatch 'NW-WM1AM2') {
            throw 'packaged Windows starter did not reach menu/orchestrator'
        }
        $StarterStatus = 'starter passed'
    } else {
        Write-Host 'START-windows.bat executes only in Windows CI.'
    }
    Write-Host "PASS: Windows ZIP integrity, resolver, missing helper, menu decline/yes, verified read, $StarterStatus ($PowerShellHost mock adb)"
} finally {
    Remove-Item Env:NVPTOOL_ADB,Env:FAKE_BUNDLED_APK,Env:FAKE_APP_MISSING,Env:FAKE_STATE_DIR,Env:NVPTOOL_BACKUP_DIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}
