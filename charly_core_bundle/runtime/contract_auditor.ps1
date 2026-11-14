# ==============================================================================
# CHARLY v4.0 - AUDITOR DETERMINISTA DE CONTRATO PSICOMETRICO
# ==============================================================================
# Inspecciona el script generado en R y la salida de consola para certificar
# que se hayan cumplido estrictamente TODOS los compromisos del contrato
# para el arquetipo canonico activo (1 de 9).
# Si detecta omisiones, desvios o violaciones, RECHAZA el script (Passed = False)
# y genera las directivas de reparacion especificas.
# ==============================================================================

function Get-EffectPolynomial {
    # Expande una expresion de ':=' (sumas, productos, parentesis y nombres ya definidos) a una
    # lista de monomios; cada monomio es un arreglo de etiquetas de senderos.
    param([string]$Expr, [hashtable]$Defs, [int]$Depth = 0)
    if ($Depth -gt 12) { throw "definicion circular o demasiado profunda" }
    $tokens = @([regex]::Matches($Expr, '[A-Za-z_\.][\w\.]*|[\+\*\(\)]') | ForEach-Object { $_.Value })
    $state = @{ T = $tokens; I = 0 }
    $poly = Read-EffectSum -State $state -Defs $Defs -Depth $Depth
    return ,$poly
}

function Read-EffectSum {
    param([hashtable]$State, [hashtable]$Defs, [int]$Depth)
    $acc = Read-EffectProduct -State $State -Defs $Defs -Depth $Depth
    while ($State.I -lt $State.T.Count -and $State.T[$State.I] -eq '+') {
        $State.I++
        $rhs = Read-EffectProduct -State $State -Defs $Defs -Depth $Depth
        foreach ($m in $rhs) { [void]$acc.Add($m) }
    }
    return ,$acc
}

function Read-EffectProduct {
    param([hashtable]$State, [hashtable]$Defs, [int]$Depth)
    $acc = Read-EffectAtom -State $State -Defs $Defs -Depth $Depth
    while ($State.I -lt $State.T.Count -and $State.T[$State.I] -eq '*') {
        $State.I++
        $rhs = Read-EffectAtom -State $State -Defs $Defs -Depth $Depth
        $new = New-Object System.Collections.ArrayList
        foreach ($a in $acc) { foreach ($b in $rhs) { [void]$new.Add([string[]](@($a) + @($b))) } }
        $acc = $new
    }
    return ,$acc
}

function Read-EffectAtom {
    param([hashtable]$State, [hashtable]$Defs, [int]$Depth)
    if ($State.I -ge $State.T.Count) { throw "expresion incompleta" }
    $tok = $State.T[$State.I]
    $State.I++
    if ($tok -eq '(') {
        $inner = Read-EffectSum -State $State -Defs $Defs -Depth $Depth
        if ($State.I -lt $State.T.Count -and $State.T[$State.I] -eq ')') { $State.I++ }
        return ,$inner
    }
    if ($tok -match '^[A-Za-z_\.]') {
        if ($Defs.ContainsKey($tok)) {
            return ,(Get-EffectPolynomial -Expr $Defs[$tok] -Defs $Defs -Depth ($Depth + 1))
        }
        $one = New-Object System.Collections.ArrayList
        [void]$one.Add([string[]]@($tok))
        return ,$one
    }
    throw "token inesperado '$tok'"
}

function Test-DefinedEffectsAreValidPaths {
    <#
    .SYNOPSIS
    Valida matematicamente cada ':=' del script: todo efecto definido debe ser una suma de
    productos de etiquetas que formen caminos causales continuos con el MISMO origen y destino
    (efecto total X->Y = directo X->Y + indirectos X->Y). Detecta p. ej. 'total := a*b + a'
    (suma un sendero X->M, que no llega al desenlace Y). Devuelve una lista de mensajes de error.
    #>
    param([string]$ScriptContent)

    $errs = @()
    $edges = @{}
    $defs = [ordered]@{}
    foreach ($line in ($ScriptContent -split '\r?\n')) {
        $l = ($line -replace '#.*$', '').Trim()
        if (-not $l) { continue }
        if ($l -match '^([A-Za-z_\.][\w\.]*)\s*:=\s*(.+)$') { $defs[$matches[1]] = $matches[2].Trim(); continue }
        if ($l -match '=~' -or $l -match '~~') { continue }
        if ($l -match '^([A-Za-z_\.][\w\.]*)\s*~\s*(.+)$') {
            $dest = $matches[1]
            foreach ($term in ($matches[2] -split '\+')) {
                if ($term.Trim() -match '^([A-Za-z_\.][\w\.]*)\s*\*\s*([A-Za-z_\.][\w\.]*)\s*$') {
                    if (-not $edges.ContainsKey($matches[1])) { $edges[$matches[1]] = @{ Origen = $matches[2]; Destino = $dest } }
                }
            }
        }
    }
    if ($defs.Count -eq 0 -or $edges.Count -eq 0) { return @() }

    $defTable = @{}
    foreach ($k in $defs.Keys) { $defTable[$k] = $defs[$k] }

    foreach ($name in $defs.Keys) {
        try { $poly = Get-EffectPolynomial -Expr $defs[$name] -Defs $defTable } catch { continue }
        $ends = @{}
        $skip = $false
        foreach ($mono in $poly) {
            foreach ($atom in $mono) { if (-not $edges.ContainsKey($atom)) { $skip = $true } }
            if ($skip) { break }
            $origs = @($mono | ForEach-Object { $edges[$_].Origen })
            $dests = @($mono | ForEach-Object { $edges[$_].Destino })
            $heads = @($mono | Where-Object { $dests -notcontains $edges[$_].Origen } | Select-Object -Unique)
            $ok = ($heads.Count -eq 1)
            $cur = $null
            if ($ok) {
                $remaining = New-Object System.Collections.ArrayList
                foreach ($a in $mono) { [void]$remaining.Add($a) }
                $curLabel = $heads[0]
                [void]$remaining.Remove($curLabel)
                $cur = $edges[$curLabel].Destino
                $src = $edges[$curLabel].Origen
                while ($remaining.Count -gt 0) {
                    $nextLabel = $remaining | Where-Object { $edges[$_].Origen -eq $cur } | Select-Object -First 1
                    if (-not $nextLabel) { $ok = $false; break }
                    [void]$remaining.Remove($nextLabel)
                    $cur = $edges[$nextLabel].Destino
                }
            }
            if (-not $ok) {
                $errs += "ERROR DE FORMULACION SEM: '$name := $($defs[$name])' multiplica etiquetas ($($mono -join ' * ')) que NO forman un camino causal continuo (origen -> mediador -> destino). Un efecto indirecto es el producto de los senderos consecutivos de una misma cadena (ej. a * b para X -> M -> Y)."
                $ends = @{}
                break
            }
            $ends["$src -> $cur"] = $true
        }
        if ($skip) { continue }
        if ($ends.Keys.Count -gt 1) {
            $errs += "ERROR DE FORMULACION SEM: '$name := $($defs[$name])' suma efectos de caminos con distinto origen/destino ($($ends.Keys -join '; ')). El efecto total de X sobre Y es EXCLUSIVAMENTE el sendero directo X -> Y (si existe en el modelo) mas la suma de los efectos indirectos X -> Y; PROHIBIDO sumar senderos hacia el mediador (X -> M) u otros destinos. Si el modelo NO tiene sendero directo X -> Y, el efecto total es igual al efecto indirecto (total := indirecto) y no se agrega ningun sendero."
        }
    }
    return $errs
}

function Audit-ScriptContract {
    param(
        [string]$ScriptPath,
        [object]$Contract,
        [string]$ConsoleOutput = ""
    )

    $result = [ordered]@{
        Passed = $true
        ErroresCriticos = @()
        OmisionesEntregables = @()
        DirectivasReparacion = @()
    }

    if (!(Test-Path $ScriptPath)) {
        $result.Passed = $false
        $result.ErroresCriticos += "No se encuentra el archivo de script: $ScriptPath"
        return $result
    }

    $scriptContent = [System.IO.File]::ReadAllText((Resolve-Path $ScriptPath), [System.Text.Encoding]::UTF8)

    # --------------------------------------------------------------------------
    # 0. AUDITORIA DE SALIDA REAL DE CONSOLA (ANTI-FALSOS POSITIVOS DE TRYCATCH)
    # --------------------------------------------------------------------------
    if (![string]::IsNullOrWhiteSpace($ConsoleOutput)) {
        if ($ConsoleOutput -match '(?i)Error:\s*El modelo no convergi|hubo un fallo cr[iíÃ]') {
            $result.Passed = $false
            $msg = "FALLO DE ESTIMACION ENCUBIERTO POR TRYCATCH: El script capturo un error fatal de lavaan dentro de tryCatch() e imprimio un mensaje de error sin calcular resultados. PROHIBIDO envolver cfa() o sem() en tryCatch(); asegurate de filtrar las filas de las variables nominales/exogenas (datos <- datos[datos[['var']] %in% c(...), ]) antes de estimar."
            $result.ErroresCriticos += $msg
            $result.DirectivasReparacion += $msg
        }
    }

    # --------------------------------------------------------------------------
    # 1. AUDITORIA DE FUNCIONES Y REGLAS PROHIBIDAS POR ARQUETIPO
    # --------------------------------------------------------------------------
    if ($Contract.Modelado.FuncionesProhibidas -contains "lavaan") {
        # Detectar si invoco lavaan(...) a secas en lugar de cfa() o sem()
        if ($scriptContent -match '(?m)^\s*fit\w*\s*<-\s*lavaan\s*\(' -or $scriptContent -match '\blavaan\s*\(\s*(?:modelo|model)') {
            $result.Passed = $false
            $msg = "VIOLACION DE ARQUITECTURA: Se detecto el uso de la funcion de bajo nivel 'lavaan()'. En modelos factoriales confirmatorios, 'lavaan()' no identifica automaticamente las varianzas latentes, provocando que el modelo no converja. DEBES USAR 'cfa(modelo, ...)' o 'sem(modelo, ...)'."
            $result.ErroresCriticos += $msg
            $result.DirectivasReparacion += $msg
        }
    }

    # Prohibición de orthogonal = TRUE en Segundo Orden
    $arch = if ($Contract.Modelado.Arquetipo) { $Contract.Modelado.Arquetipo } else { "" }
    if ($arch -eq "AFC_Segundo_Orden" -or $Contract.Modelado.NombreArquetipo -match "Segundo Orden") {
        if ($scriptContent -match 'orthogonal\s*=\s*TRUE') {
            $result.Passed = $false
            $msg = "VIOLACION DE ARQUITECTURA: Se detecto 'orthogonal = TRUE' en un modelo de segundo orden. La condicion de ortogonalidad aplica exclusivamente a modelos bifactoriales. En modelos de segundo orden, forzar ortogonalidad destruye la estructura factorial."
            $result.ErroresCriticos += $msg
            $result.DirectivasReparacion += $msg
        }
        # Prohibición de correlacionar factores de primer orden entre sí
        if ($scriptContent -match '(?m)^\s*[A-Za-z0-9_]+\s*~~\s*[A-Za-z0-9_]+') {
            # Verificar si son factores de 1er orden correlacionados
            $result.Passed = $false
            $msg = "DESVIO METODOLOGICO: En un modelo jerarquico de segundo orden, el macro-factor explica la covarianza entre los factores de primer orden. Queda prohibido correlacionar los factores de primer orden entre si con '~~'."
            $result.ErroresCriticos += $msg
            $result.DirectivasReparacion += $msg
        }
    }

    # Prohibición de htmt() en Bifactorial
    if ($arch -eq "Bifactor" -or $Contract.Modelado.NombreArquetipo -match "Bifactor") {
        if ($scriptContent -match '\bhtmt\s*\(') {
            $result.Passed = $false
            $msg = "VIOLACION METODOLOGICA: En modelos bifactoriales ortogonales queda prohibido invocar htmt(), pues arroja error fatal al compartir indicadores el factor general con los especificos."
            $result.ErroresCriticos += $msg
            $result.DirectivasReparacion += $msg
        }
    }

    # Prohibición de fa() para ACP
    if ($arch -eq "ACP") {
        if ($scriptContent -match '\bfa\s*\(' -and $scriptContent -notmatch '\bprincipal\s*\(') {
            $result.Passed = $false
            $msg = "VIOLACION METODOLOGICA: En Analisis de Componentes Principales (ACP) es obligatorio usar psych::principal(). Queda terminantemente prohibido usar fa()."
            $result.ErroresCriticos += $msg
            $result.DirectivasReparacion += $msg
        }
    }

    # Prohibición de principal() para AFE
    if ($arch -eq "AFE") {
        if ($scriptContent -match '\bprincipal\s*\(' -and $scriptContent -notmatch '\bfa\s*\(') {
            $result.Passed = $false
            $msg = "VIOLACION METODOLOGICA: En Analisis Factorial Exploratorio (AFE) es obligatorio usar psych::fa(). Queda prohibido usar principal()."
            $result.ErroresCriticos += $msg
            $result.DirectivasReparacion += $msg
        }
    }

    # Prohibición de multigrupo en MIMIC
    if ($arch -eq "MIMIC") {
        if ($scriptContent -match 'group\s*=' -or $scriptContent -match 'group\.equal\s*=') {
            $result.Passed = $false
            $msg = "VIOLACION METODOLOGICA: En Charly la invarianza se evalua exclusivamente mediante modelo MIMIC (Muthen, 1989). Queda terminantemente prohibido usar CFA multigrupo con 'group = ...'."
            $result.ErroresCriticos += $msg
            $result.DirectivasReparacion += $msg
        }
    }

    # --------------------------------------------------------------------------
    # 2. AUDITORIA DE PREPROCESAMIENTO: Inversiones
    # --------------------------------------------------------------------------
    if ($Contract.Preprocesamiento.InvertirItems.Count -gt 0) {
        foreach ($invItem in $Contract.Preprocesamiento.InvertirItems) {
            $invPat = '(?i)datos(?:\s*\$\s*|\s*\[\[?\s*[''"]?)' + $invItem + '(?:[''"]?\s*\]\]?)?\s*<-.*(?:max|min).*datos(?:\s*\$\s*|\s*\[\[?\s*[''"]?)' + $invItem
            if ($scriptContent -notmatch $invPat) {
                $result.Passed = $false
                $msg = "OMISION DE PREPROCESAMIENTO: No se detecto la inversion del item $invItem. Debe invertirse explicitamente: datos`$$invItem <- max(datos`$$invItem, na.rm = TRUE) + min(datos`$$invItem, na.rm = TRUE) - datos`$$invItem."
                $result.OmisionesEntregables += $msg
                $result.DirectivasReparacion += $msg
            }
        }
    }

    # --------------------------------------------------------------------------
    # 3. AUDITORIA DE PREPROCESAMIENTO: Recodificaciones a NA
    # --------------------------------------------------------------------------
    if ($Contract.Preprocesamiento.RecodificarNA.Count -gt 0) {
        foreach ($rn in $Contract.Preprocesamiento.RecodificarNA) {
            if ($rn.Variable -eq "TODAS") {
                $hasGlobalRecode = ($scriptContent -match 'datos\[datos\s*==\s*7\]\s*<-\s*NA')
                $hasPuntualRecode = ($scriptContent -match "datos\[\['[^']+'\]\]\[datos\[\['[^']+'\]\]\s*==\s*7\]\s*<-\s*NA")
                $hasLoopRecode = ($scriptContent -match 'for\s*\(\s*col\s+in\s+.*?\)\s*\{[^}]*datos\[\[col\]\]\[datos\[\[col\]\]\s*==\s*7\]\s*<-\s*NA')
                $hasPercentInRecode = ($scriptContent -match 'datos\$[a-zA-Z0-9_]+\s*\[\s*datos\$[a-zA-Z0-9_]+\s*(?:==|%in%)\s*7\s*\]\s*<-\s*NA')
                
                if (-not $hasGlobalRecode -and -not $hasPuntualRecode -and -not $hasLoopRecode -and -not $hasPercentInRecode) {
                    $result.Passed = $false
                    $msg = "OMISION DE NA: No se detecto la recodificacion del valor 7 a NA en la base (ni global, ni puntual por columna, ni mediante bucle)."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            } else {
                $varName = $rn.Variable
                $varPat = "(?i)datos(?:\s*\$\s*|\s*\[\[?\s*['""]?)$varName.*<-\s*NA|datos(?:\s*\$\s*|\s*\[\[?\s*['""]?)$varName.*<-\s*(?:ifelse|if_else).*NA|is\.na\(.*$varName\)"
                $hasVarRecode = ($scriptContent -match $varPat -or $scriptContent -match 'datos\[datos\s*==\s*7\]\s*<-\s*NA')
                if (!$hasVarRecode) {
                    $result.Passed = $false
                    $msg = "OMISION DE NA: No se recodifico a NA la variable $varName para los valores $($rn.Valores -join ', ')."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }
        }
    }

    # --------------------------------------------------------------------------
    # 4. AUDITORIA DE ENTREGABLES OBLIGATORIOS POR ARQUETIPO
    # --------------------------------------------------------------------------
    $chkKeys = if ($Contract.ChecklistEntregables -is [System.Collections.IDictionary]) {
        @($Contract.ChecklistEntregables.Keys)
    } elseif ($Contract.ChecklistEntregables.PSObject -and $Contract.ChecklistEntregables.PSObject.Properties) {
        @($Contract.ChecklistEntregables.PSObject.Properties.Name)
    } else {
        @()
    }

    foreach ($k in $chkKeys) {
        switch ($k) {
            "AjusteGlobal" {
                if ($scriptContent -notmatch '\bsummary\s*\(' -and $scriptContent -notmatch '\bfitMeasures\s*\(') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: Falta reportar el ajuste global del modelo mediante print(summary(fit, fit.measures = TRUE, standardized = TRUE))."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            { $_ -in @("FiabilidadCompuesta", "FiabilidadSegundoOrden", "FiabilidadOmega") } {
                # [CR NATIVA] La CR debe calcularse a mano con las cargas estandarizadas del fit; las funciones empaquetadas
                # colapsan en 2.o orden + WLSMV + pairwise + covariables. Antes bastaba con que el script mencionara
                # 'omega(' o 'reliability(' (y un script SIN CR podia pasar con "100 % de cumplimiento").
                $crCode = if (Get-Command Get-NativeCompositeReliabilityRCode -ErrorAction SilentlyContinue) { Get-NativeCompositeReliabilityRCode -FitName "fit" } else { "CR = (sum(lambda))^2 / ((sum(lambda))^2 + sum(1 - lambda^2)) con lavaan::standardizedSolution(fit)" }
                $codeNoComments = (($scriptContent -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
                if ($codeNoComments -match '(?i)\b(?:compositeRel|compRelSEM|reliability)\s*\(') {
                    $result.Passed = $false
                    $msg = "USO PROHIBIDO DE FUNCION EMPAQUETADA PARA LA CR: Se detecto semTools::compRelSEM()/reliability()/compositeRel(). Colapsan en modelos de segundo orden con estimador ordinal (WLSMV), missing pairwise y covariables. Reemplazalas por el calculo NATIVO con las cargas estandarizadas del fit:`n$crCode"
                    $result.ErroresCriticos += $msg
                    $result.DirectivasReparacion += $msg
                }
                $hasLoadings = ($codeNoComments -match '(?i)standardizedsolution|parameterestimates\s*\([^)]*standardized|std\.all|est\.std|lavInspect\s*\([^)]*std')
                $hasFormula = ($codeNoComments -match '(?is)(?:\bsum\s*\([^)]*\)\s*\)?|\w*sum\w*\s*\)?)\s*\^\s*2') -and ($codeNoComments -match '(?i)1\s*-\s*[\w\.\$\[\]]+\s*\^\s*2')
                $printsCR = ($codeNoComments -match '(?i)\b(?:print|cat|message|kable)\s*\([^\r\n]*(?:\bcr\w*|fiab\w*|\bomega\w*|\bcomp_?rel\w*)') -or ($codeNoComments -match '(?i)\bcat\s*\([^\r\n]*(?:\bCR\b|fiabilidad)')
                if (-not ($hasLoadings -and $hasFormula -and $printsCR)) {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: Falta calcular y MOSTRAR EN CONSOLA la Fiabilidad Compuesta (CR) de cada factor con la formula nativa CR = (sum(lambda))^2 / ((sum(lambda))^2 + sum(1 - lambda^2)) sobre las cargas estandarizadas del objeto fit. Incluye exactamente:`n$crCode"
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            { $_ -in @("AVE_FornellLarcker", "FornellLarcker") } {
                if ($scriptContent -notmatch '(?i)(?:cor\.lv|lavInspect.*cor|fornell|htmt|reliability)' -and $scriptContent -notmatch '(?i)(?:ave|varianza\s+extraida|colmeans\s*\(.*lambda|sum\s*\(.*lambda\^2)') {
                    $result.Passed = $false
                    $msg = "OMISION CRITICA DE ENTREGABLE: Falta calcular el AVE y el Criterio de Fornell-Larcker (raiz cuadrada de AVE vs correlaciones latentes con lavInspect(fit, 'cor.lv'))."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "HTMT" {
                if ($scriptContent -notmatch '\bhtmt\s*\(') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: Falta calcular la ratio Heterotrait-Monotrait (HTMT) mediante semTools::htmt(modelo, data = datos)."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "Top10ModIndices" {
                if ($scriptContent -notmatch '(?i)(?:modindices|modificationindices)\s*\(' -or ($scriptContent -notmatch '\bhead\s*\(' -and $scriptContent -notmatch '\border\s*\(')) {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: Falta extraer e imprimir los 10 indices de modificacion mas altos ordenados de mayor a menor (mi <- modificationIndices(fit); print(head(mi[order(mi`$mi, decreasing = TRUE), ], 10)))."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "CargasSegundoOrden" {
                if ($scriptContent -notmatch '(?i)(?:parameterestimates|standardizedsolution|summary)\s*\(') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: Debes reportar las cargas estandarizadas del modelo de segundo orden mediante print(parameterEstimates(fit, standardized = TRUE)) o summary(fit, standardized = TRUE)."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "IndicesBifactor" {
                if ($scriptContent -notmatch '(?i)\b(?:om_h|omega_h|ecv|puc|omega_t|omega_s|omega_hs)\b') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: Falta calcular e imprimir los indices canonicos de Reise y Rodriguez (Omega Jerarquico, Omega de Subescala, ECV y PUC)."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "EstructuralMIMIC" {
                if ($scriptContent -notmatch '~\s*[A-Za-z0-9_]+' -or ($scriptContent -notmatch '\bsem\s*\(')) {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: En el modelo MIMIC, los factores latentes deben regresar sobre las covariables (ej. Factores ~ Covariables) y ajustarse con sem()."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "DIFScoreTest" {
                if ($scriptContent -notmatch '\blavTestScore\s*\(') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: La evaluacion de DIF en MIMIC exige calcular el Score Test de Muthen (1989) univariado mediante lavTestScore(fit_base, add = p_syn, epc = TRUE)."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "BonferroniFormulado" {
                if ($scriptContent -notmatch '\bp\.adjust\s*\(' -and $scriptContent -notmatch '\*\s*(?:nrow|length|k|9|24)\b' -and $scriptContent -notmatch '0\.05\s*/') {
                    $result.Passed = $false
                    $msg = "DESVIO METODOLOGICO: La correccion de Bonferroni debe aplicarse sobre los p-valores mediante p.adjust(tabla_dif`$p.value, method = 'bonferroni') o umbral p < (0.05 / nrow(tabla_dif))."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "SenderosDirectos" {
                if ($scriptContent -notmatch '~\s*[A-Za-z0-9_]+') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: Debes declarar las regresiones de senderos directos confirmados con el operador '~'."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "EfectoIndirecto" {
                if ($scriptContent -notmatch ':=\s*[a-zA-Z0-9_]+\s*\*\s*[a-zA-Z0-9_]+') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: No se definio formalmente el efecto indirecto mediado con el operador ':=' (ej. 'indirecto := a * b') etiquetando los senderos estructurales 'M ~ a * X' e 'Y ~ b * M'."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }

                $effectErrors = @(Test-DefinedEffectsAreValidPaths -ScriptContent $scriptContent)
                foreach ($ee in $effectErrors) {
                    $result.Passed = $false
                    $result.ErroresCriticos += $ee
                    $result.DirectivasReparacion += $ee
                }

                $syntax = if ($Contract.Modelado.PSObject.Properties['SintaxisLavaan'] -and $Contract.Modelado.SintaxisLavaan) {
                    $Contract.Modelado.SintaxisLavaan
                } elseif (Get-Command Build-UniversalLavaanStructuralSyntax -ErrorAction SilentlyContinue) {
                    Build-UniversalLavaanStructuralSyntax -Contract $Contract
                } else {
                    ""
                }

                if (![string]::IsNullOrWhiteSpace($syntax)) {
                    $defLines = $syntax -split '\r?\n' | Where-Object { $_ -match '^\s*([a-zA-Z0-9_]+)\s*:=' }
                    foreach ($dl in $defLines) {
                        if ($dl -match '^\s*([a-zA-Z0-9_]+)\s*:=\s*(.+)$') {
                            $paramName = $matches[1].Trim()
                            if ($scriptContent -notmatch "\b$paramName\b") {
                                $result.Passed = $false
                                $msg = "ERROR DE FORMULACION SEM: El script omitio el parametro canonico obligatorio '$paramName'. Debes incluir en lavaan exactamente: $($dl.Trim())"
                                $result.ErroresCriticos += $msg
                                $result.DirectivasReparacion += $msg
                            }
                        }
                    }
                }
            }

            "ExtraccionComponentes" {
                if ($scriptContent -notmatch '\bprincipal\s*\(') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: En ACP debes usar psych::principal() para extraer los componentes principales."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "ExtraccionFactores" {
                if ($scriptContent -notmatch '\bfa\s*\(') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: En AFE debes usar psych::fa() para extraer los factores comunes."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "MatrizRotada" {
                if ($scriptContent -notmatch '(?i)(?:loadings|print\s*\(\s*(?:acp|afe|res|modelo|fit))') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: Debes imprimir la matriz de cargas rotadas mediante print(modelo) o print(modelo`$loadings)."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "PsychPolicoricasSeguras" {
                if ($scriptContent -match '\bfa\s*\(' -and $scriptContent -match 'cor\s*=\s*["'']poly["'']' -and $scriptContent -notmatch 'na\.omit') {
                    $result.Passed = $false
                    $msg = "RIESGO DE COLAPSO NUMERICO: Para evitar que psych::fa() y psych::principal() fallen en polyBinBvn por NAs, debes aplicar na.omit() a las columnas de los items antes de pasarlo a fa() y principal()."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "OddsRatios" {
                if ($scriptContent -notmatch '(?i)exp\s*\(\s*(?:coef|ctable)') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: En regresion logistica debes calcular los Odds Ratios mediante print(exp(coef(fit))) o exp(ctable[,1])."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "PValoresExplicitos" {
                if ($scriptContent -match '\bpolr\s*\(' -and $scriptContent -notmatch '\bpnorm\s*\(' -and $scriptContent -notmatch '\bpt\s*\(') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: En la regresion con polr(), se omitio el calculo de p-valores explicitos (pnorm)."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "CoeficientesProbit" {
                if ($scriptContent -notmatch '(?i)(?:coef|summary|pnorm)\s*\(') {
                    $result.Passed = $false
                    $msg = "OMISION DE ENTREGABLE: En regresion probit debes reportar los coeficientes probit y sus p-valores."
                    $result.OmisionesEntregables += $msg
                    $result.DirectivasReparacion += $msg
                }
            }

            "BucleNoRecursivo" {
                $itemConfig = $Contract.ChecklistEntregables["BucleNoRecursivo"]
                $permiteResidual = ($itemConfig.Descripcion -match 'covarianza residual permitida' -or $itemConfig.PermiteResidual -eq $true)
                $f1 = if ($itemConfig.FactoresReciprocos -and $itemConfig.FactoresReciprocos.Count -ge 2) { $itemConfig.FactoresReciprocos[0] } else { ".*" }
                $f2 = if ($itemConfig.FactoresReciprocos -and $itemConfig.FactoresReciprocos.Count -ge 2) { $itemConfig.FactoresReciprocos[1] } else { ".*" }
                
                $covPattern = "(?i)($f1\s*~~\s*$f2|$f2\s*~~\s*$f1)"
                if (!$permiteResidual) {
                    if ($scriptContent -match $covPattern) {
                        $result.Passed = $false
                        $msg = "DISTORSION METODOLOGICA: En modelos no recursivos identificados con instrumentos segun Bollen (1989), NO debes declarar la covarianza residual entre los factores reciprocos ($f1 ~~ $f2) porque sobre-satura la identificacion del bucle."
                        $result.OmisionesEntregables += $msg
                        $result.DirectivasReparacion += $msg
                    }
                } else {
                    if ($scriptContent -notmatch $covPattern -and $scriptContent -notmatch '(?m)^\s*[A-Za-z0-9_]+\s*~~\s*[A-Za-z0-9_]+') {
                        $result.Passed = $false
                        $msg = "OMISION DE ENTREGABLE: Se solicito expresamente permitir la correlacion de perturbaciones residuales ($f1 ~~ $f2) y no fue incluida en el modelo."
                        $result.OmisionesEntregables += $msg
                        $result.DirectivasReparacion += $msg
                    }
                }
            }
        }
    }

    return $result
}
