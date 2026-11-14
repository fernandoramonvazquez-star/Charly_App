#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Charly_App.py — Aplicación de Escritorio de CHARLY v4.0 (Cerebro Psicométrico Dual).
100% idéntica línea por línea en pasos, textos, validaciones, contratos y ejecución R
a Charly (charly_core.ps1), conservando la foto de Peperina en el encabezado y ventana.
"""

import ctypes
import datetime
import html
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import webbrowser
from pathlib import Path

try:
    ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(
        "charly.psicometria.peperina.v4"
    )
except Exception:
    pass

try:
    from PySide6.QtCore import Qt, QThread, QTimer, Signal
    from PySide6.QtGui import (
        QFont,
        QIcon,
        QKeySequence,
        QPixmap,
        QShortcut,
        QTextCursor,
    )
    from PySide6.QtWidgets import (
        QApplication,
        QComboBox,
        QDialog,
        QFileDialog,
        QFrame,
        QGridLayout,
        QHBoxLayout,
        QLabel,
        QLineEdit,
        QMainWindow,
        QMessageBox,
        QPlainTextEdit,
        QProgressBar,
        QPushButton,
        QScrollArea,
        QTabWidget,
        QTextBrowser,
        QTextEdit,
        QVBoxLayout,
        QWidget,
    )

    import charly_docx
    import charly_engine
    import charly_report_summary
    import charly_secrets

    from charly_ui import (  # noqa: E402  (piezas de UI extraidas a charly_ui.py)
        CHARLY_STYLE,
        PS_COLOR_MAP,
        AsyncStep,
        AsyncTaskWorker,
        AutoScrollConsole,
        PromptStep,
        ShowInputWindowDialog,
        _strip_accents,
        as_spec,
        continue_prompt,
    )
except ImportError as _imp_err:
    _msg = (
        f"Faltan dependencias de Python ({_imp_err}).\n\n"
        "Por favor ejecute primero Instalar_Charly_App.bat."
    )
    try:
        ctypes.windll.user32.MessageBoxW(
            0, _msg, "Charly App - Dependencias faltantes", 0x10
        )
    except Exception:
        sys.stderr.write(_msg + "\n")
    sys.exit(1)

class CharlyApp(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("CHARLY v4.0 - Asistente de Análisis Psicométrico en R")
        self.setMinimumSize(720, 500)
        self.setStyleSheet(CHARLY_STYLE)

        screen = QApplication.primaryScreen()
        if screen:
            avail = screen.availableGeometry()
            w = min(1020, max(760, avail.width() - 60))
            h = min(700, max(520, avail.height() - 60))
            x = avail.x() + max(0, (avail.width() - w) // 2)
            y = avail.y() + max(0, (avail.height() - h) // 2)
            self.setGeometry(x, y, w, h)
        else:
            self.resize(1020, 700)

        self.icon_path = Path(__file__).resolve().parent / "peperina.png"
        self.ico_path = Path(__file__).resolve().parent / "peperina.ico"
        if self.ico_path.exists():
            self.setWindowIcon(QIcon(str(self.ico_path)))
        elif self.icon_path.exists():
            self.setWindowIcon(QIcon(str(self.icon_path)))

        self.rscript_bin = charly_engine.find_rscript()
        self.active_generator = None
        self.waiting_for_input = False
        self.current_worker = None
        self._workers: set = set()  # dueños de los QThread hasta que 'finished' (evita destruirlos en marcha)
        self._cancel_requested = False
        self.current_dataset_path = ""

        self.elapsed_seconds = 0
        self.in_analysis_pipeline = False
        self.pipeline_start_time = 0.0
        self.last_run_time_str = ""
        self.elapsed_timer = QTimer(self)
        self.elapsed_timer.timeout.connect(self._on_timer_tick)

        self._init_ui()

        self.start_main_menu()

    def _open_catalogo_doc(self):
        base_dir = Path(__file__).resolve().parent
        doc_html = base_dir / "Catalogo_Consignas_Charly.html"
        doc_docx = base_dir / "Catalogo_Consignas_Charly.docx"
        target = doc_html if doc_html.exists() else (doc_docx if doc_docx.exists() else None)
        try:
            if target and target.exists():
                os.startfile(str(target))
            else:
                QMessageBox.information(
                    self,
                    "Catálogo de Ejemplos",
                    "No se encontró Catalogo_Consignas_Charly (.html / .docx) junto a la aplicación."
                )
        except OSError as e:
            QMessageBox.warning(self, "Catálogo de Ejemplos", f"No se pudo abrir el documento: {e}")

    def _open_instructivo_doc(self):
        base_dir = Path(__file__).resolve().parent
        doc_html = base_dir / "Instructivo.html"
        doc_docx = base_dir / "Instructivo.docx"
        doc_md = base_dir / "Instructivo.md"
        target = doc_html if doc_html.exists() else (doc_docx if doc_docx.exists() else (doc_md if doc_md.exists() else None))
        try:
            if target and target.exists():
                os.startfile(str(target))
            else:
                QMessageBox.information(
                    self,
                    "Instructivo de Uso",
                    "No se encontró Instructivo (.html / .docx / .md) junto a la aplicación."
                )
        except OSError as e:
            QMessageBox.warning(self, "Instructivo de Uso", f"No se pudo abrir el documento: {e}")

    def _open_security_doc(self):
        base_dir = Path(__file__).resolve().parent
        doc_html = base_dir / "Seguridad.html"
        doc_md = base_dir / "LEEME_SEGURIDAD.md"
        target = doc_html if doc_html.exists() else (doc_md if doc_md.exists() else None)
        try:
            if target and target.exists():
                os.startfile(str(target))
            else:
                QMessageBox.information(
                    self,
                    "Seguridad y Privacidad",
                    "No se encontró el documento de Seguridad (.html / .md) junto a la aplicación."
                )
        except OSError as e:
            QMessageBox.warning(self, "Seguridad y Privacidad", f"No se pudo abrir el documento: {e}")

    def _bg(self, fn, on_done, *args, **kwargs):

        """Ejecuta fn(*args) en un hilo y llama on_done(payload) en el hilo de la GUI (sin congelar la ventana)."""
        w = AsyncTaskWorker(fn, *args, **kwargs)
        w.done_signal.connect(on_done)
        self._track(w)
        w.start()
        return w

    def _save_settings(self, cfg: dict) -> bool:
        """charly_secrets.save_settings con aviso al usuario si DPAPI/disco fallan (una vez por sesión)."""
        try:
            charly_secrets.save_settings(cfg)
            return True
        except (charly_secrets.SecretError, OSError) as e:
            if not getattr(self, "_save_warned", False):
                self._save_warned = True
                QMessageBox.warning(self, "No se pudo guardar la configuración", str(e))
            return False

    def _track(self, worker):
        """Mantiene viva la referencia al QThread hasta que el hilo realmente termino."""
        self._workers.add(worker)
        worker.finished.connect(lambda w=worker: self._worker_finished(w))

    def _worker_finished(self, w):
        self._workers.discard(w)
        if self.current_worker is w:
            self.current_worker = None
        w.deleteLater()

    def _cancel_current(self):
        self.in_analysis_pipeline = False
        if hasattr(self, "lbl_timer"):
            self.lbl_timer.setText("⏱️ Listo")
        if self.current_worker is not None and self.current_worker.isRunning() and not self._cancel_requested:
            self._cancel_requested = True
            self.btn_cancel.setEnabled(False)
            self.console_write("\n[CANCELANDO] Deteniendo procesos en curso...", "Yellow")
            charly_engine.cancel_all()

    def closeEvent(self, event):
        charly_engine.cancel_all()
        for w in list(self._workers):
            w.requestInterruption()
            if not w.wait(4000):
                w.terminate()  # ultimo recurso
                w.wait(1000)
        super().closeEvent(event)

    def _on_timer_tick(self):
        self.elapsed_seconds += 1
        if getattr(self, "in_analysis_pipeline", False) and getattr(self, "pipeline_start_time", 0.0) > 0:
            total_secs = int(time.time() - self.pipeline_start_time)
            mins = total_secs // 60
            secs = total_secs % 60
            t_str = f"{mins} min {secs} seg" if mins > 0 else f"{secs} seg"
            self.lbl_timer.setText(f"⏱️ Tiempo: {t_str}")
        else:
            mins = self.elapsed_seconds // 60
            secs = self.elapsed_seconds % 60
            t_str = f"{mins} min {secs} seg" if mins > 0 else f"{secs} seg"
            self.lbl_timer.setText(f"⏱️ Tiempo: {t_str}")
    def _init_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_lay = QVBoxLayout(central)
        main_lay.setContentsMargins(14, 10, 14, 10)
        main_lay.setSpacing(8)

        # Barra superior con la foto de Peperina (exclusivo de Charly App)
        header_frame = QFrame()
        header_frame.setStyleSheet("""
            QFrame {
                background-color: #161B22;
                border: 1px solid #30363D;
                border-radius: 8px;
                padding: 6px 12px;
            }
        """)
        top_bar = QHBoxLayout(header_frame)
        top_bar.setContentsMargins(6, 4, 6, 4)

        if self.icon_path.exists():
            lbl_photo = QLabel()
            pix = QPixmap(str(self.icon_path)).scaled(
                52,
                52,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
            lbl_photo.setPixmap(pix)
            lbl_photo.setStyleSheet(
                "border: 2px solid #58A6FF; border-radius: 6px; padding: 1px; background: #0D1117;"
            )
            top_bar.addWidget(lbl_photo)

        title_col = QVBoxLayout()
        title_col.setSpacing(2)
        lbl_title = QLabel("CHARLY v4.0 - ASISTENTE DE ANÁLISIS PSICOMÉTRICO")
        lbl_title.setStyleSheet(
            "font-size: 18px; font-weight: 800; color: #F2CC60; border: none;"
        )
        lbl_sub = QLabel(
            "Ejecución local en R | Modo Nube (Google Gemini) o Modo Local (Offline) | Verificación sintáctica y metodológica"
        )
        lbl_sub.setWordWrap(True)
        lbl_sub.setStyleSheet("font-size: 11px; color: #8B949E; border: none;")
        title_col.addWidget(lbl_title)
        title_col.addWidget(lbl_sub)
        top_bar.addLayout(title_col, 1)

        self.lbl_r_badge = QLabel()
        if self.rscript_bin:
            m_ver = re.search(r"R-(\d+\.\d+\.\d+)", str(self.rscript_bin), re.I)
            self.lbl_r_badge.setText(
                f"🟢 R {m_ver.group(1)} Activo" if m_ver else "🟢 R Activo"
            )
            self.lbl_r_badge.setStyleSheet(
                "color: #56D364; font-weight: bold; font-size: 12px; border: none; margin-right: 8px;"
            )
        else:
            self.lbl_r_badge.setText("🔴 Rscript no detectado")
            self.lbl_r_badge.setStyleSheet(
                "color: #FF7B72; font-weight: bold; font-size: 12px; border: none; margin-right: 8px;"
            )
        top_bar.addWidget(self.lbl_r_badge)

        self.lbl_timer = QLabel("⏱️ Listo")
        self.lbl_timer.setStyleSheet(
            "color: #58A6FF; font-weight: bold; font-size: 12px; border: none; margin-right: 10px;"
        )
        top_bar.addWidget(self.lbl_timer)

        btn_setup_top = QPushButton("⚙️ Configurar R / IA")
        btn_setup_top.setObjectName("btn_secondary")
        btn_setup_top.clicked.connect(lambda: self.tabs.setCurrentWidget(self.tab_student_setup))
        top_bar.addWidget(btn_setup_top)

        self.btn_cancel = QPushButton("⛔ Cancelar")
        self.btn_cancel.setObjectName("btn_danger")
        self.btn_cancel.setVisible(False)
        self.btn_cancel.clicked.connect(self._cancel_current)
        top_bar.addWidget(self.btn_cancel)

        btn_security = QPushButton("🔒 Seguridad")
        btn_security.setObjectName("btn_secondary")
        btn_security.setToolTip("Qué ejecuta Charly en tu PC, qué sale de ella y cómo se protege tu API Key")
        btn_security.clicked.connect(self._open_security_doc)

        top_bar.addWidget(btn_security)

        btn_catalogo = QPushButton("📖 Catálogo de Ejemplos")
        btn_catalogo.setObjectName("btn_secondary")
        btn_catalogo.setToolTip("Ver modelos de consignas probadas y validadas para los 10 arquetipos canónicos")
        btn_catalogo.clicked.connect(self._open_catalogo_doc)
        top_bar.addWidget(btn_catalogo)

        btn_instructivo = QPushButton("📘 Instructivo")
        btn_instructivo.setObjectName("btn_secondary")
        btn_instructivo.setToolTip("Guía paso a paso de uso, configuración de R/IA y gestión de bases de datos")
        btn_instructivo.clicked.connect(self._open_instructivo_doc)
        top_bar.addWidget(btn_instructivo)

        btn_home = QPushButton("🏠 Menú Principal")

        btn_home.setObjectName("btn_secondary")
        btn_home.clicked.connect(self.start_main_menu)
        top_bar.addWidget(btn_home)

        main_lay.addWidget(header_frame)

        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 0)
        self.progress_bar.setFixedHeight(8)
        self.progress_bar.setTextVisible(False)
        self.progress_bar.setStyleSheet("""
            QProgressBar { border: none; background-color: #161B22; border-radius: 4px; }
            QProgressBar::chunk { background-color: #238636; border-radius: 4px; }
        """)
        self.progress_bar.setVisible(False)
        main_lay.addWidget(self.progress_bar)

        self.tabs = QTabWidget()

        # Pestaña 1: Consola Interactiva Principal (Idéntica a Charly)
        tab_console = QWidget()
        con_lay = QVBoxLayout(tab_console)
        con_lay.setContentsMargins(6, 6, 6, 6)
        con_lay.setSpacing(8)

        self.console_view = AutoScrollConsole()
        self.console_view.setFont(QFont("Consolas", 10))
        self.console_view.setOpenExternalLinks(False)
        con_lay.addWidget(self.console_view, 1)

        # Cuadro multilínea para Paso 1 (pegar o escribir instrucción sin truncar saltos de línea)
        self.multiline_box_frame = QFrame()
        self.multiline_box_frame.setStyleSheet(
            "QFrame { background-color: #161B22; border: 1px solid #30363D; border-radius: 6px; padding: 6px; }"
        )
        ml_lay = QVBoxLayout(self.multiline_box_frame)
        ml_lay.setContentsMargins(6, 4, 6, 4)
        lbl_ml = QLabel(
            "📋 Tu consulta (pegala acá; si ya la habías copiado con Ctrl+C aparece sola) — [ENTER] o Ctrl+Enter para usarla:"
        )
        lbl_ml.setStyleSheet(
            "color: #58A6FF; font-size: 11px; font-weight: bold; border: none;"
        )
        ml_lay.addWidget(lbl_ml)
        self.txt_multiline_goal = QPlainTextEdit()
        self.txt_multiline_goal.setPlaceholderText(
            "Pegá o escribí tu consulta acá (sin límite de largo). Luego [ENTER] / Ctrl+Enter, o usá [B] Bloc de Notas / [V] Ventana Gráfica..."
        )
        self.txt_multiline_goal.setMinimumHeight(110)
        self.txt_multiline_goal.setMaximumHeight(240)
        ml_lay.addWidget(self.txt_multiline_goal)
        # Ctrl+Enter envia la consulta (en el cuadro multilinea Enter solo agrega un salto de linea).
        self._goal_submit_shortcut = QShortcut(
            QKeySequence("Ctrl+Return"), self.txt_multiline_goal
        )
        self._goal_submit_shortcut.activated.connect(self.on_submit_input)
        # Ultimo texto que Charly puso solo en el cuadro (para poder refrescarlo si el usuario copia otra cosa).
        self._goal_autofill_text = ""
        QApplication.clipboard().dataChanged.connect(self._on_clipboard_changed)
        self.multiline_box_frame.setVisible(False)
        con_lay.addWidget(self.multiline_box_frame)

        # Botones dinámicos de opciones (en grilla para no ensanchar la ventana fuera de la pantalla)
        self.buttons_frame = QFrame()
        self.buttons_frame.setStyleSheet(
            "QFrame { background-color: #161B22; border: 1px solid #30363D; border-radius: 6px; padding: 4px; }"
        )
        self.buttons_layout = QGridLayout(self.buttons_frame)
        self.buttons_layout.setContentsMargins(6, 4, 6, 4)
        self.buttons_layout.setSpacing(6)
        con_lay.addWidget(self.buttons_frame)

        # Entrada tipo Read-Host
        input_frame = QFrame()
        input_frame.setStyleSheet(
            "QFrame { background-color: #161B22; border: 1px solid #388BFD; border-radius: 6px; padding: 4px 8px; }"
        )
        in_lay = QHBoxLayout(input_frame)
        in_lay.setContentsMargins(4, 2, 4, 2)

        self.lbl_prompt = QLabel("Selecciona una opcion:")
        self.lbl_prompt.setStyleSheet(
            "color: #F2CC60; font-family: 'Consolas'; font-size: 13px; font-weight: bold; border: none;"
        )
        in_lay.addWidget(self.lbl_prompt)

        self.txt_input = QLineEdit()
        self.txt_input.setPlaceholderText(
            "Escribe tu opcion y presiona ENTER (o presiona ENTER directo para aceptar [DEFAULT])..."
        )
        self.txt_input.returnPressed.connect(self.on_submit_input)
        in_lay.addWidget(self.txt_input, 1)

        self.btn_enter = QPushButton("⏎ ENTER")
        self.btn_enter.setObjectName("btn_default")
        self.btn_enter.clicked.connect(self.on_submit_input)
        in_lay.addWidget(self.btn_enter)

        con_lay.addWidget(input_frame)
        self.tabs.addTab(tab_console, "🖥️ Consola Interactiva CHARLY v4")

        # Pestaña 2: Código R Generado (generated_script.R)
        self.txt_tab_code = QTextEdit()
        self.txt_tab_code.setReadOnly(True)
        self.txt_tab_code.setFont(QFont("Consolas", 10))
        self.tabs.addTab(self.txt_tab_code, "💻 Código R (generated_script.R)")

        # Pestaña 3: Consola RStudio Completa (consola_rstudio_completa.txt)
        self.txt_tab_verbatim = QTextEdit()
        self.txt_tab_verbatim.setReadOnly(True)
        self.txt_tab_verbatim.setFont(QFont("Consolas", 10))
        self.tabs.addTab(
            self.txt_tab_verbatim,
            "🔢 Consola RStudio Completa (consola_rstudio_completa.txt)",
        )

        # Pestaña 4: Configuración Guiada de R e IA para Estudiantes
        self.tab_student_setup = self._build_student_setup_tab()
        self.tabs.addTab(
            self.tab_student_setup,
            "⚙️ Configurar R e IA (Estudiantes)",
        )

        main_lay.addWidget(self.tabs, 1)
        self._refresh_result_tabs_from_disk()

    def _build_student_setup_tab(self) -> QWidget:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet("QScrollArea { border: none; background-color: #0D1117; }")

        container = QWidget()
        container.setStyleSheet("background-color: #0D1117;")
        lay = QVBoxLayout(container)
        lay.setContentsMargins(16, 12, 16, 12)
        lay.setSpacing(12)

        cfg = charly_secrets.load_settings()

        card_style = """
            QFrame#setup_card {
                background-color: #161B22;
                border: 1px solid #30363D;
                border-radius: 8px;
            }
            QFrame#setup_card > QLabel, QFrame#setup_card QWidget {
                background-color: transparent;
            }
            QFrame#setup_card QLineEdit {
                background-color: #0D1117;
                color: #E6EDF3;
                border: 1px solid #30363D;
                border-radius: 5px;
                padding: 7px 10px;
                font-size: 14px;
            }
            QFrame#setup_card QLineEdit:focus {
                border: 1px solid #58A6FF;
            }
            QFrame#setup_card QPushButton#btn_secondary {
                background-color: #21262D;
                color: #C9D1D9;
                border: 1px solid #30363D;
                border-radius: 5px;
                padding: 7px 12px;
                font-size: 13px;
            }
            QFrame#setup_card QPushButton#btn_default {
                background-color: #238636;
                color: #FFFFFF;
                border: 1px solid #2EA043;
                border-radius: 5px;
                padding: 7px 14px;
                font-size: 13px;
                font-weight: bold;
            }
        """

        # --- PASO 1: ENTORNO R Y PAQUETES PSICOMETRICOS ---
        frame_r = QFrame()
        frame_r.setObjectName("setup_card")
        frame_r.setStyleSheet(card_style)
        r_lay = QVBoxLayout(frame_r)
        r_lay.setContentsMargins(18, 14, 18, 14)
        r_lay.setSpacing(10)

        lbl_r_title = QLabel("PASO 1: Entorno R y Paquetes Psicométricos (Necesario)")
        lbl_r_title.setStyleSheet("color: #F2CC60; font-size: 16px; font-weight: bold; border: none;")
        r_lay.addWidget(lbl_r_title)

        lbl_r_desc = QLabel(
            "Charly ejecuta tus modelos en R real. Si aún no tienes R instalado en tu computadora, "
            "descárgalo gratis con el botón [1] (solo abre la página de descarga: instálalo a mano) y luego instala las librerías psicométricas con un solo clic en el botón [2]."
        )
        lbl_r_desc.setWordWrap(True)
        lbl_r_desc.setStyleSheet("color: #C9D1D9; font-size: 14px; border: none;")
        r_lay.addWidget(lbl_r_desc)

        r_row = QHBoxLayout()
        lbl_r_path = QLabel("Ejecutable Rscript.exe:")
        lbl_r_path.setStyleSheet("color: #58A6FF; font-size: 14px; font-weight: bold; border: none;")
        r_row.addWidget(lbl_r_path)

        self.txt_setup_r_path = QLineEdit(cfg.get("r_home") or (self.rscript_bin or ""))
        self.txt_setup_r_path.setPlaceholderText("Detección automática en C:\\Program Files\\R...")
        r_row.addWidget(self.txt_setup_r_path, 1)

        btn_browse_r = QPushButton("📂 Buscar R...")
        btn_browse_r.setObjectName("btn_secondary")
        btn_browse_r.clicked.connect(self._browse_r_exe)
        r_row.addWidget(btn_browse_r)

        btn_dl_r = QPushButton("🌐 1. Descargar R Gratis (CRAN)")
        btn_dl_r.setObjectName("btn_secondary")
        btn_dl_r.clicked.connect(lambda: webbrowser.open("https://cran.r-project.org/bin/windows/base/"))
        r_row.addWidget(btn_dl_r)
        r_lay.addLayout(r_row)

        pkg_row = QHBoxLayout()
        self.lbl_r_pkgs_status = QLabel("Haz clic en 'Comprobar / Instalar Paquetes' para verificar lavaan, semTools, psych, MASS, readxl...")
        self.lbl_r_pkgs_status.setWordWrap(True)
        self.lbl_r_pkgs_status.setStyleSheet("color: #8B949E; font-size: 13px; border: none;")
        pkg_row.addWidget(self.lbl_r_pkgs_status, 1)

        self.btn_check_r = QPushButton("🔍 Verificar R")
        self.btn_check_r.setObjectName("btn_secondary")
        self.btn_check_r.clicked.connect(self._refresh_r_status_ui)
        pkg_row.addWidget(self.btn_check_r)

        self.btn_install_pkgs = QPushButton("📦 2. Comprobar e Instalar Paquetes de R Automáticamente")
        self.btn_install_pkgs.setObjectName("btn_default")
        self.btn_install_pkgs.clicked.connect(self._install_r_packages_clicked)
        pkg_row.addWidget(self.btn_install_pkgs)
        r_lay.addLayout(pkg_row)

        lay.addWidget(frame_r, 1)

        # --- PASO 2: IA EN LA NUBE (GOOGLE GEMINI GRATIS) ---
        frame_cloud = QFrame()
        frame_cloud.setObjectName("setup_card")
        frame_cloud.setStyleSheet(card_style)
        c_lay = QVBoxLayout(frame_cloud)
        c_lay.setContentsMargins(18, 14, 18, 14)
        c_lay.setSpacing(10)

        lbl_c_title = QLabel("PASO 2: Vía Nube Ultrarrápida — Google Gemini Gratis (Recomendada para todos los estudiantes)")
        lbl_c_title.setStyleSheet("color: #56D364; font-size: 16px; font-weight: bold; border: none;")
        c_lay.addWidget(lbl_c_title)

        lbl_c_desc = QLabel(
            "1) Haz clic en 'Obtener Clave Gratis en Google AI Studio' e inicia sesión con tu cuenta Gmail.\n"
            "2) Pulsa el botón azul 'Create API key', copia la clave y pégala abajo.\n"
            "3) Haz clic en 'Guardar y Probar Conexión Nube'. Tu clave queda guardada y cifrada en tu PC."
        )
        lbl_c_desc.setWordWrap(True)
        lbl_c_desc.setStyleSheet("color: #C9D1D9; font-size: 14px; border: none;")
        c_lay.addWidget(lbl_c_desc)

        c_row1 = QHBoxLayout()
        btn_get_key = QPushButton("🔑 1. Obtener Clave Gratis en Google AI Studio")
        btn_get_key.setObjectName("btn_secondary")
        btn_get_key.clicked.connect(lambda: webbrowser.open("https://aistudio.google.com/app/apikey"))
        c_row1.addWidget(btn_get_key)

        lbl_key = QLabel("Tu API Key:")
        lbl_key.setStyleSheet("color: #58A6FF; font-size: 14px; font-weight: bold; border: none;")
        c_row1.addWidget(lbl_key)

        self.txt_setup_api_key = QLineEdit(cfg.get("api_key") or "")
        self.txt_setup_api_key.setEchoMode(QLineEdit.EchoMode.Password)
        self.txt_setup_api_key.setPlaceholderText("Pega aquí tu clave de Google AI Studio (AIzaSy...)")
        c_row1.addWidget(self.txt_setup_api_key, 1)

        btn_toggle_key = QPushButton("👁️ Ver")
        btn_toggle_key.setObjectName("btn_secondary")
        btn_toggle_key.clicked.connect(self._toggle_api_key_visibility)
        c_row1.addWidget(btn_toggle_key)
        c_lay.addLayout(c_row1)

        c_row2 = QHBoxLayout()
        lbl_mod = QLabel("Modelo en la Nube:")
        lbl_mod.setStyleSheet("color: #58A6FF; font-size: 14px; font-weight: bold; border: none;")
        c_row2.addWidget(lbl_mod)

        self.cmb_cloud_model = QComboBox()
        self.cmb_cloud_model.setStyleSheet(
            "background-color: #0D1117; color: #E6EDF3; border: 1px solid #30363D; padding: 6px 10px; border-radius: 5px; font-size: 14px;"

        )

        cloud_models = [
            "gemini-flash-lite-latest",
            "gemini-flash-latest",
            "gemini-2.5-flash",
            "gemini-2.0-flash",
        ]
        self.cmb_cloud_model.addItems(cloud_models)
        saved_mod = cfg.get("model") or "gemini-flash-lite-latest"

        if saved_mod in cloud_models:

            self.cmb_cloud_model.setCurrentText(saved_mod)
        c_row2.addWidget(self.cmb_cloud_model)

        self.lbl_cloud_status = QLabel(
            "🟢 Clave configurada"
            if cfg.get("api_key")
            else (
                "⚠️ La clave guardada no se pudo descifrar en esta cuenta de Windows: pégala de nuevo"
                if cfg.get("_api_key_unreadable")
                else "⚪ Sin clave configurada aún"
            )
        )
        self.lbl_cloud_status.setStyleSheet("color: #8B949E; font-size: 13px; border: none;")
        c_row2.addWidget(self.lbl_cloud_status, 1)

        self.btn_save_cloud = QPushButton("💾 2. Guardar y Probar Conexión Nube")
        self.btn_save_cloud.setObjectName("btn_default")
        self.btn_save_cloud.clicked.connect(self._save_and_test_cloud)
        c_row2.addWidget(self.btn_save_cloud)
        c_lay.addLayout(c_row2)

        lay.addWidget(frame_cloud, 1)

        # --- PASO 3: IA LOCAL / OFFLINE (OPCIONAL) ---
        frame_local = QFrame()
        frame_local.setObjectName("setup_card")
        frame_local.setStyleSheet(card_style)
        l_lay = QVBoxLayout(frame_local)
        l_lay.setContentsMargins(18, 14, 18, 14)
        l_lay.setSpacing(10)

        lbl_l_title = QLabel("PASO 3: Vía IA Local / 100% Offline (Opcional — solo si tienes IA local en tu PC)")
        lbl_l_title.setStyleSheet("color: #58A6FF; font-size: 16px; font-weight: bold; border: none;")
        l_lay.addWidget(lbl_l_title)

        self.lbl_l_desc = QLabel()
        self.lbl_l_desc.setWordWrap(True)
        self.lbl_l_desc.setStyleSheet("color: #C9D1D9; font-size: 14px; border: none;")
        l_lay.addWidget(self.lbl_l_desc)

        l_row_mode = QHBoxLayout()
        lbl_mode = QLabel("Modo Local:")
        lbl_mode.setStyleSheet("color: #58A6FF; font-size: 14px; font-weight: bold; border: none;")
        l_row_mode.addWidget(lbl_mode)

        self.cmb_local_mode = QComboBox()
        self.cmb_local_mode.setStyleSheet(
            "background-color: #0D1117; color: #E6EDF3; border: 1px solid #30363D; padding: 6px 10px; border-radius: 5px; font-size: 14px;"
        )
        self.cmb_local_mode.addItem("Opción A: IA Local por URL (Ollama, LM Studio, Jan, GPT4All)", "endpoint")
        self.cmb_local_mode.addItem("Opción B: Archivo .gguf directo con llama-server.exe (Llama.cpp)", "llama_server")
        idx_mode = 1 if (cfg.get("local_mode") == "llama_server") else 0
        self.cmb_local_mode.setCurrentIndex(idx_mode)
        self.cmb_local_mode.currentIndexChanged.connect(self._on_local_mode_changed)
        l_row_mode.addWidget(self.cmb_local_mode, 1)

        self.btn_autodetect_local = QPushButton("🔎 1. Autodetectar Mi IA Local")
        self.btn_autodetect_local.setObjectName("btn_default")
        self.btn_autodetect_local.clicked.connect(self._auto_detect_local_clicked)
        l_row_mode.addWidget(self.btn_autodetect_local)

        btn_preset_ollama = QPushButton("⚡ Ollama (11434)")
        btn_preset_ollama.setObjectName("btn_secondary")
        btn_preset_ollama.clicked.connect(lambda: self._apply_local_preset("endpoint", "http://127.0.0.1:11434", "qwen2.5-coder:14b"))
        l_row_mode.addWidget(btn_preset_ollama)

        btn_preset_lms = QPushButton("⚡ LM Studio (1234)")
        btn_preset_lms.setObjectName("btn_secondary")
        btn_preset_lms.clicked.connect(lambda: self._apply_local_preset("endpoint", "http://127.0.0.1:1234", "local-model"))
        l_row_mode.addWidget(btn_preset_lms)

        btn_preset_seru = QPushButton("⚡ Llama.cpp / .gguf (8090)")
        btn_preset_seru.setObjectName("btn_secondary")
        btn_preset_seru.clicked.connect(lambda: self._apply_local_preset("llama_server", "http://127.0.0.1:8090", "local-model"))
        l_row_mode.addWidget(btn_preset_seru)
        l_lay.addLayout(l_row_mode)

        # Contenedor Opción A (URL Servidor + Nombre Modelo)
        self.widget_local_opt_a = QWidget()
        l_row_ep = QHBoxLayout(self.widget_local_opt_a)
        l_row_ep.setContentsMargins(0, 0, 0, 0)
        lbl_host = QLabel("URL Servidor Local:")
        lbl_host.setStyleSheet("color: #58A6FF; font-size: 14px; font-weight: bold; border: none;")
        l_row_ep.addWidget(lbl_host)

        self.txt_local_host = QLineEdit(cfg.get("local_host") or "http://127.0.0.1:8090")
        l_row_ep.addWidget(self.txt_local_host, 1)

        lbl_lmod = QLabel("Nombre Modelo:")
        lbl_lmod.setStyleSheet("color: #58A6FF; font-size: 14px; font-weight: bold; border: none;")
        l_row_ep.addWidget(lbl_lmod)

        self.txt_local_model_name = QLineEdit(cfg.get("local_model_name") or "local-model")
        l_row_ep.addWidget(self.txt_local_model_name, 1)
        l_lay.addWidget(self.widget_local_opt_a)

        # Contenedor Opción B (llama-server.exe + Archivo .gguf)
        self.widget_local_opt_b = QWidget()
        l_row_gguf = QHBoxLayout(self.widget_local_opt_b)
        l_row_gguf.setContentsMargins(0, 0, 0, 0)
        lbl_srv_exe = QLabel("Ejecutable llama-server.exe:")
        lbl_srv_exe.setStyleSheet("color: #58A6FF; font-size: 14px; font-weight: bold; border: none;")
        l_row_gguf.addWidget(lbl_srv_exe)

        self.txt_llama_exe = QLineEdit(cfg.get("llama_server_exe") or r"C:\llama-cpp\llama-server.exe")
        self.txt_llama_exe.setPlaceholderText("C:\\llama-cpp\\llama-server.exe")
        l_row_gguf.addWidget(self.txt_llama_exe, 1)

        btn_br_srv = QPushButton("📂")
        btn_br_srv.setObjectName("btn_secondary")
        btn_br_srv.clicked.connect(self._browse_llama_exe)
        l_row_gguf.addWidget(btn_br_srv)

        lbl_gguf = QLabel("Modelo .gguf:")
        lbl_gguf.setStyleSheet("color: #58A6FF; font-size: 14px; font-weight: bold; border: none;")
        l_row_gguf.addWidget(lbl_gguf)

        self.txt_gguf_path = QLineEdit(cfg.get("gguf_model_path") or "")
        self.txt_gguf_path.setPlaceholderText("C:\\llama-cpp\\models\\Qwen3.6-35B-A3B-UD-Q4_K_M.gguf")
        l_row_gguf.addWidget(self.txt_gguf_path, 2)

        btn_br_gguf = QPushButton("📂")
        btn_br_gguf.setObjectName("btn_secondary")
        btn_br_gguf.clicked.connect(self._browse_gguf_model)
        l_row_gguf.addWidget(btn_br_gguf)
        l_lay.addWidget(self.widget_local_opt_b)

        l_row_save = QHBoxLayout()
        self.lbl_local_status = QLabel("Haz clic en 'Guardar y Probar IA Local' para verificar tu conexión offline.")
        self.lbl_local_status.setWordWrap(True)
        self.lbl_local_status.setStyleSheet("color: #8B949E; font-size: 13px; border: none;")
        l_row_save.addWidget(self.lbl_local_status, 1)

        self.btn_save_local = QPushButton("💾 2. Guardar y Probar IA Local")
        self.btn_save_local.setObjectName("btn_default")
        self.btn_save_local.clicked.connect(self._save_and_test_local)
        l_row_save.addWidget(self.btn_save_local)
        l_lay.addLayout(l_row_save)

        lay.addWidget(frame_local, 1)

        self._mode_fields = {
            (cfg.get("local_mode") or "endpoint"): (
                (cfg.get("local_host") or "").strip(),
                (cfg.get("local_model_name") or "").strip(),
            )
        }
        self._update_local_mode_ui(save=False)

        scroll.setWidget(container)
        return scroll

    def _update_local_mode_ui(self, save: bool = False):
        is_opt_b = (self.cmb_local_mode.currentData() == "llama_server")
        self.widget_local_opt_a.setVisible(not is_opt_b)
        self.widget_local_opt_b.setVisible(is_opt_b)
        if is_opt_b:
            self.lbl_l_desc.setText(
                "• Si NO tienes IA local instalada en tu PC, no necesitas tocar nada aquí (usa directamente la Opción [1] Nube Gratis).\n"
                "• Opción B (Llama.cpp directo con archivo .gguf):\n"
                "   1) NO necesitas abrir ningún programa antes: Charly enciende llama-server.exe automáticamente con tu modelo .gguf al analizar.\n"
                "   2) Haz clic en '🔎 1. Autodetectar Mi IA Local' (o elige tus archivos abajo) y luego en '💾 2. Guardar y Probar IA Local'."
            )
            # [FIX M8] antes aqui se forzaban host y modelo (y se persistian), perdiendo los datos de la Opcion A.
            # Ahora solo se rellena un host vacio; el cambio de modo conserva los campos de cada opcion.
            if not self.txt_local_host.text().strip():
                self.txt_local_host.setText(self._LOCAL_MODE_DEFAULTS["llama_server"][0])
            if not self.txt_local_model_name.text().strip():
                self.txt_local_model_name.setText(self._LOCAL_MODE_DEFAULTS["llama_server"][1])
        else:
            self.lbl_l_desc.setText(
                "• Si NO tienes IA local instalada en tu PC, no necesitas tocar nada aquí (usa directamente la Opción [1] Nube Gratis).\n"
                "• Opción A (Ollama, LM Studio, Jan AI, GPT4All, etc.):\n"
                "   1) Abre primero tu programa de IA local en tu computadora con un modelo cargado.\n"
                "   2) Haz clic en '🔎 1. Autodetectar Mi IA Local' (detectará el puerto y el nombre real de tu modelo) y luego en '💾 2. Guardar y Probar IA Local'."
            )
        self._last_local_mode = self.cmb_local_mode.currentData()
        if save:
            self._save_settings(self._collect_current_settings())

    # Valores por defecto (host, nombre de modelo) de cada opcion del modo local
    _LOCAL_MODE_DEFAULTS = {
        "endpoint": ("http://127.0.0.1:11434", "local-model"),
        "llama_server": ("http://127.0.0.1:8090", "local-model"),
    }

    def _remember_current_mode_fields(self):
        """Guarda host/modelo del modo actual antes de que un preset o la autodeteccion cambie de modo."""
        mode = self.cmb_local_mode.currentData() or "endpoint"
        self._mode_fields[mode] = (self.txt_local_host.text().strip(), self.txt_local_model_name.text().strip())

    def _on_local_mode_changed(self, _idx: int = 0):
        """Cambio de modo hecho por el usuario: guarda los campos del modo que deja y restaura los del que elige."""
        new_mode = self.cmb_local_mode.currentData() or "endpoint"
        prev_mode = getattr(self, "_last_local_mode", None)
        if prev_mode and prev_mode != new_mode:
            self._mode_fields[prev_mode] = (
                self.txt_local_host.text().strip(),
                self.txt_local_model_name.text().strip(),
            )
            host, name = self._mode_fields.get(new_mode) or self._LOCAL_MODE_DEFAULTS[new_mode]
            self.txt_local_host.setText(host or self._LOCAL_MODE_DEFAULTS[new_mode][0])
            self.txt_local_model_name.setText(name or self._LOCAL_MODE_DEFAULTS[new_mode][1])
        self._update_local_mode_ui(save=True)

    def _collect_current_settings(self) -> dict:
        cfg = charly_secrets.load_settings()
        cfg["r_home"] = self.txt_setup_r_path.text().strip()
        cfg["api_key"] = self.txt_setup_api_key.text().strip()
        cfg["model"] = self.cmb_cloud_model.currentText().strip()
        cfg["local_mode"] = self.cmb_local_mode.currentData() or "endpoint"
        cfg["local_host"] = self.txt_local_host.text().strip() or "http://127.0.0.1:8090"
        cfg["local_model_name"] = self.txt_local_model_name.text().strip() or "local-model"
        cfg["llama_server_exe"] = self.txt_llama_exe.text().strip()
        cfg["gguf_model_path"] = self.txt_gguf_path.text().strip()
        return cfg

    def _toggle_api_key_visibility(self):
        if self.txt_setup_api_key.echoMode() == QLineEdit.EchoMode.Password:
            self.txt_setup_api_key.setEchoMode(QLineEdit.EchoMode.Normal)
        else:
            self.txt_setup_api_key.setEchoMode(QLineEdit.EchoMode.Password)

    def _apply_local_preset(self, mode: str, host: str, model_name: str):
        idx = 1 if mode == "llama_server" else 0
        self._remember_current_mode_fields()
        self.cmb_local_mode.blockSignals(True)
        self.cmb_local_mode.setCurrentIndex(idx)
        self.cmb_local_mode.blockSignals(False)
        self.txt_local_host.setText(host)
        self.txt_local_model_name.setText(model_name)
        if mode == "llama_server":
            best = charly_engine._select_best_gguf(Path(r"C:\llama-cpp\models"), self.txt_gguf_path.text().strip())
            if best:
                self.txt_gguf_path.setText(str(best))
            if not self.txt_llama_exe.text().strip() and os.path.isfile(r"C:\llama-cpp\llama-server.exe"):
                self.txt_llama_exe.setText(r"C:\llama-cpp\llama-server.exe")
        self._update_local_mode_ui(save=True)
        self.lbl_local_status.setText(f"Preset aplicado ({host}). Haz clic en '💾 2. Guardar y Probar IA Local' para verificar.")
        self.lbl_local_status.setStyleSheet("color: #58A6FF; font-size: 11px; border: none;")

    def _auto_detect_local_clicked(self):
        self.lbl_local_status.setText("⏳ Buscando programas de IA Local abiertos o modelos .gguf en tu PC...")
        self.lbl_local_status.setStyleSheet("color: #58A6FF; font-size: 11px; border: none;")
        self.btn_autodetect_local.setEnabled(False)
        current_mode = self.cmb_local_mode.currentData() or "llama_server"

        def _done(payload):
            self.btn_autodetect_local.setEnabled(True)
            if payload.get("ok"):
                det = payload["result"]
            else:
                det = {"found": False, "message": f"❌ Error durante la detección: {payload.get('error')}"}
            if det.get("found"):
                idx = 1 if det.get("mode") == "llama_server" else 0
                self._remember_current_mode_fields()
                self.cmb_local_mode.blockSignals(True)
                self.cmb_local_mode.setCurrentIndex(idx)
                self.cmb_local_mode.blockSignals(False)
                self.txt_local_host.setText(det.get("host") or "http://127.0.0.1:8090")
                self.txt_local_model_name.setText(det.get("model_name") or "local-model")
                if det.get("llama_server_exe"):
                    self.txt_llama_exe.setText(det["llama_server_exe"])
                if det.get("gguf_model_path"):
                    self.txt_gguf_path.setText(det["gguf_model_path"])
                self._update_local_mode_ui(save=True)
                self.lbl_local_status.setText(det["message"])
                self.lbl_local_status.setStyleSheet("color: #56D364; font-size: 11px; font-weight: bold; border: none;")
                QMessageBox.information(self, "IA Local Detectada", det["message"])
            else:
                self.lbl_local_status.setText(det["message"])
                self.lbl_local_status.setStyleSheet("color: #F2CC60; font-size: 11px; font-weight: bold; border: none;")
                QMessageBox.warning(self, "Detección de IA Local", det["message"])

        self._bg(charly_engine.auto_detect_local_ai, _done, preferred_mode=current_mode)

    def _browse_r_exe(self):
        f, _ = QFileDialog.getOpenFileName(
            self,
            "Seleccionar Rscript.exe",
            r"C:\Program Files\R",
            "Ejecutable Rscript (Rscript.exe);;Todos (*.*)",
        )
        if f:
            self.txt_setup_r_path.setText(f)
            cfg = self._collect_current_settings()
            self._save_settings(cfg)
            self._refresh_r_status_ui()

    def _browse_llama_exe(self):
        start_dir = str(Path(self.txt_llama_exe.text().strip()).parent) if self.txt_llama_exe.text().strip() else r"C:\\"
        f, _ = QFileDialog.getOpenFileName(
            self,
            "Seleccionar llama-server.exe",
            start_dir,
            "Ejecutable (llama-server.exe *.exe)",
        )
        if f:
            self.txt_llama_exe.setText(f)
            self._save_settings(self._collect_current_settings())

    def _browse_gguf_model(self):
        start_dir = str(Path(self.txt_gguf_path.text().strip()).parent) if self.txt_gguf_path.text().strip() else r"C:\llama-cpp\models"
        if not os.path.isdir(start_dir):
            start_dir = r"C:\\"
        f, _ = QFileDialog.getOpenFileName(
            self,
            "Seleccionar Modelo .gguf",
            start_dir,
            "Modelos GGUF (*.gguf);;Todos (*.*)",
        )
        if f:
            self.txt_gguf_path.setText(f)
            self._save_settings(self._collect_current_settings())

    def _refresh_r_status_ui(self):
        cfg = self._collect_current_settings()
        self._save_settings(cfg)
        self.btn_check_r.setEnabled(False)
        self.lbl_r_pkgs_status.setText("⏳ Verificando R y las librerías (puede tardar unos segundos)...")
        self.lbl_r_pkgs_status.setStyleSheet("color: #58A6FF; font-size: 12px; font-weight: bold; border: none;")

        def _done(payload):
            self.btn_check_r.setEnabled(True)
            if payload.get("ok"):
                self._apply_r_diag(payload["result"])
            else:
                self.lbl_r_pkgs_status.setText(f"❌ No se pudo verificar R: {payload.get('error')}")
                self.lbl_r_pkgs_status.setStyleSheet("color: #FF7B72; font-size: 12px; font-weight: bold; border: none;")

        self._bg(charly_engine.diagnose_r_environment, _done)

    def _apply_r_diag(self, diag: dict):
        self.rscript_bin = diag.get("rscript") or None
        if diag["r_found"]:
            self.txt_setup_r_path.setText(diag["rscript"])
            ver_short = diag["r_version"].replace("R version ", "R ").split("(")[0].strip()
            self.lbl_r_badge.setText(f"🟢 {ver_short} Activo")
            self.lbl_r_badge.setStyleSheet(
                "color: #56D364; font-weight: bold; font-size: 12px; border: none; margin-right: 8px;"
            )
            parts = []
            for p, info in diag["packages"].items():
                if info["installed"]:
                    parts.append(f"✅ {p} ({info['version']})")
                else:
                    parts.append(f"❌ {p} (Falta)")
            if not diag["missing"]:
                self.lbl_r_pkgs_status.setText("🟢 ¡Todo listo! Librerías instaladas: " + " | ".join(parts))
                self.lbl_r_pkgs_status.setStyleSheet("color: #56D364; font-size: 12px; font-weight: bold; border: none;")
            else:
                self.lbl_r_pkgs_status.setText(
                    "⚠️ Faltan instalar librerías (" + ", ".join(diag["missing"]) + "). Haz clic en el botón verde de al lado ->\n"
                    + " | ".join(parts)
                )
                self.lbl_r_pkgs_status.setStyleSheet("color: #F2CC60; font-size: 12px; font-weight: bold; border: none;")
        else:
            self.lbl_r_badge.setText("🔴 Rscript no detectado")
            self.lbl_r_badge.setStyleSheet(
                "color: #FF7B72; font-weight: bold; font-size: 12px; border: none; margin-right: 8px;"
            )
            self.lbl_r_pkgs_status.setText(
                "❌ R no fue detectado en esta PC. Haz clic arriba en [🌐 1. Descargar R Gratis (CRAN)], instálalo y vuelve a pulsar [🔍 Verificar R]."
            )
            self.lbl_r_pkgs_status.setStyleSheet("color: #FF7B72; font-size: 12px; font-weight: bold; border: none;")

    def _install_r_packages_clicked(self):
        cfg = self._collect_current_settings()
        self._save_settings(cfg)
        self.btn_install_pkgs.setEnabled(False)
        self.lbl_r_pkgs_status.setText("⏳ Comprobando e instalando paquetes de R desde CRAN... (esto puede tardar 1 a 3 minutos la primera vez)")
        self.lbl_r_pkgs_status.setStyleSheet("color: #58A6FF; font-size: 12px; font-weight: bold; border: none;")
        self.progress_bar.setVisible(True)

        def _do_install():
            return charly_engine.install_missing_r_packages()

        self._pkg_worker = AsyncTaskWorker(_do_install)

        def _on_done(payload):
            self.progress_bar.setVisible(False)
            self.btn_install_pkgs.setEnabled(True)
            self._refresh_r_status_ui()
            if payload.get("ok"):
                ok, msg = payload["result"]
                if ok:
                    QMessageBox.information(self, "Paquetes de R Listos", msg)
                else:
                    QMessageBox.warning(self, "Aviso en Instalación de R", msg)
            else:
                QMessageBox.warning(self, "Error", str(payload.get("error")))

        self._pkg_worker.done_signal.connect(_on_done)
        self._track(self._pkg_worker)
        self._pkg_worker.start()

    def _save_and_test_cloud(self):
        cfg = self._collect_current_settings()
        self._save_settings(cfg)
        self.lbl_cloud_status.setText("⏳ Probando conexión con Google Gemini...")
        self.lbl_cloud_status.setStyleSheet("color: #58A6FF; font-size: 12px; border: none;")
        self.btn_save_cloud.setEnabled(False)

        def _done(payload):
            self.btn_save_cloud.setEnabled(True)
            if payload.get("ok"):
                ok, msg = payload["result"]
            else:
                ok, msg = False, f"❌ Error interno al probar la conexión: {payload.get('error')}"
            self.lbl_cloud_status.setText(msg)
            self.lbl_cloud_status.setStyleSheet(
                f"color: {'#56D364' if ok else '#FF7B72'}; font-size: 12px; font-weight: bold; border: none;"
            )
            if ok:
                QMessageBox.information(self, "Conexión Nube Lista", msg)
            else:
                QMessageBox.warning(self, "Atención en Clave de Nube", msg)

        self._bg(
            charly_engine.test_cloud_connection,
            _done,
            cfg.get("api_key", ""),
            cfg.get("model", "gemini-flash-lite-latest"),
        )

    def _save_and_test_local(self):
        cfg = self._collect_current_settings()
        self._save_settings(cfg)
        self.lbl_local_status.setText("⏳ Verificando configuración de IA Local...")
        self.lbl_local_status.setStyleSheet("color: #58A6FF; font-size: 11px; border: none;")
        self.btn_save_local.setEnabled(False)

        def _done(payload):
            self.btn_save_local.setEnabled(True)
            if payload.get("ok"):
                ok, msg = payload["result"]
            else:
                ok, msg = False, f"❌ Error interno al verificar la IA local: {payload.get('error')}"
            # test_local_ai_connection puede haber corregido gguf/modelo en 'cfg'
            if cfg.get("gguf_model_path") and cfg["gguf_model_path"] != self.txt_gguf_path.text().strip():
                self.txt_gguf_path.setText(cfg["gguf_model_path"])
            if cfg.get("local_model_name") and cfg["local_model_name"] != self.txt_local_model_name.text().strip():
                self.txt_local_model_name.setText(cfg["local_model_name"])
            self._save_settings(cfg)
            self.lbl_local_status.setText(msg)
            self.lbl_local_status.setStyleSheet(
                f"color: {'#56D364' if ok else '#F2CC60'}; font-size: 11px; font-weight: bold; border: none;"
            )
            if ok:
                QMessageBox.information(self, "IA Local Lista", msg)
            else:
                QMessageBox.warning(self, "Estado de IA Local", msg)

        self._bg(charly_engine.test_local_ai_connection, _done, cfg)

    def _refresh_result_tabs_from_disk(self):
        code_f = charly_engine.V4_WORKSPACE / "generated_script.R"
        con_f = charly_engine.V4_WORKSPACE / "consola_rstudio_completa.txt"
        con_text = con_f.read_text(encoding="utf-8-sig", errors="replace") if con_f.exists() else ""
        raw_c = charly_report_summary.extract_executed_r_code(con_text) if con_text else ""
        if not raw_c and code_f.exists():
            raw_c = code_f.read_text(encoding="utf-8-sig", errors="replace")
        if raw_c:
            clean_c = re.sub(r'(\r?\n\s*){3,}', '\n\n', raw_c).strip()
            self.txt_tab_code.setPlainText(clean_c)
        if con_text:
            clean_v = re.sub(r'(\r?\n\s*){3,}', '\n\n', con_text).strip()
            self.txt_tab_verbatim.setPlainText(clean_v)

    def scroll_console_to_bottom(self):

        self.console_view.flush()  # vuelca lo pendiente antes de posicionar el scroll
        self.console_view.moveCursor(QTextCursor.MoveOperation.End)
        self.console_view.ensureCursorVisible()
        sb = self.console_view.verticalScrollBar()
        if sb:
            sb.setValue(sb.maximum())

    def console_clear(self):
        self.console_view.clear()

    def console_write(self, text: str, color: str = "White", newline: bool = True):
        hex_col = PS_COLOR_MAP.get(color, "#E6EDF3")
        escaped = html.escape(text)
        escaped = (
            escaped.replace(" ", "&nbsp;")
            .replace("\r\n", "<br>")
            .replace("\n", "<br>")
        )
        suffix = "<br>" if newline else ""
        span = f"<span style='color:{hex_col}; font-family:Consolas,monospace;'>{escaped}</span>{suffix}"
        self.console_view.queue_html(span)  # [G1] buffer; el scroll lo decide la consola (solo si estaba al final)

    def console_write_lines(self, lines: list[tuple[str, str]]):
        for txt, col in lines:
            self.console_write(txt, col)
        self.scroll_console_to_bottom()
        QTimer.singleShot(0, self.scroll_console_to_bottom)

    def _set_quick_buttons(self, buttons: list[tuple[str, str, str]]):
        while self.buttons_layout.count():
            item = self.buttons_layout.takeAt(0)
            w = item.widget()
            if w:
                w.deleteLater()

        if not buttons:
            self.buttons_frame.setVisible(False)
            self.scroll_console_to_bottom()
            QTimer.singleShot(0, self.scroll_console_to_bottom)
            return

        self.buttons_frame.setVisible(True)
        max_cols = 3
        for idx, item_tuple in enumerate(buttons):
            lbl = item_tuple[0]
            val = item_tuple[1]
            style_id = item_tuple[2] if len(item_tuple) > 2 else ""
            btn = QPushButton(lbl)
            if style_id:
                btn.setObjectName(style_id)
            if val == "__BROWSE_FILE__":
                btn.clicked.connect(self._browse_and_submit_file)
            elif val == "__EXPORT_WORD__":
                btn.clicked.connect(self._export_analysis_to_word)
            elif val == "__SUBMIT_INPUT__":
                btn.clicked.connect(self.on_submit_input)
            else:
                btn.clicked.connect(lambda checked=False, v=val: self.submit_value(v))
            row = idx // max_cols
            col = idx % max_cols
            self.buttons_layout.addWidget(btn, row, col)

        self.scroll_console_to_bottom()
        QTimer.singleShot(0, self.scroll_console_to_bottom)
        QTimer.singleShot(40, self.scroll_console_to_bottom)

    def _browse_and_submit_file(self):
        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Seleccionar archivo de datos",
            str(charly_engine.CHARLY_V4_DIR.parent),
            "Archivos de datos (*.xlsx *.xls *.csv *.sav *.dta *.rds)",
        )
        if file_path:

            self.submit_value(file_path)

    def _export_analysis_to_word(self):
        # Sincroniza workspaces para asegurar la lectura del resultado mas reciente
        charly_engine.sync_workspaces()

        res_f = charly_engine.V4_WORKSPACE / "consola_rstudio_completa.txt"
        code_f = charly_engine.V4_WORKSPACE / "generated_script.R"
        if not res_f.exists():
            QMessageBox.warning(
                self, "Sin Resultados", "Aún no hay resultados para exportar."
            )
            return

        path, _ = QFileDialog.getSaveFileName(

            self,
            "Guardar Informe en Word",
            "Informe_Charly_Psicometria.docx",
            "Documento Word (*.docx)",
        )
        if not path:
            return

        try:

            full_con = res_f.read_text(encoding="utf-8-sig", errors="replace")
            r_out = charly_report_summary.extract_console_output(full_con)

            raw_c = charly_report_summary.extract_executed_r_code(full_con)
            if not raw_c and code_f.exists():
                raw_c = code_f.read_text(encoding="utf-8-sig", errors="replace")
            r_code = re.sub(r'(\r?\n\s*){3,}', '\n\n', raw_c).strip()
            warn_f = charly_engine.V4_WORKSPACE / "avisos_r.txt"
            if not warn_f.exists():
                warn_f = charly_engine.APP_WORKSPACE / "avisos_r.txt"
            r_warnings = (
                warn_f.read_text(encoding="utf-8-sig", errors="replace").strip()
                if warn_f.exists()
                else ""
            )

            info = {

                "filename": Path(self.current_dataset_path).name
                if self.current_dataset_path
                else "Datos",
                "n_rows": "N/D",
                "n_cols": "N/D",
            }
            # N y variables reales: perfil de datos de la ultima corrida + N efectivo informado por lavaan.
            try:
                prof_f = charly_engine.V4_WORKSPACE / "dataset_profile.json"
                if prof_f.exists():
                    prof = json.loads(prof_f.read_text(encoding="utf-8-sig"))
                    info["n_rows"] = prof.get("n_filas", info["n_rows"])
                    info["n_cols"] = prof.get("n_columnas_total", info["n_cols"])
            except Exception:
                pass
            n_eff = charly_report_summary.extract_effective_n(r_out)
            if n_eff is not None:

                info["n_rows"] = n_eff

            charly_docx.create_word_report(
                analysis_title="Informe Psicométrico — CHARLY v4.0",
                summary_text=charly_report_summary.build_key_results_summary(r_out),
                r_output=r_out,
                r_code=r_code,
                dataset_info=info,
                output_path=path,
                r_warnings=r_warnings,
            )

            QMessageBox.information(

                self, "Exportación Exitosa", f"Informe Word guardado en:\n{path}"

            )

        except PermissionError:
            ts = datetime.datetime.now().strftime("%H%M%S")
            p = Path(path)
            alt_path = str(p.with_name(f"{p.stem}_{ts}{p.suffix}"))
            try:
                charly_docx.create_word_report(
                    analysis_title="Informe Psicométrico — CHARLY v4.0",
                    summary_text=charly_report_summary.build_key_results_summary(r_out),
                    r_output=r_out,
                    r_code=r_code,
                    dataset_info=info,
                    output_path=alt_path,
                    r_warnings=r_warnings,
                )
                QMessageBox.warning(
                    self,
                    "Archivo Abierto en Word",
                    f"El archivo '{p.name}' está actualmente abierto en Microsoft Word y Windows no permite sobrescribirlo.\n\n"
                    f"Para no perder tu informe, se guardó automáticamente una copia en:\n{alt_path}\n\n"
                    f"(Para sobrescribir el archivo original, cerrá Microsoft Word y volvé a exportar).",
                )
            except Exception as e2:
                QMessageBox.critical(
                    self,
                    "Error de Bloqueo de Word",
                    f"El archivo '{p.name}' está abierto en Microsoft Word y bloqueado por Windows.\n\n"
                    f"Por favor, cerrá Microsoft Word e intentá exportar nuevamente.",
                )
        except Exception as e:

            QMessageBox.critical(

                self, "Error", f"No se pudo exportar a Word:\n{e}"
            )

    def _on_clipboard_changed(self):
        """Paso de la consulta: si el usuario copia (Ctrl+C) mientras el cuadro esta visible y aun no lo
        modifico a mano, el texto copiado aparece solo. Asi hay UN solo lugar donde esta la consulta."""
        try:
            if not (self.waiting_for_input and self.multiline_box_frame.isVisible()):
                return
            current = self.txt_multiline_goal.toPlainText()
            if current.strip() and current != self._goal_autofill_text:
                return  # el usuario ya escribio/pego algo propio: no se pisa
            clip = (QApplication.clipboard().text() or "").strip()
            if clip:
                self._goal_autofill_text = clip
                self.txt_multiline_goal.setPlainText(clip)
        except Exception:
            pass

    def _present_prompt(self, prompt_spec: dict):
        self.waiting_for_input = True
        if hasattr(self, "lbl_timer") and not self.elapsed_timer.isActive():
            last_t = getattr(self, "last_run_time_str", "")
            if last_t:
                self.lbl_timer.setText(f"⏱️ Listo ({last_t})")
            else:
                self.lbl_timer.setText("⏱️ Listo")
        prompt_text = prompt_spec.get("prompt", "Selecciona una opcion")
        self.lbl_prompt.setText(f"{prompt_text}: ")
        self.btn_enter.setEnabled(True)

        show_ml = prompt_spec.get("show_multiline_goal", False)
        self.multiline_box_frame.setVisible(show_ml)
        # En el paso de la consulta el cuadro multilinea es el UNICO lugar de entrada: la linea de abajo
        # (QLineEdit, tope de 32767 caracteres) se deshabilita para que nunca recorte una consulta larga.
        self.txt_input.setEnabled(not show_ml)
        self.txt_input.clear()
        if show_ml:
            prefill = prompt_spec.get("goal_prefill", "") or ""
            self._goal_autofill_text = prefill
            self.txt_multiline_goal.setPlainText(prefill)
            self.txt_multiline_goal.setFocus()
            self.txt_multiline_goal.moveCursor(QTextCursor.MoveOperation.End)
        else:
            self.txt_input.setFocus()

        self._set_quick_buttons(prompt_spec.get("buttons", []))
        self.scroll_console_to_bottom()
        QTimer.singleShot(0, self.scroll_console_to_bottom)
        QTimer.singleShot(60, self.scroll_console_to_bottom)

    def on_submit_input(self):
        if not self.waiting_for_input:
            return
        if self.multiline_box_frame.isVisible():
            val = self.txt_multiline_goal.toPlainText().strip()
        else:
            val = self.txt_input.text().strip()
        self.submit_value(val)

    def submit_value(self, value: str):
        if not self.waiting_for_input or not self.active_generator:
            return
        self.waiting_for_input = False
        self.multiline_box_frame.setVisible(False)
        display_echo = value if value else "[ENTER]"
        if len(display_echo) > 120:
            display_echo = display_echo[:120] + "..."
        self.console_write(f"{self.lbl_prompt.text()}{display_echo}", "DarkGray")
        self._advance_generator(value)

    def _advance_generator(self, send_val=None, error=None):
        if not self.active_generator:
            return
        if self.active_generator.gi_running:
            # [G2] un bucle de eventos anidado (p.ej. dlg.exec() dentro de un paso) intento reentrar al generador:
            # se reintenta en cuanto el paso actual termine, en vez de lanzar "generator already executing".
            QTimer.singleShot(0, lambda: self._advance_generator(send_val, error))
            return
        try:
            if error is not None:
                # [FIX C3] el fallo del worker se propaga al generador con su causa real
                step_spec = self.active_generator.throw(RuntimeError(error))
            elif send_val is None:
                step_spec = next(self.active_generator)
            else:
                step_spec = self.active_generator.send(send_val)
            self._handle_generator_yield(step_spec)
        except StopIteration:
            self.active_generator = None
        except Exception as e:
            self.active_generator = None
            self.console_write(f"\n[ERROR INTERNO] {e}", "Red")
            self.start_main_menu()

    def _handle_generator_yield(self, spec):
        spec = as_spec(spec)
        kind = spec.get("kind", "prompt")
        if kind == "prompt":
            self._present_prompt(spec)
        elif kind == "async":
            self.waiting_for_input = False
            self.txt_input.setEnabled(False)
            self.btn_enter.setEnabled(False)
            self._set_quick_buttons([])
            self.lbl_prompt.setText(spec.get("status_label", "Procesando en R / IA..."))
            self.progress_bar.setVisible(True)
            self.elapsed_seconds = 0
            self.elapsed_timer.start(1000)

            fn = spec["fn"]
            args = spec.get("args", ())
            kwargs = dict(spec.get("kwargs", {}))
            stream_lines = spec.get("stream_lines", False)
            stream_tokens = spec.get("stream_tokens", False)

            worker = AsyncTaskWorker(fn, *args, **kwargs)
            if stream_lines:
                worker.kwargs["on_line"] = worker.line_signal.emit
                worker.line_signal.connect(self.console_write)
            if stream_tokens:
                worker.kwargs["on_token"] = worker.token_signal.emit
                worker.token_signal.connect(
                    lambda t, c: self.console_write(t, c, newline=False)
                )

            worker.done_signal.connect(self._on_async_done)
            self._track(worker)
            self.current_worker = worker
            self._cancel_requested = False
            charly_engine.CANCEL_EVENT.clear()
            self.btn_cancel.setEnabled(True)
            self.btn_cancel.setVisible(True)
            worker.start()

    def _on_async_done(self, payload: dict):
        self.elapsed_timer.stop()
        self.progress_bar.setVisible(False)
        self.btn_cancel.setVisible(False)
        self.current_worker = None  # el QThread sigue en self._workers hasta 'finished'
        if self._cancel_requested:
            self.in_analysis_pipeline = False
            self.last_run_time_str = ""
            if hasattr(self, "lbl_timer"):
                self.lbl_timer.setText("⏱️ Listo")
            self._cancel_requested = False
            self.console_write("\n[CANCELADO] Operacion cancelada por el usuario.", "Yellow")
            if self.active_generator is not None:
                self.active_generator.close()
                self.active_generator = None
            self.start_main_menu()
            return
        if not payload.get("ok", False):
            self.console_write(f"\n[ERROR] {payload.get('error')}", "Red")
            self._advance_generator(error=payload.get("error") or "Fallo desconocido")
        else:
            self._advance_generator(payload.get("result"))

    # =========================================================================
    # MENÚ PRINCIPAL (LÍNEAS 1978-2032 DE charly_core.ps1)
    # =========================================================================
    def start_main_menu(self):
        self.in_analysis_pipeline = False
        self.last_run_time_str = ""
        if hasattr(self, "lbl_timer"):
            self.lbl_timer.setText("⏱️ Listo")
        if self.current_worker and self.current_worker.isRunning():
            self._cancel_current()  # antes: el boton quedaba muerto hasta que terminara el worker
            return
        self.tabs.setCurrentIndex(0)
        self.active_generator = self._main_loop_generator()
        self._advance_generator(None)

    def _main_loop_generator(self):
        while True:
            self.console_clear()
            self.console_write_lines(charly_engine.get_main_menu_lines())

            opt = (
                yield {
                    "kind": "prompt",
                    "prompt": "Selecciona una opcion (1-4, D, M para Modelos, 0 para salir)",
                    "buttons": [
                        (
                            "[1] Nube Ultrarrapida (Gemini Flash) [Recomendado]",
                            "1",
                            "btn_default",
                        ),
                        ("[2] Local Privado / Offline (Seru Giran)", "2", ""),
                        ("[3] Ver Resultados (Consola R completa)", "3", "btn_secondary"),
                        ("[4] Ver Codigo R", "4", "btn_secondary"),
                        ("[D] o [5] Descriptivos de Datos", "D", "btn_warn"),
                        ("[M] o [6] Modelos Soportados", "M", "btn_warn"),
                        ("[S] Estado del Sistema", "S", "btn_secondary"),
                        ("[0] o [Q] Salir", "0", "btn_danger"),
                    ],
                }
            ).strip()

            opt_u = opt.upper()
            if opt_u == "1":
                yield from self._run_pipeline_generator("cloud")
            elif opt_u == "2":
                _srv_up = yield {
                    "kind": "async",
                    "status_label": "Verificando el servidor de IA local...",
                    "fn": charly_engine.test_local_server,
                }
                if not _srv_up:
                    self.console_write(
                        "\n[AVISO] La IA Local esta apagada. Encendiendo automaticamente...",
                        "Yellow",
                    )
                    yield {
                        "kind": "async",
                        "status_label": "Encendiendo servidor local Seru Giran (Qwen3.6-35B-A3B MoE)...",
                        "fn": charly_engine.run_local_server_action,
                        "args": ("start",),
                    }
                yield from self._run_pipeline_generator("local")
            elif opt_u == "3":
                res_f = charly_engine.V4_WORKSPACE / "consola_rstudio_completa.txt"
                if res_f.exists():
                    subprocess.Popen(["notepad.exe", str(res_f.resolve())])
                    self._refresh_result_tabs_from_disk()
                else:
                    self.console_write(
                        "Aun no se ha generado ningun reporte de resultados.",
                        "Yellow",
                    )
                    yield continue_prompt()
            elif opt_u == "4":
                script_f = charly_engine.V4_WORKSPACE / "generated_script.R"
                if script_f.exists():
                    subprocess.Popen(["notepad.exe", str(script_f.resolve())])
                    self._refresh_result_tabs_from_disk()
                else:
                    self.console_write(
                        "Aun no se ha generado ningun script R en workspace/generated_script.R.",
                        "Yellow",
                    )
                    yield continue_prompt()
            elif opt_u in ("D", "5"):
                yield from self._show_data_descriptives_generator()
            elif opt_u in ("M", "6", "7"):
                self.console_clear()
                self.console_write_lines(charly_engine.get_model_catalog_lines())
                yield continue_prompt()
            elif opt_u == "S":
                self.console_clear()
                _status_lines = yield {
                    "kind": "async",
                    "status_label": "Consultando el estado del sistema...",
                    "fn": charly_engine.get_status_lines,
                }
                self.console_write_lines(_status_lines or [])
                yield continue_prompt()
            elif opt_u in ("0", "Q"):
                self.close()
                QApplication.quit()
                return
            else:
                self.console_write("Opcion invalida.", "Red")
                yield continue_prompt()

    # =========================================================================
    # Show-DataDescriptives (LÍNEAS 1868-1916 DE charly_core.ps1)
    # =========================================================================
    def _show_data_descriptives_generator(self):
        self.console_clear()
        self.console_write_lines(charly_engine.get_banner_lines())
        self.console_write(
            "\n>>> RADIOGRAFIA DESCRIPTIVA DE LA BASE DE DATOS:", "Magenta"
        )
        self.console_write(
            "Inspecciona variables, rangos, frecuencias completas, NAs y detecta valores atipicos.",
            "Gray",
        )
        self.console_write("", "White")

        prof = charly_engine.load_dataset_profile_json()
        last_used = str(
            prof.get("archivo_original") or prof.get("archivo") or ""
        ).strip()
        default_prompt = f" [ENTER para '{last_used}']" if last_used else ""

        user_input = (
            yield {
                "kind": "prompt",
                "prompt": f"Escribe el nombre o ruta del archivo de datos (o arrastralo aqui){default_prompt}",
                "buttons": (
                    [
                        (
                            f"[ENTER] Usar '{Path(last_used).name}'",
                            "",
                            "btn_default",
                        )
                    ]
                    if last_used
                    else []
                )
                + [("📂 Examinar archivo...", "__BROWSE_FILE__", "")],
            }
        ).strip()

        if not user_input:
            user_input = last_used

        if not user_input:
            self.console_write("No se especifico ningun archivo.", "Yellow")
            yield continue_prompt()
            return

        target_file = yield {
            "kind": "async",
            "status_label": "Buscando el archivo de datos...",
            "fn": charly_engine.find_dataset_file,
            "args": (user_input,),
        }
        if not target_file or not os.path.isfile(target_file):
            if os.path.isfile(user_input):
                target_file = str(Path(user_input).resolve())

        if not target_file or not os.path.isfile(target_file):
            self.console_write(
                f"No se pudo encontrar el archivo '{user_input}'.", "Red"
            )
            yield continue_prompt()
            return

        file_name = Path(target_file).name
        self.console_write(
            f"\n[ANALIZADOR] Generando radiografia descriptiva de '{file_name}'...",
            "Cyan",
        )

        desc_res = yield {
            "kind": "async",
            "status_label": f"[ANALIZADOR] Generando radiografía descriptiva de '{file_name}'...",
            "fn": charly_engine.run_data_descriptives,
            "args": (target_file,),
        }

        if desc_res and desc_res.get("success"):
            if desc_res.get("report_text"):
                self.console_write("", "White")
                self.console_write(desc_res["report_text"], "White")
            self.console_write(
                "\n[OK] Informe descriptivo generado. Abriendo en el Bloc de Notas...",
                "Green",
            )
        else:
            self.console_write(
                "\nError al generar el informe descriptivo.", "Red"
            )
            if desc_res and desc_res.get("output"):
                self.console_write(desc_res["output"], "Red")

        self.console_write("", "White")
        yield continue_prompt()

    # =========================================================================
    # Get-UserPsychometricGoal (LÍNEAS 732-842 DE charly_core.ps1)
    # =========================================================================
    def _get_user_psychometric_goal_generator(self):
        goal_path = charly_engine.V4_WORKSPACE / "user_goal.txt"

        def _clipboard_now() -> str:
            # El portapapeles se lee EN EL MOMENTO de mostrar el cuadro (despues del "Entendido"), no al
            # abrir el paso: asi sirve igual si la consulta se copio antes o despues de leer los arquetipos.
            try:
                return (QApplication.clipboard().text() or "").strip()
            except Exception:
                return ""

        clip_text = ""
        acknowledged = False
        while True:
            self.console_clear()
            self.console_write_lines(
                charly_engine.get_step1_archetypes_banner_lines()
            )

            # Confirmacion obligatoria: sin leer las reglas y el catalogo no se puede cargar la consigna.
            if not acknowledged:
                yield continue_prompt(
                    "Paso 1 de 2: Para continuar, confirmá",
                    "[ Entendido: He leído las reglas y el catálogo ]",
                )
                self.console_write("", "White")
                self.console_write(
                    "⚠️ VERIFICACIÓN IMPORTANTE: ¿Estás seguro de que leíste todo completo y de forma comprensiva?",
                    "Yellow",
                )
                self.console_write(
                    "   Asegurate de haber revisado las reglas, los 10 arquetipos y el Catálogo de Consignas",
                    "Yellow",
                )
                self.console_write(
                    "   (botón superior) con ejemplos testeados para inspirar la redacción de tu consulta.",
                    "Yellow",
                )
                self.console_write(
                    "   Esto es indispensable para que el sistema pueda ayudarte con éxito.",
                    "Yellow",
                )
                yield continue_prompt(
                    "Paso 2 de 2: Confirmación de lectura comprensiva",
                    "[ Sí, leí todo completo y comprensivamente, deseo continuar ]",
                )
                acknowledged = True
                continue

            clip_text = _clipboard_now()
            self.console_write(
                "Pega tu consulta en el cuadro de abajo (si ya la habias copiado con Ctrl+C, aparece sola; "
                "si la copias ahora, tambien) y presiona [ENTER] o Ctrl+Enter.",
                "Gray",
            )

            input_val = yield {
                "kind": "prompt",
                "prompt": ">",
                "show_multiline_goal": True,
                "goal_prefill": clip_text,
                "buttons": [
                    (
                        "[ENTER] Usar esta consulta",
                        "__SUBMIT_INPUT__",
                        "btn_default",
                    ),
                    ("[B] Abrir Bloc de Notas", "B", ""),
                    ("[V] Ventana Grafica de Texto", "V", ""),
                ],
            }

            trimmed = input_val.strip() if input_val else ""

            # Caso 2: Opción 'B' (Bloc de Notas)
            if trimmed.lower() in ("b", "n"):
                self.console_write(
                    "\n[SISTEMA] Abriendo el Bloc de Notas... Pega tu texto ahi, guarda (Ctrl+G) y cierralo.",
                    "Yellow",
                )
                if clip_text and not goal_path.exists():
                    goal_path.write_text(clip_text, encoding="utf-8")
                elif not goal_path.exists():
                    goal_path.write_text("", encoding="utf-8")
                yield {
                    "kind": "async",
                    "status_label": "Esperando cierre del Bloc de Notas (workspace/user_goal.txt)...",
                    "fn": lambda: charly_engine.wait_process(
                        ["notepad.exe", str(goal_path)]
                    ),
                }
                if goal_path.exists():
                    saved = goal_path.read_text(
                        encoding="utf-8-sig", errors="replace"
                    ).strip()
                    if saved:
                        self.console_write(
                            "[OK] Instruccion leida exitosamente desde el Bloc de Notas.",
                            "Green",
                        )
                        charly_engine.sync_workspaces(from_v4_to_app=True)
                        return saved
                self.console_write(
                    "[AVISO] No se guardo texto en el Bloc de Notas.", "Yellow"
                )
                continue

            # Caso 3: Opción 'V' (Ventana Gráfica)
            if trimmed.lower() == "v":
                preset = clip_text if clip_text else ""
                dlg = ShowInputWindowDialog(self, preset)
                if dlg.exec() == QDialog.DialogCode.Accepted:
                    win_text = dlg.get_text()
                    if win_text:
                        self.console_write(
                            "\n[OK] Instruccion recibida desde la ventana grafica.",
                            "Green",
                        )
                        goal_path.write_text(win_text, encoding="utf-8")
                        charly_engine.sync_workspaces(from_v4_to_app=True)
                        return win_text
                self.console_write(
                    "[AVISO] Ventana cancelada o sin texto.", "Yellow"
                )
                continue

            # Caso 4: Escribió o pegó texto en la consola
            if trimmed:
                if trimmed.lower() == "salir":
                    return None
                if re.match(r"^\[?[1-6]\]?$", trimmed) or re.match(
                    r"(?i)^opci[oó]n\s*[1-6]$", trimmed
                ):
                    self.console_write(
                        f"\n[AVISO] Has ingresado solo una opcion de menu ('{trimmed}'). Aqui debes escribir o pegar tu CONSULTA ESTADISTICA completa en el cuadro de abajo.",
                        "Yellow",
                    )
                    yield continue_prompt("Presiona ENTER para reintentar", "[ENTER] Reintentar")
                    continue
                goal_path.write_text(trimmed, encoding="utf-8")
                charly_engine.sync_workspaces(from_v4_to_app=True)
                return trimmed

            self.console_write(
                "\n[AVISO] No ingresaste ninguna instruccion. Intenta nuevamente o presiona B para Bloc de Notas.",
                "Yellow",
            )
            yield continue_prompt("Presiona ENTER para reintentar", "[ENTER] Reintentar")

    # =========================================================================
    # Run-Pipeline (LÍNEAS 891-1842 DE charly_core.ps1)
    # =========================================================================
    def _run_pipeline_generator(self, engine: str):
        charly_engine.set_active_engine(engine)
        self.console_clear()
        self.console_write_lines(charly_engine.get_banner_lines())
        self.console_write(
            ">>> INICIANDO PIPELINE PSICOMETRICO AUTONOMO...", "Yellow"
        )

        # 0. Limpieza de estado previo
        charly_engine.clean_stale_artifacts()

        # 1. Solicitud de instrucción psicométrica
        custom_goal = None
        while True:
            custom_goal = yield from self._get_user_psychometric_goal_generator()
            if not custom_goal or not custom_goal.strip():
                self.console_write("\nOperacion cancelada.", "Yellow")
                yield continue_prompt()
                return

            goal_words = len([w for w in re.split(r"\s+", custom_goal) if w])
            if goal_words > 500 and engine != "cloud":
                self.console_write("", "White")
                self.console_write(
                    "==========================================================================",
                    "Yellow",
                )
                self.console_write(
                    f" AVISO DE EXTENSION DE CONSULTA ({goal_words} palabras)",
                    "Yellow",
                )
                self.console_write(
                    "==========================================================================",
                    "Yellow",
                )
                self.console_write(
                    f" Tu consulta tiene {goal_words} palabras. Para que Seru Giran (IA local)",
                    "White",
                )
                self.console_write(
                    " genere codigo R de alta calidad sin desbordar el contexto, te sugerimos:",
                    "White",
                )
                self.console_write("", "White")
                self.console_write(
                    "   1) Sintetizar la consulta manteniendo las especificaciones conceptuales centrales.",
                    "Cyan",
                )
                self.console_write(
                    "   2) O estructurarla en solicitudes secuenciales (primero el modelo de medida y luego la estructura).",
                    "Cyan",
                )
                self.console_write("", "White")
                self.console_write(
                    " (Con Gemini en la nube no hay limite de extension).",
                    "Green",
                )
                self.console_write(
                    "==========================================================================",
                    "Yellow",
                )
                continuar = (
                    yield {
                        "kind": "prompt",
                        "prompt": " Continuar con esta consulta de todas formas? (S = si / N = reescribir)",
                        "buttons": [
                            ("[S] Si, continuar", "S", "btn_warn"),
                            ("[N] Reescribir", "N", "btn_default"),
                        ],
                    }
                ).strip()
                if continuar.upper() != "S":
                    goal_path = charly_engine.V4_WORKSPACE / "user_goal.txt"
                    if goal_path.exists():
                        goal_path.write_text("", encoding="utf-8")
                    continue
            break

        # Detección exhaustiva de solicitud de invarianza o DIF -> Advertencia metodológica obligatoria
        invariance_synonyms = r"(?i)\b(mimic|invarianz?a|invariante|invariance|dif\b|diff\b|sesgo\s+de\s+[ií]tems?|sesgo\s+de\s+reactivos?|sesgo\s+de\s+medici[oó]n|multigrupo|multi-group|multigroup|configural|escalar|estricta|invarianza\s+m[eé]trica|equivalencia\s+de\s+medida|equivalencia\s+factorial|funcionamiento\s+diferencial|comparaci[oó]n\s+entre\s+grupos|diferencias?\s+entre\s+grupos\s+en\s+(?:la\s+)?medida)\b"
        # DIF solo si la consigna lo pide (un MIMIC sin DIF no evalua DIF)
        dif_regex = r"(?i)\b(?:dif|diff|funcionamiento\s+diferencial|score\s+test|sesgo|invarianz\w*|invarianc\w*|invariance|multigrupo|multi-group|multigroup|configural|escalar|equivalencia\s+(?:de\s+medida|factorial))\b"
        pre_parsed = yield {
            "kind": "async",
            "status_label": "Analizando arquetipo inicial...",
            "fn": charly_engine.parse_directives_and_archetype,
            "args": (custom_goal,),
        }
        pre_archetype = (pre_parsed or {}).get("CanonicalArchetype", "")
        non_mimic_archs = {
            "AFC_Primer_Orden",
            "AFC_Segundo_Orden",
            "Bifactor",
            "SEM_Senderos",
            "SEM_NoRecursivo",
            "ACP",
            "AFE",
            "Regresion_Logistica",
            "Regresion_Probit",
        }
        if re.search(dif_regex, custom_goal) and (
            pre_archetype == "MIMIC"
            or (
                re.search(invariance_synonyms, custom_goal)
                and pre_archetype not in non_mimic_archs
            )
        ):
            self.console_write("", "White")
            self.console_write(
                "==========================================================================",
                "Cyan",
            )
            self.console_write(
                " [AVISO METODOLOGICO CHARLY]: INVARIANZA Y DIF EXCLUSIVA CON MODELOS MIMIC",
                "Yellow",
            )
            self.console_write(
                "==========================================================================",
                "Cyan",
            )
            self.console_write(
                " Has solicitado evaluar Invarianza de Medicion / Funcionamiento Diferencial (DIF).",
                "White",
            )
            self.console_write(
                " En este sistema, la evaluacion se realiza EXCLUSIVAMENTE mediante MODELOS",
                "White",
            )
            self.console_write(
                " MIMIC (Multiple Indicators Multiple Causes; Muthen, 1989) con Score Test",
                "White",
            )
            self.console_write(
                " univariado iterativo (1 gl por reactivo), preservando el N muestral completo",
                "White",
            )
            self.console_write(
                " y evitando la fragmentacion por subgrupos o celdas ordinales vacias.",
                "White",
            )
            self.console_write(
                " Quedan desestimados los modelos multigrupo por riesgo de colapso asintotico.",
                "DarkGray",
            )
            self.console_write(
                "==========================================================================",
                "Cyan",
            )
            self.console_write("", "White")

        # Bloqueo preventivo de conflicto Probit vs Logit
        if re.search(r"(?i)\bprobit\b", custom_goal) and re.search(
            r"(?i)log[ií]stic[oa]", custom_goal
        ):
            self.console_write("", "White")
            self.console_write(
                "==========================================================================",
                "Red",
            )
            self.console_write(
                " [ERROR]: CONFLICTO DE ENLACES (PROBIT Y LOGIT)", "Yellow"
            )
            self.console_write(
                "==========================================================================",
                "Red",
            )
            self.console_write(
                " Has solicitado modelos PROBIT y LOGISTICA en la misma instruccion.",
                "White",
            )
            self.console_write(
                " LIMITACION 11: No esta permitido mezclar Probit y Logit en la misma orden.",
                "Cyan",
            )
            self.console_write(
                " Por favor, separa tu pedido en dos instrucciones distintas y vuelve a",
                "White",
            )
            self.console_write(" ejecutar Charly.", "White")
            self.console_write(
                "==========================================================================",
                "Red",
            )
            self.console_write(
                "\n[SISTEMA] Ejecucion abortada por violacion de reglas metodologicas.",
                "Yellow",
            )
            yield continue_prompt()
            return

        # Bloqueo preventivo de tareas secuenciales dependientes
        secuencial_regex = r"(?i)(seg[uú]n\s+(?:el\s+)?resultado|dependiendo\s+de|una\s+vez\s+que\s+(?:termin|teng|sep)|en\s+funci[oó]n\s+d(?:e|el)\s+resultado|a\s+partir\s+d(?:e|el)\s+resultado)"
        if re.search(secuencial_regex, custom_goal):
            self.console_write("", "White")
            self.console_write(
                "==========================================================================",
                "Red",
            )
            self.console_write(
                " [ERROR]: TAREAS SECUENCIALES CONDICIONALES DETECTADAS",
                "Yellow",
            )
            self.console_write(
                "==========================================================================",
                "Red",
            )
            self.console_write(
                " Tu instruccion parece exigir ver el dato de un paso para hacer el siguiente.",
                "White",
            )
            self.console_write(
                " LIMITACION 11: Charly no puede tomar decisiones iterativas en el medio.",
                "Cyan",
            )
            self.console_write(
                " Por favor, pide el primer paso, mira los resultados, y luego pide el",
                "White",
            )
            self.console_write(
                " siguiente paso en una nueva corrida.", "White"
            )
            self.console_write(
                "==========================================================================",
                "Red",
            )
            self.console_write(
                "\n[SISTEMA] Ejecucion abortada por violacion de reglas metodologicas.",
                "Yellow",
            )
            yield continue_prompt()
            return

        # 2. Identificación dinámica e inteligente del archivo de datos
        target_file = yield {
            "kind": "async",
            "status_label": "Identificando el archivo de datos...",
            "fn": charly_engine.find_dataset_file,
            "args": (custom_goal,),
        }
        if target_file:
            matched_name = Path(target_file).name
            self.console_write(
                f"\n[ANALISIS DE SOLICITUD] Archivo identificado automaticamente: '{matched_name}'",
                "Green",
            )
            self.console_write(f"  Ruta origen: {target_file}", "DarkGray")
        else:
            while not target_file or not os.path.isfile(target_file):
                self.console_write(
                    "\n[AVISO] No se pudo identificar automaticamente el archivo de datos en tu instruccion.",
                    "Yellow",
                )
                user_input_path = (
                    yield {
                        "kind": "prompt",
                        "prompt": "Por favor, escribe la ruta o nombre del archivo de datos a analizar (o 'salir')",
                        "buttons": [
                            (
                                "📂 Examinar archivo de datos...",
                                "__BROWSE_FILE__",
                                "btn_default",
                            ),
                            ("Salir", "salir", "btn_danger"),
                        ],
                    }
                ).strip()
                if user_input_path.lower() == "salir":
                    return

                if len(user_input_path) > 25 and re.search(
                    r"(?i)base|modelo|hace|regresion|cfa|sem|variables|probit",
                    user_input_path,
                ):
                    custom_goal = user_input_path
                    (charly_engine.V4_WORKSPACE / "user_goal.txt").write_text(
                        custom_goal, encoding="utf-8"
                    )
                    self.console_write(
                        "[OK] Consulta del investigador actualizada correctamente.",
                        "Green",
                    )

                resolved = yield {
                    "kind": "async",
                    "status_label": "Buscando el archivo de datos...",
                    "fn": charly_engine.find_dataset_file,
                    "args": (user_input_path,),
                }
                if resolved and os.path.isfile(resolved):
                    target_file = resolved
                elif os.path.isfile(user_input_path):
                    target_file = str(Path(user_input_path).resolve())

        self.current_dataset_path = target_file

        # 3. Crear copia de trabajo segura
        safe_data_file, copy_msg = charly_engine.create_safe_working_copies(
            target_file
        )
        self.console_write(copy_msg, "DarkGray")

        # 4. Pilar 1: Radiografía Descriptiva y Configuración Metodológica Guiada
        goal_path = charly_engine.V4_WORKSPACE / "user_goal.txt"
        confirmed_and_ready = False
        method_specs = ""

        while not confirmed_and_ready:
            self.console_write(
                f"\n[PASO 2/5] Radiografia empirica de variables en '{target_file}':",
                "Cyan",
            )
            prof_res = yield {
                "kind": "async",
                "status_label": "[PASO 2/5] Ejecutando radiografía empírica de variables en R...",
                "fn": charly_engine.run_data_profiler,
                "args": (safe_data_file, target_file, custom_goal),
            }
            if not prof_res or not prof_res.get("success"):
                self.console_write("Error en el perfilado de datos.", "Red")
                if prof_res and prof_res.get("stdout"):
                    self.console_write(prof_res["stdout"], "Red")
                yield continue_prompt()
                return

            self._render_profiler_stdout(prof_res["stdout"])

            # 4.05 Checkpoint de Verificación Explícita de Variables Identificadas
            focal_vars = prof_res.get("focalized_vars") or []
            if focal_vars:
                self.console_write("", "White")
                self.console_write(
                    "==========================================================================",
                    "DarkCyan",
                )
                self.console_write(
                    " [CHEQUEO DE VARIABLES IDENTIFICADAS PARA EL MODELO]",
                    "Yellow",
                )
                self.console_write(
                    "==========================================================================",
                    "DarkCyan",
                )
                self.console_write(
                    f" Columnas reales detectadas: {', '.join(focal_vars)}",
                    "White",
                )
                self.console_write(
                    f" Total variables analizadas: {len(focal_vars)}", "Gray"
                )
                self.console_write(
                    "==========================================================================",
                    "DarkCyan",
                )
                check_vars = (
                    yield {
                        "kind": "prompt",
                        "prompt": " Confirmas que estas variables son las correctas? (ENTER = Si / M = Modificar lista)",
                        "buttons": [
                            (
                                "[ENTER] Si, confirmar variables",
                                "",
                                "btn_default",
                            ),
                            ("[M] Modificar lista", "M", "btn_warn"),
                        ],
                    }
                ).strip()
                if check_vars.upper() == "M":
                    new_vars = (
                        yield {
                            "kind": "prompt",
                            "prompt": " Ingresa las variables deseadas separadas por coma",
                            "buttons": [],
                        }
                    ).strip()
                    if new_vars:
                        custom_goal += f"\r\nVariables especificadas expresamente por el investigador: {new_vars}"
                        goal_path.write_text(custom_goal, encoding="utf-8")
                        continue

            # 4.08 Directivas de Senderos y Mediaciones para el Modelo
            parsed_info = yield {
                "kind": "async",
                "status_label": "Analizando directivas psicométricas...",
                "fn": charly_engine.parse_directives_and_archetype,
                "args": (custom_goal,),
            }
            canonical_archetype = (parsed_info or {}).get(
                "CanonicalArchetype", "AFC_Primer_Orden"
            )
            arrow_directives = (parsed_info or {}).get("ArrowDirectives") or []
            mediation_directives_list = (
                (parsed_info or {}).get("MediationDirectives") or []
            )
            total_effects_directives_list = (
                (parsed_info or {}).get("TotalEffectsDirectives") or []
            )

            # 4.1 Checkpoint de Configuración Metodológica Interactivamente Guiada
            self.console_write("", "White")
            self.console_write(
                "==========================================================================",
                "Cyan",
            )
            self.console_write(
                " CONFIGURACION METODOLOGICA (Presiona ENTER para aceptar la opcion sugerida)",
                "Yellow",
            )
            self.console_write(
                "==========================================================================",
                "Cyan",
            )

            is_exploratory = canonical_archetype in ("ACP", "AFE")
            is_direct_regression = canonical_archetype in (
                "Regresion_Logistica",
                "Regresion_Probit",
            )

            clean_na_codes = ""
            inversion_directive = ""
            continuous_exc_directive = ""
            category_clean_directive = ""
            selected_estimator = "WLSMV"
            selected_missing = "pairwise"

            # -----------------------------------------------------------------
            # FAMILIA 1: EXPLORATORIOS (ACP / AFE)
            # -----------------------------------------------------------------
            if is_exploratory:
                self.console_write(
                    " [FAMILIA DETECTADA]: Modelos Exploratorios y Reduccion (Libreria psych)",
                    "Green",
                )
                self.console_write(
                    "                      (AFE con fa() y/o Componentes Principales con principal())",
                    "Gray",
                )
                self.console_write("", "White")

                has_afe = bool(
                    re.search(
                        r"(?i)(?:afe\b|factor(?:ial)?\s+explorat|fa\(|ejes\s+principales|minres)",
                        custom_goal,
                    )
                )
                has_acp = bool(
                    re.search(
                        r"(?i)(?:acp\b|pca\b|componentes?\s+princip|principal\s+components|principal\()",
                        custom_goal,
                    )
                )
                if not has_afe and not has_acp:
                    has_afe = True

                selected_extract = "minres"
                if has_afe:
                    default_extract = "1"
                    if re.search(
                        r"(?i)\bpa\b|\bejes\s+principales\b", custom_goal
                    ):
                        default_extract = "2"
                    elif re.search(
                        r"(?i)\bml\b|\bmaxima\s+verosimilitud\b", custom_goal
                    ):
                        default_extract = "3"

                    self.console_write(
                        " 1. Metodo de extraccion para Analisis Factorial Exploratorio (fa):",
                        "White",
                    )
                    if has_acp:
                        self.console_write(
                            "    (En ACP la extraccion no tiene opciones porque es algebraica y exacta: descomposicion espectral de autovalores)",
                            "DarkGray",
                        )
                    self.console_write(
                        "    [1] minres (Residuos minimos - Recomendado y por defecto) [DEFAULT]",
                        "Green" if default_extract == "1" else "Gray",
                    )
                    self.console_write(
                        "    [2] pa     (Ejes principales - Principal Axis Factoring)",
                        "Green" if default_extract == "2" else "Gray",
                    )
                    self.console_write(
                        "    [3] ml     (Maxima verosimilitud clasica)",
                        "Green" if default_extract == "3" else "Gray",
                    )
                    extract_in = (
                        yield {
                            "kind": "prompt",
                            "prompt": f"    Selecciona (1-3) [ENTER = {default_extract}]",
                            "buttons": [
                                (
                                    f"[ENTER] Default ({default_extract})",
                                    "",
                                    "btn_default",
                                ),
                                ("[1] minres", "1", ""),
                                ("[2] pa", "2", ""),
                                ("[3] ml", "3", ""),
                            ],
                        }
                    ).strip()
                    if not extract_in:
                        extract_in = default_extract
                    selected_extract = {"2": "pa", "3": "ml"}.get(
                        extract_in, "minres"
                    )

                # B. Rotación(es) para AFE y/o ACP
                goal_norm_rot = _strip_accents(custom_goal)
                detected_afe_rot = ""
                detected_acp_rot = ""

                m_pre_afe = re.search(
                    r"(?i)\b(promax|varimax|oblimin|none)\b\s+(?:para|en)\s+(?:el\s+)?(?:afe|factorial|analisis\s+factorial)",
                    goal_norm_rot,
                )
                if m_pre_afe:
                    detected_afe_rot = m_pre_afe.group(1).lower()

                m_pre_acp = re.search(
                    r"(?i)\b(promax|varimax|oblimin|none)\b\s+(?:para|en)\s+(?:el\s+)?(?:acp|pca|componentes)",
                    goal_norm_rot,
                )
                if m_pre_acp:
                    detected_acp_rot = m_pre_acp.group(1).lower()

                if has_afe and has_acp:
                    self.console_write(
                        "\n 2. Rotaciones diferenciadas para AFE y ACP:",
                        "White",
                    )
                    self.console_write(
                        "    (Permite configurar rotaciones independientes, ej. Oblimin oblicua para AFE y Varimax ortogonal para ACP)",
                        "DarkGray",
                    )
                    default_afe_rot = {
                        "promax": "2",
                        "varimax": "3",
                        "none": "4",
                    }.get(detected_afe_rot, "1")
                    self.console_write(
                        "\n    2.a Rotacion para Analisis Factorial Exploratorio (fa):",
                        "White",
                    )
                    self.console_write(
                        f"        [1] oblimin (Oblicua directa - Recomendada para factores que correlacionan){' [DEFAULT]' if default_afe_rot == '1' else ''}",
                        "Green" if default_afe_rot == "1" else "Gray",
                    )
                    self.console_write(
                        f"        [2] promax  (Oblicua clasica){' [DEFAULT]' if default_afe_rot == '2' else ''}",
                        "Green" if default_afe_rot == "2" else "Gray",
                    )
                    self.console_write(
                        f"        [3] varimax (Ortogonal - Factores independientes a 90 grados){' [DEFAULT]' if default_afe_rot == '3' else ''}",
                        "Green" if default_afe_rot == "3" else "Gray",
                    )
                    self.console_write(
                        f"        [4] none    (Sin rotacion){' [DEFAULT]' if default_afe_rot == '4' else ''}",
                        "Green" if default_afe_rot == "4" else "Gray",
                    )
                    rot_afe_in = (
                        yield {
                            "kind": "prompt",
                            "prompt": f"        Selecciona rotacion AFE (1-4) [ENTER = {default_afe_rot}]",
                            "buttons": [
                                (
                                    f"[ENTER] Default ({default_afe_rot})",
                                    "",
                                    "btn_default",
                                ),
                                ("[1] oblimin", "1", ""),
                                ("[2] promax", "2", ""),
                                ("[3] varimax", "3", ""),
                                ("[4] none", "4", ""),
                            ],
                        }
                    ).strip()
                    if not rot_afe_in:
                        rot_afe_in = default_afe_rot
                    selected_afe_rot = {
                        "2": "promax",
                        "3": "varimax",
                        "4": "none",
                    }.get(rot_afe_in, "oblimin")

                    default_acp_rot = {
                        "oblimin": "1",
                        "promax": "2",
                        "none": "4",
                    }.get(detected_acp_rot, "3")
                    self.console_write(
                        "\n    2.b Rotacion para Analisis de Componentes Principales (principal):",
                        "White",
                    )
                    self.console_write(
                        f"        [1] oblimin (Oblicua directa){' [DEFAULT]' if default_acp_rot == '1' else ''}",
                        "Green" if default_acp_rot == "1" else "Gray",
                    )
                    self.console_write(
                        f"        [2] promax  (Oblicua clasica){' [DEFAULT]' if default_acp_rot == '2' else ''}",
                        "Green" if default_acp_rot == "2" else "Gray",
                    )
                    self.console_write(
                        f"        [3] varimax (Ortogonal - Estandar para maximizar varianza de componentes){' [DEFAULT]' if default_acp_rot == '3' else ''}",
                        "Green" if default_acp_rot == "3" else "Gray",
                    )
                    self.console_write(
                        f"        [4] none    (Sin rotacion){' [DEFAULT]' if default_acp_rot == '4' else ''}",
                        "Green" if default_acp_rot == "4" else "Gray",
                    )
                    rot_acp_in = (
                        yield {
                            "kind": "prompt",
                            "prompt": f"        Selecciona rotacion ACP (1-4) [ENTER = {default_acp_rot}]",
                            "buttons": [
                                (
                                    f"[ENTER] Default ({default_acp_rot})",
                                    "",
                                    "btn_default",
                                ),
                                ("[1] oblimin", "1", ""),
                                ("[2] promax", "2", ""),
                                ("[3] varimax", "3", ""),
                                ("[4] none", "4", ""),
                            ],
                        }
                    ).strip()
                    if not rot_acp_in:
                        rot_acp_in = default_acp_rot
                    selected_acp_rot = {
                        "1": "oblimin",
                        "2": "promax",
                        "4": "none",
                    }.get(rot_acp_in, "varimax")
                else:
                    target_single = (
                        "Componentes Principales (principal)"
                        if has_acp
                        else "Analisis Factorial Exploratorio (fa)"
                    )
                    detected_single = (
                        detected_acp_rot if has_acp else detected_afe_rot
                    )
                    if not detected_single:
                        m_rot = re.search(
                            r"(?i)\b(promax|varimax|oblimin|none)\b",
                            goal_norm_rot,
                        )
                        if m_rot:
                            detected_single = m_rot.group(1).lower()
                    default_single_rot = {
                        "oblimin": "1",
                        "promax": "2",
                        "varimax": "3",
                        "none": "4",
                    }.get(detected_single, "3" if has_acp else "1")

                    self.console_write(
                        f"\n 2. Rotacion para {target_single}:", "White"
                    )
                    self.console_write(
                        f"    [1] oblimin (Oblicua directa - Recomendada cuando los factores correlacionan){' [DEFAULT]' if default_single_rot == '1' else ''}",
                        "Green" if default_single_rot == "1" else "Gray",
                    )
                    self.console_write(
                        f"    [2] promax  (Oblicua clasica){' [DEFAULT]' if default_single_rot == '2' else ''}",
                        "Green" if default_single_rot == "2" else "Gray",
                    )
                    self.console_write(
                        f"    [3] varimax (Ortogonal - Factores/Componentes independientes a 90 grados){' [DEFAULT]' if default_single_rot == '3' else ''}",
                        "Green" if default_single_rot == "3" else "Gray",
                    )
                    self.console_write(
                        f"    [4] none    (Sin rotacion){' [DEFAULT]' if default_single_rot == '4' else ''}",
                        "Green" if default_single_rot == "4" else "Gray",
                    )
                    rot_single_in = (
                        yield {
                            "kind": "prompt",
                            "prompt": f"    Selecciona rotacion (1-4) [ENTER = {default_single_rot}]",
                            "buttons": [
                                (
                                    f"[ENTER] Default ({default_single_rot})",
                                    "",
                                    "btn_default",
                                ),
                                ("[1] oblimin", "1", ""),
                                ("[2] promax", "2", ""),
                                ("[3] varimax", "3", ""),
                                ("[4] none", "4", ""),
                            ],
                        }
                    ).strip()
                    if not rot_single_in:
                        rot_single_in = default_single_rot
                    single_rot_choice = {
                        "2": "promax",
                        "3": "varimax",
                        "4": "none",
                    }.get(rot_single_in, "oblimin")
                    selected_afe_rot = single_rot_choice
                    selected_acp_rot = single_rot_choice

                clean_na_codes = yield from self._get_structured_na_rules(
                    "3", "las variables analizadas en AFE/ACP"
                )
                inversion_directive = (
                    yield from self._get_structured_item_inversion("4")
                )
                category_clean_directive = (
                    yield from self._get_structured_category_cleaning("5")
                )

                # D. Variables o ítems a incluir en AFE / ACP
                prof_obj = charly_engine.load_dataset_profile_json()
                total_file_cols = prof_obj.get(
                    "n_columnas_total", prof_obj.get("total_columnas", 0)
                )
                c_names = list((prof_obj.get("columnas") or {}).keys())
                c_count = len(c_names)
                detected_summary = ""
                if c_count > 0:
                    if c_count == total_file_cols:
                        detected_summary = f"Todas las variables validas de la base ({c_count} variables)"
                    elif c_count <= 5:
                        detected_summary = (
                            f"{', '.join(c_names)} ({c_count} variables)"
                        )
                    else:
                        detected_summary = f"{c_names[0]} hasta {c_names[-1]} ({c_count} variables: {c_names[0]}, {c_names[1]} ... {c_names[-1]})"
                default_vars_display = (
                    detected_summary
                    if detected_summary
                    else "Todas las variables validas de la base"
                )

                self.console_write(
                    "\n 4. Variables o items a incluir en el analisis factorial / componentes:",
                    "White",
                )
                self.console_write(
                    f"    [ENTER = {default_vars_display}] [DEFAULT]", "Green"
                )
                self.console_write(
                    "    (O escribe el rango o columnas deseadas si deseas cambiarlas, ej: I2 a I49, I1:I20, o 'todas'):",
                    "Gray",
                )
                vars_input = (
                    yield {
                        "kind": "prompt",
                        "prompt": "    Variables a incluir [ENTER = Mantener detectadas]",
                        "buttons": [
                            (
                                "[ENTER] Mantener detectadas [DEFAULT]",
                                "",
                                "btn_default",
                            )
                        ],
                    }
                ).strip()

                custom_vars_str = ""
                if vars_input:
                    self.console_write(
                        f"\n[RE-PERFILADO] Aplicando seleccion personalizada de variables: '{vars_input}'...",
                        "Cyan",
                    )
                    if re.match(
                        r"(?i)^todas?$|^toda\s+la\s+base$", vars_input
                    ):
                        custom_goal = f"{custom_goal}. Analizar todas las variables validas de la base."
                        custom_vars_str = (
                            "todas las variables validas de la base"
                        )
                    else:
                        custom_goal = (
                            f"{custom_goal}. Variables a analizar: {vars_input}."
                        )
                        custom_vars_str = vars_input
                    goal_path.write_text(custom_goal, encoding="utf-8")
                    yield {
                        "kind": "async",
                        "status_label": "Re-perfilando variables en R...",
                        "fn": charly_engine.run_data_profiler,
                        "args": (safe_data_file, target_file, custom_goal),
                    }

                rot_specs = (
                    f"Rotaciones diferenciadas: AFE (fa) con rotate = '{selected_afe_rot}' y ACP (principal) con rotate = '{selected_acp_rot}'."
                    if (has_afe and has_acp)
                    else (
                        f"rotate = '{selected_acp_rot}' en principal()."
                        if has_acp
                        else f"rotate = '{selected_afe_rot}' en fa()."
                    )
                )
                fam_lbl = (
                    "AFE con fa() y ACP con principal()"
                    if (has_afe and has_acp)
                    else (
                        "ACP con principal()" if has_acp else "AFE con fa()"
                    )
                )
                ext_lbl = (
                    f"{selected_extract} para AFE (fa(..., fm = '{selected_extract}')). "
                    if has_afe
                    else ""
                ) + (
                    "En ACP descomposicion espectral canonica de varianza total (principal())."
                    if has_acp
                    else ""
                )
                vars_lbl = (
                    custom_vars_str
                    if custom_vars_str
                    else (
                        detected_summary
                        if detected_summary
                        else "Variables observadas perfiladas en la Ficha Tecnica."
                    )
                )
                na_lbl = (
                    f"Tratar como datos faltantes (NA) ejecutando el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {clean_na_codes}"
                    if clean_na_codes
                    else "No se requieren recodificaciones adicionales a NA."
                )
                inv_lbl = (
                    f"- Inversion de items (polaridad inversa): Ejecutar el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {inversion_directive}"
                    if inversion_directive
                    else "- Inversion de items: No se requiere."
                )

                cat_lbl = (
                    f"- Limpieza de categorias nominales: Ejecutar el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {category_clean_directive}"
                    if category_clean_directive
                    else "- Limpieza de categorias: No se requiere."
                )
                method_specs = (
                    "\r\n================================================================================\r\n"
                    "ESPECIFICACIONES METODOLOGICAS CONFIRMADAS POR EL INVESTIGADOR:\r\n"
                    f"- Familia estadistica: Modelos exploratorios y reduccion con libreria psych ({fam_lbl}).\r\n"
                    f"- Metodo de extraccion: {ext_lbl}\r\n"
                    f"- Rotacion: {rot_specs}\r\n"
                    f"- Variables analizadas en AFE/ACP: {vars_lbl}.\r\n"
                    "- Manejo de faltantes en psych (AFE/ACP): use = 'pairwise' (en psych el argumento de faltantes es estrictamente 'use', no usar 'cor').\r\n"
                    f"- Recodificacion de faltantes (NA): {na_lbl}\r\n"
                    f"{inv_lbl}\r\n"
                    f"{cat_lbl}\r\n"
                    "================================================================================\r\n"
                )

            # -----------------------------------------------------------------
            # FAMILIA 2: REGRESIÓN DIRECTA (PROBIT / LOGIT)
            # -----------------------------------------------------------------
            elif is_direct_regression:
                self.console_write(
                    " [FAMILIA DETECTADA]: Regresion Directa (Modelos Lineales Generalizados: Probit / Logit)",
                    "Yellow",
                )
                self.console_write("", "White")
                clean_na_codes = yield from self._get_structured_na_rules(
                    "1", "las variables del modelo de regresion"
                )
                inversion_directive = (
                    yield from self._get_structured_item_inversion("2")
                )
                category_clean_directive = (
                    yield from self._get_structured_category_cleaning("3")
                )

                dep_var_name, is_binary, is_probit = yield {
                    "kind": "async",
                    "status_label": "Verificando niveles de la variable dependiente...",
                    "fn": charly_engine.detect_direct_regression_binary,
                    "args": (custom_goal, clean_na_codes, category_clean_directive),
                }
                if is_binary:
                    link_part = '(link = "probit")' if is_probit else ""
                    reg_family_directive = (
                        f"- Familia estadistica: Regresion BINARIA (variable dependiente '{dep_var_name}' con 2 categorias).\r\n"
                        f"- Modelo y funcion en R: Usar OBLIGATORIAMENTE glm(formula, family = binomial{link_part}, data = datos). PROHIBIDO usar polr()."
                    )
                else:
                    m_part = "probit" if is_probit else "logistic"
                    reg_family_directive = (
                        f"- Familia estadistica: Regresion ORDINAL POLITOMICA (variable dependiente '{dep_var_name}' con 3 o mas categorias).\r\n"
                        f"- Modelo y funcion en R: Usar MASS::polr(formula, method = '{m_part}', data = datos), convirtiendo la dependiente con: datos${dep_var_name} <- factor(datos${dep_var_name}, ordered = TRUE)."
                    )

                na_lbl = (
                    f"Tratar como datos faltantes (NA) ejecutando el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {clean_na_codes}"
                    if clean_na_codes
                    else "No se requieren recodificaciones adicionales a NA."

                )

                inv_lbl = (
                    f"- Inversion de items (polaridad inversa): Ejecutar el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {inversion_directive}"
                    if inversion_directive
                    else "- Inversion de items: No se requiere."
                )

                cat_lbl = (

                    f"- Limpieza de categorias nominales: Ejecutar el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {category_clean_directive}"
                    if category_clean_directive
                    else "- Limpieza de categorias: No se requiere."
                )
                method_specs = (
                    "\r\n================================================================================\r\n"
                    "ESPECIFICACIONES METODOLOGICAS CONFIRMADAS POR EL INVESTIGADOR:\r\n"
                    f"{reg_family_directive}\r\n"
                    f"- Recodificacion de faltantes (NA): {na_lbl}\r\n"
                    f"{inv_lbl}\r\n"
                    f"{cat_lbl}\r\n"
                    "================================================================================\r\n"
                )

            # -----------------------------------------------------------------
            # FAMILIA 3: LAVAAN (AFC, BIFACTOR, MIMIC, SEM)
            # -----------------------------------------------------------------
            else:
                default_est_choice = "1"
                if re.search(r"(?i)\bMLR\b", custom_goal):
                    default_est_choice = "2"
                elif re.search(r"(?i)\bML\b", custom_goal):
                    default_est_choice = "3"
                elif re.search(r"(?i)\bWLSMV\b", custom_goal):
                    default_est_choice = "1"

                self.console_write(" 1. Estimador para el modelo:", "White")
                self.console_write(
                    "    [1] WLSMV (Recomendado para items ordinales / politomicos / Likert)",
                    "Green" if default_est_choice == "1" else "Gray",
                )
                self.console_write(
                    "    [2] MLR   (Maxima verosimilitud robusta para variables continuas)",
                    "Green" if default_est_choice == "2" else "Gray",
                )
                self.console_write(
                    "    [3] ML    (Maxima verosimilitud clasica)",
                    "Green" if default_est_choice == "3" else "Gray",
                )
                est_input = (
                    yield {
                        "kind": "prompt",
                        "prompt": f"    Selecciona (1-3) [ENTER = {default_est_choice}]",
                        "buttons": [
                            (
                                f"[ENTER] Default ({default_est_choice})",
                                "",
                                "btn_default",
                            ),
                            ("[1] WLSMV", "1", ""),
                            ("[2] MLR", "2", ""),
                            ("[3] ML", "3", ""),
                        ],
                    }
                ).strip()
                if not est_input:
                    est_input = default_est_choice
                selected_estimator = {"2": "MLR", "3": "ML"}.get(
                    est_input, "WLSMV"
                )

                default_miss_choice = "1"
                if re.search(r"(?i)\blistwise\b", custom_goal):
                    default_miss_choice = "2"

                self.console_write(
                    "\n 2. Tratamiento de datos faltantes (Missing Data):",
                    "White",
                )
                if selected_estimator == "WLSMV":
                    self.console_write(
                        "    [1] Pairwise (Estandar y recomendado para WLSMV) [DEFAULT]",
                        "Green",
                    )
                    self.console_write(
                        "    [2] Listwise (Eliminacion por casos completos)",
                        "Gray",
                    )
                else:
                    self.console_write(
                        f"    [1] FIML (Full Information Maximum Likelihood - Estandar para {selected_estimator}) [DEFAULT]",
                        "Green",
                    )
                    self.console_write(
                        "    [2] Listwise (Eliminacion por casos completos)",
                        "Gray",
                    )
                miss_input = (
                    yield {
                        "kind": "prompt",
                        "prompt": f"    Selecciona (1-2) [ENTER = {default_miss_choice}]",
                        "buttons": [
                            (
                                f"[ENTER] Default ({default_miss_choice})",
                                "",
                                "btn_default",
                            ),
                            (
                                "[1] Pairwise"
                                if selected_estimator == "WLSMV"
                                else "[1] FIML",
                                "1",
                                "",
                            ),
                            ("[2] Listwise", "2", ""),
                        ],
                    }
                ).strip()
                if not miss_input:
                    miss_input = default_miss_choice
                if miss_input == "2":
                    selected_missing = "listwise"
                else:
                    selected_missing = (
                        "pairwise"
                        if selected_estimator == "WLSMV"
                        else "fiml"
                    )

                clean_na_codes = yield from self._get_structured_na_rules(
                    "3",
                    "las variables o items del modelo de medida/estructural",
                )
                inversion_directive = (
                    yield from self._get_structured_item_inversion("4")
                )
                continuous_exc_directive = (
                    yield from self._get_structured_continuous_exceptions(
                        "5", selected_estimator
                    )
                )
                category_clean_directive = (
                    yield from self._get_structured_category_cleaning("6")
                )

                dif_directive = ""
                if canonical_archetype == "MIMIC" and re.search(dif_regex, custom_goal):
                    self.console_write(
                        "\n 7. Evaluacion de Invarianza de Medida y Funcionamiento Diferencial (DIF):",
                        "White",
                    )
                    self.console_write(
                        "    [1] Modelo MIMIC con Score Test Univariado de Muthen (1989 / Mplus) a 1 gl + Bonferroni [DEFAULT]",
                        "Green",
                    )
                    self.console_write(
                        "        (Metodologia exclusiva de Charly: evita colapso de celdas vacias y fragmentacion de muestra)",
                        "Gray",
                    )
                    yield {
                        "kind": "prompt",
                        "prompt": "    Confirmar evaluacion exclusiva con MIMIC [ENTER = 1]",
                        "buttons": [
                            (
                                "[ENTER / 1] Confirmar evaluacion exclusiva con MIMIC [DEFAULT]",
                                "",
                                "btn_default",
                            )
                        ],
                    }
                    dif_directive = (
                        "\r\n- Evaluacion de Invarianza y DIF: Score Test univariado iterativo (Muthen 1989 / Mplus) "
                        "evaluando cada sendero directo (item ~ covariable) de forma independiente (1 gl) con correccion de Bonferroni. "
                        "OBLIGATORIO usar bucle for iterando sobre los pares de expand.grid(item, pred) con lavTestScore(fit_base, add = p_syn, epc = TRUE). "
                        "PROHIBIDO concatenar multiples senderos simultaneos en una sola llamada a lavTestScore()."
                    )

                bif_directive = ""
                if canonical_archetype == "Bifactor":
                    self.console_write(
                        "\n 7. Indices de Fiabilidad y Estructura Bifactorial (Reise / Rodriguez):",
                        "White",
                    )
                    self.console_write(
                        "    [1] Computar indices canonicos: Omega_H (general), Omega_HS (subescalas) y ECV [DEFAULT]",
                        "Green",
                    )
                    self.console_write(
                        "        (En modelos bifactoriales ortogonales, Alfa, HTMT y Fornell-Larcker no aplican o generan error de matriz singular)",
                        "Gray",
                    )
                    yield {
                        "kind": "prompt",
                        "prompt": "    Confirmar evaluacion bifactorial [ENTER = 1]",
                        "buttons": [
                            (
                                "[ENTER / 1] Confirmar evaluacion bifactorial [DEFAULT]",
                                "",
                                "btn_default",
                            )
                        ],
                    }
                    bif_directive = (
                        "\r\n- Evaluacion Bifactorial: Computar obligatoriamente los indices canonicos de consistencia y estructura bifactorial "
                        "(Reise 2012, Rodriguez et al. 2016) a partir de las cargas estandarizadas de lavInspect(fit, 'std'): "
                        "Omega Jerarquico (Omega_H para el factor general), Omegas de Subescala limpios (Omega_HS para cada factor especifico descontando al general), "
                        "Omega Total (Omega_T) y Varianza Comun Explicada (ECV). PROHIBIDO invocar htmt() o Fornell-Larcker sobre la sintaxis bifactorial ortogonal "
                        "ya que produce error de matriz no definida positiva y carece de validez metodologica."
                    )

                # F. Evaluación de Senderos y Mediaciones (SEM_Senderos / SEM_NoRecursivo)
                is_structural = canonical_archetype in (
                    "SEM_Senderos",
                    "SEM_NoRecursivo",
                )
                is_raw_mediation = False
                if is_structural:
                    ai_needs_update = canonical_archetype == "SEM_Senderos"
                    current_goal_context = custom_goal

                    if canonical_archetype == "SEM_NoRecursivo":
                        self.console_write(
                            "\n [AVISO] Modelo no recursivo detectado. Por seguridad matematica, se deshabilitan las mediaciones automaticas.",
                            "Yellow",
                        )
                        mediation_directives_list = []
                        total_effects_directives_list = []

                    while ai_needs_update:
                        if engine == "local":
                            # Modo local: ninguna consulta sale de la PC; las cadenas de mediacion se deducen
                            # de las flechas escritas (contract_builder.ps1).
                            ai_obj = {}
                        else:
                            self.console_write(
                                "\n [IA] Analizando mediaciones y efectos totales del texto (2-5s)...",
                                "Cyan",
                            )
                            ai_obj = yield {
                                "kind": "async",
                                "status_label": "[IA] Analizando mediaciones y efectos totales...",
                                "fn": charly_engine.invoke_semantic_parser,
                                "args": (current_goal_context,),
                            }
                        mediation_directives_list = (ai_obj or {}).get(
                            "mediaciones", []
                        )
                        total_effects_directives_list = (ai_obj or {}).get(
                            "efectos_totales", []
                        )

                        self.console_write(
                            "\n 6. Estructura Causal (Senderos Manuales + Mediaciones IA):",
                            "White",
                        )
                        if arrow_directives:
                            self.console_write(
                                "    Senderos Directos (Ingresados manualmente):",
                                "Gray",
                            )
                            for ad in arrow_directives:
                                origs = " + ".join(ad.get("Origenes") or [])
                                dst = ad.get("Destino", "")
                                self.console_write(
                                    f"      - {origs} -> {dst}", "Green"
                                )
                        else:
                            self.console_write(
                                "    Senderos Directos (Ingresados manualmente): [Ninguno detectado]",
                                "DarkGray",
                            )
                            self.console_write(
                                "      > AVISO: En modelos estructurales debes escribir las flechas al final (ej. A -> B).",
                                "Yellow",
                            )
                            self.console_write(
                                "      > IMPORTANTE: Usa nombres sin espacios (ej: Trato_Personal) y separalos con punto o salto de linea.",
                                "Yellow",
                            )

                        if mediation_directives_list:
                            self.console_write(
                                "    Efectos Indirectos en cadena (IA):",
                                "Gray",
                            )
                            for md in mediation_directives_list:
                                self.console_write(f"      - {md}", "Green")
                        if total_effects_directives_list:
                            self.console_write(
                                "    Efectos Totales / Sumas (IA):", "Gray"
                            )
                            for et in total_effects_directives_list:
                                self.console_write(f"      - {et}", "Green")

                        self.console_write(
                            "\n    [ENTER = Aprobar y continuar]", "White"
                        )
                        self.console_write(
                            "    [E     = Asistente de mediaciones paso a paso (Recomendado, sin texto libre)]",
                            "Magenta",
                        )
                        self.console_write(
                            "    [T     = Escribir efectos en texto libre (Bloc de Notas)]",
                            "DarkCyan",
                        )
                        self.console_write(
                            "    [M     = Modificar mediaciones/efectos en lenguaje humano]",
                            "Yellow",
                        )
                        self.console_write(
                            "    [N     = Ignorar aportes de la IA (continuar sin mediaciones)]",
                            "DarkGray",
                        )
                        self.console_write(
                            "    [C     = Cancelar analisis (ideal si olvidaste poner las flechas)]",
                            "Red",
                        )

                        resp = (
                            yield {
                                "kind": "prompt",
                                "prompt": "    Elige una opcion [ENTER / E / T / M / N / C]",
                                "buttons": [
                                    (
                                        "[ENTER] Aprobar y continuar",
                                        "",
                                        "btn_default",
                                    ),
                                    (
                                        "[E] Asistente paso a paso",
                                        "E",
                                        "",
                                    ),
                                    ("[T] Texto libre", "T", "btn_secondary"),
                                    ("[M] Modificar (IA)", "M", "btn_warn"),
                                    ("[N] Ignorar IA", "N", "btn_secondary"),
                                    ("[C] Cancelar", "C", "btn_danger"),
                                ],
                            }
                        ).strip().lower()

                        if resp == "e":
                            w_res = (
                                yield from self._invoke_structured_mediation_selector(
                                    arrow_directives
                                )
                            )
                            meds_sel = w_res.get("Mediaciones") or []
                            tots_sel = w_res.get("EfectosTotales") or []
                            if meds_sel or tots_sel:
                                mediation_directives_list = meds_sel
                                total_effects_directives_list = tots_sel
                                is_raw_mediation = False
                                ai_needs_update = False
                                self.console_write(
                                    "    [OK] Mediaciones y efectos totales confirmados via asistente estructurado.",
                                    "Green",
                                )
                            else:
                                self.console_write(
                                    "    [AVISO] No se seleccionaron mediaciones. Se continuara solo con senderos directos.",
                                    "Yellow",
                                )
                                mediation_directives_list = []
                                total_effects_directives_list = []
                                is_raw_mediation = False
                                ai_needs_update = False
                        elif resp == "t":
                            self.console_write(
                                "\n    [ALINEACION] Abriendo ventana para ingresar efectos personalizados exactos...",
                                "Cyan",
                            )
                            init_t = (
                                "Escribe aca exactamente los efectos indirectos o totales a calcular.\n"
                                "Ej:\n"
                                "1. El efecto indirecto total en cadena (Sobrecarga -> Conflicto -> Desgaste -> Rotacion)\n"
                                "2. La ruta indirecta corta de Sobrecarga a Rotacion mediada solo por Conflicto"
                            )
                            dlg = ShowInputWindowDialog(self, init_t)
                            if dlg.exec() == QDialog.DialogCode.Accepted:
                                raw_med = dlg.get_text()
                                if raw_med:
                                    mediation_directives_list = [
                                        f"[BYPASS IA - EXPRESIONES EXACTAS DEL USUARIO]:\n{raw_med}"
                                    ]
                                    total_effects_directives_list = []
                                    is_raw_mediation = True
                                    ai_needs_update = False
                                    self.console_write(
                                        "    [OK] Efectos personalizados guardados (Bypass IA activado).",
                                        "Green",
                                    )
                                else:
                                    self.console_write(
                                        "    [AVISO] No se ingreso texto. Volviendo al menu.",
                                        "Yellow",
                                    )
                        elif resp == "m":
                            mod_text = (
                                yield {
                                    "kind": "prompt",
                                    "prompt": "    > Escribe tu instruccion (Ej: 'agrega el efecto total')",
                                    "buttons": [],
                                }
                            ).strip()
                            if mod_text:
                                current_goal_context += f"\n\nCORRECCION DEL USUARIO (OBLIGATORIA): {mod_text}"
                        elif resp in ("c", "cancelar"):
                            self.console_write(
                                "\n[X] Ejecucion cancelada por el usuario. Agrega tus flechas al texto y vuelve a intentar.",
                                "Red",
                            )
                            yield {
                                "kind": "prompt",
                                "prompt": "Presiona ENTER para volver al menu",
                                "buttons": [
                                    ("[ENTER] Volver al menu", "", "btn_default")
                                ],
                            }
                            return
                        elif resp in ("n", "no"):
                            mediation_directives_list = []
                            total_effects_directives_list = []
                            is_raw_mediation = False
                            ai_needs_update = False
                        else:
                            ai_needs_update = False

                arrow_directive_text = ""
                if arrow_directives:
                    arrow_lines = []
                    for ad in arrow_directives:
                        orig_str = " + ".join(ad.get("Origenes") or [])
                        dst = ad.get("Destino", "")
                        arrow_lines.append(
                            f"  * {orig_str} -> {dst}  ==>  {dst} ~ {orig_str}"
                        )
                    arrow_directive_text = (
                        "\r\n- Senderos Estructurales Confirmados:\r\n"
                        + "\r\n".join(arrow_lines)
                        + "\r\n  [Principio Canonico]: En lavaan, la variable senalada por la flecha (Destino) se predice por el Origen (Destino ~ Origen). Estas formulas son OBLIGATORIAS y deben escribirse de forma exacta y no invertida en el modelo."
                    )

                mediation_directive_text = ""
                if is_raw_mediation and mediation_directives_list:
                    clean_raw = mediation_directives_list[0].replace(
                        "[BYPASS IA - EXPRESIONES EXACTAS DEL USUARIO]:\n", ""
                    )
                    mediation_directive_text = (
                        "\r\n- Efectos Indirectos y Totales (Personalizados / Bypass IA):\r\n"
                        "El usuario ha definido de forma exacta los efectos a calcular. Debes OBLIGATORIAMENTE etiquetar todos los senderos involucrados y utilizar el operador ':=' para calcular de forma precisa lo siguiente:\r\n"
                        f"{clean_raw}\r\n"
                        "  [Principio Canonico de Efectos Totales]: El efecto total de cualquier variable predictora sobre un desenlace se compone EXCLUSIVAMENTE de su propio sendero directo mas la suma de sus propios efectos indirectos (rutas que nacen en esa misma variable predictora y terminan en el desenlace). Queda TERMINANTEMENTE PROHIBIDO sumar o incluir al efecto total coeficientes de otras variables independientes, covariables de control o senderos ajenos al predictor evaluado. Si el modelo NO contiene un sendero directo desde ese predictor hacia el desenlace, su efecto total es IGUAL a la suma de sus efectos indirectos (no agregues ningun sendero ni coeficiente hacia el mediador). Calcula efectos totales solo si el usuario los pide; si pide unicamente la mediacion, define solo los efectos indirectos."
                    )
                elif mediation_directives_list or total_effects_directives_list:
                    combined_m = list(mediation_directives_list) + list(
                        total_effects_directives_list
                    )
                    med_list_str = "\r\n  * ".join(combined_m)
                    mediation_directive_text = (
                        f"\r\n- Mediaciones y Efectos Totales (Contrato Explicito):\r\n  * {med_list_str}\r\n"
                        "  [Principio Canonico]: Todo sendero causal que intervenga debe etiquetarse. Luego, el efecto indirecto se define exclusivamente con ':=' computando el producto de las etiquetas. Queda PROHIBIDO usar '~' dentro de ':='.\r\n"
                        "  [Principio Canonico de Efectos Totales]: El efecto total de cualquier variable predictora sobre un desenlace se compone EXCLUSIVAMENTE de su propio sendero directo mas la suma de sus propios efectos indirectos (rutas que nacen en esa misma variable predictora y terminan en el desenlace). Queda TERMINANTEMENTE PROHIBIDO sumar o incluir al efecto total coeficientes de otras variables independientes, covariables de control o senderos ajenos al predictor evaluado. Si el modelo NO contiene un sendero directo desde ese predictor hacia el desenlace, su efecto total es IGUAL a la suma de sus efectos indirectos (no agregues ningun sendero ni coeficiente hacia el mediador). Calcula efectos totales solo si el usuario los pide; si pide unicamente la mediacion, define solo los efectos indirectos."
                    )
                elif re.search(
                    r"(?i)\b(mediaci[oó]n|indirecto|efecto\s+total|efectos\s+indirectos)\b",
                    custom_goal,
                ):
                    mediation_directive_text = (
                        "\r\n- Mediaciones y Efectos Indirectos en lavaan: Todo sendero causal que intervenga debe etiquetarse (Destino ~ eq * Origen). Luego usar ':=' para el producto de etiquetas.\r\n"
                        "  [Principio Canonico de Efectos Totales]: El efecto total de cualquier variable predictora sobre un desenlace se compone EXCLUSIVAMENTE de su propio sendero directo mas la suma de sus propios efectos indirectos (rutas que nacen en esa misma variable predictora y terminan en el desenlace). Queda TERMINANTEMENTE PROHIBIDO sumar o incluir al efecto total coeficientes de otras variables independientes, covariables de control o senderos ajenos al predictor evaluado. Si el modelo NO contiene un sendero directo desde ese predictor hacia el desenlace, su efecto total es IGUAL a la suma de sus efectos indirectos (no agregues ningun sendero ni coeficiente hacia el mediador). Calcula efectos totales solo si el usuario los pide; si pide unicamente la mediacion, define solo los efectos indirectos."
                    )

                est_desc = (
                    "(declarar ordered = c(...) para todas las variables de los factores de medida)"
                    if selected_estimator == "WLSMV"
                    else "(estimacion continua sin ordered)"
                )
                na_lbl = (
                    f"Tratar como datos faltantes (NA) ejecutando el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {clean_na_codes}"
                    if clean_na_codes
                    else "No se requieren recodificaciones adicionales a NA."
                )
                inv_lbl = (
                    f"- Inversion de items (polaridad inversa): Ejecutar el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {inversion_directive}"
                    if inversion_directive
                    else "- Inversion de items: No se requiere."
                )
                cont_lbl = (
                    f"\r\n- Excepciones de tipo de variable: {continuous_exc_directive}"
                    if continuous_exc_directive
                    else ""
                )
                cat_lbl = (
                    f"- Limpieza de categorias nominales: Ejecutar el siguiente codigo R OBLIGATORIO antes de cualquier analisis: {category_clean_directive}"
                    if category_clean_directive
                    else "- Limpieza de categorias: No se requiere."
                )

                method_specs = (
                    "\r\n================================================================================\r\n"
                    "ESPECIFICACIONES METODOLOGICAS CONFIRMADAS POR EL INVESTIGADOR:\r\n"
                    f"- Estimador: {selected_estimator} {est_desc}.\r\n"
                    f'- Tratamiento de datos faltantes: missing = "{selected_missing}".\r\n'
                    f"- Recodificacion de faltantes (NA): {na_lbl}\r\n"
                    f"{inv_lbl}"
                    f"{cont_lbl}\r\n"
                    f"{cat_lbl}{dif_directive}{bif_directive}{arrow_directive_text}{mediation_directive_text}\r\n"
                    "================================================================================\r\n"
                )

            # Paso 4: Muestra de Especificaciones y Contrato Psicométrico Vinculante (líneas 1701-1755)
            contract_res = yield {
                "kind": "async",
                "status_label": "Construyendo Contrato de Ejecución Psicométrica...",
                "fn": charly_engine.build_and_format_contract,
                "args": (
                    custom_goal,
                    clean_na_codes,
                    inversion_directive,
                    continuous_exc_directive,
                    selected_estimator,
                    selected_missing,

                    mediation_directives_list,

                    total_effects_directives_list,
                    canonical_archetype,

                ),

            }

            if contract_res and contract_res.get("success"):
                self.console_write(
                    f"\n[ARQUETIPO IDENTIFICADO]: {contract_res.get('archetype_name')}",
                    "Green",
                )
                self.console_write(f"\n{contract_res.get('display')}\n", "Green")
            else:
                self.console_write(f"\n{method_specs.strip()}\n", "DarkCyan")

            self.console_write(
                "==========================================================================",
                "Yellow",
            )
            self.console_write(
                " CONTROL DE VALIDACION: Dar el OK para avanzar o volver a la instancia previa",
                "Yellow",
            )
            self.console_write(
                "==========================================================================",
                "Yellow",
            )
            self.console_write(
                " [ENTER = Si, dar OK y avanzar con la generacion del script R] [DEFAULT]",
                "Green",
            )
            self.console_write(
                " [R     = Abrir Bloc de Notas para modificar tu pedido y re-perfilar]",
                "Cyan",
            )
            self.console_write(
                " [M     = Modificar/Redefinir la configuracion metodologica paso a paso]",
                "Gray",
            )

            review_opt = (
                yield {
                    "kind": "prompt",
                    "prompt": " Dar el OK para avanzar? [ENTER = Avanzar / R = Bloc de Notas / M = Re-definir]",
                    "buttons": [
                        (
                            "[ENTER] Si, dar OK y avanzar con la generacion del script R [DEFAULT]",
                            "",
                            "btn_default",
                        ),
                        (
                            "[R] Abrir Bloc de Notas para modificar tu pedido y re-perfilar",
                            "R",
                            "btn_warn",
                        ),
                        (
                            "[M] Modificar/Redefinir la configuracion metodologica paso a paso",
                            "M",
                            "",
                        ),
                    ],
                }
            ).strip().lower()

            if review_opt in ("r", "b"):
                self.console_write(
                    "\n[SISTEMA] Abriendo el Bloc de Notas... Modifica tu pedido, guarda (Ctrl+G o Archivo > Guardar) y cierra la ventana.",
                    "Yellow",
                )
                yield {
                    "kind": "async",
                    "status_label": "Esperando edición en Bloc de Notas...",
                    "fn": lambda: charly_engine.wait_process(
                        ["notepad.exe", str(goal_path)]
                    ),
                }
                if goal_path.exists():
                    custom_goal = goal_path.read_text(
                        encoding="utf-8-sig", errors="replace"
                    ).strip()
                    self.console_write(
                        "\n[OK] Instruccion actualizada exitosamente desde el Bloc de Notas:",
                        "Green",
                    )
                    self.console_write(f">> {custom_goal}\n", "Cyan")
                    if charly_engine.test_is_na_cancelled(custom_goal):
                        self.console_write(
                            "[ALINEACION] Detectada cancelacion / correccion ('no corre / me equivoque / sin faltantes') en la instruccion.",
                            "Green",
                        )
                        self.console_write(
                            "             Se anulo cualquier recodificacion de valores a NA.",
                            "Green",
                        )
                self.console_write(
                    "[SISTEMA] Regresando a la instancia previa para re-perfilar y redefinir la configuracion con el pedido actualizado...",
                    "Cyan",
                )
                confirmed_and_ready = False
            elif review_opt in ("m", "n", "no"):
                self.console_write(
                    "\n[SISTEMA] OK no otorgado. Regresando a la instancia previa de configuracion para redefinir todo paso a paso...",
                    "Cyan",
                )
                confirmed_and_ready = False
            else:
                confirmed_and_ready = True
                self.console_write(
                    "\n[OK] Especificaciones metodologicas confirmadas por el investigador. Avanzando a la generacion de codigo R...",
                    "Green",
                )

        # Guardar finalGoalText = customGoal + methodSpecs (líneas 1757-1758)
        final_goal_text = custom_goal + "\r\n" + method_specs
        goal_path.write_text(final_goal_text, encoding="utf-8")
        charly_engine.sync_workspaces(from_v4_to_app=True)

        # Iniciar cronometraje total del pipeline de analisis
        self.in_analysis_pipeline = True
        self.pipeline_start_time = time.time()
        # 4. Pilar 2: Introspección del Entorno R Local (líneas 1760-1767)
        self.console_write(
            "\n[PASO 3/5] Verificando firmas de funciones en R local...", "Cyan"
        )
        ok_env, out_env = yield {
            "kind": "async",
            "status_label": "[PASO 3/5] Verificando firmas de funciones en R local...",
            "fn": charly_engine.run_step3_env_inspector,
        }
        if out_env:
            self.console_write(out_env, "Green" if ok_env else "Red")
        if not ok_env:
            self.console_write("Error en la introspeccion de R.", "Red")
            yield continue_prompt()
            return

        # 5. Solicitud y ensamblador de Prompt (líneas 1769-1771)
        self.console_write(
            "\n[PASO 4/5] Ensamblando restricciones tecnicas...", "Cyan"
        )
        ok_pb, out_pb = yield {
            "kind": "async",

            "status_label": "[PASO 4/5] Ensamblando restricciones técnicas...",

            "fn": charly_engine.run_step4_prompt_builder,
            "args": (canonical_archetype,),

        }

        if out_pb:
            self.console_write(out_pb, "Cyan" if ok_pb else "Red")
        # [FIX C4] sin prompt nuevo NO se sigue (antes se reutilizaba el full_prompt.txt anterior)
        if not ok_pb or not (charly_engine.V4_WORKSPACE / "full_prompt.txt").exists():
            self.console_write(
                "\n[ERROR] No se pudo ensamblar el prompt. Se aborta para no usar datos de una consulta anterior.",
                "Red",
            )
            yield continue_prompt()
            return

        # 6. Generación con el Motor Elegido (líneas 1773-1798)
        active_engine = engine
        gen_ok = False
        if active_engine == "cloud":
            self.console_write(
                "\n[PASO 5/5] Solicitando generacion de codigo a Google Gemini Flash...",
                "Cyan",
            )
            gen_ok, cloud_lines = yield {
                "kind": "async",
                "status_label": "[PASO 5/5] Solicitando generación de código a Google Gemini Flash...",
                "fn": charly_engine.run_cloud_engine_ps1,
            }
            self.console_write_lines(cloud_lines)
            if not gen_ok:
                self.console_write(
                    "\n[FALLO EN NUBE] Google Gemini no esta disponible en este momento.",
                    "Yellow",
                )
        else:
            self.console_write(
                "\n[PASO 5/5] Solicitando generacion de codigo a Seru Giran (Qwen3.6-35B-A3B MoE Local)...",
                "Cyan",

            )

            gen_ok, _ = yield {

                "kind": "async",
                "status_label": "[PASO 5/5] Solicitando generación de código a Seru Giran (Local)...",
                "fn": charly_engine.run_local_engine_stream,
                "stream_lines": True,
                "stream_tokens": True,
            }

        if not gen_ok:
            self.console_write(
                "Error durante la generacion del script.", "Red"
            )
            yield continue_prompt()
            return

        # 7. Ejecución en R con Bucle de Autorreparación Dinámica (líneas 1800-1806)
        repair_res = yield {
            "kind": "async",
            "status_label": "Ejecutando script en R local con bucle de autorreparación y auditoría de contrato...",
            "fn": charly_engine.run_with_repair_pipeline,
            "args": (active_engine,),
            "stream_lines": True,
        }

        self._refresh_result_tabs_from_disk()
        run_exit_code = 0 if (repair_res and repair_res.get("success")) else 1
        self.in_analysis_pipeline = False
        if getattr(self, "pipeline_start_time", 0.0) > 0:
            total_p_secs = max(1, int(time.time() - self.pipeline_start_time))
            mins_p = total_p_secs // 60
            secs_p = total_p_secs % 60
            self.last_run_time_str = f"{mins_p} min {secs_p} seg" if mins_p > 0 else f"{secs_p} seg"
            if hasattr(self, "lbl_timer"):
                self.lbl_timer.setText(f"⏱️ Listo ({self.last_run_time_str})")

        # 8. Resumen visual inmediato y menú post-análisis (líneas 1808-1841)
        self.console_write(
            "\n========================================================================",
            "Cyan",
        )
        if run_exit_code == 0:
            _tiene_avisos = bool(((repair_res or {}).get("avisos") or "").strip())
            if _tiene_avisos:
                self.console_write(
                    " ESTADO: EXITOSA CON AVISOS (Codigo de salida 0)                        ",
                    "Yellow",
                )
                self.console_write(
                    " Charly genero el codigo y R calculo los resultados, pero R emitio avisos.",
                    "Yellow",
                )
            else:
                self.console_write(
                    " ESTADO: EJECUCION EXITOSA EN R (Codigo de salida 0)                    ",
                    "Green",
                )
                self.console_write(
                    " Charly genero el codigo y R calculo todos los resultados requeridos.   ",
                    "Green",
                )
            # Si R emitio avisos (aunque termino con codigo 0) se muestran tambien en este cartel final.
            _avisos_txt = (repair_res or {}).get("avisos") or ""
            if _avisos_txt.strip():
                _avisos_lines = [l.rstrip() for l in _avisos_txt.splitlines() if l.strip()]
                self.console_write(
                    "------------------------------------------------------------------------",
                    "Yellow",
                )
                self.console_write(
                    " [!] ATENCION: R EMITIO AVISOS durante el calculo. Revisalos antes de    ",
                    "Yellow",
                )
                self.console_write(
                    "     interpretar los resultados: pueden afectar la validez del modelo.   ",
                    "Yellow",
                )
                for _al in _avisos_lines[:12]:
                    self.console_write("     " + _al.strip(), "Yellow")
                if len(_avisos_lines) > 12:
                    self.console_write(
                        f"     ... ({len(_avisos_lines) - 12} lineas mas en consola_rstudio_completa.txt)",
                        "Yellow",
                    )
        elif repair_res and repair_res.get("contract_unmet"):
            self.console_write(
                " ESTADO: R CALCULO LOS RESULTADOS, PERO EL CONTRATO PSICOMETRICO NO SE CUMPLIO (Codigo 2)",
                "Yellow",
            )
            self.console_write(
                " Los resultados se conservaron; al inicio del informe figura el aviso del auditor.       ",
                "Yellow",
            )
        else:
            self.console_write(
                " ESTADO: R DETUVO LA ESTIMACION CON OBSERVACIONES / ERROR (Codigo 1)    ",
                "Red",
            )
            self.console_write(
                " Charly genero fielmente el codigo, pero R emitio advertencias/errores. ",
                "Yellow",
            )
        self.console_write(
            "========================================================================",
            "Cyan",
        )
        self.console_write(
            " - Codigo R cargado : workspace/generated_script.R (Abierto en RStudio)  ",
            "White",
        )
        self.console_write(
            "   💡 TIP RSTUDIO   : El script esta en el editor superior. Para correrlo interactivo o consultar warnings(), pulsa [Source] (o Ctrl+Shift+S).",
            "Cyan",
        )
        self.console_write(
            " - Salida de R      : workspace/consola_rstudio_completa.txt (Consola R completa)",
            "White",
        )
        if getattr(self, "last_run_time_str", ""):
            self.console_write(
                f" - Duracion total   : {self.last_run_time_str} (Analisis completo)",
                "White",
            )
        self.console_write(
            "========================================================================",
            "Cyan",
        )
        self.console_write(
            " [1] Ver Resultados y Codigo (Abrir Consola R Completa en Bloc de Notas)",
            "White",
        )
        self.console_write(
            " [2] Ver Solo Codigo R (Abrir Script en Bloc de Notas)", "Cyan"
        )
        self.console_write(" [3] Hacer Otro Analisis", "Yellow")
        self.console_write(" [0] Salir", "Red")
        self.console_write(
            "========================================================================",
            "Cyan",
        )

        while True:
            action = (
                yield {
                    "kind": "prompt",
                    "prompt": "Elige una opcion (o presiona Enter para ver Resultados y Codigo)",
                    "buttons": [
                        (
                            "[ENTER / 1] Ver Resultados y Codigo (Bloc de Notas)",
                            "1",
                            "btn_default",
                        ),
                        ("[2] Ver Solo Codigo R (Bloc de Notas)", "2", ""),
                        ("📄 Exportar a Word (.docx)", "__EXPORT_WORD__", "btn_warn"),
                        ("[3] Hacer Otro Analisis", "3", "btn_secondary"),
                        ("[0] Salir", "0", "btn_danger"),
                    ],
                }
            ).strip()

            # Ver el codigo o la consola NO cierra esta pantalla: se abre el Bloc de Notas y se vuelve a
            # presentar este mismo menu (con Exportar a Word incluido) para elegir otra opcion.
            if re.match(r"(?i)^(2|C)$", action):
                script_f = charly_engine.V4_WORKSPACE / "generated_script.R"
                if script_f.exists():
                    subprocess.Popen(["notepad.exe", str(script_f.resolve())])
                continue
            elif re.match(r"(?i)^(3|N)$", action):
                return
            elif re.match(r"(?i)^(0|Q)$", action):
                self.close()
                QApplication.quit()
                return
            else:
                con_f = charly_engine.V4_WORKSPACE / "consola_rstudio_completa.txt"
                if con_f.exists():
                    subprocess.Popen(["notepad.exe", str(con_f.resolve())])
                continue

    # =========================================================================
    # FUNCIONES ESTRUCTURADAS DE PASO 3 (LÍNEAS 107-660 DE charly_core.ps1)
    # =========================================================================
    def _get_structured_na_rules(self, step_number: str, scope: str):
        col_names, all_vals_global, _ = (
            charly_engine.get_profile_columns_and_values()
        )

        self.console_write(
            f"\n {step_number}. Recodificacion de valores como datos faltantes (NA):",
            "White",
        )
        self.console_write(
            "    Hay algun codigo numerico en los datos que represente", "Gray"
        )
        self.console_write(
            "    'no sabe / no contesta' o valor nulo en los reactivos (ej: 7, 99) y deba tratarse como NA?", "Gray"
        )
        self.console_write(
            "    💡 NOTA: Si deseas filtrar categorias sociodemograficas (ej: dejar solo ciertas categorias", "Yellow"
        )
        self.console_write(
            "       en GENERO o NIVEL EDUCATIVO pasando el resto a NA), NO lo hagas aca; para eso existe", "Yellow"
        )
        self.console_write(
            "       el paso posterior de 'Filtrado de categorias'.", "Yellow"
        )
        self.console_write("", "White")
        self.console_write(
            "    [1] No, no hay valores a recodificar [DEFAULT]", "Green"
        )
        self.console_write(
            "    [2] Si, quiero definir reglas de NA", "Gray"
        )

        has_na = (
            yield {
                "kind": "prompt",
                "prompt": "    Selecciona (1-2) [ENTER = 1]",
                "buttons": [
                    (
                        "[ENTER / 1] No, no hay valores a recodificar [DEFAULT]",
                        "1",
                        "btn_default",
                    ),
                    ("[2] Si, quiero definir reglas de NA", "2", ""),
                ],
            }
        ).strip()
        if not has_na:
            has_na = "1"

        if has_na != "2":
            self.console_write(
                "    [OK] Sin recodificacion de faltantes.", "Green"
            )
            return ""

        na_rules = []
        adding_rules = True

        while adding_rules:
            self.console_write("", "White")
            if all_vals_global:
                self.console_write(
                    f"    Valores detectados en la base: {', '.join(str(x) for x in all_vals_global)}",
                    "Cyan",
                )
            na_val = (
                yield {
                    "kind": "prompt",
                    "prompt": "    Que valor numerico debe tratarse como NA?",
                    "buttons": [],
                }
            ).strip()
            if not na_val:
                self.console_write(
                    "    [AVISO] No se ingreso un valor. Se cancela esta regla.",
                    "Yellow",
                )
                adding_rules = False
                continue

            chk = charly_engine.test_value_exists_in_profile(na_val)
            if not chk.get("Exists", True):
                self.console_write(
                    f"    [AVISO DE RADIOGRAFIA] En la base analizada el valor maximo es {chk.get('MaxObs')}. No existe el valor '{chk.get('MissingVal')}'.",
                    "Yellow",
                )
                self.console_write("    Se descarta esta regla.", "Gray")
                add_more = (
                    yield {
                        "kind": "prompt",
                        "prompt": "    Agregar otra regla de NA? [S/N, ENTER = N]",
                        "buttons": [
                            ("[ENTER / N] No", "N", "btn_default"),
                            ("[S] Si", "S", ""),
                        ],
                    }
                ).strip()
                if re.match(r"(?i)^s", add_more):
                    continue
                else:
                    adding_rules = False
                    continue

            self.console_write("", "White")
            self.console_write(
                f"    Donde aplicar NA = {na_val} ?", "White"
            )
            self.console_write(
                f"    [1] En TODAS {scope} [DEFAULT]", "Green"
            )
            self.console_write(
                "    [2] Solo en variables especificas", "Gray"
            )
            where_choice = (
                yield {
                    "kind": "prompt",
                    "prompt": "    Selecciona (1-2) [ENTER = 1]",
                    "buttons": [
                        (
                            f"[ENTER / 1] En TODAS {scope} [DEFAULT]",
                            "1",
                            "btn_default",
                        ),
                        ("[2] Solo en variables especificas", "2", ""),
                    ],
                }
            ).strip()
            if not where_choice:
                where_choice = "1"

            target_vars = "todas"
            if where_choice == "2":
                if col_names:
                    self.console_write(
                        f"    Variables disponibles: {', '.join(col_names)}",
                        "Cyan",
                    )
                vars_input = (
                    yield {
                        "kind": "prompt",
                        "prompt": "    Variables (separadas por coma, ej: I2, I4)",
                        "buttons": [],
                    }
                ).strip()
                target_vars = vars_input if vars_input else "todas"
            elif where_choice != "1":
                cand_vars = [
                    x.strip()
                    for x in re.split(r"[,;\s]+", where_choice)
                    if x.strip()
                ]
                matched_vars = []
                for cv in cand_vars:
                    found_col = [
                        c
                        for c in col_names
                        if c.lower().startswith(cv.lower())
                        or c.lower() == cv.lower()
                    ]
                    if found_col:
                        matched_vars.extend(found_col)
                    else:
                        matched_vars.append(cv)
                if matched_vars:
                    seen = []
                    for mv in matched_vars:
                        if mv not in seen:
                            seen.append(mv)
                    target_vars = ", ".join(seen)

            na_rules.append({"Value": na_val, "Variables": target_vars})
            if target_vars == "todas":
                self.console_write(
                    f"    [OK] Regla registrada: valor {na_val} -> NA en TODAS {scope}",
                    "Green",
                )
            else:
                self.console_write(
                    f"    [OK] Regla registrada: valor {na_val} -> NA solo en: {target_vars}",
                    "Green",
                )

            add_more = (
                yield {
                    "kind": "prompt",
                    "prompt": "    Agregar otra regla de NA? [S/N, ENTER = N]",
                    "buttons": [
                        ("[ENTER / N] No", "N", "btn_default"),
                        ("[S] Si", "S", ""),
                    ],
                }
            ).strip()
            if not re.match(r"(?i)^s", add_more):
                adding_rules = False

        if not na_rules:
            self.console_write(
                "    [OK] Sin recodificacion de faltantes.", "Green"
            )
            return ""

        parts = []
        for r in na_rules:
            if r["Variables"] == "todas":
                parts.append(
                    f'datos[["VARIABLE"]][datos[["VARIABLE"]] %in% c({r["Value"]})] <- NA para cada variable analizada'
                )
            else:
                vs = [
                    v.strip()
                    for v in re.split(r"[,;\s]+", r["Variables"])
                    if v.strip()
                ]
                for v in vs:
                    parts.append(
                        f'datos[["{v}"]][datos[["{v}"]] %in% c({r["Value"]})] <- NA'
                    )
        directive = "; ".join(parts)

        self.console_write("", "White")
        self.console_write(
            "    ================================================", "Cyan"
        )
        self.console_write(
            "    RESUMEN DE REGLAS DE NA CONFIRMADAS:", "Cyan"
        )
        for r in na_rules:
            if r["Variables"] == "todas":
                self.console_write(
                    f"      - Valor {r['Value']} -> NA en TODAS {scope}",
                    "White",
                )
            else:
                self.console_write(
                    f"      - Valor {r['Value']} -> NA en: {r['Variables']}",
                    "White",
                )
        self.console_write(
            "    ================================================", "Cyan"
        )
        return directive

    def _get_structured_item_inversion(self, step_number: str):
        col_names, _, _ = charly_engine.get_profile_columns_and_values()

        self.console_write(
            f"\n {step_number}. Inversion de items (polaridad inversa):",
            "White",
        )
        self.console_write(
            "    Si algun item de la bateria esta formulado en sentido contrario",
            "Gray",
        )
        self.console_write(
            "    al resto (ej: item negativo en una escala positiva), debe invertirse.",
            "Gray",
        )
        self.console_write("", "White")
        self.console_write(
            "    [1] No hay items a invertir [DEFAULT]", "Green"
        )
        self.console_write(
            "    [2] Si, hay items con polaridad inversa", "Gray"
        )

        has_inv = (
            yield {
                "kind": "prompt",
                "prompt": "    Selecciona (1-2) [ENTER = 1]",
                "buttons": [
                    (
                        "[ENTER / 1] No hay items a invertir [DEFAULT]",
                        "1",
                        "btn_default",
                    ),
                    ("[2] Si, hay items con polaridad inversa", "2", ""),
                ],
            }
        ).strip()
        if not has_inv:
            has_inv = "1"

        if has_inv != "2":
            self.console_write("    [OK] Sin inversion de items.", "Green")
            return ""

        if col_names:
            self.console_write(
                f"    Variables disponibles: {', '.join(col_names)}", "Cyan"
            )
        items_input = (
            yield {
                "kind": "prompt",
                "prompt": "    Items a invertir (separados por coma, ej: I8, I22)",
                "buttons": [],
            }
        ).strip()
        if not items_input:
            self.console_write("    [OK] Sin inversion de items.", "Green")
            return ""

        items = [
            it.strip()
            for it in re.split(r"[,;\s]+", items_input)
            if it.strip()
        ]
        parts = [
            f"datos[['{it}']] <- max(datos[['{it}']], na.rm=TRUE) + min(datos[['{it}']], na.rm=TRUE) - datos[['{it}']]"
            for it in items
        ]
        directive = "; ".join(parts)

        self.console_write("", "White")
        self.console_write(
            "    ================================================", "Cyan"
        )
        self.console_write("    ITEMS A INVERTIR CONFIRMADOS:", "Cyan")
        for it in items:
            self.console_write(
                f"      - {it} (formula: max + min - valor)", "White"
            )
        self.console_write(
            "    ================================================", "Cyan"
        )
        return directive

    def _get_structured_continuous_exceptions(
        self, step_number: str, estimator: str
    ):
        if estimator != "WLSMV":
            return ""

        col_names, _, _ = charly_engine.get_profile_columns_and_values()

        self.console_write(
            f"\n {step_number}. Excepciones de tipo de variable (continua vs ordinal):",
            "White",
        )
        self.console_write(
            "    Seleccionaste WLSMV, por lo que todos los items del modelo",
            "Gray",
        )
        self.console_write(
            "    se tratan como ORDINALES (van al vector ordered = c(...)).",
            "Gray",
        )
        self.console_write(
            "    Si alguna variable debe tratarse como CONTINUA (excluirla",
            "Gray",
        )
        self.console_write("    del vector ordered), indicalo aca.", "Gray")
        self.console_write("", "White")
        self.console_write(
            "    [1] No, todas las variables son ordinales [DEFAULT]", "Green"
        )
        self.console_write(
            "    [2] Si, hay variables que deben ser continuas", "Gray"
        )

        has_exc = (
            yield {
                "kind": "prompt",
                "prompt": "    Selecciona (1-2) [ENTER = 1]",
                "buttons": [
                    (
                        "[ENTER / 1] No, todas las variables son ordinales [DEFAULT]",
                        "1",
                        "btn_default",
                    ),
                    ("[2] Si, hay variables que deben ser continuas", "2", ""),
                ],
            }
        ).strip()
        if not has_exc:
            has_exc = "1"

        if has_exc != "2":
            self.console_write(
                "    [OK] Todas las variables tratadas como ordinales.", "Green"
            )
            return ""

        if col_names:
            self.console_write(
                f"    Variables disponibles: {', '.join(col_names)}", "Cyan"
            )
        vars_input = (
            yield {
                "kind": "prompt",
                "prompt": "    Variables CONTINUAS (separadas por coma, ej: RECOMENDACION, EDAD)",
                "buttons": [],
            }
        ).strip()
        if not vars_input:
            self.console_write(
                "    [OK] Todas las variables tratadas como ordinales.", "Green"
            )
            return ""

        vs = [
            v.strip() for v in re.split(r"[,;\s]+", vars_input) if v.strip()
        ]
        self.console_write("", "White")
        self.console_write(
            "    ================================================", "Cyan"
        )
        self.console_write("    VARIABLES CONTINUAS CONFIRMADAS:", "Cyan")
        self.console_write(
            "    (se EXCLUYEN del vector ordered = c(...))", "Cyan"
        )
        for v in vs:
            self.console_write(f"      - {v}", "White")
        self.console_write(
            "    ================================================", "Cyan"
        )

        return f"Las siguientes variables NO deben incluirse en el vector ordered (tratarlas como CONTINUAS, no ordinales): {', '.join(vs)}. Usar setdiff() para excluirlas del vector ordered si es necesario."

    def _get_structured_category_cleaning(self, step_number: str):
        col_names, _, col_info = charly_engine.get_profile_columns_and_values()

        self.console_write(
            f"\n {step_number}. Filtrado de categorias en variables nominales:",
            "White",
        )
        self.console_write(
            "    Si alguna variable categorica (ej: GENERO, COBERTURA) debe",
            "Gray",
        )
        self.console_write(
            "    restringirse a ciertos valores (pasar el resto a NA), indicalo aca.",
            "Gray",
        )
        self.console_write(
            "    IMPORTANTE: Se pregunta que categorias CONSERVAR (las demas",
            "Yellow",
        )
        self.console_write("    se eliminan automaticamente).", "Yellow")
        self.console_write("", "White")
        self.console_write(
            "    [1] No, conservar todas las categorias tal cual estan [DEFAULT]",
            "Green",
        )
        self.console_write(
            "    [2] Si, deseo filtrar categorias (especificar cuales CONSERVAR)",
            "Gray",
        )

        has_cat = (
            yield {
                "kind": "prompt",
                "prompt": "    Selecciona (1-2) [ENTER = 1]",
                "buttons": [
                    (
                        "[ENTER / 1] No, conservar todas las categorias [DEFAULT]",
                        "1",
                        "btn_default",
                    ),
                    ("[2] Si, deseo filtrar categorias", "2", ""),
                ],
            }
        ).strip()
        if not has_cat:
            has_cat = "1"

        if has_cat != "2":
            self.console_write(
                "    [OK] Sin filtrado de categorias (se conservan todas).",
                "Green",
            )
            return ""

        cat_rules = []
        adding_rules = True

        while adding_rules:
            self.console_write("", "White")
            if col_names:
                self.console_write(
                    f"    Variables disponibles: {', '.join(col_names)}", "Cyan"
                )
            var_name = (
                yield {
                    "kind": "prompt",
                    "prompt": "    Nombre de la variable a limpiar (ej: GENERO)",
                    "buttons": [],
                }
            ).strip()
            if not var_name:
                adding_rules = False
                continue

            # Buscar nombre exacto en col_info
            matched_key = var_name
            for k in col_info.keys():
                if k.lower() == var_name.lower():
                    matched_key = k
                    break
            if matched_key in col_info:
                vals_str = ", ".join(str(x) for x in col_info[matched_key])
                self.console_write(
                    f"    Categorias detectadas en {matched_key}: {vals_str}",
                    "Cyan",
                )

            keep_input = (
                yield {
                    "kind": "prompt",
                    "prompt": f"    Categorias a CONSERVAR en {matched_key} (separadas por coma, ej: 1, 2)",
                    "buttons": [],
                }
            ).strip()
            if not keep_input:
                self.console_write(
                    "    [AVISO] No se indicaron categorias. Se descarta esta regla.",
                    "Yellow",
                )
                add_more = (
                    yield {
                        "kind": "prompt",
                        "prompt": "    Agregar otra variable? [S/N, ENTER = N]",
                        "buttons": [
                            ("[ENTER / N] No", "N", "btn_default"),
                            ("[S] Si", "S", ""),
                        ],
                    }
                ).strip()
                if re.match(r"(?i)^s", add_more):
                    continue
                else:
                    adding_rules = False
                    continue

            keep_vals = [
                v.strip()
                for v in re.split(r"[,;\s]+", keep_input)
                if v.strip()
            ]
            cat_rules.append({"Variable": matched_key, "KeepValues": keep_vals})
            self.console_write(
                f"    [OK] Regla registrada: en {matched_key}, conservar solo las filas con: {', '.join(keep_vals)} (se excluyen el resto de las categorias)",
                "Green",
            )

            add_more = (
                yield {
                    "kind": "prompt",
                    "prompt": "    Agregar otra variable? [S/N, ENTER = N]",
                    "buttons": [
                        ("[ENTER / N] No", "N", "btn_default"),
                        ("[S] Si", "S", ""),
                    ],
                }
            ).strip()
            if not re.match(r"(?i)^s", add_more):
                adding_rules = False

        if not cat_rules:
            self.console_write("    [OK] Sin limpieza de categorias.", "Green")
            return ""

        parts = []
        for r in cat_rules:
            keep_str = ", ".join(r["KeepValues"])
            parts.append(
                f"datos <- datos[datos[['{r['Variable']}']] %in% c({keep_str}), ]"
            )
        directive = "; ".join(parts)

        self.console_write("", "White")
        self.console_write(
            "    ================================================", "Cyan"
        )
        self.console_write(
            "    LIMPIEZA DE CATEGORIAS CONFIRMADA:", "Cyan"
        )
        for r in cat_rules:
            self.console_write(
                f"      - {r['Variable']}: conservar solo filas con ({', '.join(r['KeepValues'])}), excluyendo el resto",
                "White",
            )
        self.console_write(
            "    ================================================", "Cyan"
        )
        return directive

    def _invoke_structured_mediation_selector(
        self, arrow_directives: list[dict]
    ):
        detected_paths = charly_engine.get_all_causal_paths(arrow_directives)

        self.console_write(
            "\n ==========================================================================",
            "Cyan",
        )
        self.console_write(
            "  ASISTENTE ESTRUCTURAL: MEDIACIONES Y EFECTOS TOTALES (Seleccion sin texto libre)",
            "Cyan",
        )
        self.console_write(
            " ==========================================================================",
            "Cyan",
        )

        if not detected_paths:
            self.console_write(
                " No se detectaron cadenas indirectas de 3 o mas variables a partir de las flechas.",
                "Yellow",
            )
            self.console_write(
                " Se modelaran exclusivamente los senderos directos en lavaan.",
                "Gray",
            )
            return {"Mediaciones": [], "EfectosTotales": []}

        self.console_write(
            "\n Rutas indirectas detectadas a partir de tus flechas directas:",
            "White",
        )
        for i, dp in enumerate(detected_paths, start=1):
            self.console_write(f"  [{i}] {dp}", "Green")

        self.console_write(
            "\n 1. ¿Cuales rutas indirectas queres calcular con el operador ':='?",
            "White",
        )
        self.console_write(
            "    [1] Todas las rutas detectadas [DEFAULT]", "Green"
        )
        self.console_write(
            "    [2] Elegir rutas por numero (ej: 1, 2, 3)", "Gray"
        )
        self.console_write("    [3] Ninguna ruta indirecta", "Gray")
        opt_rutas = (
            yield {
                "kind": "prompt",
                "prompt": "    Selecciona (1-3) [ENTER = 1]",
                "buttons": [
                    (
                        "[ENTER / 1] Todas las rutas detectadas [DEFAULT]",
                        "1",
                        "btn_default",
                    ),
                    ("[2] Elegir rutas por numero", "2", ""),
                    ("[3] Ninguna ruta indirecta", "3", "btn_secondary"),
                ],
            }
        ).strip()
        if not opt_rutas:
            opt_rutas = "1"

        selected_paths = []
        if opt_rutas == "1":
            selected_paths = list(detected_paths)
        elif opt_rutas == "2":
            nums_input = (
                yield {
                    "kind": "prompt",
                    "prompt": "    Ingresa los numeros a incluir (separados por coma, ej: 1, 2, 3)",
                    "buttons": [],
                }
            ).strip()
            for tok in re.split(r"[,;\s]+", nums_input):
                if tok.isdigit():
                    idx = int(tok) - 1
                    if 0 <= idx < len(detected_paths):
                        selected_paths.append(detected_paths[idx])

        pair_map: dict[str, list[str]] = {}
        for p in selected_paths:
            parts = [x.strip() for x in re.split(r"\s*->\s*", p) if x.strip()]
            if len(parts) >= 2:
                key = f"{parts[0]} -> {parts[-1]}"
                pair_map.setdefault(key, []).append(p)

        all_pairs = list(pair_map.keys())
        selected_totals = []

        if all_pairs:
            self.console_write(
                "\n 2. ¿Calcular el Efecto Indirecto Sumado para los predictores focales?",
                "White",
            )
            self.console_write(
                "    (Suma formal de todas las rutas indirectas entre el predictor y el desenlace)",
                "Gray",
            )
            for p_key in all_pairs:
                p_count = len(pair_map[p_key])
                self.console_write(
                    f"      - Par {p_key} ({p_count} ruta/s indirecta/s)",
                    "Cyan",
                )
            self.console_write(
                "    [1] Si, calcular efecto indirecto sumado para todos los pares clave [DEFAULT]",
                "Green",
            )
            self.console_write(
                "    [2] No calcular efecto indirecto sumado", "Gray"
            )
            opt_sum = (
                yield {
                    "kind": "prompt",
                    "prompt": "    Selecciona (1-2) [ENTER = 1]",
                    "buttons": [
                        (
                            "[ENTER / 1] Si, calcular efecto indirecto sumado [DEFAULT]",
                            "1",
                            "btn_default",
                        ),
                        ("[2] No", "2", "btn_secondary"),
                    ],
                }
            ).strip()
            if not opt_sum:
                opt_sum = "1"

            if opt_sum == "1":
                for k in all_pairs:
                    parts = [x.strip() for x in re.split(r"\s*->\s*", k)]
                    src, dst = parts[0], parts[1]
                    selected_totals.append(
                        f"Efecto indirecto sumado de {src} sobre {dst} (suma exclusiva de todas las rutas indirectas que nacen en {src} y terminan en {dst})"
                    )

            self.console_write(
                "\n 3. ¿Calcular el Efecto Total de cada predictor focal sobre el desenlace?",
                "White",
            )
            self.console_write(
                "    NOTA METODOLOGICA: Se calcula sumando el sendero directo del predictor mas",
                "Yellow",
            )
            self.console_write(
                "    sus rutas indirectas. Se excluyen terminantemente covariables de control u otras variables independientes ajenas al predictor.",
                "Yellow",
            )
            self.console_write(
                "    [1] Si, calcular Efecto Total para cada predictor focal [DEFAULT]",
                "Green",
            )
            self.console_write("    [2] No calcular efecto total", "Gray")
            opt_tot = (
                yield {
                    "kind": "prompt",
                    "prompt": "    Selecciona (1-2) [ENTER = 1]",
                    "buttons": [
                        (
                            "[ENTER / 1] Si, calcular Efecto Total [DEFAULT]",
                            "1",
                            "btn_default",
                        ),
                        ("[2] No", "2", "btn_secondary"),
                    ],
                }
            ).strip()
            if not opt_tot:
                opt_tot = "1"

            if opt_tot == "1":
                for k in all_pairs:
                    parts = [x.strip() for x in re.split(r"\s*->\s*", k)]
                    src, dst = parts[0], parts[1]
                    selected_totals.append(
                        f"Efecto total de {src} sobre {dst} = sendero directo de {src} sobre {dst} mas la suma exclusiva de sus propios efectos indirectos (PROHIBIDO sumar o incluir coeficientes de otras variables independientes, covariables de control o senderos no pertenecientes al predictor {src})"
                    )

        self.console_write(
            "\n    ================================================", "Cyan"
        )
        self.console_write(
            "    ESTRUCTURA Y MEDIACIONES CONFIRMADAS:", "Cyan"
        )
        if selected_paths:
            self.console_write(
                "      - Rutas indirectas a computar (:=):", "White"
            )
            for sp in selected_paths:
                self.console_write(f"        * {sp}", "Green")
        else:
            self.console_write(
                "      - Rutas indirectas: [Ninguna]", "DarkGray"
            )
        if selected_totals:
            self.console_write(
                "      - Efectos sumados y totales (:=):", "White"
            )
            for st in selected_totals:
                self.console_write(f"        * {st}", "Green")
        self.console_write(
            "    ================================================", "Cyan"
        )

        return {"Mediaciones": selected_paths, "EfectosTotales": selected_totals}

    def _render_profiler_stdout(self, stdout_text: str):
        for line in stdout_text.splitlines():
            col = "White"
            if line.startswith("[PASO 2/5]"):
                col = "Cyan"
            elif line.startswith("---") or line.startswith("VARIABLE"):
                col = "DarkGray" if line.startswith("---") else "Yellow"
            elif "[AVISO" in line:
                col = "Yellow"
            elif "[EXITO]" in line:
                col = "Green"
            elif "[ERROR" in line:
                col = "Red"
            self.console_write(line, col)

def main():
    app = QApplication(sys.argv)
    ico_path = Path(__file__).resolve().parent / "peperina.ico"
    png_path = Path(__file__).resolve().parent / "peperina.png"
    if ico_path.exists():
        app.setWindowIcon(QIcon(str(ico_path)))
    elif png_path.exists():
        app.setWindowIcon(QIcon(str(png_path)))

    win = CharlyApp()
    win.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    main()
