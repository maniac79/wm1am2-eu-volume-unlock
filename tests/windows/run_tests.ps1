# Windows/PowerShell test suite for nvptool.ps1, driven by a simulated adb.
# No device, no privileged helper, no settings or NVRAM touched.
$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
$Root = Split-Path (Split-Path $Here -Parent) -Parent
$NV   = Join-Path $Root 'tools/nvptool.ps1'
$INJ  = Join-Path $Root 'tools/inject.ps1'
$Fake = Join-Path $Root 'tests/host/fakebin-ps/fake-adb.ps1'

$PS = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' }
      elseif (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' }
      else { throw 'no PowerShell host found' }

$script:Pass = 0
$script:Fail = 0
$script:Failed = @()

function Check([string]$Name, [bool]$Cond) {
    if ($Cond) { $script:Pass++ } else { $script:Fail++; $script:Failed += $Name }
}

function New-Env {
    $t = Join-Path ([System.IO.Path]::GetTempPath()) ("npt-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $t | Out-Null
    $env:FAKE_STATE_DIR = Join-Path $t 'state'
    $env:NVPTOOL_BACKUP_DIR = Join-Path $t 'backups'
    New-Item -ItemType Directory -Force -Path $env:FAKE_STATE_DIR | Out-Null
    $env:NVPTOOL_ADB = $Fake
    foreach ($v in @('FAKE_MODEL', 'FAKE_FP', 'FAKE_PKGVER', 'FAKE_DEVICES', 'FAKE_PROFILE',
                     'FAKE_RESPONSE', 'FAKE_RESPONSE_READ', 'FAKE_RESPONSE_WRITE',
                     'FAKE_SETTINGS_RESTORE_FAIL', 'NVPTOOL_SERIAL',
                     'NVPTOOL_ALLOW_NON_BASELINE_RESTORE')) {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    return $t
}

function Run-Nv([string[]]$NvArgs) {
    $out = & $PS -NoProfile -ExecutionPolicy Bypass -File $NV @NvArgs 2>&1
    return [pscustomobject]@{ Out = ($out -join "`n"); Rc = $LASTEXITCODE }
}

function Get-BackupDir { return (Join-Path $env:NVPTOOL_BACKUP_DIR 'SER123') }

Write-Host '== status is non-mutating =='
[void](New-Env)
$r = Run-Nv @('status')
Check 'status rc 0' ($r.Rc -eq 0)
$calls = Get-Content -LiteralPath (Join-Path $env:FAKE_STATE_DIR 'calls.log') -Raw
Check 'status does not install' (-not ($calls -match 'pm path'))
Check 'status does not push' (-not ($calls -match 'push'))
Check 'status does not set settings' (-not ($calls -match 'settings put'))
Check 'status creates no backup dir' (-not (Test-Path $env:NVPTOOL_BACKUP_DIR))

Write-Host '== device binding and guards =='
[void](New-Env); $env:FAKE_DEVICES = 'AAA BBB'
Check 'multiple devices abort' ((Run-Nv @('read')).Rc -ne 0)
[void](New-Env); $env:FAKE_MODEL = 'NW-A306'
Check 'wrong model rc 11' ((Run-Nv @('apply')).Rc -eq 11)
[void](New-Env); $env:FAKE_FP = 'SonyAudio/icx1298_001/icx1298:11/1.09.05/70:user/release-keys'
Check 'wrong firmware rc 11' ((Run-Nv @('apply')).Rc -eq 11)
[void](New-Env); $env:FAKE_PKGVER = '1.0.0'
Check 'stale app version aborts' ((Run-Nv @('apply')).Rc -ne 0)

Write-Host '== read + backup =='
[void](New-Env)
$r = Run-Nv @('read')
Check 'read rc 0' ($r.Rc -eq 0)
$base = Join-Path (Get-BackupDir) 'baseline.conf'
Check 'baseline created' (Test-Path $base)
if (Test-Path $base) {
    $txt = [System.IO.File]::ReadAllText($base)
    Check 'baseline labelled' ($txt -match 'kind=baseline')
    Check 'field 0 is 512 hex chars' ($txt -match "field\.0\.hex=[0-9a-f]{512}")
    Check 'backup has integrity sidecar' (Test-Path "$base.sha256")
}

Write-Host '== apply =='
[void](New-Env)
$r = Run-Nv @('apply')
Check 'apply rc 0' ($r.Rc -eq 0)
Check 'apply reports verified' ($r.Out -match 'verified')
Check 'apply created a backup' (Test-Path (Join-Path (Get-BackupDir) 'baseline.conf'))

Write-Host '== already-modified device is not labelled factory =='
[void](New-Env); $env:FAKE_PROFILE = 'target'
$r = Run-Nv @('read')
Check 'read on modified rc 0' ($r.Rc -eq 0)
Check 'no baseline for modified device' (-not (Test-Path (Join-Path (Get-BackupDir) 'baseline.conf')))
$snap = Get-ChildItem -Path (Get-BackupDir) -Filter '*-snapshot-*.conf' -ErrorAction SilentlyContinue
Check 'snapshot recorded' ($null -ne $snap)
$r = Run-Nv @('restore')
Check 'restore without baseline rc 20' ($r.Rc -eq 20)
Check 'refusal explains snapshot' ($r.Out -match 'not a factory backup')

Write-Host '== restore from a validated baseline =='
[void](New-Env)
[void](Run-Nv @('read'))
$r = Run-Nv @('restore')
Check 'restore rc 0' ($r.Rc -eq 0)
Check 'restore reports fields' ($r.Out -match 'field 7')

Write-Host '== corrupt backup rejected =='
[void](New-Env)
[void](Run-Nv @('read'))
$base = Join-Path (Get-BackupDir) 'baseline.conf'
$txt = [System.IO.File]::ReadAllText($base)
[System.IO.File]::WriteAllText($base, ($txt -replace 'field\.0\.hex=.', 'field.0.hex=0'))
Check 'corrupt backup rc 20' ((Run-Nv @('restore')).Rc -eq 20)

Write-Host '== cleanup failure is not success =='
[void](New-Env); $env:FAKE_SETTINGS_RESTORE_FAIL = '1'
$r = Run-Nv @('apply')
Check 'cleanup failure rc 7' ($r.Rc -eq 7)
Check 'no success claim' (-not ($r.Out -match 'apply OK'))
Check 'recovery state stated' ($r.Out -match 'recovery-required')

Write-Host '== no alternative write path =='
$out = & $PS -NoProfile -ExecutionPolicy Bypass -File $INJ -ClassName 'org.maniac79.nvptool.Apply' -RunId 'X1' 2>&1
$rc = $LASTEXITCODE
Check 'inject.ps1 refuses Apply' ($rc -eq 3)
Check 'refusal names the safe route' (($out -join ' ') -match 'nvptool.ps1')

Write-Host ''
Write-Host "PASS=$($script:Pass) FAIL=$($script:Fail)"
if ($script:Fail -ne 0) {
    $script:Failed | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
exit 0
