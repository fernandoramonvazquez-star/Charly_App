# Instalar_Charly_App.ps1 - Instalador integral y autónomo de Charly App v4.0
$Host.UI.RawUI.WindowTitle = "Instalador de Charly App v4.0"
$ErrorActionPreference = "Continue"

$appDir = $PSScriptRoot
if (-not $appDir) { $appDir = (Get-Location).Path }
Set-Location $appDir

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host "                 INSTALADOR DE CHARLY APP v4.0" -ForegroundColor Cyan
Write-Host "       Asistente computacional para psicometría reproducible en R" -ForegroundColor Gray
Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. LOCALIZACIÓN Y AUTO-INSTALACIÓN DE PYTHON
# ---------------------------------------------------------------------------
function Find-PythonExecutable {
    try {
        $testPath = & python -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $testPath -and -not ($testPath -like "*WindowsApps*")) {
            return $testPath.Trim()
        }
    } catch {}

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
    Write-Host " [AVISO] No se detectó una instalación funcional de Python 3.10+." -ForegroundColor Yellow
    Write-Host " Charly App requiere Python para su interfaz y lógica central." -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "¿Deseas descargar e instalar Python 3.12 automáticamente ahora? (S/n): " -NoNewline -ForegroundColor Cyan
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
            Write-Host "Instalación de Python finalizada." -ForegroundColor Green
        } catch {
            Write-Host "Fallo la descarga automática de Python: $_" -ForegroundColor Red
        }
        $pyExe = Find-PythonExecutable
    }
}

if (-not $pyExe) {
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host " ERROR: No se pudo localizar Python.exe." -ForegroundColor Red
    Write-Host " Por favor instala Python manualmente desde: https://www.python.org/downloads/" -ForegroundColor Yellow
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

# ---------------------------------------------------------------------------
# 2. LOCALIZACIÓN Y AUTO-INSTALACIÓN DE R (MOTOR ESTADÍSTICO)
# ---------------------------------------------------------------------------
function Find-RExecutable {
    try {
        $cmd = (Get-Command Rscript.exe -ErrorAction SilentlyContinue).Source
        if ($cmd -and (Test-Path $cmd)) { return $cmd }
    } catch {}

    $candidates = @(
        "C:\Program Files\R\R-*\bin\Rscript.exe",
        "C:\Program Files (x86)\R\R-*\bin\Rscript.exe",
        "$env:LOCALAPPDATA\Programs\R\R-*\bin\Rscript.exe",
        "C:\R\bin\Rscript.exe"
    )
    foreach ($pat in $candidates) {
        $found = Get-Item $pat -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($found -and (Test-Path $found.FullName)) {
            return $found.FullName
        }
    }

    $rReg = @("HKLM:\Software\R-Core\R", "HKCU:\Software\R-Core\R", "HKLM:\Software\R-Core\R64", "HKCU:\Software\R-Core\R64")
    foreach ($reg in $rReg) {
        if (Test-Path $reg) {
            $p = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).InstallPath
            if ($p) {
                $exe = Join-Path $p "bin\Rscript.exe"
                if (Test-Path $exe) { return $exe }
            }
        }
    }

    return $null
}

Write-Host "Verificando entorno de R..." -ForegroundColor Gray
$rExe = Find-RExecutable

if (-not $rExe) {
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Yellow
    Write-Host " [AVISO] No se detectó R instalado en tu computadora." -ForegroundColor Yellow
    Write-Host " Charly App utiliza R como motor estadístico para calcular los modelos." -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "¿Deseas descargar e instalar R automáticamente ahora desde CRAN? (S/n): " -NoNewline -ForegroundColor Cyan
    $rAns = Read-Host
    if ($rAns -eq "" -or $rAns -match "^[sSyY]") {
        Write-Host ""
        Write-Host "Localizando última versión oficial de R para Windows en CRAN..." -ForegroundColor Gray
        try {
            $cranUrl = "https://cloud.r-project.org/bin/windows/base/"
            $html = (Invoke-WebRequest -Uri $cranUrl -UseBasicParsing).Content
            $rFile = "R-4.6.2-win.exe"
            if ($html -match 'href="(R-[0-9\.]+-win\.exe)"') {
                $rFile = $matches[1]
            }
            $rDownloadUrl = "$cranUrl$rFile"
            Write-Host "Descargando $rFile (aprox. 80 MB)..." -ForegroundColor Gray
            $rInstaller = Join-Path $env:TEMP $rFile
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $rDownloadUrl -OutFile $rInstaller -UseBasicParsing
            
            Write-Host "Instalando R para Windows en segundo plano..." -ForegroundColor Gray
            $p = Start-Process -FilePath $rInstaller -ArgumentList "/SILENT", "/SUPPRESSMSGBOXES" -Wait -PassThru
            Remove-Item $rInstaller -Force -ErrorAction SilentlyContinue
            Write-Host "Instalación de R finalizada con éxito." -ForegroundColor Green
        } catch {
            Write-Host "No se pudo descargar automáticamente R: $_" -ForegroundColor Red
            Write-Host "Puedes descargarlo manualmente desde: https://cloud.r-project.org/bin/windows/base/" -ForegroundColor Yellow
        }
        $rExe = Find-RExecutable
    }
}

if ($rExe) {
    Write-Host "R detectado en: $rExe" -ForegroundColor Green
    $rDir = Split-Path $rExe -Parent
    $env:PATH = "$rDir;$env:PATH"
} else {
    Write-Host "AVISO: R no fue instalado en este paso. Podrás instalarlo más adelante desde cloud.r-project.org" -ForegroundColor Yellow
}

Write-Host ""

# ---------------------------------------------------------------------------
# 3. INSTALACIÓN DE DEPENDENCIAS DE PYTHON (PySide6, python-docx)
# ---------------------------------------------------------------------------
Write-Host "[1/3] Instalando librerías de Python (PySide6, python-docx)..." -ForegroundColor Yellow
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
    Write-Host " AVISO: Ocurrió un inconveniente al instalar las dependencias con pip." -ForegroundColor Red
    Write-Host " Comprueba tu conexión a internet e intenta nuevamente." -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host ""
    Read-Host "Presione Enter para salir"
    exit 1
}

# ---------------------------------------------------------------------------
# 4. INSTALACIÓN OPCIONAL DE PAQUETES DE R (lavaan, psych, semTools, etc.)
# ---------------------------------------------------------------------------
if ($rExe) {
    Write-Host ""
    Write-Host "¿Deseas instalar ahora los paquetes estadísticos de R (lavaan, psych, MASS, semTools)? (S/n): " -NoNewline -ForegroundColor Cyan
    $pkgAns = Read-Host
    if ($pkgAns -eq "" -or $pkgAns -match "^[sSyY]") {
        Write-Host "Instalando paquetes de R desde CRAN (esto puede demorar unos minutos)..." -ForegroundColor Yellow
        & $rExe -e "pkgs <- c('lavaan', 'psych', 'MASS', 'semTools', 'readxl', 'writexl', 'openxlsx', 'ggplot2', 'GPArotation'); to_install <- pkgs[!pkgs %in% installed.packages()[,'Package']]; if(length(to_install)>0) install.packages(to_install, repos='https://cloud.r-project.org')"
        Write-Host "Paquetes de R listos." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 5. CREACIÓN DE ACCESO DIRECTO EN EL ESCRITORIO
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 6. VERIFICACIÓN E INICIO
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/3] Verificando inicio de Charly App..." -ForegroundColor Yellow
$testLoad = & $pyExe -c "import PySide6, docx; print('OK')" 2>&1
if ($testLoad -notmatch "OK") {
    Write-Host "ERROR al validar las librerías:" -ForegroundColor Red
    Write-Host $testLoad -ForegroundColor Red
    Write-Host ""
    Read-Host "Presione Enter para salir"
    exit 1
}

Write-Host ""
Write-Host "========================================================================" -ForegroundColor Green
Write-Host "  ¡INSTALACIÓN FINALIZADA CON ÉXITO! Iniciando Charly App..." -ForegroundColor Green
Write-Host "========================================================================" -ForegroundColor Green
Write-Host ""

Start-Process -FilePath $pywExe -ArgumentList "`"$appDir\Charly_App.py`"" -WorkingDirectory $appDir
exit 0
