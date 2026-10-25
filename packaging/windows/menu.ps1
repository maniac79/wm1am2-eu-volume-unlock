# Windows menu - deliberately limited to non-mutating actions.
#
# The full orchestration (verified backup before writing, write-ahead journal,
# per-field restore) is implemented and host-tested only in the bash tool
# (nvptool.sh). Until the PowerShell equivalent is validated, this menu offers
# status / full read / reboot and refuses to write anything.

$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
Set-Location $Here

$Pkg = 'org.maniac79.nvptool'
$Apk = 'nvptool.apk'
$ExpectedVersion = '1.1.0'
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
    foreach ($c in @(
        (Join-Path $Here 'platform-tools\adb.exe'),
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'),
        'C:\platform-tools\adb.exe')) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Show-Requirements {
    Write-Hr
    Write-Host '  Requirements'
    Write-Hr
    @'
  You do not need the full Android SDK - only "Platform Tools":
    https://developer.android.com/tools/releases/platform-tools
  Unzip it and either put the folder next to this menu (platform-tools\adb.exe)
  or add it to PATH.

  On the player:
    Settings > About device > tap "Build number" 7x
    Developer options > enable "USB debugging"
    Connect USB, accept "Allow USB debugging?", tick "Always allow".

  Supported configuration: NW-WM1AM2, Android 11, firmware 1.09.00.
'@ | Write-Host
    Write-Hr
    Pause-Menu
}

function Test-Device {
    $state = (& adb get-state 2>$null | Out-String).Trim()
    return ($state -eq 'device')
}

function Show-Status {
    Write-Hr
    Write-Host '  Status (read-only)'
    Write-Hr
    $model = (& adb shell getprop ro.product.model 2>$null | Out-String).Trim()
    $dest = (& adb shell getprop vendor.destination 2>$null | Out-String).Trim()
    $safe = (& adb shell getprop vendor.safe_volume.enabled 2>$null | Out-String).Trim()
    Write-Host "  device      : $model"
    Write-Host "  destination : $dest"
    Write-Host "  safe_volume : $safe"
    Write-Host ''
    Write-Host '  No app installed, no privilege used, no setting changed, no NVRAM written.'
}

# --------------------------------------------------------------------------
$script:Adb = Find-Adb
if ($script:Adb) {
    $adbDir = Split-Path $script:Adb -Parent
    $env:PATH = "$adbDir;$env:PATH"
}

if (-not $script:Adb) { Show-Requirements }

while ($true) {
    Write-Hr
    Write-Host '  Sony NW-WM1AM2 - EU volume cap tool  (experimental)'
    Write-Hr
    Write-Host '  1) Status          read-only, changes nothing'
    Write-Host '  2) Full NVP read   privileged read only (no writes)'
    Write-Host '  3) Reboot the player'
    Write-Host '  6) Requirements / where is adb'
    Write-Host '  0) Exit'
    Write-Host ''
    Write-Host '  NOTE: applying or restoring on Windows is not supported yet.'
    Write-Host '  Use the macOS or Linux package for that; it takes a verified'
    Write-Host '  backup before every write.'
    Write-Host ''
    $choice = Read-Host '  Choice'

    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { exit 0 }
    if ($choice -eq '6' -or -not $script:Adb) { Show-Requirements; continue }

    if (-not (Test-Device)) {
        Write-Hr
        Write-Host '  No authorised device found. Check USB debugging and the prompt.'
        Write-Hr
        Pause-Menu
        continue
    }

    switch ($choice) {
        '1' { Show-Status; Pause-Menu }
        '2' {
            Write-Hr
            Write-Host '  Full NVP read (privileged, read-only)'
            Write-Hr
            $run = "win-$(Get-Date -Format yyyyMMddHHmmss)"
            $out = & (Join-Path $Here 'inject.ps1') -ClassName 'org.maniac79.nvptool.Read' -RunId $run 2>&1 | Out-String
            Write-Host $out
            if ($LASTEXITCODE -ne 0) {
                Write-Host '  Read did not produce a complete result - see the message above.'
            }
            Write-Host ''
            Write-Host '  Applying is not available on Windows yet; use the macOS/Linux package.'
            Pause-Menu
        }
        '3' {
            & adb reboot *> $null
            Write-Host '  Reboot requested.'
            Pause-Menu
        }
        default { Write-Host '  Unknown or unsupported choice.'; Start-Sleep -Seconds 1 }
    }
}
