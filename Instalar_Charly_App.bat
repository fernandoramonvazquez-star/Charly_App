@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar_Charly_App.ps1"
if errorlevel 1 goto :fail
exit /b 0

:fail
echo.
echo Presione una tecla para salir...
pause >nul
exit /b 1
