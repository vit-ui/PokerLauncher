@echo off
setlocal
set "SCRIPT=%~dp0scripts\setup.ps1"
if not exist "%SCRIPT%" (
    echo Setup script not found: "%SCRIPT%"
    pause
    exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
