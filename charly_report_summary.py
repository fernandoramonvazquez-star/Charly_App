#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""charly_report_summary.py - Resumen factual de la salida de R para el informe Word de Charly App.

Extrae SOLO datos presentes en la salida (N, estimador, indices de ajuste, parametros definidos ':=').
No interpreta ni inventa nada: si un dato no aparece en la salida, se omite.
"""

import re

_NUM = r"-?\d+(?:\.\d+)?"


def extract_effective_n(r_output: str):
    """N efectivo informado por lavaan ('Number of observations'); None si no figura."""
    m = re.search(r"Number of observations\s+(\d+)", r_output or "")
    return int(m.group(1)) if m else None


_CONSOLE_MARKER = re.compile(
    r"^(?:RESULTADOS Y REGISTRO DE SALIDA DE R|RESPUESTA TEXTUAL Y CRUDA DE LA CONSOLA DE R)[^\n]*\n={20,}[ \t]*\r?\n",
    re.MULTILINE,
)
_CODE_BLOCK_MARKER = re.compile(
    r"CODIGO FUENTE R EJECUTADO EN ESTE ANALISIS:[^\n]*\n={20,}[ \t]*\r?\n(.*?)\n={20,}[ \t]*\r?\n(?:RESULTADOS Y REGISTRO DE SALIDA DE R|RESPUESTA TEXTUAL Y CRUDA DE LA CONSOLA DE R)",
    re.DOTALL,
)
_CONTRACT_BANNER = re.compile(r"\A\s*!!! AVISO DE CONTRATO.*?\n={20,}[ \t]*\r?\n", re.DOTALL)


def extract_executed_r_code(console_text: str) -> str:
    """Extrae el codigo fuente R exacto ejecutado por el motor desde consola_rstudio_completa.txt.
    
    Garantiza consistencia absoluta entre los resultados estadisticos y el codigo documentado,
    incluso si el archivo en disco fue modificado accidentalmente o sobreescrito por el editor de RStudio.
    """
    text = console_text or ""
    m = _CODE_BLOCK_MARKER.search(text)
    if m:
        return m.group(1).strip()
    return ""


def extract_console_output(console_text: str) -> str:
    """Salida de R completa y sin filtrar tomada de consola_rstudio_completa.txt.

    El archivo trae una cabecera de Charly (script ejecutado, fecha, codigo fuente) seguida de la salida
    textual de R (stdout + stderr, con todos los avisos). Se devuelve SOLO esa salida de R, sin recortar nada
    de ella. Si el aviso del auditor de contrato figura al inicio del archivo, se conserva delante.
    Si no se reconoce la cabecera, se devuelve el archivo completo (nunca se descarta informacion).
    """
    text = console_text or ""
    banner = ""
    mb = _CONTRACT_BANNER.match(text)
    if mb:
        banner = mb.group(0).strip() + "\n\n"
    ms = list(_CONSOLE_MARKER.finditer(text))
    if not ms:
        return text.strip()
    return banner + text[ms[-1].end():].strip()


def _last_value(line_match):
    """Entre columnas 'Standard' y 'Scaled/Robust' se informa la ultima (la corregida) cuando existe."""
    vals = [v for v in line_match.groups() if v is not None]
    return vals[-1] if vals else None


def build_key_results_summary(r_output: str) -> str:
    text = r_output or ""
    paragraphs = []

    head = []
    n_eff = extract_effective_n(text)
    if n_eff is not None:
        head.append(f"Observaciones analizadas (N efectivo): {n_eff}.")
    m_est = re.search(r"^\s*Estimator\s+(\S+)", text, re.MULTILINE)
    if m_est:
        head.append(f"Estimador: {m_est.group(1)}.")
    if head:
        paragraphs.append(" ".join(head))

    fit = []
    for label, pattern in (
        ("CFI", rf"Comparative Fit Index \(CFI\)\s+({_NUM})(?:\s+({_NUM}))?"),
        ("TLI", rf"Tucker-Lewis Index \(TLI\)\s+({_NUM})(?:\s+({_NUM}))?"),
        ("RMSEA", rf"^\s*RMSEA\s+({_NUM})(?:\s+({_NUM}))?"),
        ("SRMR", rf"^\s*SRMR\s+({_NUM})(?:\s+({_NUM}))?"),
    ):
        m = re.search(pattern, text, re.MULTILINE)
        if m:
            fit.append(f"{label} = {_last_value(m)}")
    if fit:
        paragraphs.append("Indices de ajuste global: " + "; ".join(fit) + ".")

    # Bloque 'Defined Parameters' (efectos definidos con ':=')
    m_def = re.search(r"Defined Parameters:\s*\n(?:.*\n)?((?:[ \t]+\S.*\n?)+)", text)
    if m_def:
        rows = []
        for line in m_def.group(1).splitlines():
            tok = line.split()
            # nombre est se z pvalue [std.lv std.all]
            if len(tok) >= 5 and re.fullmatch(_NUM, tok[1]) and re.fullmatch(_NUM, tok[4]):
                rows.append(f"{tok[0]}: estimacion = {tok[1]}, EE = {tok[2]}, z = {tok[3]}, p = {tok[4]}")
        if rows:
            paragraphs.append("Efectos definidos (:=): " + " | ".join(rows) + ".")

    paragraphs.append(
        "Este resumen se extrajo automaticamente de la salida completa de la consola de R incluida en este informe; no incluye interpretacion. "
        "La interpretacion sustantiva y metodologica de los resultados debe ser realizada por el investigador."
    )
    return "\n\n".join(paragraphs)

