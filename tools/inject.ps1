<#
.SYNOPSIS
    Start one of the nvptool classes in a platform_app context.

.DESCRIPTION
    Windows / PowerShell 5.1+. Needs only `adb` (no Python, no JDK).
    See tools/inject.py for the full explanation of why this step exists.

.EXAMPLE
    .\tools\inject.ps1 org.maniac79.nvptool.Read

.EXAMPLE
    .\tools\inject.ps1 org.maniac79.nvptool.Apply

.EXAMPLE
    .\tools\inject.ps1 org.maniac79.nvptool.Rollback
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$ClassName,
    [string]$Package = 'org.maniac79.nvptool',
    [int]$RunUid = 1000,
    [string]$Seinfo = 'platform:targetSdkVersion=29:complete',
    [string]$Hal = '/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk',
    [int]$WaitSeconds = 8
)

$ErrorActionPreference = 'Stop'
$Tag = 'NVPTOOL'
$Remote = '/data/local/tmp/nvptool_payload.txt'

# $env:TEMP does not exist on macOS/Linux PowerShell, so fall back properly.
$tempDir = if ($env:TEMP) { $env:TEMP }
           elseif ($env:TMPDIR) { $env:TMPDIR }
           else { [System.IO.Path]::GetTempPath() }
$Local = Join-Path $tempDir 'nvptool_payload.txt'

function Stop-Cleanup {
    & adb shell 'settings delete global hidden_api_blacklist_exemptions' *> $null
    & adb shell "rm -f $Remote" *> $null
    Remove-Item -Force -ErrorAction SilentlyContinue $Local
}

# ---- preflight -------------------------------------------------------------
$state = (& adb get-state 2>$null | Out-String).Trim()
if ($state -ne 'device') {
    Write-Error "adb device not ready (state='$state')"
    exit 1
}
$model = (& adb shell 'getprop ro.product.model' | Out-String).Trim()
Write-Host "device model: $model"

$rawApk = & adb shell "pm path $Package" 2>$null
$apkPath = @(
    ($rawApk -split "`n") |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -like 'package:*' } |
        ForEach-Object { $_.Substring(8) }
) | Select-Object -First 1

if (-not $apkPath) {
    Write-Error "package $Package is not installed - run: adb install -r out\nvptool.apk"
    exit 1
}

& adb shell "test -r $Hal" *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "cannot read HAL apk at $Hal"
    exit 1
}

# ---- build the zygote payload ---------------------------------------------
$cmdLine = 'CLASSPATH=' + $apkPath + ':' + $Hal + ' /system/bin/app_process /system/bin ' + $ClassName + ' #'

$zygoteArgs = @(
    "--setuid=$RunUid",
    "--setgid=$RunUid",
    '--setgroups=3003',
    '--runtime-args',
    "--seinfo=$Seinfo",
    '--runtime-flags=1',
    '--nice-name=nvptool',
    '--invoke-with',
    $cmdLine
)

# LF only, UTF-8 without BOM - the device shell must see plain line breaks.
$payload = "LClass1;->method1(`n" + $zygoteArgs.Count + "`n" + ($zygoteArgs -join "`n")
[System.IO.File]::WriteAllText($Local, $payload, (New-Object System.Text.UTF8Encoding($false)))

try {
    & adb push $Local $Remote *> $null
    & adb shell 'logcat -c' *> $null
    & adb shell 'am force-stop com.android.settings' *> $null
    & adb shell "settings put global hidden_api_blacklist_exemptions `"`$(cat $Remote)`"" *> $null
    Start-Sleep -Seconds 1
    & adb shell 'am start -a android.settings.SETTINGS' *> $null
    Start-Sleep -Seconds $WaitSeconds

    $out = & adb shell 'logcat -b all -d' 2>$null | Select-String -SimpleMatch $Tag

    if ($out) {
        $out | ForEach-Object { $_.Line }
    }
    else {
        Write-Host "(no $Tag output - the spawn is flaky, just run the command again)"
        $code = 2
    }
}
finally {
    Stop-Cleanup
}

if ($code -eq 2) { exit 2 }
exit 0
