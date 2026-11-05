@echo off
setlocal
set "SCRIPT=%~dp0scripts\launch.ps1"
if not exist "%SCRIPT%" (
    echo Launcher script not found: "%SCRIPT%"
    pause
    exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
