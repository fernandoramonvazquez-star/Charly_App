param (
    [string]$UserPrompt,
    [string]$UserPromptFile
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# [FIX M3] El texto del usuario llega por archivo (sin limite de linea de comandos ni problemas de comillas/guiones)
if ($UserPromptFile -and (Test-Path -LiteralPath $UserPromptFile)) {
    $UserPrompt = [System.IO.File]::ReadAllText($UserPromptFile, [System.Text.Encoding]::UTF8)
}

$apiKey = if (![string]::IsNullOrWhiteSpace($env:CHARLY_GEMINI_API_KEY)) { $env:CHARLY_GEMINI_API_KEY } else { "" }
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Output '{"mediaciones":[],"efectos_totales":[]}'
    exit 0
}
$url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent"

# System Prompt enfocado estrictamente en extraer cadenas causales y devolver JSON
$sysPrompt = "Eres un parser semántico ultrarrápido y determinista. Tu única tarea es leer el texto del usuario (que describe un modelo estadístico SEM) y extraer las cadenas de mediación (efectos indirectos) y efectos totales.
REGLA 1: Debes retornar UNICAMENTE un objeto JSON válido, sin formato markdown, sin bloques de código, sin texto adicional.
REGLA 2: La estructura del JSON debe ser exactamente: { `"mediaciones`": [ `"A -> B -> C`" ], `"efectos_totales`": [ `"Efecto indirecto total de A sobre C`" ] }
REGLA 3: NO extraigas flechas directas (A -> B). El usuario proveerá las flechas directas por otro medio. Solo te encargas de rutas de 3 o más pasos (mediaciones) y de sumas (efectos totales).
REGLA 4: Si el usuario habla de un efecto indirecto en cadena (ej. 'desde X hasta Y pasando por Z'), tradúcelo a `"X -> Z -> Y`" en el arreglo `"mediaciones`".
REGLA 5: Si el usuario pide sumar efectos, calcular el 'efecto indirecto total', o un efecto compuesto, descríbelo textualmente en la lista `"efectos_totales`" (Ej. `"Efecto indirecto total (suma) desde X hasta Y`").
REGLA 6: Usa los nombres exactos de los factores (Capitalizados) tal como los menciona el usuario. Si no hay elementos en alguna categoría, devuelve arreglos vacíos []."

$payloadObj = @{
    system_instruction = @{ parts = @( @{ text = $sysPrompt } ) }
    contents = @( @{ role = "user"; parts = @( @{ text = $UserPrompt } ) } )
    generationConfig = @{
        temperature = 0.0
    }
}

$jsonBody = $payloadObj | ConvertTo-Json -Depth 6
$bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

$req = [System.Net.HttpWebRequest]::Create($url)
$req.Method = "POST"
$req.Headers.Add("x-goog-api-key", $apiKey)   # [FIX M11] clave en encabezado, no en la URL
$req.ContentType = "application/json; charset=utf-8"
$req.ContentLength = $bytes.Length
$req.Timeout = 15000
$req.ReadWriteTimeout = 15000

try {
    $reqStream = $req.GetRequestStream()
    $reqStream.Write($bytes, 0, $bytes.Length)
    $reqStream.Close()
    
    $resp = $req.GetResponse()
    $rStream = $resp.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($rStream, [System.Text.Encoding]::UTF8)
    $resText = $reader.ReadToEnd()
    
    $json = $resText | ConvertFrom-Json
    if ($json.candidates -and $json.candidates.Count -gt 0) {
        $extractedText = $json.candidates[0].content.parts[0].text
        # Limpiar posible markdown
        $extractedText = $extractedText -replace '```json', '' -replace '```', ''
        Write-Output $extractedText.Trim()
    } else {
        Write-Output '{ "mediaciones": [], "efectos_totales": [] }'
    }
} catch {
    # Aviso a stderr (no contamina el JSON de stdout): Charly App lo registra en charly.log.
    [Console]::Error.WriteLine("[semantic_parser] Fallo la extraccion de mediaciones (se usara la deteccion automatica): " + $_.Exception.Message)
    Write-Output '{ "mediaciones": [], "efectos_totales": [] }'
}
