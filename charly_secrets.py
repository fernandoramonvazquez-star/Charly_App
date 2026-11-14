#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""charly_secrets.py — Gestión segura y cifrada de credenciales y entorno para Charly App."""

import base64
import copy
import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path

APP_NAME = "Charly_App"
CONFIG_FILE = "settings.json"

# Serializa lecturas/escrituras de settings.json entre el hilo de la GUI y los workers.
_LOCK = threading.RLock()
# [G4] Cache de la ultima lectura valida, validada por (ruta, mtime_ns, tamano). Antes cada subproceso releia el JSON y
# volvia a descifrar con DPAPI.
_CACHE: dict = {"key": None, "value": None}


class SecretError(RuntimeError):
    """No se pudo cifrar/descifrar un secreto (nunca se degrada en silencio a texto plano)."""


def config_dir() -> Path:
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    d = Path(base) / APP_NAME
    d.mkdir(parents=True, exist_ok=True)
    return d


def config_path() -> Path:
    return config_dir() / CONFIG_FILE


# ---------------------------------------------------------------------------
# DPAPI (CryptProtectData / CryptUnprotectData)
# ---------------------------------------------------------------------------
_IS_WIN = sys.platform.startswith("win")
_crypt32 = None
_kernel32 = None
_BLOB = None

if _IS_WIN:
    import ctypes
    from ctypes import wintypes

    class _BLOB(ctypes.Structure):  # DATA_BLOB
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    # DLLs privadas (no el ctypes.windll global compartido) con firmas explícitas.
    _crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _crypt32.CryptProtectData.argtypes = [
        ctypes.POINTER(_BLOB), wintypes.LPCWSTR, ctypes.POINTER(_BLOB),
        wintypes.LPVOID, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(_BLOB),
    ]
    _crypt32.CryptUnprotectData.argtypes = [
        ctypes.POINTER(_BLOB), ctypes.POINTER(wintypes.LPWSTR), ctypes.POINTER(_BLOB),
        wintypes.LPVOID, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(_BLOB),
    ]
    _crypt32.CryptProtectData.restype = wintypes.BOOL
    _crypt32.CryptUnprotectData.restype = wintypes.BOOL
    _kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    _kernel32.LocalFree.restype = wintypes.HLOCAL


def _dpapi(fn, data: bytes, what: str) -> bytes:
    """Ejecuta CryptProtectData/CryptUnprotectData. Lanza SecretError si falla (flag 1 = UI_FORBIDDEN)."""
    buf = ctypes.create_string_buffer(data, len(data))
    entry = _BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    out = _BLOB()
    if not fn(ctypes.byref(entry), None, None, None, None, 1, ctypes.byref(out)):
        raise SecretError(f"DPAPI no pudo {what} (WinError {ctypes.get_last_error()}).")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        _kernel32.LocalFree(out.pbData)


def encrypt_key(plain: str) -> str:
    """Cifra con DPAPI (prefijo 'dpapi:'). Fuera de Windows usa 'plain:' (honesto: NO es cifrado)."""
    if not plain:
        return ""
    raw = plain.encode("utf-8")
    if not _IS_WIN:
        return "plain:" + base64.b64encode(raw).decode("ascii")
    return "dpapi:" + base64.b64encode(_dpapi(_crypt32.CryptProtectData, raw, "cifrar la clave")).decode("ascii")


def decrypt_key(token: str) -> str:
    """
    Devuelve la clave en claro o lanza SecretError si no se puede recuperar (p.ej. settings.json
    copiado a otro usuario/PC). NUNCA devuelve el blob cifrado como si fuera la clave.
    """
    if not token:
        return ""
    try:
        if token.startswith("dpapi:"):
            if not _IS_WIN:
                raise SecretError("La clave fue cifrada con DPAPI de Windows y no puede leerse en este sistema.")
            raw = base64.b64decode(token[6:])
            return _dpapi(_crypt32.CryptUnprotectData, raw, "descifrar la clave").decode("utf-8")
        if token.startswith("plain:"):
            return base64.b64decode(token[6:]).decode("utf-8")
    except SecretError:
        raise
    except Exception as e:
        raise SecretError(f"Clave almacenada ilegible: {e}") from e
    return token  # formato legado: clave en claro


# ---------------------------------------------------------------------------
# Ajustes
# ---------------------------------------------------------------------------
def _first_existing(candidates) -> str:
    for c in candidates:
        if c and os.path.isfile(c):
            return str(c)
    return ""


def default_settings() -> dict:
    local_app = os.environ.get("LOCALAPPDATA", "")
    default_srv = _first_existing([
        os.environ.get("CHARLY_LLAMA_SERVER_EXE"),
        shutil.which("llama-server"),
        os.path.join(local_app, APP_NAME, "llama-cpp", "llama-server.exe") if local_app else "",
        r"C:\llama-cpp\llama-server.exe",
    ])
    default_mod = _first_existing([
        os.environ.get("CHARLY_LOCAL_MODEL_PATH"),
        os.path.join(local_app, APP_NAME, "llama-cpp", "models", "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf") if local_app else "",
        r"C:\llama-cpp\models\Qwen3.6-35B-A3B-UD-Q4_K_M.gguf",
    ])
    return {
        "engine": "cloud",
        "model": "gemini-flash-lite-latest",  # gemini-2.5-flash devuelve 404 para cuentas nuevas
        "api_key": "",
        "r_home": "",
        "local_mode": "llama_server" if default_srv else "endpoint",
        "local_host": "http://127.0.0.1:8090",
        "local_model_name": "local-model",
        "llama_server_exe": default_srv,
        "gguf_model_path": default_mod,
    }


def load_settings() -> dict:
    """
    Lee settings.json. Un JSON corrupto NO se descarta en silencio: se conserva como
    settings.corrupt-<ts>.json y se devuelven los valores por defecto. Si la clave guardada no se
    puede descifrar, se devuelve api_key="" y '_api_key_unreadable'=True (la GUI lo avisa).
    """
    with _LOCK:
        f = config_path()
        try:
            st = f.stat()
            cache_key = (str(f), st.st_mtime_ns, st.st_size)
        except OSError:
            cache_key = None
        if cache_key is not None and _CACHE["key"] == cache_key:
            return copy.deepcopy(_CACHE["value"])
        defaults = default_settings()
        if not f.exists():
            return defaults
        try:
            data = json.loads(f.read_text(encoding="utf-8-sig"))
            if not isinstance(data, dict):
                raise ValueError("settings.json no es un objeto JSON")
        except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
            try:
                f.replace(f.with_name(f"settings.corrupt-{int(time.time())}.json"))
            except OSError:
                pass
            return defaults
        except OSError:
            return defaults
        merged = dict(defaults)
        if "api_key_encrypted" in data:
            token = data.pop("api_key_encrypted")
            try:
                data["api_key"] = decrypt_key(token)
            except SecretError:
                data["api_key"] = ""
                merged["_api_key_unreadable"] = bool(token)
        merged.update(data)
        if cache_key is not None:
            _CACHE["key"], _CACHE["value"] = cache_key, copy.deepcopy(merged)
        return merged


def _atomic_write_text(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)  # atómico en NTFS: nunca queda un JSON a medio escribir


def save_settings(settings: dict) -> None:
    """
    Guarda settings.json de forma atómica. Si no se puede cifrar la clave, el resto de los ajustes
    se guarda igual (sin clave) y se lanza SecretError para que la GUI avise: jamás se escribe
    la clave en claro.
    """
    with _LOCK:
        f = config_path()
        to_save = dict(default_settings())
        to_save.update(settings)
        for k in [k for k in to_save if k.startswith("_")]:
            to_save.pop(k)  # banderas internas (p.ej. _api_key_unreadable) no se persisten
        plain_key = to_save.pop("api_key", "")
        secret_error = None
        try:
            to_save["api_key_encrypted"] = encrypt_key(plain_key)
        except SecretError as e:
            secret_error = e
            to_save["api_key_encrypted"] = ""
        _atomic_write_text(f, json.dumps(to_save, indent=2, ensure_ascii=False))
        _CACHE["key"] = None  # invalida la cache (el mtime podria coincidir en escrituras muy seguidas)
        if secret_error is not None:
            raise SecretError(f"{secret_error} La API Key NO se guardó; los demás ajustes sí.")
