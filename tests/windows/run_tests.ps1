# Windows/PowerShell test suite for nvptool.ps1, driven by a simulated adb.
# No device, no privileged helper, no settings or NVRAM touched.
[CmdletBinding()]
param(
    # Which host runs the code under test. 'auto' means "the same host that is
    # running this harness", never a different one, so a PowerShell 5.1 run
    # cannot silently exercise pwsh (or the other way round).
    [ValidateSet('auto', 'pwsh', 'powershell')]
    [string]$PowerShellHost = 'auto'
)
$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
$Root = Split-Path (Split-Path $Here -Parent) -Parent
$NV   = Join-Path $Root 'tools/nvptool.ps1'
$INJ  = Join-Path $Root 'tools/inject.ps1'
$Fake = Join-Path $Root 'tests/host/fakebin-ps/fake-adb.ps1'

function Resolve-HostExe([string]$Want) {
    if ($Want -eq 'auto') {
        $p = (Get-Process -Id $PID).Path
        if ($p) { return $p }
        throw 'cannot determine the PowerShell host executable running this harness'
    }
    $cmd = Get-Command $Want -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "PowerShell host '$Want' was requested but is not installed" }
    return $cmd.Source
}

$PS = Resolve-HostExe $PowerShellHost
$selfExe = (Get-Process -Id $PID).Path
$selfId  = "$($PSVersionTable.PSVersion)|$($PSVersionTable.PSEdition)"
$childId = (& $PS -NoProfile -Command '$PSVersionTable.PSVersion.ToString() + "|" + $PSVersionTable.PSEdition' 2>&1 | Out-String).Trim()

Write-Host "harness host : $selfId  [$selfExe]"
Write-Host "child   host : $childId  [$PS]"

# Guard against a silent interpreter switch: an explicit request must resolve to
# that executable, and 'auto' must keep the host that is running the harness.
$leaf = [System.IO.Path]::GetFileNameWithoutExtension($PS)
if ($PowerShellHost -ne 'auto' -and $leaf -ne $PowerShellHost) {
    throw "requested host '$PowerShellHost' but resolved '$leaf'"
}
if ($PowerShellHost -eq 'auto' -and $childId -ne $selfId) {
    throw "host mismatch: harness runs $selfId but child processes report $childId"
}

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

Write-Host '== cleanup failure is not success (apply stops before writing) =='
[void](New-Env); $env:FAKE_SETTINGS_RESTORE_FAIL = '1'
$r = Run-Nv @('apply')
Check 'cleanup failure rc 7' ($r.Rc -eq 7)
Check 'no success claim' (-not ($r.Out -match 'apply OK'))
Check 'recovery state stated' ($r.Out -match 'recovery-required')
Check 'says the write phase never started' ($r.Out -match 'write phase was NOT started')
Check 'backup was still taken first' ($r.Out -match 'backup:')
$calls = Get-Content -LiteralPath (Join-Path $env:FAKE_STATE_DIR 'calls.log') -Raw
$injections = ([regex]::Matches($calls, 'settings put global hidden_api_blacklist_exemptions')).Count
# Two privileged runs would mean read + write; a failed read must leave exactly one.
Check 'only the backup read ran, no write phase' ($injections -eq 1)

Write-Host '== restore stops between fields when cleanup fails =='
[void](New-Env)
[void](Run-Nv @('read'))
Set-Content -LiteralPath (Join-Path $env:FAKE_STATE_DIR 'calls.log') -Value ''
$env:FAKE_SETTINGS_RESTORE_FAIL = '1'
$r = Run-Nv @('restore')
Check 'restore aborted rc 7' ($r.Rc -eq 7)
Check 'restore makes no success claim' (-not ($r.Out -match 'restore OK'))
Check 'restore names the field it stopped after' ($r.Out -match 'stopped after field 0')
Check 'restore states the unwritten fields' ($r.Out -match 'NOT written: 7 field\(s\)')
$calls = Get-Content -LiteralPath (Join-Path $env:FAKE_STATE_DIR 'calls.log') -Raw
$injections = ([regex]::Matches($calls, 'settings put global hidden_api_blacklist_exemptions')).Count
Check 'exactly one field was written' ($injections -eq 1)
Remove-Item Env:FAKE_SETTINGS_RESTORE_FAIL -ErrorAction SilentlyContinue

Write-Host '== restore-reference cleanup failure is not success =='
[void](New-Env); $env:FAKE_SETTINGS_RESTORE_FAIL = '1'
$r = Run-Nv @('restore-reference')
Check 'restore-reference rc 7' ($r.Rc -eq 7)
Check 'restore-reference no success claim' (-not ($r.Out -match 'reference profile restored'))
Check 'restore-reference offers no reboot' (-not ($r.Out -match 'Reboot'))
Check 'restore-reference states recovery' ($r.Out -match 'could NOT be restored')
$settingPath = Join-Path $env:FAKE_STATE_DIR 'setting'
$leftover = if (Test-Path -LiteralPath $settingPath) { Get-Content -LiteralPath $settingPath -Raw } else { '' }
Check 'the setting really was left behind' ($leftover -match 'NVPTOOL-PAYLOAD')
Remove-Item Env:FAKE_SETTINGS_RESTORE_FAIL -ErrorAction SilentlyContinue

Write-Host '== no alternative write path =='
$out = & $PS -NoProfile -ExecutionPolicy Bypass -File $INJ -ClassName 'org.maniac79.nvptool.Apply' -RunId 'X1' 2>&1
$rc = $LASTEXITCODE
Check 'inject.ps1 refuses Apply' ($rc -eq 3)
Check 'refusal names the safe route' (($out -join ' ') -match 'nvptool.ps1')

Write-Host '== launcher -> menu -> orchestrator =='
$isWindowsOs = if (Test-Path Variable:\IsWindows) { $IsWindows } else { ($env:OS -eq 'Windows_NT') }
$pkg = Join-Path ([System.IO.Path]::GetTempPath()) ('nvp launch ' + [guid]::NewGuid().ToString('N').Substring(0, 8) + ' ünïcode')
New-Item -ItemType Directory -Force -Path $pkg | Out-Null
# Repackage the shipped layout: paths here contain spaces and non-ASCII characters
# on purpose, because the launcher passes them through cmd -> powershell -> nvptool.
# The archives put the menu next to copies of tools/nvptool.ps1 and tools/inject.ps1.
$layout = @{
    'menu.ps1'         = 'packaging/windows/menu.ps1'
    'START-windows.bat'= 'packaging/windows/START-windows.bat'
    'nvptool.ps1'      = 'tools/nvptool.ps1'
    'inject.ps1'       = 'tools/inject.ps1'
}
foreach ($f in $layout.Keys) {
    Copy-Item -LiteralPath (Join-Path $Root $layout[$f]) -Destination (Join-Path $pkg $f) -Force
}
$menu = Join-Path $pkg 'menu.ps1'
$packedBackups = Join-Path $pkg 'backups'

[void](New-Env)
$env:NVPTOOL_ADB = $Fake
$env:NVPTOOL_BACKUP_DIR = $packedBackups
$out = ((@('1', '', '0') | & $PS -NoProfile -ExecutionPolicy Bypass -File $menu) 2>&1 | Out-String)
$menuRc = $LASTEXITCODE
Check 'menu (status) rc 0' ($menuRc -eq 0)
Check 'menu reached the orchestrator' ($out -match 'device\s+: NW-WM1AM2')
Check 'menu shows the current options' ($out -match '4\) Restore from backup')

[void](New-Env)
$env:NVPTOOL_ADB = $Fake
$env:NVPTOOL_BACKUP_DIR = $packedBackups
$out = ((@('2', '', '0') | & $PS -NoProfile -ExecutionPolicy Bypass -File $menu) 2>&1 | Out-String)
Check 'menu (read) rc 0' ($LASTEXITCODE -eq 0)
Check 'read succeeded through the menu' ($out -match 'read OK')
$made = @(Get-ChildItem -LiteralPath $packedBackups -Recurse -Filter '*.conf' -ErrorAction SilentlyContinue)
Check 'backup written under a space/unicode path' ($made.Count -ge 1)

# Explicit backup path containing spaces and non-ASCII characters must round-trip.
$baseline = $made | Where-Object { $_.Name -like '*baseline*' } | Select-Object -First 1
if ($baseline) {
    [void](New-Env)
    $env:NVPTOOL_ADB = $Fake
    $r = Run-Nv @('restore', $baseline.FullName)
    Check 'explicit unicode path restore rc 0' ($r.Rc -eq 0)
} else {
    Check 'explicit unicode path restore rc 0' $false
}

# A failing operation must surface as a failure and must not reach a reboot step.
[void](New-Env)
$env:NVPTOOL_ADB = $Fake
$env:NVPTOOL_BACKUP_DIR = $packedBackups
$env:FAKE_SETTINGS_RESTORE_FAIL = '1'
$out = ((@('restore-ref', 'yes', '', '0') | & $PS -NoProfile -ExecutionPolicy Bypass -File $menu) 2>&1 | Out-String)
Check 'menu surfaces the exit code' ($out -match 'exit code 7')
Check 'menu makes no success claim' (-not ($out -match 'reference profile restored'))
Check 'menu does not suggest a reboot' (-not ($out -match 'Reboot now so the change'))
Remove-Item Env:FAKE_SETTINGS_RESTORE_FAIL -ErrorAction SilentlyContinue

if ($isWindowsOs) {
    $bat = Join-Path $pkg 'START-windows.bat'
    [void](New-Env)
    $env:NVPTOOL_ADB = $Fake
    $env:NVPTOOL_BACKUP_DIR = $packedBackups
    $out = ((@('1', '', '0') | & cmd.exe /c "`"$bat`"") 2>&1 | Out-String)
    Check 'START-windows.bat rc 0' ($LASTEXITCODE -eq 0)
    Check 'START-windows.bat reached the orchestrator' ($out -match 'device\s+: NW-WM1AM2')
} else {
    Write-Host '  (START-windows.bat not executed: this host is not Windows)'
}
Remove-Item -LiteralPath $pkg -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "PASS=$($script:Pass) FAIL=$($script:Fail)"
if ($script:Fail -ne 0) {
    $script:Failed | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
exit 0
