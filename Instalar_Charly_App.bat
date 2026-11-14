@echo off
chcp 65001 >nul
title Instalador de Charly App v4.0
echo ========================================================================
echo          INSTALADOR DE CHARLY APP v4.0
echo ========================================================================
echo.
cd /d "%~dp0"

echo [1/3] Verificando dependencias de Python (PySide6, python-docx)...
python -m pip install --upgrade pip --quiet
python -m pip install PySide6 python-docx --quiet
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [AVISO] Se requiere Python 3.10 o superior agregado al PATH del sistema.
    echo Descarga e instalacion: https://www.python.org/downloads/
    echo Al instalar, recordar tildar la casilla: "Add Python to PATH".
    echo.
    pause
    exit /b 1
)

echo [2/3] Creando acceso directo "Charly App" en el Escritorio...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ws = New-Object -ComObject WScript.Shell; $desk = [Environment]::GetFolderPath('Desktop'); $dir = (Get-Location).Path; $q = [char]34; $lnk = $ws.CreateShortcut((Join-Path $desk 'Charly App.lnk')); $pyw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source; if (-not $pyw) { $pyw = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }; if ($pyw) { $lnk.TargetPath = $pyw; $lnk.Arguments = $q + (Join-Path $dir 'Charly_App.py') + $q; $lnk.WorkingDirectory = $dir; $ico = Join-Path $dir 'peperina.ico'; if (Test-Path $ico) { $lnk.IconLocation = $ico }; $lnk.Save() }"

echo [3/3] Instalacion finalizada correctamente. Iniciando Charly App...
pythonw -c "import PySide6, docx" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    start "" pythonw "%~dp0Charly_App.py"
) else (
    start "" python "%~dp0Charly_App.py"
)
exit /b 0
