# Simulated adb for tests. Native on Windows PowerShell and on pwsh.
# Select it by pointing NVPTOOL_ADB at this file. No real device involved.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Argv)
$ErrorActionPreference = 'Continue'
$S = $env:FAKE_STATE_DIR
if (-not $S) { [Console]::Error.WriteLine('FAKE_STATE_DIR not set'); exit 2 }
New-Item -ItemType Directory -Force -Path $S | Out-Null
Add-Content -LiteralPath (Join-Path $S 'calls.log') -Value ($Argv -join ' ')

$script:FakePid = if ($env:FAKE_PID) { [int]$env:FAKE_PID } else { 4201 }
$devices = if ($env:FAKE_DEVICES) { $env:FAKE_DEVICES -split '\s+' } else { @('SER123') }
$model   = if ($env:FAKE_MODEL) { $env:FAKE_MODEL } else { 'NW-WM1AM2' }
$fp      = if ($env:FAKE_FP) { $env:FAKE_FP } else { 'SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys' }
$ver     = if ($env:FAKE_PKGVER) { $env:FAKE_PKGVER } else { '0.2.4' }
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

    $head = "NVPTOOL_RESULT v=1 schema=1 tool=0.2.4 run=$run op=$op pid=$($script:FakePid)"
    $out = @()
    if ($resp -eq 'noout') { return $out }
    $out += "$head ev=begin"
    if ($env:FAKE_NO_CLAIM -ne '1') { $out += "$head ev=note msg=claim_acquired mode=file" }
    if ($env:FAKE_DUP_SKIPPED -eq '1') { $out += "$head ev=note msg=duplicate_skipped" }
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
        default {
            # A read never writes; the host validates that explicitly.
            if ($op -eq 'read') { 'status=OK phase=done written=0 verified=8 total=8 reason=-' }
            else { 'status=OK phase=done written=8 verified=8 total=8 reason=-' }
        }
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
            # FAKE_DUP_LATE=1  -> second execution with identical records (read)
            # FAKE_DUP_ABORT=1 -> apply only: second execution aborts because the
            #                     first already wrote (digest-bound, as on hardware)
            $pushIsApply = ((Get-Content -LiteralPath $rest[1] -Raw) -match 'nvptool\.Apply')
            $late = ($env:FAKE_DUP_LATE -eq '1') -or (($env:FAKE_DUP_ABORT -eq '1') -and $pushIsApply)
            if ($late) {
                $savedResp = $env:FAKE_RESPONSE_WRITE
                if (($env:FAKE_DUP_ABORT -eq '1') -and $pushIsApply) { $env:FAKE_RESPONSE_WRITE = 'abort' }
                $script:FakePid = if ($env:FAKE_PID2) { [int]$env:FAKE_PID2 } else { 4202 }
                Set-Content -LiteralPath (Join-Path $S 'pending_late') -Value (New-ResultLines $rest[1])
                $script:FakePid = if ($env:FAKE_PID) { [int]$env:FAKE_PID } else { 4201 }
                $env:FAKE_RESPONSE_WRITE = $savedResp
                Remove-Item -LiteralPath (Join-Path $S 'lc_reads') -ErrorAction SilentlyContinue
            }
            exit 0
        }
        'pull' {
            if ($env:FAKE_PULL_FAIL -eq '1') { exit 1 }
            $source = if (Test-Path (Join-Path $S 'installed.apk')) { Join-Path $S 'installed.apk' }
                      elseif ($env:FAKE_INSTALLED_APK) { $env:FAKE_INSTALLED_APK }
                      else { $env:FAKE_BUNDLED_APK }
            Copy-Item -LiteralPath $source -Destination $rest[2] -Force
            exit 0
        }
        'install' {
            if ($env:FAKE_INSTALL_FAIL -eq '1') { exit 1 }
            Copy-Item -LiteralPath $rest[2] -Destination (Join-Path $S 'installed.apk') -Force
            $env:FAKE_INSTALLED_APK = Join-Path $S 'installed.apk'
            Set-Content -LiteralPath (Join-Path $S 'installed') -Value '1'
            Write-Output 'Success'
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
    if ($cmd -match 'pm path') {
        if ($env:FAKE_APP_MISSING -eq '1' -and -not (Test-Path (Join-Path $S 'installed'))) { exit 0 }
        Write-Output 'package:/data/app/x/base.apk'; exit 0
    }
    if ($cmd -match 'dumpsys package') { Write-Output "    versionName=$ver"; exit 0 }
    if ($cmd -match '^test -r') { exit 0 }
    if ($cmd -match '^mkdir /data/local/tmp/nvptool\.lock$') {
        $lock = Join-Path $S 'remote-lock'
        if (Test-Path $lock) { exit 1 }
        New-Item -ItemType Directory -Path $lock | Out-Null
        exit 0
    }
    if ($cmd -match '^printf .* > /data/local/tmp/nvptool\.lock/owner$') {
        if ($cmd -match "^printf '%s' '([^']+)' >") {
            Set-Content -LiteralPath (Join-Path $S 'remote-lock/owner') -Value $Matches[1] -NoNewline
            exit 0
        }
        exit 1
    }
    if ($cmd -eq 'cat /data/local/tmp/nvptool.lock/owner') {
        $p = Join-Path $S 'remote-lock/owner'
        if (-not (Test-Path $p)) { exit 1 }
        Get-Content -LiteralPath $p
        exit 0
    }
    if ($cmd -eq 'rm -f /data/local/tmp/nvptool.lock/owner && rmdir /data/local/tmp/nvptool.lock') {
        Remove-Item -LiteralPath (Join-Path $S 'remote-lock') -Recurse -Force
        exit 0
    }
    if ($cmd -match 'logcat -d') {
        $l = Join-Path $S 'logcat'
        # FAKE_DUP_LATE=1: a second execution whose records only appear after the
        # host has already seen the first summary.
        $late = Join-Path $S 'pending_late'
        if (Test-Path $late) {
            $readsFile = Join-Path $S 'lc_reads'
            $n = 0
            if (Test-Path $readsFile) { $n = [int]((Get-Content -LiteralPath $readsFile -Raw).Trim()) }
            $n++
            Set-Content -LiteralPath $readsFile -Value "$n"
            if ($n -ge 2) {
                Add-Content -LiteralPath $l -Value (Get-Content -LiteralPath $late)
                Remove-Item -LiteralPath $late -Force
            }
        }
        if (Test-Path $l) { Get-Content -LiteralPath $l }
        exit 0
    }
    if ($cmd -match 'settings get global hidden_api_blacklist_exemptions') {
        if ($env:FAKE_SETTINGS_GET_FAIL -eq '1') { exit 1 }
        Write-Output (Get-Setting); exit 0
    }
    if ($cmd -eq 'settings list global') {
        if ($env:FAKE_SETTINGS_LIST_FAIL -eq '1') { exit 1 }
        if (Test-Path (Join-Path $S 'setting')) { Write-Output "hidden_api_blacklist_exemptions=$(Get-Setting)" }
        exit 0
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
        if ($env:FAKE_START_FAIL -eq '1') { exit 1 }
        $p = Join-Path $S 'pending'
        if ((Test-Path $p) -and (Test-Path (Join-Path $S 'armed'))) {
            Add-Content -LiteralPath (Join-Path $S 'logcat') -Value (Get-Content -LiteralPath $p)
            Remove-Item -LiteralPath (Join-Path $S 'armed') -ErrorAction SilentlyContinue
        }
        exit 0
    }
    if ($cmd -match '^rm -f /data/local/tmp/nvptool-') { exit 0 }
    exit 0
}
exit 0

