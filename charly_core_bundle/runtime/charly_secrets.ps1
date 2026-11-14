# ==============================================================================
# CHARLY v4.0 - LECTURA SEGURA DE LA API KEY DE GOOGLE GEMINI (sin texto plano en el codigo)
# ==============================================================================
# Orden de busqueda:
#   1. Parametro explicito (-ApiKey), si se paso.
#   2. Variable de entorno CHARLY_GEMINI_API_KEY (la define Charly App para sus subprocesos).
#   3. %APPDATA%\Charly_App\settings.json -> 'api_key_encrypted' (cifrada con Windows DPAPI, solo legible por TU
#      usuario de Windows en ESTA PC; es el mismo almacen que usa Charly App).
# Nunca se escribe ni se imprime la clave.

function Get-CharlyGeminiApiKey {
    param([string]$Explicit = "")

    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:CHARLY_GEMINI_API_KEY)) { return $env:CHARLY_GEMINI_API_KEY.Trim() }

    $cfgBase = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { $env:APPDATA } else { Join-Path $env:USERPROFILE "AppData\Roaming" }
    $settingsPath = Join-Path $cfgBase "Charly_App\settings.json"
    if (-not (Test-Path -LiteralPath $settingsPath)) { return "" }

    try {
        $cfg = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $tok = [string]$cfg.api_key_encrypted
        if ($tok.StartsWith("dpapi:")) {
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $bytes = [System.Convert]::FromBase64String($tok.Substring(6))
            $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            return [System.Text.Encoding]::UTF8.GetString($plain).Trim()
        }
        if ($tok.StartsWith("plain:")) {
            return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($tok.Substring(6))).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$cfg.api_key)) { return ([string]$cfg.api_key).Trim() }   # formato legado
    } catch {
        Write-Host "[CLAVE API] No se pudo leer/descifrar la clave de settings.json (otro usuario/PC de Windows?): $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return ""
}

function Write-CharlyApiKeyHelp {
    Write-Host "[CLAVE API] No hay API Key de Google Gemini. Definila en la variable de entorno CHARLY_GEMINI_API_KEY o guardala en Charly App (pestana 'Configurar R e IA'), que la cifra con DPAPI en %APPDATA%\Charly_App\settings.json." -ForegroundColor Red
}
