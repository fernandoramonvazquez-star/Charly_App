# ==============================================================================
# CHARLY v4.0 - ENSAMBLADOR DE PROMPTS MODULAR POR ARQUETIPO CANONICO
# ==============================================================================
# Ensambla un prompt 100% humano, conciso y de alta densidad para LLM.
# Estructurado estrictamente alrededor de los 9 Arquetipos Canonicos (de a uno).
# Inyecta quirurgicamente SOLO las directivas del arquetipo activo, reduciendo
# el tamano del prompt de 25 KB a ~8-11 KB (65% a 75% menos tokens en CPU).
# ==============================================================================

param(
    [string]$UserGoal = "",
    [string]$CanonicalArchetype = "",
    [string]$DataBlockPath = "dataset_prompt_block.txt",
    [string]$EnvBlockPath = "r_env_prompt_block.txt",
    [string]$OutputFile = "workspace/full_prompt.txt"
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$baseDir = Split-Path $PSScriptRoot -Parent
if (!(Test-Path (Join-Path $baseDir "workspace"))) {
    New-Item -ItemType Directory -Force -Path (Join-Path $baseDir "workspace") | Out-Null
}
$psicoParserPath = Join-Path $baseDir "runtime/psico_parser.ps1"
if (Test-Path $psicoParserPath) { . $psicoParserPath }
$contractBuilderPath = Join-Path $baseDir "runtime/contract_builder.ps1"
if (Test-Path $contractBuilderPath) { . $contractBuilderPath }

$userGoalFile = Join-Path $baseDir "workspace/user_goal.txt"
if ([string]::IsNullOrWhiteSpace($UserGoal) -and (Test-Path $userGoalFile)) {
    try {
        $UserGoal = [System.IO.File]::ReadAllText($userGoalFile, [System.Text.Encoding]::UTF8)
    } catch {}
}

function Get-SafePath ([string]$p, [string]$parent) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    try {
        $invalidChars = [System.IO.Path]::GetInvalidPathChars()
        if ($p.IndexOfAny($invalidChars) -ge 0) { return "" }
        if ([System.IO.Path]::IsPathRooted($p)) { return $p }
        $candidateWs = Join-Path (Join-Path $parent "workspace") $p
        if (Test-Path $candidateWs) { return $candidateWs }
        return (Join-Path $parent $p)
    } catch { return "" }
}

$dataFile = Get-SafePath $DataBlockPath $baseDir
$envFile  = Get-SafePath $EnvBlockPath $baseDir
$outFile  = Get-SafePath $OutputFile $baseDir

$dataBlock = if (![string]::IsNullOrWhiteSpace($dataFile) -and (Test-Path $dataFile)) { [System.IO.File]::ReadAllText($dataFile, [System.Text.Encoding]::UTF8) } else { "No hay datos de perfilado." }
$envBlock  = if (![string]::IsNullOrWhiteSpace($envFile) -and (Test-Path $envFile))   { [System.IO.File]::ReadAllText($envFile, [System.Text.Encoding]::UTF8) }  else { "No hay datos de entorno." }

# Extraer nombre del archivo original y de hoja si estan presentes
$sourceFileName = "datos.xlsx"
if ($dataBlock -match 'Archivo fuente:\s*`([^`]+)`') {
    $sourceFileName = $matches[1]
}

$sheetParam = ""
if ($dataBlock -match 'Hoja:\s*`([^`]+)`|Hoja:\s*''([^'']+)''') {
    $sheetFound = if ($matches[1]) { $matches[1] } else { $matches[2] }
    $sheetParam = ", sheet = '$sheetFound'"
}

$readInstruction = if ($sourceFileName -match '(?i)\.sav$') {
    "haven::read_sav(`"$sourceFileName`")"
} elseif ($sourceFileName -match '(?i)\.dta$') {
    "haven::read_dta(`"$sourceFileName`")"
} elseif ($sourceFileName -match '(?i)\.rds$') {
    "readRDS(`"$sourceFileName`")"
} elseif ($sourceFileName -match '(?i)\.csv$') {
    "read.csv(`"$sourceFileName`")"
} else {
    "readxl::read_excel(`"$sourceFileName`"$sheetParam)"
}

function Remove-Diacritics ([string]$text) {
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

# ==============================================================================
# IDENTIFICACION EXCLUSIVA DEL ARQUETIPO CANONICO ACTIVO (1 DE 9)
# ==============================================================================
$rawUserGoal = ($UserGoal -split '={20,}')[0]

$contractObj = $null
$existingContractPath = Join-Path $baseDir "workspace/contract_specs.json"
if (Test-Path $existingContractPath) {
    try {
        $contractObj = Get-Content $existingContractPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {}
}

if (-not $contractObj -and (Get-Command Build-PsychometricContract -ErrorAction SilentlyContinue)) {
    try {
        $contractObj = Build-PsychometricContract -UserPrompt $rawUserGoal
        $contractJson = $contractObj | ConvertTo-Json -Depth 6
        Set-Content (Join-Path $baseDir "workspace/contract_specs.json") $contractJson -Encoding UTF8
    } catch {}
}

$activeArchetype = "AFC_Primer_Orden"
if (![string]::IsNullOrWhiteSpace($CanonicalArchetype)) {
    $activeArchetype = $CanonicalArchetype
} elseif ($contractObj -and $contractObj.Modelado -and $contractObj.Modelado.Arquetipo) {
    $activeArchetype = $contractObj.Modelado.Arquetipo
} elseif (Get-Command Get-CanonicalArchetype -ErrorAction SilentlyContinue) {
    $activeArchetype = Get-CanonicalArchetype -UserPrompt $rawUserGoal
}

Write-Host "[PROMPT BUILDER] Arquetipo Canonico Activo: [$activeArchetype]" -ForegroundColor Cyan

# ==============================================================================
# CONSTRUCCION MODULAR QUIRURGICA: BASE + ARQUETIPO ACTIVO + CIERRE
# ==============================================================================
$fence = '```'

# 1. Base Universal (Lectura, Faltantes, Inversión de Ítems, Fidelidad de Nombres)
$blockBase = @"
ESTILO DE CODIGO R: 100% HUMANO, MINIMALISTA Y ELEGANTE
Escribe el script de R EXACTAMENTE como lo haria un investigador psicometrista experto en RStudio.
PROHIBIDO USAR O INVENTAR NOMBRES DE VARIABLES FICTICIAS. Trabaja exclusivamente con las variables y factores reales descritos en la Ficha Tecnica.

REGLAS GENERALES OBLIGATORIAS:
1. LIBRERIAS:
   - Carga unicamente las librerias requeridas mediante library(...) segun el analisis solicitado.
   - PROHIBIDO ejecutar install.packages().

2. LECTURA DE DATOS, HIGIENE Y PREPROCESAMIENTO:
   - Lectura de datos: Lee directamente el archivo indicado con $readInstruction.
   - RECODIFICACION DE FALTANTES Y FILTRADO DE CATEGORIAS (HIGIENE DE DATOS):
     * Si se solicita recodificar valores a NA en items de medicion (ej. 7 a NA):
       - La recodificacion debe ejecutarse de forma OBLIGATORIA INMEDIATAMENTE despues de leer los datos y ANTES de cualquier inversion o estimacion.
       - En los indicadores de factores latentes ('=~'), recodifica solo la celda en esas columnas sin borrar la fila (para respetar missing = "pairwise", "fiml" o "listwise").
       - Si aplica de forma general a los items del modelo, ejecutala de forma limpia sobre los items del instrumento: datos[datos == valor_na] <- NA (o por columnas analizadas).
     * FILTRADO DE CATEGORIAS EN VARIABLES NOMINALES Y COVARIABLES EXOGENAS:
       - Cuando se solicite conservar ciertas categorias en una variable nominal (ej. GENERO conservar 1 y 2), filtra directamente las filas del dataframe: datos <- datos[datos[['var']] %in% c(1, 2), ].
       - Si una covariable exogena (predictora a la derecha de ~) contiene NAs o tuvo valores recodificados a NA, filtra sus filas antes de estimar: datos <- datos[!is.na(datos`$covariable), ].
   - INVERSION DE ITEMS (REVERSE CODING):
     * Si se solicita invertir un item: datos`$item <- max(datos`$item, na.rm = TRUE) + min(datos`$item, na.rm = TRUE) - datos`$item. Prohibido usar constantes numericas fijas arbitrarias.

3. FIDELIDAD DE NOMBRES DE VARIABLES Y FACTORES:
   - Respeta estrictamente los nombres de variables y factores tal como los especifico el investigador.
   - PROHIBICION DE PALABRAS RESERVADAS: Queda terminantemente prohibido nombrar variables latentes con 'F' (alias de FALSE) o 'T' (alias de TRUE). En modelos jerarquicos o bifactoriales, usa 'G' o 'Factor_General'.
   - Si un nombre de factor coincide con el nombre de una columna existente en la base, agrega check.lv.names = FALSE en la llamada de lavaan.

4. REGLAS UNIVERSALES DE SINTAXIS Y ESTIMACION EN LAVAAN (APLICA A TODO MODELO CFA, SEM, BIFACTOR Y MIMIC):
   - MODELO DE MEDIDA Y COVARIANZAS:
     * Cada factor latente de primer orden se define con el operador '=~' seguido de sus indicadores observados: Factor =~ item1 + item2 + ...
     * Las correlaciones de errores de medida o covarianzas residuales se especifican de a pares con el operador binario '~~': item1 ~~ item2. Prohibido encadenar tres o mas elementos con '~~'.
     * PROHIBICION SINTACTICA ESTRICTA: Adentro de las comillas de 'modelo <- ''...''' solo van ecuaciones de lavaan ('=~', '~', '~~', ':='). Queda TERMINANTEMENTE PROHIBIDO escribir codigo R como 'ordered <- c(...)' o asignaciones '<-' / '=' adentro del string del modelo lavaan.
   - ESTIMADORES Y ARGUMENTO 'ordered' EN LA LLAMADA A cfa() O sem():
     * Los argumentos 'estimator', 'ordered' y 'missing' se pasan SIEMPRE como argumentos de la funcion cfa(modelo, data = datos, ...) o sem(modelo, data = datos, ...):
       - Para estimador WLSMV (items discretos/ordinales): estimator = "WLSMV", ordered = c(...) (incluyendo exhaustivamente todos los indicadores observados de los factores de medida) y missing = "pairwise".
       - Si hay excepciones continuas dentro de un modelo ordinal WLSMV, excluyelas con setdiff(): ordered_vars <- setdiff(todos_los_indicadores, continuas) y pasa ordered = ordered_vars en cfa()/sem().
       - Para estimador MLR o ML (variables continuas): estimator = "MLR" (o "ML") y missing = "fiml" (o "listwise"), omitiendo por completo el argumento 'ordered'.
     * Las covariables predictoras exogenas (a la derecha de '~') NUNCA se incluyen en el vector 'ordered'.
"@

# 2. Bloque Especifico del Arquetipo Canonico Activo
$blockArchetype = ""

switch ($activeArchetype) {

    "AFC_Primer_Orden" {
        $blockArchetype = @"

ARQUETIPO CANONICO: AFC DE PRIMER ORDEN
Analisis Factorial Confirmatorio con Fiabilidad Compuesta (FC), AVE, Criterio de Fornell-Larcker, HTMT y Modindices (Top 10).

DIRECTIVAS ESPECIFICAS:
1. ESPECIFICACION Y ESTIMACION:
   - Define cada factor latente con el operador '=~' seguido de sus indicadores observados: Factor =~ item1 + item2 + ...
   - Funcion de estimacion obligatoria: cfa(modelo, data = datos, ...).
   - PROHIBIDO TERMINANTEMENTE usar lavaan() a secas.
   - ESTIMADORES:
     * Para items discretos/ordinales: estimator = "WLSMV", ordered = c(...) (con todos los indicadores del modelo) y missing = "pairwise".
     * Si se solicitan variables continuas: estimator = "MLR" (o "ML") con missing = "fiml", omitiendo 'ordered'.
     * Si se excluyen variables de 'ordered', usa: ordered_vars <- setdiff(todos_los_indicadores, continuas).

2. METRICAS Y ENTREGABLES OBLIGATORIOS (DEBEN FIGURAR TODOS EN EL SCRIPT):
   - Ajuste global del modelo:
     print(summary(fit, fit.measures = TRUE, standardized = TRUE))
   - Fiabilidad Compuesta (CR) por factor, calculada de forma NATIVA con las cargas estandarizadas del objeto fit:
     CR = (sum(lambda))^2 / ((sum(lambda))^2 + sum(1 - lambda^2))  (codigo exacto en el CONTRATO; mostrar con print()).
     PROHIBIDO semTools::compRelSEM / reliability / compositeRel (colapsan con WLSMV, pairwise y covariables).
   - Varianza Media Extraida (AVE) y Criterio de Fornell-Larcker:
     pe <- parameterEstimates(fit, standardized = TRUE)
     ave <- sapply(unique(pe`$lhs[pe`$op == "=~"]), function(f) mean(pe`$std.all[pe`$lhs == f & pe`$op == "=~"]^2))
     cat("\n--- Criterio de Fornell-Larcker (Raiz de AVE vs Correlaciones Latentes) ---\n")
     print(sqrt(ave))
     print(lavInspect(fit, "cor.lv"))
   - Ratio Heterotrait-Monotrait (HTMT):
     print(semTools::htmt(modelo, data = datos))
   - Top 10 Indices de Modificacion (Modindices):
     mi <- modificationIndices(fit)
     print(head(mi[order(mi`$mi, decreasing = TRUE), ], 10))
"@
    }

    "AFC_Segundo_Orden" {
        $blockArchetype = @"

ARQUETIPO CANONICO: AFC DE SEGUNDO ORDEN
Modelo Jerarquico de Orden Superior donde un macro-factor latente explica la covarianza de los factores de primer orden.

DIRECTIVAS ESPECIFICAS:
1. ESPECIFICACION Y ESTIMACION:
   - Factores de primer orden: Factor1 =~ item1 + item2 + ...
   - Factor de segundo orden (macro-factor): MacroFactor =~ Factor1 + Factor2 + Factor3 + ...
   - Funcion de estimacion obligatoria: cfa(modelo, data = datos, ...).
   - PROHIBICIONES TAXATIVAS:
     * Queda TERMINANTEMENTE PROHIBIDO incluir orthogonal = TRUE. La ortogonalidad aplica exclusivamente a bifactor; en segundo orden anula las covarianzas latentes y destruye el modelo.
     * Queda TERMINANTEMENTE PROHIBIDO correlacionar los factores de primer orden entre si (ej. Factor1 ~~ Factor2). El factor de segundo orden explica la totalidad de sus relaciones.
     * PROHIBIDO encadenar operadores '~~' (ej. F1 ~~ F2 ~~ F3). '~~' es estrictamente binario.
     * PROHIBIDO TERMINANTEMENTE usar lavaan() a secas.

2. METRICAS Y ENTREGABLES OBLIGATORIOS:
   - Ajuste global del modelo:
     print(summary(fit, fit.measures = TRUE, standardized = TRUE))
   - Cargas factoriales de 1er y 2do orden:
     pe <- parameterEstimates(fit, standardized = TRUE)
     print(pe[pe`$op == "=~", c("lhs", "op", "rhs", "est", "se", "z", "pvalue", "std.all")])
   - Fiabilidad Compuesta (CR) de 1er y 2do orden, calculada de forma NATIVA con las cargas estandarizadas del objeto fit:
     CR = (sum(lambda))^2 / ((sum(lambda))^2 + sum(1 - lambda^2))  (codigo exacto en el CONTRATO; mostrar con print() por factor).
     PROHIBIDO semTools::compRelSEM / reliability / compositeRel (colapsan en 2do orden con WLSMV, pairwise y covariables).
   - Si se solicita comparacion con el modelo de primer orden oblicuo, estima ambos modelos y reporta tabla comparativa de fitmeasures.
"@
    }

    "Bifactor" {
        $blockArchetype = @"

ARQUETIPO CANONICO: MODELO BIFACTORIAL
Factor General global que subyace a todos los items + Factores Especificos ortogonales.

DIRECTIVAS ESPECIFICAS:
1. ESPECIFICACION Y CONDICION DE ORTOGONALIDAD:
   - Factor General: Mide OBLIGATORIAMENTE a la totalidad de los items observados de todos los factores especificos:
     Factor_General =~ item1 + item2 + item3 + ... (union exhaustiva de todos los items)
   - Factores Especificos: Miden sus respectivos subconjuntos de items:
     Espec1 =~ item1 + item2 ...
     Espec2 =~ item3 + item4 ...
   - CONDICION DE ORTOGONALIDAD OBLIGATORIA: Pasa siempre orthogonal = TRUE en cfa() o sem():
     fit <- cfa(modelo, data = datos, orthogonal = TRUE, ...)
   - PROHIBICIONES TAXATIVAS:
     * Queda TERMINANTEMENTE PROHIBIDO invocar htmt() o Fornell-Larcker sobre el modelo bifactorial (al compartir items el factor general con los especificos, arrojan error numerico por matriz no definida positiva).
     * Queda TERMINANTEMENTE PROHIBIDO usar lavaan() a secas.

2. COMPUTO EXACTO DE INDICES DE REISE Y RODRIGUEZ EN R:
   Debes incluir obligatoriamente el siguiente bloque de computo oficial en texto plano:
   std <- lavInspect(fit, "std")
   lam <- std`$lambda; th <- diag(std`$theta)
   g_col <- names(which.max(colSums(lam != 0)))
   s_cols <- setdiff(colnames(lam), g_col)
   lam_g <- lam[, g_col]
   v_tot <- (sum(lam_g))^2 + sum(sapply(s_cols, function(s) (sum(lam[, s]))^2 )) + sum(th)
   om_h <- (sum(lam_g))^2 / v_tot
   om_t <- ((sum(lam_g))^2 + sum(sapply(s_cols, function(s) (sum(lam[, s]))^2 ))) / v_tot
   ecv_g <- sum(lam_g^2) / (sum(lam_g^2) + sum(sapply(s_cols, function(s) sum(lam[, s]^2))))
   p_tot <- nrow(lam); tot_cors <- p_tot * (p_tot - 1) / 2
   cont_cors <- sum(sapply(s_cols, function(s) { k <- sum(lam[, s] != 0); k * (k - 1) / 2 }))
   puc <- (tot_cors - cont_cors) / tot_cors
   cat("\n========================================================================\n")
   cat(" INDICES DE ESTRUCTURA Y FIABILIDAD BIFACTORIAL (Reise / Rodriguez)\n")
   cat("========================================================================\n")
   cat(sprintf(" Factor General (%s):\n", g_col))
   cat(sprintf("   - Omega Jerarquico (Omega_H) : %.3f\n", om_h))
   cat(sprintf("   - Omega Total      (Omega_T) : %.3f\n", om_t))
   cat(sprintf("   - Varianza Comun   (ECV_G)   : %.1f%%\n", ecv_g * 100))
   cat(sprintf("   - No Contaminadas  (PUC)     : %.1f%%\n", puc * 100))
   if (any(th < 0)) cat(" [ADVERTENCIA] Solucion impropia: hay varianzas residuales negativas (Heywood); interpretar con cautela estos indices.\n")
   cat("\n Factores Especificos (Omega de Subescala pura):\n")
   for (s in s_cols) {
     it <- which(lam[, s] != 0)
     w_hs <- (sum(lam[it, s]))^2 / ((sum(lam[it, g_col]))^2 + (sum(lam[it, s]))^2 + sum(th[it]))
     cat(sprintf("   - Subescala %-10s: Omega_HS = %.3f\n", s, w_hs))
   }
   cat("========================================================================\n")
"@
    }

    "MIMIC" {
        $blockArchetype = @"

ARQUETIPO CANONICO: MODELO MIMIC Y EVALUACION DE DIF (MUTHEN, 1989)
Multiple Indicators Multiple Causes para evaluar sesgo de reactivos (DIF) e invarianza de medicion.

DIRECTIVAS ESPECIFICAS:
1. ESPECIFICACION DEL MODELO BASE MIMIC:
   - Los constructos latentes de primer orden se definen con sus indicadores ('=~'). Si se solicita un factor de segundo orden (macro-factor), definelo con '=~' sobre los factores de primer orden (ej. Global =~ Factor1 + Factor2 + Factor3).
   - Las covariables predictoras regresan EXCLUSIVAMENTE sobre los FACTORES LATENTES indicados por el investigador:
     * Si el investigador indica que las predictoras cargan sobre el factor de segundo orden (ej. Global), escribe: Global ~ covariable1 + covariable2 + ... (NO regreses los factores de primer orden sobre las covariables en ese caso).
     * Si no hay factor de segundo orden, regresa CADA factor de primer orden sobre las covariables en lineas separadas de sintaxis lavaan:
       Factor1 ~ covariable1 + covariable2
       Factor2 ~ covariable1 + covariable2
       Factor3 ~ covariable1 + covariable2
       (OBLIGATORIO: en lavaan cada ecuacion va en su propia linea; PROHIBIDO escribir 'Factor1 + Factor2 ~ ...').
     * OBLIGATORIO: En modelos MIMIC para evaluar DIF con Score Test (lavTestScore), las covariables DEBEN estar incluidas en el modelo base estimando las regresiones estructurales (Factor ~ Covariable) con sem(). PROHIBIDO estimar un CFA sin covariables para luego llamar a lavTestScore con las covariables, pues lavaan fallara con error de dimensiones (Delta.group).
   - PROHIBICIONES TAXATIVAS:
     * Queda TERMINANTEMENTE PROHIBIDO particionar la muestra mediante CFA multigrupo ('group = ...', 'group.equal = ...', o ajustar sucesivos modelos configural, metrico o escalar). En Charly se utiliza exclusivamente la solucion canonica de Muthen (1989).
     * PROHIBIDO incluir regresiones directas de covariables a los items en el modelo base (esos senderos son contrastados a posteriori mediante Score Test).
     * Las covariables predictoras NUNCA se declaran en el vector ordered = c(...).
     * FILTRADO PREVENTIVO DE NAs: datos <- datos[!is.na(datos`$covariable), ] antes de estimar.
   - Funcion obligatoria: fit <- sem(modelo, data = datos, ...)
   - Reporte base: print(summary(fit, fit.measures = TRUE, standardized = TRUE, rsquare = TRUE))

   - FIABILIDAD COMPUESTA (CR) SI EL USUARIO LA PIDE O HAY 2DO ORDEN:
     Si la consigna solicita fiabilidad compuesta (CR) o el modelo tiene factores latentes jerarquicos, calcula la CR de forma NATIVA con las cargas estandarizadas:
     ss_cr <- lavaan::standardizedSolution(fit)
     ld_cr <- ss_cr[ss_cr`$op == "=~", ]
     cr_tab <- do.call(rbind, lapply(unique(ld_cr`$lhs), function(f) {
       lam <- ld_cr`$est.std[ld_cr`$lhs == f]
       data.frame(Factor = f, CR = round(sum(lam)^2 / (sum(lam)^2 + sum(1 - lam^2)), 3))
     }))
     print(cr_tab, row.names = FALSE)
     (PROHIBIDO semTools::compRelSEM / reliability / compositeRel).

2. EVALUACION DE DIF MEDIANTE SCORE TEST UNIVARIADO (1 GL POR CONTRASTE) Y BONFERRONI:
   - ALCANCE DE DIF: Si el investigador solicita evaluar DIF solo para una covariable especifica (ej. solo GENERO) o sobre un subconjunto de items (ej. solo items de Liderazgo), restringe 'grid_dif' EXCLUSIVAMENTE a esa covariable y esos items solicitados (no evalues covariables ajenas si se pidio una sola). Si no hay restriccion, evalua todas las covariables exogenas sobre los indicadores del modelo:
   - Evalua cada sendero directo item ~ covariable de forma iterativa:
     grid_dif <- expand.grid(item = indicadores_observados, pred = covariables_exogenas, stringsAsFactors = FALSE)
     res_dif <- data.frame()
     for (k in 1:nrow(grid_dif)) {
       p_syn <- paste0(grid_dif`$item[k], " ~ ", grid_dif`$pred[k])
       st <- suppressWarnings(lavTestScore(fit, add = p_syn, epc = TRUE))
       res_dif <- rbind(res_dif, st`$uni)
     }
     tabla_dif <- res_dif
     tabla_dif`$p_adj <- p.adjust(tabla_dif`$p.value, method = 'bonferroni')
     tabla_dif`$DIF_Bonferroni <- tabla_dif`$p_adj < 0.05
     print(tabla_dif[order(-tabla_dif`$X2), c("lhs", "op", "rhs", "X2", "df", "p.value", "epc", "p_adj", "DIF_Bonferroni")])
   - PROHIBICION CRITICA SOBRE LAVTESTSCORE: lavTestScore() devuelve una lista con componentes `$test, `$uni y `$epc. NO tiene propiedad `$pvalue ni `$p.value en la raiz (retornan NULL y provocan 'replacement has length zero'). Es OBLIGATORIO usar el patron canonico de arriba acumulando st`$uni en res_dif (la columna se llama p.value), o bien acceder a st`$test`$p.value. Queda TERMINANTEMENTE PROHIBIDO escribir st`$pvalue.
   - PROHIBICION: Prohibido concatenar multiples senderos en una sola llamada de lavTestScore; se evalua estrictamente sendero por sendero en el bucle for.
"@
    }

    "SEM_NoRecursivo" {
        $blockArchetype = @"

ARQUETIPO CANONICO: MODELOS NO RECURSIVOS (RETROALIMENTACION RECIPROCA)
Modelado de ecuaciones estructurales con bucles o feedback loops entre factores.

DIRECTIVAS ESPECIFICAS:
1. REGLA UNIVERSAL DE SENDEROS DIRECCIONALES EN LAVAAN:
   - Todo sendero estructural direccional 'Origen -> Destino' se traduce en lavaan con el operador '~'.
   - El DESTINO se ubica obligatoriamente a la IZQUIERDA y el ORIGEN a la DERECHA:
     Destino ~ Origen
   - Si multiples origenes inciden sobre el mismo destino:
     Destino ~ Origen1 + Origen2
   - PROHIBICION TAXATIVA: Queda TERMINANTEMENTE PROHIBIDO escribir flechas '->' dentro del modelo lavaan.

2. ESPECIFICACION DE BUCLES NO RECURSIVOS:
   - Formula ambas ecuaciones estructurales simultaneamente:
     B ~ A + ...
     A ~ B + ...
   - Identificacion formal (Bollen, 1989): cada variable endogena en el bucle debe contar con variables instrumentales exogenas exclusivas.
   - Covarianza residual: incluye 'A ~~ B' unicamente si se solicita expresamente permitir correlacion de perturbaciones residuales.
   - Funcion de estimacion obligatoria: sem(modelo, data = datos, ...).
   - PROHIBIDO usar lavaan() a secas.
   - PROHIBICION TAXATIVA DE MEDIACIONES: Queda TERMINANTEMENTE PROHIBIDO calcular efectos indirectos (operador :=) en este arquetipo, para evitar recursividad infinita. Limitate estricta y unicamente a las regresiones principales (~).

3. ENTREGABLES OBLIGATORIOS (DEBEN FIGURAR TODOS EN EL SCRIPT):
   - Reporte de todos los senderos estructurales directos:
     pe <- parameterEstimates(fit, standardized = TRUE)
     print(pe[pe`$op == "~", c("lhs", "op", "rhs", "est", "se", "z", "pvalue", "std.all")])
   - Ajuste global: print(summary(fit, fit.measures = TRUE, standardized = TRUE))
"@
    }

    "SEM_Senderos" {
        $blockArchetype = @"

ARQUETIPO CANONICO: SEM / SENDEROS CAUSALES Y MEDIACIONES
Modelos de Ecuaciones Estructurales con senderos direccionales, mediacion, efectos indirectos y totales.

DIRECTIVAS ESPECIFICAS:
1. REGLA UNIVERSAL DE SENDEROS DIRECCIONALES EN LAVAAN:
   - Todo sendero estructural direccional 'Origen -> Destino' se traduce en lavaan con el operador '~'.
   - El DESTINO se ubica obligatoriamente a la IZQUIERDA y el ORIGEN a la DERECHA:
     Destino ~ Origen
   - Si multiples origenes inciden sobre el mismo destino:
     Destino ~ Origen1 + Origen2
   - PROHIBICION TAXATIVA: Queda TERMINANTEMENTE PROHIBIDO escribir flechas '->' dentro del modelo lavaan, o invertir el orden de los terminos.
   - Funcion obligatoria: sem(modelo, data = datos, ...)

2. MEDIACIONES Y EFECTOS INDIRECTOS / TOTALES (OPERADOR ':='):
   - ETIQUETADO DE SENDEROS: Asigna etiquetas deterministas multiplicadoras a los predictores:
     M ~ a * X
     Y ~ b * M + c * X
   - DEFINICION DEL EFECTO: El operador ':=' se reserva EXCLUSIVAMENTE para computar productos o sumas de etiquetas:
     indirecto := a * b
     total := (a * b) + c
   - REGLA DEL EFECTO TOTAL: total = sendero directo de X hacia Y (SOLO si existe en el modelo) + efectos indirectos de X hacia Y. Sin sendero directo el total es IGUAL al efecto indirecto. PROHIBIDO sumar senderos hacia el mediador (ej. 'total := indirecto + a' es INCORRECTO). Si el usuario solo pidio la mediacion, no definas efecto total.
   - PROHIBICIONES TAXATIVAS:
     * Queda TERMINANTEMENTE PROHIBIDO escribir formulas de regresion a la derecha de ':=' (ej. 'ind := Y ~ X' es fatal).
     * PROHIBIDO usar '=' o '<-' dentro de la sintaxis del modelo lavaan.
   - REPORTE DE EFECTOS DEFINIDOS:
     pe <- parameterEstimates(fit, standardized = TRUE)
     if (any(pe`$op == ":=")) {
       print(pe[pe`$op == ":=", c("lhs", "op", "rhs", "est", "se", "z", "pvalue", "std.all")])
     }
   - Ajuste global: print(summary(fit, fit.measures = TRUE, standardized = TRUE))
"@
    }

    "ACP" {
        $blockArchetype = @"

ARQUETIPO CANONICO: ANALISIS DE COMPONENTES PRINCIPALES (ACP)
Reduccion de dimensionalidad mediante descomposicion en componentes principales con psych::principal().

DIRECTIVAS ESPECIFICAS:
1. FUNCION Y ESTIMACION:
   - Funcion obligatoria: psych::principal(datos[, items], nfactors = k, rotate = "rotacion", use = "pairwise", ...)
   - MANEJO OBLIGATORIO DE DATOS FALTANTES (NAs): En psych::principal() el argumento para datos con NAs es estrictamente 'use = "pairwise"'. Queda TERMINANTEMENTE PROHIBIDO usar 'cor = "pairwise"' o 'cor = "pairwise.complete.obs"', ya que el argumento 'cor' en psych define el metodo de matriz (ej. "cor", "poly") y provoca error fatal en R.
   - PROHIBICION TAXATIVA: Queda TERMINANTEMENTE PROHIBIDO utilizar la funcion fa() para ACP. El ACP exige de manera obligatoria la funcion principal() de psych.
   - DETERMINACION DE COMPONENTES: Si no se especifica el numero de componentes k, calculalo dinamicamente segun el Criterio de Kaiser (autovalores > 1):
     k <- sum(eigen(cor(datos[, items], use = "pairwise.complete.obs"))`$values > 1)
   - REPORTE DE CARGAS: En psych, imprime directamente print(acp_res). PROHIBIDO usar summary(), ya que en psych summary() omite la tabla de cargas y devuelve NULL.
   - Reporte de autovalores y varianza explicada: print(acp_res`$values); print(acp_res`$Vaccounted).
"@
    }

    "AFE" {
        $blockArchetype = @"

ARQUETIPO CANONICO: ANALISIS FACTORIAL EXPLORATORIO (AFE)
Extraccion de factores comunes latentes y rotacion factorial con psych::fa().

DIRECTIVAS ESPECIFICAS:
1. FUNCION Y ESTIMACION:
   - Librerias: Cargar library(readxl), library(psych) y library(GPArotation) (esta ultima para soporte nativo de rotaciones oblicuas sin avisos diferidos de namespace).
   - Funcion obligatoria: psych::fa(datos[, items], nfactors = k, fm = "minres", rotate = "oblimin", use = "pairwise", ...)
   - MANEJO OBLIGATORIO DE DATOS FALTANTES (NAs): En psych::fa() el argumento para datos con NAs es estrictamente 'use = "pairwise"'. Queda TERMINANTEMENTE PROHIBIDO usar 'cor = "pairwise"' o 'cor = "pairwise.complete.obs"'.
   - PROHIBICION TAXATIVA: Queda TERMINANTEMENTE PROHIBIDO usar principal() para AFE.
   - DETERMINACION DE FACTORES: Si no se especifica k, calculalo con el Criterio de Kaiser (autovalores > 1):
     k <- sum(eigen(cor(datos[, items], use = "pairwise.complete.obs"))`$values > 1)
   - REPORTE DE CARGAS Y COMUNALIDADES: Imprime directamente print(afe_res). PROHIBIDO usar summary() (devuelve NULL en psych).
   - Reporte de comunalidades y varianzas: print(afe_res`$communality); print(afe_res`$Vaccounted).
   - Si la rotacion es oblicua, imprime la matriz de correlacion entre factores: if (!is.null(afe_res`$Phi)) print(afe_res`$Phi).
"@
    }

    "Regresion_Logistica" {
        $blockArchetype = @"

ARQUETIPO CANONICO: REGRESION LOGISTICA (BINARIA U ORDINAL)
Modelos de regresion logistica para variables dependientes discretas.

DIRECTIVAS ESPECIFICAS:
1. SELECCION DE FUNCION SEGUN NIVELES DE LA DEPENDIENTE:
   - Si la variable dependiente es BINARIA (2 categorias, ej. 0/1):
     * Funcion obligatoria: glm(formula, data = datos, family = binomial, na.action = na.omit)
     * Si la dependiente binaria NO esta codificada 0/1 (ej. 1/2), convertila antes con datos`$y <- factor(datos`$y); con una variable numerica 1/2 glm falla ("y values must be 0 <= y <= 1").
     * PROHIBICION TAXATIVA: Queda TERMINANTEMENTE PROHIBIDO usar polr() cuando la dependiente tiene solo 2 categorias (provoca error fatal 'response must have 3 or more levels').
   - Si la variable dependiente es ORDINAL / POLITOMICA (3 o mas categorias):
     * Convierte previamente la variable a factor ordenado: datos`$y <- factor(datos`$y, ordered = TRUE)
     * Funcion obligatoria: MASS::polr(formula, data = datos, method = "logistic", Hess = TRUE)

2. ENTREGABLES OBLIGATORIOS:
   - Odds Ratios (OR) con coeficientes:
     print(exp(coef(fit)))
   - Errores estandar y p-valores explicitos:
     * Si usas glm() binaria: summary(fit) ya reporta coeficientes, errores estandar, estadisticos z y p-valores (Pr(>|z|)). Usa simplemente print(summary(fit)) seguido de print(exp(coef(fit))).
     * Si usas MASS::polr() ordinal: polr no reporta p-valores de forma nativa. Extraelos con:
       ctable <- coef(summary(fit))
       p_val <- 2 * (1 - pnorm(abs(ctable[, "t value"])))
       or_pred <- ifelse(rownames(ctable) %in% names(coef(fit)), round(exp(ctable[, "Value"]), 4), NA)  # ATENCION: En polr() la columna es "Value" (o [, 1]), NUNCA "Estimate"
       print(cbind(ctable, "p value" = round(p_val, 4), "OR" = or_pred))
"@
    }

    "Regresion_Probit" {
        $blockArchetype = @"

ARQUETIPO CANONICO: REGRESION PROBIT (BINARIA U ORDINAL)
Modelos de regresion probit con distribucion acumulada normal.

DIRECTIVAS ESPECIFICAS:
1. SELECCION DE FUNCION SEGUN NIVELES DE LA DEPENDIENTE:
   - Si la dependiente es BINARIA (2 categorias):
     * Funcion obligatoria: glm(formula, data = datos, family = binomial(link = "probit"), na.action = na.omit)
     * Si la dependiente binaria NO esta codificada 0/1 (ej. 1/2), convertila antes con datos`$y <- factor(datos`$y); con una variable numerica 1/2 glm falla ("y values must be 0 <= y <= 1").
     * PROHIBICION TAXATIVA: Queda TERMINANTEMENTE PROHIBIDO usar polr() para dependientes binarias.
   - Si la dependiente es ORDINAL / POLITOMICA (3 o mas categorias):
     * Convierte previamente la variable a factor ordenado: datos`$y <- factor(datos`$y, ordered = TRUE)
     * Funcion obligatoria: MASS::polr(formula, data = datos, method = "probit", Hess = TRUE)

2. ENTREGABLES OBLIGATORIOS:
   - Coeficientes probit, errores estandar y p-valores explicitos:
     * Si usas glm(): print(summary(fit)) ya reporta z y p-valores.
     * Si usas MASS::polr():
       ctable <- coef(summary(fit))
       p_val <- 2 * (1 - pnorm(abs(ctable[, "t value"])))
       print(cbind(ctable, "p value" = round(p_val, 4)))
"@
    }

    default {
        $blockArchetype = @"

ARQUETIPO CANONICO: MODELADO PSICOMETRICO GENERAL
Estima el modelo solicitado utilizando la funcion canonica correspondiente (cfa, sem, principal, fa, glm o polr) respetando las restricciones de datos.
"@
    }
}

# MIMIC: el DIF (Score Test + Bonferroni) solo se incluye si la consigna lo pide.
$difRequested = $true
if ($activeArchetype -eq "MIMIC") {
    $goalAsksDif = ((Remove-Diacritics $rawUserGoal.ToLower()) -match '(?i)\b(?:dif|diff|funcionamiento\s+diferencial|score\s+test|sesgo|invarianz\w*|invarianc\w*|invariance|multigrupo|multi-group|multigroup|configural|escalar|equivalencia\s+(?:de\s+medida|factorial))\b')
    $contractAsksDif = ($contractObj -and $contractObj.Modelado -and ($contractObj.Modelado.PSObject.Properties.Name -contains 'DIFSolicitado') -and [bool]$contractObj.Modelado.DIFSolicitado)
    $difRequested = ($goalAsksDif -or $contractAsksDif)
    if (-not $difRequested) {
        $blockArchetype = [regex]::Replace($blockArchetype, '(?s)\r?\n2\. EVALUACION DE DIF MEDIANTE.*$', '')
        $blockArchetype += "
2. NO se solicito DIF: reporta unicamente el modelo MIMIC (ajuste, cargas y regresiones de los factores sobre las covariables). PROHIBIDO ejecutar lavTestScore() o evaluar DIF.
"
    }
}

# 3. Bloque de Cierre y Presentacion Universal
$blockClosing = @"

PRESENTACION DE RESULTADOS Y PROHIBICIONES FINALES:
- Envuelve obligatoriamente las impresiones clave en print(...) o cat(...) para asegurar salida en ejecucion no interactiva.
- PROHIBIDO sink().
- PROHIBIDO tryCatch() innecesarios o wrappers defensivos que oculten errores.
- PROHIBIDO comentarios de relleno o texto decorativo ficticio.
- FORMATO DE SALIDA: Devuelve EXCLUSIVAMENTE UN UNICO bloque de codigo R completo entre ${fence}r y ${fence}, sin fragmentos parciales, sin texto previo ni posterior, sin explicaciones ni monologos internos. Todo el script ejecutable debe estar en ese unico bloque.
"@

# Ensamblar directivas nucleares (estrictamente modulares: Base + Arquetipo Activo + Cierre)
$coreDirectives = $blockBase + $blockArchetype + $blockClosing

# Inyectar directiva de invarianza MIMIC si aplica
$invarianceDirective = ""
$postGoalInvariance = ""
if ($activeArchetype -eq "MIMIC" -and $difRequested) {
    $invarianceDirective = @"

[DIRECTIVA METODOLOGICA OFICIAL DE INVARIANZA EN CHARLY]:
La evaluacion de Invarianza de Medicion y Funcionamiento Diferencial del Item (DIF) se realiza EXCLUSIVAMENTE mediante MODELO ESTRUCTURAL MIMIC (Muthen, 1989).
Queda TERMINANTEMENTE PROHIBIDO utilizar 'group = ...' o ajustar sucesivos modelos configural/metrico/escalar.
Estima el modelo base con sem() (Factores ~ Covariable) y evalua DIF item por item con Score Test univariado (1 gl) aplicando correccion de Bonferroni.
"@

    $postGoalInvariance = @"

================================================================================
RECORDATORIO METODOLOGICO DE INVARIANZA (MIMIC, MUTHEN 1989):
================================================================================
1. PROHIBIDO modelos sucesivos configural/metric/scalar o 'group = ...'.
2. Modelo base MIMIC: Factores latentes regresan sobre covariables exogenas.
3. Evaluar DIF reactivo por reactivo a 1 gl mediante lavTestScore(fit, add = p_syn, epc = TRUE) con Bonferroni.
4. lavTestScore() retorna lista (`$test, `$uni, `$epc). PROHIBIDO st`$pvalue (usar st`$uni o st`$test`$p.value).
================================================================================
"@
}

# Inyectar directiva de senderos si aplica
$semPathsDirective = ""
if ($activeArchetype -eq "SEM_Senderos" -and $contractObj -and $contractObj.Modelado -and $contractObj.Modelado.SintaxisLavaan) {
    $semPathsDirective = @"

[DIRECTIVA OBLIGATORIA DE SENDEROS ESTRUCTURALES Y MEDIACIONES]:
Dentro de la definicion del modelo en lavaan, debes copiar e incluir DE FORMA EXACTA Y LITERAL las siguientes formulas estructurales con sus etiquetas deterministas:
$($contractObj.Modelado.SintaxisLavaan.Trim())
Queda TERMINANTEMENTE PROHIBIDO modificar estas etiquetas, omitir los multiplicadores '*' en las regresiones '~', o inventar otras como 'a' o 'b'.
"@
} elseif ($activeArchetype -in @("SEM_Senderos", "MIMIC")) {
    $arrowDirectivesBuilder = @()
    if (Get-Command Get-ArrowDirectives -ErrorAction SilentlyContinue) {
        $arrowDirectivesBuilder = @(Get-ArrowDirectives -UserPrompt $rawUserGoal)
    }
    if ($arrowDirectivesBuilder.Count -gt 0) {
        $pathLines = @()
        foreach ($ad in $arrowDirectivesBuilder) {
            $origsStr = ($ad.Origenes -join " + ")
            $pathLines += "  $($ad.Destino) ~ $origsStr"
        }
        $semPathsDirective = @"

[DIRECTIVA OBLIGATORIA DE SENDEROS ESTRUCTURALES CONFIRMADOS]:
Dentro de la definicion del modelo en lavaan, debes incluir DE FORMA EXACTA Y OBLIGATORIA las siguientes formulas (Destino ~ Origen):
$($pathLines -join "`r`n")
Queda TERMINANTEMENTE PROHIBIDO invertir el orden o escribir flechas '->'.
"@
    }
}

# Generar e inyectar Contrato Psicométrico vinculante
$contractBlock = ""
if ($contractObj -and (Get-Command Generate-ContractPromptDirectives -ErrorAction SilentlyContinue)) {
    try {
        $contractBlock = "`r`n" + (Generate-ContractPromptDirectives -Contract $contractObj) + "`r`n"
        Set-Content (Join-Path $baseDir "workspace/contract_prompt_block.txt") $contractBlock -Encoding UTF8
    } catch {}
}

# Ensamblar prompt completo
$fullPrompt = @"
Eres un investigador psicometrista y analista de datos en R.
Tu tarea es convertir la solicitud del investigador en un script de R LIMPIO, CONCISO, ELEGANTE Y 100% HUMANO, exactamente como lo escribirias en RStudio.
PROHIBIDO incluir explicaciones, texto introductorio o monologos internos: devuelve UNICAMENTE el bloque de codigo R ejecutable entre ${fence}r y ${fence}.

$coreDirectives
$contractBlock
================================================================================
INFORMACION EMPIRICA DE LA BASE DE DATOS:
================================================================================
$dataBlock

================================================================================
SOLICITUD DEL INVESTIGADOR:$invarianceDirective$semPathsDirective
================================================================================
$UserGoal$postGoalInvariance
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outFile, $fullPrompt, $utf8NoBom)

# Guardar bloque de reglas para bucle de reparacion
$rulesBlockFile = Join-Path $baseDir "workspace/rules_prompt_block.txt"
[System.IO.File]::WriteAllText($rulesBlockFile, $coreDirectives, $utf8NoBom)

$promptLength = (Get-Item $outFile).Length
$estimatedTokens = [Math]::Ceiling($promptLength / 3.5)
Write-Host "[PROMPT BUILDER] Prompt modular por arquetipo generado con exito en $outFile" -ForegroundColor Green
Write-Host "[PROMPT BUILDER] Tamano: $promptLength bytes (~$estimatedTokens tokens estimados)." -ForegroundColor Cyan
