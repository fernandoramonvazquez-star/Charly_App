# ==============================================================================
# CHARLY v4.0 - CONSTRUCTOR DEL CONTRATO DE EJECUCION PSICOMETRICA
# ==============================================================================
# Parsea la consigna textual del usuario y genera un contrato estructurado con:
# 1. Preprocesamiento (inversiones, recodificaciones a NA, filtrado de covariables).
# 2. Especificacion del modelo y funcion R obligatoria (PROHIBIENDO lavaan() a secas).
# 3. Checklist de entregables y metricas matematicas exactas.
# ==============================================================================

function Remove-ContractDiacritics ([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return "" }
    # Sanear posibles artefactos de encoding/mojibake UTF-8 decodificado como ANSI/Latin1
    $cleaned = $text -replace '(?i)\u00c3\u00a1|\u00c3\u0081|a\u00a1|Ã¡', 'a' `
                     -replace '(?i)\u00c3\u00a9|\u00c3\u0089|a\u00a9|Ã©', 'e' `
                     -replace '(?i)\u00c3\u00ad|\u00c3\u008d|a\u00ad|a-|Ã­|\u00ad', 'i' `
                     -replace '(?i)\u00c3\u00b3|\u00c3\u0093|a\u00b3|Ã³', 'o' `
                     -replace '(?i)\u00c3\u00ba|\u00c3\u009a|a\u00ba|Ãº', 'u' `
                     -replace '(?i)\u00c3\u00b1|\u00c3\u0091|a\u00b1|Ã±', 'n' `
                     -replace '\uFFFD', ''
    $normalized = ($cleaned.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', '')
    # Eliminar cualquier caracter no ASCII residual
    $asciiOnly = $normalized -replace '[^\x20-\x7E\r\n\t]', ''
    return $asciiOnly
}

function Get-CleanIdentifier {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $clean = ($Name.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', '') -replace '[^A-Za-z0-9_]', ''
    return $clean
}

function Get-CanonicalArchetype {
    param(
        [string]$UserPrompt = "",
        [array]$ArrowDirectives = @()
    )

    $rawText = ($UserPrompt -split '={20,}')[0]
    $normText = Remove-ContractDiacritics ($rawText.ToLower())

    # 1. SEM / NO RECURSIVO (Bucles y Feedback Loops)
    if ($normText -match '(?i)(?:retroalimentaci[oó]n|feedback\s+loop|no\s+recursiv|rec[ií]proc|bucle)') {
        return "SEM_NoRecursivo"
    }

    # 2. MIMIC & DIF: Factores ~ Covars / Score Test Muthen / Invarianza
    if ($normText -match '(?i)\b(mimic|invarianz?a|sesgo\s+de\s+[ií]tems?|muthen|score\s+test)\b') {
        return "MIMIC"
    }

    # 2b. Factor de segundo orden predicho por covariables (flechas) = MIMIC en segundo orden, salvo que se pida mediacion
    if ($normText -match '(?i)\b(segundo\s+orden|2do\s+orden|orden\s+superior|macro-factor|factor\s+superior|second-order|higher-order)\b' -and
        (($ArrowDirectives -and $ArrowDirectives.Count -gt 0) -or ($rawText -match '(?i)[A-Za-z0-9_]+\s*->\s*[A-Za-z0-9_]+')) -and
        $normText -notmatch '(?i)(?:mediaci|efectos?\s+indirectos?|efecto\s+total)') {
        return "MIMIC"
    }

    # 3. SEM / SENDEROS: Flechas explícitas (->), directivas de senderos o mediaciones confirmadas
    if (($ArrowDirectives -and $ArrowDirectives.Count -gt 0) -or 
        ($rawText -match '(?i)[A-Za-z0-9_]+\s*->\s*[A-Za-z0-9_]+') -or 
        ($normText -match '(?i)(?:senderos?|path\s+analysis|mediaci[oó]n|efectos?\s+indirectos?)')) {
        return "SEM_Senderos"
    }

    # 3. BIFACTORIAL: Factor general sobre todos los items + específicos ortogonales
    if ($normText -match '(?i)\b(?:bifact\w*|general-specific)\b') {
        return "Bifactor"
    }

    # 4. AFC DE SEGUNDO ORDEN: Macro-factor de segundo orden / factor superior
    if ($normText -match '(?i)\b(segundo\s+orden|2do\s+orden|orden\s+superior|macro-factor|factor\s+superior|second-order|higher-order)\b') {
        return "AFC_Segundo_Orden"
    }

    # 5. REGRESION PROBIT: clásica u ordinal
    if ($normText -match '(?i)\bprobit\b') {
        return "Regresion_Probit"
    }

        # 6. REGRESION LOGISTICA: clasica u ordinal (polr / glm)
    if ($normText -match '(?i)\b(?:log[ií]?stic\w*|log[ií]?t\w*|polr|odds\s*ratios?)\b' -or ($normText -match '(?i)\b(?:regresi[oó]?n|glm)\b' -and $normText -match '(?i)\bbinari[ao]\b')) {
        return "Regresion_Logistica"
    }

    # 7. AFE: Análisis Factorial Exploratorio (fa)
    if ($normText -match '(?i)(?:\bafe\b|factorial\s+explorat\w*|\bfa\(|ejes\s+principales)') {
        return "AFE"
    }

    # 8. ACP: Análisis de Componentes Principales (principal)
    if ($normText -match '(?i)\b(acp\b|componentes\s+principales|principal\()\b') {
        return "ACP"
    }

    # 9. AFC DE PRIMER ORDEN (Default para modelos confirmatorios/constructos con FC, AVE, Fornell-Larcker, HTMT y modindices)
    return "AFC_Primer_Orden"
}

function Get-InferredMediationChains {
    <#
    .SYNOPSIS
    Infiere cadenas de mediacion (X -> M -> ... -> Y) a partir de los senderos confirmados
    cuando el usuario pide "mediacion"/"efecto indirecto" en texto libre sin nombrar la cadena.
    Si la consigna nombra al menos dos variables en la oracion que pide la mediacion,
    solo se conservan los caminos cuyo origen y destino esten nombrados ahi.
    No inventa senderos: solo recorre los que el usuario ya declaro.
    #>
    param(
        [array]$Senderos = @(),
        [string]$UserPrompt = ""
    )

    $adj = [ordered]@{}
    foreach ($s in $Senderos) {
        $dst = if ($s.Destino) { $s.Destino.ToString().Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($dst)) { continue }
        foreach ($o in @($s.Origenes)) {
            $ot = if ($o) { $o.ToString().Trim() } else { "" }
            if ([string]::IsNullOrWhiteSpace($ot)) { continue }
            if (-not $adj.Contains($ot)) { $adj[$ot] = New-Object System.Collections.ArrayList }
            if ($adj[$ot] -notcontains $dst) { [void]$adj[$ot].Add($dst) }
        }
    }
    if ($adj.Count -eq 0) { return @() }

    $allNodes = New-Object System.Collections.ArrayList
    foreach ($k in $adj.Keys) {
        if ($allNodes -notcontains $k) { [void]$allNodes.Add($k) }
        foreach ($d in $adj[$k]) { if ($allNodes -notcontains $d) { [void]$allNodes.Add($d) } }
    }

    # Caminos simples de >= 3 nodos (al menos un mediador)
    $paths = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($node)
        [void]$stack.Add($node)
        if ($adj.Contains($node)) {
            foreach ($nx in $adj[$node]) {
                if ($stack -contains $nx) { continue }
                [void]$stack.Add($nx)
                if ($stack.Count -ge 3 -and $paths.Count -lt 50) { [void]$paths.Add(($stack -join ' -> ')) }
                $stack.RemoveAt($stack.Count - 1)
                & $walk $nx
            }
        }
        $stack.RemoveAt($stack.Count - 1)
    }
    foreach ($start in @($adj.Keys)) { & $walk $start }

    $paths = @($paths | Select-Object -Unique)
    if ($paths.Count -eq 0) { return @() }

    # Filtro por variables nombradas en la(s) oracion(es) que piden la mediacion
    $rawText = ($UserPrompt -split '={20,}')[0]
    $sentences = $rawText -split '(?<=[\.\n;])'
    $mentioned = @()
    foreach ($sent in $sentences) {
        $ns = Remove-ContractDiacritics ($sent.ToLower())
        if ($ns -notmatch '(?:mediaci|indirect|efecto\s+total)') { continue }
        foreach ($n in $allNodes) {
            $nn = (Remove-ContractDiacritics ($n.ToLower()))
            if ($nn -and $ns -match ('(?<![a-z0-9_])' + [regex]::Escape($nn) + '(?![a-z0-9_])') -and $mentioned -notcontains $n) {
                $mentioned += $n
            }
        }
    }
    if ($mentioned.Count -ge 2) {
        $paths = @($paths | Where-Object {
            $parts = $_ -split '\s*->\s*'
            ($mentioned -contains $parts[0]) -and ($mentioned -contains $parts[-1])
        })
        # Si ademas se nombra al mediador (>= 3 variables), solo se conservan los caminos cuyos mediadores estan TODOS
        # nombrados, descartando los tramos contenidos en otro camino mas largo (A->B->C dentro de A->B->C->D).
        if ($mentioned.Count -ge 3) {
            $paths = @($paths | Where-Object {
                $parts = $_ -split '\s*->\s*'
                $mid = @($parts[1..($parts.Count - 2)])
                @($mid | Where-Object { $mentioned -notcontains $_ }).Count -eq 0
            })
            $paths = @($paths | Where-Object {
                $cur = $_
                -not (@($paths | Where-Object { $_ -ne $cur -and (" -> " + $_ + " -> ").Contains(" -> " + $cur + " -> ") }).Count -gt 0)
            })
        }
    }
    return @($paths)
}

function Build-UniversalLavaanStructuralSyntax {
    <#
    .SYNOPSIS
    Generador matematico universal de sintaxis lavaan para regresiones estructurales,
    mediaciones (:=) y efectos totales a partir de la teoria de grafos (DAG).
    Garantiza etiquetado determinista y elimina alucinaciones de LLMs.
    #>
    param([object]$Contract)

    if (-not $Contract -or -not $Contract.Modelado) { return "" }
    $senderos = $Contract.Modelado.Senderos
    $mediaciones = $Contract.Modelado.Mediaciones

    if (-not $senderos -or $senderos.Count -eq 0) {
        return ""
    }

    $edgeLabels = @{}
    $regressionsByDest = [ordered]@{}

    foreach ($s in $senderos) {
        $dst = if ($s.Destino) { $s.Destino.ToString().Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($dst)) { continue }
        $dstClean = Get-CleanIdentifier $dst
        if (-not $regressionsByDest.Contains($dst)) {
            $regressionsByDest[$dst] = @()
        }
        $origs = if ($s.Origenes) { @($s.Origenes) } else { @() }
        foreach ($orig in $origs) {
            $origTrim = $orig.ToString().Trim()
            if ([string]::IsNullOrWhiteSpace($origTrim)) { continue }
            $origClean = Get-CleanIdentifier $origTrim
            $lbl = "p_${origClean}_${dstClean}"
            $edgeLabels["$origTrim->$dst"] = $lbl
            $edgeLabels["$origClean->$dstClean"] = $lbl
            $regressionsByDest[$dst] += @{ Origin = $origTrim; Label = $lbl }
        }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("  # --- REGRESIONES ESTRUCTURALES Y ETIQUETADO DETERMINISTA ---")
    foreach ($dst in $regressionsByDest.Keys) {
        $terms = @()
        foreach ($r in $regressionsByDest[$dst]) {
            $terms += "$($r.Label) * $($r.Origin)"
        }
        [void]$sb.AppendLine("  $dst ~ $($terms -join ' + ')")
    }

    $indirectPathsByPair = [ordered]@{}

    if ($mediaciones -and $mediaciones.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("  # --- EFECTOS INDIRECTOS INDIVIDUALES (OPERADOR :=) ---")
        foreach ($m in $mediaciones) {
            $nodes = $m.ToString() -split '\s*->\s*' | Where-Object { $_.Trim() -ne '' }
            if ($nodes.Count -ge 3) {
                $multTerms = @()
                $nodeNamesClean = @()
                for ($i = 0; $i -lt ($nodes.Count - 1); $i++) {
                    $u = $nodes[$i].Trim()
                    $v = $nodes[$i+1].Trim()
                    $uClean = Get-CleanIdentifier $u
                    $vClean = Get-CleanIdentifier $v
                    $key1 = "$u->$v"
                    $key2 = "$uClean->$vClean"
                    $lbl = if ($edgeLabels.ContainsKey($key1)) { $edgeLabels[$key1] } elseif ($edgeLabels.ContainsKey($key2)) { $edgeLabels[$key2] } else { "p_${uClean}_${vClean}" }
                    $multTerms += $lbl
                    $nodeNamesClean += $uClean
                }
                $nodeNamesClean += (Get-CleanIdentifier $nodes[-1].Trim())

                $srcClean = $nodeNamesClean[0]
                $dstClean = $nodeNamesClean[-1]
                $pairKey = "$srcClean->$dstClean"

                $indParamName = "ind_" + ($nodeNamesClean -join '_')

                if (-not $indirectPathsByPair.Contains($pairKey)) {
                    $indirectPathsByPair[$pairKey] = @()
                }
                $indirectPathsByPair[$pairKey] += $indParamName

                [void]$sb.AppendLine("  $indParamName := $($multTerms -join ' * ')")
            }
        }
    }

    if ($indirectPathsByPair.Keys.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("  # --- EFECTOS INDIRECTOS SUMADOS Y EFECTOS TOTALES ---")

        foreach ($pairKey in $indirectPathsByPair.Keys) {
            $pairParts = $pairKey -split '->'
            $srcClean = $pairParts[0]
            $dstClean = $pairParts[1]
            $pathsList = $indirectPathsByPair[$pairKey]

            $indTotalName = "ind_total_${srcClean}_${dstClean}"
            [void]$sb.AppendLine("  $indTotalName := $($pathsList -join ' + ')")

            $directKey1 = "$srcClean->$dstClean"
            $directLabel = if ($edgeLabels.ContainsKey($directKey1)) { $edgeLabels[$directKey1] } else { $null }

            # Efecto total X->Y = sendero directo X->Y (si existe) + suma de efectos indirectos X->Y.
            # NUNCA se suman senderos hacia el mediador (p. ej. X->M) ni de otros destinos.
            # Si el modelo no tiene sendero directo (sin efecto directo, c = 0), el total coincide con el indirecto:
            # solo se declara cuando el usuario pidio explicitamente un efecto total.
            $totalName = "total_${srcClean}_${dstClean}"
            # El efecto total incluye TODOS los caminos indirectos X -> Y del modelo, aunque el usuario haya pedido
            # la mediacion de uno solo (p. ej. con dos mediadores en paralelo).
            $allChains = @(Get-InferredMediationChains -Senderos $Contract.Modelado.Senderos -UserPrompt "" | Where-Object {
                $pp = $_ -split '\s*->\s*'
                ((Get-CleanIdentifier $pp[0]) -eq $srcClean) -and ((Get-CleanIdentifier $pp[-1]) -eq $dstClean)
            })
            $totalIndExpr = $indTotalName
            if ($allChains.Count -gt $pathsList.Count) {
                $prods = foreach ($ch in $allChains) {
                    $nn = $ch -split '\s*->\s*'
                    $lbls = for ($q = 0; $q -lt ($nn.Count - 1); $q++) { $edgeLabels["$($nn[$q])->$($nn[$q+1])"] }
                    $lbls -join ' * '
                }
                $totalIndExpr = '(' + ($prods -join ' + ') + ')'
            }
            if ($directLabel) {
                [void]$sb.AppendLine("  $totalName := $directLabel + $totalIndExpr")
            } elseif ($Contract.Modelado.EfectoTotalSolicitado -or ($Contract.Modelado.EfectosTotales -and $Contract.Modelado.EfectosTotales.Count -gt 0)) {
                [void]$sb.AppendLine("  # --- EFECTOS TOTALES: no hay sendero directo de $srcClean a $dstClean (sin efecto directo, c = 0); el total coincide con el efecto indirecto ---")
                [void]$sb.AppendLine("  $totalName := $totalIndExpr")
            } else {
                [void]$sb.AppendLine("  # --- EFECTOS TOTALES: no hay sendero directo de $srcClean a $dstClean (sin efecto directo, c = 0); el efecto total coincide con ${indTotalName} ---")
            }
        }
    }

    return $sb.ToString()
}

function Build-PsychometricContract {
    param(
        [string]$UserPrompt = "",
        [object]$DataProfile = $null,
        [string]$InteractiveNaCodes = "",
        [string]$InteractiveInversions = "",
        [string]$InteractiveContinuous = "",
        [string]$InteractiveEstimator = "",
        [string]$InteractiveMissing = "",
        [array]$ArrowDirectives = @(),
        [array]$MediationDirectives = @(),
        [array]$TotalEffectsDirectives = @(),
        [string]$CanonicalArchetype = "",
        [switch]$InteractivePriority = $false
    )

    $rawText = ($UserPrompt -split '={20,}')[0]
    $normText = Remove-ContractDiacritics ($rawText.ToLower())


    # Fiabilidad Compuesta (CR): codigo nativo (fuente unica en psico_parser.ps1); NUNCA semTools::compRelSEM/reliability/compositeRel
    $crNativeCode = if (Get-Command Get-NativeCompositeReliabilityRCode -ErrorAction SilentlyContinue) {
        Get-NativeCompositeReliabilityRCode -FitName "fit"
    } else {
        'ss_cr <- lavaan::standardizedSolution(fit); ld_cr <- ss_cr[ss_cr$op == "=~", ]; cr_tab <- do.call(rbind, lapply(unique(ld_cr$lhs), function(f) { lam <- ld_cr$est.std[ld_cr$lhs == f]; data.frame(Factor = f, CR = round(sum(lam)^2 / (sum(lam)^2 + sum(1 - lam^2)), 3)) })); print(cr_tab, row.names = FALSE)'
    }

    $contract = [ordered]@{
        Id = [System.Guid]::NewGuid().ToString()
        Fecha = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Preprocesamiento = [ordered]@{
            InvertirItems = @()
            RecodificarNA = @()
            FiltrarCovariablesNA = @()
        }
        Modelado = [ordered]@{
            TipoFamilia = "General"
            FuncionRObligatoria = ""
            FuncionesProhibidas = @()
            Estimador = "WLSMV"
            TratamientoFaltantes = "pairwise"
            VariablesContinuas = @()
            VariablesOrdenadas = @()
            ExcluirDeOrdered = @()
            Senderos = @()
            Mediaciones = @()
            EfectosTotales = @()
        }
        ChecklistEntregables = [ordered]@{}
    }

    # --------------------------------------------------------------------------
    # 1. PREPROCESAMIENTO: Inversiones de items
    # --------------------------------------------------------------------------
    if ($InteractivePriority) {
        # Modo interactivo: lo que el usuario confirmo en el Wizard tiene prioridad absoluta
        if (![string]::IsNullOrWhiteSpace($InteractiveInversions)) {
            foreach ($it in [regex]::Matches($InteractiveInversions, '(?i)\b([I|i|item|p|P]\d+[a-zA-Z0-9_]*)\b')) {
                $itemClean = $it.Groups[1].Value.ToUpper()
                $stopInv = @("DATOS", "MAX", "MIN", "TRUE", "NA", "RM")
                if ($stopInv -notcontains $itemClean -and $contract.Preprocesamiento.InvertirItems -notcontains $itemClean) {
                    $contract.Preprocesamiento.InvertirItems += $itemClean
                }
            }
        }
        # Si el usuario eligio no invertir en el wizard, queda vacio sin leer de rawText
    } else {
        # Modo por lotes / no interactivo: parsear de rawText
        $invertMatches = [regex]::Matches($rawText, '(?i)(?:invert\w*|dar\s+vuelta|puntuaci[oó]n\s+invertida|item\s+invertido)\s*(?:el\s+|los\s+|previamente\s+|la\s+escala\s+del\s+)?(?:[ií]tems?|reactivos?)?\s*([^.;,\r\n]+?)(?=\s*(?:y\s+)?(?:pasar\s+a\s+na|recodificar|declar\w*|tratar|donde|estimar|utilizar|evaluar|como|con\s+estimador|[.;,\r\n]|$))')
        foreach ($im in $invertMatches) {
            $cand = $im.Groups[1].Value
            $subMatches = [regex]::Matches($cand, '\b([I|i|item|p|P]\d+[a-zA-Z0-9_]*)\b')
            foreach ($sm in $subMatches) {
                $itemClean = $sm.Groups[1].Value.ToUpper()
                if ($contract.Preprocesamiento.InvertirItems -notcontains $itemClean) {
                    $contract.Preprocesamiento.InvertirItems += $itemClean
                }
            }
        }
        $passiveMatches = [regex]::Matches($rawText, '(?i)\b([I|i|item|p|P]\d+[a-zA-Z0-9_]*)\b[^\r\n.;]*?(?:debe\s+ser\s+invertid[oa]|invertid[oa]|polaridad\s+inversa|dalo\s+vuelta)')
        foreach ($pm in $passiveMatches) {
            $subMatches = [regex]::Matches($pm.Value, '(?i)\b([I|i|item|p|P]\d+[a-zA-Z0-9_]*)\b')
            foreach ($sm in $subMatches) {
                $itemClean = $sm.Groups[1].Value.ToUpper()
                if ($contract.Preprocesamiento.InvertirItems -notcontains $itemClean) {
                    $contract.Preprocesamiento.InvertirItems += $itemClean
                }
            }
        }
        if ($normText -match '(?i)(?:dar\s+vuelta|invert\w*).*\b(i8)\b' -and $contract.Preprocesamiento.InvertirItems -notcontains "I8") {
            $contract.Preprocesamiento.InvertirItems += "I8"
        }
    }

    # --------------------------------------------------------------------------
    # 2. PREPROCESAMIENTO: Recodificaciones a NA
    # --------------------------------------------------------------------------
    if ($InteractivePriority) {
        # Modo interactivo: usar exactamente las reglas de NA confirmadas
        if (![string]::IsNullOrWhiteSpace($InteractiveNaCodes)) {
            $rules = $InteractiveNaCodes -split ';' | Where-Object { ![string]::IsNullOrWhiteSpace($_) }
            foreach ($rule in $rules) {
                $valMatchC = [regex]::Match($rule, '(?i)%in%\s*c\(([\d\s,]+)\)')
                $valMatchEq = [regex]::Match($rule, '==\s*(\d+)')
                
                $valArray = @()
                if ($valMatchC.Success) {
                    $valArray = $valMatchC.Groups[1].Value -split ',' | ForEach-Object { [int]$_.Trim() }
                } elseif ($valMatchEq.Success) {
                    $valArray = @([int]$valMatchEq.Groups[1].Value)
                } else {
                    $valArray = @(7)
                }
                
                $matchedCols = @()
                foreach ($it in [regex]::Matches($rule, '(?i)\[\[?\s*[''"]([a-zA-Z0-9_]+)[''"]\s*\]?\]')) {
                    $c = $it.Groups[1].Value.ToUpper()
                    if ($c -ne "DATOS" -and $c -ne "VARIABLE" -and $matchedCols -notcontains $c) { $matchedCols += $c }
                }
                if ($matchedCols.Count -eq 0) {
                    foreach ($it in [regex]::Matches($rule, '(?i)\b([a-zA-Z][a-zA-Z0-9_]*)\b')) {
                        $c = $it.Groups[1].Value.ToUpper()
                        $stopNa = @("DATOS", "VARIABLE", "TRUE", "NA", "RM", "VALOR", "VALORES", "CODIGO", "IS", "WHICH", "C", "IN")
                        if ($stopNa -notcontains $c -and $matchedCols -notcontains $c) { $matchedCols += $c }
                    }
                }
                if ($matchedCols.Count -eq 0 -or $rule -match '(?i)para\s+cada\s+variable|todas') {
                    $contract.Preprocesamiento.RecodificarNA += @{ Variable = "TODAS"; Valores = $valArray }
                } else {
                    foreach ($itUp in $matchedCols) {
                        $contract.Preprocesamiento.RecodificarNA += @{ Variable = $itUp; Valores = $valArray }
                        if ($itUp -match '(?i)^(GENERO|COBERTURA|SEXO|EDAD|EDUCA|NIVEL_EDUCATIVO)$') {
                            if ($contract.Preprocesamiento.FiltrarCovariablesNA -notcontains $itUp) {
                                $contract.Preprocesamiento.FiltrarCovariablesNA += $itUp
                            }
                        }
                    }
                }
            }
        }
        # Si el usuario eligio no recodificar NAs, queda vacio sin leer de rawText
    } else {
        # Modo por lotes / no interactivo
        if ($normText -match '(?i)genero.*(?:3\s*y\s*4|valores\s*3\s*y\s*4|codigos?\s*3\s*y\s*4)') {
            $contract.Preprocesamiento.RecodificarNA += @{ Variable = "GENERO"; Valores = @(3, 4) }
            $contract.Preprocesamiento.FiltrarCovariablesNA += "GENERO"
        }
        if ($normText -match '(?i)cobertura.*(?:distinto\s+de\s+1\s*y\s*2|dejar\s+solo\s+1\s*y\s*2)') {
            $contract.Preprocesamiento.RecodificarNA += @{ Variable = "COBERTURA"; Valores = @("distinto de 1 y 2") }
            $contract.Preprocesamiento.FiltrarCovariablesNA += "COBERTURA"
        }
        $isGlobalNA = ($normText -match '(?i)(?:en\s+toda\s+la\s+base.*(?:valor\s+7|7\s+representa|7\s+a\s+na|7\s+es\s+na)|(?:valor\s+7|7\s+representa|todos?\s+los\s+7).*en\s+toda\s+la\s+base)')
        if ($isGlobalNA) {
            $contract.Preprocesamiento.RecodificarNA += @{ Variable = "TODAS"; Valores = @(7) }
        } else {
            # 1. Patrones naturales de estudiantes: "I2 e I24 (7=NA)", "sacando los 7 de I24", "limpiar 7 de I2", etc.
            $patsNA = @(
                '(?i)(?:recodific\w*|en|para)?\s*([I|i]\d+(?:\s*(?:,|y|e)\s*[I|i]\d+)*)[^.;\r\n]*?\(\s*(\d+)\s*=\s*NA\s*\)',
                '(?i)(?:pasar|tratar|recodific\w*|convertir|considerar)\s+(?:los\s+|el\s+)?(?:valores?|codigos?)?\s*(\d+)\s*(?:a|como)\s+na\s+(?:en|para|de)\s+([^.;\r\n]+)',
                '(?i)(?:limpi\w*|sac\w*|quit\w*|borr\w*)\s+(?:los\s+|el\s+)?(?:valores?|codigos?)?\s*(\d+)\s+(?:de|en|para)\s+([^.;\r\n]+)',
                '(?i)(?:el\s+valor|los\s+valores|valores?|codigo)?\s*(\d+)\s+(?:de|en)\s+([^.;\r\n]+?)\s*(?:ponelo|ponelos|son|es|pasalos?)\s*(?:como|a)?\s*na',
                '(?i)(?:consider\w*|trat\w*)\s+(?:datos\s+)?(?:faltantes|perdidos|ausentes)\s+(?:los|el)?\s*(\d+)\s+(?:de|en|para)\s+([^.;\r\n]+)',
                '(?i)declar\w*\s+(?:los\s+)?(?:valores?|codigos?|\s+)*\b(\d+)\b\s+de\s+(?:(?:los\s+)?items?\s+)?([^.;\r\n]+?)\s*(?:como\s+na|a\s+na)',
                '(?i)(?:pasar\s+(?:a|como)\s+na|tratar.*(?:a|como)\s+na|recodificar.*(?:a|como)\s+na|codigo.*na|valor.*na)[^.;\r\n]*?(?:en|para)\s*([^.;\r\n]+)'
            )
            foreach ($p in $patsNA) {
                foreach ($m in [regex]::Matches($normText, $p)) {
                    $val = 7
                    $cand = ""
                    if ($m.Groups.Count -ge 3 -and $m.Groups[2].Success) {
                        # Si el grupo 1 son items y grupo 2 es valor (ej. "I2 (7=NA)")
                        if ($m.Groups[1].Value -match '(?i)[I|i]\d+') {
                            $cand = $m.Groups[1].Value
                            if ($m.Groups[2].Value -match '^\d+$') { $val = [int]$m.Groups[2].Value }
                        } else {
                            if ($m.Groups[1].Value -match '^\d+$') { $val = [int]$m.Groups[1].Value }
                            $cand = $m.Groups[2].Value
                        }
                    } elseif ($m.Groups.Count -ge 2 -and $m.Groups[1].Success) {
                        $cand = $m.Groups[1].Value
                    }
                    if ($cand) {
                        foreach ($it in [regex]::Matches($cand, '\b([I|i]\d+)\b')) {
                            $itUp = $it.Groups[1].Value.ToUpper()
                            if ($contract.Preprocesamiento.InvertirItems -notcontains $itUp) {
                                $existing = $contract.Preprocesamiento.RecodificarNA | Where-Object { $_.Variable -eq $itUp -and $_.Valores -contains $val }
                                if (-not $existing) {
                                    $contract.Preprocesamiento.RecodificarNA += @{ Variable = $itUp; Valores = @($val) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }




    # --------------------------------------------------------------------------
    # 3. IDENTIFICACION DEL ARQUETIPO CANONICO (1 DE 9 EXCLUYENTES)
    # --------------------------------------------------------------------------
    $archetype = if (![string]::IsNullOrWhiteSpace($CanonicalArchetype)) {
        $CanonicalArchetype
    } else {
        Get-CanonicalArchetype -UserPrompt $rawText -ArrowDirectives $ArrowDirectives
    }
    $contract.Modelado["Arquetipo"] = $archetype

    # Estimador y tratamiento de datos continuos vs ordinales
    if ($InteractivePriority -and ![string]::IsNullOrWhiteSpace($InteractiveEstimator)) {
        $contract.Modelado.Estimador = $InteractiveEstimator
        $contract.Modelado.TratamientoFaltantes = if (![string]::IsNullOrWhiteSpace($InteractiveMissing)) { $InteractiveMissing } else { "pairwise" }
    } else {
        if ($normText -match '(?i)\bmlr\b|\bmaxima\s+verosimilitud\s+robusta\b') {
            $contract.Modelado.Estimador = "MLR"
            $contract.Modelado.TratamientoFaltantes = "fiml"
        } else {
            $contract.Modelado.Estimador = "WLSMV"
            $contract.Modelado.TratamientoFaltantes = "pairwise"
        }
    }

    # Separacion de Continuas vs Ordinales
    if ($InteractivePriority) {
        if (![string]::IsNullOrWhiteSpace($InteractiveContinuous)) {
            $targetStr = $InteractiveContinuous
            if ($targetStr -match ':\s*([^.\r\n]+)') { $targetStr = $matches[1] }
            $stopCont = @("CONTINUO", "CONTINUA", "CONTINUAS", "VARIABLES", "ITEMS", "EXCLUIR", "ORDERED", "DATOS", "SEPARADAS", "COMA", "LAS", "SIGUIENTES", "NO", "DEBEN", "INCLUIRSE", "EN", "EL", "VECTOR", "TRATARLAS", "COMO", "ORDINALES", "USAR", "SETDIFF", "PARA", "EXCLUIRLAS", "DEL", "SI", "ES", "NECESARIO")
            foreach ($it in [regex]::Matches($targetStr, '(?i)\b([I|i]\d+|[A-Za-z0-9_]+)\b')) {
                $cUp = $it.Groups[1].Value.ToUpper()
                if ($stopCont -notcontains $cUp -and $contract.Modelado.ExcluirDeOrdered -notcontains $cUp) {
                    $contract.Modelado.VariablesContinuas += $cUp
                    $contract.Modelado.ExcluirDeOrdered += $cUp
                }
            }
        }
    } else {
        $contMatches = [regex]::Matches($rawText, '(?i)(?:como\s+)?\b([I|i]\d+)\b[^\r\n.;]*?(?:continuo|vector\s+ordered|no\s+lo\s+metas\s+como\s+ordinal)|(?:tratalo\s+como\s+continuo|comportamiento\s+casi\s+continuo|distribuci[oó]n\s+casi\s+continuo|no\s+lo\s+metas\s+como\s+ordinal|excluir\s+de\s+ordered)\s*[:\s]*([A-Za-z0-9_\s,]+)')
        foreach ($cm in $contMatches) {
            foreach ($it in [regex]::Matches($cm.Value, '\b([I|i]\d+)\b')) {
                $cUp = $it.Groups[1].Value.ToUpper()
                if ($contract.Modelado.VariablesContinuas -notcontains $cUp) {
                    $contract.Modelado.VariablesContinuas += $cUp
                    $contract.Modelado.ExcluirDeOrdered += $cUp
                }
            }
        }
    }

    # Configuracion especifica de Entregables segun el Arquetipo Canónico Activo
    switch ($archetype) {
        "AFC_Primer_Orden" {
            $contract.Modelado.TipoFamilia = "Modelos_Lavaan"
            $contract.Modelado.NombreArquetipo = "AFC de Primer Orden (con FC, AVE, Fornell-Larcker, HTMT y Modindices)"
            $contract.Modelado.FuncionRObligatoria = "cfa()"
            $contract.Modelado.FuncionesProhibidas = @("lavaan")

            $contract.ChecklistEntregables["AjusteGlobal"] = [ordered]@{
                Descripcion = "Indices de ajuste global: CFI, TLI, RMSEA y SRMR mediante summary(fit, fit.measures = TRUE, standardized = TRUE)"
                Requerido = $true
                DirectivaR = "print(summary(fit, fit.measures = TRUE, standardized = TRUE))"
            }
            $contract.ChecklistEntregables["FiabilidadCompuesta"] = [ordered]@{
                Descripcion = "Fiabilidad Compuesta (CR) de cada factor, calculada de forma NATIVA con las cargas estandarizadas del objeto fit (PROHIBIDO semTools::compRelSEM / reliability / compositeRel)"
                Requerido = $true
                DirectivaR = $crNativeCode
            }
            $contract.ChecklistEntregables["AVE_FornellLarcker"] = [ordered]@{
                Descripcion = "Varianza Media Extraida (AVE) por factor y Criterio de Fornell-Larcker (raiz de AVE vs correlaciones latentes)"
                Requerido = $true
                DirectivaR = "pe <- parameterEstimates(fit, standardized = TRUE); ave <- sapply(unique(pe`$lhs[pe`$op == '=~']), function(f) mean(pe`$std.all[pe`$lhs == f & pe`$op == '=~']^2)); sqrt_ave <- sqrt(ave); print(sqrt_ave); print(lavInspect(fit, 'cor.lv'))"
            }
            $contract.ChecklistEntregables["HTMT"] = [ordered]@{
                Descripcion = "Ratio Heterotrait-Monotrait (HTMT) mediante semTools::htmt"
                Requerido = $true
                DirectivaR = "cat('\n--- Ratio HTMT ---\n'); print(semTools::htmt(modelo, data = datos))"
            }
            $contract.ChecklistEntregables["Top10ModIndices"] = [ordered]@{
                Descripcion = "Top 10 indices de modificacion (MI) ordenados de mayor a menor"
                Requerido = $true
                DirectivaR = "mi <- modificationIndices(fit); print(head(mi[order(mi`$mi, decreasing = TRUE), ], 10))"
            }
        }

        "AFC_Segundo_Orden" {
            $contract.Modelado.TipoFamilia = "Modelos_Lavaan"
            $contract.Modelado.NombreArquetipo = "AFC de Segundo Orden (Macro-factor superior)"
            $contract.Modelado.FuncionRObligatoria = "cfa()"
            $contract.Modelado.FuncionesProhibidas = @("lavaan")

            $contract.ChecklistEntregables["AjusteGlobal"] = [ordered]@{
                Descripcion = "Indices de ajuste global: CFI, TLI, RMSEA y SRMR mediante summary(fit, fit.measures = TRUE, standardized = TRUE)"
                Requerido = $true
                DirectivaR = "print(summary(fit, fit.measures = TRUE, standardized = TRUE))"
            }
            $contract.ChecklistEntregables["CargasSegundoOrden"] = [ordered]@{
                Descripcion = "Cargas factoriales de 1er orden y cargas del macro-factor de segundo orden sobre los factores base"
                Requerido = $true
                DirectivaR = "pe <- parameterEstimates(fit, standardized = TRUE); print(pe[pe`$op == '=~', c('lhs', 'op', 'rhs', 'est', 'se', 'z', 'pvalue', 'std.all')])"
            }
            $contract.ChecklistEntregables["FiabilidadSegundoOrden"] = [ordered]@{
                Descripcion = "Fiabilidad Compuesta (CR) de las dimensiones de 1er orden y del factor de segundo orden, calculada de forma NATIVA con las cargas estandarizadas del objeto fit (PROHIBIDO semTools::compRelSEM / reliability / compositeRel)"
                Requerido = $true
                DirectivaR = $crNativeCode
            }
            if ($normText -match '(?i)(?:compar|rival|competid|frente\s+a|\bvs\b|dos\s+modelos)') {
                $contract.ChecklistEntregables["ComparacionModelos"] = [ordered]@{
                    Descripcion = "Comparacion formal de ajuste entre Modelo Oblicuo (Primer Orden) y Modelo de Segundo Orden"
                    Requerido = $true
                    DirectivaR = "Generar tabla comparativa de fitmeasures(c('chisq.scaled', 'df.scaled', 'pvalue.scaled', 'cfi.scaled', 'tli.scaled', 'rmsea.scaled'))."
                }
            }
        }

        "Bifactor" {
            $contract.Modelado.TipoFamilia = "Modelos_Lavaan"
            $contract.Modelado.NombreArquetipo = "Modelo Bifactorial (Factor General + Factores Especificos)"
            $contract.Modelado.FuncionRObligatoria = "cfa(..., orthogonal = TRUE)"
            $contract.Modelado.FuncionesProhibidas = @("lavaan")

            $contract.ChecklistEntregables["AjusteGlobal"] = [ordered]@{
                Descripcion = "Indices de ajuste global: CFI, TLI, RMSEA y SRMR mediante summary(fit, fit.measures = TRUE, standardized = TRUE)"
                Requerido = $true
                DirectivaR = "print(summary(fit, fit.measures = TRUE, standardized = TRUE))"
            }
            $contract.ChecklistEntregables["IndicesBifactor"] = [ordered]@{
                Descripcion = "Calculo exacto de indices de Reise y Rodriguez: Omega Jerarquico (omega_h), Omega de Subescala pura (omega_s), ECV y PUC"
                Requerido = $true
                DirectivaR = "Calcular Omega Jerarquico (omega_h), Omega Total (omega_t), ECV_G, PUC y, para cada subescala especifica, omega_HS = (sum(lam_s))^2 / ((sum(lam_g_s))^2 + (sum(lam_s))^2 + sum(th_s)) usando SOLO los items de esa subescala (lam_g_s = cargas del factor general en esos items). Imprimir en consola con cat() formateado."
            }
            if ($normText -match '(?i)(?:modindices|modificationindices|modificaci|indices?\s+de\s+modificaci|top\s*10|10\s+.*(?:[ií]|a.?)ndices)') {
                $contract.ChecklistEntregables["Top10ModIndices"] = [ordered]@{
                    Descripcion = "Impresion de los 10 indices de modificacion (MI) mas altos ordenados de mayor a menor"
                    Requerido = $true
                    DirectivaR = "mi <- modificationIndices(fit); print(head(mi[order(mi`$mi, decreasing = TRUE), ], 10))"
                }
            }
        }

        "MIMIC" {
            $contract.Modelado.TipoFamilia = "Modelos_Lavaan"
            $contract.Modelado.NombreArquetipo = "Modelo MIMIC (Invarianza y Funcionamiento Diferencial DIF)"
            $contract.Modelado.FuncionRObligatoria = "sem()"
            $contract.Modelado.FuncionesProhibidas = @("lavaan", "group =")

            $contract.ChecklistEntregables["EstructuralMIMIC"] = [ordered]@{
                Descripcion = "Regresion estructural de factores latentes sobre covariables observadas (Factor ~ Covars)"
                Requerido = $true
                DirectivaR = "pe <- parameterEstimates(fit, standardized = TRUE); print(pe[pe`$op == '~', c('lhs', 'op', 'rhs', 'est', 'se', 'z', 'pvalue', 'std.all')])"
            }
            # El DIF (Score Test + Bonferroni) solo se exige si la consigna lo pide; un MIMIC sin DIF no lo calcula.
            $difRequested = [bool]($normText -match '(?i)\b(?:dif|diff|funcionamiento\s+diferencial|score\s+test|sesgo|invarianz\w*|invarianc\w*|invariance|multigrupo|multi-group|multigroup|configural|escalar|equivalencia\s+(?:de\s+medida|factorial))\b')
            $contract.Modelado["DIFSolicitado"] = $difRequested
            if ($difRequested) {
                $contract.ChecklistEntregables["DIFScoreTest"] = [ordered]@{
                    Descripcion = "Evaluacion asintotica de DIF mediante Score Test (Multiplicador de Lagrange) univariado con epc = TRUE"
                    Requerido = $true
                    DirectivaR = "lavTestScore(fit, add = p_syn, epc = TRUE)"
                }
                $contract.ChecklistEntregables["BonferroniFormulado"] = [ordered]@{
                    Descripcion = "Correccion estricta de Bonferroni sobre los p-valores del Score Test"
                    Requerido = $true
                    DirectivaR = "tabla_dif`$p_adj <- p.adjust(tabla_dif`$p.value, method = 'bonferroni'); tabla_dif`$DIF_Bonferroni <- tabla_dif`$p_adj < 0.05"
                }
            }
        }

        "SEM_NoRecursivo" {
            $contract.Modelado.TipoFamilia = "Modelos_Lavaan"
            $contract.Modelado.NombreArquetipo = "SEM / Modelos No Recursivos (Bucles y Feedback Loops)"
            $contract.Modelado.FuncionRObligatoria = "sem()"
            $contract.Modelado.FuncionesProhibidas = @("lavaan")

            $contract.ChecklistEntregables["SenderosDirectos"] = [ordered]@{
                Descripcion = "Estimacion y reporte de todos los senderos directos confirmados (Destino ~ eq * Origen)"
                Requerido = $true
                DirectivaR = "Declarar formulas de regresion estructural con etiquetas deterministas prefijadas."
            }
            $contract.ChecklistEntregables["AjusteGlobal"] = [ordered]@{
                Descripcion = "Indices de ajuste global y coeficientes estandarizados"
                Requerido = $true
                DirectivaR = "print(summary(fit, fit.measures = TRUE, standardized = TRUE))"
            }
            $recipMatch = [regex]::Match($rawText, '(?i)([A-Za-z0-9_]+)\s*->\s*([A-Za-z0-9_]+)[^A-Za-z0-9_]*?\b\2\s*->\s*\1')
            $f1 = if ($recipMatch.Success) { $recipMatch.Groups[1].Value } else { "Relacional" }
            $f2 = if ($recipMatch.Success) { $recipMatch.Groups[2].Value } else { "Estrategico" }
            $permiteResidual = ($normText -match '(?i)(?:permitir|incluir|correlaci).*residual')
            $contract.ChecklistEntregables["BucleNoRecursivo"] = [ordered]@{
                Descripcion = if ($permiteResidual) { "Especificacion del bucle reciproco con covariables instrumentales Y covarianza residual ($f1 ~~ $f2)" } else { "Especificacion del bucle reciproco con covariables instrumentales SIN covarianza residual ($f1 ~~ $f2)" }
                Requerido = $true
                DirectivaR = if ($permiteResidual) { "Declarar '$f1 ~ $f2' y '$f2 ~ $f1' junto a instrumentos e incluir '$f1 ~~ $f2'." } else { "Declarar '$f1 ~ $f2' y '$f2 ~ $f1' junto a instrumentos omitiendo '$f1 ~~ $f2'." }
                FactoresReciprocos = @($f1, $f2)
                PermiteResidual = $permiteResidual
            }
        }

        "SEM_Senderos" {
            $contract.Modelado.TipoFamilia = "Modelos_Lavaan"
            $contract.Modelado.NombreArquetipo = "SEM / Senderos Causales y Mediaciones"
            $contract.Modelado.FuncionRObligatoria = "sem()"
            $contract.Modelado.FuncionesProhibidas = @("lavaan")

            $contract.ChecklistEntregables["SenderosDirectos"] = [ordered]@{
                Descripcion = "Estimacion y reporte de todos los senderos directos confirmados (Destino ~ eq * Origen)"
                Requerido = $true
                DirectivaR = "Declarar formulas de regresion estructural con etiquetas deterministas prefijadas."
            }
            if (($MediationDirectives -and $MediationDirectives.Count -gt 0) -or ($TotalEffectsDirectives -and $TotalEffectsDirectives.Count -gt 0) -or ($normText -match '(?i)(?:indirecto|mediaci|efecto\s+total)')) {
                $contract.ChecklistEntregables["EfectoIndirecto"] = [ordered]@{
                    Descripcion = "Declaracion formal de parametros indirectos y totales (operador :=) y reporte de significacion, error estandar y p-valor"
                    Requerido = $true
                    DirectivaR = "Definir 'indirecto := a * b' etiquetando los senderos 'M ~ a * X' e 'Y ~ b * M'. Reportar via parameterEstimates(fit)[pe`$op == ':=', c('lhs', 'op', 'rhs', 'est', 'se', 'z', 'pvalue', 'std.all')]."
                }
            }
            $contract.ChecklistEntregables["AjusteGlobal"] = [ordered]@{
                Descripcion = "Indices de ajuste global y coeficientes estandarizados"
                Requerido = $true
                DirectivaR = "print(summary(fit, fit.measures = TRUE, standardized = TRUE))"
            }
        }

        "ACP" {
            $contract.Modelado.TipoFamilia = "Exploratorio_Psych"
            $contract.Modelado.NombreArquetipo = "Analisis de Componentes Principales (ACP)"
            $contract.Modelado.FuncionRObligatoria = "psych::principal()"
            $contract.Modelado.FuncionesProhibidas = @("lavaan", "cfa", "sem")
            $contract.Modelado.Estimador = "Descomposicion Eigen (Componentes Principales)"

            $contract.ChecklistEntregables["PsychPolicoricasSeguras"] = [ordered]@{
                Descripcion = "Calculo seguro de matriz de correlaciones (policorica si datos ordinales) sin colapso por NAs"
                Requerido = $true
                DirectivaR = "na.omit(datos[, items]) antes de policorica si aplica."
            }
            $contract.ChecklistEntregables["ExtraccionComponentes"] = [ordered]@{
                Descripcion = "Extraccion de componentes principales, autovalores y varianza explicada acumulada"
                Requerido = $true
                DirectivaR = "acp_res <- psych::principal(datos_items, nfactors = k, rotate = 'varimax'); print(acp_res`$values); print(acp_res`$Vaccounted)"
            }
            $contract.ChecklistEntregables["MatrizRotada"] = [ordered]@{
                Descripcion = "Matriz de componentes rotados"
                Requerido = $true
                DirectivaR = "print(acp_res`$loadings)"
            }
        }

        "AFE" {
            $contract.Modelado.TipoFamilia = "Exploratorio_Psych"
            $contract.Modelado.NombreArquetipo = "Analisis Factorial Exploratorio (AFE)"
            $contract.Modelado.FuncionRObligatoria = "psych::fa()"
            $contract.Modelado.FuncionesProhibidas = @("lavaan", "cfa", "sem")
            $contract.Modelado.Estimador = "Minres / WLS / PA"

            $contract.ChecklistEntregables["PsychPolicoricasSeguras"] = [ordered]@{
                Descripcion = "Calculo seguro de matriz de correlaciones (policorica si datos ordinales) sin colapso por NAs"
                Requerido = $true
                DirectivaR = "na.omit(datos[, items]) antes de policorica si aplica."
            }
            $contract.ChecklistEntregables["ExtraccionFactores"] = [ordered]@{
                Descripcion = "Extraccion de factores comunes (Minres/WLS/PA) y comunalidades"
                Requerido = $true
                DirectivaR = "afe_res <- psych::fa(datos_items, nfactors = k, fm = 'minres', rotate = 'oblimin'); print(afe_res`$communality); print(afe_res`$Vaccounted)"
            }
            $contract.ChecklistEntregables["MatrizRotada"] = [ordered]@{
                Descripcion = "Matriz de cargas factoriales rotadas y correlacion entre factores"
                Requerido = $true
                DirectivaR = "print(afe_res`$loadings); if (!is.null(afe_res`$Phi)) print(afe_res`$Phi)"
            }
        }

        "Regresion_Logistica" {
            $contract.Modelado.TipoFamilia = "RegresionDirecta"
            $contract.Modelado.NombreArquetipo = "Regresion Logistica (Binaria u Ordinal)"
            $contract.Modelado.FuncionRObligatoria = "glm(family = binomial) o MASS::polr(method = 'logistic')"
            $contract.Modelado.FuncionesProhibidas = @("lavaan", "cfa", "sem")
            $contract.Modelado.Estimador = "Maxima Verosimilitud (GLM)"

            $contract.ChecklistEntregables["OddsRatios"] = [ordered]@{
                Descripcion = "Calculo de coeficientes y Odds Ratios (exp(coef)) con intervalos de confianza"
                Requerido = $true
                DirectivaR = "print(exp(coef(fit_logit)))"
            }
            $contract.ChecklistEntregables["PValoresExplicitos"] = [ordered]@{
                Descripcion = "Calculo obligatorio de errores estandar y p-valores explicitos (pnorm)"
                Requerido = $true
                DirectivaR = "p_val <- 2 * (1 - pnorm(abs(t_stat))); print(cbind(coef, se, z, p_val))"
            }
        }

        "Regresion_Probit" {
            $contract.Modelado.TipoFamilia = "RegresionDirecta"
            $contract.Modelado.NombreArquetipo = "Regresion Probit (Binaria u Ordinal)"
            $contract.Modelado.FuncionRObligatoria = "glm(family = binomial(link = 'probit')) o MASS::polr(method = 'probit')"
            $contract.Modelado.FuncionesProhibidas = @("lavaan", "cfa", "sem")
            $contract.Modelado.Estimador = "Maxima Verosimilitud (GLM Probit)"

            $contract.ChecklistEntregables["CoeficientesProbit"] = [ordered]@{
                Descripcion = "Coeficientes probit, errores estandar y p-valores explicitos (pnorm)"
                Requerido = $true
                DirectivaR = "p_val <- 2 * (1 - pnorm(abs(t_stat))); print(cbind(coef, se, z, p_val))"
            }
        }
    }

    # El usuario pidio la CR en su consigna (p. ej. en un MIMIC o SEM): se vuelve entregable OBLIGATORIO y auditable
    if ($contract.Modelado.TipoFamilia -eq "Modelos_Lavaan" `
        -and (Get-Command Test-CompositeReliabilityRequested -ErrorAction SilentlyContinue) `
        -and (Test-CompositeReliabilityRequested -UserPrompt $UserPrompt) `
        -and -not ($contract.ChecklistEntregables.Contains("FiabilidadCompuesta") -or $contract.ChecklistEntregables.Contains("FiabilidadSegundoOrden"))) {
        $contract.ChecklistEntregables["FiabilidadCompuesta"] = [ordered]@{
            Descripcion = "Fiabilidad Compuesta (CR) solicitada por el investigador: calculada por cada factor de forma NATIVA con las cargas estandarizadas del objeto fit (PROHIBIDO semTools::compRelSEM / reliability / compositeRel)"
            Requerido = $true
            DirectivaR = $crNativeCode
        }
    }

    # El usuario pidio indices de modificacion en cualquier modelo Lavaan (AFC 2do orden, MIMIC, SEM, etc.):
    $asksModIndices = ($normText -match '(?i)(?:modindices|modificationindices|modificaci[oó]n\s+de\s+[ií]ndices|[ií]ndices?\s+de\s+modificaci|[ií]ndices?\s+para\s+mejorar|top\s*10|10\s+.*(?:[ií]|a.?)ndices)')
    if ($contract.Modelado.TipoFamilia -eq "Modelos_Lavaan" `
        -and $asksModIndices `
        -and -not $contract.ChecklistEntregables.Contains("Top10ModIndices")) {
        $contract.ChecklistEntregables["Top10ModIndices"] = [ordered]@{
            Descripcion = "Top 10 indices de modificacion (MI) ordenados de mayor a menor solicitados por el investigador"
            Requerido = $true
            DirectivaR = "mi <- modificationIndices(fit); print(head(mi[order(mi`$mi, decreasing = TRUE), ], 10))"
        }
    }

    if ($ArrowDirectives -and $ArrowDirectives.Count -gt 0) {
        foreach ($ad in $ArrowDirectives) {
            $contract.Modelado.Senderos += @{ Origenes = $ad.Origenes; Destino = $ad.Destino }
        }
    }

    if ($MediationDirectives -and $MediationDirectives.Count -gt 0) {
        foreach ($md in $MediationDirectives) {
            $contract.Modelado.Mediaciones += $md
        }
    }

    if ($TotalEffectsDirectives -and $TotalEffectsDirectives.Count -gt 0) {
        foreach ($td in $TotalEffectsDirectives) {
            $contract.Modelado.EfectosTotales += $td
        }
    }

    # Mediacion pedida en texto libre sin cadena explicita (p. ej. "calculame la mediacion de M entre X e Y"):
    # se infieren las cadenas a partir de los senderos ya declarados, para que la sintaxis canonica
    # determinista (ind_*, total_*) reemplace cualquier formula improvisada por el LLM.
    if ($contract.Modelado["Arquetipo"] -eq "SEM_Senderos" `
        -and $contract.Modelado.Senderos.Count -gt 0 `
        -and $contract.Modelado.Mediaciones.Count -eq 0 `
        -and $contract.Modelado.EfectosTotales.Count -eq 0 `
        -and $normText -match '(?:mediaci|indirect|efecto\s+total)') {
        $inferred = @(Get-InferredMediationChains -Senderos $contract.Modelado.Senderos -UserPrompt $UserPrompt)
        foreach ($chain in $inferred) { $contract.Modelado.Mediaciones += $chain }
    }
    $contract.Modelado["EfectoTotalSolicitado"] = [bool]($normText -match 'efecto\s+total|efectos\s+totales')

    $contract.Modelado["SintaxisLavaan"] = Build-UniversalLavaanStructuralSyntax -Contract $contract

    return $contract
}

function Format-PsychometricContractDisplay {
    param([object]$Contract)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("         CONTRATO DE EJECUCION PSICOMETRICA (CONFIRMACION PREVIA)              ")
    [void]$sb.AppendLine("================================================================================")
    $nomArq = if ($Contract.Modelado.NombreArquetipo) { $Contract.Modelado.NombreArquetipo } else { $Contract.Modelado.TipoFamilia }
    [void]$sb.AppendLine("ARQUETIPO CANONICO ACTIVO: [ $nomArq ]")
    [void]$sb.AppendLine("--------------------------------------------------------------------------------")
    [void]$sb.AppendLine("1. ACCIONES DE PREPROCESAMIENTO E HIGIENE:")
    
    $invStr = if ($Contract.Preprocesamiento.InvertirItems.Count -gt 0) { ($Contract.Preprocesamiento.InvertirItems -join ", ") } else { "Ninguna" }
    [void]$sb.AppendLine("   - Invertir items                   : [ $invStr ]")

    if ($Contract.Preprocesamiento.RecodificarNA.Count -gt 0) {
        $naList = @()
        foreach ($rn in $Contract.Preprocesamiento.RecodificarNA) {
            $naList += "$($rn.Variable) = ($($rn.Valores -join ','))"
        }
        [void]$sb.AppendLine("   - Recodificar a NA                 : [ $($naList -join '; ') ]")
    } else {
        [void]$sb.AppendLine("   - Recodificar a NA                 : [ No se requieren ]")
    }

    if ($Contract.Preprocesamiento.FiltrarCovariablesNA.Count -gt 0) {
        [void]$sb.AppendLine("   - Filtrar NAs en covariables       : [ $($Contract.Preprocesamiento.FiltrarCovariablesNA -join ', ') ]")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("2. MODELADO Y MOTOR DE ESTIMACION EN R:")
    [void]$sb.AppendLine("   - Arquetipo de analisis            : $nomArq")
    [void]$sb.AppendLine("   - Familia de analisis              : $($Contract.Modelado.TipoFamilia)")
    [void]$sb.AppendLine("   - Funcion R obligatoria            : $($Contract.Modelado.FuncionRObligatoria)")
    if ($Contract.Modelado.FuncionesProhibidas.Count -gt 0) {
        [void]$sb.AppendLine("   - FUNCIONES PROHIBIDAS             : [ $($Contract.Modelado.FuncionesProhibidas -join ', ') ] (NUNCA usar lavaan() a secas!)")
    }
    [void]$sb.AppendLine("   - Estimador estadistico            : $($Contract.Modelado.Estimador) (missing = '$($Contract.Modelado.TratamientoFaltantes)')")
    if ($Contract.Modelado.ExcluirDeOrdered.Count -gt 0) {
        [void]$sb.AppendLine("   - Variables excluidas de 'ordered' : [ $($Contract.Modelado.ExcluirDeOrdered -join ', ') ] (Tratar como continuas)")
    }

    $secNum = 3
    if ($Contract.Modelado.Senderos -and $Contract.Modelado.Senderos.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("$secNum. ESTRUCTURA SEM Y SENDEROS CAUSALES DETECTADOS:")
        foreach ($s in $Contract.Modelado.Senderos) {
            $origStr = $s.Origenes -join " + "
            [void]$sb.AppendLine("   - $origStr -> $($s.Destino)  (lavaan: $($s.Destino) ~ $origStr)")
        }
        $secNum++
    }
    
    if (($Contract.Modelado.Mediaciones -and $Contract.Modelado.Mediaciones.Count -gt 0) -or ($Contract.Modelado.EfectosTotales -and $Contract.Modelado.EfectosTotales.Count -gt 0)) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("$secNum. EFECTOS INDIRECTOS Y MEDIACIONES (CONTRATO EXPLICITO):")
        if ($Contract.Modelado.Mediaciones) {
            foreach ($m in $Contract.Modelado.Mediaciones) {
                [void]$sb.AppendLine("   - Cadena causal obligatoria: $m")
            }
        }
        if ($Contract.Modelado.EfectosTotales -and $Contract.Modelado.EfectosTotales.Count -gt 0) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("   EFECTOS TOTALES COMPUESTOS OBLIGATORIOS:")
            foreach ($t in $Contract.Modelado.EfectosTotales) {
                [void]$sb.AppendLine("   - Suma total / Efecto Compuesto: $t")
            }
        }

        $syntaxBlock = Build-UniversalLavaanStructuralSyntax -Contract $Contract
        if (![string]::IsNullOrWhiteSpace($syntaxBlock)) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("   FORMULAS LAVAAN GENERADAS POR TEORIA DE GRAFOS (INMUTABLES):")
            foreach ($sLine in ($syntaxBlock.Trim() -split '\r?\n')) {
                [void]$sb.AppendLine("   $sLine")
            }
        }
        $secNum++
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("$secNum. CHECKLIST DE ENTREGABLES Y METRICAS OBLIGATORIAS:")
    $checklistKeys = if ($Contract.ChecklistEntregables -is [System.Collections.IDictionary]) {
        @($Contract.ChecklistEntregables.Keys)
    } elseif ($Contract.ChecklistEntregables.PSObject -and $Contract.ChecklistEntregables.PSObject.Properties) {
        @($Contract.ChecklistEntregables.PSObject.Properties.Name)
    } else {
        @()
    }
    if ($checklistKeys.Count -eq 0) {
        [void]$sb.AppendLine("   [v] Coeficientes estandarizados, Errores Estandar y Medidas de Ajuste Global")
    } else {
        foreach ($k in $checklistKeys) {
            $item = $Contract.ChecklistEntregables.$k
            [void]$sb.AppendLine("   [v] $($item.Descripcion)")
        }
    }
    [void]$sb.AppendLine("================================================================================")

    return $sb.ToString()
}

function Generate-ContractPromptDirectives {
    param([object]$Contract)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("CONTRATO VINCULANTE DE EJECUCION PSICOMETRICA (CUMPLIMIENTO OBLIGATORIO 100%):")
    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("Para que tu script sea APROBADO por el auditor automatico, DEBES implementar:")
    [void]$sb.AppendLine("")

    # 1. Reglas de funciones
    if ($Contract.Modelado.FuncionRObligatoria) {
        [void]$sb.AppendLine("1. FUNCION DE AJUSTE: Debes usar OBLIGATORIAMENTE '$($Contract.Modelado.FuncionRObligatoria)'.")
    }
    if ($Contract.Modelado.FuncionesProhibidas.Count -gt 0) {
        [void]$sb.AppendLine("   PROHIBICION ESTRICTA: Queda TERMINANTEMENTE PROHIBIDO invocar 'lavaan(modelo, ...)' a secas. Usa siempre 'cfa(modelo, ...)' o 'sem(modelo, ...)'.")
    }

    # 2. Reglas de preprocesamiento
    if ($Contract.Preprocesamiento.InvertirItems.Count -gt 0) {
        foreach ($inv in $Contract.Preprocesamiento.InvertirItems) {
            [void]$sb.AppendLine("2. INVERSION OBLIGATORIA: datos`$$inv <- max(datos`$$inv, na.rm = TRUE) + min(datos`$$inv, na.rm = TRUE) - datos`$$inv")
        }
    }
    if ($Contract.Preprocesamiento.RecodificarNA.Count -gt 0) {
        foreach ($rn in $Contract.Preprocesamiento.RecodificarNA) {
            if ($rn.Variable -eq "TODAS") {
                [void]$sb.AppendLine("3. RECODIFICACION A NA: datos[datos == $($rn.Valores[0])] <- NA")
            } else {
                $valStr = if ($rn.Valores.Count -gt 1) { "c($($rn.Valores -join ', '))" } else { "$($rn.Valores[0])" }
                [void]$sb.AppendLine("3. RECODIFICACION A NA: datos`$$($rn.Variable)[datos`$$($rn.Variable) %in% $valStr] <- NA")
            }
        }
    }
    if ($Contract.Preprocesamiento.FiltrarCovariablesNA.Count -gt 0) {
        foreach ($fc in $Contract.Preprocesamiento.FiltrarCovariablesNA) {
            [void]$sb.AppendLine("4. FILTRADO PREVENTIVO: datos <- datos[!is.na(datos`$$fc), ]")
        }
    }
    if ($Contract.Modelado.ExcluirDeOrdered.Count -gt 0) {
        [void]$sb.AppendLine("EXCLUSION DE 'ordered': Las siguientes variables deben tratarse como CONTINUAS y NO incluirse en el vector 'ordered = c(...)': $($Contract.Modelado.ExcluirDeOrdered -join ', '). Usar setdiff() si es necesario.")
    }

    # 3. Reglas de entregables especificos
    $chkKeys = if ($Contract.ChecklistEntregables -is [System.Collections.IDictionary]) {
        @($Contract.ChecklistEntregables.Keys)
    } elseif ($Contract.ChecklistEntregables.PSObject -and $Contract.ChecklistEntregables.PSObject.Properties) {
        @($Contract.ChecklistEntregables.PSObject.Properties.Name)
    } else {
        @()
    }
    if ($chkKeys.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("DIRECTIVAS DE SALIDA Y ENTREGABLES OBLIGATORIOS:")
        $idx = 5
        foreach ($k in $chkKeys) {
            $ent = $Contract.ChecklistEntregables.$k
            [void]$sb.AppendLine("$idx. $($ent.Descripcion):")
            [void]$sb.AppendLine("   Sintaxis requerida: $($ent.DirectivaR)")
            $idx++
        }
        if (($chkKeys -contains "FiabilidadCompuesta" -or $chkKeys -contains "FiabilidadSegundoOrden") -and (Get-Command Get-CompositeReliabilityRule -ErrorAction SilentlyContinue)) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine((Get-CompositeReliabilityRule))
        }
    }

    $structuralBlock = Build-UniversalLavaanStructuralSyntax -Contract $Contract
    if (![string]::IsNullOrWhiteSpace($structuralBlock)) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("================================================================================")
        [void]$sb.AppendLine("SINTAXIS ESTRUCTURAL Y FORMULAS DE MEDIACION CANONICAS EN LAVAAN (INMUTABLES):")
        [void]$sb.AppendLine("================================================================================")
        [void]$sb.AppendLine("El motor psicometrico ha resuelto el Grafo Causal (DAG) exacto.")
        [void]$sb.AppendLine("DEBES copiar e incorporar TEXTUALMENTE las siguientes lineas dentro de la definicion de 'modelo <- ''...'':")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine($structuralBlock.TrimEnd())
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("REGLA MATEMATICA ESTRICTA: Queda TERMINANTEMENTE PROHIBIDO modificar estas etiquetas,")
        [void]$sb.AppendLine("renombrar parametros (:=), inventar productos ajenos (ej. multiplicar dos flechas salientes)")
        [void]$sb.AppendLine("o sumar covariables ajenas a los efectos totales de cada predictor focal.")
        [void]$sb.AppendLine("================================================================================")
    }

    if ($Contract.Modelado.Mediaciones -and $Contract.Modelado.Mediaciones.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("DIRECTIVAS DE MEDIACION EXPLICITA:")
        $midx = 1
        foreach ($m in $Contract.Modelado.Mediaciones) {
            [void]$sb.AppendLine("M$midx. MEDIACION OBLIGATORIA: Debes declarar el efecto indirecto (:=) exactamente para esta cadena causal: '$m'.")
            $midx++
        }
    }

    if ($Contract.Modelado.EfectosTotales -and $Contract.Modelado.EfectosTotales.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("DIRECTIVAS DE EFECTOS TOTALES:")
        $tidx = 1
        foreach ($t in $Contract.Modelado.EfectosTotales) {
            [void]$sb.AppendLine("T$tidx. EFECTO COMPUESTO OBLIGATORIO: Debes declarar con ':=' el siguiente efecto total/compuesto: '$t'.")
            $tidx++
        }
    }

    [void]$sb.AppendLine("================================================================================")

    return $sb.ToString()
}
