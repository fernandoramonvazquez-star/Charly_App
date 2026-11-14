# ==============================================================================
# CHARLY v4.0 - GESTOR DE SERVIDOR LOCAL LLAMA-SERVER (SERU GIRAN: QWEN3.6-35B-A3B MoE)
# ==============================================================================

param(
    [string]$Action = "status"
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$modelPath = if (![string]::IsNullOrWhiteSpace($env:CHARLY_LOCAL_MODEL_PATH)) { $env:CHARLY_LOCAL_MODEL_PATH } else { "C:\llama-cpp\models\Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" }
$expectedBytes = 22134528992

$fallbackMoEPath = "C:\llama-cpp\models\Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
$fallbackMoEBytes = 18556689568

$fallbackDensePath = "C:\llama-cpp\models\qwen2.5-coder-32b-instruct-q4_k_m.gguf"
$fallbackDenseBytes = 19851335872

$serverExe = if (![string]::IsNullOrWhiteSpace($env:CHARLY_LLAMA_SERVER_EXE)) { $env:CHARLY_LLAMA_SERVER_EXE } else { "C:\llama-cpp\llama-server.exe" }
$defaultPort = 8090
$ports = @(8090, 8080)

function Get-LocalModelStatus {
    if (![string]::IsNullOrWhiteSpace($env:CHARLY_LOCAL_MODEL_PATH) -and (Test-Path $env:CHARLY_LOCAL_MODEL_PATH)) {
        $customItem = Get-Item $env:CHARLY_LOCAL_MODEL_PATH
        $customGB = [Math]::Round($customItem.Length / 1GB, 2)
        $friendlyName = if ($customItem.Name -match "Qwen3\.6-35B-A3B") { "Qwen3.6-35B-A3B MoE" } else { $customItem.BaseName }
        return @{
            Ready           = $true
            IsPrimary       = $true
            ActiveModelPath = $customItem.FullName
            ActiveModelName = $friendlyName
            Message         = "Modelo local ($friendlyName) listo ($customGB GB)."
            Percent         = 100
        }
    }
    $q36Exists = Test-Path $modelPath
    $q36Size = if ($q36Exists) { (Get-Item $modelPath).Length } else { 0 }
    $q36Pct = [Math]::Round(($q36Size / $expectedBytes) * 100, 1)
    $q36GB = [Math]::Round($q36Size / 1GB, 2)

    if ($q36Exists -and $q36Size -ge $expectedBytes) {
        return @{
            Ready           = $true
            IsPrimary       = $true
            ActiveModelPath = $modelPath
            ActiveModelName = "Qwen3.6-35B-A3B MoE"
            Message         = "Modelo Seru Giran (Qwen3.6-35B-A3B MoE) descargado y listo ($q36GB GB)."
            Percent         = 100
        }
    }

    # Respaldo inmediato 1: Qwen3-Coder-30B-A3B MoE (mientras termina de descargar Qwen3.6-35B-A3B)
    if (Test-Path $fallbackMoEPath) {
        $fbMoESize = (Get-Item $fallbackMoEPath).Length
        if ($fbMoESize -ge $fallbackMoEBytes) {
            $dlMsg = if ($q36Exists) { "Descargando Qwen3.6-35B-A3B: $q36GB GB / 20.61 GB ($q36Pct%)" } else { "Qwen3.6-35B-A3B pendiente de descarga" }
            return @{
                Ready           = $true
                IsPrimary       = $false
                ActiveModelPath = $fallbackMoEPath
                ActiveModelName = "Qwen3-Coder-30B-A3B MoE (Activo mientras descarga Qwen3.6-35B-A3B)"
                Message         = "$dlMsg | Motor activo ahora: Qwen3-Coder-30B-A3B MoE."
                Percent         = $q36Pct
            }
        }
    }

    # Respaldo inmediato 2: Qwen 2.5 Coder 32B
    if (Test-Path $fallbackDensePath) {
        $fbDenseSize = (Get-Item $fallbackDensePath).Length
        if ($fbDenseSize -ge $fallbackDenseBytes) {
            $dlMsg = if ($q36Exists) { "Descargando Qwen3.6-35B-A3B: $q36GB GB / 20.61 GB ($q36Pct%)" } else { "Qwen3.6-35B-A3B pendiente de descarga" }
            return @{
                Ready           = $true
                IsPrimary       = $false
                ActiveModelPath = $fallbackDensePath
                ActiveModelName = "Qwen 2.5 Coder 32B (Respaldo activo)"
                Message         = "$dlMsg | Respaldo Qwen 2.5 32B listo para usar."
                Percent         = $q36Pct
            }
        }
    }

    if ($q36Exists) {
        return @{
            Ready           = $false
            IsPrimary       = $false
            ActiveModelPath = $modelPath
            ActiveModelName = "Qwen3.6-35B-A3B MoE"
            Message         = "Descarga en progreso: $q36GB GB / 20.61 GB ($q36Pct%)."
            Percent         = $q36Pct
        }
    }

    return @{
        Ready           = $false
        IsPrimary       = $false
        ActiveModelPath = $modelPath
        ActiveModelName = "Qwen3.6-35B-A3B MoE"
        Message         = "El archivo del modelo aun no existe."
        Percent         = 0
    }
}

function Get-ActivePort {
    foreach ($p in $ports) {
        try {
            $res = Invoke-RestMethod -Uri "http://127.0.0.1:$p/health" -Method Get -TimeoutSec 1 -ErrorAction SilentlyContinue
            if ($res.status -eq "ok") { return $p }
        } catch {}
    }
    return $null
}

# [FIX M10] PID del proceso que escucha en un puerto (Get-NetTCPConnection; respaldo: netstat)
function Get-PortOwnerPid([int]$port) {
    try {
        $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($c) { return [int]$c.OwningProcess }
    } catch {}
    try {
        $m = (netstat -ano -p tcp) | Select-String -Pattern (":$port\s+\S+\s+LISTENING\s+(\d+)") | Select-Object -First 1
        if ($m) { return [int]$m.Matches[0].Groups[1].Value }
    } catch {}
    return $null
}

function Test-ServerRunning {
    return ($null -ne (Get-ActivePort))
}

function Start-LocalServer {
    $st = Get-LocalModelStatus
    if (!$st.Ready) {
        Write-Host "[LOCAL SERVER] $($st.Message)" -ForegroundColor Yellow
        Write-Host "[LOCAL SERVER] Por favor espera a que finalice la descarga o utiliza el motor en la nube." -ForegroundColor Cyan
        return $false
    }

    $active = Get-ActivePort
    if ($active) {
        if ($st.IsPrimary) {
            try {
                $expectedLeaf = [regex]::Escape((Split-Path $st.ActiveModelPath -Leaf))
                $ownerPid = Get-PortOwnerPid $active
                $cmdLine = if ($ownerPid) { (Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue).CommandLine } else { $null }
                # Solo se reinicia el servidor del puerto propio de Charly ($defaultPort); uno ajeno en otro puerto se respeta.
                if ($cmdLine -and $active -eq $defaultPort -and ($cmdLine -notmatch $expectedLeaf -or $cmdLine -notmatch "--reasoning-budget\s+400")) {
                    Write-Host "[LOCAL SERVER] Actualizando servidor en vivo a $($st.ActiveModelName) (reasoning-budget 400)..." -ForegroundColor Cyan
                    Stop-LocalServer $active
                    $active = $null
                }
            } catch {}
        }
    }

    if ($active) {
        Write-Host "[LOCAL SERVER] Seru Giran ($($st.ActiveModelName)) ya esta activo en http://127.0.0.1:$active" -ForegroundColor Green
        return $true
    }

    if (!(Test-Path $serverExe)) {
        Write-Host "[LOCAL SERVER] No se encontro el ejecutable llama-server.exe en: $serverExe" -ForegroundColor Red
        return $false
    }

    $chosenModel = $st.ActiveModelPath
    $logicalCores = [Environment]::ProcessorCount
    $threadsGen = [Math]::Max(2, [Math]::Min(6, [int]($logicalCores / 2)))
    $threadsBatch = [Math]::Max(2, [Math]::Min(8, [int]($logicalCores / 2) + 2))
    # [FIX M10] Charly calcula los hilos optimos segun la topologia de la CPU (p. ej. 6 = nucleos de rendimiento) y los pasa por entorno
    if ($env:CHARLY_LLAMA_THREADS -match '^\d+$' -and [int]$env:CHARLY_LLAMA_THREADS -ge 1) { $threadsGen = [int]$env:CHARLY_LLAMA_THREADS }
    if ($env:CHARLY_LLAMA_THREADS_BATCH -match '^\d+$' -and [int]$env:CHARLY_LLAMA_THREADS_BATCH -ge 1) { $threadsBatch = [int]$env:CHARLY_LLAMA_THREADS_BATCH }
    Write-Host "[LOCAL SERVER] Iniciando Seru Giran [$($st.ActiveModelName)] optimizado (puerto $defaultPort, contexto 12k, threads $threadsGen/$threadsBatch)..." -ForegroundColor Cyan
    # [FIX M3] Start-Process -ArgumentList NO entrecomilla los elementos con espacios (PS 5.1): se hace a mano.
    function Quote-Arg([string]$s) { '"' + ($s -replace '"', '\"') + '"' }
    $procArgs = @("-m", (Quote-Arg $chosenModel), "-c", "12288", "-np", "1", "--threads", "$threadsGen", "--threads-batch", "$threadsBatch", "-b", "512", "-ub", "512", "--reasoning", "on", "--reasoning-budget", "400", "--reasoning-format", "deepseek", "--port", "$defaultPort", "--host", "127.0.0.1")
    $serverProc = Start-Process -FilePath $serverExe -ArgumentList $procArgs -WindowStyle Minimized -PassThru

    $attempts = 0
    while ($attempts -lt 150) {
        Start-Sleep -Seconds 2
        $attempts++
        $active = Get-ActivePort
        if ($active) {
            Write-Host "[LOCAL SERVER] Seru Giran listo y respondiendo en http://127.0.0.1:$active" -ForegroundColor Green
            return $true
        }
        Write-Host "." -NoNewline
    }
    Write-Host "`n[LOCAL SERVER] Tiempo de espera agotado al iniciar Seru Giran." -ForegroundColor Red
    return $false
}

function Stop-LocalServer([int]$Port = $defaultPort) {
    # [FIX M10] antes: taskkill /F /IM llama-server.exe (mataba TODOS los llama-server del equipo, incluidos los ajenos).
    Write-Host "[LOCAL SERVER] Deteniendo el llama-server del puerto $Port..." -ForegroundColor Yellow
    $ownerPid = Get-PortOwnerPid $Port
    if (-not $ownerPid) {
        Write-Host "[LOCAL SERVER] No hay ningun servidor escuchando en el puerto $Port." -ForegroundColor Gray
        return
    }
    $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.ProcessName -ne "llama-server") {
        Write-Host "[LOCAL SERVER] El proceso del puerto $Port no es llama-server; no se toca." -ForegroundColor Yellow
        return
    }
    Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
    $attempts = 0
    while ((Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) -and $attempts -lt 20) {
        Start-Sleep -Milliseconds 500
        $attempts++
    }
    Write-Host "[LOCAL SERVER] Servidor detenido completamente." -ForegroundColor Green
}

switch ($Action.ToLower()) {
    "start"  { Start-LocalServer }
    "stop"   { Stop-LocalServer }
    "status" { 
        $st = Get-LocalModelStatus
        $colorModel = if ($st.IsPrimary) { "Green" } elseif ($st.Ready) { "Cyan" } else { "Yellow" }
        Write-Host "Estado del Modelo Local: $($st.Message)" -ForegroundColor $colorModel
        
        $active = Get-ActivePort
        $statusText = if ($active) { "SI (puerto $active)" } else { "NO" }
        $colorRunning = if ($active) { "Green" } else { "Gray" }
        Write-Host "Servidor HTTP Activo: $statusText" -ForegroundColor $colorRunning
    }
}
