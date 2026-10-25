# nvptool.ps1 - native Windows host orchestrator (parity with nvptool.sh)
#
#   status | install | read | apply | restore [file] | restore-reference | reboot
#
# Same Java payload, guards and backup format (byte-identical to the bash
# implementation, so backups are interchangeable). Exit codes:
#   0 ok | 3 nothing written | 4 outcome unknown | 5 write failed
#   6 reboot failed | 7 cleanup failed (recovery required) | 11 unsupported
#   20 backup invalid | 21 non-baseline restore without consent
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- constants
$ToolVersion = '0.2.3'
$Schema      = '1'
$Pkg         = 'org.maniac79.nvptool'
$Hal         = '/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk'
$Model       = 'NW-WM1AM2'
$Fingerprint = 'SonyAudio/icx1298_001/icx1298:11/1.09.00/68:user/release-keys'

$Keys = @(
    'ro.vendor.alc.voltbl_id.se_high',
    'ro.vendor.alc.voltbl_id.se_low',
    'ro.vendor.alc.voltbl_id.btl_high',
    'ro.vendor.alc.voltbl_id.btl_low',
    'ro.app.highgain.mode',
    'ro.volume.gain.se',
    'ro.volume.gain.btl',
    'ro.safe_volume.enabled'
)
$Lens = @(256, 256, 256, 256, 4, 4, 4, 4)

$script:Serial = ''
$script:SettingsState = ''
$script:SettingsCaptured = $false
$script:SettingsTouched = $false
$script:CleanupAttempted = $false
$script:RunDir = ''
$script:CleanupOk = $true
$script:RemoteLockHeld = $false
$script:RemoteLock = '/data/local/tmp/nvptool.lock'
$script:RecoveryRecord = ''
# Collection window after the setting is disarmed: a second execution that lands
# after the first summary must still be inside the snapshot.
$script:SettleSecs = if ($env:NVPTOOL_SETTLE_SECS) { [int]$env:NVPTOOL_SETTLE_SECS } else { 3 }
$script:LocalLockError = ''
$script:RemotePayloads = @()

function Fail([string]$Message, [int]$Code = 1) {
    $e = New-Object System.Exception("nvptool: $Message")
    $e.Data['ExitCode'] = $Code
    throw $e
}

# ------------------------------------------------------------------ helpers
function Get-AdbCommand {
    # Test harness hook: point NVPTOOL_ADB at a simulator. Otherwise real adb.
    if ($env:NVPTOOL_ADB) {
        if (-not [System.IO.Path]::IsPathRooted($env:NVPTOOL_ADB) -or
            -not (Test-Path -LiteralPath $env:NVPTOOL_ADB -PathType Leaf)) {
            Fail 'NVPTOOL_ADB must be an absolute path to an existing adb executable' 2
        }
        return $env:NVPTOOL_ADB
    }
    # The archive is flat; source checkouts keep the script under tools/.
    foreach ($base in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent))) {
        $sibling = Join-Path $base 'platform-tools/adb.exe'
        if (Test-Path -LiteralPath $sibling -PathType Leaf) { return $sibling }
        $sibling = Join-Path $base 'platform-tools/adb'
        if (Test-Path -LiteralPath $sibling -PathType Leaf) { return $sibling }
    }
    $c = Get-Command adb -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    Fail 'adb not found in PATH' 2
}

function Invoke-Adb {
    # No param() block on purpose: adb-style arguments such as '-s' must arrive
    # as plain strings in $args, not be parsed as PowerShell parameters.
    $AdbArgs = @($args)
    $adb = Get-AdbCommand
    $out = & $adb @AdbArgs 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Output = @($out | ForEach-Object { "$_" }); Code = $code }
}

function Invoke-AdbText {
    $AdbArgs = @($args)
    $r = Invoke-Adb @AdbArgs
    return (($r.Output -join "`n").Trim())
}

function Get-Prop([string]$Name) {
    return (Invoke-AdbText '-s' $script:Serial 'shell' "getprop $Name")
}

function Select-Device {
    $list = @(
        (Invoke-AdbText 'devices') -split "`n" |
            Select-Object -Skip 1 |
            Where-Object { $_ -match "`tdevice$" } |
            ForEach-Object { ($_ -split "`t")[0] } |
            Where-Object { $_ }
    )
    if ($list.Count -eq 0) { Fail 'no authorised adb device (enable USB debugging and accept the prompt)' }
    if ($list.Count -gt 1) { Fail 'more than one adb device attached; disconnect others or set NVPTOOL_SERIAL' }
    if ($env:NVPTOOL_SERIAL -and $env:NVPTOOL_SERIAL -ne $list[0]) {
        Fail "attached device $($list[0]) does not match requested serial $env:NVPTOOL_SERIAL"
    }
    $script:Serial = $list[0]
}

function Assert-DevicePresent {
    $now = @((Invoke-AdbText 'devices') -split "`n" | Select-Object -Skip 1 |
             Where-Object { $_ -match "`tdevice$" } | ForEach-Object { ($_ -split "`t")[0] })
    if ($now -notcontains $script:Serial) { Fail "device $script:Serial disappeared during the operation" }
}

function Assert-Preflight {
    Assert-DevicePresent
    $m = Get-Prop 'ro.product.model'
    if ($m -ne $Model) { Fail "unsupported model '$m' (expected $Model)" 11 }
    $f = Get-Prop 'ro.build.fingerprint'
    if ($f -ne $Fingerprint) { Fail "unsupported firmware '$f'" 11 }
    $script:ModelSeen = $m
    $script:FpSeen = $f
    $t = Invoke-Adb '-s' $script:Serial 'shell' "test -r $Hal"
    if ($t.Code -ne 0) { Fail "HAL apk not readable at $Hal" 11 }
}

function Get-BundledApk {
    foreach ($base in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent))) {
        $apk = Join-Path $base 'nvptool.apk'
        $receipt = Join-Path $base 'SOURCE-COMMIT.txt'
        if (-not (Test-Path -LiteralPath $apk) -or -not (Test-Path -LiteralPath $receipt)) { continue }
        $matches = @((Get-Content -LiteralPath $receipt) | Where-Object { $_ -match '^apk_sha256=[0-9a-f]{64}$' })
        if ($matches.Count -ne 1) { Fail 'bundle has no unique APK hash receipt' }
        $expected = $matches[0].Substring(11)
        $actual = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { Fail 'bundled APK does not match SOURCE-COMMIT.txt; obtain a verified package' }
        return [pscustomobject]@{ Path = $apk; Hash = $expected }
    }
    $root = Split-Path $PSScriptRoot -Parent
    $apk = Join-Path $root 'out/nvptool.apk'
    $receipt = Join-Path $root 'out/build-receipt.json'
    if ((Test-Path -LiteralPath $apk) -and (Test-Path -LiteralPath $receipt)) {
        $r = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
        $expected = [string]$r.apk.sha256
        if ($expected -notmatch '^[0-9a-f]{64}$') { Fail 'source build receipt has no APK hash' }
        $actual = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { Fail 'source APK does not match build receipt' }
        return [pscustomobject]@{ Path = $apk; Hash = $expected }
    }
    Fail 'nvptool.apk and SOURCE-COMMIT.txt are required next to this tool'
}

function Get-InstalledApkPath {
    $r = Invoke-Adb '-s' $script:Serial 'shell' "pm path $Pkg"
    if ($r.Code -ne 0) { Fail 'could not query installed helper APK path' }
    $paths = @($r.Output | Where-Object { $_ -match '^package:(/.*/base\.apk)\s*$' } |
        ForEach-Object { ($_ -replace '^package:', '').Trim() })
    if ($paths.Count -eq 0) { return '' }
    if ($paths.Count -ne 1 -or $paths[0] -notmatch '^/data/app/[A-Za-z0-9_./~+=-]+/base\.apk$') {
        Fail 'installed helper APK path is ambiguous or unsafe'
    }
    return $paths[0]
}

function Assert-AppVersion {
    $apkPath = Get-InstalledApkPath
    if (-not $apkPath) { Fail 'helper app is not installed; use menu option 7 or nvptool.ps1 install before this operation' }
    $dumpResult = Invoke-Adb '-s' $script:Serial 'shell' "dumpsys package $Pkg"
    if ($dumpResult.Code -ne 0) { Fail 'could not query installed helper version' }
    $dump = $dumpResult.Output -join "`n"
    $ver = ''
    foreach ($line in ($dump -split "`n")) {
        if ($line -match 'versionName=(\S+)') { $ver = $Matches[1]; break }
    }
    if ($ver -ne $ToolVersion) { Fail "installed app version '$ver' does not match tool version $ToolVersion; use menu option 7 or nvptool.ps1 install" }
    $bundle = Get-BundledApk
    $pulled = Join-Path $script:RunDir 'installed-base.apk'
    $pull = Invoke-Adb '-s' $script:Serial 'pull' $apkPath $pulled
    if ($pull.Code -ne 0 -or -not (Test-Path -LiteralPath $pulled)) {
        Fail 'could not read installed helper APK; refusing privileged spawn'
    }
    $got = (Get-FileHash -LiteralPath $pulled -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $bundle.Hash) { Fail 'installed helper APK bytes differ from the verified bundled APK; use menu option 7 or nvptool.ps1 install' }
    $script:InstalledApkPath = $apkPath
}


# ----------------------------------------------------------------- settings
# Captured once per command. Re-capturing per phase would launder a phase's
# failed cleanup into the next phase's "original" and report a false success.
function Read-SettingsState {
    $list = Invoke-Adb '-s' $script:Serial 'shell' 'settings list global'
    if ($list.Code -ne 0) { Fail 'settings list failed; refusing mutation' }
    if (@($list.Output | Where-Object { $_ -match '^hidden_api_blacklist_exemptions=' }).Count -gt 0) {
        Fail 'hidden_api_blacklist_exemptions already exists; refusing to overwrite an untransportable original value' 12
    }
    $get = Invoke-Adb '-s' $script:Serial 'shell' 'settings get global hidden_api_blacklist_exemptions'
    if ($get.Code -ne 0) { Fail 'settings get failed; refusing mutation' }
    if ($get.Output.Count -ne 1 -or $get.Output[0] -ne 'null') {
        Fail 'settings state is ambiguous; refusing mutation'
    }
    return 'absent'
}

function Capture-Settings {
    if ($script:SettingsCaptured) { return }
    $script:SettingsState = Read-SettingsState
    $dir = Get-BackupDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script:RecoveryRecord = Join-Path $dir "recovery-$($script:OperationId).txt"
    $record = "serial=$($script:Serial)`nrun=$($script:OperationId)`noriginal=absent`nremote_lock=$($script:RemoteLock)`ncreated=$((Get-Date).ToUniversalTime().ToString('o'))`n"
    [System.IO.File]::WriteAllText($script:RecoveryRecord, $record, (New-Object System.Text.UTF8Encoding($false)))
    $script:SettingsCaptured = $true
    $script:SettingsTouched = $false
}

function Restore-Settings {
    if (-not $script:SettingsTouched) { return $true }
    $deleted = Invoke-Adb '-s' $script:Serial 'shell' 'settings delete global hidden_api_blacklist_exemptions'
    if ($deleted.Code -ne 0) { return $false }
    try { $after = Read-SettingsState } catch { return $false }
    if ($after -ne 'absent') { return $false }
    $script:SettingsTouched = $false
    return $true
}


# ---------------------------------------------------------------- temp / hash
function New-RunDir {
    $script:RunDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nvptool-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
}

function Remove-RunDir {
    if ($script:RunDir -and (Test-Path $script:RunDir)) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:RunDir
    }
}

function Get-Sha256Hex([string]$Text) {
    # Matches `printf %s "$text" | sha256sum`: UTF-8 bytes, no BOM, lowercase hex.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-CanonicalDigest {
    param([string[]]$HexValues, [bool]$TrailingNewline)
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $HexValues.Count; $i++) {
        if ($i -lt $HexValues.Count - 1 -or $TrailingNewline) {
            [void]$sb.Append("$i=$($HexValues[$i])`n")
        } else {
            [void]$sb.Append("$i=$($HexValues[$i])")
        }
    }
    return (Get-Sha256Hex $sb.ToString())
}

# --------------------------------------------------------------- privileged
function New-Payload {
    param([string]$Class, [string]$RunId, [string[]]$Extra)
    $apkPath = $script:InstalledApkPath
    if (-not $apkPath) { Fail 'installed helper was not verified' }

    $extraText = ''
    if ($Extra -and $Extra.Count -gt 0) { $extraText = ' ' + ($Extra -join ' ') }
    $cmd = 'CLASSPATH=' + $apkPath + ':' + $Hal + ' /system/bin/app_process /system/bin ' +
           $Class + ' ' + $RunId + $extraText + ' #'

    $zygote = @(
        '--setuid=1000', '--setgid=1000', '--setgroups=3003', '--runtime-args',
        '--seinfo=platform:targetSdkVersion=29:complete', '--runtime-flags=1',
        '--nice-name=nvptool', '--invoke-with', $cmd
    )
    $payload = "LClass1;->method1(`n" + $zygote.Count + "`n" + ($zygote -join "`n")
    $file = Join-Path $script:RunDir 'payload.txt'
    [System.IO.File]::WriteAllText($file, $payload, (New-Object System.Text.UTF8Encoding($false)))
    return $file
}

function Invoke-NvpClass {
    param([string]$Class, [string]$Op, [string]$RunId, [string[]]$Extra = @())

    Assert-AppVersion
    $file = New-Payload -Class $Class -RunId $RunId -Extra $Extra
    Capture-Settings
    if ((Read-SettingsState) -ne 'absent') { Fail 'settings changed before phase' }
    # Claim area: created by the shell user, so the payload needs no directory
    # write permission of its own. Without it the payload refuses to touch the
    # HAL, because one request could otherwise execute more than once.
    $claimDir = '/data/local/tmp/nvptool-claims'
    $mk = Invoke-Adb '-s' $script:Serial 'shell' "mkdir -p $claimDir && chmod 0777 $claimDir"
    if ($mk.Code -ne 0) { Fail 'could not prepare the claim directory (settings untouched)' }
    $lk = Invoke-Adb '-s' $script:Serial 'shell' "touch $claimDir/lock-$RunId && chmod 0666 $claimDir/lock-$RunId"
    if ($lk.Code -ne 0) { Fail 'could not prepare the claim lock file (settings untouched)' }
    # The run id is generated internally and contains only digits and hyphens.
    $remote = "/data/local/tmp/nvptool-$RunId-$Op.txt"
    $script:RemotePayloads += $remote
    $script:CleanupAttempted = $false
    try {
        $push = Invoke-Adb '-s' $script:Serial 'push' $file $remote
        if ($push.Code -ne 0) { Fail 'could not push payload (settings untouched)' }
        $script:SettingsTouched = $true
        $set = Invoke-Adb '-s' $script:Serial 'shell' `
            "settings put global hidden_api_blacklist_exemptions `"`$(cat $remote)`""
        if ($set.Code -ne 0) { Fail 'could not install payload' }

        $stopped = Invoke-Adb '-s' $script:Serial 'shell' 'am force-stop com.android.settings'
        if ($stopped.Code -ne 0) { Fail 'could not restart settings after payload' 4 }
        $started = Invoke-Adb '-s' $script:Serial 'shell' 'am start -a android.settings.SETTINGS'
        if ($started.Code -ne 0) { Fail 'could not launch settings after payload' 4 }

        # Disarm immediately. The exemption applies to EVERY zygote fork while it
        # is present, so the arming window must cover one fork, not the whole poll
        # loop: ActivityManager retries the start, and each retry is another
        # execution of the payload.
        $script:CleanupAttempted = $true
        try { $script:CleanupOk = (Restore-Settings) -and $script:CleanupOk }
        catch { $script:CleanupOk = $false }
        $removedEarly = Invoke-Adb '-s' $script:Serial 'shell' "rm -f $remote"
        if ($removedEarly.Code -eq 0) { $script:RemotePayloads = @($script:RemotePayloads | Where-Object { $_ -ne $remote }) }
        else { $script:CleanupOk = $false }
        [void](Invoke-Adb '-s' $script:Serial 'shell' "rm -f $claimDir/claim-$RunId-* $claimDir/lock-$RunId")

        $lines = @()
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            $raw = Invoke-Adb '-s' $script:Serial 'shell' 'logcat -d -s NVPTOOL:V'
            if ($raw.Code -ne 0) { Fail 'logcat failed: operation outcome unknown' 4 }
            $lines = @($raw.Output | Where-Object { $_ -match [regex]::Escape("run=$RunId ") })
            if ($lines | Where-Object { $_ -match 'ev=summary' }) { break }
        }
        # Settle window, then one final read: the snapshot must cover the whole
        # window, so a later execution cannot fall outside it.
        if ($script:SettleSecs -gt 0) { Start-Sleep -Seconds $script:SettleSecs }
        $raw = Invoke-Adb '-s' $script:Serial 'shell' 'logcat -d -s NVPTOOL:V'
        if ($raw.Code -ne 0) { Fail 'logcat failed: operation outcome unknown' 4 }
        $lines = @($raw.Output | Where-Object { $_ -match [regex]::Escape("run=$RunId ") })
        $resultFile = Join-Path $script:RunDir "result-$RunId.txt"
        $lines | Set-Content -Path $resultFile -Encoding UTF8
        return [pscustomobject]@{
            Found = [bool]($lines | Where-Object { $_ -match 'ev=summary' })
            File = $resultFile
        }
    } finally {
        # The setting is restored before the payload is removed. On failure the
        # lock and recovery record remain, preventing a second unsafe run.
        # It was already disarmed above; a second attempt would hammer a failing
        # operation and defeat the "attempted once" invariant.
        if (-not $script:CleanupAttempted) {
            $script:CleanupAttempted = $true
            try { $script:CleanupOk = (Restore-Settings) -and $script:CleanupOk }
            catch { $script:CleanupOk = $false }
        }
        try {
            $removed = Invoke-Adb '-s' $script:Serial 'shell' "rm -f $remote"
            if ($removed.Code -ne 0) { $script:CleanupOk = $false }
        } catch { $script:CleanupOk = $false }
    }
}

# ------------------------------------------------------------------ parsing
function Get-Token([string]$Line, [string]$Name) {
    foreach ($t in ($Line -split ' ')) {
        if ($t.StartsWith("$Name=")) { return $t.Substring($Name.Length + 1) }
    }
    return ''
}

function Assert-Result {
    param([string]$Op, [string]$RunId, [string]$File)

    if (-not (Test-Path $File)) { Fail 'no completion record: outcome UNKNOWN (not "unchanged")' 4 }
    $lines = @(Get-Content -LiteralPath $File -Encoding UTF8 | Where-Object { "$_".Trim().Length -gt 0 })
    if ($lines.Count -eq 0) { Fail 'no completion record: outcome UNKNOWN (not "unchanged")' 4 }

    $begins = @($lines | Where-Object { $_ -match 'ev=begin' })
    $sums   = @($lines | Where-Object { $_ -match 'ev=summary' })
    if ($begins.Count -ne 1) { Fail "malformed result (begin x$($begins.Count)): outcome UNKNOWN" 4 }
    if ($sums.Count -ne 1)   { Fail "malformed result (summary x$($sums.Count)): outcome UNKNOWN" 4 }

    $bi = [array]::IndexOf($lines, $begins[0])
    $si = [array]::IndexOf($lines, $sums[0])
    if ($si -le $bi) { Fail 'malformed result (summary before begin): outcome UNKNOWN' 4 }

    $s = $sums[0]
    if ($s.IndexOf("run=$RunId ", [StringComparison]::Ordinal) -lt 0) {
        Fail 'stale result (run id mismatch): outcome UNKNOWN' 4
    }
    if ($s.IndexOf("op=$Op", [StringComparison]::Ordinal) -lt 0) {
        Fail 'stale result (operation mismatch): outcome UNKNOWN' 4
    }

    # Reply association: the summary must come from the same execution as the
    # begin. Two executions produce two begins (rejected above); a mismatch here
    # means records from different processes were mixed into one snapshot.
    $bpid = Get-Token $begins[0] 'pid'
    $spid = Get-Token $s 'pid'
    if (-not $bpid) { Fail 'malformed result (begin without pid): outcome UNKNOWN' 4 }
    if (-not $spid) { Fail 'malformed result (summary without pid): outcome UNKNOWN' 4 }
    if ($bpid -ne $spid) {
        Fail "result records from two processes (pid $bpid vs $spid): outcome UNKNOWN" 4
    }

    $status = Get-Token $s 'status'
    if (@('OK', 'ABORT', 'REFUSED', 'INCOMPLETE', 'FATAL') -notcontains $status) {
        Fail "malformed result (status '$status'): outcome UNKNOWN" 4
    }

    # At least one single-execution guard must be recorded: an exclusive claim or
    # a verified disarm of the exemption. Without either, a second fork could
    # have executed as well.
    # A successful run must record a single-execution guard. A REFUSED run is let
    # through so the payload can report why it declined; it is never success.
    if ($status -eq 'OK' -and
        -not ($lines | Where-Object { $_ -match 'msg=(claim_acquired|disarm_ok)' })) {
        Fail 'no single-execution guard recorded' 4
    }
    $dup = @($lines | Where-Object { $_ -match 'msg=duplicate_skipped' }).Count
    if ($dup -gt 0) { Write-Host "note: $dup duplicate execution(s) were claimed out and did no work" }

    $fields = @($lines | Where-Object { $_ -match 'ev=field' })
    if ($Op -eq 'read') {
        if ($fields.Count -ne 8) { Fail "incomplete read (fields=$($fields.Count)): outcome UNKNOWN" 4 }
        for ($i = 0; $i -lt 8; $i++) {
            if (-not ($fields | Where-Object { (Get-Token $_ 'idx') -eq "$i" })) {
                Fail "incomplete read (missing field $i): outcome UNKNOWN" 4
            }
        }
    }

    return [pscustomobject]@{
        Status   = $status
        Written  = Get-Token $s 'written'
        Verified = Get-Token $s 'verified'
        Total    = Get-Token $s 'total'
        Reason   = Get-Token $s 'reason'
        Fields   = $fields
    }
}

function Get-ResultHex {
    param($Fields)
    $hex = @()
    for ($i = 0; $i -lt 8; $i++) {
        $line = $Fields | Where-Object { (Get-Token $_ 'idx') -eq "$i" } | Select-Object -First 1
        $hex += (Get-Token $line 'val')
    }
    return $hex
}

# ------------------------------------------------------------------- backup
function Get-BackupRoot {
    if ($env:NVPTOOL_BACKUP_DIR) { return $env:NVPTOOL_BACKUP_DIR }
    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nvptool\backups')
}

function Get-BackupDir {
    $safe = ($script:Serial -replace '[^A-Za-z0-9._-]', '_')
    return (Join-Path (Get-BackupRoot) $safe)
}

function Get-AsciiPaddedHex([string]$Text, [int]$Len) {
    $bytes = New-Object byte[] $Len
    $n = [Math]::Min($Text.Length, $Len)
    for ($i = 0; $i -lt $n; $i++) { $bytes[$i] = [byte][char]$Text[$i] }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-ProfileHex([string]$Mode) {
    if ($Mode -eq 'target') {
        return @(
            (Get-AsciiPaddedHex 'kVolTblIcx1298HpSeGainHigh' 256),
            (Get-AsciiPaddedHex 'kVolTblIcx1298HpSeGainLow' 256),
            (Get-AsciiPaddedHex 'kVolTblIcx1298HpBtlGainHigh' 256),
            (Get-AsciiPaddedHex 'kVolTblIcx1298HpBtlGainLow' 256),
            '01000000', '01000000', '01000000', '00000000'
        )
    }
    return @(
        (Get-AsciiPaddedHex 'kVolTblIcx1298CewHpSe' 256),
        (Get-AsciiPaddedHex 'kVolTblIcx1298CewHpSe' 256),
        (Get-AsciiPaddedHex 'kVolTblIcx1298CewHpBtl' 256),
        (Get-AsciiPaddedHex 'kVolTblIcx1298CewHpBtl' 256),
        '00000000', '00000000', '00000000', '01000000'
    )
}

function Get-ConfigurationKind([string[]]$Hex) {
    if (($Hex -join ',') -eq ((Get-ProfileHex 'reference') -join ',')) { return 'baseline' }
    if (($Hex -join ',') -eq ((Get-ProfileHex 'target') -join ','))    { return 'snapshot' }
    return 'foreign'
}



function Save-Backup([string]$Kind) {
    $hex = $script:CurrentHex
    $digest = Get-CanonicalDigest -HexValues $hex -TrailingNewline $false
    $dir = Get-BackupDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $name = "$ts-$Kind-$($script:RunId).conf"
    $path = Join-Path $dir $name
    if (Test-Path $path) { Fail "backup file already exists: $path" }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($kv in @(
        @('schema', $Schema), @('tool', $ToolVersion), @('kind', $Kind),
        @('serial', $script:Serial), @('model', $script:ModelSeen),
        @('fingerprint', $script:FpSeen), @('created', $ts),
        @('run', $script:RunId), @('digest', $digest))) {
        [void]$sb.Append("$($kv[0])=$($kv[1])`n")
    }
    for ($i = 0; $i -lt 8; $i++) {
        [void]$sb.Append("field.$i.key=$($Keys[$i])`n")
        [void]$sb.Append("field.$i.len=$($Lens[$i])`n")
        [void]$sb.Append("field.$i.hex=$($hex[$i])`n")
    }
    $text = $sb.ToString()
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $utf8)
    [System.IO.File]::WriteAllText("$path.sha256", "$(Get-Sha256Hex $text)  $name`n", $utf8)

    if ($Kind -eq 'baseline') {
        $base = Join-Path $dir 'baseline.conf'
        if (-not (Test-Path $base)) {
            [System.IO.File]::WriteAllText($base, $text, $utf8)
            [System.IO.File]::WriteAllText("$base.sha256", "$(Get-Sha256Hex $text)  baseline.conf`n", $utf8)
        }
    }
    return $path
}

function Load-Backup([string]$File) {
    if (-not (Test-Path $File)) { Fail "backup not found: $File" 20 }
    if (-not (Test-Path "$File.sha256")) { Fail "backup has no integrity file: $File.sha256" 20 }

    $text = [System.IO.File]::ReadAllText($File)
    $want = ((Get-Content -LiteralPath "$File.sha256" -Raw) -split '\s+')[0]
    if ($want -ne (Get-Sha256Hex $text)) { Fail 'backup integrity check failed (corrupt or edited)' 20 }

    $map = @{}
    foreach ($line in ($text -split "`n")) {
        $l = $line.TrimEnd("`r")
        if ($l -match '^([^=]+)=(.*)$') { $map[$Matches[1].Trim()] = $Matches[2] }
    }

    if ($map['schema'] -ne $Schema) { Fail "backup schema '$($map['schema'])' is not supported" 20 }
    if ($map['serial'] -ne $script:Serial) { Fail "backup belongs to device $($map['serial']), not $($script:Serial)" 20 }
    if ($map['model'] -ne $script:ModelSeen) { Fail 'backup model does not match device' 20 }
    if ($map['fingerprint'] -ne $script:FpSeen) { Fail 'backup firmware does not match device' 20 }

    $hex = @()
    for ($i = 0; $i -lt 8; $i++) {
        if ($map["field.$i.key"] -ne $Keys[$i]) { Fail "backup field $i has an unexpected key" 20 }
        if ($map["field.$i.len"] -ne "$($Lens[$i])") { Fail "backup field $i has an unexpected length" 20 }
        $h = $map["field.$i.hex"]
        if (-not $h -or $h.Length -ne ($Lens[$i] * 2) -or $h -notmatch '^[0-9a-f]+$') {
            Fail "backup field $i is not valid hex" 20
        }
        $hex += $h
    }

    $recomputed = Get-CanonicalDigest -HexValues $hex -TrailingNewline $false
    if ($recomputed -ne $map['digest']) { Fail 'backup digest does not match its contents' 20 }
    return [pscustomobject]@{ Hex = $hex; Kind = $map['kind'] }
}

function Get-LatestBaseline {
    $dir = Get-BackupDir
    $base = Join-Path $dir 'baseline.conf'
    if (Test-Path $base) { return $base }
    $f = Get-ChildItem -Path $dir -Filter '*-baseline-*.conf' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }
    return $null
}

function Assert-WriteEnabled {
    # One privileged request can execute more than once on device (see
    # docs/ZYGOTE-SINGLE-EXECUTION.md). For a read that is waste; for a write it
    # is an unbounded number of NVRAM operations. Writes stay closed until the
    # single-shot design is validated on hardware.
    if ($env:NVPTOOL_ALLOW_UNVALIDATED_WRITE -eq '1') { return }
    [Console]::Error.WriteLine(
        "nvptool: NVRAM writes are disabled in this build.`n`n" +
        "Reason: one privileged request can run more than once on the device `n" +
        "(duplicate execution through the Zygote exemption), which is not safe `n" +
        "for writes. Reads - 'status' and 'read' - remain available.`n`n" +
        "This is a deliberate safety hold. Lifting it requires the design in `n" +
        "docs/ZYGOTE-SINGLE-EXECUTION.md to be validated on an Android 11 `n" +
        "NW-WM1AM2. Deliberate bypass, at your own risk:`n" +
        "  NVPTOOL_ALLOW_UNVALIDATED_WRITE=1")
    exit 13
}

function Assert-Cleanup([string]$Op) {
    if ($script:CleanupOk) { return }
    Fail (
        "$Op finished, but hidden_api_blacklist_exemptions could NOT be restored.`n" +
        "This is recovery-required, not a clean success.`n" +
        "  Check:    adb shell settings get global hidden_api_blacklist_exemptions`n" +
        "  Original: $($script:SettingsState)") 7
}

# ----------------------------------------------------------------- commands
function New-RunId { return "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$PID-$(Get-Random -Maximum 32767)" }

function Acquire-Lock {
    $safe = $script:Serial -replace '[^A-Za-z0-9._-]', '_'
    $lock = Join-Path ([System.IO.Path]::GetTempPath()) "nvptool.lock.$safe"
    try {
        $script:LocalLock = New-Object System.IO.FileStream($lock,
            [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
    } catch { Fail "another local nvptool run owns $lock; inspect before clearing a stale lock" }
    $script:LocalLockPath = $lock
    $remote = Invoke-Adb '-s' $script:Serial 'shell' "mkdir $($script:RemoteLock)"
    if ($remote.Code -ne 0) { Fail "device lock $($script:RemoteLock) is held; inspect it before manual recovery" }
    $script:RemoteLockHeld = $true
    $owner = Invoke-Adb '-s' $script:Serial 'shell' "printf '%s' '$($script:OperationId)' > $($script:RemoteLock)/owner"
    if ($owner.Code -ne 0) { Fail 'could not write remote lock owner record' }
}

function Release-Lock {
    if ($script:RemoteLockHeld -and $script:CleanupOk -and -not $script:SettingsTouched) {
        try {
            $owner = Invoke-Adb '-s' $script:Serial 'shell' "cat $($script:RemoteLock)/owner"
            if ($owner.Code -ne 0 -or ($owner.Output -join '') -ne $script:OperationId) { $script:CleanupOk = $false }
            else {
                $remove = Invoke-Adb '-s' $script:Serial 'shell' "rm -f $($script:RemoteLock)/owner && rmdir $($script:RemoteLock)"
                if ($remove.Code -ne 0) { $script:CleanupOk = $false }
                else { $script:RemoteLockHeld = $false }
            }
        } catch { $script:CleanupOk = $false }
    }
    if ($script:LocalLock) {
        try {
            $script:LocalLock.Dispose()
            Remove-Item -LiteralPath $script:LocalLockPath -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $script:LocalLockPath) {
                throw 'lock file still exists after removal'
            }
        } catch {
            $script:LocalLockError = $_.Exception.Message
            $script:CleanupOk = $false
        } finally {
            $script:LocalLock = $null
        }
    }
}

function Initialize-Operation {
    New-RunDir
    Select-Device
    Assert-Preflight
    $script:OperationId = New-RunId
    Acquire-Lock
    Assert-AppVersion
}

function Invoke-InstallHelperCmd {
    New-RunDir
    Select-Device
    Assert-Preflight
    $script:OperationId = New-RunId
    Acquire-Lock
    $bundle = Get-BundledApk
    Write-Output 'Installing the verified bundled helper APK. Android will accept an upgrade only with the same signing certificate.'
    Write-Output 'No installed helper will be uninstalled.'
    $r = Invoke-Adb '-s' $script:Serial 'install' '-r' $bundle.Path
    if ($r.Code -ne 0) { Fail "helper installation failed: $($r.Output -join ' ')" }
    Assert-AppVersion
    Write-Output 'helper installed and its device APK bytes verified.'
}

function Invoke-StatusCmd {
    New-RunDir
    Select-Device
    Assert-DevicePresent
    $m = Get-Prop 'ro.product.model'
    $d = Get-Prop 'vendor.destination'
    $s = Get-Prop 'vendor.safe_volume.enabled'
    $label = if ($s -eq '00000000') { 'limit off' } else { 'factory/limited' }
    Write-Output "device      : $m"
    Write-Output "destination : $d"
    Write-Output "safe_volume : $s ($label)"
    Write-Output "adb serial  : $($script:Serial)"
    Write-Output ''
    Write-Output 'Read-only check: no app installed, no privilege used, no setting changed, no NVRAM written.'
}

function Invoke-ReadCmd {
    Initialize-Operation
    $script:RunId = New-RunId
    $r = Invoke-NvpClass 'org.maniac79.nvptool.Read' 'read' $script:RunId
    if (-not $r.Found) { Fail 'no completion record: outcome UNKNOWN (not "unchanged")' 4 }
    $res = Assert-Result 'read' $script:RunId $r.File
    if ($res.Status -ne 'OK') { Fail "read $($res.Status) ($($res.Reason))" 3 }

    $script:CurrentHex = Get-ResultHex $res.Fields
    $kind = Get-ConfigurationKind $script:CurrentHex
    $path = Save-Backup $kind
    [void](Load-Backup $path)
    Assert-Cleanup 'read'
    Write-Output "read OK ($kind configuration)"
    Write-Output "backup: $path"
}

function Invoke-ApplyCmd {
    Assert-WriteEnabled
    Initialize-Operation

    # 1. back up first; nothing is written until a verified backup exists
    $script:RunId = New-RunId
    $r = Invoke-NvpClass 'org.maniac79.nvptool.Read' 'read' $script:RunId
    if (-not $r.Found) { Fail 'backup read produced no record; NOTHING WRITTEN' 4 }
    $res = Assert-Result 'read' $script:RunId $r.File
    if ($res.Status -ne 'OK') { Fail "backup read $($res.Status); NOTHING WRITTEN" 3 }

    $script:CurrentHex = Get-ResultHex $res.Fields
    $kind = Get-ConfigurationKind $script:CurrentHex
    $path = Save-Backup $kind
    [void](Load-Backup $path)

    # Fail closed: if the privileged read phase could not put the temporary
    # setting back, the device is not clean. Do not start a second privileged
    # run, and do not write NVRAM on top of an unclean state.
    if (-not $script:CleanupOk) {
        Fail ("apply aborted after the backup-read phase: the temporary setting " +
              "hidden_api_blacklist_exemptions could NOT be restored.`n`n" +
              "The NVRAM write phase was NOT started, so this run wrote nothing.`n" +
              "A valid backup was taken first:`n" +
              "  backup: $path`n`n" +
              "This is a recovery-required state, not a clean result:`n" +
              "  Check:    adb shell settings get global hidden_api_blacklist_exemptions`n" +
              "  Expected: null (stock) or your original value`n" +
              "  Original: $($script:SettingsState)`n`n" +
              "Fix that setting before running apply again.") 7
    }

    # 2. write, bound to the digest of the backup just taken (Java-compatible:
    #    Profile.digest keeps a trailing newline after the eighth field)
    $digest = Get-CanonicalDigest -HexValues $script:CurrentHex -TrailingNewline $true

    $script:RunId = New-RunId
    $r2 = Invoke-NvpClass 'org.maniac79.nvptool.Apply' 'apply' $script:RunId @($digest)
    if (-not $r2.Found) {
        Fail "no completion record: outcome UNKNOWN. Do not assume nothing changed.`nRecovery: read + restore from`n  $path" 4
    }
    $res2 = Assert-Result 'apply' $script:RunId $r2.File
    if ($res2.Status -ne 'OK') {
        Fail "apply $($res2.Status) (reason $($res2.Reason), verified $($res2.Verified)/$($res2.Total))`nRecovery: restore from`n  $path" 5
    }

    Assert-Cleanup 'apply'
    Write-Output "apply OK - $($res2.Verified)/$($res2.Total) verified (wrote $($res2.Written))"
    Write-Output "backup: $path"
    Write-Output 'Reboot for the change to take effect.'
}


function Invoke-RestoreCmd {
    Assert-WriteEnabled
    $file = ''
    if ($Rest -and $Rest.Count -gt 0) { $file = $Rest[0] }
    Initialize-Operation

    if (-not $file) {
        $file = Get-LatestBaseline
        if (-not $file) {
            Fail ("no original (baseline) backup found for this device.`n" +
                  "A backup of an already-modified state is not a factory backup. Options:`n" +
                  "  - restore the built-in reference profile: nvptool.ps1 restore-reference`n" +
                  "  - or pass an explicit file plus NVPTOOL_ALLOW_NON_BASELINE_RESTORE=1") 20
        }
    }

    $bk = Load-Backup $file
    if ($bk.Kind -ne 'baseline') {
        Write-Output "WARNING: this backup is kind=$($bk.Kind), not a factory baseline."
        Write-Output '         Restoring it returns the device to an ALREADY MODIFIED state.'
        if ($env:NVPTOOL_ALLOW_NON_BASELINE_RESTORE -ne '1') {
            Fail ("refusing to restore a non-baseline backup without explicit consent.`n" +
                  'Re-run with NVPTOOL_ALLOW_NON_BASELINE_RESTORE=1 if that is really what you want.') 21
        }
    }
    Write-Output "restoring from: $file (kind=$($bk.Kind))"

    for ($i = 0; $i -lt 8; $i++) {
        $script:RunId = New-RunId
        $r = Invoke-NvpClass 'org.maniac79.nvptool.RestoreField' 'restore' $script:RunId @("$i", $bk.Hex[$i])
        if (-not $r.Found) { Fail "field ${i}: no completion record, outcome UNKNOWN. Re-run read." 4 }
        $res = Assert-Result 'restore' $script:RunId $r.File
        if ($res.Status -ne 'OK') {
            Fail "field ${i}: $($res.Status) ($($res.Reason)); fields 0..$($i - 1) were restored" 5
        }
        Write-Output "  field $i : $($res.Reason)"

        # Fail closed between fields: a field that leaves the temporary setting
        # behind makes the device unclean, so no further field may be written.
        if (-not $script:CleanupOk) {
            Fail ("restore stopped after field ${i}: the NVRAM field was restored and verified, " +
                  "but the temporary setting hidden_api_blacklist_exemptions could NOT be put back.`n`n" +
                  "  Restored: fields 0..${i} (verified)`n" +
                  "  NOT written: $(7 - $i) field(s)`n`n" +
                  "No further field was written. This is a recovery-required state, not a clean result:`n" +
                  "  Check:    adb shell settings get global hidden_api_blacklist_exemptions`n" +
                  "  Expected: null (stock) or your original value`n" +
                  "  Original: $($script:SettingsState)`n`n" +
                  "Fix that setting before running restore again (it is safe to re-run: already " +
                  "restored fields are rewritten with the same values).") 7
        }
    }

    Assert-Cleanup 'restore'
    Write-Output "restore OK ($($bk.Kind)) - reboot to reload the table for these values."
}

function Invoke-RestoreReferenceCmd {
    Assert-WriteEnabled
    Initialize-Operation
    $script:RunId = New-RunId
    $r = Invoke-NvpClass 'org.maniac79.nvptool.RestoreReference' 'restore_reference' `
        $script:RunId @('CONFIRM_REFERENCE_PROFILE')
    if (-not $r.Found) { Fail 'no completion record, outcome UNKNOWN' 4 }
    $res = Assert-Result 'restore_reference' $script:RunId $r.File
    if ($res.Status -ne 'OK') { Fail "reference restore $($res.Status) ($($res.Reason))" 5 }
    Assert-Cleanup 'restore_reference'
    Write-Output "reference profile restored ($($res.Verified)/$($res.Total) verified). Reboot."
}

function Invoke-RebootCmd {
    New-RunDir
    Select-Device
    Assert-DevicePresent
    $r = Invoke-Adb '-s' $script:Serial 'reboot'
    if ($r.Code -ne 0) { Fail 'reboot command failed' 6 }
    Write-Output "reboot requested for $($script:Serial)."
}

# ----------------------------------------------------------------- dispatch
$script:FinalCode = 0
try {
    switch ($Command.ToLowerInvariant()) {
        'status'            { Invoke-StatusCmd }
        'read'              { Invoke-ReadCmd }
        'apply'             { Invoke-ApplyCmd }
        'restore'           { Invoke-RestoreCmd }
        'restore-reference' { Invoke-RestoreReferenceCmd }
        'install'           { Invoke-InstallHelperCmd }
        'reboot'            { Invoke-RebootCmd }
        default {
            Fail "unknown command: $Command (try: status install read apply restore restore-reference reboot)" 64
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($_.Exception.Data.Contains('ExitCode')) {
        $script:FinalCode = [int]$_.Exception.Data['ExitCode']
    } else {
        $script:FinalCode = 4
    }
} finally {
    if ($script:SettingsTouched -and -not $script:CleanupAttempted) {
        try { $script:CleanupOk = (Restore-Settings) -and $script:CleanupOk }
        catch { $script:CleanupOk = $false }
    }
    try { Release-Lock } catch { $script:CleanupOk = $false }
    if ($script:CleanupOk -and -not $script:RemoteLockHeld -and $script:RecoveryRecord) {
        Remove-Item -LiteralPath $script:RecoveryRecord -Force -ErrorAction SilentlyContinue
    }
    if (-not $script:CleanupOk -or $script:RemoteLockHeld) {
        $remoteStatus = if ($script:RemoteLockHeld) { "held at $($script:RemoteLock)" } else { 'released' }
        if ($script:LocalLockError) {
            [Console]::Error.WriteLine("nvptool: host lock cleanup failed at $($script:LocalLockPath): $($script:LocalLockError)")
        }
        [Console]::Error.WriteLine("nvptool: cleanup incomplete; recovery-required. Original setting: $($script:SettingsState). Remote lock: $remoteStatus. Recovery record: $($script:RecoveryRecord).")
        $script:FinalCode = 7
    }
    Remove-RunDir
}
exit $script:FinalCode

