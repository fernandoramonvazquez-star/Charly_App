# ==============================================================================
# CHARLY v4.0 - MOTOR EN LA NUBE GRATUITO: GOOGLE GEMINI FLASH (API REST)
# ==============================================================================

param(
    [string]$PromptFile = "workspace/full_prompt.txt",
    [string]$OutputFile = "workspace/generated_script.R",
    [string]$ApiKey = ""
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# La API Key NO vive en el codigo: parametro, variable de entorno CHARLY_GEMINI_API_KEY o settings.json cifrado (DPAPI)
. (Join-Path (Split-Path $PSScriptRoot -Parent) "runtime\charly_secrets.ps1")
$ApiKey = Get-CharlyGeminiApiKey -Explicit $ApiKey
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-CharlyApiKeyHelp
    exit 1
}

if (!(Test-Path $PromptFile)) {
    Write-Host "[GEMINI ENGINE] Error: No se encuentra el archivo de prompt: $PromptFile" -ForegroundColor Red
    exit 1
}

$promptText = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile), [System.Text.Encoding]::UTF8)

# Modelos flash oficiales y vigentes de Google AI Studio (prioriza CHARLY_GEMINI_MODEL si fue configurado)
$candidateModels = @()
if (![string]::IsNullOrWhiteSpace($env:CHARLY_GEMINI_MODEL)) {
    $candidateModels += $env:CHARLY_GEMINI_MODEL.Trim()
}
$candidateModels += @(
    "gemini-flash-lite-latest",
    "gemini-flash-latest",
    "gemini-2.5-flash",
    "gemini-2.0-flash"
)
$modelsToTry = @($candidateModels | Select-Object -Unique)

$success = $false
$responseContent = ""

foreach ($m in $modelsToTry) {
    Write-Host "[GEMINI ENGINE] Consultando a Google Gemini ($m)..." -ForegroundColor Cyan
    # [M11] la clave va en el encabezado x-goog-api-key, no en la URL
    $url = "https://generativelanguage.googleapis.com/v1beta/models/${m}:generateContent"
    
    $payloadObj = @{
        contents = @(
            @{
                role = "user"
                parts = @(
                    @{ text = [string]$promptText }
                )
            }
        )
        generationConfig = @{
            temperature = 0.1
            maxOutputTokens = 8192
        }
    }
    
    $jsonBody = $payloadObj | ConvertTo-Json -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    
    $maxAttemptsPerModel = 2
    for ($attempt = 1; $attempt -le $maxAttemptsPerModel; $attempt++) {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = "POST"
        $req.Headers.Add("x-goog-api-key", $ApiKey)
        $req.ContentType = "application/json; charset=utf-8"
        $req.ContentLength = $bytes.Length
        $req.Timeout = 90000
        $req.ReadWriteTimeout = 90000
        
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $reqStream = $req.GetRequestStream()
            $reqStream.Write($bytes, 0, $bytes.Length)
            $reqStream.Close()
            
            $resp = $req.GetResponse()
            $rStream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($rStream, [System.Text.Encoding]::UTF8)
            $resText = $reader.ReadToEnd()
            $sw.Stop()
            
            $json = $resText | ConvertFrom-Json
            if ($json.candidates -and $json.candidates.Count -gt 0) {
                $responseContent = ($json.candidates[0].content.parts | ForEach-Object { $_.text }) -join ""
                if ($json.candidates[0].finishReason -eq "MAX_TOKENS") {
                    Write-Host "[GEMINI ENGINE] Error: la respuesta de $m llego al limite de tokens (MAX_TOKENS): el codigo R esta INCOMPLETO. Simplifica la consulta." -ForegroundColor Red
                    exit 1
                }
                Write-Host "[GEMINI ENGINE] Respuesta recibida en $($sw.ElapsedMilliseconds) ms con modelo $m" -ForegroundColor Green
                $success = $true
                break
            }
        } catch [System.Net.WebException] {
            $errResp = $_.Exception.Response
            if ($errResp) {
                $statusCode = [int]$errResp.StatusCode
                $errStream = $errResp.GetResponseStream()
                $errReader = New-Object System.IO.StreamReader($errStream)
                $errBody = $errReader.ReadToEnd()
                Write-Host "[GEMINI ENGINE] Error API ($statusCode) con $m (intento $attempt): $errBody" -ForegroundColor Yellow
                
                # Si es 503 (alta demanda temporal), esperar 3 segundos antes de reintentar
                if ($statusCode -eq 503 -and $attempt -lt $maxAttemptsPerModel) {
                    Write-Host "[GEMINI ENGINE] Demanda alta en Google Cloud. Esperando 3s antes de reintentar con $m..." -ForegroundColor Gray
                    Start-Sleep -Seconds 3
                    continue
                }
            } else {
                Write-Host "[GEMINI ENGINE] Error de red con $m : $($_.Exception.Message)" -ForegroundColor Yellow
            }
            break
        }
    }
    if ($success) { break }
}

if (!$success -or [string]::IsNullOrWhiteSpace($responseContent)) {
    Write-Host "[GEMINI ENGINE] Error: No se pudo obtener respuesta de la API de Gemini." -ForegroundColor Red
    exit 1
}

# Extraer y desinfectar bloque de codigo R de forma universal
$rCode = ""
if ($responseContent -match '(?s)```(?:r|R)?\s*\r?\n(.*?)```') {
    $rCode = $matches[1]
} elseif ($responseContent -match '(?s)(?:^|\r?\n)`*(?:r|R)?\s*\r?\n(.*?)```') {
    $rCode = $matches[1]
} elseif ($responseContent -match '(?s)(?:```+|`+)(?:r|R)?\s*\r?\n(.*)') {
    $rCode = $matches[1]
} else {
    $rCode = $responseContent
}

# Desinfeccion defensiva de caracteres markdown residuales:
# primero se quita la valla de apertura y luego se corta en la de cierre (antes podia vaciar el codigo)
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

# Guardar script R puro generado por el modelo
$targetDir = Split-Path $OutputFile -Parent
if (!(Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }

$fullOutputPath = [System.IO.Path]::GetFullPath($OutputFile)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($fullOutputPath, $rCode, $utf8NoBom)
Write-Host "[GEMINI ENGINE] Script R guardado exitosamente en: $OutputFile" -ForegroundColor Green
