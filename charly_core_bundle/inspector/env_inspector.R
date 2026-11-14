# ==============================================================================
# CHARLY v4.0 - PILAR 2: INTROSPECCIÓN DINÁMICA DEL ENTORNO DE R
# ==============================================================================
# Inspecciona las librerías locales, sus versiones y las firmas reales
# de las funciones clave para proveer restricciones formales al LLM.
# ==============================================================================

suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) install.packages("jsonlite", repos = "https://cloud.r-project.org")
  library(jsonlite)
})

cat("[INSPECTOR] Inspeccionando entorno R y librerías psicométricas...\n")

r_version <- paste(R.version$major, R.version$minor, sep = ".")
pkgs <- c("lavaan", "semTools", "psych", "GPArotation", "MASS", "readxl", "haven")
pkg_versions <- list()

for (p in pkgs) {
  if (requireNamespace(p, quietly = TRUE)) {
    pkg_versions[[p]] <- as.character(packageVersion(p))
  } else {
    pkg_versions[[p]] <- "NO_INSTALADA"
  }
}

# Firmas de funciones clave
signatures <- list()
if (pkg_versions[["semTools"]] != "NO_INSTALADA") {
  signatures$htmt <- paste(deparse(args(semTools::htmt)), collapse = " ")
}
if (pkg_versions[["lavaan"]] != "NO_INSTALADA") {
  signatures$cfa <- paste(deparse(args(lavaan::cfa)), collapse = " ")
  signatures$sem <- paste(deparse(args(lavaan::sem)), collapse = " ")
  signatures$fitMeasures <- paste(deparse(args(lavaan::fitMeasures)), collapse = " ")
  signatures$standardizedSolution <- paste(deparse(args(lavaan::standardizedSolution)), collapse = " ")
  signatures$parameterEstimates <- paste(deparse(args(lavaan::parameterEstimates)), collapse = " ")
  signatures$lavInspect <- paste(deparse(args(lavaan::lavInspect)), collapse = " ")
  signatures$lavTestLRT <- paste(deparse(args(lavaan::lavTestLRT)), collapse = " ")
  signatures$lavTestScore <- paste(deparse(args(lavaan::lavTestScore)), collapse = " ")
}

env_info <- list(
  r_version = r_version,
  paquetes = pkg_versions,
  firmas = signatures
)

save_inspector_file <- function(fname, content_lines) {
  con <- file(fname, "w", encoding = "UTF-8")
  writeLines(content_lines, con)
  close(con)
  if (dir.exists("workspace")) {
    con_ws <- file(file.path("workspace", basename(fname)), "w", encoding = "UTF-8")
    writeLines(content_lines, con_ws)
    close(con_ws)
  }
}

json_env_str <- jsonlite::toJSON(env_info, pretty = TRUE, auto_unbox = TRUE)
save_inspector_file("r_env_specs.json", json_env_str)

# Bloque de prompt compacto de alta densidad para LLMs
prompt_lines <- c(
  sprintf("### ESPECIFICACIONES TECNICAS DEL ENTORNO R LOCAL (R %s):", r_version),
  sprintf("- Librerias en el sistema: lavaan %s | semTools %s | psych %s | GPArotation %s | MASS %s | readxl %s | haven %s",
          pkg_versions$lavaan, pkg_versions$semTools, pkg_versions$psych, pkg_versions$GPArotation, pkg_versions$MASS, pkg_versions$readxl, pkg_versions$haven),
  "- FUNCIONES CLAVE: cfa, sem, fitMeasures, parameterEstimates, lavInspect, standardizedSolution, lavTestScore, fa, principal.",
  "- NOTAS ESPECIFICAS Y TRAMPAS CRITICAS:",
  "  * psych: para AFE usar fa(); para Componentes Principales (PCA) usar obligatoriamente principal(), NUNCA fa(..., fm = 'pa').",
  "  * fitMeasures() devuelve vector atomico nombrado: indexar SIEMPRE con [[ ]] (fit_measures[['cfi.scaled']]), NUNCA '$'.",
  "  * lavInspect(fit, 'rsquare') devuelve vector atomico: imprimir directo con print(), NUNCA '$'.",
  "  * INVARIANZA Y DIF (MIMIC): evaluar estrictamente mediante Score Test univariado iterando cada sendero en un bucle for con lavTestScore(fit_base, add = p_syn, epc = TRUE). PROHIBIDO pasar multiples senderos concatenados a 'add' en una sola llamada.",
  "  * cor(): si variables son ordered, convertir con as.numeric() antes de pasar a cor()."
)

save_inspector_file("r_env_prompt_block.txt", prompt_lines)
cat("[INSPECTOR] Entorno verificado. Reglas de firma generadas en r_env_prompt_block.txt\n")
