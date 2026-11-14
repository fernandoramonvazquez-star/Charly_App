# ==============================================================================
# CHARLY v4.0 - GENERADOR DE INFORME DESCRIPTIVO Y RADIOGRAFIA DE DATOS
# ==============================================================================

suppressPackageStartupMessages({
  if (!requireNamespace("readxl", quietly = TRUE)) install.packages("readxl", repos = "https://cloud.r-project.org")
  library(readxl)
})

args_cmd <- commandArgs(trailingOnly = TRUE)
if (length(args_cmd) == 0) {
  stop("Uso: Rscript generate_descriptives_report.R <archivo_datos> <archivo_salida> [archivo_original]")
}

data_path <- args_cmd[1]
out_report <- if (length(args_cmd) > 1) args_cmd[2] else "workspace/descriptivos_base.txt"
orig_name  <- if (length(args_cmd) > 2) args_cmd[3] else basename(data_path)

if (!file.exists(data_path)) {
  stop(sprintf("Error: El archivo '%s' no existe.", data_path))
}

clean_haven_df <- function(d) {
  d <- as.data.frame(d, check.names = FALSE, stringsAsFactors = FALSE)
  for (nm in names(d)) {
    if (inherits(d[[nm]], "haven_labelled")) {
      d[[nm]] <- as.vector(d[[nm]])
    }
  }
  d
}

# 1. Lectura del archivo
selected_sheet <- "N/A"
if (grepl("\\.xlsx?$|\\.xlsm$", data_path, ignore.case = TRUE)) {
  sheets <- excel_sheets(data_path)
  best_sheet <- sheets[1]
  best_cols <- 0
  for (s in sheets) {
    temp <- tryCatch(read_excel(data_path, sheet = s, n_max = 2), error = function(e) NULL)
    if (!is.null(temp) && ncol(temp) > best_cols) {
      best_cols <- ncol(temp)
      best_sheet <- s
    }
  }
  selected_sheet <- best_sheet
  df <- as.data.frame(read_excel(data_path, sheet = selected_sheet))
} else if (grepl("\\.sav$", data_path, ignore.case = TRUE)) {
  if (!requireNamespace("haven", quietly = TRUE)) install.packages("haven", repos = "https://cloud.r-project.org")
  df <- clean_haven_df(haven::read_sav(data_path))
} else if (grepl("\\.dta$", data_path, ignore.case = TRUE)) {
  if (!requireNamespace("haven", quietly = TRUE)) install.packages("haven", repos = "https://cloud.r-project.org")
  df <- clean_haven_df(haven::read_dta(data_path))
} else if (grepl("\\.rds$", data_path, ignore.case = TRUE)) {
  df <- clean_haven_df(readRDS(data_path))
} else {
  df <- as.data.frame(read.csv(data_path, stringsAsFactors = FALSE))
}

n_rows <- nrow(df)
n_cols <- ncol(df)

lines <- c()
add <- function(...) { lines <<- c(lines, sprintf(...)) }

add("================================================================================")
add("             CHARLY v4.0 - RADIOGRAFIA DESCRIPTIVA DE LA BASE DE DATOS          ")
add("================================================================================")
add("Archivo analizado : %s", orig_name)
add("Ruta completa     : %s", normalizePath(data_path))
if (selected_sheet != "N/A") {
  add("Hoja seleccionada : %s", selected_sheet)
}
add("Total casos (N)   : %d filas", n_rows)
add("Total variables   : %d columnas", n_cols)
add("Fecha y hora      : %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
add("================================================================================")
add("")
add("--------------------------------------------------------------------------------")
add(" DETALLE VARIABLE POR VARIABLE (FRECUENCIAS, RANGOS Y FALTANTES)")
add("--------------------------------------------------------------------------------")

alertas_aislados <- c()
alertas_codigos_7 <- c()

for (i in 1:n_cols) {
  col_name <- colnames(df)[i]
  col_vals <- df[[i]]
  n_na <- sum(is.na(col_vals))
  pct_na <- round((n_na / n_rows) * 100, 2)
  valid_vals <- col_vals[!is.na(col_vals)]
  n_valid <- length(valid_vals)
  
  u_vals <- sort(unique(valid_vals))
  n_u <- length(u_vals)
  is_num <- is.numeric(valid_vals)
  
  # Clasificar como categórica / ordinal si tiene 12 o menos valores únicos
  es_categorica <- (n_u <= 12) || !is_num
  
  tipo_label <- if (!is_num) "Texto / Categórica" else if (es_categorica) "Numérica Categórica / Likert" else "Numérica Continua"
  
  add("")
  add("[%02d] %s", i, col_name)
  add("     Tipo: %s | N válidos: %d | NAs: %d (%.2f%%)", tipo_label, n_valid, n_na, pct_na)
  
  if (n_valid == 0) {
    add("     [AVISO: Columna completamente vacía (100%% NAs)]")
    next
  }
  
  if (es_categorica) {
    add("     Valores únicos (%d): %s", n_u, paste(u_vals, collapse = ", "))
    add("     DISTRIBUCION DE FRECUENCIAS:")
    tbl <- table(valid_vals)
    for (val_name in names(tbl)) {
      freq <- as.numeric(tbl[val_name])
      pct <- (freq / n_valid) * 100
      nota_aislado <- ""
      if (freq <= 2) {
        nota_aislado <- "  <-- [⚠️ ATENCIÓN: CATEGORÍA AISLADA (<= 2 casos)]"
        alertas_aislados <- c(alertas_aislados, sprintf("Variable '%s': valor '%s' con solo %d caso(s)", col_name, val_name, freq))
      }
      add("       * %-6s : %4d casos (%5.2f%%)%s", val_name, freq, pct, nota_aislado)
    }
  } else {
    v_min <- min(valid_vals)
    v_max <- max(valid_vals)
    v_mean <- mean(valid_vals)
    v_sd <- sd(valid_vals)
    v_med <- median(valid_vals)
    add("     Rango  : [%.2f a %.2f] | Valores únicos: %d", v_min, v_max, n_u)
    add("     Media  : %.2f | Desvío Estándar: %.2f | Mediana: %.2f", v_mean, v_sd, v_med)
  }
  
  # Detección de códigos atípicos o sospechosos en variables ordinales o discretas
  if (is_num && any(valid_vals %in% c(7, 8, 9, 99, 999))) {
    cods_detectados <- intersect(c(7, 8, 9, 99, 999), valid_vals)
    for (cd in cods_detectados) {
      cnt <- sum(valid_vals == cd)
      # Solo alertar si parece código suelto fuera del rango común 1..5 o 1..6
      if (cd %in% c(7, 8, 99, 999) && (n_u <= 8)) {
        alertas_codigos_7 <- c(alertas_codigos_7, sprintf("Variable '%s': valor '%s' presente en %d caso(s) (posible código de faltante o 'No sabe/No contesta')", col_name, cd, cnt))
      }
    }
  }
}

add("")
add("================================================================================")
add(" RESUMEN DE ALERTAS Y DETECCIONES AUTOMATICAS DE CALIDAD DE DATOS")
add("================================================================================")

if (length(alertas_aislados) > 0) {
  add("")
  add(" [!] CATEGORÍAS CON CASOS RAROS O AISLADOS (<= 2 observaciones):")
  for (al in alertas_aislados) {
    add("     - %s", al)
  }
} else {
  add("")
  add(" [OK] No se detectaron categorías con casos aislados raros.")
}

if (length(alertas_codigos_7) > 0) {
  add("")
  add(" [?] POSIBLES CODIGOS DE 'NO SABE/NO CONTESTA' O FALTANTES (7, 8, 99, etc.):")
  for (c7 in unique(alertas_codigos_7)) {
    add("     - %s", c7)
  }
  add("     (Tip: Recuerda indicar en tu instrucción si deseas que estos números se tomen como NAs).")
}

add("")
add("================================================================================")
add(" FIN DE LA RADIOGRAFIA DESCRIPTIVA - LISTO PARA MODELAR EN CHARLY")
add("================================================================================")

con_rep <- file(out_report, "w", encoding = "UTF-8")
writeLines(lines, con_rep)
close(con_rep)
cat(sprintf("[DESCRIPTIVOS] Informe generado exitosamente en: %s\n", out_report))
