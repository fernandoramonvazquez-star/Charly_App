# ==============================================================================
# CHARLY v4.0 - PERFILADOR UNIVERSAL DE ESQUEMA DE DATOS (SIN REGLAS FIJAS)
# ==============================================================================
# Lee CUALQUIER archivo de datos (Excel, SPSS .sav, Stata .dta, R .rds o CSV),
# inspecciona sus columnas reales, tipos de datos y rangos, sin asumir ningún
# modelo psicométrico a priori.
# ==============================================================================

suppressPackageStartupMessages({
  if (!requireNamespace("readxl", quietly = TRUE)) install.packages("readxl", repos = "https://cloud.r-project.org")
  if (!requireNamespace("jsonlite", quietly = TRUE)) install.packages("jsonlite", repos = "https://cloud.r-project.org")
  library(readxl)
  library(jsonlite)
})

clean_haven_df <- function(d) {
  d <- as.data.frame(d, check.names = FALSE, stringsAsFactors = FALSE)
  for (nm in names(d)) {
    if (inherits(d[[nm]], "haven_labelled")) {
      d[[nm]] <- as.vector(d[[nm]])
    }
  }
  d
}

args_cmd <- commandArgs(trailingOnly = TRUE)
if (length(args_cmd) == 0 || args_cmd[1] == "") {
  stop("[PERFILADOR] Error: Debes especificar la ruta del archivo de datos a perfilar.")
}
data_path <- args_cmd[1]
if (!file.exists(data_path)) {
  stop(sprintf("[PERFILADOR] Error: El archivo '%s' no existe o no se puede acceder.", data_path))
}

original_name <- if (length(args_cmd) > 1) args_cmd[2] else data_path
goal_path     <- if (length(args_cmd) > 2) args_cmd[3] else "workspace/user_goal.txt"

cat(sprintf("[PERFILADOR EMPIRICO] Leyendo archivo: %s\n", normalizePath(data_path)))
read_target <- data_path

selected_sheet <- NULL
if (grepl("\\.xlsx?$|\\.xlsm$", data_path, ignore.case = TRUE)) {
  sheets <- tryCatch(
    excel_sheets(read_target),
    error = function(e) {
      if (!is.null(original_name) && file.exists(original_name)) {
        cat(sprintf("[PERFILADOR] Aviso: Reintentando lectura con archivo original '%s'...\n", original_name))
        read_target <<- original_name
        excel_sheets(original_name)
      } else {
        stop(e)
      }
    }
  )
  
  # Seleccionar la hoja con mayor cantidad de datos
  best_sheet <- sheets[1]
  best_cols <- 0
  for (s in sheets) {
    temp <- tryCatch(read_excel(read_target, sheet = s, n_max = 2), error = function(e) NULL)
    if (!is.null(temp) && ncol(temp) > best_cols) {
      best_cols <- ncol(temp)
      best_sheet <- s
    }
  }
  selected_sheet <- best_sheet
  cat(sprintf("[PERFILADOR EMPIRICO] Hoja seleccionada: '%s' (%d hojas disponibles: %s)\n", 
              selected_sheet, length(sheets), paste(sheets, collapse = ", ")))
  df <- tryCatch(
    as.data.frame(read_excel(read_target, sheet = selected_sheet)),
    error = function(e) {
      if (!is.null(original_name) && file.exists(original_name)) {
        as.data.frame(read_excel(original_name, sheet = selected_sheet))
      } else {
        stop(e)
      }
    }
  )
} else if (grepl("\\.sav$", data_path, ignore.case = TRUE)) {
  if (!requireNamespace("haven", quietly = TRUE)) install.packages("haven", repos = "https://cloud.r-project.org")
  df <- tryCatch(
    clean_haven_df(haven::read_sav(read_target)),
    error = function(e) {
      if (!is.null(original_name) && file.exists(original_name)) {
        clean_haven_df(haven::read_sav(original_name))
      } else {
        stop(e)
      }
    }
  )
} else if (grepl("\\.dta$", data_path, ignore.case = TRUE)) {
  if (!requireNamespace("haven", quietly = TRUE)) install.packages("haven", repos = "https://cloud.r-project.org")
  df <- tryCatch(
    clean_haven_df(haven::read_dta(read_target)),
    error = function(e) {
      if (!is.null(original_name) && file.exists(original_name)) {
        clean_haven_df(haven::read_dta(original_name))
      } else {
        stop(e)
      }
    }
  )
} else if (grepl("\\.rds$", data_path, ignore.case = TRUE)) {
  df <- tryCatch(
    clean_haven_df(readRDS(read_target)),
    error = function(e) {
      if (!is.null(original_name) && file.exists(original_name)) {
        clean_haven_df(readRDS(original_name))
      } else {
        stop(e)
      }
    }
  )
} else {
  df <- as.data.frame(read.csv(data_path, stringsAsFactors = FALSE))
}

n_obs <- nrow(df)
n_cols <- ncol(df)

# Lectura de la instruccion del usuario para aislar variables solicitadas
goal_text <- ""
if (!is.null(goal_path) && file.exists(goal_path)) {
  goal_text <- paste(readLines(goal_path, warn = FALSE), collapse = " ")
}

clean_str <- function(s) {
  s <- gsub("[áÁ]", "a", s)
  s <- gsub("[éÉ]", "e", s)
  s <- gsub("[íÍ]", "i", s)
  s <- gsub("[óÓ]", "o", s)
  s <- gsub("[úÚ]", "u", s)
  s
}

clean_user <- clean_str(goal_text)

# Expansion de rangos sintacticos de variables observadas (ej. I2 a I49, I2 hasta la I49, desde I2 hasta I49)
range_pat <- "(?i)(?:desde\\s+(?:la\\s+|el\\s+)?(?:variable|columna|item)?\\s*(?:o\\s+(?:variable|columna|item)\\s*)?)?\\b([a-zA-Z_]+)([0-9]+)\\s*(?:hasta\\s+(?:la\\s+|el\\s+)?|a\\s+(?:la\\s+|el\\s+)?|al\\s+|to\\s+|-|\\.\\.)\\s*(?:(?:la\\s+|el\\s+)?(?:variable|columna|item)\\s*)?([a-zA-Z_]+)?([0-9]+)\\b"
range_matches <- gregexpr(range_pat, clean_user, perl = TRUE)
expanded_range_names <- c()
range_slice_indices <- c()

if (range_matches[[1]][1] != -1) {
  reg_matches_text <- regmatches(clean_user, range_matches)[[1]]
  for (m in reg_matches_text) {
    parts <- regmatches(m, regexec(range_pat, m, perl = TRUE))[[1]]
    if (length(parts) >= 5) {
      prefix1 <- parts[2]
      num1 <- as.integer(parts[3])
      prefix2 <- if (nchar(parts[4]) > 0) parts[4] else prefix1
      num2 <- as.integer(parts[5])
      if (tolower(prefix1) == tolower(prefix2) && !is.na(num1) && !is.na(num2) && num1 <= num2) {
        # 1. Expandir nombres numericos
        if ((num2 - num1) <= 200) {
          for (k in num1:num2) {
            expanded_range_names <- c(expanded_range_names, paste0(prefix1, k))
          }
        }
        # 2. Rebanada posicional directa si ambos extremos existen en las columnas del archivo
        name1 <- paste0(prefix1, num1)
        name2 <- paste0(prefix2, num2)
        idx1 <- which(tolower(colnames(df)) == tolower(name1))
        idx2 <- which(tolower(colnames(df)) == tolower(name2))
        if (length(idx1) > 0 && length(idx2) > 0 && idx1[1] <= idx2[1]) {
          range_slice_indices <- c(range_slice_indices, idx1[1]:idx2[1])
        }
      }
    }
  }
}

matched_indices <- c()
for (i in 1:n_cols) {
  c_name <- colnames(df)[i]
  # Excluir columnas fantasmas de Excel o columnas completamente vacias
  if (grepl("^\\.\\.\\.[0-9]+$", c_name)) next
  if (all(is.na(df[[i]]))) next
  
  c_clean <- clean_str(c_name)
  c_clean_escaped <- gsub("([.\\^$*+?()[{\\\\|\\]])", "\\\\\\1", c_clean)
  c_flexible <- gsub("_+", "[ _]+", c_clean_escaped)
  pat <- if (grepl("^[a-zA-Z]{4,}$", c_clean)) {
    sprintf("(?i)\\b%s[a-zA-Z]*\\b", c_flexible)
  } else {
    sprintf("(?i)\\b%s\\b", c_flexible)
  }
  if (i %in% range_slice_indices || any(tolower(c_name) == tolower(expanded_range_names)) || grepl(pat, clean_user, perl = TRUE)) {
    matched_indices <- c(matched_indices, i)
  }
}

is_all_explicit <- grepl("(?i)\\b(?:todas?\\s+(?:las?\\s+)?(?:variables?|items?|columnas?)|toda\\s+la\\s+base)\\b", clean_user)
if (is_all_explicit) {
  matched_indices <- c()
}

if (length(matched_indices) > 0) {
  target_indices <- matched_indices
  is_subset <- TRUE
  cat(sprintf("\n[PERFILADOR FOCALIZADO] Variables identificadas para el modelo (%d de %d en el archivo):\n", 
              length(target_indices), n_cols))
  cat(sprintf("  >> Variables: %s\n", paste(colnames(df)[target_indices], collapse = ", ")))
  cat(sprintf("  >> Omitiendo %d columnas residuales o vacias (reduce prompt en ~60%% y evita ruido en LLM).\n\n",
              n_cols - length(target_indices)))
} else {
  # Modo general: perfila todas las variables con datos reales
  target_indices <- which(!grepl("^\\.\\.\\.[0-9]+$", colnames(df)) & sapply(df, function(x) !all(is.na(x))))
  is_subset <- FALSE
  cat(sprintf("\n[PERFILADOR UNIVERSAL] Instruccion general: analizando %d variables validas de la base.\n\n", 
              length(target_indices)))
}

col_profiles <- list()
prompt_col_lines <- c()

cat("--------------------------------------------------------------------------------\n")
cat(sprintf("%-16s | %-10s | %-6s | %-26s | %s\n", "VARIABLE", "TIPO", "NAs", "RANGO / VALORES", "MEDIA (DE)"))
cat("--------------------------------------------------------------------------------\n")

for (i in target_indices) {
  c_name <- colnames(df)[i]
  vals <- df[[i]]
  na_count <- sum(is.na(vals))
  clean_vals <- vals[!is.na(vals)]
  is_num <- is.numeric(vals)
  
  u_vals <- if(length(clean_vals) > 0) sort(unique(clean_vals)) else numeric(0)
  v_min <- if(length(u_vals) > 0) min(u_vals) else NA
  v_max <- if(length(u_vals) > 0) max(u_vals) else NA
  
  mean_sd_str <- if (is_num && length(clean_vals) > 1) {
    sprintf("%.2f (%.2f)", mean(clean_vals), sd(clean_vals))
  } else if (is_num && length(clean_vals) == 1) {
    sprintf("%.2f (N/A)", mean(clean_vals))
  } else {
    "Cat/Factor"
  }
  
  col_profiles[[c_name]] <- list(
    indice = i,
    nombre = c_name,
    tipo = class(vals)[1],
    n_validos = length(clean_vals),
    n_nas = na_count,
    min = v_min,
    max = v_max,
    media = if(is_num && length(clean_vals) > 0) mean(clean_vals) else NA,
    de = if(is_num && length(clean_vals) > 1) sd(clean_vals) else NA,
    n_unicos = length(u_vals),
    valores_detectados = head(u_vals, 7)
  )
  
  # Resumen compacto
  val_summary <- if (is_num && length(u_vals) <= 8) {
    sprintf("[%s]", paste(u_vals, collapse = ", "))
  } else if (is_num) {
    sprintf("[%s a %s] (k=%d)", v_min, v_max, length(u_vals))
  } else {
    sprintf("Factor (k=%d)", length(u_vals))
  }
  
  cat(sprintf("%-16s | %-10s | %-6d | %-26s | %s\n", 
              substr(c_name, 1, 16), substr(class(vals)[1], 1, 10), na_count, 
              substr(val_summary, 1, 26), mean_sd_str))
  
  prompt_col_lines <- c(prompt_col_lines, 
    sprintf("  - `%s` | Tipo: %s | %s | NAs: %d", 
            c_name, class(vals)[1], val_summary, na_count))
}
cat("--------------------------------------------------------------------------------\n")

profile_out <- list(
  timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
  archivo = basename(data_path),
  hoja = selected_sheet,
  n_filas = n_obs,
  n_columnas_total = n_cols,
  n_columnas_perfiladas = length(target_indices),
  modalidad_focalizada = is_subset,
  columnas = col_profiles
)

save_text_file <- function(fname, content_lines) {
  con <- file(fname, "w", encoding = "UTF-8")
  writeLines(content_lines, con)
  close(con)
  if (dir.exists("workspace")) {
    con_ws <- file(file.path("workspace", basename(fname)), "w", encoding = "UTF-8")
    writeLines(content_lines, con_ws)
    close(con_ws)
  }
}

json_str <- jsonlite::toJSON(profile_out, pretty = TRUE, auto_unbox = TRUE)
save_text_file("dataset_profile.json", json_str)

# Bloque de esquema empirico para el prompt
prompt_lines <- c(
  "### FICHA TECNICA DEL CONJUNTO DE DATOS (LEIDO DIRECTAMENTE DE LA BASE):",
  sprintf("- Archivo fuente: `%s` %s", basename(original_name), if(!is.null(selected_sheet)) sprintf("| Hoja: `%s`", selected_sheet) else ""),
  sprintf("- Ruta de carga en R: `%s`", gsub("\\\\", "/", data_path)),
  sprintf("- Total observaciones: N = %d filas", n_obs),
  sprintf("- Variables en archivo: %d columnas totales (%s: %d variables seleccionadas)", 
          n_cols, if(is_subset) "MODALIDAD FOCALIZADA EN MODELO" else "MODALIDAD COMPLETA", length(target_indices)),
  if (is_subset) {
    sprintf("- REGLA MAGNA DE AISLAMIENTO: El modelo requiere unicamente estas %d variables. NUNCA filtrar ni aplicar na.omit() globalmente a columnas ajenas de la base.", length(target_indices))
  } else {
    "- ESTRUCTURA DE COLUMNAS DISPONIBLES EN EL ARCHIVO:"
  },
  "- VARIABLES INVOLUCRADAS EN EL ANALISIS:",
  prompt_col_lines
)

save_text_file("dataset_prompt_block.txt", prompt_lines)
cat(sprintf("[PERFILADOR EMPIRICO] Perfilado completado: N = %d, %d variables analizadas.\n", n_obs, length(target_indices)))
