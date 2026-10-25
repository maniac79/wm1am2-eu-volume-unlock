# Compatibility entry point. The historical arbitrary-class runner bypassed the
# orchestrator's APK identity, device lock, backup and setting recovery checks.
# Keep only the named read operation and route it through nvptool.ps1.
param(
    [Parameter(Mandatory = $true)][string]$ClassName,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$Package = 'org.maniac79.nvptool',
    [string]$Serial = '',
    [int]$RunUid = 1000,
    [string]$Seinfo = 'platform:targetSdkVersion=29:complete',
    [string]$Hal = '/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk',
    [int]$WaitSeconds = 20
)
if ($ClassName -ne 'org.maniac79.nvptool.Read' -or
    $Package -ne 'org.maniac79.nvptool' -or $RunUid -ne 1000 -or
    $Seinfo -ne 'platform:targetSdkVersion=29:complete' -or
    $Hal -ne '/system_ext/priv-app/IzmAudioManager/IzmAudioManager.apk' -or
    $WaitSeconds -ne 20 -or $RunId -notmatch '^[A-Za-z0-9_-]+$') {
    [Console]::Error.WriteLine('refusing standalone class invocation; use nvptool.ps1 read, apply or restore')
    exit 3
}
if ($Serial) { $env:NVPTOOL_SERIAL = $Serial }
$hostExe = (Get-Process -Id $PID).Path
& $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'nvptool.ps1') 'read'
exit $LASTEXITCODE
