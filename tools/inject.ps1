# inject.ps1 - start one nvptool class in a platform_app context (Windows).
#
# Strict by design:
#   - binds to exactly one authorised device (or -Serial);
#   - does not clear logcat;
#   - preserves the previous hidden_api_blacklist_exemptions value;
#   - exits non-zero unless a complete summary record for this run id is seen.
#
# It is a runner only. Backup/journal orchestration lives in the bash tool.
param(
    [Parameter(Mandatory = $true)][string]$ClassName,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$Package = 'org.maniac79.nvptool',
    [string]$Serial = '',
    [int]$RunUid = 1000,
    [string]$Seinfo = 'platform:targetSdkVersion=29:complete',
    [string]$Hal = '/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk',
    [int]$WaitSeconds = 20,
    # Write-capable classes are refused by default. This runner has no backup
    # orchestration, so allowing a write from here would bypass "backup first".
    [switch]$AllowUnsafeWrite
)

$ErrorActionPreference = 'Stop'

$writeClasses = @(
    'org.maniac79.nvptool.Apply',
    'org.maniac79.nvptool.RestoreField',
    'org.maniac79.nvptool.RestoreReference'
)
if (($writeClasses -contains $ClassName) -and (-not $AllowUnsafeWrite)) {
    Write-Error ("refusing to run write-capable class '$ClassName': this runner takes no " +
                 'backup. Use the macOS/Linux tool (nvptool.sh) for writes.')
    exit 3
}
$Tag = 'NVPTOOL'
$Remote = '/data/local/tmp/nvptool_payload.txt'

$tempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR }
           else { [System.IO.Path]::GetTempPath() }
$Local = Join-Path $tempDir ("nvptool_payload_{0}.txt" -f $RunId)

# ---- device selection ------------------------------------------------------
$state = (& adb get-state 2>$null | Out-String).Trim()
if ($state -ne 'device') { Write-Error "adb device not ready (state='$state')"; exit 1 }

if ([string]::IsNullOrEmpty($Serial)) {
    $list = @(& adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "`tdevice$" } |
              ForEach-Object { ($_ -split "`t")[0] } | Where-Object { $_ })
    if ($list.Count -eq 0) { Write-Error 'no authorised adb device'; exit 1 }
    if ($list.Count -gt 1) { Write-Error "more than one adb device attached ($($list -join ', ')); pass -Serial"; exit 1 }
    $Serial = $list[0]
}
function A { & adb -s $Serial @args }

$model = (& adb -s $Serial shell getprop ro.product.model | Out-String).Trim()
Write-Host "device: $model ($Serial)"

$rawApk = & adb -s $Serial shell "pm path $Package" 2>$null
$apkPath = @(($rawApk -split "`n") | ForEach-Object { $_.Trim() } |
             Where-Object { $_ -like 'package:*' } | ForEach-Object { $_.Substring(8) }) |
           Select-Object -First 1
if (-not $apkPath) { Write-Error "package $Package not installed"; exit 1 }

# ---- payload ---------------------------------------------------------------
$cmdLine = 'CLASSPATH=' + $apkPath + ':' + $Hal + ' /system/bin/app_process /system/bin ' + $ClassName + ' ' + $RunId + ' #'
$zygoteArgs = @(
    "--setuid=$RunUid", "--setgid=$RunUid", '--setgroups=3003', '--runtime-args',
    "--seinfo=$Seinfo", '--runtime-flags=1', '--nice-name=nvptool', '--invoke-with', $cmdLine
)
$payload = "LClass1;->method1(`n" + $zygoteArgs.Count + "`n" + ($zygoteArgs -join "`n")
[System.IO.File]::WriteAllText($Local, $payload, (New-Object System.Text.UTF8Encoding($false)))

# ---- previous setting state ------------------------------------------------
$before = (& adb -s $Serial shell 'settings get global hidden_api_blacklist_exemptions' | Out-String).Trim()
$touched = $false

try {
    & adb -s $Serial push $Local $Remote *> $null
    $touched = $true
    & adb -s $Serial shell "settings put global hidden_api_blacklist_exemptions `"`$(cat $Remote)`"" *> $null
    & adb -s $Serial shell 'am force-stop com.android.settings' *> $null
    & adb -s $Serial shell 'am start -a android.settings.SETTINGS' *> $null

    $lines = @()
    for ($i = 0; $i -lt $WaitSeconds; $i++) {
        Start-Sleep -Seconds 1
        $lines = @(& adb -s $Serial shell "logcat -d -s $Tag`:V" 2>$null | Where-Object { $_ -match [regex]::Escape("run=$RunId ") })
        if ($lines | Where-Object { $_ -match 'ev=summary' }) { break }
    }
    $lines | ForEach-Object { Write-Host $_ }

    $summaries = @($lines | Where-Object { $_ -match 'ev=summary' })
    if ($summaries.Count -ne 1) { Write-Error "no single summary record (got $($summaries.Count)) - outcome unknown"; exit 4 }
    if ($summaries[0] -notmatch 'status=OK') { Write-Error 'operation did not report OK'; exit 5 }
    exit 0
}
finally {
    & adb -s $Serial shell "rm -f $Remote" *> $null
    if ($touched) {
        if ($before -eq 'null') {
            & adb -s $Serial shell 'settings delete global hidden_api_blacklist_exemptions' *> $null
        } else {
            & adb -s $Serial shell "settings put global hidden_api_blacklist_exemptions `"$before`"" *> $null
        }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $Local
}
