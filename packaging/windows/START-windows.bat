@echo off
REM Double-click launcher for Windows.
REM Opens PowerShell with the menu. Uses -ExecutionPolicy Bypass because the
REM script is not signed; it runs only from this folder.
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0menu.ps1"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo The menu exited with code %RC%.
    pause
)
endlocal
