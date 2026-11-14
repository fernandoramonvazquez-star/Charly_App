# ==============================================================================
# CHARLY v4.0 - MOTOR DE INFERENCIA LOCAL: SERU GIRAN (QWEN3.6-35B-A3B MoE) EN LLAMA-SERVER
# ==============================================================================

param(
    [string]$PromptFile = "workspace/full_prompt.txt",
    [string]$OutputFile = "workspace/generated_script.R",
    [int]$Port = 8080,
    [double]$Temperature = 0.1
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (!(Test-Path $PromptFile)) {
    Write-Host "[LOCAL ENGINE] Error: No se encuentra el archivo de prompt: $PromptFile" -ForegroundColor Red
    exit 1
}

$serverScript = Join-Path $PSScriptRoot "local_server.ps1"
. $serverScript

$useDirectEndpoint = ($env:CHARLY_LOCAL_MODE -eq "endpoint" -and ![string]::IsNullOrWhiteSpace($env:CHARLY_LOCAL_HOST))
if (!$useDirectEndpoint) {
    $serverReady = Start-LocalServer
    if (!$serverReady) {
        Write-Host "[LOCAL ENGINE] No se pudo iniciar el servidor local con Seru Giran (Qwen3.6-35B-A3B MoE)." -ForegroundColor Red
        exit 1
    }
    $activePort = Get-ActivePort
    if (!$activePort) { $activePort = 8090 }
    $modelSt = Get-LocalModelStatus
    $activeModelLabel = if ($modelSt -and $modelSt.ActiveModelName) { $modelSt.ActiveModelName } else { "Qwen3.6-35B-A3B MoE" }
    $targetBaseUrl = "http://127.0.0.1:$activePort"
    $modelPayloadName = "local-model"
}
else {
    $targetBaseUrl = $env:CHARLY_LOCAL_HOST.TrimEnd('/')
    $modelPayloadName = if (![string]::IsNullOrWhiteSpace($env:CHARLY_LOCAL_MODEL_NAME)) { $env:CHARLY_LOCAL_MODEL_NAME } else { "local-model" }
    $activeModelLabel = $modelPayloadName
}

$promptText = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile), [System.Text.Encoding]::UTF8)

Write-Host "[LOCAL ENGINE] Enviando consulta a IA Local ($activeModelLabel) en $targetBaseUrl ..." -ForegroundColor Cyan
Write-Host "[LOCAL ENGINE] Procesando localmente..." -ForegroundColor Gray

# Presupuesto dinamico y adaptativo de tokens (Permite hasta 6144 tokens de salida con prompt compactado):
$estimatedInputTokens = [Math]::Ceiling($promptText.Length / 3.0)
$contextLimit = 12288
$safetyMargin = 250
$availableOutputTokens = $contextLimit - $estimatedInputTokens - $safetyMargin
# Garantizar hasta 6144 tokens completos de salida para modelos extensos
$safeMaxTokens = [Math]::Min(6144, [Math]::Max(2048, $availableOutputTokens))

$bodyObj = @{
    model                = $modelPayloadName
    messages             = @(
        @{
            role    = "user"
            content = $promptText
        }
    )
    temperature          = $Temperature
    max_tokens           = $safeMaxTokens
    n_predict            = $safeMaxTokens
    stream               = $true
    chat_template_kwargs = @{
        enable_thinking = $true
    }
}

$jsonBody = $bodyObj | ConvertTo-Json -Depth 6
$bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

$url = "$targetBaseUrl/v1/chat/completions"
$req = [System.Net.HttpWebRequest]::Create($url)
$req.Method = "POST"
$req.ContentType = "application/json; charset=utf-8"
$req.ContentLength = $bytes.Length
$req.Timeout = 3600000
$req.ReadWriteTimeout = 3600000

$reqStream = $req.GetRequestStream()
$reqStream.Write($bytes, 0, $bytes.Length)
$reqStream.Close()

try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "`n[SERU GIRAN] Procesando prompt en los 6 Performance-Cores..." -ForegroundColor Cyan

    $resp = $req.GetResponse()
    $rStream = $resp.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($rStream, [System.Text.Encoding]::UTF8)

    # 1. Monitoreo en vivo y en tiempo real de lectura de prompt y razonamiento en los P-Cores
    $rawAnswerBuilder = New-Object System.Text.StringBuilder
    $firstTokenReceived = $false
    $codeAlreadyFinished = $false
    $reasoningTokens = 0
    $inThinkTag = $false
    $spinChars = @('|', '/', '-', '\')
    $spinIdx = 0
    # Velocidad empirica de lectura de prompt en i7-13620H (6 P-Cores): ~35 tokens/seg
    $estReadSeconds = [Math]::Max(30, [Math]::Round($estimatedInputTokens / 35.0))

    Write-Host "[ETAPA 1/3 - LECTURA EN CPU]: Leyendo consigna y datos (~$estimatedInputTokens tokens, tiempo estimado Total: 2 a 4 min)..." -ForegroundColor Yellow

    # Fase 1: Monitoreo en vivo segundo a segundo hasta que llegue el primer token de codigo real
    while (!$firstTokenReceived) {
        $readLineTask = $reader.ReadLineAsync()
        while (!$readLineTask.IsCompleted) {
            Start-Sleep -Milliseconds 1000
            # Watchdog: verificar que llama-server siga en ejecucion activa (si no es endpoint externo)
            if (!$useDirectEndpoint) {
                $serverProc = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue
                if (!$serverProc) {
                    Write-Host "`n[LOCAL ENGINE] Error critico: El proceso llama-server se detuvo inesperadamente." -ForegroundColor Red
                    exit 1
                }
            }

            try {
                $elapsedSec = [int][Math]::Floor($sw.ElapsedMilliseconds / 1000.0)
                $min = [int][Math]::Floor($elapsedSec / 60.0)
                $sec = [int]($elapsedSec % 60)
                $timeStr = "{0:00}m {1:00}s" -f $min, $sec
                $spin = $spinChars[$spinIdx % $spinChars.Count]
                $spinIdx++

                if ($reasoningTokens -eq 0) {
                    $pct = [int][Math]::Min(99, [Math]::Round(($elapsedSec / [double]$estReadSeconds) * 100.0))
                    $filled = [int][Math]::Floor($pct / 5.0)
                    $empty = [int](20 - $filled)
                    $bar = ("#" * $filled) + ("." * $empty)
                    $stageTxt = if ($pct -lt 30) { "Leyendo ficha de datos" } elseif ($pct -lt 65) { "Procesando contrato psicometrico" } elseif ($pct -lt 90) { "Aplicando reglas del Decalogo" } else { "Iniciando motor de inferencia" }
                    $msg = "`r[ACTIVO $spin] [$bar] $pct% | $stageTxt | Reloj: $timeStr (No cierres la ventana)".PadRight(98)
                    Write-Host -NoNewline $msg -ForegroundColor Yellow
                }
                else {
                    $pctThink = [int][Math]::Min(100, [Math]::Round(($reasoningTokens / 400.0) * 100.0))
                    $filled = [int][Math]::Floor($pctThink / 5.0)
                    $empty = [int](20 - $filled)
                    $bar = ("#" * $filled) + ("." * $empty)
                    $msg = "`r[PENSANDO $spin] [$bar] $reasoningTokens/400 tokens | Disenando script R | Reloj: $timeStr".PadRight(98)
                    Write-Host -NoNewline $msg -ForegroundColor Cyan
                }
            }
            catch {}
        }

        # Analizar la linea recibida
        $line = $readLineTask.Result
        if ($null -eq $line) { break }
        if ($line.StartsWith("data: ")) {
            $data = $line.Substring(6).Trim()
            if ($data -eq "[DONE]") { break }
            try {
                $chunk = $data | ConvertFrom-Json
                $rDelta = $chunk.choices[0].delta.reasoning_content
                $delta = $chunk.choices[0].delta.content

                # Si el modelo envia <think> dentro de content, contabilizarlo tambien como razonamiento
                if (![string]::IsNullOrEmpty($delta)) {
                    if ($delta -match '<think>') { $inThinkTag = $true }
                    if ($inThinkTag) {
                        $rDelta = $delta
                        if ($delta -match '</think>') {
                            $inThinkTag = $false
                            $delta = ($delta -split '</think>', 2)[1]
                        }
                        else {
                            $delta = ""
                        }
                    }
                }

                if (![string]::IsNullOrEmpty($rDelta)) {
                    if ($reasoningTokens -eq 0) {
                        $elapsedSec = [int][Math]::Floor($sw.ElapsedMilliseconds / 1000.0)
                        $min = [int][Math]::Floor($elapsedSec / 60.0)
                        $sec = [int]($elapsedSec % 60)
                        $timeStr = "{0:00}m {1:00}s" -f $min, $sec
                        Write-Host "`r[ETAPA 1/3 COMPLETADA]: Lectura de prompt finalizada en $timeStr.                                              " -ForegroundColor Green
                        Write-Host "[ETAPA 2/3 - RAZONAMIENTO]: Seru Giran esta pensando la solucion (tope: 400 tokens)..." -ForegroundColor Cyan
                    }
                    $reasoningTokens++
                    $elapsedSec = [int][Math]::Floor($sw.ElapsedMilliseconds / 1000.0)
                    $min = [int][Math]::Floor($elapsedSec / 60.0)
                    $sec = [int]($elapsedSec % 60)
                    $timeStr = "{0:00}m {1:00}s" -f $min, $sec
                    $spin = $spinChars[$spinIdx % $spinChars.Count]
                    $spinIdx++
                    $pctThink = [int][Math]::Min(100, [Math]::Round(($reasoningTokens / 400.0) * 100.0))
                    $filled = [int][Math]::Floor($pctThink / 5.0)
                    $empty = [int](20 - $filled)
                    $bar = ("#" * $filled) + ("." * $empty)
                    $msg = "`r[PENSANDO $spin] [$bar] $reasoningTokens/400 tokens ($pctThink%) | Disenando script R | Reloj: $timeStr".PadRight(98)
                    Write-Host -NoNewline $msg -ForegroundColor Cyan
                }

                if (![string]::IsNullOrEmpty($delta)) {
                    [void]$rawAnswerBuilder.Append($delta)

                    # Analizar si ya se abrio el bloque de codigo R para iniciar el streaming visible
                    $currentFull = $rawAnswerBuilder.ToString()
                    $afterThink = if ($currentFull -match '(?s)</think>\s*(.+)$') { $matches[1] } elseif ($currentFull -notmatch '<think>') { $currentFull } else { "" }

                    $codeStarted = $false
                    $codeInitialChunk = ""

                    if ($afterThink -match '(?s)```(?:r|R)?(?:\s*\r?\n|\s+)(.*)$') {
                        $codeStarted = $true
                        $codeInitialChunk = $matches[1]
                    }
                    elseif ($afterThink.Length -gt 250 -and $afterThink -match '(?m)^\s*(?:library|require|datos\s*<-|#)') {
                        $codeStarted = $true
                        $codeInitialChunk = $afterThink
                    }

                    if ($codeStarted) {
                        $firstTokenReceived = $true
                        $elapsedSec = [int][Math]::Floor($sw.ElapsedMilliseconds / 1000.0)
                        $min = [int][Math]::Floor($elapsedSec / 60.0)
                        $sec = [int]($elapsedSec % 60)
                        $timeStr = "{0:00}m {1:00}s" -f $min, $sec

                        Write-Host "`r[ETAPA 2/3 COMPLETADA]: Razonamiento finalizado ($reasoningTokens tokens) en $timeStr.                          " -ForegroundColor Green
                        Write-Host "`n[ETAPA 3/3 - SERU GIRAN ESCRIBIENDO CODIGO R EN VIVO]:`n" -ForegroundColor DarkCyan

                        if ($codeInitialChunk -match '```') {
                            $cleanChunk = ($codeInitialChunk -split '```', 2)[0]
                            if (![string]::IsNullOrEmpty($cleanChunk)) {
                                Write-Host -NoNewline $cleanChunk -ForegroundColor White
                            }
                            $codeAlreadyFinished = $true
                        }
                        else {
                            if (![string]::IsNullOrEmpty($codeInitialChunk)) {
                                Write-Host -NoNewline $codeInitialChunk -ForegroundColor White
                            }
                        }
                        break
                    }
                }
            }
            catch {}
        }
    }

    # Fase 2: Streaming en vivo del codigo generado token por token
    $streamActive = !$codeAlreadyFinished
    while (!$reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($null -ne $line -and $line.StartsWith("data: ")) {
            $data = $line.Substring(6).Trim()
            if ($data -eq "[DONE]") { break }
            try {
                $chunk = $data | ConvertFrom-Json
                $delta = $chunk.choices[0].delta.content
                if (![string]::IsNullOrEmpty($delta)) {
                    [void]$rawAnswerBuilder.Append($delta)

                    if ($streamActive) {
                        # Si el delta contiene el cierre del bloque ```, cortar el streaming y terminar
                        if ($delta -match '```') {
                            $beforeClosing = ($delta -split '```', 2)[0]
                            if (![string]::IsNullOrEmpty($beforeClosing)) {
                                Write-Host -NoNewline $beforeClosing -ForegroundColor White
                            }
                            $streamActive = $false
                            $currentFull = $rawAnswerBuilder.ToString()
                            $afterThink = if ($currentFull -match '(?s)</think>\s*(.+)$') { $matches[1] } elseif ($currentFull -notmatch '<think>') { $currentFull } else { "" }
                            if ($afterThink -match '(?s)```(?:r|R)?(?:\s*\r?\n|\s+)(.*?)```' -and $matches[1].Length -gt 500 -and $matches[1] -match '\b(?:sem|cfa|lavaan|glm|polr|fa|principal)\s*\(' -and $matches[1] -match '\b(?:print|summary|parameterEstimates)\s*\(') {
                                break
                            }
                        }
                        else {
                            Write-Host -NoNewline $delta -ForegroundColor White
                            $currentFull = $rawAnswerBuilder.ToString()
                            $afterThink = if ($currentFull -match '(?s)</think>\s*(.+)$') { $matches[1] } elseif ($currentFull -notmatch '<think>') { $currentFull } else { "" }
                            if ($afterThink -match '(?s)```(?:r|R)?(?:\s*\r?\n|\s+)(.*?)```' -and $matches[1].Length -gt 500 -and $matches[1] -match '\b(?:sem|cfa|lavaan|glm|polr|fa|principal)\s*\(' -and $matches[1] -match '\b(?:print|summary|parameterEstimates)\s*\(') {
                                $streamActive = $false
                                break
                            }
                        }
                    }
                }
            }
            catch {}
        }
    }
    $sw.Stop()
    $fullAnswer = $rawAnswerBuilder.ToString()
    $rawAnswer = if ($fullAnswer -match '(?s)</think>\s*(.+)$') { $matches[1] } else { $fullAnswer }
    $rawAnswer = [regex]::Replace($rawAnswer, '(?s)<think>.*?</think>\s*', '')
    Write-Host "`n`n[LOCAL ENGINE] Inferencia completada en $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

    # Extraer y desinfectar el bloque cerrado MAS LARGO de codigo R
    $rCode = ""
    $codeMatches = [regex]::Matches($rawAnswer, '(?s)```(?:r|R)?\s*\r?\n(.*?)```')
    if ($codeMatches.Count -gt 0) {
        $rCode = ($codeMatches | Sort-Object { $_.Groups[1].Value.Length } -Descending)[0].Groups[1].Value
    }
    elseif ($rawAnswer -match '(?s)(?:^|\r?\n)`*(?:r|R)?\s*\r?\n(.*?)```') {
        $rCode = $matches[1]
    }
    elseif ($rawAnswer -match '(?s)(?:```+|`+)(?:r|R)?\s*\r?\n(.*)') {
        $rCode = $matches[1]
    }
    else {
        $rCode = $rawAnswer
    }

    # Desinfeccion defensiva de caracteres markdown residuales:
    # [FIX M7] primero se quita la valla de apertura y luego se corta en la de cierre (antes podia vaciar el codigo)
    $rCode = [regex]::Replace($rCode, '^\s*```[A-Za-z{}]*[ \t]*(?:\r?\n|$)', '')
    $fenceIdx = $rCode.IndexOf('```')
    if ($fenceIdx -ge 0) { $rCode = $rCode.Substring(0, $fenceIdx) }
    $rCode = [regex]::Replace($rCode, '^\s*`+\s*(?:r|R)?\s*(\r?\n|$)', '')
    $rCode = [regex]::Replace($rCode, '^\s*(?:r|R)\s*(\r?\n)', '')

    # Remover parrafos conversacionales en espanol al final
    $sanLines = $rCode -split "`r?`n"
    $cleanLinesList = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $sanLines) {
        $trimL = $l.Trim()
        if ($trimL -match '^```') { break }
        if ($cleanLinesList.Count -gt 3 -and $trimL -match '^(?:Si el error|Aseg[uú]rate|Nota:|Espero que|En este script|El error original)\b') {
            break
        }
        $cleanLinesList.Add($l)
    }
    $rCode = ($cleanLinesList -join "`r`n").Trim()

    $targetDir = Split-Path $OutputFile -Parent
    if (![string]::IsNullOrWhiteSpace($targetDir) -and !(Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }

    $fullOutputPath = [System.IO.Path]::GetFullPath($OutputFile)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fullOutputPath, $rCode, $utf8NoBom)
    Write-Host "[LOCAL ENGINE] Script R generado guardado en: $OutputFile" -ForegroundColor Green
}
catch [System.Net.WebException] {
    $errResp = $_.Exception.Response
    if ($errResp) {
        $errReader = New-Object System.IO.StreamReader($errResp.GetResponseStream())
        Write-Host "[LOCAL ENGINE] Error del servidor local: $($errReader.ReadToEnd())" -ForegroundColor Red
    }
    else {
        Write-Host "[LOCAL ENGINE] Error durante la inferencia local: $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}
catch {
    Write-Host "[LOCAL ENGINE] Error durante la inferencia local: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
