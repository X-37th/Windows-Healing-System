@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "repoUrl=https://github.com/X-37th/Windows-Healing-System"
set "scriptPath=%~dp0WindowsHealingSystem.ps1"
set "logDir=%~dp0Logs"
set "logFile=%logDir%\WindowsHealingSystem-Run.log"
set "wtDefaultPath=%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe"
set "wtScoopPath=%USERPROFILE%\scoop\apps\windows-terminal\current\wt.exe"

if not exist "%logDir%" mkdir "%logDir%" >nul 2>&1

call :Banner
call :Log ============================================================
call :Log Windows Healing System launcher started at %DATE% %TIME%

if not exist "%scriptPath%" (
    call :Error "WindowsHealingSystem.ps1 was not found next to Run.bat."
    exit /b 1
)

set "wtPath="
if exist "%wtDefaultPath%" set "wtPath=%wtDefaultPath%"
if not defined wtPath if exist "%wtScoopPath%" set "wtPath=%wtScoopPath%"

if defined wtPath (
    call :Info "Opening Windows Healing System in Windows Terminal..."
    call :Log Using Windows Terminal: %wtPath%
    PowerShell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%wtPath%' -ArgumentList 'PowerShell -NoProfile -ExecutionPolicy Bypass -File ""%scriptPath%""' -Verb RunAs" >> "%logFile%" 2>&1
) else (
    call :Info "Windows Terminal was not found. Opening Windows PowerShell instead..."
    call :Log Windows Terminal not found; falling back to Windows PowerShell.
    PowerShell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'PowerShell' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%scriptPath%""' -Verb RunAs" >> "%logFile%" 2>&1
)

if errorlevel 1 (
    call :Error "Failed to start WindowsHealingSystem.ps1."
    exit /b 1
)

call :Success "Launch request sent. Approve the UAC prompt to continue."
echo.
echo Logs: %logFile%
echo Help: %repoUrl%/issues
echo.
exit /b 0

:Banner
echo.
echo ============================================================
echo  Windows Healing System
echo  Launcher: Run.bat
echo ============================================================
echo.
exit /b 0

:Info
echo [INFO] %~1
call :Log [INFO] %~1
exit /b 0

:Success
echo [ OK ] %~1
call :Log [ OK ] %~1
exit /b 0

:Error
echo [ERROR] %~1
echo See log: %logFile%
call :Log [ERROR] %~1
pause
exit /b 0

:Log
echo %*>> "%logFile%"
exit /b 0
