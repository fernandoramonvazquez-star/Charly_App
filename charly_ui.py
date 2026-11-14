#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
charly_ui.py — Piezas reutilizables de la interfaz de Charly App (extraidas de Charly_App.py):
estilo, mapa de colores, dialogo de entrada, worker de hilos, consola con buffer y pasos tipados del asistente.
"""

import unicodedata
from dataclasses import dataclass, field
from typing import Any, Callable

from PySide6.QtCore import QThread, QTimer, Signal
from PySide6.QtGui import QTextCursor
from PySide6.QtWidgets import (
    QDialog,
    QHBoxLayout,
    QLabel,
    QPlainTextEdit,
    QPushButton,
    QTextBrowser,
    QVBoxLayout,
)

CHARLY_STYLE = """
QMainWindow {
    background-color: #0D1117;
}
QTabWidget::pane {
    border: 1px solid #30363D;
    background-color: #0D1117;
    border-radius: 6px;
}
QTabBar::tab {
    background: #161B22;
    border: 1px solid #30363D;
    padding: 8px 16px;
    font-size: 12px;
    font-weight: 700;
    color: #8B949E;
    border-top-left-radius: 5px;
    border-top-right-radius: 5px;
    margin-right: 3px;
}
QTabBar::tab:selected {
    background: #0D1117;
    color: #58A6FF;
    border-bottom: 2px solid #58A6FF;
}
QPushButton {
    background-color: #1F6FEB;
    color: #FFFFFF;
    font-weight: bold;
    font-size: 12px;
    border-radius: 5px;
    padding: 7px 14px;
    border: 1px solid #388BFD;
}
QPushButton:hover {
    background-color: #388BFD;
}
QPushButton#btn_default {
    background-color: #238636;
    border: 1px solid #2EA043;
    font-size: 12px;
}
QPushButton#btn_default:hover {
    background-color: #2EA043;
}
QPushButton#btn_warn {
    background-color: #9E6A03;
    border: 1px solid #D29922;
}
QPushButton#btn_warn:hover {
    background-color: #BB8009;
}
QPushButton#btn_danger {
    background-color: #DA3633;
    border: 1px solid #F85149;
}
QPushButton#btn_danger:hover {
    background-color: #F85149;
}
QPushButton#btn_secondary {
    background-color: #21262D;
    border: 1px solid #30363D;
    color: #C9D1D9;
}
QPushButton#btn_secondary:hover {
    background-color: #30363D;
}
QLineEdit {
    background-color: #161B22;
    color: #F0F6FC;
    border: 1.5px solid #388BFD;
    border-radius: 5px;
    padding: 7px 10px;
    font-family: 'Consolas', monospace;
    font-size: 13px;
}
QPlainTextEdit, QTextEdit, QTextBrowser {
    background-color: #090D16;
    color: #E6EDF3;
    border: 1px solid #30363D;
    border-radius: 6px;
    font-family: 'Consolas', 'Courier New', monospace;
}
"""

PS_COLOR_MAP = {
    "Cyan": "#39C5BB",
    "DarkCyan": "#2A9D8F",
    "Yellow": "#F2CC60",
    "DarkYellow": "#D29922",
    "Green": "#56D364",
    "White": "#E6EDF3",
    "DarkGray": "#8B949E",
    "Gray": "#B1BAC4",
    "Red": "#FF7B72",
    "Magenta": "#D2A8FF",
}


def _strip_accents(s: str) -> str:
    nfd = unicodedata.normalize("NFD", s or "")
    return "".join(c for c in nfd if unicodedata.category(c) != "Mn")


class ShowInputWindowDialog(QDialog):
    """Idéntico a Show-InputWindow (líneas 662-730 de charly_core.ps1)."""

    def __init__(self, parent=None, initial_text: str = ""):
        super().__init__(parent)
        self.setWindowTitle("Charly v4 - Instruccion del Investigador")
        self.resize(720, 520)
        self.setStyleSheet("""
            QDialog { background-color: #1E1E1E; color: #FFFFFF; }
            QLabel { color: #00FFFF; font-family: 'Segoe UI'; font-size: 13px; font-weight: bold; }
            QPlainTextEdit { background-color: #141414; color: #DCDCDC; font-family: 'Consolas'; font-size: 13px; border: 1px solid #3F3F46; }
        """)
        lay = QVBoxLayout(self)
        lbl = QLabel(
            " Pega o escribe tu instruccion psicometrica (acepta multiples lineas sin dispararse):"
        )
        lay.addWidget(lbl)

        self.txt_box = QPlainTextEdit()
        self.txt_box.setPlainText(initial_text)
        lay.addWidget(self.txt_box, 1)

        btn_row = QHBoxLayout()
        btn_row.addStretch()

        btn_cancel = QPushButton("Cancelar")
        btn_cancel.setStyleSheet(
            "background-color: #282828; color: #D3D3D3; padding: 8px 18px;"
        )
        btn_cancel.clicked.connect(self.reject)
        btn_row.addWidget(btn_cancel)

        btn_ok = QPushButton("Aceptar y Ejecutar")
        btn_ok.setStyleSheet(
            "background-color: #007ACC; color: white; font-weight: bold; padding: 8px 22px;"
        )
        btn_ok.clicked.connect(self.accept)
        btn_row.addWidget(btn_ok)

        lay.addLayout(btn_row)

    def get_text(self) -> str:
        return self.txt_box.toPlainText().strip()


class AsyncTaskWorker(QThread):
    line_signal = Signal(str, str)
    token_signal = Signal(str, str)
    done_signal = Signal(object)

    def __init__(self, fn, *args, **kwargs):
        super().__init__()
        self.fn = fn
        self.args = args
        self.kwargs = kwargs

    def run(self):
        import traceback

        payload = {"ok": False, "error": "La tarea termino sin devolver resultado."}
        try:
            payload = {"ok": True, "result": self.fn(*self.args, **self.kwargs)}
        except BaseException as e:  # noqa: BLE001 - nunca dejar al generador esperando
            payload = {
                "ok": False,
                "error": f"{type(e).__name__}: {e}",
                "traceback": traceback.format_exc(),
            }
        finally:
            self.done_signal.emit(payload)  # SIEMPRE emite


class AutoScrollConsole(QTextBrowser):
    """
    Consola de texto enriquecido para salida en vivo.
    - Buffer: los fragmentos se acumulan y se vuelcan cada ~40 ms con UN solo insertHtml (antes: un insertHtml, dos
      scrolls y un QTimer por token => miles de operaciones por generacion).
    - Scroll "pegajoso": sigue el final solo si el usuario ya estaba al final (si subio a leer, no se lo arrastra).
    - Se inserta con un cursor propio (no toca la seleccion del usuario) y se recorta al superar MAX_CHARS.
    """

    FLUSH_MS = 40
    MAX_CHARS = 1_500_000

    def __init__(self, parent=None):
        super().__init__(parent)
        self.document().setDocumentMargin(12)
        self._pending: list[str] = []
        self._flush_timer = QTimer(self)
        self._flush_timer.setSingleShot(True)
        self._flush_timer.setInterval(self.FLUSH_MS)
        self._flush_timer.timeout.connect(self.flush)

    def _at_bottom(self) -> bool:
        sb = self.verticalScrollBar()
        return (not sb) or sb.value() >= sb.maximum() - 4

    def queue_html(self, fragment: str):
        self._pending.append(fragment)
        if not self._flush_timer.isActive():
            self._flush_timer.start()

    def flush(self):
        if not self._pending:
            return
        self._flush_timer.stop()
        chunk = "".join(self._pending)
        self._pending.clear()
        stick = self._at_bottom()
        cur = QTextCursor(self.document())
        cur.movePosition(QTextCursor.MoveOperation.End)
        cur.insertHtml(chunk)
        excess = self.document().characterCount() - self.MAX_CHARS
        if excess > 0:
            trim = QTextCursor(self.document())
            trim.setPosition(0)
            trim.setPosition(excess, QTextCursor.MoveMode.KeepAnchor)
            trim.removeSelectedText()
        if stick:
            sb = self.verticalScrollBar()
            sb.setValue(sb.maximum())

    def clear(self):
        self._pending.clear()
        self._flush_timer.stop()
        super().clear()

    def resizeEvent(self, event):
        was_bottom = self._at_bottom()  # se mide ANTES: el redimensionado cambia el maximo
        super().resizeEvent(event)
        if was_bottom:
            sb = self.verticalScrollBar()
            if sb:
                sb.setValue(sb.maximum())


# ---------------------------------------------------------------------------
# Pasos tipados del asistente (el generador puede ceder dicts clasicos o estas dataclasses)
# ---------------------------------------------------------------------------
@dataclass
class PromptStep:
    """Pide un dato al usuario (equivale a {"kind": "prompt", ...})."""

    prompt: str = "Selecciona una opcion"
    buttons: list = field(default_factory=list)  # [(etiqueta, valor, id_estilo), ...]
    show_multiline_goal: bool = False

    def to_spec(self) -> dict:
        return {
            "kind": "prompt",
            "prompt": self.prompt,
            "buttons": list(self.buttons),
            "show_multiline_goal": self.show_multiline_goal,
        }


@dataclass
class AsyncStep:
    """Ejecuta fn en un hilo (equivale a {"kind": "async", ...})."""

    fn: Callable[..., Any]
    status_label: str = "Procesando en R / IA..."
    args: tuple = ()
    kwargs: dict = field(default_factory=dict)
    stream_lines: bool = False
    stream_tokens: bool = False

    def to_spec(self) -> dict:
        return {
            "kind": "async",
            "fn": self.fn,
            "status_label": self.status_label,
            "args": tuple(self.args),
            "kwargs": dict(self.kwargs),
            "stream_lines": self.stream_lines,
            "stream_tokens": self.stream_tokens,
        }


def continue_prompt(text: str = "Presiona ENTER para continuar", button: str = "[ENTER] Continuar") -> PromptStep:
    """Paso 'Presiona ENTER para continuar' (se repetia ~20 veces como dict literal)."""
    return PromptStep(prompt=text, buttons=[(button, "", "btn_default")])


def as_spec(step: Any) -> dict:
    """Normaliza y VALIDA un paso cedido por el generador (dict o dataclass); errores claros en vez de KeyError."""
    spec = step.to_spec() if hasattr(step, "to_spec") else step
    if not isinstance(spec, dict):
        raise TypeError(f"El asistente cedio un paso invalido ({type(step).__name__}); se esperaba dict, PromptStep o AsyncStep.")
    kind = spec.get("kind", "prompt")
    if kind not in ("prompt", "async"):
        raise ValueError(f"Tipo de paso desconocido: {kind!r}")
    if kind == "async" and not callable(spec.get("fn")):
        raise ValueError("Paso 'async' sin una funcion 'fn' invocable.")
    return spec
