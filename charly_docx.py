#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""charly_docx.py — Generador de informes Word con formato APA para Charly App."""

import datetime
import re
from pathlib import Path
from docx import Document
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls, qn


def set_cell_border(cell, **kwargs):
    """Aplica bordes finos estilo APA a las celdas de una tabla Word."""
    tcPr = cell._tc.get_or_add_tcPr()
    tcBorders = parse_xml(
        f'<w:tcBorders {nsdecls("w")}>\n'
        f'<w:top w:val="{kwargs.get("top", "none")}" w:sz="{kwargs.get("top_sz", "4")}" w:space="0" w:color="{kwargs.get("top_color", "auto")}"/>\n'
        f'<w:left w:val="{kwargs.get("left", "none")}"/>\n'
        f'<w:bottom w:val="{kwargs.get("bottom", "none")}" w:sz="{kwargs.get("bottom_sz", "4")}" w:space="0" w:color="{kwargs.get("bottom_color", "auto")}"/>\n'
        f'<w:right w:val="{kwargs.get("right", "none")}"/>\n'
        f'</w:tcBorders>'
    )
    tcPr.append(tcBorders)


def create_word_report(analysis_title: str,
                       summary_text: str,
                       r_output: str,
                       r_code: str,
                       dataset_info: dict,
                       output_path: str,
                       r_warnings: str = "") -> str:
    doc = Document()

    # Margenes de 2.54 cm (1 pulgada, formato APA)
    sections = doc.sections
    for section in sections:
        section.top_margin = Inches(1.0)
        section.bottom_margin = Inches(1.0)
        section.left_margin = Inches(1.0)
        section.right_margin = Inches(1.0)

    # Encabezado institucional
    p_header = doc.add_paragraph()
    p_header.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    r_hdr = p_header.add_run("CHARLY v4 — SISTEMA PSICOMÉTRICO Y METODOLÓGICO")
    r_hdr.font.size = Pt(8.5)
    r_hdr.font.color.rgb = RGBColor(120, 120, 120)

    # Titulo Principal
    p_title = doc.add_paragraph()
    r_title = p_title.add_run(f"Informe de Resultados: {analysis_title}")
    r_title.bold = True
    r_title.font.size = Pt(18)
    r_title.font.color.rgb = RGBColor(24, 43, 73)

    # Metadatos del analisis
    p_meta = doc.add_paragraph()
    now_str = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
    p_meta.add_run(f"Fecha de ejecución: {now_str}\n").font.size = Pt(9.5)
    p_meta.add_run(f"Archivo fuente: {dataset_info.get('filename', 'N/D')}\n").font.size = Pt(9.5)
    p_meta.add_run(f"Muestra efectiva: N = {dataset_info.get('n_rows', 'N/D')} observaciones — Variables en la base: {dataset_info.get('n_cols', 'N/D')}\n").font.size = Pt(9.5)
    p_meta.add_run(f"Motor analítico: Entorno R local + Charly Dual Engine").font.size = Pt(9.5)

    # 1. Resumen de resultados principales
    sec_num = 1
    doc.add_heading(f"{sec_num}. Resumen de resultados principales", level=1)

    has_warnings = bool(r_warnings and r_warnings.strip())
    if has_warnings:
        p_alert = doc.add_paragraph()
        r_alert = p_alert.add_run("⚠️ Nota metodológica: El cálculo generó advertencias en el motor R durante la estimación (ver detalle en la Sección 2).")
        r_alert.bold = True
        r_alert.font.size = Pt(9.5)
        r_alert.font.color.rgb = RGBColor(190, 85, 0)
        p_alert.paragraph_format.space_after = Pt(4)

    # Texto interpretativo
    for par in summary_text.split("\n\n"):
        p = doc.add_paragraph(par.strip())
        p.paragraph_format.line_spacing = 1.15
        p.paragraph_format.space_after = Pt(6)

    # 2. Avisos y Advertencias de R (si existieron)
    if has_warnings:
        sec_num += 1
        doc.add_heading(f"{sec_num}. Avisos y Advertencias Emitidos por R", level=1)

        p_warn_desc = doc.add_paragraph()
        r_wdesc = p_warn_desc.add_run(
            "Atención metodológica: El motor R completó la estimación, pero emitió los siguientes avisos técnicos. "
            "Deben ser revisados antes de interpretar los resultados, ya que pueden comprometer la identificación, "
            "la convergencia o la validez psicométrica del modelo:"
        )
        r_wdesc.bold = True
        r_wdesc.font.size = Pt(9.5)
        r_wdesc.font.color.rgb = RGBColor(190, 85, 0)
        p_warn_desc.paragraph_format.space_after = Pt(4)

        p_warn_box = doc.add_paragraph()
        r_wbox = p_warn_box.add_run(r_warnings.strip())
        r_wbox.font.name = "Consolas"
        r_wbox.font.size = Pt(8.5)
        r_wbox.font.color.rgb = RGBColor(130, 40, 0)
        p_warn_box.paragraph_format.space_after = Pt(12)

    # Salida Completa de la Consola de R
    sec_num += 1
    doc.add_heading(f"{sec_num}. Salida Completa de la Consola de R", level=1)

    p_note = doc.add_paragraph()
    r_note = p_note.add_run(
        "Reproduccion textual y sin filtrar de lo que R emitio (salida estandar y mensajes de error/aviso). "
        "Los avisos y mensajes de R, si los hubo, figuran en este bloque tal como R los escribio "
        "(los mensajes de aviso/error se listan a continuacion de la salida estandar)."
    )
    r_note.italic = True
    r_note.font.size = Pt(9)
    r_note.font.color.rgb = RGBColor(90, 90, 90)

    # Bloque de salida de R
    p_out = doc.add_paragraph()
    r_run = p_out.add_run(r_output)
    r_run.font.name = "Consolas"
    r_run.font.size = Pt(8.5)
    p_out.paragraph_format.space_after = Pt(12)

    # Sintaxis Reproducible de R
    sec_num += 1
    doc.add_heading(f"{sec_num}. Sintaxis Reproducible de R", level=1)

    # Normalizacion de espaciado: maximo 1 linea en blanco entre bloques y 0 dentro de bloques
    clean_code = re.sub(r'(\r?\n\s*){3,}', '\n\n', r_code or '').strip()

    p_code = doc.add_paragraph()
    p_code.paragraph_format.line_spacing = 1.0
    p_code.paragraph_format.space_before = Pt(4)
    p_code.paragraph_format.space_after = Pt(8)
    r_crun = p_code.add_run(clean_code)
    r_crun.font.name = "Consolas"
    r_crun.font.size = Pt(8.5)

    # Pie de pagina
    p_footer = doc.add_paragraph()
    p_footer.paragraph_format.space_before = Pt(20)
    r_foot = p_footer.add_run("Resultados generados por Charly v4. Cálculos analizados con R local.")
    r_foot.font.size = Pt(8.5)
    r_foot.font.italic = True
    r_foot.font.color.rgb = RGBColor(140, 140, 140)

    doc.save(output_path)
    return output_path
