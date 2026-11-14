# Instalar_Charly_App.ps1 - Instalador robusto para PCs limpias
$Host.UI.RawUI.WindowTitle = "Instalador de Charly App v4.0"
$ErrorActionPreference = "Continue"

$appDir = $PSScriptRoot
if (-not $appDir) { $appDir = (Get-Location).Path }
Set-Location $appDir

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host "                 INSTALADOR DE CHARLY APP v4.0" -ForegroundColor Cyan
Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host ""

function Find-PythonExecutable {
    # 1. Probar 'python' en PATH actual si funciona de verdad (excluyendo el alias vacio de WindowsApps)
    try {
        $testPath = & python -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $testPath -and -not ($testPath -like "*WindowsApps*")) {
            return $testPath.Trim()
        }
    } catch {}

    # 2. Rutas conocidas estandar de Python en Windows
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "$env:ProgramFiles\Python313\python.exe",
        "$env:ProgramFiles\Python312\python.exe",
        "$env:ProgramFiles\Python311\python.exe",
        "$env:ProgramFiles\Python310\python.exe",
        "C:\Python313\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe",
        "C:\Python310\python.exe"
    )

    foreach ($c in $candidates) {
        if (Test-Path $c) {
            try {
                $test = & $c -c "import sys; print(sys.executable)" 2>$null
                if ($LASTEXITCODE -eq 0 -and $test) {
                    return $c
                }
            } catch {}
        }
    }

    # 3. Buscar en el registro de Windows
    $regRoots = @("HKCU:\Software\Python\PythonCore", "HKLM:\Software\Python\PythonCore")
    foreach ($r in $regRoots) {
        if (Test-Path $r) {
            Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
                $ip = Join-Path $_.PSPath "InstallPath"
                if (Test-Path $ip) {
                    $prop = (Get-ItemProperty $ip -ErrorAction SilentlyContinue)."(default)"
                    if ($prop) {
                        $exe = Join-Path $prop "python.exe"
                        if (Test-Path $exe) {
                            return $exe
                        }
                    }
                }
            }
        }
    }

    return $null
}

Write-Host "Verificando entorno de Python..." -ForegroundColor Gray
$pyExe = Find-PythonExecutable

if (-not $pyExe) {
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Yellow
    Write-Host " [AVISO] No se detecto una instalacion funcional de Python 3.10+." -ForegroundColor Yellow
    Write-Host " Charly App requiere Python para su funcionamiento." -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Deseas descargar e instalar Python 3.12 automaticamente ahora? (S/n): " -NoNewline -ForegroundColor Cyan
    $ans = Read-Host
    if ($ans -eq "" -or $ans -match "^[sSyY]") {
        Write-Host ""
        Write-Host "Descargando instalador oficial de Python 3.12..." -ForegroundColor Gray
        $pyUrl = "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe"
        $installer = Join-Path $env:TEMP "python-installer-charly.exe"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $pyUrl -OutFile $installer -UseBasicParsing
            Write-Host "Instalando Python en segundo plano (agregando al PATH)..." -ForegroundColor Gray
            $p = Start-Process -FilePath $installer -ArgumentList "/passive", "InstallAllUsers=0", "PrependPath=1", "Include_test=0" -Wait -PassThru
            Remove-Item $installer -Force -ErrorAction SilentlyContinue
            Write-Host "Instalacion de Python finalizada." -ForegroundColor Green
        } catch {
            Write-Host "Fallo la descarga automatica: $_" -ForegroundColor Red
        }
        $pyExe = Find-PythonExecutable
    }
}

if (-not $pyExe) {
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host " ERROR: No se pudo localizar Python.exe." -ForegroundColor Red
    Write-Host " Por favor instala Python manualmente desde:" -ForegroundColor Yellow
    Write-Host " https://www.python.org/downloads/" -ForegroundColor White
    Write-Host " IMPORTANTE: Marca la casilla 'Add python.exe to PATH' en el instalador." -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host ""
    Read-Host "Presione Enter para salir"
    exit 1
}

$pyDir = Split-Path $pyExe -Parent
$pyScripts = Join-Path $pyDir "Scripts"
$env:PATH = "$pyDir;$pyScripts;$env:PATH"

Write-Host "Python detectado en: $pyExe" -ForegroundColor Green
Write-Host ""

# [1/3] Instalar dependencias
Write-Host "[1/3] Instalando dependencias necesarias (PySide6, python-docx)..." -ForegroundColor Yellow
Write-Host "Descargando paquetes (aprox. 150 MB). Puede demorar 1-2 minutos." -ForegroundColor Gray
Write-Host "Por favor espera a que finalice..." -ForegroundColor Gray
Write-Host ""

& $pyExe -m pip install --upgrade pip
if (Test-Path "$appDir\requirements.txt") {
    & $pyExe -m pip install -r "$appDir\requirements.txt"
} else {
    & $pyExe -m pip install PySide6 python-docx
}

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host " AVISO: Ocurrio un inconveniente al instalar las dependencias con pip." -ForegroundColor Red
    Write-Host " Comprueba tu conexion a internet e intenta nuevamente." -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host ""
    Read-Host "Presione Enter para salir"
    exit 1
}

# [2/3] Crear acceso directo en Escritorio
Write-Host ""
Write-Host "[2/3] Creando acceso directo 'Charly App' en el Escritorio..." -ForegroundColor Yellow
try {
    $pywExe = Join-Path $pyDir "pythonw.exe"
    if (-not (Test-Path $pywExe)) { $pywExe = $pyExe }

    $ws = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath("Desktop")
    $lnk = $ws.CreateShortcut((Join-Path $desk "Charly App.lnk"))
    $lnk.TargetPath = $pywExe
    $lnk.Arguments = "`"$appDir\Charly_App.py`""
    $lnk.WorkingDirectory = $appDir
    $ico = Join-Path $appDir "peperina.ico"
    if (Test-Path $ico) { $lnk.IconLocation = $ico }
    $lnk.Save()
    Write-Host "Acceso directo creado correctamente." -ForegroundColor Green
} catch {
    Write-Host "No se pudo crear el acceso directo: $_" -ForegroundColor Yellow
}

# [3/3] Probar inicio
Write-Host ""
Write-Host "[3/3] Verificando inicio de Charly App..." -ForegroundColor Yellow
$testLoad = & $pyExe -c "import PySide6, docx; print('OK')" 2>&1
if ($testLoad -notmatch "OK") {
    Write-Host "ERROR al validar las librerias:" -ForegroundColor Red
    Write-Host $testLoad -ForegroundColor Red
    Write-Host ""
    Read-Host "Presione Enter para salir"
    exit 1
}

Write-Host ""
Write-Host "========================================================================" -ForegroundColor Green
Write-Host "  INSTALACION FINALIZADA CON EXITO! Iniciando Charly App..." -ForegroundColor Green
Write-Host "========================================================================" -ForegroundColor Green
Write-Host ""

Start-Process -FilePath $pywExe -ArgumentList "`"$appDir\Charly_App.py`"" -WorkingDirectory $appDir
exit 0
