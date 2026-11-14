# ==============================================================================
# CHARLY v4.0 - PARSER Y NORMALIZADOR PSICOMETRICO DETERMINISTA
# ==============================================================================
# Extrae con precision matematica y conceptual directivas desde el texto del usuario:
# 1. Higiene de datos: recodificacion de faltantes (puntual o general)
# 2. Excepciones continuas en modelos ordinales (para aplicar setdiff)
# 3. Senderos causales con flechas (Destino ~ Origen)
# 4. Informacion de variable dependiente y cardinalidad (glm vs polr)
# ==============================================================================

function Remove-DiacriticsText ([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return "" }
    $normalized = $text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $normalized.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

function Get-MissingDirectives {
    param(
        [string]$UserPrompt,
        [array]$AvailableColumns = @()
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ([string]::IsNullOrWhiteSpace($UserPrompt)) { return $results }

    # Verificar cancelacion explicita de faltantes en la directiva global
    $cancPattern = '(?i)\b(?:me\s+equivoqu[eé]\s+no\s+(?:van?|corren?)\s+(?:los\s+)?faltantes?|no\s+(?:corren?|van?|aplican?)\s+(?:los\s+)?(?:datos\s+)?faltantes?|olv[ií]date\s+de\s+(?:los\s+)?faltantes?|sin\s+(?:datos\s+)?faltantes?|cero\s+faltantes?|anular\s+(?:los\s+)?faltantes?)\b'
    if ($UserPrompt -match $cancPattern) { return $results }

    $norm = Remove-DiacriticsText $UserPrompt
    $clauses = $norm -split '[\.;\r\n]+|,\s*(?=(?:y\s+|e\s+)?(?:en|para|sobre)\s+[a-zA-Z])' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }

    foreach ($rawClause in $clauses) {
        $c = $rawClause.Trim()
        # La clausula debe referirse a faltantes
        if ($c -notmatch '(?i)\b(faltantes?|perdidos?|na|ausentes?)\b') { continue }
        if ($c -match '(?i)\b(no\s+corre|no\s+va|sin\s+faltantes|olvidate)\b') { continue }

        # Aislar sub-clausulas de inversion de items dentro de la misma oracion separada por comas
        # Se quitan SOLO el verbo de inversion y el/los item(s) invertidos (no el resto de la clausula), para que un item
        # invertido no se confunda con una columna a recodificar y para no perder la parte de faltantes ("invertir I8 y recodificar los 7...").
        $cForMissing = $c -replace '(?i)\b[a-zA-Z]\w*\d\w*\s+(?:esta\s+|es\s+|estan\s+|son\s+)?invert\w*', ' ' `
                          -replace '(?i)\binvert\w*\s+(?:(?:el|la|los|las|item|items|reactivo|reactivos|variable|variables|polaridad|escala|del|de)\s+)*[a-zA-Z]\w*\d\w*(?:\s*(?:,|y|e)\s+[a-zA-Z]\w*\d\w*)*', ' '

        # Extraer numeros (e.g. "valores 7", "valores 3 y 4", "valor 4", "codigo 7", "valores 7 u 8")
        $nums = [System.Collections.Generic.List[int]]::new()
        $numMatches = [regex]::Matches($cForMissing, '(?i)(?:valores?|c[oó]digos?|c[oó]digo|marcados?\s+con)\s+([0-9\s,yye\-]+)')
        foreach ($nm in $numMatches) {
            $digits = [regex]::Matches($nm.Groups[1].Value, '\b\d+\b')
            foreach ($d in $digits) {
                $valInt = [int]$d.Value
                if (-not $nums.Contains($valInt)) { $nums.Add($valInt) }
            }
        }
        # Fallback para "codigo 7" o numeros aislados entre 3 y 99
        if ($nums.Count -eq 0) {
            $digits = [regex]::Matches($cForMissing, '\b\d+\b')
            foreach ($d in $digits) {
                $valInt = [int]$d.Value
                if ($valInt -ge 3 -and $valInt -le 99) {
                    if (-not $nums.Contains($valInt)) { $nums.Add($valInt) }
                }
            }
        }

        if ($nums.Count -eq 0) { continue }

        # Ambito general explicito (e.g. "en cualquier indicador", "en cualquiera de las 4 variables", "en todos los reactivos")
        $isExplicitGeneral = ($cForMissing -match '(?i)\b(cualquier\s+indicador|cualquiera\s+de\s+las?|todas\s+las?\s+variables?|cualquiera\s+de\s+los?|todos\s+los?\s+(?:reactivos|indicadores|items|variables)|en\s+todos\s+los?\s+(?:reactivos|indicadores|items|variables))\b')

        # Buscar columnas presentes en la clausula
        $matchedCols = [System.Collections.Generic.List[string]]::new()
        if ($AvailableColumns.Count -gt 0) {
            foreach ($col in $AvailableColumns) {
                $colNorm = Remove-DiacriticsText $col
                $colEsc = [regex]::Escape($colNorm) -replace '_', '[ _]'
                if ($cForMissing -match "(?i)\b$colEsc\b") {
                    if (-not $matchedCols.Contains($col)) { $matchedCols.Add($col) }
                }
            }
        }

        # Si no se encontraron por AvailableColumns y no es general explicito, extraer variables nombradas tras conectores SOLO si no habia AvailableColumns
        if ($matchedCols.Count -eq 0 -and (-not $isExplicitGeneral) -and $AvailableColumns.Count -eq 0) {
            $colPattern = '(?i)(?:en|de|del|para|sobre)\s+(?:la\s+variable\s+|el\s+[ií]tem\s+|los\s+[ií]tems\s+|las\s+variables\s+)?([a-zA-Z0-9_,\s+yye\-]+)'
            $cMatches = [regex]::Matches($c, $colPattern)
            foreach ($cm in $cMatches) {
                $rawList = $cm.Groups[1].Value
                $toks = $rawList -split '[,;\s]+|\b(?:y|e|u|o)\b' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
                foreach ($tok in $toks) {
                    $cleanTok = $tok.Trim()
                    if ($cleanTok -match '(?i)^(?:el|la|los|las|item|items|reactivo|reactivos|modelo|variable|variables|de|del|en|para|sobre|como|debe|deben|tomar|tomarse|tomarlo|tomarlos|tratar|tratarlo|tratarlos|datos?|faltantes?|perdidos?|ausentes?|na|resto|no|aplica|aplican|tocar|tocarse|recodificar|valor|valores|codigo|codigos|todos|todas|considerar|considerarse|considerado|considerada|es|son|sabe|contesta|asi|que|ponelo|poner|ponerlo|si|hubiera|algun|alguno|alguna)$') { continue }
                    if ($cleanTok -match '^[a-zA-Z][a-zA-Z0-9_\.]*$' -and -not $matchedCols.Contains($cleanTok)) {
                        $matchedCols.Add($cleanTok)
                    }
                }
            }
        }

        if ($isExplicitGeneral -or $matchedCols.Count -eq 0) {
            $results.Add([PSCustomObject]@{
                Tipo     = "General"
                Columnas = @()
                Valores  = @($nums)
                Clausula = $c
            })
        } else {
            $results.Add([PSCustomObject]@{
                Tipo     = "Puntual"
                Columnas = @($matchedCols)
                Valores  = @($nums)
                Clausula = $c
            })
        }
    }

    return $results
}

function Get-ContinuousExceptions {
    param([string]$UserPrompt)
    $exceptions = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($UserPrompt)) { return $exceptions }

    # Si existen especificaciones confirmadas por el asistente metodologico, son la AUTORIDAD MAXIMA:
    if ($UserPrompt -match '(?i)Excepciones de tipo de variable:[^\r\n]*?:\s*([a-zA-Z0-9_,\s]+?)\.(?:\s+Usar|\r?\n|$)') {
        $raw = $Matches[1]
        $tokens = $raw -split '[,;\s]+' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
        foreach ($tok in $tokens) {
            $clean = $tok.Trim()
            if ($clean -match '^[a-zA-Z0-9_\.]+$' -and -not $exceptions.Contains($clean)) {
                $exceptions.Add($clean)
            }
        }
        if ($exceptions.Count -gt 0) { return $exceptions }
    }

    $norm = Remove-DiacriticsText $UserPrompt
    $pats = @(
        '(?i)(?:salvo|excepto|menos|con\s+excepcion\s+de)\s+(?:a\s+)?(?:los?\s+|las?\s+)?(?:items?\s+|variables?\s+|columnas?\s+)?([a-zA-Z0-9_\.\s,yye]+?)\s+que\s+(?:son|es|deben?\s+ser)\s+(?:tratad[ao]s?\s+como\s+)?continu[ao]s?',
        '(?i)(?:salvo|excepto|menos)\s+(?:a\s+)?(?:los?\s+|las?\s+)?(?:items?\s+|variables?\s+|columnas?\s+)?([a-zA-Z0-9_\.\s,yye]+?)\s+continu[ao]s?',
        '(?i)(?:tratar|tratal[ao]s?|tratarlo|tratarla|declarar|declaral[ao]s?|tomar|tomal[ao]s?|considerar|consideral[ao]s?|poner|ponel[ao]s?)\s+(?:a\s+)?(?:los?\s+|las?\s+)?(?:items?\s+|variables?\s+|columnas?\s+)?([a-zA-Z0-9_\.\s,yye]+?)\s+como\s+(?:variables?\s+)?continu[ao]s?',
        '(?i)\b([a-zA-Z0-9_\.]+)\s+es\s+continu[ao]\b'
    )

    foreach ($p in $pats) {
        $matches = [regex]::Matches($norm, $p)
        foreach ($m in $matches) {
            $rawVars = $m.Groups[1].Value.Trim()
            $tokens = $rawVars -split '[,;\s]+|\b(?:y|e)\b' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
            foreach ($tok in $tokens) {
                $clean = $tok.Trim()
                if ($clean -match '(?i)^(?:el|la|los|las|item|items|variable|variables|columna|columnas|que|son|es|debe|deben|ser|tratada|tratado|tratadas|tratados|como|salvo|menos|excepto|declarar|tratar|considerar|poner)$') { continue }
                if ($clean -match '^[a-zA-Z0-9_\.]+$' -and -not $exceptions.Contains($clean)) {
                    $exceptions.Add($clean)
                }
            }
        }
    }
    return $exceptions
}

function Get-ArrowDirectives {
    param(
        [string]$UserPrompt,
        [array]$KnownConstructs = @()
    )
    $directives = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ([string]::IsNullOrWhiteSpace($UserPrompt)) { return $directives }

    $norm = Remove-DiacriticsText $UserPrompt
    # Variantes de flecha tipograficas (→, ⟶, ➔, =>, –>, —>) se normalizan a "->" para que no se pierdan senderos en silencio
    $norm = $norm -replace '[\u2192\u27F6\u2794\u279C\u279E]|=>|\u2013>|\u2014>|\u2212>', '->'
    $lines = $norm -split '\r?\n'

    $stopWords = @(
        'ademas', 'del', 'de', 'la', 'las', 'el', 'los', 'un', 'una', 'unos', 'unas',
        'factor', 'factores', 'segundo', 'orden', 'sendero', 'senderos', 'estructural',
        'estructurales', 'adicional', 'adicionales', 'modelo', 'sem', 'con', 'su', 'sus',
        'en', 'por', 'para', 'sobre', 'entre', 'cada', 'todas', 'todos', 'coeficiente',
        'coeficientes', 'regresion', 'regresiones', 'reportar', 'reporte', 'imprimir',
        'mostrar', 'calcular', 'pedir', 'solicitar', 'valor', 'pvalor', 'tabla', 'ajuste',
        'medida', 'datos', 'base', 'variable', 'variables', 'item', 'items', 'reactivo',
        'reactivos', 'ir', 'va', 'van', 'hacia', 'desde', 'indicador', 'indicadores'
    )

    $inReportSection = $false

    # Identificar factores declarados expresamente como de segundo orden (sus flechas salientes son cargas '=~', no regresiones '~')
    $secondOrderFactors = [System.Collections.Generic.List[string]]::new()
    $soMatches1 = [regex]::Matches($norm, '(?i)factor\s+["'']?([a-zA-Z][a-zA-Z0-9_]*)["'']?\s*,?\s*de\s+(?:segundo\s+orden|2do\s+orden|orden\s+superior)')
    foreach ($m in $soMatches1) { $secondOrderFactors.Add($m.Groups[1].Value.ToLowerInvariant()) }
    $soMatches2 = [regex]::Matches($norm, '(?i)factor\s+de\s+(?:segundo\s+orden|2do\s+orden|orden\s+superior)\s+["'']?([a-zA-Z][a-zA-Z0-9_]*)["'']?')
    foreach ($m in $soMatches2) {
        $v = $m.Groups[1].Value.ToLowerInvariant()
        if ($stopWords -notcontains $v -and -not $secondOrderFactors.Contains($v)) { $secondOrderFactors.Add($v) }
    }

    foreach ($line in $lines) {
        $trimLine = $line.Trim()
        # Ignorar lineas de encabezado tipo "TAREA 01: ... F5->F7"
        if ($trimLine -match '(?i)^TAREA\s+\d+:') { continue }

        # Detectar seccion de reporte/salida para no confundir requisitos de salida con especificacion del modelo
        if ($trimLine -match '(?i)^\s*reportar\s*:') {
            $inReportSection = $true
            continue
        }

        if ($inReportSection) {
            # Si se inicia una nueva seccion de modelado, reanudar parsing
            if ($trimLine -match '(?i)^(?:modelo|especificaciones|senderos?|variables?)\s*:') {
                $inReportSection = $false
            } else {
                continue
            }
        }

        if ($trimLine -match '->') {
            # Extraer pares limpios de flechas: ORIGEN -> DESTINO (admitiendo listas de origenes separadas por + o comas)
            $arrowMatches = [regex]::Matches($trimLine, '(?:\b|\()([a-zA-Z][a-zA-Z0-9_]*(?:\s*(?:,|\+|\be\b|\by\b)\s*[a-zA-Z][a-zA-Z0-9_]*)*)\s*->\s*([a-zA-Z][a-zA-Z0-9_]*)')
            foreach ($am in $arrowMatches) {
                $rawOrig = $am.Groups[1].Value.Trim()
                $destToken = $am.Groups[2].Value.Trim()

                # Validar que destino sea identificador limpio y no una palabra común
                if ($destToken -match '^[a-zA-Z][a-zA-Z0-9_]*$' -and $stopWords -notcontains $destToken.ToLowerInvariant()) {
                    # Extraer tokens de origen
                    $rawTokens = $rawOrig -split '[,;\s]+|\b(?:y|e)\b'
                    $cleanOrigs = @($rawTokens | Where-Object {
                        ![string]::IsNullOrWhiteSpace($_) -and
                        $_ -match '^[a-zA-Z][a-zA-Z0-9_]*$' -and
                        $stopWords -notcontains $_.ToLowerInvariant()
                    })

                    # Excluir origenes que sean factores de segundo orden (sus flechas hacia 1er orden son '=~', no '~')
                    $cleanOrigs = @($cleanOrigs | Where-Object { -not $secondOrderFactors.Contains($_.ToLowerInvariant()) })

                    if ($cleanOrigs.Count -gt 0) {
                        $existingDest = $directives | Where-Object { $_.Destino -eq $destToken } | Select-Object -First 1
                        if ($existingDest) {
                            foreach ($co in $cleanOrigs) {
                                if ($existingDest.Origenes -notcontains $co) {
                                    $existingDest.Origenes += $co
                                }
                            }
                            $existingDest.Lavaan = "$destToken ~ " + ($existingDest.Origenes -join " + ")
                        } else {
                            $directives.Add([PSCustomObject]@{
                                Destino  = $destToken
                                Origenes = @($cleanOrigs)
                                Lavaan   = "$destToken ~ " + ($cleanOrigs -join " + ")
                            })
                        }
                    }
                }
            }
        }
    }
    return $directives
}


# ==============================================================================
# FIABILIDAD COMPUESTA (CR) NATIVA - fuente unica para prompt, contrato, auditor y reparador
# ==============================================================================
# Las funciones empaquetadas (semTools::compRelSEM / reliability / compositeRel) colapsan en modelos de segundo orden con
# estimador ordinal (WLSMV), missing = "pairwise" y covariables (comprobado: "SDs[[b]] %*% SIGMA[[b]]", "subindice fuera de
# los limites"; compositeRel() ni siquiera existe en semTools >= 0.5-9). La CR se calcula a mano con las cargas estandarizadas:
#   CR = (sum(lambda))^2 / ((sum(lambda))^2 + sum(1 - lambda^2))

function Test-CompositeReliabilityRequested {
    param([string]$UserPrompt)
    if ([string]::IsNullOrWhiteSpace($UserPrompt)) { return $false }
    $txt = Remove-DiacriticsText (($UserPrompt -split '={20,}')[0])
    # 'CR' y '(FC)' se buscan respetando mayusculas para no confundir con otras palabras
    return [bool]($txt -match '(?i)(?:fiabilidad|confiabilidad)\s+compuesta|composite\s+reliability|(?-i:\bCR\b|\(\s*FC\s*\))')
}

function Get-NativeCompositeReliabilityRCode {
    param([string]$FitName = "fit")
    $code = @'
cat("\n--- FIABILIDAD COMPUESTA (CR) por factor: (sum(lambda))^2 / ((sum(lambda))^2 + sum(1 - lambda^2)) ---\n")
ss_cr <- lavaan::standardizedSolution(@@FIT@@)
ld_cr <- ss_cr[ss_cr$op == "=~", ]
cr_tab <- do.call(rbind, lapply(unique(ld_cr$lhs), function(f) {
  lam <- ld_cr$est.std[ld_cr$lhs == f]
  data.frame(Factor = f, Indicadores = length(lam), CR = round(sum(lam)^2 / (sum(lam)^2 + sum(1 - lam^2)), 3))
}))
print(cr_tab, row.names = FALSE)
'@
    return $code.Replace("@@FIT@@", $FitName).TrimEnd()
}

function Get-CompositeReliabilityRule {
    return @(
        "REGLA DE FIABILIDAD COMPUESTA (CR) - CALCULO NATIVO OBLIGATORIO:",
        "   * PROHIBIDO usar semTools::compRelSEM(), semTools::reliability(), compositeRel() u omega() empaquetados para la CR: colapsan en modelos de segundo orden con estimador ordinal (WLSMV), missing = 'pairwise' y covariables.",
        "   * Calcula la CR en R de forma nativa con las cargas estandarizadas extraidas del objeto fit, POR CADA FACTOR (de 1er y de 2do orden):",
        "     CR = (sum(lambda))^2 / ((sum(lambda))^2 + sum(1 - lambda^2))",
        "   * Muestra el valor de cada factor en consola con print()."
    ) -join "`r`n"
}
