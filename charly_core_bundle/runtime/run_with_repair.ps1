# ==============================================================================



# CHARLY v4.0 - BUCLE DE EJECUCION Y AUTORREPARACION DINAMICA (SELF-CORRECTION)



# ==============================================================================



param(



[string]$ScriptPath = "workspace/generated_script.R",



[string]$Engine = "cloud",



[int]$MaxAttempts = 2



)



[Console]::OutputEncoding = [System.Text.Encoding]::UTF8



$OutputEncoding = [System.Text.Encoding]::UTF8



if ($env:CHARLY_RSCRIPT_EXE -and (Test-Path $env:CHARLY_RSCRIPT_EXE)) {



$Rscript = $env:CHARLY_RSCRIPT_EXE



} else {



$rDirs = Get-ChildItem "C:\Program Files\R" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending



if ($rDirs.Count -gt 0) { $Rscript = Join-Path $rDirs[0].FullName "bin\Rscript.exe" } else { $Rscript = "C:\Program Files\R\R-4.5.2\bin\Rscript.exe" }



}

$rVerStr = if ($Rscript -match 'R-(\d+\.\d+\.\d+)') { "R $($matches[1])" } else { "R" }



$scriptDir = if (![string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }



$baseDir = if (![string]::IsNullOrWhiteSpace($scriptDir)) { Split-Path $scriptDir -Parent } else { (Get-Location).Path }



if (Test-Path (Join-Path $baseDir "workspace")) { Set-Location $baseDir }



if (-not (Test-Path $ScriptPath)) {



if ($ScriptPath -match 'charly_v4[\\/](.+)$' -and (Test-Path $matches[1])) {



$ScriptPath = $matches[1]



} elseif (Test-Path (Join-Path $baseDir $ScriptPath)) {



$ScriptPath = Join-Path $baseDir $ScriptPath



}



}



if (Test-Path $ScriptPath) {



$ScriptPath = (Resolve-Path $ScriptPath).Path



}



$utf8NoBom = New-Object System.Text.UTF8Encoding($false)



# Archivo con los avisos de R de la ultima ejecucion (lo leen charly_core.ps1 y Charly_App para el cartel final).



# Se borra al inicio para que nunca quede un archivo viejo de un analisis anterior.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseDir = if ($scriptDir) { Split-Path -Parent $scriptDir } else { $null }

$wsCandidates = New-Object System.Collections.Generic.List[string]
$wsCandidates.Add("workspace/avisos_r.txt")
if ($baseDir) { $wsCandidates.Add((Join-Path $baseDir "workspace/avisos_r.txt")) }
if ($baseDir) {
    $parentDir = Split-Path $baseDir -Parent
    if ($parentDir) {
        $wsCandidates.Add((Join-Path $parentDir "workspace/avisos_r.txt"))
        $wsCandidates.Add((Join-Path $parentDir "charly_core_bundle/workspace/avisos_r.txt"))
        $wsCandidates.Add((Join-Path $parentDir "charly_v4/workspace/avisos_r.txt"))
    }
}
$wsCandidates.Add((Join-Path (Get-Location).Path "workspace/avisos_r.txt") )
foreach ($p in ($wsCandidates | Select-Object -Unique)) {
    if (![string]::IsNullOrWhiteSpace($p) -and (Test-Path $p)) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}



# Extrae de la salida de R los BLOQUES COMPLETOS de avisos (Warning message / lavaan WARNING / lavaan-> ...),



# filtrando ruido informativo de paquetes (This is lavaan..., was built under, etc.) para evitar falsos positivos.



function Get-RWarningBlocks([string]$Text, [string[]]$FallbackLines) {



$rawLines = New-Object System.Collections.Generic.List[string]



$capturing = $false



$headerPattern = '^(Warning( in| message)?|Avisos?:?|Mensajes? de aviso:?|lavaan WARNING:?|lavaan->)'



$benignPattern = 'This is (semTools|lavaan)|is BETA|FREE software|please report|^#+$|was built under|fue compilado con la versi|Attaching package|The following object|Loading required (namespace|package)|Cargando el paquete requerido|cargando espacio de nombres|Registered S3 method|New names:|Waiting for profiling to be done|^\s*\u2022|->\s*`\.\.\.'



foreach ($ln in ($Text -split "`r?`n")) {



$trimmed = $ln.Trim()



if ($trimmed -match $headerPattern -or $ln -match '^\s*lavaan->') {



$capturing = $true



$rawLines.Add($ln.TrimEnd())



continue



}



if ($capturing) {



if ($trimmed.StartsWith('>') -or $trimmed.StartsWith('[1]') -or $trimmed.StartsWith('ESTADO:') -or [string]::IsNullOrWhiteSpace($trimmed)) {



$capturing = $false



} else {



$rawLines.Add($ln.TrimEnd())



}



}



}



$joined = ($rawLines -join "`n")



foreach ($fl in $FallbackLines) {



if ($fl -match $benignPattern) { continue }



if ($joined.Contains($fl.Trim())) { continue }



$rawLines.Add($fl.Trim())



}



# Filtrar lineas benignas y verificar si quedan advertencias reales (no solo encabezados vacios como 'Aviso:')



$cleanLines = New-Object System.Collections.Generic.List[string]



$hasSubstantiveContent = $false



foreach ($line in $rawLines) {



if ($line -match $benignPattern) { continue }



$cleanLines.Add($line)



if ($line.Trim() -notmatch '^(:|Warning( in| message)?:?|Avisos?:?|Mensajes? de aviso:?)$') {



$hasSubstantiveContent = $true



}



}



if (-not $hasSubstantiveContent) {
    return @()
}

$filteredLines = New-Object System.Collections.Generic.List[string]
$headerRegex = '^(:|Warning( in| message)?:?|Avisos?:?|Mensajes? de aviso:?)$'
for ($i = 0; $i -lt $cleanLines.Count; $i++) {
    $curr = $cleanLines[$i].Trim()
    $isHeader = ($curr -match $headerRegex)
    if ($isHeader) {
        if ($i + 1 -ge $cleanLines.Count) { continue }
        $next = $cleanLines[$i + 1].Trim()
        if ($next -match $headerRegex -or [string]::IsNullOrWhiteSpace($next)) { continue }
    }
    $filteredLines.Add($cleanLines[$i])
}

return $filteredLines.ToArray()



}



function Get-NameKey([string]$s) {

if ([string]::IsNullOrEmpty($s)) { return "" }

return (($s.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', '').ToLowerInvariant() -replace '[\s_\.\-]+', '')

}

function Repair-ColumnCasing {
    param([string]$Script, [string[]]$RealCols)

    if ([string]::IsNullOrEmpty($Script) -or -not $RealCols -or $RealCols.Count -eq 0) {
        return $Script
    }

    $rReserved = @(
        'if','else','repeat','while','function','for','in','next','break',
        'true','false','null','inf','nan','na','na_integer_','na_real_',
        'na_complex_','na_character_','data','file','sheet','method',
        'family','link','ordered','missing','estimator','std','est','se',
        'fit','summary','print','cat','factor','list','matrix','vector',
        'table','mean','sd','var','cor','cov','sum','min','max','df'
    )

    $lowerCounts = @{}
    foreach ($rc in $RealCols) {
        if ([string]::IsNullOrWhiteSpace($rc)) { continue }
        $lk = $rc.ToLowerInvariant()
        $lowerCounts[$lk] = ($lowerCounts[$lk] -as [int]) + 1
    }

    $colMap = @{}
    foreach ($rc in $RealCols) {
        if ([string]::IsNullOrWhiteSpace($rc) -or $rc.Length -lt 2) { continue }
        $lk = $rc.ToLowerInvariant()
        if ($lowerCounts[$lk] -gt 1) { continue }
        if ($rReserved -contains $lk) { continue }
        $colMap[$lk] = $rc
    }

    if ($colMap.Count -eq 0) { return $Script }

    $alt = (($colMap.Keys | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|')
    $fixedPairs = [System.Collections.Generic.List[string]]::new()

    $evalMatch = [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $orig = $m.Groups['col'].Value
        $canon = $colMap[$orig.ToLowerInvariant()]
        if ($canon -and ($orig -cne $canon)) {
            $pair = "$orig->$canon"
            if (-not $fixedPairs.Contains($pair)) { $fixedPairs.Add($pair) }
            return $m.Groups['prefix'].Value + $canon + $m.Groups['suffix'].Value
        }
        return $m.Value
    }

    # 1. Acceso dataframe$COL (en cualquier linea no comentada)
    $patDollar = '(?im)(?<prefix>[a-zA-Z0-9_\.]+\$)(?<col>' + $alt + ')(?<suffix>(?![a-zA-Z0-9_\.]))'
    # 2. Cadenas literales exactas "COL" / 'COL' (no precedidas de sheet = )
    $patQuoted = '(?im)(?<!sheet\s*=\s*)(?<prefix>[''"])(?<col>' + $alt + ')(?<suffix>\k<prefix>)'
    # 3. Identificadores libres en formulas/expresiones (no precedidos de $/./letra ni seguidos de (/<-)
    $patBare = '(?im)(?<prefix>(?<![a-zA-Z0-9_\.\$]))(?<col>' + $alt + ')(?<suffix>(?![a-zA-Z0-9_\.])(?!\s*(?:\(|<-)))'

    $lines = $Script -split "(`r`n|`n|`r)"
    $outParts = New-Object System.Collections.Generic.List[string]
    $inModelString = $false
    $modelQuote = ""

    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        $part = $lines[$idx]
        if ($part -eq "`r`n" -or $part -eq "`n" -or $part -eq "`r") {
            $outParts.Add($part)
            continue
        }

        $trimmed = $part.Trim()
        if ($trimmed.StartsWith('#')) {
            $outParts.Add($part)
            continue
        }

        if (-not $inModelString -and $trimmed -match '^\s*[a-zA-Z0-9_\.]+\s*(?:<-|=)\s*([''"])([^''"]*)$') {
            $qChar = $Matches[1]
            # Si la comilla no se cierra en esta misma linea, inicia un bloque multilinea (p. ej. modelo lavaan)
            $inModelString = $true
            $modelQuote = $qChar
            $part = [regex]::Replace($part, $patDollar, $evalMatch)
            $outParts.Add($part)
            continue
        }

        if ($inModelString) {
            $part = [regex]::Replace($part, $patBare, $evalMatch)
            if ($trimmed -match ([regex]::Escape($modelQuote) + '\s*(?:#.*)?$')) {
                $inModelString = $false
                $modelQuote = ""
            }
            $outParts.Add($part)
            continue
        }

        # Separar posible comentario inline sin alterar comillas
        $hashIdx = -1
        $qOpen = ""
        for ($ci = 0; $ci -lt $part.Length; $ci++) {
            $ch = $part[$ci]
            if ($qOpen) {
                if ($ch -eq '\' -and ($ci + 1) -lt $part.Length) { $ci++; continue }
                if ($ch -eq $qOpen) { $qOpen = "" }
            } else {
                if ($ch -eq '"' -or $ch -eq "'") { $qOpen = $ch }
                elseif ($ch -eq '#') { $hashIdx = $ci; break }
            }
        }
        $codeSeg = if ($hashIdx -ge 0) { $part.Substring(0, $hashIdx) } else { $part }
        $commentSeg = if ($hashIdx -ge 0) { $part.Substring($hashIdx) } else { "" }

        $codeSeg = [regex]::Replace($codeSeg, $patDollar, $evalMatch)
        $codeSeg = [regex]::Replace($codeSeg, $patQuoted, $evalMatch)

        if ($trimmed -notmatch '^(?:cat|sprintf|message|warning|stop|print)\s*\(\s*[''"]') {
            # Reemplazar identificadores libres fuera de strings (salvo cadenas de modelo con ~ o =~)
            $segOut = New-Object System.Text.StringBuilder
            $pos = 0
            $qRe = [regex]::new('([''"])(?:\\.|(?!\1).)*\1')
            foreach ($qm in $qRe.Matches($codeSeg)) {
                if ($qm.Index -gt $pos) {
                    $plain = $codeSeg.Substring($pos, $qm.Index - $pos)
                    [void]$segOut.Append([regex]::Replace($plain, $patBare, $evalMatch))
                }
                $qText = $qm.Value
                if ($qText -match '=~|~') {
                    $qText = [regex]::Replace($qText, $patBare, $evalMatch)
                }
                [void]$segOut.Append($qText)
                $pos = $qm.Index + $qm.Length
            }
            if ($pos -lt $codeSeg.Length) {
                $tail = $codeSeg.Substring($pos)
                [void]$segOut.Append([regex]::Replace($tail, $patBare, $evalMatch))
            }
            $codeSeg = $segOut.ToString()
        }

        $outParts.Add($codeSeg + $commentSeg)
    }

    if ($fixedPairs.Count -gt 0) {
        Write-Host "[ALINEACION DE NOMBRES] Se normalizaron mayusculas/minusculas de columnas segun la base real: $($fixedPairs -join ', ')" -ForegroundColor Green
    }

    return ($outParts -join "")
}



# Reescribe la anulacion destructiva de los DOS niveles validos de una variable binaria (ver blindaje en glm()).



function Repair-DestructiveDepClean {



param([string]$Script, [string]$Var, [string[]]$Vals)



$v = [regex]::Escape($Var)



$ref = '(?:datos\[\[[''"]?' + $v + '[''"]?\]\]|datos\$' + $v + ')'



$alt = (($Vals | ForEach-Object { [regex]::Escape($_) }) -join '|')



$newLine = "datos[['$Var']][!datos[['$Var']] %in% c($($Vals -join ', '))] <- NA"



$valSet = @($Vals | Sort-Object)



# (a) dos asignaciones consecutivas: VD[VD == a] <- NA ; VD[VD == b] <- NA   (solo si a != b)



$pA = '(?m)^[ \t]*' + $ref + '\s*\[\s*' + $ref + '\s*==\s*(' + $alt + ')\s*\]\s*<-\s*NA[ \t]*\r?\n[ \t]*' + $ref + '\s*\[\s*' + $ref + '\s*==\s*(' + $alt + ')\s*\]\s*<-\s*NA[ \t]*'



$out = [regex]::Replace($Script, $pA, [System.Text.RegularExpressions.MatchEvaluator]{



param($m)



if ($m.Groups[1].Value -ne $m.Groups[2].Value) { return $newLine } else { return $m.Value }



})



# (b) VD[VD %in% c(a, b)] <- NA con exactamente los dos niveles validos



$pB = '(?m)^[ \t]*' + $ref + '\s*\[\s*' + $ref + '\s*%in%\s*c\(([^)]*)\)\s*\]\s*<-\s*NA[ \t]*'



$out = [regex]::Replace($out, $pB, [System.Text.RegularExpressions.MatchEvaluator]{



param($m)



$inner = @([regex]::Matches($m.Groups[1].Value, '[0-9]+(?:\.[0-9]+)?') | ForEach-Object { $_.Value } | Sort-Object -Unique)



if (($inner -join ',') -eq ($valSet -join ',')) { return $newLine } else { return $m.Value }



})



return $out



}



$lastErrorEncountered = ""



# Cargar el parser psicometrico determinista y el auditor de contrato



$psicoParserPath = Join-Path $scriptDir "psico_parser.ps1"



if (Test-Path $psicoParserPath) { . $psicoParserPath }



$contractAuditorPath = Join-Path $scriptDir "contract_auditor.ps1"



if (Test-Path $contractAuditorPath) { . $contractAuditorPath }



# Limpiar archivos de salida previos para garantizar total frescura de datos



if (Test-Path "workspace/resultados_analisis.txt") { Remove-Item "workspace/resultados_analisis.txt" -Force -ErrorAction SilentlyContinue }



if (Test-Path "workspace/consola_rstudio_completa.txt") { Remove-Item "workspace/consola_rstudio_completa.txt" -Force -ErrorAction SilentlyContinue }



for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {



# Normalizador defensivo de rutas de datos: si el script intenta leer un archivo que no existe en esa ruta,



# pero existe workspace/datos_analisis.*, corregir la llamada a 'workspace/datos_analisis.*' automaticamente.



if (Test-Path $ScriptPath) {



$rawScript = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)



# Limpiador de BOM (Byte Order Mark) para prevenir error fatal de R 'unexpected input'



if ($rawScript.StartsWith([char]0xFEFF)) {



$rawScript = $rawScript.TrimStart([char]0xFEFF)



$rawScript = [regex]::Replace($rawScript, "(\r?\n\s*){3,}", "`r`n`r`n")

        [System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawScript, $utf8NoBom)



Write-Host "[BLINDAJE DE CODIFICACION] Se removio preventivamente el caracter BOM (Byte Order Mark) del script" -ForegroundColor Green



}



# Blindaje universal anti-fugas markdown, etiquetas <think> y caracteres residuales:



if ($rawScript -match '(?s)<think>.*?</think>' -or $rawScript -match '(?s)^.*?</think>') {



$rawScript = [regex]::Replace($rawScript, '(?s)<think>.*?</think>\s*', '')



$rawScript = [regex]::Replace($rawScript, '(?s)^.*?</think>\s*', '')



}



# 1. Truncar si hay valla de cierre ``` o markdown residual al final
if ($rawScript -match '(?s)```[ \t]*(?:[rR]|rscript)?[ \t]*\r?\n(.*?)(?:```|\Z)') {
    $rawScript = $matches[1]
} elseif ($rawScript -match '(?s)```\s*\r?\n(.*?)(?:```|\Z)') {
    $rawScript = $matches[1]
} else {
    $rawScript = [regex]::Replace($rawScript, '^\s*```[A-Za-z{}]*[ \t]*(?:\r?\n|$)', '')
    $fenceIdx = $rawScript.IndexOf('```')
    if ($fenceIdx -ge 0) {
        $rawScript = $rawScript.Substring(0, $fenceIdx)
        Write-Host "[BLINDAJE DEFENSIVO] Se trunco preventivamente el texto residual posterior a la valla markdown de cierre" -ForegroundColor Green
    }
}



# 2. Remover lineas iniciales con comillas invertidas sueltas (` o ```) o identificadores de lenguaje ('r' / 'R')



if ($rawScript -match '^\s*`+(?:r|R)?\s*(\r?\n|$)' -or $rawScript -match '^\s*(?:r|R)\s*\r?\n') {



$rawScript = [regex]::Replace($rawScript, '^\s*`+\s*(?:r|R)?\s*(\r?\n|$)', '')



$rawScript = [regex]::Replace($rawScript, '^\s*(?:r|R)\s*\r?\n', '')



Write-Host "[BLINDAJE DEFENSIVO] Se removio preventivamente la valla o caracter markdown residual al inicio del script" -ForegroundColor Green



}



# 3. Remover parrafos conversacionales en espanol al final (fuera de codigo R)



$sLines = $rawScript -split "`r?`n"



$sClean = [System.Collections.Generic.List[string]]::new()



foreach ($sl in $sLines) {



$trimSl = $sl.Trim()



if ($trimSl -match '^```') { break }



if ($sClean.Count -gt 3 -and $trimSl -match '^(?:Si el error|Aseg[uú]rate|Nota:|Espero que|En este script|El error original|Este script|El c[oó]digo|La correcci[oó]n|Explicaci[oó]n:|Los cambios|He corregido|He modificado|Se corrig[eiío])\b') {



Write-Host "[BLINDAJE DEFENSIVO] Se removio texto conversacional no comentado al final del script" -ForegroundColor Green



break



}



$sClean.Add($sl)



}



$rawScript = ($sClean -join "`r`n").Trim()



# Desactivar notacion cientifica globalmente en el script para legibilidad



if ($rawScript -notmatch 'options\s*\(\s*scipen') {



$rawScript = "options(scipen = 999)`r`n" + $rawScript



Write-Host "[ALINEACION ESTADISTICA] Se desactivo la notacion cientifica (scipen=999) para reportar p-valores legibles" -ForegroundColor Green



}



$rawScript = [regex]::Replace($rawScript, "(\r?\n\s*){3,}", "`r`n`r`n")

        [System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawScript, $utf8NoBom)



$safeFiles = Get-ChildItem -Path "workspace" -Filter "datos_analisis.*" -ErrorAction SilentlyContinue



if ($safeFiles.Count -gt 0) {



$defaultSafePath = "workspace/" + $safeFiles[0].Name



$fullSafePath = ($safeFiles[0].FullName -replace '\\', '/')



if ($rawScript -notmatch '(?:read_excel|read\.csv|read\.table|read_sav|read_dta|readRDS)\s*\(\s*if\s*\(\s*file\.exists') {



$pathPattern = "(readxl::read_excel|read_excel|read\.csv|read\.table|haven::read_sav|read_sav|haven::read_dta|read_dta|readRDS)\(\s*['""]([^'""]+?)['""]"



$mPath = [regex]::Match($rawScript, $pathPattern)



if ($mPath.Success) {



$func = $mPath.Groups[1].Value



$origCand = if ($mPath.Groups[2].Success) { $mPath.Groups[2].Value } else { "" }



$smartPath = if ($origCand -and (Test-Path $origCand)) {



"if (file.exists('$origCand')) '$origCand' else if (file.exists('$defaultSafePath')) '$defaultSafePath' else '$fullSafePath'"



} else {



"if (file.exists('$defaultSafePath')) '$defaultSafePath' else '$fullSafePath'"



}



$rawScript = [regex]::Replace($rawScript, $pathPattern, "$func($smartPath", 1)



$rawScript = [regex]::Replace($rawScript, "(\r?\n\s*){3,}", "`r`n`r`n")

        [System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawScript, $utf8NoBom)



Write-Host "[BLINDAJE DE RUTA] Se normalizo la lectura a ruta inteligente auto-resoluble (Charly + RStudio Source)" -ForegroundColor Green



}



}



}



# Normalizacion universal de hoja y columnas segun el perfilador empirico



$profilePath = "workspace/dataset_profile.json"



if (Test-Path $profilePath) {



try {



$profObj = Get-Content $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json



if ($profObj.hoja) {



$realSheet = $profObj.hoja



if ($rawScript -match "sheet\s*=\s*['""]([^'""]+)['""]") {



$calledSheet = $Matches[1]



if ($calledSheet -ne $realSheet) {



$rawScript = $rawScript -replace "sheet\s*=\s*['""]\Q$calledSheet\E['""]", "sheet = '$realSheet'"



Write-Host "[NORMALIZADOR UNIVERSAL] Hoja ajustada a la detectada por el perfilador: '$realSheet'" -ForegroundColor Green



}



} elseif ($rawScript -match "(readxl::read_excel|read_excel)\(\s*['""]([^'""]+)['""]\s*\)") {



$rawScript = [regex]::Replace($rawScript, "(readxl::read_excel|read_excel)\(\s*(['""][^'""]+['""])\s*\)", "`$1(`$2, sheet = '$realSheet')")



Write-Host "[NORMALIZADOR UNIVERSAL] Hoja inyectada segun el perfilador: sheet = '$realSheet'" -ForegroundColor Green



}



}



} catch {}



}



$userGoalCheck = if (Test-Path "workspace/user_goal.txt") { [System.IO.File]::ReadAllText((Resolve-Path "workspace/user_goal.txt"), [System.Text.Encoding]::UTF8) } else { "" }



$rawUserGoalCheck = ($userGoalCheck -split '={20,}')[0]



# 1. Analisis y Alineacion Determinista de Faltantes e Higiene de Datos (via psico_parser)



$realColNames = @()



if (Test-Path "workspace/dataset_profile.json") {



try {



$pJson = Get-Content "workspace/dataset_profile.json" -Raw -Encoding UTF8 | ConvertFrom-Json



if ($pJson.columnas) { $realColNames = @($pJson.columnas.PSObject.Properties.Name) }



} catch {}



}

if ($realColNames.Count -gt 0) {
    $rawScript = Repair-ColumnCasing -Script $rawScript -RealCols $realColNames
}



# Extraer variables observadas del script como candidatos adicionales



$scriptObservedCols = @([regex]::Matches($rawScript, 'datos\$([a-zA-Z0-9_\.]+)|datos\[\[["'']([a-zA-Z0-9_\.]+)["'']\]\]') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })



$factorMatchesEarly = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~')



$allFactorsEarly = @($factorMatchesEarly | ForEach-Object { $_.Groups[1].Value })



$rhsMatchesEarly = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~\s*([^#\r\n]+)')



foreach ($rm in $rhsMatchesEarly) {



$items = $rm.Groups[2].Value -split '\+'



foreach ($it in $items) {



$cleanVar = ($it -replace '^.*\*', '').Trim()



if ($cleanVar -match '^[a-zA-Z][a-zA-Z0-9_\.]*$' -and $allFactorsEarly -notcontains $cleanVar -and $scriptObservedCols -notcontains $cleanVar) {



if ($realColNames.Count -eq 0 -or $realColNames -contains $cleanVar) {



$scriptObservedCols += $cleanVar



}



}



}



}



$combinedCols = @($realColNames + $scriptObservedCols | Select-Object -Unique)



# Extraer directivas de faltantes:
# PRINCIPIO ARQUITECTONICO: Si el usuario confirmo las especificaciones paso a paso en el asistente (Wizard),
# el bloque confirmado es la UNICA FUENTE DE VERDAD. Esto permite que el usuario escriba libremente en el chat
# sin que frases coloquiales o informales interfieran con las reglas exactas confirmadas en el asistente.
$missingDirectives = @()
$isNaExplicitlyCancelled = $false

if ($userGoalCheck -match '(?i)ESPECIFICACIONES\s+METODOLOGICAS\s+CONFIRMADAS') {
    $confirmedParts = $userGoalCheck -split '(?i)ESPECIFICACIONES\s+METODOLOGICAS\s+CONFIRMADAS[^

]*'
    $confirmedBlock = if ($confirmedParts.Count -gt 1) { $confirmedParts[1] } else { "" }
    
    if ($confirmedBlock -match '(?i)-\s*Recodificacion\s+de\s+faltantes\s*\(NA\):\s*No\s+se\s+requieren') {
        $missingDirectives = @()
        $isNaExplicitlyCancelled = $true
    } elseif ($confirmedBlock -match '(?i)-\s*Recodificacion\s+de\s+faltantes\s*\(NA\):[^

]*antes\s+de\s+cualquier\s+analisis:\s*([^

]+)') {
        if (Get-Command Get-MissingDirectives -ErrorAction SilentlyContinue) {
            $missingDirectives = @(Get-MissingDirectives -UserPrompt $Matches[1] -AvailableColumns $combinedCols)
        }
    }
} else {
    # Modo legado sin asistente: inferir desde el texto libre del usuario
    $naCancPattern = '(?i)\b(?:me\s+equivoqu[eé]\s+no\s+(?:van?|corren?)\s+(?:los\s+)?faltantes?|no\s+(?:corren?|van?|aplican?)\s+(?:los\s+)?(?:datos\s+)?faltantes?|olv[ií]date\s+de\s+(?:los\s+)?faltantes?|sin\s+(?:datos\s+)?faltantes?|cero\s+faltantes?|anular\s+(?:los\s+)?faltantes?)\b'
    $isNaExplicitlyCancelled = ($userGoalCheck -match $naCancPattern)
    if (Get-Command Get-MissingDirectives -ErrorAction SilentlyContinue) {
        $missingDirectives = @(Get-MissingDirectives -UserPrompt $userGoalCheck -AvailableColumns $combinedCols)
    }
}

# Si fue cancelado explicitamente O las especificaciones confirmadas indican que no se requieren faltantes:
if ($isNaExplicitlyCancelled -or ($userGoalCheck -match '(?i)-\s*Recodificacion\s+de\s+faltantes\s*\(NA\):\s*No\s+se\s+requieren\s+recodificaciones')) {




$recodePatternsToRemove = @(



'(?m)^\s*#\s*Recodificaci[oó]n\s+(?:exhaustiva\s+)?de\s+faltantes.*?\r?\n',



'(?m)^\s*cols_faltantes\s*<-\s*c\([^)]+\)\s*\r?\n\s*for\s*\([^)]+\)\s*\{[^}]+\}\s*\r?\n',



'(?m)^\s*datos\[\[[^\]]+\]\]\[datos\[\[[^\]]+\]\]\s*==\s*\d+\]\s*<-\s*NA\s*\r?\n',



'(?m)^\s*datos\$[a-zA-Z0-9_\.]+\s*\[\s*datos\$[a-zA-Z0-9_\.]+\s*==\s*\d+\s*\]\s*<-\s*NA\s*\r?\n',



'(?m)^\s*datos\s*\[\s*datos\s*==\s*\d+\s*\]\s*<-\s*NA\s*\r?\n'



)



$removedAny = $false



foreach ($rp in $recodePatternsToRemove) {



if ($rawScript -match $rp) {



$rawScript = [regex]::Replace($rawScript, $rp, "")



$removedAny = $true



}



}



if ($removedAny) {



Write-Host "[ALINEACION DE FALTANTES] Se anulo la recodificacion de faltantes (NA) en el script R conforme a la cancelacion o especificacion." -ForegroundColor Green



}



} elseif ($missingDirectives.Count -gt 0) {



# Extraer factores y variables observadas del modelo lavaan



$factorMatches = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~')



$allFactors = @($factorMatches | ForEach-Object { $_.Groups[1].Value })



$rhsMatches = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~\s*([^#\r\n]+)')



$allObserved = [System.Collections.Generic.List[string]]::new()



foreach ($rm in $rhsMatches) {



$items = $rm.Groups[2].Value -split '\+'



foreach ($it in $items) {



$cleanVar = ($it -replace '^.*\*', '').Trim()



if ($cleanVar -match '^[a-zA-Z][a-zA-Z0-9_\.]*$' -and $allFactors -notcontains $cleanVar -and -not $allObserved.Contains($cleanVar)) {



if ($realColNames.Count -eq 0 -or $realColNames -contains $cleanVar) {



$allObserved.Add($cleanVar)



}



}



}



}



# Procesar cada directiva detectada deterministamente



$injectedLines = [System.Collections.Generic.List[string]]::new()



foreach ($mDir in $missingDirectives) {



if ($mDir.Tipo -eq "Puntual") {



# Restringir o eliminar recodificaciones globales peligrosas



foreach ($val in $mDir.Valores) {



$globalBad = '(?m)^\s*datos\s*\[\s*datos\s*==\s*' + [regex]::Escape($val) + '\s*\]\s*<-\s*NA\s*\r?\n?'



if ($rawScript -match $globalBad) {



$rawScript = [regex]::Replace($rawScript, $globalBad, "")



Write-Host "[ALINEACION DE FALTANTES] Se elimino la recodificacion global 'datos[datos == $val] <- NA' para aplicar solo a variables especificas" -ForegroundColor Green



}



}



# Verificar si cada columna puntual tiene su recodificacion



foreach ($col in $mDir.Columnas) {



if ($combinedCols.Count -gt 0 -and $combinedCols -notcontains $col -and $allObserved -notcontains $col) {



continue



}



foreach ($val in $mDir.Valores) {



$colEsc = [regex]::Escape($col)



$valEsc = [regex]::Escape($val)



$recodeLine = "datos[['$col']][datos[['$col']] == $val] <- NA"



$re = '(?m)datos(?:\[\[[''"]?' + $colEsc + '[''"]?\]\]|\$' + $colEsc + ')\s*\[\s*datos(?:\[\[[''"]?' + $colEsc + '[''"]?\]\]|\$' + $colEsc + ')\s*(?:==|%in%)\s*(?:c\s*\(\s*)?' + $valEsc + '\b'



$alreadyRecoded = ($rawScript -match $re) -or ($rawScript -match "datos\[datos\s*==\s*$valEsc\]\s*<-\s*NA") -or ($injectedLines -contains $recodeLine)



if (-not $alreadyRecoded) {



$injectedLines.Add($recodeLine)



Write-Host "[ALINEACION DE FALTANTES] Inyectando recodificacion puntual: $recodeLine" -ForegroundColor Green



}



}



}



} elseif ($mDir.Tipo -eq "General") {



foreach ($val in $mDir.Valores) {



# Si existe global datos[datos == val] <- NA, transformarlo a bucle sobre indicadores observados



$globalBad = '(?m)^\s*datos\s*\[\s*datos\s*==\s*' + [regex]::Escape($val) + '\s*\]\s*<-\s*NA\s*\r?\n?'



if ($allObserved.Count -gt 0) {



$validObs = if ($realColNames.Count -gt 0) { @($allObserved | Where-Object { $realColNames -contains $_ }) } else { @($allObserved) }



if ($validObs.Count -gt 0) {



$colsStr = ($validObs | ForEach-Object { "`"$_`"" }) -join ", "



$recodeBlock = "# Recodificacion exhaustiva de faltantes (valor $val a NA en variables del modelo)`r`n" +



"cols_faltantes <- c($colsStr)`r`n" +



"for (col in cols_faltantes) {`r`n" +



"  if (col %in% names(datos)) datos[[col]][datos[[col]] == $val] <- NA`r`n" +



"}`r`n`r`n"



if ($rawScript -match $globalBad) {



$rawScript = [regex]::Replace($rawScript, $globalBad, "")



$injectedLines.Add($recodeBlock.TrimEnd())



Write-Host "[ALINEACION DE FALTANTES] Se transformo 'datos[datos == $val] <- NA' en bucle seguro sobre indicadores" -ForegroundColor Green



} elseif ($rawScript -notmatch "(?:==|%in%)\s*(?:c\s*\(\s*)?$val\b") {



$injectedLines.Add($recodeBlock.TrimEnd())



Write-Host "[ALINEACION DE FALTANTES] Inyectando bucle de faltantes general ($val -> NA) en $($validObs.Count) indicadores" -ForegroundColor Green



}



}



}



}



}



}



if ($injectedLines.Count -gt 0) {



$blockToInsert = ($injectedLines -join "`r`n") + "`r`n`r`n"



if ($rawScript -match '(?m)^#\s*Invers|datos\$\w+\s*<-\s*max') {



$anchorReg = [regex]::new('(?m)(^#\s*Invers|datos\$\w+\s*<-\s*max)')



$rawScript = $anchorReg.Replace($rawScript, "$blockToInsert`$1", 1)



} elseif ($rawScript -match '(?m)^#\s*Definici|modelo\s*<-') {



$anchorReg = [regex]::new('(?m)(^#\s*Definici|modelo\s*<-)')



$rawScript = $anchorReg.Replace($rawScript, "$blockToInsert`$1", 1)



} else {



$rawScript = [regex]::Replace($rawScript, '(?m)(datos\s*<-\s*read[^\r\n]+\r?\n)', "`$1`r`n$blockToInsert", 1)



}



}



}



# Blindaje de sintaxis tibble: corregir datos[datos$VAR == ...] o datos["VAR"][datos["VAR"] ...] a datos[["VAR"]][...]



$badSingleBracketPattern = '(?m)^\s*datos\[\s*["'']([a-zA-Z0-9_\.]+)["'']\s*\]\s*\[\s*datos\[\s*["'']\1["'']\s*\]\s*([^\]]+)\]\s*<-\s*NA'



if ($rawScript -match $badSingleBracketPattern) {



$rawScript = [regex]::Replace($rawScript, $badSingleBracketPattern, 'datos[["$1"]][datos[["$1"]] $2] <- NA')



Write-Host "[ALINEACION DE FALTANTES] Se normalizo indexacion de un corchete datos['VAR'] a doble corchete datos[['VAR']] (compatible con tibble)" -ForegroundColor Green



}



$badTibblePattern = '(?m)^\s*datos\s*\[\s*datos\$([a-zA-Z0-9_\.]+)\s*==([^\]]+)\]\s*<-\s*NA'



if ($rawScript -match $badTibblePattern) {



$evaluator = [System.Text.RegularExpressions.MatchEvaluator]{



param($m)



$v = $m.Groups[1].Value



$c = $m.Groups[2].Value



return "datos`$$v[datos`$$v ==$c] <- NA"



}



$rawScript = [regex]::Replace($rawScript, $badTibblePattern, $evaluator)



Write-Host "[ALINEACION DE FALTANTES] Se corrigio indexacion de tibble 'datos[datos`$VAR ...]' a 'datos`$VAR[datos`$VAR ...] <- NA'" -ForegroundColor Green



}



# Mecanica universal de filtrado de categorias y covariables exogenas (sin listas de nombres):



# 1. Identificar factores latentes ('=~'), indicadores de medicion ('=~') y predictores exogenos observados ('~')



$lavFactors = @([regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_\.]+)\s*=~') | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -Unique)



$lavIndicators = [System.Collections.Generic.List[string]]::new()



foreach ($mInd in [regex]::Matches($rawScript, '(?m)^\s*[a-zA-Z0-9_\.]+\s*=~\s*([^#\r\n]+)')) {



foreach ($part in ($mInd.Groups[1].Value -split '\+')) {



$vClean = ($part -replace '^.*\*', '').Trim()



if ($vClean -match '^[a-zA-Z][a-zA-Z0-9_\.]*$' -and $lavFactors -notcontains $vClean -and -not $lavIndicators.Contains($vClean)) {



$lavIndicators.Add($vClean)



}



}



}



$lavEndog = @([regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_\.]+)\s*~\s*(?!=)') | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -Unique)



$lavExogenous = [System.Collections.Generic.List[string]]::new()



foreach ($mReg in [regex]::Matches($rawScript, '(?m)^\s*[a-zA-Z0-9_\.]+\s*~\s*(?!=)([^#\r\n]+)')) {



foreach ($part in ($mReg.Groups[1].Value -split '\+')) {



$vClean = ($part -replace '^.*\*', '').Trim()



if ($vClean -match '^[a-zA-Z][a-zA-Z0-9_\.]*$' -and $lavFactors -notcontains $vClean -and $lavEndog -notcontains $vClean -and -not $lavIndicators.Contains($vClean) -and -not $lavExogenous.Contains($vClean)) {



$lavExogenous.Add($vClean)



}



}



}



# 2. Si hay filtrado de categorias expresado como '!datos[[VAR]] %in% c(...) <- NA' sobre una variable que NO es indicador de un factor (=~),



# convertirlo a filtrado directo de filas: datos <- datos[datos[['VAR']] %in% c(...), ]



# Semantica acordada: para variables que NO son indicadores de un factor (covariables/predictores exogenos tipo GENERO)



# se eliminan las filas fuera de las categorias validas (y con NA); los indicadores de medida conservan TODAS las filas



# y es el argumento missing de lavaan (pairwise/listwise/fiml) quien las gestiona. Tolera un nivel de parentesis



# anidados en c(...) y un comentario al final de la linea.



$catNaPattern = '(?m)^[ \t]*datos(?:\[\[[''"]([a-zA-Z0-9_\.]+)[''"]\]\]|\$([a-zA-Z0-9_\.]+))\s*\[\s*!\s*datos(?:\[\[[''"](?:\1|\2)[''"]\]\]|\$(?:\1|\2))\s*%in%\s*(c\s*\((?:[^()]|\([^()]*\))+\))\s*\]\s*<-\s*NA[ \t]*(?:#[^\r\n]*)?(?=\r?$)'



if ($rawScript -match $catNaPattern) {



$rawScript = [regex]::Replace($rawScript, $catNaPattern, {



param($m)



$vName = if ($m.Groups[1].Success -and $m.Groups[1].Value) { $m.Groups[1].Value } else { $m.Groups[2].Value }



$cExpr = $m.Groups[3].Value



if (-not $lavIndicators.Contains($vName)) {



Write-Host "[MECANICA DE FILTRADO] Se convirtio asignacion NA de categorias en '$vName' a filtrado directo de filas: datos <- datos[datos[['$vName']] %in% $cExpr, ]" -ForegroundColor Green



return "datos <- datos[datos[['$vName']] %in% $cExpr, ]"



}



return $m.Value



})



}



# 3. Si un predictor exogeno observado en lavaan (~) tuvo recodificacion puntual a NA (ej. == 9 <- NA),



# asegurar que se filtren sus NAs antes de sem()/cfa() para que lavaan no cree categorias vacias al aplicar fixed.x = TRUE



foreach ($exoCol in $lavExogenous) {



$exoEsc = [regex]::Escape($exoCol)



$patNaExo = '(?m)datos(?:\[\[[''"]?' + $exoEsc + '[''"]?\]\]|\$' + $exoEsc + ')\s*\[(?:[^\[\]]|\[\[[^\]]*\]\]|\[[^\]]*\])+\]\s*<-\s*NA'



$patFiltExo = '!is\.na\s*\(\s*datos(?:\[\[[''"]?' + $exoEsc + '[''"]?\]\]|\$' + $exoEsc + ')\s*\)|datos\s*\[\s*datos(?:\[\[[''"]?' + $exoEsc + '[''"]?\]\]|\$' + $exoEsc + ')\s*%in%'



$hasNaRecodeOnExo = ($rawScript -match $patNaExo)



$hasRowFilterOnExo = ($rawScript -match $patFiltExo)



if ($hasNaRecodeOnExo -and -not $hasRowFilterOnExo) {



$filterExoLine = "datos <- datos[!is.na(datos[['$exoCol']]), ]"



# Covariables exogenas: se eliminan las filas con NA ANTES de sem()/cfa() (evita el colapso de WLSMV/MLR).



# Los indicadores de medida NO se filtran: lavaan los gestiona con su argumento missing.



$filterInserted = $true



if ($rawScript -match '(?m)^(\s*(?:modelo|model)\w*\s*<-)') {



$rawScript = [regex]::Replace($rawScript, '(?m)^(\s*(?:modelo|model)\w*\s*<-)', "$filterExoLine`r`n`$1", 1)



} elseif ($rawScript -match '(?m)^(\s*(?:fit|ajuste)\w*\s*<-\s*(?:sem|cfa)\b)') {



$rawScript = [regex]::Replace($rawScript, '(?m)^(\s*(?:fit|ajuste)\w*\s*<-\s*(?:sem|cfa)\b)', "$filterExoLine`r`n`$1", 1)



} elseif ($rawScript -match '(?m)^([^#\r\n]*\b(?:sem|cfa|lavaan)\s*\()') {



$rawScript = [regex]::Replace($rawScript, '(?m)^([^#\r\n]*\b(?:sem|cfa|lavaan)\s*\()', "$filterExoLine`r`n`$1", 1)



} else {



$filterInserted = $false



}



if ($filterInserted) {



Write-Host "[MECANICA DE FILTRADO] Se agrego '$filterExoLine' para predictor exogeno '$exoCol' recodificado a NA" -ForegroundColor Green



} else {



Write-Host "[AVISO] No se encontro donde insertar el filtro de NA para el predictor exogeno '$exoCol' (sin llamada a sem()/cfa()/lavaan())" -ForegroundColor Yellow



}



}



}



# 4. Blindaje contra funcion inexistente stdLoadings() en lavaan:



if ($rawScript -match '\bstdLoadings\s*\(\s*([a-zA-Z0-9_\.]+)\s*\)') {



$rawScript = [regex]::Replace($rawScript, '\bstdLoadings\s*\(\s*([a-zA-Z0-9_\.]+)\s*\)', 'subset(parameterEstimates($1, standardized = TRUE), op == "=~", select = c("lhs", "op", "rhs", "est", "se", "z", "pvalue", "std.all"))')



Write-Host "[ALINEACION LAVAAN] Se reemplazo funcion inexistente 'stdLoadings()' por 'subset(parameterEstimates(..., standardized = TRUE), op == `"=~`")'" -ForegroundColor Green



}



# Blindaje de regresiones directas (polr vs glm binomial):



# 1. Identificar si hay una regresion directa en el script (glm o polr) y su variable dependiente



$regDepVar = $null



$regIsPolr = $false



$regIsGlm = $false



if ($rawScript -match '\bpolr\s*\(\s*(?:(?:as\.factor|factor|ordered)\s*\(\s*([a-zA-Z0-9_\.]+)[^~]*\)|([a-zA-Z0-9_\.]+))\s*~') {
            $regDepVar = if ($matches[1]) { $matches[1] } else { $matches[2] }



$regIsPolr = $true



} elseif ($rawScript -match '\bglm\s*\(\s*(?:as\.factor\s*\(\s*|factor\s*\(\s*|ordered\s*\(\s*)?([a-zA-Z0-9_\.]+)\s*~[^)]*family\s*=\s*binomial') {



$regDepVar = $matches[1]



$regIsGlm = $true



}



# Determinar empiricamente si la variable dependiente es BINARIA (2 niveles observados):



$isBinaryDep = $false



$binLevels = @()



if ($regDepVar) {



if (Test-Path "workspace/dataset_profile.json") {



try {



$prof = Get-Content "workspace/dataset_profile.json" -Raw -Encoding UTF8 | ConvertFrom-Json



$colObj = $null



if ($prof.columnas) {



foreach ($p in $prof.columnas.PSObject.Properties) {



if ($p.Name -ieq $regDepVar -or ($p.Name -replace '_', ' ') -ieq ($regDepVar -replace '_', ' ') -or ($p.Name -replace '[ _]', '') -ieq ($regDepVar -replace '[ _]', '')) {



$colObj = $p.Value



break



}



}



}



if ($colObj) {



$vals = @($colObj.valores_detectados)



$naValsToDrop = [System.Collections.Generic.List[int]]::new()



$uGoalNorm = if ($rawUserGoalCheck) { $rawUserGoalCheck.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', '' } else { "" }



$escVar = [regex]::Escape($regDepVar) -replace '_', '[ _]'



$targetPats = @(



"(?i)(?:ante\s+)?(?:los\s+|el\s+)?(?:valores?|c[oó]digos?)\s+([0-9\s,yye\-]+)\s+(?:en|de)\s+(?:la\s+variable\s+)?$escVar\b",



"(?i)(?:en|de)\s+(?:la\s+variable\s+)?$escVar\b[^,.]*?(?:(?:los\s+|el\s+)?(?:valores?|c[oó]digos?))\s+([0-9\s,yye\-]+)"



)



$foundSpecific = $false



foreach ($tp in $targetPats) {



$tMatches = [regex]::Matches($uGoalNorm, $tp)



foreach ($tm in $tMatches) {



$numMatches = [regex]::Matches($tm.Groups[1].Value, '\b\d+\b')



foreach ($nm in $numMatches) {



$vInt = [int]$nm.Value



if (-not $naValsToDrop.Contains($vInt)) {



$naValsToDrop.Add($vInt)



$foundSpecific = $true



}



}



}



}



if (-not $foundSpecific) {



if (![string]::IsNullOrWhiteSpace($missVal)) {



$naValsToDrop.Add([int]$missVal)



}



$gPats = @(



'(?i)(?:(?:ante\s+)?(?:los\s+|el\s+)?(?:valores?|c[oó]digos?))\s+([0-9\s,yye\-]+)\s+(?:como|a)\s+(?:datos?\s+)?(?:faltantes?|perdidos?|na|ausentes?)',



'(?i)(?:tomar|tratar|considerar|recodificar)\s*(?:(?:los\s+|el\s+)?(?:valores?|c[oó]digos?)\s+)?([0-9\s,yye\-]+)\s*(?:como|a)\s*(?:datos?\s+)?(?:faltantes?|perdidos?|na|ausentes?)'



)



foreach ($gp in $gPats) {



$gMatches = [regex]::Matches($uGoalNorm, $gp)



foreach ($gm in $gMatches) {



$numMatches = [regex]::Matches($gm.Groups[1].Value, '\b\d+\b')



foreach ($nm in $numMatches) {



$vInt = [int]$nm.Value



if (-not $naValsToDrop.Contains($vInt)) { $naValsToDrop.Add($vInt) }



}



}



}



}



foreach ($dVal in $naValsToDrop) {

                            $vals = $vals | Where-Object { $_ -ne $dVal }

                        }



# Si la variable dependiente fue filtrada en el script a categorias especificas:

                        $escDepCol = [regex]::Escape($regDepVar)

                        $depFiltPat = '(?i)' + $escDepCol + '[\]\x27\"]*\s*%in%\s*c\(([^)]+)\)'

                        if ($rawScript -match $depFiltPat) {

                            $allowedDepCats = @($matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") })

                            $vals = @($vals | Where-Object { "$_" -in $allowedDepCats })

                        }



if ($vals.Count -le 2 -and $vals.Count -gt 0) {

                            $isBinaryDep = $true

                            $binLevels = @($vals | ForEach-Object { "$_" })

                        } else {

                            $isBinaryDep = $false

                        }



}



} catch {}



}



}



# Si no se pudo determinar por el perfilador, recurrir a la declaracion del usuario:

        if ($isBinaryDep -eq $false -and ($colObj -eq $null)) {

            $uGoalNorm = if ($rawUserGoalCheck) { $rawUserGoalCheck.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', '' } else { "" }

            if ($uGoalNorm -match '(?i)\bbinari[ao]\b') {

                $isBinaryDep = $true

            }

        }

        # Blindaje de creacion de factores ordenados con columnas no inicializadas (ej. datos$I3_factor <- factor(datos$I3_factor)):



$badFactorAssign = '(?m)^\s*(?:[a-zA-Z0-9_]+_factor\s*<-\s*factor\([^)]+\)\s*\r?\n)?\s*datos\$([a-zA-Z0-9_]+)_factor\s*<-\s*factor\(\s*datos\$\1_factor[^)]*\)\s*\r?\n?'



if ($rawScript -match $badFactorAssign) {



$colName = $matches[1]



$rawScript = [regex]::Replace($rawScript, $badFactorAssign, "datos`$$colName <- factor(datos`$$colName, ordered = TRUE)`r`n")



Write-Host "[ALINEACION R] Se corrigio asignacion recursiva sobre columna no inicializada: datos`$$colName <- factor(datos`$$colName, ordered = TRUE)" -ForegroundColor Green



}



# CASO 1: Si la variable dependiente es BINARIA pero el script uso polr():



# polr() en MASS requiere OBLIGATORIAMENTE 3 o mas niveles ('response must have 3 or more levels').



# Para variables binarias DEBE usarse glm(..., family = binomial).



if ($isBinaryDep -and $regIsPolr) {



$polrCallPattern = '\bpolr\s*\(((?:[^()]|\([^()]*\))*)\)'



if ($rawScript -match $polrCallPattern) {



$fullPolrCall = $matches[0]



$inside = $matches[1]



if ($inside -match '^\s*([^~,]+)\s*~\s*([^,]+)\s*,\s*(?:data\s*=\s*)?([a-zA-Z0-9_\.]+)') {



$dep = $matches[1].Trim()



$preds = $matches[2].Trim()



$dat = $matches[3].Trim()



$isProbit = ($rawUserGoalCheck -match '(?i)probit') -or ($inside -match 'method\s*=\s*["'']probit["'']')



$familyStr = if ($isProbit) { 'binomial(link = "probit")' } else { 'binomial' }



$newCall = "glm($dep ~ $preds, data = $dat, family = $familyStr, na.action = na.omit)"



$rawScript = $rawScript.Replace($fullPolrCall, $newCall)



Write-Host "[ALINEACION ESTADISTICA] Se corrigio polr() a glm(family=$familyStr) ya que '$dep' es binaria (polr requiere 3+ niveles)" -ForegroundColor Green



$regIsPolr = $false



$regIsGlm = $true



}



}



}



# CASO 2: Si el usuario solicito expresamente un modelo ORDINAL/ORDENADO, la variable NO es binaria (tiene 3+ niveles),



# pero el script uso glm(family = binomial):



# glm colapsa arbitrariamente los niveles superiores a 0 y 1. Se debe redirigir a polr() de MASS.



$isOrdinalExplicitlyRequested = ($rawUserGoalCheck -match '(?i)(?:ordenad[oa]|ordinal)') -and (-not $isBinaryDep)



if ($isOrdinalExplicitlyRequested -and $regIsGlm) {



$glmCallPattern = '\bglm\s*\(((?:[^()]|\([^()]*\))*)\)'



if ($rawScript -match $glmCallPattern) {



$fullGlmCall = $matches[0]



$inside = $matches[1]



if ($inside -match '^\s*([^~,]+)\s*~\s*([^,]+)\s*,\s*(?:data\s*=\s*)?([a-zA-Z0-9_\.]+)') {



$dep = $matches[1].Trim()



$preds = $matches[2].Trim()



$dat = $matches[3].Trim()



$isProbit = ($rawUserGoalCheck -match '(?i)probit') -or ($inside -match 'link\s*=\s*["'']probit["'']')



$methodStr = if ($isProbit) { "probit" } else { "logistic" }



$newCall = "polr($dep ~ $preds, data = $dat, method = '$methodStr')"



$rawScript = $rawScript.Replace($fullGlmCall, $newCall)



if ($rawScript -notmatch 'library\s*\(\s*MASS\s*\)') {



$rawScript = "library(MASS)`r`n" + $rawScript



}



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio glm(family=binomial) a polr(method='$methodStr') para modelo ordenado sobre '$dep'" -ForegroundColor Green



$regIsPolr = $true



$regIsGlm = $false



}



}



}



# Si el modelo resultante es glm(), asegurar que las referencias a coeficientes



# usen columnas validas de glm ("Estimate", "z value") en vez de las de polr ("Value", "t value").



if ($regIsGlm) {



if ($rawScript -match '\[([^\]]*?),\s*[''"]Value[''"]\s*\]') {



$rawScript = [regex]::Replace($rawScript, '\[([^\]]*?),\s*[''"]Value[''"]\s*\]', '[$1, "Estimate"]')



Write-Host "[ALINEACION SINTACTICA] Se corrigio indice de columna 'Value' a 'Estimate' para glm()" -ForegroundColor Green



}



if ($rawScript -match '\[([^\]]*?),\s*[''"]t value[''"]\s*\]') {



$rawScript = [regex]::Replace($rawScript, '\[([^\]]*?),\s*[''"]t value[''"]\s*\]', '[$1, "z value"]')



Write-Host "[ALINEACION SINTACTICA] Se corrigio indice de columna 't value' a 'z value' para glm()" -ForegroundColor Green



}



}

        if ($regIsPolr -or ($rawScript -match '\bpolr\s*\(')) {

            if ($rawScript -match '\[([^\]]*?),\s*[''"]Estimate[''"]\s*\]') {

                $rawScript = [regex]::Replace($rawScript, '\[([^\]]*?),\s*[''"]Estimate[''"]\s*\]', '[$1, "Value"]')

                Write-Host "[ALINEACION SINTACTICA] Se corrigio indice de columna 'Estimate' a 'Value' para polr()" -ForegroundColor Green

            }

            if ($rawScript -match '\[([^\]]*?),\s*[''"]z value[''"]\s*\]') {

                $rawScript = [regex]::Replace($rawScript, '\[([^\]]*?),\s*[''"]z value[''"]\s*\]', '[$1, "t value"]')

                Write-Host "[ALINEACION SINTACTICA] Se corrigio indice de columna 'z value' a 't value' para polr()" -ForegroundColor Green

            }

        }



# Limpieza preventiva: Eliminar conversiones globales a factor generadas por la IA.



# Estas mutan el dataframe permanentemente y rompen la asuncion continua de la variable para modelos posteriores.



# Nuestro sistema inyecta estas conversiones "al vuelo" (inline) en la formula de cada funcion estadistica.



$factorMutPattern = '(?m)^\s*datos(?:\[\[[''"][a-zA-Z0-9_\.]+[''"]\]\]|\$[a-zA-Z0-9_\.]+)\s*<-\s*(?:as\.)?(?:factor|ordered)\b[^\r\n]*\r?\n?'



if ($rawScript -match $factorMutPattern) {



$rawScript = [regex]::Replace($rawScript, $factorMutPattern, '')



Write-Host "[ALINEACION PSICOMETRICA] Se purgaron conversiones globales a factor para evitar corromper predictores en modelos sucesivos" -ForegroundColor Green



}



# Blindaje defensivo de libreria MASS para polr()



if ($rawScript -match '\bpolr\s*\(' -and $rawScript -notmatch 'library\s*\(\s*MASS\s*\)') {



$rawScript = "library(MASS)`r`n" + $rawScript



Write-Host "[BLINDAJE DEFENSIVO] Se agrego library(MASS) requerido por polr()" -ForegroundColor Green



}



# Blindaje defensivo de tipos para polr(): la variable dependiente debe ser factor ordenado



# Se usa negative lookahead para afectar a todas las llamadas que no esten ya convertidas



$polrPattern = '\bpolr\s*\(\s*(?!factor|as\.factor|ordered)([a-zA-Z0-9_\.]+)\s*~'



if ($rawScript -match $polrPattern) {



$rawScript = [regex]::Replace($rawScript, $polrPattern, 'polr(factor($1, ordered = TRUE) ~')



Write-Host "[BLINDAJE DEFENSIVO] Se convirtieron variables dependientes a factor ordenado requerido por polr() en la formula" -ForegroundColor Green



}



# Blindaje contra alucinacion de funcion de enlace en polr():



# Red de seguridad: si el usuario pidio "logistica ordinal" en su texto, forzar method='logistic'.



# Esto cubre tanto errores del prompt_builder como alucinaciones de la IA.



if ($rawUserGoalCheck -match '(?i)log[ií]stic[oa]' -and $rawScript -match "method\s*=\s*['""]probit['""]" -and $rawScript -match '\bpolr\s*\(') {



$rawScript = $rawScript -replace "(?<=\bpolr\s*\([^;]*)method\s*=\s*['""]probit['""]", "method = 'logistic'"



Write-Host "[ALINEACION ESTADISTICA] Se corrigio el enlace en polr() a 'logistic' (solicitado por el usuario), revirtiendo 'probit'" -ForegroundColor Green



}



# Blindaje defensivo de tipos para glm(family = binomial): asegurar factor si la variable dependiente no ha sido convertida



$glmPattern = '\bglm\s*\(\s*(?!factor|as\.factor|as\.numeric|ordered)([a-zA-Z0-9_\.]+)\s*~([^)]*family\s*=\s*binomial)'



if ($rawScript -match $glmPattern) {



$rawScript = [regex]::Replace($rawScript, $glmPattern, 'glm(factor($1) ~$2')



Write-Host "[BLINDAJE DEFENSIVO] Se estandarizaron variables dependientes a factor para glm(family=binomial) en la formula" -ForegroundColor Green



}



# Blindaje para fa.parallel(): la IA suele inventar argumentos que no existen en psych.



# Argumentos invalidos comunes: fa.parallel="fa", rotate="oblimin", n.iter no existe en algunas versiones



# La firma correcta es: fa.parallel(x, n.obs=, fa="fa", fm="pa")



if ($rawScript -match 'fa\.parallel\s*\(') {



# Eliminar argumento 'fa.parallel =' (confunde el nombre de la funcion con un parametro)



$rawScript = [regex]::Replace($rawScript, '(?<=fa\.parallel\s*\([^)]*),\s*fa\.parallel\s*=\s*["\u0027][^"\u0027]*["\u0027]', '')



# Eliminar argumento 'rotate =' (no existe en fa.parallel)



$rawScript = [regex]::Replace($rawScript, '(?<=fa\.parallel\s*\([^)]*),\s*rotate\s*=\s*["\u0027][^"\u0027]*["\u0027]', '')



# Limpiar comas dobles residuales



$rawScript = [regex]::Replace($rawScript, ',\s*,', ',')



$rawScript = [regex]::Replace($rawScript, '\(\s*,', '(')



Write-Host "[BLINDAJE DEFENSIVO] Se limpiaron argumentos invalidos de fa.parallel() (fa.parallel=, rotate=)" -ForegroundColor Green



}



# Blindaje contra limpieza destructiva de la variable dependiente BINARIA en glm() (generalizado: antes solo actuaba



# sobre una variable llamada COBERTURA con niveles 1/2). Si el script anula con NA justo los DOS niveles validos



# (datos$VD[datos$VD == a] <- NA ; datos$VD[datos$VD == b] <- NA, o VD %in% c(a, b)), se reescribe como



# datos$VD[!datos$VD %in% c(a, b)] <- NA, conservando los niveles validos y anulando solo el resto.



if ($regIsGlm -and $regDepVar -and $binLevels.Count -eq 2) {



$fixedDep = Repair-DestructiveDepClean -Script $rawScript -Var $regDepVar -Vals $binLevels



if ($fixedDep -ne $rawScript) {



$rawScript = $fixedDep



Write-Host "[BLINDAJE DEFENSIVO] Se corrigio limpieza destructiva de '$regDepVar': ahora preserva los niveles validos ($($binLevels -join ', ')) y anula solo el resto" -ForegroundColor Green



}



}



# Blindaje contra uso invalido de coef() en lavaan (type = "std", se = TRUE, indexacion):



$invalidCoefPat = '(?m)coef\s*\(\s*([a-zA-Z0-9_\.]+)\s*,\s*[^)]*(?:type\s*=\s*["'']std["'']|se\s*=\s*TRUE|z\.test\s*=\s*TRUE)[^)]*\)(?:\s*\[[^\]]+\])*'



if ($rawScript -match $invalidCoefPat) {



$rawScript = [regex]::Replace($rawScript, $invalidCoefPat, 'subset(parameterEstimates($1, standardized = TRUE), op == "~")')



Write-Host "[ALINEACION SINTAXIS] Se sustituyo 'coef(..., type=""std"")' por 'subset(parameterEstimates(..., standardized = TRUE), op == ""~"")'" -ForegroundColor Green



}



# Asegurar emision en consola de llamadas de reporte clave si estan sueltas sin print()



$nakedReportPat = '(?m)^\s*(?!(?:print|cat|tryCatch)\b)\s*((?:summary|fitMeasures|parameterEstimates|modindices)\s*\([^\r\n]*\)(?:\s*(?:\|>|%>%).*)?)\s*$'



if ($rawScript -match $nakedReportPat) {



$rawScript = [regex]::Replace($rawScript, $nakedReportPat, 'print($1)')



}



# Blindaje de direccion causal de senderos en SEM:



# El principio matematico universal es: Destino ~ Origen (el elemento señalado por '->' va a la izquierda del tilde).



# Aplica universalmente a Factor->Factor, Factor->Variable, Variable->Factor, Variable->Variable.



$arrowDirectives = @()



if (Get-Command Get-ArrowDirectives -ErrorAction SilentlyContinue) {



$arrowDirectives = @(Get-ArrowDirectives -UserPrompt $rawUserGoalCheck)



}



foreach ($ad in $arrowDirectives) {



$dest = $ad.Destino



$origs = $ad.Origenes



# Validacion defensiva: los identificadores deben ser validos y no vacios



if ([string]::IsNullOrWhiteSpace($dest) -or $dest -notmatch '^[a-zA-Z][a-zA-Z0-9_]*$') { continue }



$invalidOrig = $origs | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -notmatch '^[a-zA-Z][a-zA-Z0-9_]*$' }



if ($invalidOrig) { continue }



$origsClean = ($origs -join " + ")



$canonicalLavaan = "$dest ~ $origsClean"



# Caso A: Flecha literal en el script R (ej. "Origen -> Destino" o "A + B -> C")



foreach ($orig in $origs) {



$literalArrowPat = "(?m)^\s*" + [regex]::Escape($orig) + "\s*->\s*" + [regex]::Escape($dest) + "(?:\s*#.*)?\s*$"



if ($rawScript -match $literalArrowPat) {



$rawScript = [regex]::Replace($rawScript, $literalArrowPat, "  $canonicalLavaan")



Write-Host "[ALINEACION SEM] Se tradujo flecha literal '$orig -> $dest' a '$canonicalLavaan'" -ForegroundColor Green



}



}



# Caso B: Sendero causal invertido en sintaxis de lavaan (ej. "Origen ~ Destino")



foreach ($orig in $origs) {



# Si el modelo es deliberadamente no recursivo (reciproco A -> B y B -> A), no es una inversion



$isReciprocal = $false



if ($arrowDirectives) {



$recipDir = $arrowDirectives | Where-Object { $_.Destino -eq $orig -and $_.Origenes -contains $dest }



if ($recipDir) { $isReciprocal = $true }



}



if (-not $isReciprocal) {



$invertedPattern = "(?m)^\s*" + [regex]::Escape($orig) + "\s*~\s*[^#\r\n]*\b" + [regex]::Escape($dest) + "\b(?:\s*#.*)?\s*$"



if ($rawScript -match $invertedPattern) {



$rawScript = [regex]::Replace($rawScript, $invertedPattern, "  $canonicalLavaan")



Write-Host "[ALINEACION SEM] Se corrigio sendero causal invertido ('$orig ~ $dest') a la direccion canonica '$canonicalLavaan'" -ForegroundColor Green



}



}



}



# Caso C: Verificar si el sendero ya esta presente en el modelo lavaan (como regresion '~' o carga factorial '=~')



$pathExists = $true



foreach ($orig in $origs) {



$hasRegPath = ($rawScript -match "(?m)^\s*" + [regex]::Escape($dest) + "\s*~[^#\r\n]*\b" + [regex]::Escape($orig) + "\b")



$hasLoadPath = ($rawScript -match "(?m)^\s*" + [regex]::Escape($orig) + "\s*=~[^#\r\n]*\b" + [regex]::Escape($dest) + "\b")



if (-not ($hasRegPath -or $hasLoadPath)) { $pathExists = $false; break }



}



if (-not $pathExists) {



# Solo incorporar si tanto destino como origenes existen en el script como variables o factores conocidos



$allKnown = $true



foreach ($t in @($dest) + $origs) {



if ($rawScript -notmatch "\b" + [regex]::Escape($t) + "\b") {



$allKnown = $false



break



}



}



if ($allKnown) {



$modelBlockPat = "(?s)(modelo\s*<-\s*['""][^'""]+)(['""])"



if ($rawScript -match $modelBlockPat) {



$rawScript = [regex]::Replace($rawScript, $modelBlockPat, "`$1  $canonicalLavaan`r`n`$2", 1)



Write-Host "[ALINEACION SEM] Se incorporo sendero faltante al modelo: '$canonicalLavaan'" -ForegroundColor Green



}



}



}



}



# Blindaje contra duplicacion de carga factorial de 2do orden ('G =~ F1 + F2') y regresion ('F1 ~ G'):



# Si el modelo ya define 'Macro =~ ... SubFactor ...' y ademas tiene 'SubFactor ~ Macro', eliminar la regresion duplicada.



$measCheckMatches = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~\s*([^#\r\n]+)')



foreach ($mm in $measCheckMatches) {



$lhsFac = $mm.Groups[1].Value.Trim()



$rhsTokens = @([regex]::Matches($mm.Groups[2].Value, '\b([a-zA-Z][a-zA-Z0-9_\.]*)\b') | ForEach-Object { $_.Groups[1].Value })



foreach ($rt in $rhsTokens) {



$dupRegPat = "(?m)^\s*" + [regex]::Escape($rt) + "\s*~\s*(?:[a-zA-Z0-9_]+\s*\*\s*)?" + [regex]::Escape($lhsFac) + "\s*(?:#.*)?\r?\n?"



if ($rawScript -match $dupRegPat) {



$rawScript = [regex]::Replace($rawScript, $dupRegPat, "")



Write-Host "[ALINEACION SEM] Se elimino regresion redundante '$rt ~ $lhsFac' porque ya esta definida como carga factorial '$lhsFac =~ $rt'" -ForegroundColor Green



}



}



}



# Caso D: Cualquier otra flecha literal no traducida en una linea de sintaxis de R



$genericArrowPattern = '(?m)^\s*([a-zA-Z0-9_\.\s\+]+?)\s*->\s*([a-zA-Z0-9_\.]+)(?:\s*#.*)?\s*$'



if ($rawScript -match $genericArrowPattern) {



$rawScript = [regex]::Replace($rawScript, $genericArrowPattern, {



param($m)



$origRaw = $m.Groups[1].Value.Trim()



$dest = $m.Groups[2].Value.Trim()



$origTokens = @([regex]::Matches($origRaw, '\b([a-zA-Z0-9_\.]+)\b') | ForEach-Object { $_.Groups[1].Value })



$origClean = ($origTokens -join " + ")



Write-Host "[ALINEACION SEM] Se tradujo flecha literal residual '$origRaw -> $dest' a '$dest ~ $origClean'" -ForegroundColor Green



return "  $dest ~ $origClean"



})



}



# Blindaje de nombre de factor latente reservado 'F' (alias de FALSE en R):



# En lavaan, nombrar una variable latente como 'F' colisiona con el valor logico FALSE.



# Se sustituye por 'G' en la especificacion del modelo.



if ($rawScript -match '(?m)^\s*F\s*=~') {



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*F\s*=~', '  G =~')



Write-Host "[ALINEACION SINTAXIS] Se renombro el factor latente 'F' a 'G' para evitar colision con el identificador reservado FALSE en R" -ForegroundColor Green



}



# Blindaje de exhaustividad de variables en el argumento 'ordered' (lavaan):



# Si el usuario solicito tratar los indicadores como ordinales (con o sin excepciones continuas),



# ningun indicador observado del modelo debe quedar excluido del vector 'ordered' salvo las excepciones continuas explicitas.



if ($rawScript -match '(?i)\border\b|estimator\s*=\s*["'']WLSMV["'']' -or $rawUserGoalCheck -match '(?i)\bordinales?\b') {



# 1. Extraer factores latentes definidos con '=~'



$factorMatches = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~')



$allFactors = @($factorMatches | ForEach-Object { $_.Groups[1].Value })



# 2. Extraer todos los indicadores observados del modelo (terminos en RHS que no son factores)



$rhsMatches = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~\s*([^#\r\n]+)')



$allObserved = [System.Collections.Generic.List[string]]::new()



foreach ($rm in $rhsMatches) {



$toks = [regex]::Matches($rm.Groups[2].Value, '\b([a-zA-Z0-9_]+)\b')



foreach ($tok in $toks) {



$tVal = $tok.Groups[1].Value



if ($allFactors -notcontains $tVal -and -not $allObserved.Contains($tVal)) {



$allObserved.Add($tVal)



}



}



}



if ($allObserved.Count -gt 0) {



# 3. Detectar excepciones continuas: AUTORIDAD ABSOLUTA al asistente metodologico confirmado
$contTokens = @()
if ($userGoalCheck -match '(?i)Excepciones de tipo de variable:[^\r\n]*?:\s*([a-zA-Z0-9_,\s]+?)\.(?:\s+Usar|\r?\n|$)') {
    $rawC = $Matches[1]
    $tokensC = $rawC -split '[,;\s]+' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
    foreach ($tc in $tokensC) {
        $cleanC = $tc.Trim()
        if ($cleanC -match '^[a-zA-Z0-9_\.]+$' -and -not $contTokens.Contains($cleanC)) {
            $contTokens += $cleanC
        }
    }
    Write-Host "[WIZARD CONFIRMADO] Excepciones continuas leidas del asistente paso a paso: $($contTokens -join ', ')" -ForegroundColor Green
} elseif (Get-Command Get-ContinuousExceptions -ErrorAction SilentlyContinue) {
    $contTokens = @(Get-ContinuousExceptions -UserPrompt $userGoalCheck)
}



# 4. Determinar el vector esperado de ordinales (observados menos excepciones continuas)



$expectedOrdinals = @($allObserved | Where-Object { $contTokens -notcontains $_ })



# 5. Auditar y corregir ordered_vars <- c(...) si existe



$ordVarsPat = '(?m)^\s*ordered_vars\s*<-\s*c\s*\(([^)]+)\)'



if ($rawScript -match $ordVarsPat) {



$currInside = $Matches[1]



$currItems = @([regex]::Matches($currInside, '\b([a-zA-Z0-9_]+)\b') | ForEach-Object { $_.Groups[1].Value })



$missingItems = @($expectedOrdinals | Where-Object { $currItems -notcontains $_ })



$duplicateItems = @($currItems | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })



$unexpectedItems = @($currItems | Where-Object { $expectedOrdinals -notcontains $_ })



if ($missingItems.Count -gt 0 -or $duplicateItems.Count -gt 0 -or $unexpectedItems.Count -gt 0) {



$newOrdStr = 'ordered_vars <- c(' + (($expectedOrdinals | ForEach-Object { "`"$_`"" }) -join ', ') + ')'



$rawScript = [regex]::Replace($rawScript, $ordVarsPat, $newOrdStr)



Write-Host "[ALINEACION ORDINAL] Se normalizo 'ordered_vars': $($expectedOrdinals.Count) ordinales declarados. Excluidas continuas: $($contTokens -join ', ')" -ForegroundColor Green



}



}



# 6. Auditar y corregir el argumento ordered = c(...) en sem() / cfa() si existe



$orderedPattern = '(?i)ordered\s*=\s*c\s*\(([^)]+)\)'



if ($rawScript -match $orderedPattern) {



$currInside = $Matches[1]



$currItems = @([regex]::Matches($currInside, '\b([a-zA-Z0-9_]+)\b') | ForEach-Object { $_.Groups[1].Value })



$missingItems = @($expectedOrdinals | Where-Object { $currItems -notcontains $_ })



$duplicateItems = @($currItems | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })



$unexpectedItems = @($currItems | Where-Object { $expectedOrdinals -notcontains $_ })



$hasUnquoted = ($currInside -match '(?<!["''])\b([a-zA-Z0-9_]+)\b(?!["''])')



if ($missingItems.Count -gt 0 -or $duplicateItems.Count -gt 0 -or $unexpectedItems.Count -gt 0 -or $hasUnquoted) {



$targetOrdinals = if ($expectedOrdinals.Count -gt 0) { $expectedOrdinals } else { $currItems }



$newOrderedStr = 'ordered = c(' + (($targetOrdinals | ForEach-Object { "`"$_`"" }) -join ', ') + ')'



$rawScript = [regex]::Replace($rawScript, $orderedPattern, $newOrderedStr)



Write-Host "[ALINEACION ORDINAL] Se normalizo argumento 'ordered = c(...)'. Excluidas continuas: $($contTokens -join ', ')" -ForegroundColor Green



}



}



}



# 7. Blindaje de 'ordered = TRUE' o 'ordered = names(datos)': reemplazar por vector explicito de indicadores



# ordered = TRUE / names(datos) hace que lavaan trate TODAS las columnas del data.frame como ordinales,



# incluyendo covariables continuas como EDAD. Se reemplaza por el vector especifico.



$orderedTruePat = '(?i)ordered\s*=\s*(?:TRUE|names\s*\(\s*[a-zA-Z0-9_\.]+\s*\)|colnames\s*\(\s*[a-zA-Z0-9_\.]+\s*\))'



if ($rawScript -match $orderedTruePat -and $expectedOrdinals.Count -gt 0) {



$newOrderedStr = 'ordered = c(' + (($expectedOrdinals | ForEach-Object { "`"$_`"" }) -join ', ') + ')'



$rawScript = [regex]::Replace($rawScript, $orderedTruePat, $newOrderedStr)



Write-Host "[ALINEACION ORDINAL] Se reemplazo 'ordered = TRUE / names(datos)' por vector explicito de $($expectedOrdinals.Count) indicadores ordinales" -ForegroundColor Green



}



# 8. Si el LLM escribio erroneamente 'ordered <- c(...)' dentro del string del modelo lavaan, extraerlo y pasarlo a sem()/cfa()



$inModelOrdPat = '(?m)^[ \t]*ordered\s*<-\s*c\s*\([^)]+\)[ \t]*\r?\n?'



if ($rawScript -match $inModelOrdPat -and $expectedOrdinals.Count -gt 0) {



$rawScript = [regex]::Replace($rawScript, $inModelOrdPat, '')



if ($rawScript -notmatch '(?i)ordered\s*=') {



$newOrderedStr = 'ordered = c(' + (($expectedOrdinals | ForEach-Object { "`"$_`"" }) -join ', ') + ')'



$rawScript = [regex]::Replace($rawScript, '(?i)(estimator\s*=\s*["''](?:WLSMV|DWLS|ULS|ULSMV)["''])', "`$1, $newOrderedStr")



}



Write-Host "[ALINEACION ORDINAL] Se reubico 'ordered = c(...)' desde el string del modelo hacia los argumentos de lavaan" -ForegroundColor Green



}



}



# Blindaje de modelos jerarquicos de orden superior / segundo orden:



$isHigherOrder = $false



$higherOrderFactor = $null



$factorMatches = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~')



$allFactors = @($factorMatches | ForEach-Object { $_.Groups[1].Value })



$rhsMatches = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~\s*([^#\r\n]+)')



foreach ($rm in $rhsMatches) {



$lhsF = $rm.Groups[1].Value



$toks = [regex]::Matches($rm.Groups[2].Value, '\b([a-zA-Z0-9_]+)\b')



foreach ($tok in $toks) {



if ($allFactors -contains $tok.Groups[1].Value -and $tok.Groups[1].Value -ne $lhsF) {



$isHigherOrder = $true



$higherOrderFactor = $lhsF



break



}



}



if ($isHigherOrder) { break }



}



# 1. En modelos de orden superior, orthogonal = TRUE anula covarianzas y colapsa la estimacion



$isBifactorOrOrthogonalRequested = $rawUserGoalCheck -match '(?i)\bbifactor\w*|\bortogonal\w*'



if ($isHigherOrder -and (-not $isBifactorOrOrthogonalRequested)) {



if ($rawScript -match 'orthogonal\s*=\s*TRUE') {



$rawScript = [regex]::Replace($rawScript, ',\s*orthogonal\s*=\s*TRUE', '')



$rawScript = [regex]::Replace($rawScript, 'orthogonal\s*=\s*TRUE\s*,?', '')



Write-Host "[ALINEACION PSICOMETRICA] Se removio 'orthogonal = TRUE' incompatible con modelo jerarquico de segundo orden" -ForegroundColor Green



}



}



# 2. Sintaxis invalida de covarianzas encadenadas '~~' (ej. F1 ~~ F2 ~~ F3... o A ~~ B ~~ C)



# En lavaan, '~~' es estrictamente binario. Encadenar tres o mas operandos colapsa con error de sintaxis.



$chainedCovPattern = '(?m)^[ \t]*[a-zA-Z0-9_\.]+[ \t]*(?:~~[ \t]*[a-zA-Z0-9_\.]+[ \t]*){2,}[ \t]*\r?\n?'



if ($rawScript -match $chainedCovPattern) {



$rawScript = [regex]::Replace($rawScript, $chainedCovPattern, '')



Write-Host "[ALINEACION PSICOMETRICA] Se removio la sintaxis invalida de encadenamiento de covarianzas '~~' (ej. F1 ~~ F2 ~~ F3...)" -ForegroundColor Green



}



# 3. En modelos de segundo orden, los factores de primer orden ya covarian a traves del factor general.



# Correlacionar los factores de primer orden entre si (F1 ~~ F2) produce redundancia e identificacion defectuosa.



if ($isHigherOrder) {



foreach ($f1 in $allFactors) {



if ($f1 -eq $higherOrderFactor) { continue }



foreach ($f2 in $allFactors) {



if ($f2 -eq $higherOrderFactor -or $f1 -eq $f2) { continue }



$spuriousCov = "(?m)^[ \t]*$f1[ \t]*~~[ \t]*$f2[ \t]*\r?\n?"



if ($rawScript -match $spuriousCov -and ($rawUserGoalCheck -notmatch "$f1\s*~~\s*$f2") -and ($rawUserGoalCheck -notmatch "$f2\s*~~\s*$f1")) {



$rawScript = [regex]::Replace($rawScript, $spuriousCov, '')



Write-Host "[ALINEACION PSICOMETRICA] Se removio correlacion redundante entre factores de primer orden '$f1 ~~ $f2' en modelo jerarquico" -ForegroundColor Green



}



}



}



}



# Blindaje de funcion ACP (Analisis de Componentes Principales):



# Si el usuario solicito ACP pero la IA uso fa() en lugar de principal(), se corrige.



if ($rawUserGoalCheck -match '(?i)componentes\s+principales|\bACP\b|\bPCA\b') {



if ($rawScript -notmatch '\bprincipal\s*\(' -and $rawScript -match '(?i)(\b(?:acp|pca|componentes)\w*\s*(?:<-|=)\s*)fa\s*\(') {



$rawScript = [regex]::Replace($rawScript, '(?i)(\b(?:acp|pca|componentes)\w*\s*(?:<-|=)\s*)fa\s*\(', '$1principal(')



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio la funcion fa() a principal() requerida por ACP" -ForegroundColor Green
        }
    }

    # Blindaje de argumento de faltantes en psych (principal() y fa()):
    # La IA frecuentemente confunde use = "pairwise" con cor = "pairwise" o cor = "pairwise.complete.obs".
    # En psych::principal y psych::fa, 'cor' define el metodo de correlacion (ej. "cor", "poly", "tet").
    # Si se pasa cor = "pairwise...", R falla fatalmente con:
    # "I am sorry: missing values (NAs) in the correlation matrix do not allow me to continue".
    # Debe ser strictly 'use = "pairwise"'.
    if ($rawScript -match '(?i)\b(?:principal|fa)\s*\(') {
        if ($rawScript -match '(?i)\b(?:principal|fa)\s*\([^)]*?\buse\s*=') {
            $rawScript = [regex]::Replace($rawScript, '(?i)(?<=\b(?:principal|fa)\s*\([^)]*),\s*cor\s*=\s*["''](?:pairwise|pairwise\.complete\.obs|complete\.obs|complete)["'']', '')
            $rawScript = [regex]::Replace($rawScript, '(?i)(?<=\b(?:principal|fa)\s*\(\s*)\bcor\s*=\s*["''](?:pairwise|pairwise\.complete\.obs|complete\.obs|complete)["'']\s*,\s*', '')
            Write-Host "[ALINEACION PSICOMETRICA] Se removio el argumento redundante/invalido 'cor = `"pairwise`"' en psych" -ForegroundColor Green
        } else {
            $rawScript = [regex]::Replace($rawScript, '(?i)(?<=\b(?:principal|fa)\s*\([^)]*)\bcor\s*=\s*["''](?:pairwise|pairwise\.complete\.obs|complete\.obs|complete)["'']', 'use = "pairwise"')
            Write-Host "[ALINEACION PSICOMETRICA] Se corrigio el argumento 'cor = `"pairwise`"' a 'use = `"pairwise`"' en psych para evitar colapso por NAs" -ForegroundColor Green
        }
    }

# Blindaje de determinacion de dimensiones en psych: nfactors = "auto" es invalido en fa() y principal().



# Se debe sustituir por el calculo dinamico de autovalores > 1 (Kaiser).



if ($rawScript -match 'nfactors\s*=\s*["'']auto["'']') {



$rawScript = [regex]::Replace($rawScript, 'nfactors\s*=\s*["'']auto["'']', 'nfactors = sum(eigen(cor(datos, use = "pairwise.complete.obs"))`$values > 1)')



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio 'nfactors = `"auto`"' calculando dinamicamente los autovalores mayores a 1 (Kaiser)" -ForegroundColor Green



}



# Blindaje de funcion n_factors() o nfactors() en psych (criterio de Kaiser):



# Si el script invoca n_factors(...) o nfactors(...), que no existen en psych ni en base R,



# inyectamos la definicion nativa de R que calcula los autovalores mayores a 1 (Kaiser).



if ($rawScript -match '\bn_factors\s*\(' -or $rawScript -match '(?<!=~\s*)\bnfactors\s*\(') {



if ($rawScript -notmatch 'n_factors\s*<-\s*function') {



$nFactorsHelper = "n_factors <- function(x, ...) sum(eigen(cor(x, use = 'pairwise.complete.obs'))`$values > 1)`r`n"



$rawScript = $nFactorsHelper + $rawScript



Write-Host "[BLINDAJE PSICOMETRICO] Se inyecto preventivamente la definicion de n_factors() (criterio de Kaiser > 1) para evitar error de funcion no encontrada" -ForegroundColor Green



}



if ($rawScript -match 'nfactors\s*=\s*nfactors\s*\(') {



$rawScript = [regex]::Replace($rawScript, 'nfactors\s*=\s*nfactors\s*\(', 'nfactors = n_factors(')



}



}



# Blindaje de extraccion de autovalores en eigen():



# eigen() devuelve una lista con $values y $vectors. Si el script escribe eigen(...) > 1 omitiendo $values,



# R colapsa con "'list' object cannot be coerced to type 'double'".



# Se asegura que se acceda a $values.



if ($rawScript -match 'eigen\s*\([^)]+\)\s*>\s*1') {



$rawScript = [regex]::Replace($rawScript, '(eigen\s*\([^)]+\))(\s*>\s*1)', '$1`$values$2')



Write-Host "[ALINEACION R] Se corrigio 'eigen(...) > 1' a 'eigen(...)$values > 1' para acceder al vector numerico de autovalores" -ForegroundColor Green



}



# Blindaje de columnas inexistentes al indexar dataframes en R (ej. paste0("I", 4:48)):



# Si el script define un vector de variables o columnas y luego indexa datos[, variables],



# pero la base tiene huecos de numeracion (items eliminados), se asegura el filtrado con intersect().



$varVecMatch = [regex]::Match($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*<-\s*(?:paste0|c)\s*\(')



if ($varVecMatch.Success) {



$varName = $varVecMatch.Groups[1].Value



if ($rawScript -match "datos\[\s*,\s*$varName\s*\]" -and $rawScript -notmatch "intersect\s*\(\s*$varName") {



$rawScript = [regex]::Replace($rawScript, "(?s)(\b$varName\s*<-\s*(?:paste0|c)\s*\([^)]*\)\s*\r?\n)", "`$1$varName <- intersect($varName, names(datos))`r`n", 1)



Write-Host "[BLINDAJE DEFENSIVO] Se agrego '$varName <- intersect($varName, names(datos))' para evitar error de columnas inexistentes en rangos" -ForegroundColor Green



}



}



# Blindaje de columnas inexistentes dentro de llamadas directas datos[, c(...)]:



if (Test-Path "workspace/dataset_profile.json") {



try {



$profData = Get-Content "workspace/dataset_profile.json" -Raw -Encoding UTF8 | ConvertFrom-Json



if ($profData.columnas) {



$realCols = @($profData.columnas.PSObject.Properties.Name)



$subPat = 'datos\[\s*,\s*c\s*\(([^\]]+)\)\s*\]'



if ($rawScript -match $subPat) {



$calledCols = [regex]::Matches($Matches[1], '["'']([a-zA-Z0-9_\.]+)["'']') | ForEach-Object { $_.Groups[1].Value }



$invalidCols = @($calledCols | Where-Object { $realCols -notcontains $_ })



if ($invalidCols.Count -gt 0) {



$validOnly = @($calledCols | Where-Object { $realCols -contains $_ })



$validColsStr = ($validOnly | ForEach-Object { "`"$_`"" }) -join ", "



$rawScript = [regex]::Replace($rawScript, 'datos\[\s*,\s*c\s*\([^\]]+\)\s*\]', "datos[, c($validColsStr)]")



Write-Host "[BLINDAJE DEFENSIVO] Se filtraron $($invalidCols.Count) columnas inexistentes de la indexacion: $($invalidCols -join ', ')" -ForegroundColor Green



}



}



}



} catch {}



}



# Blindaje de reporte para modelos exploratorios de psych (fa y principal):



# En psych, summary() no emite la tabla de cargas factoriales y devuelve NULL.



# Debe imprimirse directamente el objeto: print(fit_exploratorio)



if ($rawScript -match '(?i)\b(?:fa|principal)\s*\(') {



$rawScript = [regex]::Replace($rawScript, '(?i)(?:print\s*\(\s*)?summary\s*\(\s*([a-zA-Z0-9_]+)\s*(?:,[^)]*)?\)\s*\)?', {



param($m)



$var = $m.Groups[1].Value



Write-Host "[ALINEACION PSYCH] Se corrigio 'summary($var)' a 'print($var)' para emitir la matriz de cargas completa" -ForegroundColor Green



return "print($var)"



})



}



# Blindaje de psych::polychoric contra NAs y colapso de integracion en C (polyBinBvn):



# En bases con celdas con asimetria o frecuencias nulas, el default correct = 0.5 (Yates)



# distorsiona cumsum(rsum) > 1.0 produciendo NaNs en qnorm() y colapso en polyBinBvn.



# Es ESTRICTAMENTE OBLIGATORIO fijar correct = 0 y asegurar na.omit().



if ($rawScript -match '(?i)(?:psych::)?polychoric\s*\(') {



$rawScript = [regex]::Replace($rawScript, '(?i)\b(?:psych::)?polychoric\s*\((.*?)\)(\s*#.*)?$', {



param($m)



$inner = $m.Groups[1].Value.Trim()



$comment = $m.Groups[2].Value



if ($inner -notmatch '(?i)correct\s*=') {



$inner = "$inner, correct = 0"



} else {



$inner = [regex]::Replace($inner, '(?i)correct\s*=\s*[^,)]+', 'correct = 0')



}



if ($inner -notmatch '(?i)na\.omit') {



$inner = [regex]::Replace($inner, '^([^,]+)', 'na.omit($1)')



}



Write-Host "[ALINEACION PSYCH] Se blindo 'polychoric' inyectando 'correct = 0' y 'na.omit()' para erradicar fallo en polyBinBvn" -ForegroundColor Green



return "psych::polychoric($inner)$comment"



}, [System.Text.RegularExpressions.RegexOptions]::Multiline)



}



# Blindaje de Fornell-Larcker y calculo de AVE:



# colMeans(lam^2) colapsa con error "'x' debe ser un array de al menos dos dimensiones"



# cuando lam es un vector 1D de standardizedSolution. Se inyecta calculo canonico por factor.



if ($rawScript -match '(?i)colMeans\s*\(\s*lam(?:\^2|\s*\*\s*lam)?\s*\)' -or ($rawScript -match '(?i)colMeans' -and $rawScript -match '(?i)fornell')) {



$flReplacement = @"
# Calculo canonico y blindado de AVE por factor para Fornell-Larcker
pe_fl <- parameterEstimates(fit, standardized = TRUE)
lv_fl <- unique(pe_fl`$lhs[pe_fl`$op == "=~"])
ave <- sapply(lv_fl, function(f) mean(pe_fl`$std.all[pe_fl`$lhs == f & pe_fl`$op == "=~"]^2, na.rm = TRUE))
sqrt_ave <- sqrt(ave)
cor_lv <- lavInspect(fit, 'cor.lv')
cat("\n--- CRITERIO DE FORNELL-LARCKER ---\n")
cat("Raiz cuadrada del AVE por factor:\n"); print(sqrt_ave)
cat("Correlaciones entre variables latentes:\n"); print(cor_lv)
"@



$rawScript = [regex]::Replace($rawScript, '(?is)lam\s*<-\s*standardizedSolution[^;\n]+[;\n\s]*ave\s*<-\s*colMeans\([^)]+\)[;\n\s]*(?:sqrt_ave\s*<-\s*sqrt\(ave\)[;\n\s]*)?(?:cor_lv\s*<-\s*lavInspect\([^)]+\)[;\n\s]*)?(?:print\(sqrt_ave\)[;\n\s]*)?(?:print\(cor_lv\))?', $flReplacement)



Write-Host "[ALINEACION PSICOMETRICA] Se reemplazo calculo colMeans(lam^2) por extraccion canonica de AVE por factor para Fornell-Larcker" -ForegroundColor Green



}



# Blindaje de AVE (Average Variance Extracted):



# fitMeasures(fit, "ave") no existe en lavaan y devuelve numeric(0). El AVE se calcula NATIVO con las cargas



# estandarizadas (no con semTools::reliability(), que colapsa en 2.o orden + WLSMV + pairwise + covariables).



$avePat = '(?i)fitMeasures\s*\(\s*(\w+)\s*,\s*["'']ave["'']\s*\)'



if ($rawScript -match $avePat) {



$rawScript = [regex]::Replace($rawScript, $avePat, [System.Text.RegularExpressions.MatchEvaluator]{



param($m)



$fo = $m.Groups[1].Value



return "print({ ss_ave <- lavaan::standardizedSolution($fo); ss_ave <- ss_ave[ss_ave" + '$' + "op == '=~', ]; sapply(split(ss_ave" + '$' + "est.std, ss_ave" + '$' + "lhs), function(l) mean(l^2)) })"



})



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio la llamada invalida 'fitMeasures(fit, `"ave`")' por el AVE nativo (media de cargas estandarizadas^2 por factor)" -ForegroundColor Green



}



# (La conversion reliability() -> compRelSEM() se ELIMINO: ambas funciones colapsan en estos modelos. Toda llamada a



#  compositeRel/compRelSEM/reliability se sustituye mas abajo por el calculo NATIVO de la CR.)



# Blindaje defensivo de libreria semTools si se utilizan sus funciones



if (($rawScript -match '\bhtmt\s*\(' -or $rawScript -match '\breliability\s*\(' -or $rawScript -match '\bcompRelSEM\s*\(') -and $rawScript -notmatch 'library\s*\(\s*semTools\s*\)') {



$rawScript = "library(semTools)`r`n" + $rawScript



Write-Host "[BLINDAJE DEFENSIVO] Se agrego library(semTools) requerido para funciones psicometricas" -ForegroundColor Green



}



# Blindaje de compatibilidad estimador vs missing en lavaan:



if ($rawScript -match 'estimator\s*=\s*["'']ML(?:R)?["'']' -and $rawScript -match 'missing\s*=\s*["'']pairwise["'']') {



$rawScript = [regex]::Replace($rawScript, 'missing\s*=\s*["'']pairwise["'']', 'missing = "fiml"')



Write-Host "[ALINEACION DEFENSIVA] Se corrigio 'missing = `"pairwise`"' a 'missing = `"fiml`"' compatible con estimador ML/MLR" -ForegroundColor Green



}



if ($rawScript -match 'estimator\s*=\s*["'']WLSMV["'']' -and $rawScript -match 'missing\s*=\s*["'']fiml["'']') {



$rawScript = [regex]::Replace($rawScript, 'missing\s*=\s*["'']fiml["'']', 'missing = "pairwise"')



Write-Host "[ALINEACION DEFENSIVA] Se corrigio 'missing = `"fiml`"' a 'missing = `"pairwise`"' compatible con estimador WLSMV" -ForegroundColor Green



}

    # Blindaje deterministico para missing = "listwise" en lavaan:
    # Cuando se usa listwise con indicadores ordinales (WLSMV), si una categoria se vacia por eliminacion
    # cruzada de filas con NA, lavaan aborta en step 1. Pre-filtrar complete.cases sobre las variables del modelo
    # garantiza que lavaan reciba la muestra final limpia y estime sin error.
    if ($rawScript -match 'missing\s*=\s*["'']listwise["'']' -and $rawScript -notmatch 'complete\.cases') {
        if ($rawScript -match '(?m)^(\s*)(?:fit\w*|ajuste\w*)\s*<-\s*(?:sem|cfa|lavaan)\s*\(\s*([a-zA-Z0-9_]+)\s*,') {
            $ind = $Matches[1]
            $mv = $Matches[2]
            $cleanBlock = "${ind}# [BLINDAJE LISTWISE] Pre-filtrado deterministico de complete.cases sobre variables del modelo:`r`n" +
                          "${ind}if (exists(`"$mv`")) {`r`n" +
                          "${ind}  vars_ov_clean <- intersect(lavNames($mv, type = `"ov`"), names(datos))`r`n" +
                          "${ind}  if (length(vars_ov_clean) > 0) datos <- datos[complete.cases(datos[, vars_ov_clean, drop = FALSE]), ]`r`n" +
                          "${ind}}`r`n"
            $rgx = [regex]::new('(?m)^(\s*)(?:fit\w*|ajuste\w*)\s*<-\s*(?:sem|cfa|lavaan)\s*\(\s*[a-zA-Z0-9_]+\s*,')
            $rawScript = $rgx.Replace($rawScript, $cleanBlock + '$0', 1)
            Write-Host "[ALINEACION DEFENSIVA] Se inyecto pre-filtrado complete.cases para missing = `"listwise`" sobre modelo '$mv'" -ForegroundColor Green
        }
    }




# Asegurar emision en consola envolviendo llamadas psicometricas sueltas con print()



$unprintedPatterns = @(



'(?m)^\s*(?!print\()\s*(htmt\s*\([^)]*\))\s*$',



'(?m)^\s*(?!print\()\s*(semTools::htmt\s*\([^)]*\))\s*$',



'(?m)^\s*(?!print\()\s*(lavInspect\s*\([^)]*\))\s*$',



'(?m)^\s*(?!print\()\s*(semTools::reliability\s*\([^)]*\))\s*$'



)



foreach ($pat in $unprintedPatterns) {



if ($rawScript -match $pat) {



$rawScript = [regex]::Replace($rawScript, $pat, 'print($1)')



}



}



# Blindaje de extraccion de p-valor en contrastes lavTestLRT:



# lavTestLRT devuelve un data.frame anova donde la probabilidad esta en [["Pr(>Chisq)"]][2].



# Los LLMs suelen alucinar propiedades inexistentes como $chisq.pvalue o $p.value que devuelven NULL.



if ($rawScript -match 'lavTestLRT') {



if ($rawScript -match '(\w+)\$(?:chisq\.pvalue|p\.value|pvalue)') {



$rawScript = [regex]::Replace($rawScript, '(\w+)\$(?:chisq\.pvalue|p\.value|pvalue)', '$1[["Pr(>Chisq)"]][2]')



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio el acceso inexistente al p-valor en lavTestLRT a '[[\`"Pr(>Chisq)\`"]][2]'" -ForegroundColor Green



}



}



# Blindaje de operador flecha '->' dentro de la sintaxis del modelo lavaan (SEM / Path Analysis):



# En la sintaxis de lavaan no existe '->'. Debe transformarse A -> B a B ~ A.



if ($rawScript -match '(?m)^\s*([a-zA-Z0-9_\.]+)\s*->\s*([a-zA-Z0-9_\.]+)') {



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*([a-zA-Z0-9_\.]+)\s*->\s*([a-zA-Z0-9_\.]+)', '$2 ~ $1')



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio el operador flecha '->' a la sintaxis valida de lavaan '~'" -ForegroundColor Green



}



# Blindaje de etiquetas de parametros lavaan (ERROR 1 del post-mortem):



# Los LLMs generan etiquetas en estilo Mplus: "Variable ~ Factor (label)" pero lavaan



# exige la notacion "Variable ~ label*Factor". Esta correccion previene el error:



# lavaan->lav_parse_model_string(): Last element of rhs part expected to be an identifier



# Patron: lineas dentro de strings de modelo lavaan con "~ Var (label)" o "=~ Var (label)"



# Se usa un loop while para manejar multiples etiquetas en la misma linea:



#   Eficiencia ~ Calidad (a) + Trato_Social (b)  ->  Eficiencia ~ a*Calidad + b*Trato_Social



$labelPat = '(?m)((?:~|=~)\s*(?:[^#\r\n]*?)\b)([a-zA-Z0-9_\.]+)\s+\(([a-zA-Z0-9_]+)\)'



$labelFixCount = 0



while ($rawScript -match $labelPat) {



$rawScript = [regex]::Replace($rawScript, $labelPat, '$1$3*$2')



$labelFixCount++



if ($labelFixCount -gt 20) { break }  # seguro anti-loop infinito



}



if ($labelFixCount -gt 0) {



Write-Host "[ALINEACION LAVAAN] Se corrigieron $labelFixCount etiqueta(s) de estilo Mplus '(label)' a sintaxis lavaan 'label*variable'" -ForegroundColor Green



}



# Blindaje de llamada a HTMT: htmt(fit) arroja error fatal (no puede coaccionar clase S4 a vector).



# Requiere htmt(modelo, data = datos).



if ($rawScript -match '(?i)\b(?:semTools::)?htmt\s*\(\s*(?:fit\w*)\s*\)') {



$modelVarMatch = [regex]::Match($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*(?:<-|=)\s*[''"](?:\s*[a-zA-Z0-9_]+\s*=~)')



$modelVarName = if ($modelVarMatch.Success) { $modelVarMatch.Groups[1].Value } else { "modelo" }



$rawScript = [regex]::Replace($rawScript, '(?i)\b(?:semTools::)?htmt\s*\(\s*(?:fit\w*)\s*\)', "semTools::htmt($modelVarName, data = datos)")



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio la llamada invalida 'htmt(fit)' a 'semTools::htmt($modelVarName, data = datos)'" -ForegroundColor Green



}



# [CR NATIVA] Fiabilidad Compuesta: compositeRel() (inexistente en semTools >= 0.5-9), compRelSEM() y reliability()



# colapsan en modelos de 2.o orden con estimador ordinal (WLSMV), missing pairwise y covariables. Toda llamada



# (suelta, dentro de print() o asignada a una variable) se reemplaza por el calculo nativo de la CR con las cargas



# estandarizadas: CR = (sum(lambda))^2 / ((sum(lambda))^2 + sum(1 - lambda^2)).



$crPkgCall = '(?:semTools::)?(?:compositeRel|compRelSEM|reliability)\s*\(\s*([A-Za-z0-9_\.]+)\s*(?:,[^()\r\n]*)?\)'



# (el script puede tener fin de linea CRLF: se tolera \r antes de $)



$crAssign = '(?m)^([ \t]*)([A-Za-z0-9_\.]+)[ \t]*(?:<-|=)[ \t]*' + $crPkgCall + '[ \t]*(?:;(.*?))?\r?$'



$crStmt = '(?m)^[ \t]*(?:print\s*\(\s*)?' + $crPkgCall + '\s*\)?[ \t]*\r?$'



if ($rawScript -match $crAssign -or $rawScript -match $crStmt) {



$rawScript = [regex]::Replace($rawScript, $crAssign, [System.Text.RegularExpressions.MatchEvaluator]{



param($m)



$native = if (Get-Command Get-NativeCompositeReliabilityRCode -ErrorAction SilentlyContinue) { Get-NativeCompositeReliabilityRCode -FitName $m.Groups[3].Value } else { 'print("CR no disponible")' }



$out = $native + "`r`n" + $m.Groups[2].Value + " <- cr_tab"



if ($m.Groups[4].Success -and -not [string]::IsNullOrWhiteSpace($m.Groups[4].Value)) { $out += "`r`n" + $m.Groups[4].Value.Trim() }



return $out



})



$rawScript = [regex]::Replace($rawScript, $crStmt, [System.Text.RegularExpressions.MatchEvaluator]{



param($m)



if (Get-Command Get-NativeCompositeReliabilityRCode -ErrorAction SilentlyContinue) { return (Get-NativeCompositeReliabilityRCode -FitName $m.Groups[1].Value) } else { return 'print("CR no disponible")' }



})



Write-Host "[ALINEACION PSICOMETRICA] Se reemplazo la funcion empaquetada de fiabilidad (compositeRel/compRelSEM/reliability) por el calculo NATIVO de la CR con cargas estandarizadas" -ForegroundColor Green



}



# Blindaje de MASS::polr (regresion ordinal):



# En R, polr() exige que la variable dependiente sea de clase factor.



$polrPatternDuplicate = '\bpolr\s*\(\s*(?!factor|as\.factor|ordered)([a-zA-Z0-9_\.]+)\s*~'



if ($rawScript -match $polrPatternDuplicate) {



$rawScript = [regex]::Replace($rawScript, $polrPatternDuplicate, 'polr(factor($1, ordered = TRUE) ~')



Write-Host "[ALINEACION PSICOMETRICA] Se aseguro la conversion a factor de las variables dependientes para polr() en la formula" -ForegroundColor Green



}



# Blindaje de DIF / Invarianza en modelos MIMIC:



# En lavaan, modindices() omite senderos directos de predictoras a items (devuelve 0 filas).



# La metodologia canonica unificada de Charly utiliza lavTestScore(fit, add = ..., epc = TRUE).



if ($rawScript -match 'modindices\s*\(' -and $rawScript -match 'op\s*==\s*["'']~["'']') {



if ($rawScript -match 'modindices\s*\(\s*([a-zA-Z0-9_]+)\s*\)') {



$fitBaseName = $matches[1]



$predMatches = [regex]::Matches($rawScript, '(?m)^\s*[a-zA-Z0-9_]+\s*~\s*([^#\r\n]+)')



$predsList = [System.Collections.Generic.List[string]]::new()



foreach ($pm in $predMatches) {



$toks = [regex]::Matches($pm.Groups[1].Value, '\b([a-zA-Z0-9_]+)\b')



foreach ($tok in $toks) {



$pVal = $tok.Groups[1].Value



if ($allFactors -notcontains $pVal -and -not $allObserved.Contains($pVal) -and -not $predsList.Contains($pVal)) {



$predsList.Add($pVal)



}



}



}



if ($allObserved.Count -gt 0 -and $predsList.Count -gt 0) {



$itemsStr = ($allObserved | ForEach-Object { "`"$_`"" }) -join ", "



$predsStr = ($predsList | ForEach-Object { "`"$_`"" }) -join ", "



$lavScoreBlock = "`r`n# Evaluacion unificada de DIF mediante Score Test Univariado (Muthen 1989 / Mplus)`r`n" +



"grid_dif <- expand.grid(item = c($itemsStr), pred = c($predsStr), stringsAsFactors = FALSE)`r`n" +



"res_dif <- data.frame()`r`n" +



"for (k in 1:nrow(grid_dif)) {`r`n" +



"  p_syn <- paste0(grid_dif`$item[k], `" ~ `", grid_dif`$pred[k])`r`n" +



"  st <- suppressWarnings(lavTestScore($fitBaseName, add = p_syn, epc = TRUE))`r`n" +



"  res_dif <- rbind(res_dif, st`$uni)`r`n" +



"}`r`n" +



"dif_senderos <- res_dif`r`n" +



"dif_senderos`$DIF_Bonferroni <- dif_senderos`$p.value < (0.05 / nrow(dif_senderos))`r`n" +



"print(dif_senderos[order(-dif_senderos`$X2), c(`"lhs`", `"op`", `"rhs`", `"X2`", `"df`", `"p.value`", `"epc`", `"DIF_Bonferroni`")])`r`n"



$modPattern = '(?s)[a-zA-Z0-9_]+\s*(?:<-|=)\s*modindices\s*\([^)]*\).*?(?=print\s*\([^)]*Bonferroni[^)]*\)|\Z)'



if ($rawScript -match $modPattern) {



$rawScript = [regex]::Replace($rawScript, $modPattern, $lavScoreBlock)



# Limpiar cualquier print residual de Bonferroni si quedo duplicado



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*print\s*\([^)]*Bonferroni[^)]*\)\s*$', '')



Write-Host "[ALINEACION PSICOMETRICA] Se actualizo la extraccion de DIF a la funcion oficial lavTestScore() con Score Test univariado iterativo (Muthen 1989)" -ForegroundColor Green



}



}



}



}



# Blindaje de modindices() frente a matriz singular / subidentificacion empirica:



# En lavaan, si la matriz de informacion no es invertible (ej. modelos bifactoriales con 2 factores especificos),



# modindices() lanza un error fatal 'could not compute modification indices; information matrix is singular'.



# Envolvemos modindices() con tryCatch() para emitir un aviso explicativo y permitir que el script concluya con exito.



if ($rawScript -match '\bmodindices\s*\(' -and $rawScript -notmatch 'tryCatch\s*\(') {



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*(?:print\s*\(\s*)?(?:head\s*\(\s*)?modindices\s*\(\s*([a-zA-Z0-9_]+)[^)]*\)\s*(?:,\s*\d+\s*)?\)\s*\)?', {



param($m)



$fitVar = $m.Groups[1].Value



Write-Host "[ALINEACION PSICOMETRICA] Se protegio la extraccion de modindices($fitVar) con tryCatch para prevenir colapso por matriz singular" -ForegroundColor Green



return "tryCatch({ print(head(modindices($fitVar, sort = TRUE), 10)) }, error = function(e) { cat('\n[AVISO]: Indices de modificacion no disponibles para $fitVar (el modelo presenta problemas de identificacion o matriz singular).\n') })"



})



}



# Blindaje contra concatenacion masiva en lavTestScore (Score Test simultaneo vs univariado):



# Pasar decenas de senderos concatenados a 'add' en una sola llamada colapsa la matriz asintotica e infla el chi-cuadrado.



# Si se detecta paste(..., collapse = "\n") con lavTestScore, se transforma a bucle univariado canonico de Muthen:



$simScoreMatch = [regex]::Match($rawScript, '(?s)([a-zA-Z0-9_]+)\s*<-\s*expand\.grid\s*\([^)]*\)\s*[\r\n]+\s*([a-zA-Z0-9_]+)\s*<-\s*paste\s*\([^)]*collapse\s*=\s*["'']\\n["''][^)]*\)\s*[\r\n]+\s*([a-zA-Z0-9_]+)\s*<-\s*lavTestScore\s*\(\s*([a-zA-Z0-9_]+)\s*,\s*add\s*=\s*\2\s*,\s*epc\s*=\s*TRUE\s*\)\s*[\r\n]+\s*([a-zA-Z0-9_]+)\s*<-\s*\3\$uni')



if ($simScoreMatch.Success) {



$gridVar = $simScoreMatch.Groups[1].Value



$fitVar  = $simScoreMatch.Groups[4].Value



$tabVar  = $simScoreMatch.Groups[5].Value



$univariateLoop = "res_dif <- data.frame()`r`n" +



"for (k in 1:nrow($gridVar)) {`r`n" +



"  p_syn <- paste0(${gridVar}`$item[k], `" ~ `", ${gridVar}`$pred[k])`r`n" +



"  st <- suppressWarnings(lavTestScore($fitVar, add = p_syn, epc = TRUE))`r`n" +



"  res_dif <- rbind(res_dif, st`$uni)`r`n" +



"}`r`n" +



"$tabVar <- res_dif"



$rawScript = $rawScript.Replace($simScoreMatch.Value, "$($simScoreMatch.Value.Split("`n")[0])`r`n$univariateLoop")



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio el Score Test en bloque simultaneo transformandolo a bucle univariado canonico de Muthen 1989 (1 gl por sendero)" -ForegroundColor Green



}



# Blindaje de extraccion de lavTestScore (res_score$uni y X2 vs $value):



# lavTestScore devuelve una lista. La tabla univariada esta en $uni y el estadistico es X2.



# Si la IA asigna tabla_dif <- res_score (sin $uni), o accede a $value, se alinea preventivamente.



if ($rawScript -match '\blavTestScore\s*\(') {



# 1. Corregir asignacion directa sin $uni (tabla_dif <- res_score -> tabla_dif <- res_score$uni)



$rawScript = [regex]::Replace($rawScript, '(\b[a-zA-Z0-9_]+\s*(?:<-|=)\s*([a-zA-Z0-9_]+))\s*(?=\r?\n|$)', {



param($m)



$targetVar = $m.Groups[2].Value



if ($rawScript -match "$targetVar\s*(?:<-|=)\s*lavTestScore\s*\(") {



return "$($m.Groups[1].Value)`$uni"



}



return $m.Value



})



# 2. Corregir $value por $X2 en la tabla de DIF



if ($rawScript -match '\b([a-zA-Z0-9_]+)\$value\b') {



$rawScript = [regex]::Replace($rawScript, '\b([a-zA-Z0-9_]+)\$value\b', '$1$X2')



Write-Host "[ALINEACION PSICOMETRICA] Se corrigio el acceso inexistente a '`$value' en la tabla de Score Test a '`$X2'" -ForegroundColor Green



}



# 3. Corregir order(-tabla_dif$value) si quedo suelto



if ($rawScript -match 'order\s*\(\s*-\s*([a-zA-Z0-9_]+)\$value\s*\)') {



$rawScript = [regex]::Replace($rawScript, 'order\s*\(\s*-\s*([a-zA-Z0-9_]+)\$value\s*\)', 'order(-$1$X2)')



}



# 4. Blindar columnas de Bonferroni y subconjunto de impresion en tabla_dif para evitar 'columnas no definidas seleccionadas'



if ($rawScript -match '([a-zA-Z0-9_]+)\$p\.value\s*<-\s*p\.adjust\s*\(\s*\1\$p\.value') {



$rawScript = [regex]::Replace($rawScript, '([a-zA-Z0-9_]+)\$p\.value\s*<-\s*p\.adjust\s*\(\s*\1\$p\.value([^)]*)\)', '${1}$$p_adj <- p.adjust(${1}$$p.value${2}); ${1}$$p.adjusted <- ${1}$$p_adj; ${1}$$DIF_Bonferroni <- ${1}$$p_adj < 0.05')



Write-Host "[ALINEACION PSICOMETRICA] Se preservaron p.value y columnas ajustadas de Bonferroni en la tabla de Score Test" -ForegroundColor Green



}



$rawScript = [regex]::Replace($rawScript, '(\b[a-zA-Z0-9_]+)\s*\[\s*(order\s*\([^\]]+\))\s*,\s*(c\s*\([^)]+\))\s*\]', '${1}[${2}, intersect(${3}, colnames(${1}))]')

# 5. Corregir acceso a $pvalue o $p.value a nivel de raiz en objeto lavTestScore

            # lavTestScore devuelve una lista con $test, $uni y $epc. La propiedad $pvalue a nivel de raiz no existe (es NULL)

            # y provoca 'replacement has length zero' al intentar guardarlo en un vector. Debe ser $test$p.value.

            $scoreVars = @([regex]::Matches($rawScript, '\b([a-zA-Z0-9_]+)\s*(?:<-|=)\s*(?:suppressWarnings\s*\(\s*)?lavTestScore') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)

            foreach ($sVar in $scoreVars) {

                if ($rawScript -match "\b$sVar\`$(?:pvalue|p\.value)\b(?!\s*\[)") {

                    $rawScript = [regex]::Replace($rawScript, "\b$sVar\`$(?:pvalue|p\.value)\b(?!\s*\[)", "$sVar`$test`$p.value")

                    Write-Host "[ALINEACION PSICOMETRICA] Se corrigio el acceso a '`$$sVar`$pvalue' en lavTestScore a '`$$sVar`$test`$p.value'" -ForegroundColor Green

                }if ($rawScript -match "\b$sVar\`$(?:Chi2|chi2|chisq)\b(?!\s*\[)") {
                    $rawScript = [regex]::Replace($rawScript, "\b$sVar\`$(?:Chi2|chi2|chisq)\b(?!\s*\[)", "$sVar`$test`$X2")
                    Write-Host "[ALINEACION PSICOMETRICA] Se corrigio el acceso a '`$$sVar`$Chi2' en lavTestScore a '`$$sVar`$test`$X2'" -ForegroundColor Green
                }



}



}



# Blindaje UNIVERSAL de HTMT frente a cualquier tipo de modelo:



# semTools::htmt() puede colapsar por multiples razones:



# - En modelos bifactoriales ortogonales: 'sample covariance matrix is not positive-definite'



# - En modelos con varianza cero post-recodificacion: matriz de correlaciones singular



# - En datos con poca variabilidad: NaN en correlaciones heterotrait



# Se protege TODA llamada a htmt() con tryCatch, adaptando el mensaje segun el contexto.



if ($rawScript -match '\bhtmt\s*\(' -and $rawScript -notmatch 'tryCatch.*htmt') {



$isBifactorCtx = ($rawUserGoalCheck -match '(?i)bifactor' -or $rawScript -match '(?i)bifactor|orthogonal\s*=\s*TRUE')



$htmtMsg = if ($isBifactorCtx) {



"[AVISO METODOLOGICO]: El ratio HTMT no aplica a modelos bifactoriales ortogonales (los factores latentes son matematicamente ortogonales, cor = 0). La consistencia e interpretabilidad de las subescalas se evalua mediante los Omegas Jerarquicos de Subescala (Omega_HS)."



} else {



"[AVISO]: El ratio HTMT no pudo calcularse (posible matriz de correlaciones singular o no positiva definida). Verificar que los items tengan variabilidad suficiente."



}



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*(?:print\s*\(\s*)?(?:semTools::)?htmt\s*\(\s*([a-zA-Z0-9_]+)[^)]*\)\s*\)?', {



param($m)



$modVar = $m.Groups[1].Value



Write-Host "[ALINEACION PSICOMETRICA] Se protegio htmt($modVar) con tryCatch universal para prevenir colapso por matriz no positiva" -ForegroundColor Green



return "tryCatch({ cat('\n--- Ratio HTMT ---\n'); print(semTools::htmt($modVar, data = datos)) }, error = function(e) cat('\n$htmtMsg\n'))"



})



}



# Blindaje anti-alucinacion de modelos sucesivos multigrupo (configural/metrico/escalar):



# En Charly la invarianza se evalua EXCLUSIVAMENTE con el modelo MIMIC (Muthen 1989).



# Si el modelo genero configural_model, metric_model o scalar_model:



if ($rawScript -match '\b(configural_model|metric_model|scalar_model|fit_configural|fit_scalar)\b') {



# 1. Extraer los factores latentes base



$measLines = [regex]::Matches($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*=~\s*([^#\r\n]+)')



$measBlock = @()



$factorsList = [System.Collections.Generic.List[string]]::new()



foreach ($ml in $measLines) {



$fName = $ml.Groups[1].Value.Trim()



$rhs = ($ml.Groups[2].Value -replace '\b[a-zA-Z0-9_]+\*', '').Trim()



if (-not $factorsList.Contains($fName)) {



$factorsList.Add($fName)



$measBlock += "  $fName =~ $rhs"



}



}



# 2. Extraer la covariable predictora (group = ..., pred = ..., o ~ covariable)



$predVar = "genero"



$grpMatch = [regex]::Match($rawScript, 'group\s*=\s*["'']([a-zA-Z0-9_\.]+)["'']')



$predMatch = [regex]::Match($rawScript, 'pred\s*=\s*["'']([a-zA-Z0-9_\.]+)["'']')



if ($grpMatch.Success) {



$predVar = $grpMatch.Groups[1].Value



} elseif ($predMatch.Success) {



$predVar = $predMatch.Groups[1].Value



} else {



$pMatch2 = [regex]::Match($rawScript, '~\s*(?:[a-zA-Z0-9_]+\*)?([a-zA-Z0-9_]+)')



if ($pMatch2.Success -and -not $factorsList.Contains($pMatch2.Groups[1].Value)) {



$predVar = $pMatch2.Groups[1].Value



}



}



$facRegs = ($factorsList | ForEach-Object { "  $_ ~ $predVar" }) -join "`r`n"



$cleanMimicModel = "mimic_model <- '`r`n" + ($measBlock -join "`r`n") + "`r`n" + $facRegs + "`r`n'"



# 3. Remover las definiciones de modelos multigrupo



$rawScript = [regex]::Replace($rawScript, '(?s)(?:configural_model|metric_model|scalar_model)\s*<-\s*''[^'']+''\r?\n?', '')



$rawScript = [regex]::Replace($rawScript, '(?s)(?:configural_model|metric_model|scalar_model)\s*<-\s*"[^"]+"\r?\n?', '')



# 4. Remover ajustes y anovas asociados a fit_configural/metric/scalar



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*fit_(?:configural|metric|scalar)\s*<-\s*sem\([^\r\n]+\)\r?\n?', '')



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*print\s*\(\s*summary\s*\(\s*fit_(?:configural|metric|scalar)[^\r\n]+\)\s*\)\r?\n?', '')



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*(?:print\s*\(\s*)?anova\s*\(\s*fit_[^\r\n]+\)\s*\)?\r?\n?', '')



# 5. Inyectar definicion y ajuste de fit_base con proteccion de categorias



$fitBaseCode = @"
# Modelo base MIMIC y proteccion de categorias
if ('$predVar' %in% names(datos)) { datos <- as.data.frame(datos[!is.na(datos[['$predVar']]), ]) }
for (col in indicadores) { if (col %in% names(datos) && is.numeric(datos[[col]])) datos[[col]] <- factor(datos[[col]], ordered = TRUE) }
$cleanMimicModel
fit_base <- sem(mimic_model, data = datos, estimator = "WLSMV", ordered = indicadores, missing = "pairwise")
print(summary(fit_base, fit.measures = TRUE, standardized = TRUE))
"@



if ($rawScript -match 'fit_base\s*<-\s*fit_metric') {



$rawScript = $rawScript -replace 'fit_base\s*<-\s*fit_metric\r?\n?', $fitBaseCode



} elseif ($rawScript -match 'grid_dif\s*<-') {



$rawScript = $rawScript -replace 'grid_dif\s*<-', "$fitBaseCode`r`ngrid_dif <-"



}

# Blindaje de cobertura total de items en DIF: asegurar que expand.grid evalue TODOS los indicadores de medida
if ($rawScript -match 'grid_dif\s*<-\s*expand\.grid\s*\(\s*item\s*=\s*(?:items_ord|ord|ordered_vars)\b') {
    if ($allObserved.Count -gt 0) {
        $allItemsStr = 'c(' + (($allObserved | ForEach-Object { "`"$_`"" }) -join ', ') + ')'
        $rawScript = [regex]::Replace($rawScript, 'expand\.grid\s*\(\s*item\s*=\s*(?:items_ord|ord|ordered_vars)\b', "expand.grid(item = $allItemsStr")
        Write-Host "[ALINEACION DIF] Se aseguro que expand.grid(item) evalue todos los $($allObserved.Count) reactivos del modelo (incluidos continuos)" -ForegroundColor Green
    }
}



# Limpiar encabezados comentados de modelos multigrupo



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*#\s*(?:Modelos de invarianza|Ajuste de modelos|Reporte de modelos|Comparaci[oó]n de modelos)\s*\r?\n?', '')



Write-Host "[ALINEACION PSICOMETRICA] Se desmantelo intento de invarianza multigrupo (configural/metrico/escalar) y se ajusto exclusivamente el modelo MIMIC canonico de Muthen (1989)" -ForegroundColor Green



}



# Blindaje de comparacion de modelos mediante anova() / lavTestLRT():



# anova(fit1, fit2) en lavaan falla criticamente si uno de los modelos no converge o si no estan estrictamente anidados.



# Se protege cualquier anova(fit1, fit2) con tryCatch para que nunca aborte el script R,



# permitiendo que continue hacia la tabla de fitmeasures y los indices psicometricos.



if ($rawScript -match '\banova\s*\(\s*[a-zA-Z0-9_]+\s*,\s*[a-zA-Z0-9_]+' -and $rawScript -notmatch 'tryCatch\s*\(\s*\{\s*print\s*\(\s*anova') {



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*(?:print\s*\(\s*)?anova\s*\(\s*([a-zA-Z0-9_]+)\s*,\s*([a-zA-Z0-9_]+)\s*\)\s*\)?', {



param($m)



$f1 = $m.Groups[1].Value



$f2 = $m.Groups[2].Value



Write-Host "[ALINEACION PSICOMETRICA] Se protegio anova($f1, $f2) con tryCatch para evitar colapso de script por no convergencia o no anidamiento" -ForegroundColor Green



return "tryCatch({ print(anova($f1, $f2)) }, error = function(e) cat('\n[AVISO]: La comparacion formal de Chi-cuadrado escalado (LRT / anova) no esta disponible porque uno de los modelos no alcanzo convergencia normal o no estan jerarquicamente anidados. Se procede con la comparacion mediante indices de ajuste globales (fitmeasures).\n'))"



})



}



# Blindaje de tabla comparativa de fitmeasures ante modelos no convergidos:



# fitmeasures(fit) lanza un error fatal de R si el modelo no convergio.



# Se protege con tryCatch para garantizar que no aborte el script y se reporten los indices bifactoriales.



if ($rawScript -match '\bfitmeasures\s*\(' -and $rawScript -notmatch 'safe_fm\s*<-\s*function') {



# Inyectar la funcion helper safe_fm al inicio del bloque de analisis



$safeFmDef = "safe_fm <- function(obj, indices) tryCatch(fitmeasures(obj, indices), error = function(e) { cat('\n[AVISO]: fitmeasures() no disponible para', deparse(substitute(obj)), '(modelo no convergido).\n'); rep(NA, length(indices)) })"



# Proteger cbind de fitmeasures pareados



$rawScript = [regex]::Replace($rawScript, '(?m)^\s*(?:print\s*\(\s*)?cbind\s*\(\s*([a-zA-Z0-9_]+)\s*=\s*fitmeasures\s*\(\s*([a-zA-Z0-9_]+)\s*,\s*c\(([^)]+)\)\s*\)\s*,\s*([a-zA-Z0-9_]+)\s*=\s*fitmeasures\s*\(\s*([a-zA-Z0-9_]+)\s*,\s*c\(\3\)\s*\)\s*\)\s*\)?', {



param($m)



$l1 = $m.Groups[1].Value; $m1 = $m.Groups[2].Value



$fms = $m.Groups[3].Value



$l2 = $m.Groups[4].Value; $m2 = $m.Groups[5].Value



Write-Host "[ALINEACION PSICOMETRICA] Se protegio la tabla comparativa fitmeasures($m1, $m2) con tryCatch contra modelos no convergidos" -ForegroundColor Green



return "$safeFmDef`r`nprint(cbind($l1 = safe_fm($m1, c($fms)), $l2 = safe_fm($m2, c($fms))))"



})



# Proteger fitmeasures() individual no pareado



if ($rawScript -notmatch 'safe_fm\s*<-\s*function' -and $rawScript -match '(?m)^\s*(?:print\s*\(\s*)?fitmeasures\s*\(\s*([a-zA-Z0-9_]+)') {



$rawScript = [regex]::Replace($rawScript, '(?m)^(\s*)(?:print\s*\(\s*)?fitmeasures\s*\(\s*([a-zA-Z0-9_]+)\s*,?\s*([^)]*)\)\s*\)?', {



param($m)



$indent = $m.Groups[1].Value; $fv = $m.Groups[2].Value; $args = $m.Groups[3].Value.Trim()



$argsR = if ($args) { ", $args" } else { '' }



Write-Host "[ALINEACION PSICOMETRICA] Se protegio fitmeasures($fv) individual con tryCatch contra modelo no convergido" -ForegroundColor Green



return "${indent}tryCatch({ print(fitmeasures($fv$argsR)) }, error = function(e) cat('\n[AVISO]: fitmeasures() no disponible para $fv (modelo no convergido).\n'))"



})



}



}



# Blindaje de summary(fit, fit.measures = TRUE) ante modelos no convergidos:



# Cuando un modelo lavaan no converge, summary() aun imprime los parametros (aunque no fiables),



# pero incluir fit.measures = TRUE causa un error fatal. Se protege con tryCatch.



if ($rawScript -match 'summary\s*\([^)]*fit\.measures\s*=\s*TRUE' -and $rawScript -notmatch 'tryCatch.*summary.*fit\.measures') {



$rawScript = [regex]::Replace($rawScript, '(?m)^(\s*)(?:print\s*\(\s*)?summary\s*\(\s*([a-zA-Z0-9_]+)\s*,\s*fit\.measures\s*=\s*TRUE([^)]*)\)\s*\)?', {



param($m)



$indent = $m.Groups[1].Value; $fv = $m.Groups[2].Value; $rest = $m.Groups[3].Value



return @"
${indent}tryCatch({
${indent}  print(summary($fv, fit.measures = TRUE$rest))
${indent}}, error = function(e) {
${indent}  cat('\n[AVISO]: Medidas de ajuste no disponibles para $fv (modelo no convergido). Mostrando parametros sin fit measures:\n')
${indent}  tryCatch(print(summary($fv$rest)), error = function(e2) cat('[ERROR]: No es posible reportar parametros para $fv.\n'))
${indent}})
"@



})



Write-Host "[ALINEACION PSICOMETRICA] Se protegio summary(fit, fit.measures = TRUE) con tryCatch para modelos no convergidos" -ForegroundColor Green



}

    # Si la IA omitio por completo summary(), inyectar tryCatch con summary(fit) antes de los calculos posteriores:
    if ($rawScript -notmatch '\bsummary\s*\(' -and $rawScript -match '\b(fit|fit_base|fit_modelo)\s*<-\s*(?:cfa|sem|growth|lavaan)\b') {
        $fitVar = $Matches[1]
        if ($rawScript -match '(?m)^(\s*)(?:std\s*<-|lam\s*<-|cat\s*\(|lavInspect\s*\()') {
            $safeSummaryBlock = "tryCatch({`r`n  print(summary($fitVar, fit.measures = TRUE, standardized = TRUE))`r`n}, error = function(e) {`r`n  cat('\n[AVISO]: Medidas de ajuste no disponibles para $fitVar (modelo no convergido). Mostrando parametros sin fit measures:\n')`r`n  tryCatch(print(summary($fitVar, standardized = TRUE)), error = function(e2) cat('[ERROR]: No es posible reportar parametros para $fitVar.\n'))`r`n})`r`n`r`n" + '$0'
            $rgx = [regex]::new('(?m)^(\s*)(?:std\s*<-|lam\s*<-|cat\s*\(|lavInspect\s*\()')
            $rawScript = $rgx.Replace($rawScript, $safeSummaryBlock, 1)
            Write-Host "[ALINEACION PSICOMETRICA] Se inyecto summary($fitVar, fit.measures = TRUE) omitido por la IA para garantizar el cumplimiento del contrato" -ForegroundColor Green
        }
    }



# Blindaje de regresiones estructurales en MIMIC:



# En MIMIC, las covariables deben regresar sobre los FACTORES, nunca sobre los items observados.



# Si el modelo base contiene exclusivamente item ~ Covariables y ningun Factor ~ Covariables:



if ($rawScript -match '\blavTestScore\s*\(' -and $allFactors.Count -gt 0) {



$hasFactorRegression = $false



foreach ($fac in $allFactors) {



if ($rawScript -match "(?m)^\s*$fac\s*~\s*[^#\r\n]+") {



$hasFactorRegression = $true



break



}



}



if (-not $hasFactorRegression) {



$covarLineMatch = [regex]::Match($rawScript, '(?m)^\s*([a-zA-Z0-9_]+)\s*~\s*([a-zA-Z0-9_\s\+]+)')



if ($covarLineMatch.Success -and $allObserved.Contains($covarLineMatch.Groups[1].Value)) {



$covarsRhs = $covarLineMatch.Groups[2].Value.Trim()



foreach ($obs in $allObserved) {



$rawScript = [regex]::Replace($rawScript, "(?m)^\s*$obs\s*~\s*[^#\r\n]+\r?\n?", "")



}



$facRegBlock = ($allFactors | ForEach-Object { "  $_ ~ $covarsRhs" }) -join "`r`n"



$modelAssignMatch = [regex]::Match($rawScript, '([a-zA-Z0-9_]+\s*(?:<-|=)\s*[''"])(.*?)([''"])', [System.Text.RegularExpressions.RegexOptions]::Singleline)



if ($modelAssignMatch.Success) {



$fullModelStr = $modelAssignMatch.Groups[2].Value.TrimEnd() + "`r`n" + $facRegBlock + "`r`n"



$rawScript = $rawScript.Replace($modelAssignMatch.Groups[0].Value, $modelAssignMatch.Groups[1].Value + $fullModelStr + $modelAssignMatch.Groups[3].Value)



Write-Host "[ALINEACION PSICOMETRICA] Se reorientaron las regresiones de covariables desde los items observados hacia los factores latentes en el modelo MIMIC" -ForegroundColor Green



}



}



}



}



# Blindaje contra caidas por Indices de Modificacion (matriz singular en Lavaan):



$modIndPattern = '\b(modificationIndices|modindices)\s*\('



if ($rawScript -match $modIndPattern) {



$safeModDef = "`r`n# Funcion segura para Indices de Modificacion`r`nsafe_modindices <- function(...) {`r`n  tryCatch(lavaan::modificationIndices(...), error = function(e) {`r`n    cat('\n[AVISO]: No se pudieron calcular los indices de modificacion (matriz singular o falta de convergencia).\n')`r`n    return(data.frame(lhs=character(), op=character(), rhs=character(), mi=numeric()))`r`n  })`r`n}`r`n"



$rawScript = [regex]::Replace($rawScript, $modIndPattern, 'safe_modindices(')



if ($rawScript -match '(?m)^(library\([^)]+\)\r?\n)+') {



$rawScript = [regex]::Replace($rawScript, '(?m)^((?:library\([^)]+\)\r?\n)+)', "`$1$safeModDef", 1)



} else {



$rawScript = $safeModDef + $rawScript



}



Write-Host "[ALINEACION PSICOMETRICA] Se inyecto envoltura segura (tryCatch) para modificationIndices() y modindices()" -ForegroundColor Green



}



# Blindaje de mediaciones y formulas canonicas de SEM_Senderos:



# Si el contrato define mediaciones con formulas canonicas inmutables (SintaxisLavaan),



# y la IA omitio las etiquetas multiplicadoras o invento 'b * a' sin etiquetar las regresiones:



$contractSpecsPath = "workspace/contract_specs.json"



if (Test-Path $contractSpecsPath) {



try {



$cSpecs = Get-Content $contractSpecsPath -Raw -Encoding UTF8 | ConvertFrom-Json



if ($cSpecs -and $cSpecs.Modelado -and $cSpecs.Modelado.SintaxisLavaan -and $cSpecs.Modelado.Mediaciones -and $cSpecs.Modelado.Mediaciones.Count -gt 0) {



$canonSemSyntax = $cSpecs.Modelado.SintaxisLavaan.Trim()



# Incoherencia con la formulacion canonica: faltan parametros ':=' canonicos o hay efectos mal definidos



# (p. ej. 'total := indirecto + a', que suma un sendero hacia el mediador en vez de un camino X -> Y).



$canonMissing = $false



foreach ($cl in ($canonSemSyntax -split '\r?\n')) {



if ($cl -match '^\s*([A-Za-z_][\w\.]*)\s*:=') {



if ($rawScript -notmatch ('\b' + [regex]::Escape($matches[1]) + '\b')) { $canonMissing = $true }



}



}



$badEffectDefs = $false



if (Get-Command Test-DefinedEffectsAreValidPaths -ErrorAction SilentlyContinue) {



$badEffectDefs = (@(Test-DefinedEffectsAreValidPaths -ScriptContent $rawScript)).Count -gt 0



}



$hasBrokenLabels = ($rawScript -match '(?m):=\s*[a-zA-Z0-9_]+\s*\*\s*[a-zA-Z0-9_]+' -and $rawScript -notmatch '~\s*([a-zA-Z0-9_]+)\s*\*') -or



($rawScript -match 'unknown label') -or ($rawScript -match '(?m)^\s*[a-zA-Z0-9_]+\s*:=\s*[a-zA-Z0-9_]+\s*~') -or



($rawScript -notmatch ':=\s*[a-zA-Z0-9_]+') -or $canonMissing -or $badEffectDefs



if ($hasBrokenLabels) {



# Se elige la asignacion cuyo contenido es el modelo lavaan (contiene '~'); evita confundir



# argumentos como sheet = 'RESPUESTAS' de read_excel() con la definicion del modelo.



$modelAssignRegex = '(?s)([a-zA-Z0-9_]+\s*(?:<-|=)\s*([''"]))((?:(?!\2).)*)\2'

$modelAssignMatch = $null

foreach ($cand in [regex]::Matches($rawScript, $modelAssignRegex)) {

if ($cand.Groups[3].Value -match '~' -and $cand.Groups[1].Value -notmatch '(?i)\b(?:sheet|file|path)\s*=') { $modelAssignMatch = $cand; break }

}

if ($modelAssignMatch -and $modelAssignMatch.Success) {

$modelContent = $modelAssignMatch.Groups[3].Value

$cleanModelLines = @()

foreach ($mLine in ($modelContent -split '\r?\n')) {

$trimLine = $mLine.Trim()

if ($trimLine -match ':=\s*' -or $trimLine -match '^#\s*--- (SENDEROS|EFECTOS)') { continue }

$isStructuralReg = $false

foreach ($sItem in $cSpecs.Modelado.Senderos) {

if ($trimLine -match "^\s*$($sItem.Destino)\s*~") { $isStructuralReg = $true; break }

}

if (-not $isStructuralReg) {

$cleanModelLines += $mLine

}

}

$alignedModelStr = ($cleanModelLines -join "`r`n").TrimEnd() + "`r`n`r`n" + $canonSemSyntax + "`r`n"

$quoteChar = $modelAssignMatch.Groups[2].Value

$rawScript = $rawScript.Replace($modelAssignMatch.Groups[0].Value, $modelAssignMatch.Groups[1].Value + $alignedModelStr + $quoteChar)

Write-Host "[ALINEACION PSICOMETRICA] Se inyecto la formulacion canonica inmutable de mediacion (teoria de grafos) en la sintaxis de lavaan" -ForegroundColor Green

}



}



}



} catch {}



}



$rawScript = [regex]::Replace($rawScript, "(\r?\n\s*){3,}", "`r`n`r`n")

        [System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawScript, $utf8NoBom)



}



Write-Host "`n[EJECUTOR R] Intento $attempt de $MaxAttempts : Ejecutando $ScriptPath ..." -ForegroundColor Cyan



# [FIX C1] Lectura ASINCRONA de stdout y stderr (evita deadlock cuando R escribe mas stderr que el buffer



# del pipe) + timeout con kill del arbol de procesos (Rscript.exe y su R.exe hijo).



$RTimeoutSec = 900



$procInfo = New-Object System.Diagnostics.ProcessStartInfo



$procInfo.FileName = $Rscript

$procInfo.WorkingDirectory = $baseDir



$procInfo.Arguments = ('"{0}"' -f $ScriptPath)



$procInfo.RedirectStandardOutput = $true



$procInfo.RedirectStandardError = $true



$procInfo.RedirectStandardInput = $true



$procInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8



$procInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8



$procInfo.UseShellExecute = $false



$procInfo.CreateNoWindow = $true



$p = [System.Diagnostics.Process]::Start($procInfo)



$p.StandardInput.Close()



$outTask = $p.StandardOutput.ReadToEndAsync()



$errTask = $p.StandardError.ReadToEndAsync()



$timedOut = -not $p.WaitForExit($RTimeoutSec * 1000)



if ($timedOut) {



& taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null



[void]$p.WaitForExit(5000)



}



$stdout = $outTask.Result



$stderr = $errTask.Result



if ($timedOut) { $stderr += "`r`nError: R excedio el tiempo maximo ($RTimeoutSec s) y fue terminado." }



$exitCode = if ($timedOut) { 124 } else { $p.ExitCode }



$combinedOutput = "$stdout`r`n$stderr"



# 1. Extraer TODOS los avisos y advertencias de lavaan y librerias psicometricas



$allLavaanWarnings = @()



foreach ($line in ($combinedOutput -split "`r?`n")) {



if ($line -match 'lavaan->|Aviso|Avisos:|Warning|semTools|some estimated|is not recommended|could not|not identified|positive definite|no se puede|cannot compute|isShared') {



$trimmed = $line.Trim()



if (![string]::IsNullOrWhiteSpace($trimmed) -and $trimmed -notmatch 'package.*was built under') {



$allLavaanWarnings += $trimmed



}



}



}



$hasMisconfiguration = ($combinedOutput -match 'Did you forget to set the ordered=' -or 



$combinedOutput -match 'estimator "DWLS" is not recommended for continuous data' -or



$combinedOutput -match 'glm\.fit: algorithm did not converge')



$userGoalCheck = if (Test-Path "workspace/user_goal.txt") { [System.IO.File]::ReadAllText((Resolve-Path "workspace/user_goal.txt"), [System.Text.Encoding]::UTF8) } else { "" }



$rawUserGoalCheck = ($userGoalCheck -split '={20,}')[0]



$isBifactorRequested = ($rawUserGoalCheck -match '(?i)bifactor')



$hasSecondOrderConfusion = $isBifactorRequested -and ($rawScript -match '(?m)^\s*F\w*\s*=~\s*F\d+\s*\+\s*F\d+')



$hasModelSyntaxError = ($combinedOutput -match 'lavaan ERROR: syntax error' -or $combinedOutput -match 'unexpected symbol' -or $combinedOutput -match 'unexpected string constant')



$hasSilentTryCatchError = ($combinedOutput -match '(?i)Error:\s*El modelo no convergi|hubo un fallo cr[iíÃ]')



$hasLavaanWarning = ($allLavaanWarnings.Count -gt 0)



$isFatalError = ($exitCode -ne 0) -or $hasModelSyntaxError -or $hasSecondOrderConfusion -or $hasSilentTryCatchError



# Si R finalizo con codigo 0, sin desconfiguracion ni errores de sintaxis en lavaan:



if (!$isFatalError -and !$hasMisconfiguration) {



Write-Host "`n[EJECUTOR R] Ejecucion exitosa en $rVerStr (Codigo 0)!" -ForegroundColor Green



Write-Host $stdout



$rWarnLines = @(Get-RWarningBlocks -Text $combinedOutput -FallbackLines $allLavaanWarnings)



if ($rWarnLines.Count -gt 0) {



Write-Host "`n[AVISOS DE R] R termino sin errores, pero emitio los siguientes avisos. REVISARLOS antes de interpretar los resultados:" -ForegroundColor Yellow



$shown = 0



foreach ($wl in $rWarnLines) {



if ($shown -ge 60) { break }



Write-Host "   $wl" -ForegroundColor Yellow



$shown++



}



if ($rWarnLines.Count -gt $shown) {



Write-Host "   ... ($($rWarnLines.Count - $shown) lineas mas: ver consola_rstudio_completa.txt)" -ForegroundColor Yellow



}



try {
    if (!(Test-Path "workspace")) { New-Item -ItemType Directory -Force -Path "workspace" | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path (Resolve-Path "workspace") "avisos_r.txt"), ($rWarnLines -join "`r`n"), $utf8NoBom)
} catch {}
} else {
    try {
        $cleanTarget = Join-Path (Resolve-Path "workspace" -ErrorAction SilentlyContinue) "avisos_r.txt"
        if ($cleanTarget -and (Test-Path $cleanTarget)) {
            Remove-Item -LiteralPath $cleanTarget -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}



# Guardar la salida limpia de R en resultados_analisis.txt



if (![string]::IsNullOrWhiteSpace($stdout)) {



Set-Content -Path "workspace/resultados_analisis.txt" -Value $stdout.Trim() -Encoding UTF8



}



$currentScr = if (Test-Path $ScriptPath) { [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8) } else { "" }



# Guardar la SALIDA CRUDA COMPLETA ESTILO RSTUDIO (Script fuente + stdout + stderr + warnings verbatim)



$rHeader = @"
================================================================================
CONSOLA COMPLETA DE RSTUDIO (SALIDA DIRECTA Y VERBATIM DEL MOTOR $($rVerStr.ToUpperInvariant()))
================================================================================
Script ejecutado : $ScriptPath
Fecha y hora     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Estado ejecucion : Codigo de salida 0 (Exitoso)
================================================================================

================================================================================
CODIGO FUENTE R EJECUTADO EN ESTE ANALISIS:
================================================================================
$currentScr
================================================================================
RESULTADOS Y REGISTRO DE SALIDA DE R (CONSOLA VERBATIM):
================================================================================
"@



$rawConsoleOutput = $rHeader + $combinedOutput



if (!(Test-Path "workspace")) { New-Item -ItemType Directory -Force -Path "workspace" | Out-Null }



$rawConsoleOutput = [regex]::Replace($rawConsoleOutput, "(\r?\n\s*){3,}", "`r`n`r`n")

        [System.IO.File]::WriteAllText((Join-Path (Resolve-Path "workspace") "consola_rstudio_completa.txt"), $rawConsoleOutput, $utf8NoBom)



Write-Host "`n[CONSOLA RSTUDIO] Salida completa guardada en workspace/consola_rstudio_completa.txt" -ForegroundColor Cyan



# Integrar Script R al INICIO del reporte para Reproducibilidad Total



$reportFile = "workspace/resultados_analisis.txt"



if ((Test-Path $ScriptPath) -and (Test-Path $reportFile)) {



for ($fRetry = 0; $fRetry -lt 4; $fRetry++) {



try {



Start-Sleep -Milliseconds 150



$rawRep = [System.IO.File]::ReadAllText((Resolve-Path $reportFile), [System.Text.Encoding]::UTF8)



# Limpiar cualquier bloque previo de CODIGO FUENTE (este arriba o abajo)



$pureResults = [System.Text.RegularExpressions.Regex]::Replace($rawRep, "(?s)={20,}\r?\n(?:# )?CODIGO FUENTE R.*?={20,}\r?\n(?:RESULTADOS.*?\r?\n)?", "")



$pureResults = [System.Text.RegularExpressions.Regex]::Replace($pureResults, "(?s)\r?\n={20,}\r?\n(?:# )?CODIGO FUENTE R.*$", "")



$pureResults = $pureResults.Trim()

$warnHeaderBlock = ""
if ($rWarnLines.Count -gt 0) {
    $warnHeaderBlock = "`r`n`r`n================================================================================`r`n[!] ATENCION: R EMITIO AVISOS DURANTE EL CALCULO (REVISAR ANTES DE INTERPRETAR):`r`n================================================================================`r`n" + ($rWarnLines -join "`r`n")
}

$reportWithHeader = @"
# ==============================================================================
# CODIGO FUENTE R COMPLETO (Copiar desde aqui y pegar directamente en RStudio):
# ==============================================================================
$currentScr
# ==============================================================================
# FIN DEL CODIGO FUENTE R - A CONTINUACION RESULTADOS DE LA ESTIMACION:
# ==============================================================================

================================================================================
RESULTADOS ESTADISTICOS Y REPORTES DE ESTIMACION:
================================================================================
$pureResults$warnHeaderBlock
"@



[System.IO.File]::WriteAllText((Resolve-Path $reportFile), $reportWithHeader, [System.Text.Encoding]::UTF8)



break



} catch {



Start-Sleep -Milliseconds 300



}



}



}



# ==============================================================================



# AUDITORIA DETERMINISTA DE CONTRATO PSICOMETRICO



# ==============================================================================



$contractAuditPassed = $true



$contractPath = "workspace/contract_specs.json"



if (Test-Path $contractPath) {



try {



$contractObj = Get-Content $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json



if (Get-Command Audit-ScriptContract -ErrorAction SilentlyContinue) {



$auditResult = Audit-ScriptContract -ScriptPath $ScriptPath -Contract $contractObj -ConsoleOutput $combinedOutput



if ($auditResult.Passed -eq $false) {



$contractAuditPassed = $false



Write-Host "`n[AUDITOR DE CONTRATO] El script compilo en R (Codigo 0), pero INCUMPLE clausulas obligatorias del contrato:" -ForegroundColor Red



foreach ($om in $auditResult.OmisionesEntregables) {



Write-Host "   * [OMISION]: $om" -ForegroundColor Yellow



}



foreach ($ec in $auditResult.ErroresCriticos) {



Write-Host "   * [ERROR CRITICO]: $ec" -ForegroundColor Red



}



$isFatalError = $true



$lastErrorEncountered = @"
!!! INCUMPLIMIENTO DEL CONTRATO PSICOMETRICO DETECTADO (EL SCRIPT COMPILO PERO OMITIO ENTREGABLES OBLIGATORIOS) !!!
$($auditResult.DirectivasReparacion -join "`r`n")
Debes corregir el script de R asegurando que incluya obligatoriamente todos estos calculos y entregables.
"@



}



}



} catch {}



}



if ($contractAuditPassed) {



Write-Host "`n[OK] Script ejecutado limpiamente en R y AUDITADO con 100% de cumplimiento del contrato." -ForegroundColor Green



# TRAZABILIDAD DEL REINTENTO Y MEMORIA DE APRENDIZAJE



if ($attempt -gt 1 -and !([string]::IsNullOrWhiteSpace($lastErrorEncountered))) {



$learnedFile = "workspace/learned_rules.json"



$existingRules = [System.Collections.Generic.List[string]]::new()



if (Test-Path $learnedFile) {



try {



$raw = Get-Content $learnedFile -Raw -Encoding UTF8



if ($raw.Trim().StartsWith("[")) {



$parsed = $raw | ConvertFrom-Json



foreach ($r in $parsed) { if (![string]::IsNullOrWhiteSpace($r)) { $existingRules.Add($r.ToString()) } }



}



} catch {}



}



$errLine = ($lastErrorEncountered -split "`r?`n" | Where-Object { $_ -notmatch '^!|^ERROR CRITICO' -and $_ -match 'Error|Error en|no se pudo|could not|not found|objeto.*no encontrado|INCUMPLIMIENTO' } | Select-Object -First 1)



if ($errLine) {



$ruleText = "En un reintento exitoso se supero la observacion: $($errLine.Trim()). Asegurar que la sintaxis de R cumpla con ese requerimiento."



if (!$existingRules.Contains($ruleText)) {



$existingRules.Add($ruleText)



$existingRules | ConvertTo-Json | Set-Content -Path $learnedFile -Encoding UTF8



Write-Host "`n[MEMORIA DE APRENDIZAJE] Nueva leccion de trazabilidad registrada en $learnedFile" -ForegroundColor DarkCyan



}



}



}



exit 0



}



}



# Si hay un error fatal, mostrarlo completo; si solo son avisos, mostrarlos



if ($isFatalError) {



Write-Host "`n[EJECUTOR R] El script produjo un error en R (Codigo $exitCode):" -ForegroundColor Red



if (![string]::IsNullOrWhiteSpace($stderr)) {



Write-Host $stderr.Trim() -ForegroundColor Red



} else {



Write-Host $stdout.Trim() -ForegroundColor Yellow



}



} elseif ($hasLavaanWarning) {



Write-Host "`n[AVISO DE LAVAAN DETECTADO] lavaan emitio las siguientes observaciones en R:" -ForegroundColor Yellow



$allLavaanWarnings | ForEach-Object { Write-Host "   * $_" -ForegroundColor Yellow }



}



if ($attempt -ge $MaxAttempts) {



Write-Host "`n[AUTORREPARACION] Se alcanzo el numero maximo de intentos ($MaxAttempts)." -ForegroundColor Red



$currentScr = if (Test-Path $ScriptPath) { [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8) } else { "" }



$rHeader = @"
================================================================================
CONSOLA COMPLETA DE RSTUDIO (REGISTRO FINAL TRAS INTENTOS DE REPARACION)
================================================================================
Script ejecutado : $ScriptPath
Fecha y hora     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Estado ejecucion : Codigo de salida 1 (R detuvo la ejecucion por observaciones o errores)
================================================================================

================================================================================
CODIGO FUENTE R GENERADO POR EL SISTEMA Y EJECUTADO:
================================================================================
$currentScr
================================================================================
RESPUESTA TEXTUAL Y CRUDA DE LA CONSOLA DE R (ERRORES / AVISOS OFICIALES):
================================================================================
"@



# [FIX M7] Si R termino BIEN y solo fallo el auditor de contrato, NO se pisan los resultados validos con el log



# crudo: se conservan con un aviso al inicio y se sale con codigo 2 (la GUI distingue "R fallo" de "contrato incumplido").



$rRanOk = (($exitCode -eq 0) -and -not $hasModelSyntaxError -and -not $hasSecondOrderConfusion -and -not $hasSilentTryCatchError -and -not $hasMisconfiguration -and (Test-Path "workspace/resultados_analisis.txt"))



if ($rRanOk) {



try {



$resPath = Join-Path (Resolve-Path "workspace") "resultados_analisis.txt"



$prevRes = [System.IO.File]::ReadAllText($resPath, [System.Text.Encoding]::UTF8)



if ($prevRes -notmatch '^\s*!!! AVISO DE CONTRATO') {



$banner = "!!! AVISO DE CONTRATO: R ejecuto el script sin errores, pero el auditor de contrato psicometrico reporto incumplimientos tras $MaxAttempts intentos. Los resultados se conservan; revisa lo siguiente:`r`n" + $lastErrorEncountered + "`r`n" + ("=" * 80) + "`r`n`r`n"



[System.IO.File]::WriteAllText($resPath, $banner + $prevRes, $utf8NoBom)



# El aviso del auditor tambien se antepone a la consola completa (la vista que se muestra al usuario): nada queda oculto.



$conPath = Join-Path (Resolve-Path "workspace") "consola_rstudio_completa.txt"



if (Test-Path $conPath) {



$prevCon = [System.IO.File]::ReadAllText($conPath, [System.Text.Encoding]::UTF8)



if ($prevCon -notmatch '^\s*!!! AVISO DE CONTRATO') {



[System.IO.File]::WriteAllText($conPath, $banner + $prevCon, $utf8NoBom)



}



}



}



} catch {}



Write-Host "[AUDITOR DE CONTRATO] R calculo los resultados, pero el contrato psicometrico no se cumplio por completo. Resultados conservados en workspace/consola_rstudio_completa.txt (con aviso del auditor al inicio)." -ForegroundColor Yellow



exit 2



}



$rawConsoleOutput = $rHeader + $combinedOutput



if (!(Test-Path "workspace")) { New-Item -ItemType Directory -Force -Path "workspace" | Out-Null }



$rawConsoleOutput = [regex]::Replace($rawConsoleOutput, "(\r?\n\s*){3,}", "`r`n`r`n")

        [System.IO.File]::WriteAllText((Join-Path (Resolve-Path "workspace") "consola_rstudio_completa.txt"), $rawConsoleOutput, $utf8NoBom)



[System.IO.File]::WriteAllText((Join-Path (Resolve-Path "workspace") "resultados_analisis.txt"), $rawConsoleOutput, $utf8NoBom)



Write-Host "[CONSOLA RSTUDIO] Registro completo con codigo y errores guardado en workspace/resultados_analisis.txt y consola_rstudio_completa.txt." -ForegroundColor Cyan



exit 1



}



Write-Host "`n[FEEDBACK A LA IA] Copiando y enviando los avisos de lavaan a los cerebros ($Engine)..." -ForegroundColor Cyan



# Filtrar avisos triviales de compilación de paquetes y extraer errores críticos de R



$cleanLines = @()



$errorLines = @()



foreach ($line in ($combinedOutput -split "`r?`n")) {



$trimmed = $line.Trim()



if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }



if ($trimmed -match '^package.*was built under') { continue }



if ($trimmed -match '^This is (lavaan|semTools)') { continue }



if ($trimmed -match '^(Adjuntando el paquete|The following object|lavaan is FREE|All users of R)') { continue }



if ($trimmed -match '^(cor2cov|reliability, skew)') { continue }



if ($trimmed -match '^(#+|=+)') { continue }



if ($trimmed -match 'Root Mean Square Error|Standard errors|User Model versus Baseline') {



$cleanLines += $trimmed



continue



}



if ($trimmed -match '(?i)\b(Error in|Error en|Error fatal|Error:)\b|Calls:|Ejecuci|ERROR EXACTO|lavaan->|cannot be regressed|syntax error|glm\.fit:|Did you forget to set the ordered=|estimator "DWLS" is not recommended|y values must be|columnas no definidas|undefined columns|no encontrado|not found|fuera de los l|out of bounds') {



$errorLines += $trimmed



}



$cleanLines += $trimmed



}



$codeForChecks = if (Test-Path $ScriptPath) { [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8) } else { "" }

if ($combinedOutput -match 'Did you forget to set the ordered=' -or $combinedOutput -match 'estimator "DWLS" is not recommended') {



$errorLines += "ERROR DE CONFIGURACION EN LAVAAN: Al utilizar el estimador WLSMV con variables ordinales, es obligatorio incluir el argumento ordered indicando el vector con los nombres de las variables observadas categoricas analizadas, y el tratamiento de datos incompletos correspondiente."



}



if ($combinedOutput -match 'y values must be 0 <= y <= 1') {



$errorLines += "ERROR EN MODELO BINOMIAL: La variable dependiente de respuesta debe estar codificada con valores numericos binarios previo al ajuste."



}



if ($combinedOutput -match 'response must have 3 or more levels') {



$errorLines += "ERROR EN REGRESION ORDINAL: La funcion polr() requiere obligatoriamente una variable dependiente con 3 o mas niveles o categorias. Si la variable de respuesta es binaria (posee unicamente dos categorias), queda TERMINANTEMENTE PROHIBIDO usar polr(); se debe utilizar la funcion glm(family = binomial) o glm(family = binomial(link = 'probit'))."



try {



$rawFix = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)



$polrRegex = '\bpolr\s*\(\s*([a-zA-Z0-9_\.]+)\s*~\s*([^,]+)\s*,\s*(?:data\s*=\s*)?([a-zA-Z0-9_\.]+)[^)]*\)'



if ($rawFix -match $polrRegex) {



$dep = $matches[1]



$preds = $matches[2]



$dat = $matches[3]



$fam = if ($rawUserGoalCheck -match '(?i)probit') { 'binomial(link = "probit")' } else { 'binomial' }



$rawFix = [regex]::Replace($rawFix, $polrRegex, "glm($dep ~ $preds, data = $dat, family = $fam, na.action = na.omit)")



$rawFix = [regex]::Replace($rawFix, '\[([^\]]*?),\s*[''"]Value[''"]\s*\]', '[$1, "Estimate"]')



$rawFix = [regex]::Replace($rawFix, '\[([^\]]*?),\s*[''"]t value[''"]\s*\]', '[$1, "z value"]')



[System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawFix, $utf8NoBom)



Write-Host "[AUTORREPARACION DETERMINISTA] Se convirtio polr() a glm(family=$fam) y se alinearon columnas para resolver variable dependiente binaria." -ForegroundColor Green



}



} catch {}



}



if (($combinedOutput -match 'subíndice fuera de los límites|subscript out of bounds') -and ($combinedOutput -match 'Value|t value' -or $codeForChecks -match '\[([^\]]*?),\s*[''"](?:Value|t value)[''"]\s*\]')) {



$errorLines += "ERROR EN ACCESO A COEFICIENTES GLM: Se intento acceder a la columna 'Value' o 't value' (propia de polr), pero el modelo estimado es glm(), cuyas columnas son 'Estimate', 'Std. Error', 'z value' y 'Pr(>|z|)'."



try {



$rawFix = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)



$rawFix = [regex]::Replace($rawFix, '\[([^\]]*?),\s*[''"]Value[''"]\s*\]', '[$1, "Estimate"]')



$rawFix = [regex]::Replace($rawFix, '\[([^\]]*?),\s*[''"]t value[''"]\s*\]', '[$1, "z value"]')



[System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawFix, $utf8NoBom)



Write-Host "[AUTORREPARACION DETERMINISTA] Se corrigieron columnas 'Value'/'t value' a 'Estimate'/'z value' para compatibilidad con glm()." -ForegroundColor Green



} catch {}



}

    if (($combinedOutput -match 'subíndice fuera de los límites|subscript out of bounds') -and ($combinedOutput -match 'Estimate|z value' -or $codeForChecks -match '\[([^\]]*?),\s*[''"](?:Estimate|z value)[''"]\s*\]') -and ($codeForChecks -match '\bpolr\s*\(')) {

        $errorLines += "ERROR EN ACCESO A COEFICIENTES POLR: Se intento acceder a la columna 'Estimate' o 'z value' (propia de glm), pero el modelo estimado es polr(), cuyas columnas en coef(summary(fit)) son 'Value', 'Std. Error' y 't value'."

        try {

            $rawFix = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)

            $rawFix = [regex]::Replace($rawFix, '\[([^\]]*?),\s*[''"]Estimate[''"]\s*\]', '[$1, "Value"]')

            $rawFix = [regex]::Replace($rawFix, '\[([^\]]*?),\s*[''"]z value[''"]\s*\]', '[$1, "t value"]')

            [System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawFix, $utf8NoBom)

            Write-Host "[AUTORREPARACION DETERMINISTA] Se corrigieron columnas 'Estimate'/'z value' a 'Value'/'t value' para compatibilidad con polr()." -ForegroundColor Green

        } catch {}

    }



if ($combinedOutput -match 'unknown label\(s\) in variable definition') {



$errorLines += "ERROR SINTACTICO DE MEDIACION EN LAVAAN: En lavaan, para computar efectos indirectos con ':=', es OBLIGATORIO colocar etiquetas multiplicadoras en los senderos estructurales (ej. 'M ~ a * X' e 'Y ~ b * M', y luego 'indirecto := a * b'). Queda TERMINANTEMENTE PROHIBIDO usar etiquetas en ':=' sin haberlas declarado previamente como multiplicadores en las regresiones con '~'."



}



if ($hasSecondOrderConfusion) {



$errorLines += "ERROR PSICOMETRICO: Se solicito un modelo bifactorial, pero se formulo una estructura jerarquica donde un factor carga sobre otros factores. En una formulacion bifactorial autentica, la dimension general carga directamente sobre todas las variables observadas simultaneamente con los factores especificos sobre sus propios indicadores, manteniendo independencia ortogonal total entre todas las dimensiones."



}



# [FIX M7] $codeForChecks se inicializa antes del bloque de diagnóstico para asegurar su disponibilidad desde el intento 1.

if ($combinedOutput -match 'some categories of variable .* are empty in group' -or $combinedOutput -match 'frequencies are' -or $combinedOutput -match 'check the group\.label argument' -or $combinedOutput -match 'group variable .* contains missing values') {



if ($codeForChecks -match '(?m)^[^#\r\n]*\bgroup\s*=') {



$errorLines += "ERROR ARQUITECTONICO DE INVARIANZA: En Charly queda TERMINANTEMENTE PROHIBIDO utilizar modelos multigrupo (group = ...). Toda evaluacion de invarianza de medicion y DIF se realiza EXCLUSIVAMENTE mediante MODELOS MIMIC (Muthen, 1989) estimando un modelo base estructural (Factor ~ covariable_grupo) y evaluando los Score Tests univariados iterativos (lavTestScore con epc = TRUE, 1 gl) con correccion de Bonferroni. Reemplaza de inmediato todo intento de CFA multigrupo por la formulacion canonica MIMIC."



} else {



$errorLines += "ERROR DE CATEGORIA VACIA EN LAVAAN: Se detectaron categorias ordinales con frecuencia cero en la muestra activa. Si el modelo incluye covariables predictoras exogenas con NAs o recodificadas a NA, DEBES filtrar previamente los casos de la covariable con datos <- datos[!is.na(datos`$covariable), ] antes de llamar a sem(). Esto evita que lavaan reserve categorias vacias y aborte."



try {



$rawFix = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)



$recodedColsFix = @([regex]::Matches($rawFix, 'datos(?:\$([a-zA-Z0-9_\.]+)|\[\[["'']([a-zA-Z0-9_\.]+)["'']\]\]).*?<-\s*NA') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } } | Select-Object -Unique)



$factorLHSFix = @([regex]::Matches($rawFix, '(?m)^\s*([a-zA-Z0-9_\.]+)\s*=~') | ForEach-Object { $_.Groups[1].Value })



$factorRHSFix = @([regex]::Matches($rawFix, '(?m)^\s*([a-zA-Z0-9_\.]+)\s*=~\s*([^\r\n#]+)') | ForEach-Object { $_.Groups[2].Value -split '\+' | ForEach-Object { ($_ -replace '^.*\*', '').Trim() } })



foreach ($colFix in $recodedColsFix) {



if ($factorLHSFix -notcontains $colFix -and $factorRHSFix -notcontains $colFix -and $rawFix -match "~\s*[^#\r\n]*\b$colFix\b") {



if ($rawFix -notmatch "!is\.na\s*\(\s*datos(?:\`$|\[\[['""])$colFix") {



$fLine = "datos <- datos[!is.na(datos[['$colFix']]), ]"



if ($rawFix -match '(?m)(#\s*Definici|modelo.*?<-)') {



$rawFix = [regex]::Replace($rawFix, "(?m)(#\s*Definici|modelo.*?<-)", "$fLine`r`n`r`n`$1", 1)



} else {



$rawFix = [regex]::Replace($rawFix, "(?m)(sem\s*\()", "$fLine`r`n`r`n`$1", 1)



}



[System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawFix, $utf8NoBom)



Write-Host "[AUTORREPARACION DETERMINISTA] Se inyecto filtrado de NAs para '$colFix' para resolver categoria vacia." -ForegroundColor Green



}



}



}



} catch {}



}



}



if ($combinedOutput -match 'different set of observed variables' -or $combinedOutput -match 'argumentos no compatibles' -or $combinedOutput -match 'ginv\(Delta1\)') {
    $errorLines += "ERROR EN EVALUACION DE INVARIANZA / DIF: Queda TERMINANTEMENTE PROHIBIDO comparar modelos con conjuntos dispares de variables observadas mediante lavTestLRT. En el sistema Charly, la evaluacion de DIF e invarianza de medicion se realiza EXCLUSIVAMENTE mediante el Score Test (Multiplicador de Lagrange) sobre el modelo multidimensional completo en un unico paso asintotico usando lavTestScore(fit_base, add = add_syntax, epc = TRUE)."
}

if ($combinedOutput -match 'Delta\.group' -or $combinedOutput -match 'no es un m[uú]ltiplo de la longitud del reemplazo' -or $combinedOutput -match 'lav_model_delta') {
    $errorLines += "ERROR CRITICO EN LAVTESTSCORE (MIMIC DIF): En lavTestScore(fit_base, add = p_syn), la covariable exogena del sendero 'item ~ covariable' NO esta incluida en el modelo base 'fit_base'. En un modelo MIMIC, las covariables DEBEN estar incluidas obligatoriamente en el modelo base estimando las regresiones estructurales sobre los factores latentes (ej. Factor1 ~ covariable1 + covariable2, Factor2 ~ ...) usando sem() (PROHIBIDO usar cfa() sin las covariables)."
}

if (($combinedOutput -match 'replacement has length zero|longitud cero') -and ($codeForChecks -match '\blavTestScore')) {
        $errorLines += "ERROR EN ACCESO A P-VALUE DE LAVTESTSCORE: lavTestScore() devuelve una lista con `$test, `$uni y `$epc. Acceder directamente a `$pvalue o `$p.value en la raiz del objeto retorna NULL, provocando 'replacement has length zero'. El p-value univariado debe extraerse como `$test`$p.value o mediante rbind(res_dif, st`$uni)."
        try {
            $rawFix = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)
            $scoreVarsFix = @([regex]::Matches($rawFix, '\b([a-zA-Z0-9_]+)\s*(?:<-|=)\s*(?:suppressWarnings\s*\(\s*)?lavTestScore') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            $modifiedScore = $false
            foreach ($sVar in $scoreVarsFix) {
                if ($rawFix -match "\b$sVar\`$(?:pvalue|p\.value)\b(?!\s*\[)") {
                    $rawFix = [regex]::Replace($rawFix, "\b$sVar\`$(?:pvalue|p\.value)\b(?!\s*\[)", "$sVar`$test`$p.value")
                    $modifiedScore = $true
                }
            }
            if ($modifiedScore) {
                [System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawFix, $utf8NoBom)
                Write-Host "[AUTORREPARACION DETERMINISTA] Se corrigio el acceso a p-value en objeto lavTestScore a `$test`$p.value." -ForegroundColor Green
            }
        } catch {}
    }

    if ($combinedOutput -match 'missing values \(NAs\) in the correlation matrix do not allow me to continue' -or $combinedOutput -match 'Likely variables with missing values are') {
        $errorLines += "ERROR EN MANEJO DE FALTANTES EN PSYCH (ACP/AFE): En psych::principal() y psych::fa(), el argumento para observaciones con NAs es estrictamente 'use = `"pairwise`"' (o 'use = `"complete`"'). Queda TERMINANTEMENTE PROHIBIDO usar 'cor = `"pairwise`"' o 'cor = `"pairwise.complete.obs`"'. Ademas, si persisten NAs, debe calcularse previamente la matriz de correlaciones con r_mat <- cor(datos[, items], use = 'pairwise.complete.obs') y pasarse directamente a principal(r_mat, nfactors = k, rotate = 'varimax', n.obs = nrow(datos))."
        try {
            $rawFix = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)
            $modifiedFix = $false
            if ($rawFix -match '(?i)\b(?:principal|fa)\s*\([^)]*?\buse\s*=') {
                $rawFix = [regex]::Replace($rawFix, '(?i)(?<=\b(?:principal|fa)\s*\([^)]*),\s*cor\s*=\s*["''](?:pairwise|pairwise\.complete\.obs|complete\.obs|complete)["'']', '')
                $rawFix = [regex]::Replace($rawFix, '(?i)(?<=\b(?:principal|fa)\s*\(\s*)\bcor\s*=\s*["''](?:pairwise|pairwise\.complete\.obs|complete\.obs|complete)["'']\s*,\s*', '')
                $modifiedFix = $true
            } else {
                if ($rawFix -match '(?i)(?<=\b(?:principal|fa)\s*\([^)]*)\bcor\s*=\s*["''](?:pairwise|pairwise\.complete\.obs|complete\.obs|complete)["'']') {
                    $rawFix = [regex]::Replace($rawFix, '(?i)(?<=\b(?:principal|fa)\s*\([^)]*)\bcor\s*=\s*["''](?:pairwise|pairwise\.complete\.obs|complete\.obs|complete)["'']', 'use = "pairwise"')
                    $modifiedFix = $true
                } elseif ($rawFix -match '(\bprincipal\s*\(\s*[^,]+,\s*nfactors\s*=\s*[^,]+,\s*rotate\s*=\s*[^,\)]+)([^)]*\))') {
                    $rawFix = [regex]::Replace($rawFix, '(\bprincipal\s*\(\s*[^,]+,\s*nfactors\s*=\s*[^,]+,\s*rotate\s*=\s*[^,\)]+)([^)]*\))', '$1, use = "pairwise"$2')
                    $modifiedFix = $true
                }
            }
            if ($modifiedFix) {
                [System.IO.File]::WriteAllText((Resolve-Path $ScriptPath), $rawFix, $utf8NoBom)
                Write-Host "[AUTORREPARACION DETERMINISTA] Se corrigio el manejo de NAs en psych (use = `"pairwise`")." -ForegroundColor Green
            }
        } catch {}
    }

if ($contractAuditPassed -eq $false -and $auditResult) {



$errorLines += "!!! INCUMPLIMIENTO DEL CONTRATO PSICOMETRICO DETECTADO (EL SCRIPT COMPILO PERO OMITIO ENTREGABLES OBLIGATORIOS) !!!"



foreach ($dr in $auditResult.DirectivasReparacion) {



$errorLines += "  * $dr"



}



}



$warningsFormatted = if ($errorLines.Count -gt 0) {



"!!! ERROR CRITICO DE R DETECTADO (LINEA EXACTA DEL FALLO) !!!`r`n" + ($errorLines -join "`r`n") + "`r`n`r`nDetalles completos del entorno y avisos:`r`n" + ($cleanLines -join "`r`n")



} elseif ($allLavaanWarnings.Count -gt 0) {



$allLavaanWarnings -join "`r`n"



} else {



$cleanLines -join "`r`n"



}



$lastErrorEncountered = $warningsFormatted



$currentCode = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)



# Desinfeccion preventiva de markdown y comentarios residuales en el codigo a reparar:



$cleanCurrentCode = $currentCode
if ($cleanCurrentCode -match '(?s)```[ \t]*(?:[rR]|rscript)?[ \t]*\r?\n(.*?)(?:```|\Z)') {
    $cleanCurrentCode = $matches[1]
} elseif ($cleanCurrentCode -match '(?s)```\s*\r?\n(.*?)(?:```|\Z)') {
    $cleanCurrentCode = $matches[1]
} else {
    $cleanCurrentCode = [regex]::Replace($cleanCurrentCode, '^\s*```[A-Za-z{}]*[ \t]*(?:\r?\n|$)', '')
    $fenceIdx2 = $cleanCurrentCode.IndexOf('```')
    if ($fenceIdx2 -ge 0) { $cleanCurrentCode = $cleanCurrentCode.Substring(0, $fenceIdx2) }
}
$cleanCurrentCode = [regex]::Replace($cleanCurrentCode, '^\s*`+\s*(?:r|R)?\s*(\r?\n|$)', '')
$cleanCurrentCode = [regex]::Replace($cleanCurrentCode, '^\s*(?:r|R)\s*\r?\n', '')
$cleanCurrentCode = $cleanCurrentCode.Trim()



$userGoalText = ""



if (Test-Path "workspace/user_goal.txt") {



$userGoalText = [System.IO.File]::ReadAllText((Resolve-Path "workspace/user_goal.txt"), [System.Text.Encoding]::UTF8)



}



# Construir el prompt de reparacion de forma modular y compacta para no desbordar el contexto de Seru Giran (12k)



$sheetRule = ""



$profilePath = "workspace/dataset_profile.json"



if (Test-Path $profilePath) {



try {



$prof = Get-Content $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json



if ($prof.hoja) { $sheetRule = "(sheet = '$($prof.hoja)')" }



} catch {}



}



$fence = '```'



$compactRules = @"
- Manten el codigo R limpio, humano y conciso.
- Sin sink(), sin bucles de instalacion de paquetes, sin tryCatch().
- Devuelve unicamente el bloque de codigo R corregido dentro de ${fence}r y ${fence}.
"@



$trimmedWarnings = (($warningsFormatted -split "`r?`n" | Select-Object -First 50) -join "`r`n")



$repairParts = @(



"Eres un investigador psicometrista y analista de datos en R.",



"Tu tarea es corregir el siguiente script de R que produjo un error durante su ejecucion:",



"",



"================================================================================",



"SOLICITUD ORIGINAL DEL INVESTIGADOR:",



"================================================================================",



$userGoalText,



"",



"================================================================================",



"ERROR DETECTADO EN R:",



"================================================================================",



$trimmedWarnings,



"",



"================================================================================",



"CODIGO R A CORREGIR:",



"================================================================================",



$cleanCurrentCode,



"",



"================================================================================",



"DIRECTIVAS:",



"================================================================================",



"1. Corrige el error respetando fielmente la solicitud del investigador.",



"2. Si una funcion accesoria no solicitada expresamente provoco el fallo, eliminala del script.",



"3. Manten el codigo R limpio, conciso y elegante, sin sink(), sin bucles de instalacion y PROHIBIDO envolver cfa() o sem() en tryCatch().",



"4. Devuelve UNICAMENTE el bloque de codigo R corregido dentro de ${fence}r ... ${fence}."



)



$repairPrompt = $repairParts -join "`r`n"



$repairFile = "workspace/repair_prompt.txt"



$fullRepairPath = [System.IO.Path]::GetFullPath($repairFile)



[System.IO.File]::WriteAllText($fullRepairPath, $repairPrompt, $utf8NoBom)



if ($Engine -eq "cloud") {



& powershell -NoProfile -ExecutionPolicy Bypass -File "engine/gemini_engine.ps1" -PromptFile $repairFile -OutputFile $ScriptPath



} else {



$repairTemp = [Math]::Min(0.7, 0.15 + ($attempt * 0.15))



& powershell -NoProfile -ExecutionPolicy Bypass -File "engine/local_engine.ps1" -PromptFile $repairFile -OutputFile $ScriptPath -Temperature $repairTemp



}



}



exit 1



