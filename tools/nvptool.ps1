# nvptool.ps1 - native Windows host orchestrator (parity with nvptool.sh)
#
#   status | read | apply | restore [file] | restore-reference | reboot
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
$ToolVersion = '0.2.2'
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
$script:RunDir = ''

function Fail([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("nvptool: $Message")
    exit $Code
}

# ------------------------------------------------------------------ helpers
function Get-AdbCommand {
    # Test harness hook: point NVPTOOL_ADB at a simulator. Otherwise real adb.
    if ($env:NVPTOOL_ADB) { return $env:NVPTOOL_ADB }
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

function Assert-AppVersion {
    $path = Invoke-AdbText '-s' $script:Serial 'shell' "pm path $Pkg"
    if ($path -notmatch 'package:') { Fail 'helper app is not installed' }
    $dump = Invoke-AdbText '-s' $script:Serial 'shell' "dumpsys package $Pkg"
    $ver = ''
    foreach ($line in ($dump -split "`n")) {
        if ($line -match 'versionName=(\S+)') { $ver = $Matches[1]; break }
    }
    if ($ver -ne $ToolVersion) { Fail "installed app version '$ver' does not match tool version $ToolVersion" }
}


# ----------------------------------------------------------------- settings
# Captured once per command. Re-capturing per phase would launder a phase's
# failed cleanup into the next phase's "original" and report a false success.
function Read-SettingsState {
    $v = Invoke-AdbText '-s' $script:Serial 'shell' 'settings get global hidden_api_blacklist_exemptions'
    if ($v -eq 'null') { return 'absent' }
    if ($v -eq '') { return 'empty' }
    return "value:$v"
}

function Capture-Settings {
    if ($script:SettingsCaptured) { return }
    $script:SettingsState = Read-SettingsState
    $script:SettingsCaptured = $true
    $script:SettingsTouched = $false
}

function Restore-Settings {
    if (-not $script:SettingsTouched) { return $true }
    switch -Wildcard ($script:SettingsState) {
        'absent' {
            [void](Invoke-Adb '-s' $script:Serial 'shell' 'settings delete global hidden_api_blacklist_exemptions')
        }
        'empty' {
            [void](Invoke-Adb '-s' $script:Serial 'shell' 'settings put global hidden_api_blacklist_exemptions ""')
        }
        'value:*' {
            $orig = $script:SettingsState.Substring(6)
            [void](Invoke-Adb '-s' $script:Serial 'shell' "settings put global hidden_api_blacklist_exemptions `"$orig`"")
        }
    }
    $after = Read-SettingsState
    return ($after -eq $script:SettingsState)
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
$script:RemotePayload = '/data/local/tmp/nvptool_payload.txt'

function New-Payload {
    param([string]$Class, [string]$RunId, [string[]]$Extra)
    $apk = Invoke-AdbText '-s' $script:Serial 'shell' "pm path $Pkg"
    $apkPath = ''
    foreach ($line in ($apk -split "`n")) {
        if ($line -match '^package:(.+)$') { $apkPath = $Matches[1].Trim(); break }
    }
    if (-not $apkPath) { Fail 'helper app is not installed' }

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

    $file = New-Payload -Class $Class -RunId $RunId -Extra $Extra
    Capture-Settings

    $push = Invoke-Adb '-s' $script:Serial 'push' $file $script:RemotePayload
    if ($push.Code -ne 0) { Fail 'could not push payload (settings untouched)' }
    $script:SettingsTouched = $true

    $set = Invoke-Adb '-s' $script:Serial 'shell' `
        "settings put global hidden_api_blacklist_exemptions `"`$(cat $script:RemotePayload)`""
    if ($set.Code -ne 0) {
        [void](Restore-Settings)
        Fail 'could not install payload'
    }

    [void](Invoke-Adb '-s' $script:Serial 'shell' 'am force-stop com.android.settings')
    [void](Invoke-Adb '-s' $script:Serial 'shell' 'am start -a android.settings.SETTINGS')

    $lines = @()
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $raw = Invoke-Adb '-s' $script:Serial 'shell' 'logcat -d -s NVPTOOL:V'
        $lines = @($raw.Output | Where-Object { $_ -match [regex]::Escape("run=$RunId ") })
        if ($lines | Where-Object { $_ -match 'ev=summary' }) { break }
    }

    $resultFile = Join-Path $script:RunDir 'result.txt'
    $lines | Set-Content -Path $resultFile -Encoding UTF8

    [void](Invoke-Adb '-s' $script:Serial 'shell' "rm -f $script:RemotePayload")
    $script:CleanupOk = Restore-Settings

    return [pscustomobject]@{
        Found = [bool]($lines | Where-Object { $_ -match 'ev=summary' })
        File  = $resultFile
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

    $status = Get-Token $s 'status'
    if (@('OK', 'ABORT', 'REFUSED', 'INCOMPLETE', 'FATAL') -notcontains $status) {
        Fail "malformed result (status '$status'): outcome UNKNOWN" 4
    }

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

function Assert-Cleanup([string]$Op) {
    if ($script:CleanupOk) { return }
    [Console]::Error.WriteLine(
        "nvptool: $Op finished, but hidden_api_blacklist_exemptions could NOT be restored.`n" +
        "This is recovery-required, not a clean success.`n" +
        "  Check:    adb shell settings get global hidden_api_blacklist_exemptions`n" +
        "  Original: $($script:SettingsState)")
    exit 7
}

# ----------------------------------------------------------------- commands
function New-RunId { return "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$PID-$(Get-Random -Maximum 32767)" }

function Acquire-Lock {
    $lock = Join-Path ([System.IO.Path]::GetTempPath()) "nvptool.lock.$($script:Serial)"
    if (Test-Path $lock) {
        $pidFile = Join-Path $lock 'pid'
        $other = ''
        if (Test-Path $pidFile) { $other = (Get-Content -LiteralPath $pidFile -Raw).Trim() }
        $alive = $false
        if ($other -match '^\d+$') {
            $alive = [bool](Get-Process -Id ([int]$other) -ErrorAction SilentlyContinue)
        }
        if ($alive) { Fail "another nvptool run is active for this device (pid $other)" }
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $lock
    }
    New-Item -ItemType Directory -Force -Path $lock | Out-Null
    Set-Content -LiteralPath (Join-Path $lock 'pid') -Value $PID -NoNewline
    $script:LockDir = $lock
}

function Release-Lock {
    if ($script:LockDir -and (Test-Path $script:LockDir)) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $script:LockDir
    }
    $script:LockDir = ''
}

function Initialize-Operation {
    New-RunDir
    Select-Device
    Acquire-Lock
    Assert-Preflight
    Assert-AppVersion
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
try {
    switch ($Command.ToLowerInvariant()) {
        'status'            { Invoke-StatusCmd }
        'read'              { Invoke-ReadCmd }
        'apply'             { Invoke-ApplyCmd }
        'restore'           { Invoke-RestoreCmd }
        'restore-reference' { Invoke-RestoreReferenceCmd }
        'reboot'            { Invoke-RebootCmd }
        default {
            Fail "unknown command: $Command (try: status read apply restore restore-reference reboot)" 64
        }
    }
} finally {
    Release-Lock
    Remove-RunDir
}
exit 0

