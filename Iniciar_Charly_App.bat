@echo off
chcp 65001 >nul
cd /d "%~dp0"

python -c "import PySide6, docx" >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ========================================================================
    echo  Instalando dependencias necesarias de Python (PySide6, python-docx)...
    echo  Esto ocurre una sola vez. Por favor, aguarde unos segundos.
    echo ========================================================================
    echo.
    python -m pip install --upgrade pip --quiet
    python -m pip install PySide6 python-docx
    if %ERRORLEVEL% NEQ 0 (
        echo.
        echo ========================================================================
        echo  AVISO: No se encontro Python 3.10+ o fallo la instalacion automatica.
        echo  Instale Python desde https://www.python.org/downloads/
        echo  marcando "Add python.exe to PATH" y ejecute Instalar_Charly_App.bat
        echo ========================================================================
        echo.
        pause
        exit /b 1
    )
)

pythonw -c "import PySide6, docx" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    start "" pythonw "%~dp0Charly_App.py"
) else (
    start "" python "%~dp0Charly_App.py"
)
exit /b 0

