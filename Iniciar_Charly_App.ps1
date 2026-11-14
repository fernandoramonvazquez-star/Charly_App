# Iniciar_Charly_App.ps1 - Lanzador inteligente con autodiagnóstico
$Host.UI.RawUI.WindowTitle = "Charly App v4.0"
$ErrorActionPreference = "Continue"

$appDir = $PSScriptRoot
if (-not $appDir) { $appDir = (Get-Location).Path }
Set-Location $appDir

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

$pyExe = Find-PythonExecutable

if (-not $pyExe) {
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host " No se encontro Python en el sistema." -ForegroundColor Red
    Write-Host " Ejecuta primero 'Instalar_Charly_App.bat' para configurar el entorno." -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host ""
    Read-Host "Presione Enter para salir"
    exit 1
}

$pyDir = Split-Path $pyExe -Parent
$pyScripts = Join-Path $pyDir "Scripts"
$env:PATH = "$pyDir;$pyScripts;$env:PATH"

# Verificar librerias
$testDeps = & $pyExe -c "import PySide6, docx; print('OK')" 2>$null
if ($testDeps -notmatch "OK") {
    Write-Host "Instalando librerias graficas necesarias (PySide6, python-docx)..." -ForegroundColor Yellow
    Write-Host "Esto ocurre una sola vez. Por favor espera..." -ForegroundColor Gray
    if (Test-Path "$appDir\requirements.txt") {
        & $pyExe -m pip install -r "$appDir\requirements.txt"
    } else {
        & $pyExe -m pip install PySide6 python-docx
    }
}

$pywExe = Join-Path $pyDir "pythonw.exe"
if (-not (Test-Path $pywExe)) { $pywExe = $pyExe }

try {
    # Lanzar Charly App
    Start-Process -FilePath $pywExe -ArgumentList "`"$appDir\Charly_App.py`"" -WorkingDirectory $appDir
    exit 0
} catch {
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host " Error al iniciar Charly App: $_" -ForegroundColor Red
    Write-Host "========================================================================" -ForegroundColor Red
    Read-Host "Presione Enter para salir"
    exit 1
}
