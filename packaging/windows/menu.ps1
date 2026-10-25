# Windows menu. Thin wrapper: every action is delegated to nvptool.ps1 and
# judged only by its exit code, so a failure can never fall through to a
# "reboot now?" prompt. There is no second, less protected write path.
$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
Set-Location $Here
$NV = Join-Path $Here 'nvptool.ps1'

# Use the PowerShell host that is running this menu. The shipped launcher starts
# powershell.exe, so that path is unchanged, but a pwsh session (or a non-Windows
# CI host) is no longer silently redirected to a different interpreter.
function Get-HostExe {
    $p = (Get-Process -Id $PID).Path
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    $c = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return 'powershell'
}
$PSExe = Get-HostExe

function Write-Hr { Write-Host ('-' * 60) }
function Pause-Menu {
    Write-Host ''
    Write-Host 'Press Enter to continue...' -NoNewline
    [void](Read-Host)
}

function Show-Requirements {
    Write-Hr
    Write-Host '  Requirements'
    Write-Hr
    @'
  You do not need the full Android SDK - only "Platform Tools":
    https://developer.android.com/tools/releases/platform-tools
  Unzip it and put the folder next to this menu (platform-tools\adb.exe), or
  add it to PATH.

  On the player:
    Settings > About device > tap "Build number" 7x
    Developer options > enable "USB debugging"
    Connect USB, accept "Allow USB debugging?", tick "Always allow".

  Supported configuration only:
    NW-WM1AM2, Android 11, firmware 1.09.00
'@ | Write-Host
    Write-Hr
    Pause-Menu
}

function Confirm-Yes([string]$Question) {
    $a = Read-Host "$Question [yes/NO]"
    return ($a -eq 'yes' -or $a -eq 'YES' -or $a -eq 'Yes')
}

# Where doing it IS the documented procedure, the default is yes: only an
# explicit no/n declines. Rebooting is harmless; skipping it leaves the player's
# apps broken until the user remembers.
function Confirm-YesDefault([string]$Question) {
    $a = Read-Host "$Question [YES/no]"
    return -not ($a -eq 'no' -or $a -eq 'NO' -or $a -eq 'No' -or $a -eq 'n' -or $a -eq 'N')
}

function Invoke-RebootPrompt {
    if (Confirm-YesDefault 'Reboot now so the change takes effect?') {
        [void](Run-Action 'Rebooting' @('reboot'))
    } else {
        Write-Host "  Reboot before judging the result, and before using the player's apps."
        Write-Host '  The change is stored in NVRAM; it is not lost by waiting.'
    }
}

function Run-Action([string]$Label, [string[]]$NvArgs) {
    Write-Hr
    Write-Host "  $Label"
    Write-Hr
    # Out-Host, not a bare call: every call site discards the function's return
    # value with [void](...), which would also discard the orchestrator's stdout -
    # the user would see the header and nothing else.
    $output = @(& $PSExe -NoProfile -ExecutionPolicy Bypass -File $NV @NvArgs 2>&1)
    $rc = $LASTEXITCODE
    $output | Out-Host
    if ($rc -ne 0) {
        Write-Host ''
        Write-Host "  The operation did not complete successfully (exit code $rc)."
        Write-Host '  Do not assume the player is unchanged - read the message above.'
        Pause-Menu
        return $false
    }
    return $true
}

if (-not (Test-Path $NV)) {
    Write-Hr; Write-Host '  nvptool.ps1 is missing next to this menu.'; Write-Hr
    Pause-Menu; exit 1
}

while ($true) {
    Write-Hr
    Write-Host '  Sony NW-WM1AM2 - EU volume cap tool  (experimental)'
    Write-Hr
    Write-Host '  1) Status               read-only, no privilege, changes nothing'
    Write-Host '  2) Full NVP read        privileged read + verified backup'
    Write-Host '  3) Apply the change     back up first, then write'
    Write-Host '  4) Restore from backup  per-field restore, verified'
    Write-Host '  5) Reboot the player'
    Write-Host '  6) Requirements / where is adb'
    Write-Host '  7) Install/update bundled helper APK (no NVRAM write)'
    Write-Host '  0) Exit'
    Write-Host ''
    Write-Host "  Advanced:  type 'restore-ref' for the built-in reference profile,"
    Write-Host '             which is NOT a backup (needs explicit confirmation).'
    Write-Host ''
    $choice = Read-Host '  Choice'

    switch ($choice) {
        '1' { [void](Run-Action 'Status (read-only)' @('status')); Pause-Menu }
        '2' { [void](Run-Action 'Full NVRAM read' @('read')); Pause-Menu }
        '3' {
            Write-Hr
            Write-Host '  This writes eight NVRAM fields. A backup is taken first and'
            Write-Host '  the write is refused if the backup cannot be verified.'
            Write-Hr
            if (-not (Confirm-Yes 'Continue?')) { break }
            if (Run-Action 'Applying configuration' @('apply')) {
                Invoke-RebootPrompt
            }
            Pause-Menu
        }
        '4' {
            Write-Hr
            Write-Host '  Restores each field from the newest verified ORIGINAL backup'
            Write-Host '  for this device. Corrupt, foreign or modified-state backups'
            Write-Host '  are refused.'
            Write-Hr
            if (-not (Confirm-Yes 'Restore from backup?')) { break }
            if (Run-Action 'Restoring' @('restore')) {
                Invoke-RebootPrompt
            }
            Pause-Menu
        }
        '5' { [void](Run-Action 'Rebooting' @('reboot')); Pause-Menu }
        '6' { Show-Requirements }
        '7' {
            Write-Hr
            Write-Host '  Installs the verified bundled nvptool.apk on the player.'
            Write-Host '  Android accepts an upgrade only with the same signing certificate.'
            Write-Host '  This does not uninstall another app or write NVRAM.'
            Write-Hr
            if (Confirm-Yes 'Install/update helper APK?') {
                [void](Run-Action 'Installing helper APK' @('install'))
                Pause-Menu
            }
        }
        'restore-ref' {
            Write-Hr
            Write-Host '  ADVANCED: writes the reference profile recorded from one unit.'
            Write-Host "  This is NOT your device's backup."
            Write-Hr
            if (Confirm-Yes 'Really write the reference profile?') {
                if (Run-Action 'Restoring reference profile' @('restore-reference')) {
                    Invoke-RebootPrompt
                }
                Pause-Menu
            }
        }
        '0' { exit 0 }
        default { Write-Host '  Unknown choice.'; Start-Sleep -Seconds 1 }
    }
    if ([string]::IsNullOrWhiteSpace($choice)) { exit 0 }
}
