# Simulated adb for tests. Native on Windows PowerShell and on pwsh.
# Select it by pointing NVPTOOL_ADB at this file. No real device involved.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv)
$ErrorActionPreference = 'Continue'
$S = $env:FAKE_STATE_DIR
if (-not $S) { [Console]::Error.WriteLine('FAKE_STATE_DIR not set'); exit 2 }
New-Item -ItemType Directory -Force -Path $S | Out-Null
Add-Content -LiteralPath (Join-Path $S 'calls.log') -Value ($Argv -join ' ')

$devices = if ($env:FAKE_DEVICES) { $env:FAKE_DEVICES -split '\s+' } else { @('SER123') }
$model   = if ($env:FAKE_MODEL) { $env:FAKE_MODEL } else { 'NW-WM1AM2' }
$fp      = if ($env:FAKE_FP) { $env:FAKE_FP } else { 'SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys' }
$ver     = if ($env:FAKE_PKGVER) { $env:FAKE_PKGVER } else { '0.2.1' }
$dest    = if ($env:FAKE_DEST) { $env:FAKE_DEST } else { '03010000' }
$safe    = if ($env:FAKE_SAFE) { $env:FAKE_SAFE } else { '01000000' }

function Get-Setting {
    $p = Join-Path $S 'setting'
    if (Test-Path $p) { return ((Get-Content -LiteralPath $p -Raw)) }
    return 'null'
}
function Set-Setting([string]$v) { [System.IO.File]::WriteAllText((Join-Path $S 'setting'), $v) }
function Get-PadHex([string]$Text) {
    $b = New-Object byte[] 256
    $n = [Math]::Min($Text.Length, 256)
    for ($i = 0; $i -lt $n; $i++) { $b[$i] = [byte][char]$Text[$i] }
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-ResultLines([string]$Payload) {
    $last = @(Get-Content -LiteralPath $Payload)[-1]
    $toks = $last -split ' '
    $cls = ''; $run = ''
    for ($i = 0; $i -lt $toks.Count; $i++) {
        if ($toks[$i] -like 'org.maniac79.nvptool.*') { $cls = $toks[$i]; $run = $toks[$i + 1]; break }
    }
    $op = switch -Wildcard ($cls) {
        '*Read' { 'read' } '*Apply' { 'apply' }
        '*RestoreField' { 'restore' } '*RestoreReference' { 'restore_reference' }
        default { 'unknown' }
    }
    $resp = if ($env:FAKE_RESPONSE) { $env:FAKE_RESPONSE } else { 'ok' }
    if ($op -eq 'read') {
        if ($env:FAKE_RESPONSE_READ) { $resp = $env:FAKE_RESPONSE_READ }
    } elseif ($env:FAKE_RESPONSE_WRITE) { $resp = $env:FAKE_RESPONSE_WRITE }

    $head = "NVPTOOL_RESULT v=1 schema=1 tool=0.2.1 run=$run op=$op"
    $out = @()
    if ($resp -eq 'noout') { return $out }
    $out += "$head ev=begin"
    if ($resp -eq 'truncated') { return $out }
    if ($op -eq 'read' -or $op -eq 'restore') {
        $target = ($env:FAKE_PROFILE -eq 'target')
        if ($target) {
            $sv = @('kVolTblIcx1298HpSeGainHigh', 'kVolTblIcx1298HpSeGainLow',
                    'kVolTblIcx1298HpBtlGainHigh', 'kVolTblIcx1298HpBtlGainLow')
            $iv = @('01000000', '01000000', '01000000', '00000000')
        } else {
            $sv = @('kVolTblIcx1298CewHpSe', 'kVolTblIcx1298CewHpSe',
                    'kVolTblIcx1298CewHpBtl', 'kVolTblIcx1298CewHpBtl')
            $iv = @('00000000', '00000000', '00000000', '01000000')
        }
        for ($i = 0; $i -lt 8; $i++) {
            if ($i -lt 4) { $hex = Get-PadHex $sv[$i]; $len = 256 }
            else { $hex = $iv[$i - 4]; $len = 4 }
            $out += "$head ev=field idx=$i key=f$i len=$len val=$hex"
        }
    }
    $sum = switch ($resp) {
        'fatal' { 'status=FATAL phase=preflight written=0 verified=0 total=8 reason=hal_unavailable' }
        'abort' { 'status=ABORT phase=read written=0 verified=0 total=8 reason=state_changed_since_backup' }
        'incomplete' { 'status=INCOMPLETE phase=write written=2 verified=2 total=8 reason=write_failed_2' }
        default { 'status=OK phase=done written=8 verified=8 total=8 reason=-' }
    }
    $out += "$head ev=summary $sum"
    if ($resp -eq 'dup') { $out += "$head ev=summary $sum" }
    return $out
}

$sub = $Argv[0]
if ($sub -eq 'devices') {
    Write-Output 'List of devices attached'
    foreach ($d in $devices) { Write-Output "$d`tdevice" }
    exit 0
}
if ($sub -eq '-s') {
    $rest = @($Argv | Select-Object -Skip 2)
    switch ($rest[0]) {
        'push' {
            Set-Content -LiteralPath (Join-Path $S 'pending') -Value (New-ResultLines $rest[1])
            exit 0
        }
        'reboot' { exit 0 }
        'shell' { break }
        default { exit 0 }
    }
    $cmd = ($rest | Select-Object -Skip 1) -join ' '
    if ($cmd -match 'getprop ro\.product\.model') { Write-Output $model; exit 0 }
    if ($cmd -match 'getprop ro\.build\.fingerprint') { Write-Output $fp; exit 0 }
    if ($cmd -match 'getprop vendor\.destination') { Write-Output $dest; exit 0 }
    if ($cmd -match 'getprop vendor\.safe_volume\.enabled') { Write-Output $safe; exit 0 }
    if ($cmd -match 'pm path') { Write-Output 'package:/data/app/x/base.apk'; exit 0 }
    if ($cmd -match 'dumpsys package') { Write-Output "    versionName=$ver"; exit 0 }
    if ($cmd -match '^test -r') { exit 0 }
    if ($cmd -match 'logcat -d') {
        $l = Join-Path $S 'logcat'
        if (Test-Path $l) { Get-Content -LiteralPath $l }
        exit 0
    }
    if ($cmd -match 'settings get global hidden_api_blacklist_exemptions') {
        Write-Output (Get-Setting); exit 0
    }
    if ($cmd -match 'settings put global hidden_api_blacklist_exemptions') {
        if ($cmd -match '\$\(cat') {
            Set-Setting 'NVPTOOL-PAYLOAD'
            Set-Content -LiteralPath (Join-Path $S 'logcat') -Value @()
            Set-Content -LiteralPath (Join-Path $S 'armed') -Value '1'
        } elseif ($env:FAKE_SETTINGS_RESTORE_FAIL -ne '1') {
            Set-Setting ($cmd.Substring($cmd.LastIndexOf(' ') + 1).Trim('"'))
        }
        exit 0
    }
    if ($cmd -match 'settings delete global hidden_api_blacklist_exemptions') {
        if ($env:FAKE_SETTINGS_RESTORE_FAIL -ne '1') {
            Remove-Item -LiteralPath (Join-Path $S 'setting') -ErrorAction SilentlyContinue
        }
        exit 0
    }
    if ($cmd -match 'am start') {
        $p = Join-Path $S 'pending'
        if ((Test-Path $p) -and (Test-Path (Join-Path $S 'armed'))) {
            Add-Content -LiteralPath (Join-Path $S 'logcat') -Value (Get-Content -LiteralPath $p)
            Remove-Item -LiteralPath (Join-Path $S 'armed') -ErrorAction SilentlyContinue
        }
        exit 0
    }
    exit 0
}
exit 0

