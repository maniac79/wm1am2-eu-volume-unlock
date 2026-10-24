# Interactive helper for the NW-WM1AM2 volume-cap tool. Windows / PowerShell.
# Called by START-windows.bat. Needs only adb.

$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
Set-Location $Here

$Pkg = 'org.maniac79.nvptool'
$Apk = 'nvptool.apk'
$script:Adb = $null

function Write-Hr { Write-Host ('-' * 60) }

function Pause-Menu {
    Write-Host ''
    Write-Host 'Press Enter to continue...' -NoNewline
    [void](Read-Host)
}

function Find-Adb {
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $Here 'platform-tools\adb.exe'),
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk\platform-tools\adb.exe'),
        'C:\platform-tools\adb.exe'
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Show-AdbMissing {
    Write-Hr
    Write-Host '  adb was not found on this computer.'
    Write-Hr
    @'
  You do not need the full Android SDK - only "Platform Tools".

  1. Download "SDK Platform-Tools" for Windows:
       https://developer.android.com/tools/releases/platform-tools
  2. Unzip it; you get a folder named "platform-tools".
  3. Then do ONE of these:
       a) Move that folder next to this script, so this file exists:
            platform-tools\adb.exe
       b) Or add it to your PATH and reopen this window.
  4. Prepare the player:
       - Settings > About device > tap "Build number" seven times
       - Settings > System > Developer options > enable "USB debugging"
       - Connect the USB cable, then accept "Allow USB debugging?" on the
         player (tick "Always allow from this computer").
  5. Start START-windows.bat again.

  Nothing has been changed on your player.
'@ | Write-Host
    Write-Hr
    Pause-Menu
}

function Test-Device {
    $state = (& adb get-state 2>$null | Out-String).Trim()
    return ($state -eq 'device')
}

function Show-NoDevice {
    Write-Hr
    Write-Host '  adb is installed, but no authorised player was found.'
    Write-Hr
    @'
  Check these, in order:
    - Is the Walkman connected with a data-capable USB cable?
    - Is "USB debugging" enabled in Developer options?
    - Did you accept the "Allow USB debugging?" prompt on the player?
      (If it never appears, unplug and replug the cable.)
'@ | Write-Host
    Write-Host ''
    Write-Host '  adb devices says:'
    (& adb devices 2>&1) | ForEach-Object { Write-Host "    $_" }
    Write-Host ''
    Pause-Menu
}

function Install-Apk {
    $found = (& adb shell "pm path $Pkg" 2>$null | Out-String)
    if ($found -match 'package:') { return $true }

    Write-Host ''
    Write-Host '  The helper app is not installed on the player yet.'
    $a = Read-Host "  Install it now from $Apk? [Y/n]"
    if ($a -match '^[nN]') { return $false }
    if (-not (Test-Path (Join-Path $Here $Apk))) {
        Write-Host "  $Apk is missing from this folder."
        Pause-Menu
        return $false
    }
    Write-Host '  installing...'
    & adb install -r (Join-Path $Here $Apk) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  Install failed.'
        Pause-Menu
        return $false
    }
    Write-Host '  installed.'
    return $true
}

function Invoke-Class {
    param([string]$ClassName, [string]$Label)

    Write-Hr
    Write-Host "  $Label"
    Write-Hr

    $out = & (Join-Path $Here 'inject.ps1') $ClassName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
        Write-Host $out
        Write-Host ''
        Write-Host '  No usable output came back. This step is known to be flaky;'
        Write-Host '  simply run it again.'
        Pause-Menu
        return $false
    }
    $out.TrimEnd() -split "`n" | ForEach-Object { Write-Host "  $_" }
    return $true
}

function Confirm-Yes {
    param([string]$Question)
    $a = Read-Host "$Question [yes/NO]"
    return ($a -eq 'yes' -or $a -eq 'YES' -or $a -eq 'Yes')
}

function Invoke-Reboot {
    Write-Host '  Rebooting the player...'
    & adb reboot *> $null
    Write-Host '  Done. Wait for it to start up again.'
    Pause-Menu
}

function Show-Menu {
    Write-Hr
    Write-Host '  Sony NW-WM1AM2 - EU volume cap tool'
    Write-Hr
    Write-Host '  1) Check status            (read-only, changes nothing)'
    Write-Host '  2) Enable the fix          (writes NVRAM, then reboot)'
    Write-Host '  3) Restore factory setting (undo everything)'
    Write-Host '  4) Reboot the player'
    Write-Host '  5) Where is adb? / requirements'
    Write-Host '  0) Exit'
    Write-Host ''
}

# --------------------------------------------------------------------------
$script:Adb = Find-Adb
if ($script:Adb) {
    $adbDir = Split-Path $script:Adb -Parent
    $env:PATH = "$adbDir;$env:PATH"
}

while ($true) {
    Show-Menu
    $choice = Read-Host '  Choice'

    if ($choice -eq '0' -or $choice -eq 'q' -or $choice -eq 'Q' -or [string]::IsNullOrWhiteSpace($choice)) {
        exit 0
    }

    if ($choice -eq '5') { Show-AdbMissing; continue }

    if (-not $script:Adb) { Show-AdbMissing; continue }
    if (-not (Test-Device)) { Show-NoDevice; continue }

    switch ($choice) {
        '1' {
            if (-not (Install-Apk)) { continue }
            Invoke-Class -ClassName 'org.maniac79.nvptool.Read' -Label 'Reading current values' | Out-Null
            Write-Host ''
            Write-Host '  Look for:  ro.safe_volume.enabled = 00000000   (fix active)'
            Write-Host '             ro.safe_volume.enabled = 01000000   (factory / capped)'
            Pause-Menu
        }
        '2' {
            if (-not (Install-Apk)) { continue }
            Write-Hr
            Write-Host "  This writes eight calibration fields into the player's NVRAM"
            Write-Host '  and needs a reboot afterwards. Option 3 undoes it.'
            Write-Hr
            if (-not (Confirm-Yes 'Continue?')) { continue }
            if (Invoke-Class -ClassName 'org.maniac79.nvptool.Apply' -Label 'Applying configuration') {
                if (Confirm-Yes 'Reboot now so the change takes effect?') {
                    Invoke-Reboot
                }
                else {
                    Write-Host '  Remember to reboot before judging the result.'
                    Pause-Menu
                }
            }
        }
        '3' {
            if (-not (Install-Apk)) { continue }
            Write-Hr
            Write-Host '  This restores the values recorded from the tested unit.'
            Write-Hr
            if (-not (Confirm-Yes 'Restore factory settings?')) { continue }
            if (Invoke-Class -ClassName 'org.maniac79.nvptool.Rollback' -Label 'Restoring factory values') {
                if (Confirm-Yes 'Reboot now?') { Invoke-Reboot } else { Pause-Menu }
            }
        }
        '4' { Invoke-Reboot }
        default {
            Write-Host '  Unknown choice.'
            Start-Sleep -Seconds 1
        }
    }
}

