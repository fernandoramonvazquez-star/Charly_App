#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
charly_engine.py — Puente Canónico 100% Idéntico a CHARLY v4.0 (charly_core.ps1).
Invoca exactamente los mismos scripts R y PowerShell con los mismos argumentos y archivos
que charly_core.ps1:
  - profiler/data_profiler.R -> workspace/dataset_profile.json & workspace/dataset_prompt_block.txt
  - profiler/generate_descriptives_report.R -> workspace/descriptivos_base.txt
  - runtime/psico_parser.ps1 (Get-ArrowDirectives, Get-MediationDirectives, Get-TotalEffectsDirectives)
  - runtime/semantic_parser.ps1 (-UserPrompt)
  - runtime/contract_builder.ps1 (Get-CanonicalArchetype, Build-PsychometricContract, Format-PsychometricContractDisplay)
  - inspector/env_inspector.R -> workspace/r_env_prompt_block.txt
  - templates/prompt_builder.ps1 -> workspace/full_prompt.txt
  - engine/gemini_engine.ps1 & engine/local_engine.ps1 & engine/local_server.ps1 -> workspace/generated_script.R
  - runtime/run_with_repair.ps1 & runtime/contract_auditor.ps1 -> workspace/resultados_analisis.txt & workspace/consola_rstudio_completa.txt
"""

import ctypes
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path
import logging
import logging.handlers

import charly_secrets

# [G6] Registro en %APPDATA%\Charly_App\charly.log (rotativo). Reemplaza muchos 'except Exception: pass' mudos.
# Nunca se registran claves ni el contenido de settings.
log = logging.getLogger("charly")
if not log.handlers:
    log.setLevel(logging.INFO)
    try:
        _h = logging.handlers.RotatingFileHandler(
            charly_secrets.config_dir() / "charly.log", maxBytes=1_000_000, backupCount=3, encoding="utf-8"
        )
        _h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        log.addHandler(_h)
    except Exception:

        log.addHandler(logging.NullHandler())

CHARLY_APP_DIR = Path(__file__).resolve().parent
CHARLY_BUNDLE_DIR = CHARLY_APP_DIR / "charly_core_bundle"

# En distribución y repositorio se usa siempre charly_core_bundle autocontenido:
EXTERNAL_V4_DIR = CHARLY_BUNDLE_DIR
dev_env = os.environ.get("CHARLY_DEV_V4_DIR")
if dev_env and Path(dev_env).exists():
    EXTERNAL_V4_DIR = Path(dev_env)

CHARLY_V4_DIR = CHARLY_BUNDLE_DIR if CHARLY_BUNDLE_DIR.exists() else EXTERNAL_V4_DIR

V4_WORKSPACE = CHARLY_V4_DIR / "workspace"
APP_WORKSPACE = CHARLY_APP_DIR / "workspace"
EXT_WORKSPACE = (EXTERNAL_V4_DIR / "workspace") if EXTERNAL_V4_DIR.exists() else None
V4_WORKSPACE.mkdir(parents=True, exist_ok=True)
APP_WORKSPACE.mkdir(parents=True, exist_ok=True)

NO_WINDOW = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

def _port_of(host: str, default: int | None = None) -> int | None:
    """Puerto numerico de una URL ('http://127.0.0.1:11434' -> 11434). Evita falsos positivos de '"1234" in host'."""
    try:
        from urllib.parse import urlparse

        u = urlparse(host if "://" in host else f"http://{host}")
        return u.port or default
    except Exception:
        return default

_CPU_TOPO_CACHE: dict | None = None

def get_cpu_topology() -> dict:
    """
    Topologia de la CPU (Windows: GetLogicalProcessorInformationEx).
    En CPU hibridas Intel (P + E) identifica los nucleos de RENDIMIENTO (clase de eficiencia mas alta).
    Devuelve: logical, physical, hybrid, p_cores, p_threads_mask (todos los hilos logicos P) y
    p_one_per_core_mask (un hilo logico por nucleo P, sin hermanos de hyper-threading).
    """
    global _CPU_TOPO_CACHE
    if _CPU_TOPO_CACHE is not None:
        return _CPU_TOPO_CACHE
    n = os.cpu_count() or 1
    topo = {"logical": n, "physical": n, "hybrid": False, "p_cores": n, "p_threads_mask": 0, "p_one_per_core_mask": 0}
    try:
        if os.name == "nt":
            from ctypes import wintypes

            k32 = ctypes.WinDLL("kernel32", use_last_error=True)
            k32.GetLogicalProcessorInformationEx.argtypes = [wintypes.DWORD, ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD)]
            k32.GetLogicalProcessorInformationEx.restype = wintypes.BOOL
            size = wintypes.DWORD(0)
            k32.GetLogicalProcessorInformationEx(0, None, ctypes.byref(size))  # 0 = RelationProcessorCore
            buf = ctypes.create_string_buffer(size.value)
            if size.value and k32.GetLogicalProcessorInformationEx(0, buf, ctypes.byref(size)):
                raw, off, cores = buf.raw[: size.value], 0, []
                while off < len(raw):
                    rel, sz = struct.unpack_from("<II", raw, off)
                    if rel == 0 and sz >= 40:
                        eff = raw[off + 9]  # EfficiencyClass (mayor = nucleo de mayor rendimiento)
                        mask = struct.unpack_from("<Q", raw, off + 32)[0]  # GROUP_AFFINITY.Mask (grupo 0)
                        cores.append((eff, mask))
                    off += sz
                if cores:
                    best = max(e for e, _ in cores)
                    p_masks = [m for e, m in cores if e == best]
                    hybrid = len({e for e, _ in cores}) > 1
                    topo.update(
                        physical=len(cores),
                        logical=sum(bin(m).count("1") for _, m in cores),
                        hybrid=hybrid,
                        p_cores=len(p_masks) if hybrid else len(cores),
                    )
                    sel = p_masks if hybrid else [m for _, m in cores]
                    topo["p_threads_mask"] = 0
                    topo["p_one_per_core_mask"] = 0
                    for m in sel:
                        topo["p_threads_mask"] |= m
                        topo["p_one_per_core_mask"] |= m & -m  # bit mas bajo = un hilo por nucleo
    except Exception:
        pass
    _CPU_TOPO_CACHE = topo
    return topo

def recommended_llama_threads() -> tuple[int, int]:
    """
    (hilos de generacion, hilos de lote) para llama-server. Generacion de tokens = limitada por ancho de banda de
    memoria: lo optimo son los nucleos de rendimiento (P) sin hermanos HT ni nucleos E (en una i7-13620H: 6).
    """
    topo = get_cpu_topology()
    gen = max(2, topo["p_cores"] if topo["hybrid"] else topo["physical"])
    # Lote (prompt eval): benchmark en esta CPU -> 12 hilos P+HT dan +8..18 % de pp pero -8 % de tg; se deja igual a gen
    # (override opcional en settings: llama_threads_batch). Con los 16 hilos (nucleos E incluidos) la generacion cae ~20 %.
    # Lote (prompt eval): en llama-bench de esta CPU, 12 hilos P+HT dan +8..18 % de pp pero -8 % de tg; se deja igual a gen
    # (override opcional en settings: llama_threads_batch). Con los 16 hilos (nucleos E incluidos) la generacion cae ~20 %.
    batch = gen
    return gen, batch

def _pid_listening_on(port: int) -> int | None:
    try:
        out = subprocess.run(
            ["netstat", "-ano", "-p", "tcp"], capture_output=True, text=True, stdin=subprocess.DEVNULL,
            creationflags=NO_WINDOW, timeout=10,
        ).stdout
    except Exception:
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0].upper() == "TCP" and parts[3].upper() == "LISTENING" and parts[1].endswith(f":{port}"):
            try:
                return int(parts[4])
            except ValueError:
                return None
    return None

def tune_llama_server(host: str) -> str:
    """
    Prioridad alta SOLO sobre el llama-server que escucha en el puerto de Charly (antes: todos los 'llama-server' del
    equipo). Ya NO se fija afinidad: la mascara fija 0x00FF usaba solo 4 de los 6 nucleos P de la i7-13620H y, medida con
    llama-bench, bajaba la generacion ~10 % frente a 6 hilos sin afinidad (16.5 vs 18.5 t/s); fijar un hilo por nucleo P
    con la mascara de llama.cpp (-C 0x555) la hundia a 6 t/s.
    """
    if os.name != "nt":
        return "no-windows"
    port = _port_of(host, 8090) or 8090
    pid = _pid_listening_on(port)
    if not pid:
        return f"sin servidor en el puerto {port}"
    from ctypes import wintypes

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    k32.SetPriorityClass.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    h = k32.OpenProcess(0x0200 | 0x1000, False, pid)  # SET_INFORMATION | QUERY_LIMITED_INFORMATION (0x0200 incluye SetProcessAffinityMask)
    if not h:
        return f"no se pudo abrir el PID {pid}"
    try:
        namebuf = ctypes.create_unicode_buffer(1024)
        n = wintypes.DWORD(1024)
        k32.QueryFullProcessImageNameW(h, 0, namebuf, ctypes.byref(n))
        if "llama-server" not in os.path.basename(namebuf.value).lower():
            return f"el PID {pid} no es llama-server; no se toca"
        k32.SetPriorityClass(h, 0x80)  # HIGH_PRIORITY_CLASS
        # Si una version anterior de Charly dejo una afinidad fija (0x00FF), se restablece a todos los procesadores.
        pm, sm = ctypes.c_size_t(0), ctypes.c_size_t(0)
        k32.GetProcessAffinityMask.argtypes = [wintypes.HANDLE, ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)]
        k32.SetProcessAffinityMask.argtypes = [wintypes.HANDLE, ctypes.c_size_t]
        if k32.GetProcessAffinityMask(h, ctypes.byref(pm), ctypes.byref(sm)) and pm.value != sm.value:
            if k32.SetProcessAffinityMask(h, sm.value):
                return f"PID {pid}: prioridad alta; afinidad restablecida ({pm.value:#x} -> {sm.value:#x})"
        return f"PID {pid}: prioridad alta (sin fijar afinidad)"
    finally:
        k32.CloseHandle(h)

def ps_quote(p) -> str:
    """Literal PowerShell entre comillas SIMPLES (sin interpolacion de $ ni `); duplica las ' internas."""
    return "'" + str(p).replace("'", "''") + "'"

# Opener SIN proxy para hablar con servidores locales (127.0.0.1): un proxy del sistema no debe interceptarlos.
_LOCAL_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
_FENCE_RE = re.compile(r"```[ \t]*(?:\{?[rR]\}?|rscript)?[ \t]*\r?\n(.*?)(?:```|\Z)", re.S)

def _sse_data(resp):
    """Itera los payloads 'data:' de un stream SSE (con o sin espacio tras los dos puntos; ignora ': ping')."""
    for raw in resp:
        line = raw.decode("utf-8", errors="replace").strip()
        if line.startswith("data:"):
            yield line[5:].strip()

# ---------------------------------------------------------------------------
# Registro de procesos hijos / streams activos + cancelacion (C2)
# ---------------------------------------------------------------------------
_ACTIVE_PROCS: set = set()
_ACTIVE_RESP: set = set()
_ACTIVE_LOCK = threading.Lock()
CANCEL_EVENT = threading.Event()

def _kill_tree(proc: subprocess.Popen) -> None:
    """Mata el proceso y todos sus descendientes (Rscript.exe -> R.exe, powershell -> R, etc.)."""
    if proc.poll() is None:
        try:
            subprocess.run(
                ["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                capture_output=True,
                stdin=subprocess.DEVNULL,
                creationflags=NO_WINDOW,
                timeout=15,
            )
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass

def cancel_all() -> None:
    """Cancela TODO lo que Charly lanzo: procesos hijos (con sus nietos) y streams HTTP en curso."""
    CANCEL_EVENT.set()
    with _ACTIVE_LOCK:
        procs = list(_ACTIVE_PROCS)
        resps = list(_ACTIVE_RESP)
        _ACTIVE_RESP.clear()
    for p in procs:
        _kill_tree(p)
    for r in resps:
        try:
            r.close()  # desbloquea el readline() del stream
        except Exception:
            pass

def run_proc(cmd, *, cwd=None, env=None, timeout=None, on_line=None) -> tuple[int, str]:
    """
    Popen robusto para procesos de consola: stdin cerrado, stdout+stderr fusionados en UN pipe
    drenado continuamente (sin deadlock), timeout y kill del arbol. on_line(linea, color) opcional.
    Devuelve (returncode, salida_completa).
    """
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    with _ACTIVE_LOCK:
        _ACTIVE_PROCS.add(proc)
    lines: list[str] = []

    def _pump():
        try:
            for raw in proc.stdout:
                l = raw.rstrip("\r\n")
                lines.append(l)
                if on_line and l:
                    on_line(l, _infer_color_for_repair_line(l))
        except Exception:
            pass

    reader = threading.Thread(target=_pump, daemon=True)
    reader.start()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_tree(proc)
        lines.append(f"[ERROR] Tiempo maximo excedido ({timeout}s); el proceso fue terminado.")
    finally:
        reader.join(5)  # si un nieto retiene el pipe, no nos colgamos
        with _ACTIVE_LOCK:
            _ACTIVE_PROCS.discard(proc)
    rc = proc.returncode if proc.returncode is not None else -1
    return rc, "\n".join(lines)

def wait_process(cmd) -> int:
    """Lanza una app GUI (p.ej. Bloc de Notas), espera a que se cierre y permite cancelarla con cancel_all()."""
    proc = subprocess.Popen(cmd)
    with _ACTIVE_LOCK:
        _ACTIVE_PROCS.add(proc)
    try:
        return proc.wait()
    finally:
        with _ACTIVE_LOCK:
            _ACTIVE_PROCS.discard(proc)

_RSCRIPT_CACHE: tuple[str, str] | None = None  # (valor de r_home en settings, ruta de Rscript)

def find_rscript(force: bool = False) -> str | None:
    """
    Detecta Rscript.exe (con cache). [G4] Antes cada llamada (get_engine_env en CADA subproceso) releia settings y
    reexploraba el disco / lanzaba 'where'. La cache se invalida si cambia r_home o si el archivo deja de existir;
    force=True fuerza una nueva busqueda (boton 'Verificar R').
    """
    global _RSCRIPT_CACHE
    try:
        r_home = (charly_secrets.load_settings().get("r_home") or "").strip()
    except Exception:
        r_home = ""
    if not force and _RSCRIPT_CACHE and _RSCRIPT_CACHE[0] == r_home and os.path.isfile(_RSCRIPT_CACHE[1]):
        return _RSCRIPT_CACHE[1]
    found = _find_rscript_uncached()
    if found:
        _RSCRIPT_CACHE = (r_home, found)
    return found

def _find_rscript_uncached() -> str | None:
    """Detecta Rscript.exe respetando configuración personalizada o rutas estándar."""
    try:
        cfg = charly_secrets.load_settings()
        r_custom = (cfg.get("r_home") or "").strip()
        if r_custom:
            p_cust = Path(r_custom)
            if p_cust.is_file() and p_cust.name.lower().startswith("rscript"):
                return str(p_cust)
            for sub in (
                p_cust / "bin" / "Rscript.exe",
                p_cust / "bin" / "x64" / "Rscript.exe",
                p_cust / "Rscript.exe",
            ):
                if sub.is_file():
                    return str(sub)
    except Exception:
        pass

    search_roots = [
        Path(r"C:\Program Files\R"),
        Path(os.path.expandvars(r"%LOCALAPPDATA%\Programs\R")),
    ]
    for r_root in search_roots:
        if r_root.exists():
            dirs = sorted([d for d in r_root.iterdir() if d.is_dir()], key=lambda x: x.name, reverse=True)
            for d in dirs:
                for cand in (d / "bin" / "Rscript.exe", d / "bin" / "x64" / "Rscript.exe"):
                    if cand.is_file():
                        return str(cand)
    fallback = r"C:\Program Files\R\R-4.5.2\bin\Rscript.exe"
    if os.path.isfile(fallback):
        return fallback
    try:
        res = subprocess.run(
            ["where", "Rscript.exe"],
            capture_output=True,
            text=True,
            check=False,
            creationflags=NO_WINDOW,
        )
        if res.returncode == 0:
            first = res.stdout.strip().splitlines()[0].strip()
            if os.path.isfile(first):
                return first
    except Exception:
        pass
    return None

_ACTIVE_ENGINE = ""

def set_active_engine(engine: str) -> None:
    """Motor elegido para la corrida en curso ('cloud' | 'local')."""
    global _ACTIVE_ENGINE
    _ACTIVE_ENGINE = (engine or "").strip().lower()

def get_engine_env() -> dict:
    """Construye el entorno de variables seguras para subprocesos PowerShell y R."""
    env = os.environ.copy()
    try:
        cfg = charly_secrets.load_settings()
        # Motor local: la clave de la nube NO se entrega a ningun subproceso (garantia de que nada sale a Gemini).
        env["CHARLY_GEMINI_API_KEY"] = "" if _ACTIVE_ENGINE == "local" else (cfg.get("api_key") or "")
        env["CHARLY_GEMINI_MODEL"] = cfg.get("model") or "gemini-flash-lite-latest"
        env["CHARLY_LOCAL_MODE"] = cfg.get("local_mode") or "llama_server"
        env["CHARLY_LOCAL_HOST"] = cfg.get("local_host") or "http://127.0.0.1:8090"
        env["CHARLY_LOCAL_MODEL_NAME"] = cfg.get("local_model_name") or "local-model"
        env["CHARLY_LLAMA_SERVER_EXE"] = cfg.get("llama_server_exe") or ""
        env["CHARLY_LOCAL_MODEL_PATH"] = cfg.get("gguf_model_path") or ""
        _gen, _batch = recommended_llama_threads()
        env["CHARLY_LLAMA_THREADS"] = str(cfg.get("llama_threads") or _gen)
        env["CHARLY_LLAMA_THREADS_BATCH"] = str(cfg.get("llama_threads_batch") or _batch)
        rscript = find_rscript()
        if rscript:
            env["CHARLY_RSCRIPT_EXE"] = rscript
    except Exception as e:
        log.warning("get_engine_env: entorno incompleto (%s: %s)", type(e).__name__, e)

    return env

def sync_workspaces(from_v4_to_app: bool = True) -> None:
    """Sincroniza todos los artefactos entre el motor y Charly_App/workspace (y charly_v4 si existe)."""
    V4_WORKSPACE.mkdir(parents=True, exist_ok=True)
    APP_WORKSPACE.mkdir(parents=True, exist_ok=True)
    dirs = [V4_WORKSPACE, APP_WORKSPACE]
    if EXT_WORKSPACE and EXT_WORKSPACE.exists():
        dirs.append(EXT_WORKSPACE)

    files_to_sync = [
        "user_goal.txt",
        "dataset_profile.json",
        "dataset_prompt_block.txt",
        "contract_specs.json",
        "r_env_prompt_block.txt",
        "full_prompt.txt",
        "generated_script.R",
        "resultados_analisis.txt",
        "consola_rstudio_completa.txt",
        "descriptivos_base.txt",
    ]

    for fname in files_to_sync:
        candidates = []
        for d in dirs:
            f = d / fname
            if f.exists() and f.is_file():
                try:
                    candidates.append((f.stat().st_mtime, f))
                except Exception:
                    pass
        if not candidates:
            continue
        candidates.sort(key=lambda x: x[0], reverse=True)
        newest_mtime, newest_f = candidates[0]

        for d in dirs:
            target = d / fname
            try:
                if target.resolve() != newest_f.resolve():
                    if not target.exists() or target.stat().st_mtime < newest_mtime:
                        shutil.copy2(newest_f, target)
            except Exception as e:
                log.warning("sync_workspaces: no se pudo copiar %s -> %s: %s", newest_f, target, e)

    # Sincronizacion estricta de avisos_r.txt: V4_WORKSPACE es la unica fuente de verdad de la corrida actual.
    v4_avisos = V4_WORKSPACE / "avisos_r.txt"
    if v4_avisos.exists():
        for d in dirs:
            target = d / "avisos_r.txt"
            try:
                if target.resolve() != v4_avisos.resolve():
                    shutil.copy2(v4_avisos, target)
            except Exception:
                pass
    else:
        for d in dirs:
            target = d / "avisos_r.txt"
            if target.exists():
                try:
                    target.unlink()
                except Exception:
                    pass

def clean_stale_artifacts() -> None:

    """Idéntico a líneas 899-902 de charly_core.ps1."""
    stale = [
        "generated_script.R",
        "repair_prompt.txt",
        "consola_rstudio_completa.txt",
        "resultados_analisis.txt",

        "audit_prompt.txt",

        "full_prompt.txt",  # [FIX C4] evita reutilizar el prompt de una consulta anterior si falla el ensamblador
        "contract_specs.json",
        "contract_prompt_block.txt",
        "temp_contract_args.json",
        "avisos_r.txt",
    ]

    target_dirs = [V4_WORKSPACE, APP_WORKSPACE]
    if EXT_WORKSPACE and EXT_WORKSPACE.exists():
        target_dirs.append(EXT_WORKSPACE)

    for ws in target_dirs:

        for name in stale:
            f = ws / name
            if f.exists():
                try:
                    f.unlink()
                except Exception as e:
                    log.warning("clean_stale_artifacts: no se pudo borrar %s: %s", f, e)

def ensure_rstudio_open(script_to_open: str = "workspace/generated_script.R") -> bool:
    """Idéntico a Ensure-RStudioOpen (líneas 20-45 de charly_core.ps1)."""
    candidates = [
        r"C:\Program Files\RStudio\rstudio.exe",
        r"C:\PROGRA~1\RStudio\rstudio.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\RStudio\rstudio.exe"),
    ]
    rstudio_exe = None
    for c in candidates:
        if os.path.isfile(c):
            rstudio_exe = c
            break
    if not rstudio_exe:
        return False

    try:
        work_dir = str(CHARLY_V4_DIR)
        script_full = CHARLY_V4_DIR / script_to_open if not os.path.isabs(script_to_open) else Path(script_to_open)
        arg_to_pass = ""
        if script_to_open and script_full.exists():
            arg_to_pass = str(script_full.resolve())
        else:
            proj_file = CHARLY_V4_DIR / "Charly.Rproj"
            if proj_file.exists():
                arg_to_pass = str(proj_file.resolve())

        args = [rstudio_exe]
        if arg_to_pass:
            args.append(arg_to_pass)
        subprocess.Popen(args, cwd=work_dir)
        return True
    except Exception:
        return False

def test_local_server() -> bool:
    try:
        cfg = charly_secrets.load_settings()
        mode = cfg.get("local_mode") or "llama_server"
        host = (cfg.get("local_host") or "http://127.0.0.1:8090").rstrip("/")
    except Exception:
        mode = "llama_server"
        host = "http://127.0.0.1:8090"

    endpoints = [f"{host}/health", f"{host}/v1/models", f"{host}/api/tags"]
    if mode == "llama_server" and _port_of(host) != 8090:
        endpoints.append("http://127.0.0.1:8090/health")

    for endpoint in endpoints:
        try:
            req = urllib.request.Request(endpoint, method="GET")
            with _LOCAL_OPENER.open(req, timeout=2) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass
    return False

def run_local_server_action(action: str = "start") -> tuple[bool, str]:
    """Ejecuta engine/local_server.ps1 -Action <start|status> o verifica endpoint externo."""
    try:
        cfg = charly_secrets.load_settings()
        if cfg.get("local_mode") == "endpoint":
            host = (cfg.get("local_host") or "http://127.0.0.1:11434").rstrip("/")
            mod = cfg.get("local_model_name") or "local-model"
            if test_local_server():
                return True, f"Estado del Modelo Local: Endpoint externo ({mod}) listo.\nServidor HTTP Activo: SI ({host})"
            if action == "start" and _port_of(host) == 11434:
                try:
                    subprocess.Popen(
                        ["ollama", "serve"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        creationflags=NO_WINDOW,
                    )
                    for _ in range(5):
                        time.sleep(1)
                        if test_local_server():
                            return True, f"Servidor Ollama iniciado automáticamente en {host} ({mod})."
                except Exception:
                    pass
            return (
                False,
                f"Estado del Modelo Local: Endpoint externo ({mod}) en {host} no responde.\n"
                f"Servidor HTTP Activo: NO (Abre primero tu programa de IA Local o cambia a Opción B en Configurar R e IA).",
            )
    except Exception:
        pass
    script_path = CHARLY_V4_DIR / "engine" / "local_server.ps1"
    if not script_path.exists():
        return False, "No se encontró engine/local_server.ps1"
    try:
        res = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script_path),
                "-Action",
                action,
            ],
            cwd=str(CHARLY_V4_DIR),
            env=get_engine_env(),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=NO_WINDOW,
        )
        out = (res.stdout or "") + ("\n" + res.stderr if res.stderr else "")
        return test_local_server(), out.strip()
    except Exception as e:
        return False, str(e)

def get_ram_status() -> tuple[float, float]:
    try:
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("sullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        stat = MEMORYSTATUSEX()
        stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat))
        free_gb = round(stat.ullAvailPhys / (1024**3), 2)
        total_gb = round(stat.ullTotalPhys / (1024**3), 2)
        return free_gb, total_gb
    except Exception:
        return 0.0, 0.0

def get_status_lines() -> list[tuple[str, str]]:
    """Idéntico a Show-Status (líneas 1844-1866 de charly_core.ps1)."""
    free_gb, total_gb = get_ram_status()
    _, srv_status = run_local_server_action("status")
    lines = get_banner_lines()
    lines.extend([
        (">>> ESTADO DEL SISTEMA Y RECURSOS:", "Yellow"),
        ("", "White"),
        (f"RAM: {free_gb} GB libres de {total_gb} GB totales", "Cyan"),
        ("\n>>> ESTADO DE LA IA LOCAL (Seru Giran - Qwen3.6-35B-A3B MoE):", "Yellow"),
    ])
    if srv_status:
        for l in srv_status.splitlines():
            col = "Green" if "ACTIVO" in l.upper() or "LISTO" in l.upper() else "White"
            lines.append((l, col))
    else:
        if test_local_server():
            lines.append(("Servidor Seru Giran ACTIVO en localhost:8090", "Green"))
        else:
            lines.append(("Servidor local APAGADO (Se encendera automaticamente cuando elijas Modo Local)", "Gray"))
    lines.extend([
        ("\n>>> ESTADO DE LA IA EN LA NUBE (Google Gemini Flash):", "Yellow"),
        ("API Key: Configurada y activa", "Green"),
        ("Costo: 100% Gratuito (Google AI Studio Free Tier, 15 RPM)", "Green"),
        ("", "White"),
    ])
    return lines

def get_banner_lines() -> list[tuple[str, str]]:
    """Idéntico a Show-Banner (líneas 47-56 de charly_core.ps1)."""
    return [
        ("========================================================================", "Cyan"),
        ("             CHARLY v4.0 - CEREBRO PSICOMETRICO DUAL                    ", "Yellow"),
        ("   Nube: Google Gemini Flash (Gratis) | Local: Qwen3.6-35B-A3B MoE      ", "White"),
        ("   Arquitectura de 3 Pilares: Datos Reales + Firmas R + Doble Blindaje  ", "Gray"),
        ("   Invarianza / DIF: Exclusivamente Modelos MIMIC (Muthen, 1989; 1 gl)  ", "Green"),
        ("========================================================================", "Cyan"),
        ("", "White"),
    ]

def get_main_menu_lines() -> list[tuple[str, str]]:
    """Idéntico al Menú Principal (líneas 1979-1995 de charly_core.ps1)."""
    lines = get_banner_lines()
    lines.extend([
        (" [1] Nube Ultrarrapida con Google Gemini Flash (5 a 8 seg) [Recomendado]", "Green"),
        (" [2] Local Privado / Offline con Seru Giran (Qwen3.6-35B-A3B MoE)", "Cyan"),
        (" [3] Ver Resultados (Consola R completa)", "White"),
        (" [4] Ver Codigo R", "Green"),
        (" [D] o [5] Descriptivos de Datos (Radiografia de variables, frecuencias y NAs)", "Magenta"),
        (" [M] o [6] Modelos Soportados (los 10 arquetipos canonicos)", "Yellow"),
        (" [0] o [Q] Salir", "Red"),
        ("", "White"),
    ])
    return lines

def get_step1_archetypes_banner_lines() -> list[tuple[str, str]]:
    """Idéntico a Get-UserPsychometricGoal (líneas 746-763 de charly_core.ps1)."""
    return [
        ("========================================================================", "Cyan"),
        ("         CHARLY v4.0 - LOS 10 ARQUETIPOS CANONICOS (DE A UNO)           ", "Yellow"),
        ("========================================================================", "Cyan"),
        ("  1. AFC PRIMER ORDEN:   Factores latentes =~ items | FC (CR), AVE, Fornell-Larcker, HTMT y Modindices", "Green"),
        ("  2. AFC SEGUNDO ORDEN:  Macro-factor =~ Factores 1er orden | Cargas y FC de 1er y 2do orden", "Green"),
        ("  3. BIFACTORIAL:        Factor General (todos los items) + Especificos ortogonales | Reise y Rodriguez", "Green"),
        ("  4. MIMIC & INVARIANZA: Factores (1er o 2do orden) ~ Covars | Invarianza y DIF (Score Test Muthen 1989 a 1 gl + Bonferroni)", "Magenta"),
        ("  5. SEM / SENDEROS:     Destino ~ Origen (A -> B) | Escribilos en frases cortas con punto.", "Green"),
        ("  6. SEM / NO RECURSIVO: Bucles y Feedback Loops (A -> B y B -> A) | Sin Mediaciones", "Yellow"),
        ("  7. ACP:                psych::principal() | Criterio de Kaiser (autovalores > 1) | Rotacion Varimax", "Cyan"),
        ("  8. AFE:                psych::fa() | Minres/WLS | Criterio de Kaiser | Rotacion Oblimin / Promax", "Cyan"),
        ("  9. REGRESION LOGIT:    Binaria (glm 0/1) u Ordinal (MASS::polr 3+ niveles) | Odds Ratios y p-valores", "Yellow"),
        (" 10. REGRESION PROBIT:   Binaria (glm probit 0/1) u Ordinal (MASS::polr probit) | Coeficientes y p-valores", "Yellow"),
        ("------------------------------------------------------------------------", "DarkGray"),
        (" REGLA DE ORO: Las consultas se procesan DE A UNA por vez (sin mezclar arquetipos incompatibles ni tareas compuestas dentro del mismo arquetipo; solicita un solo objetivo por vez).", "Cyan"),

        (" ESTIMADORES:  WLSMV (items discretos/ordinales) | MLR/ML (continuas) | Faltantes: pairwise / listwise / fiml", "Cyan"),

        (" IMPORTANTE: Limite su pedido estrictamente a las técnicas listadas. Lo que no figure en este catálogo no será calculado o se resolverá incorrectamente.", "Yellow"),
        (" RSTUDIO:   Al concluir, el script queda abierto en el panel superior de RStudio. Para correrlo interactivo o consultar warnings(), presiona [Source] (o Ctrl+Shift+S).", "DarkGray"),
        (" GUIA Y PLANTILLAS: En el repositorio consulta 'Catalogo_Consignas_Charly' (.docx / .html) con ejemplos testeados y validados para cada uno de los 10 arquetipos.", "Green"),
        ("========================================================================", "Cyan"),

    ]

def get_model_catalog_lines() -> list[tuple[str, str]]:
    """Boton [M]/[6] Modelos Soportados: muestra los MISMOS 10 arquetipos canonicos que ve el usuario al
    redactar su consigna (una unica fuente de verdad: get_step1_archetypes_banner_lines)."""
    return get_step1_archetypes_banner_lines() + [("", "White")]

def find_dataset_file(goal_text: str) -> str | None:
    """Idéntico a Find-DatasetFile (líneas 844-889 de charly_core.ps1)."""
    candidates: list[str] = []

    # 1. Nombres entre comillas: "base" o 'base'
    for m in re.finditer(r'["\']\s*([^"\']+?)\s*["\']', goal_text):
        cand = m.group(1).strip()
        if cand and cand not in candidates:
            candidates.append(cand)

    # 2. Nombres con extensión explícita
    for m in re.finditer(
        r"([a-zA-Z0-9_\-\.]+\.(?:xlsx|xls|csv|sav|rds|tsv))",
        goal_text,
        flags=re.IGNORECASE,
    ):
        cand = m.group(1).strip()
        if cand and cand not in candidates:
            candidates.append(cand)

    # 3. Palabras que siguen a 'base', 'archivo', 'datos', 'leer'
    for m in re.finditer(
        r"(?:base|archivo|datos|leer)\s+([a-zA-Z0-9_\-]+)",
        goal_text,
        flags=re.IGNORECASE,
    ):
        cand = m.group(1).strip()
        if cand and cand not in candidates:
            candidates.append(cand)

    extensions = ["", ".xlsx", ".xls", ".sav", ".dta", ".csv", ".rds"]
    user_profile = Path(os.environ.get("USERPROFILE", str(Path.home())))
    onedrive = os.environ.get("OneDrive", "")
    search_locations = [
        CHARLY_APP_DIR,
        CHARLY_APP_DIR / "datasets_ejemplo",
        CHARLY_V4_DIR,
        EXTERNAL_V4_DIR if EXTERNAL_V4_DIR.exists() else None,
        EXTERNAL_V4_DIR.parent if EXTERNAL_V4_DIR.exists() else None,
        user_profile / "Downloads",
        user_profile / "Desktop",
        user_profile / "Documents",
        user_profile / "OneDrive" / "Desktop",
        user_profile / "OneDrive" / "Escritorio",
        user_profile / "OneDrive" / "Documentos",
        Path(onedrive) / "Desktop" if onedrive else None,
        Path(onedrive) / "Escritorio" if onedrive else None,
    ]
    valid_locs = [loc for loc in search_locations if loc and loc.exists()]

    for cand in candidates:
        if os.path.isfile(cand):
            return str(Path(cand).resolve())
        for ext in extensions:
            name_with_ext = (
                cand
                if (ext and cand.lower().endswith(ext.lower()))
                else f"{cand}{ext}"
            )
            for loc in valid_locs:
                test_p = loc / name_with_ext
                if test_p.is_file():
                    return str(test_p.resolve())
            # Búsqueda recursiva en directorios conocidos
            for r_root in (
                [EXTERNAL_V4_DIR.parent, CHARLY_APP_DIR]
                if EXTERNAL_V4_DIR.exists()
                else [CHARLY_APP_DIR]
            ):
                try:
                    for found in r_root.rglob(name_with_ext):
                        if found.is_file():
                            return str(found.resolve())
                except Exception:
                    pass
    return None

def create_safe_working_copies(target_file: str) -> tuple[str, str]:
    """
    Idéntico a las líneas 1020-1045 de charly_core.ps1.
    Retorna (safe_data_file_rel, log_message).
    """
    src = Path(target_file).resolve()
    ext = src.suffix
    orig_file_name = src.name
    safe_rel = f"workspace/datos_analisis{ext}"
    dest_full = V4_WORKSPACE / f"datos_analisis{ext}"
    deep_ws = V4_WORKSPACE / "workspace"
    deep_ws.mkdir(parents=True, exist_ok=True)

    targets = [
        dest_full,
        CHARLY_V4_DIR / f"datos_analisis{ext}",
        deep_ws / f"datos_analisis{ext}",
        V4_WORKSPACE / orig_file_name,
        CHARLY_V4_DIR / orig_file_name,
        deep_ws / orig_file_name,
        APP_WORKSPACE / f"datos_analisis{ext}",
        APP_WORKSPACE / orig_file_name,
    ]
    failures = []
    for t in targets:
        try:
            t.parent.mkdir(parents=True, exist_ok=True)
            if src != t.resolve():
                shutil.copy2(src, t)
        except Exception as e:
            failures.append(t)
            log.warning("create_safe_working_copies: no se pudo copiar %s -> %s: %s", src, t, e)

    # [G6] Antes siempre informaba exito aunque fallaran las 8 copias (y el script R apuntaba a un archivo inexistente).
    if not dest_full.exists():
        log.error("create_safe_working_copies: sin copia principal en %s; se usa el original %s", dest_full, src)
        return str(src), (
            "[AVISO] No se pudo crear la copia de trabajo segura (¿el archivo esta abierto o bloqueado?). "
            f"Se usara el archivo original: {src}"
        )
    extra = f" ({len(failures)} copias auxiliares fallaron; ver charly.log)" if failures else ""
    return safe_rel, f"[SISTEMA] Copia de trabajo segura creada en '{safe_rel}' (sin bloqueos de Excel){extra}"

def load_dataset_profile_json() -> dict:
    """Lee workspace/dataset_profile.json generado por profiler/data_profiler.R."""
    p = V4_WORKSPACE / "dataset_profile.json"
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8-sig", errors="replace"))
        except Exception:
            pass
    return {}

def run_data_profiler(safe_data_file: str, target_file: str, custom_goal: str) -> dict:
    """
    Idéntico a las líneas 1052-1084 de charly_core.ps1.
    Ejecuta profiler/data_profiler.R y lee workspace/dataset_profile.json.
    """
    rscript = find_rscript()
    if not rscript:
        return {"success": False, "stdout": "No se encontró Rscript.exe"}

    goal_path = V4_WORKSPACE / "user_goal.txt"
    goal_path.write_text(custom_goal, encoding="utf-8")

    res = subprocess.run(
        [
            rscript,
            "profiler/data_profiler.R",
            str(safe_data_file),
            str(target_file),
            "workspace/user_goal.txt",
        ],
        cwd=str(CHARLY_V4_DIR),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    stdout = (res.stdout or "") + ("\n" + res.stderr if res.stderr else "")
    sync_workspaces(from_v4_to_app=True)
    prof = load_dataset_profile_json()
    focal_vars = prof.get("variables_focalizadas") or []
    if isinstance(focal_vars, str):
        focal_vars = [focal_vars]

    return {
        "success": res.returncode == 0,
        "stdout": stdout.rstrip(),
        "profile_json": prof,
        "focalized_vars": focal_vars,
    }

def test_is_na_cancelled(text: str) -> bool:
    """Idéntico a Test-IsNaCancelled (líneas 58-63 de charly_core.ps1)."""
    if not text or not text.strip():
        return False
    pat = r"(?i)\b(?:me\s+equivoqu[eé]|no\s+corre|no\s+va|no\s+van|no\s+aplica|olv[ií]date|anul[ao]r?|cancel[ao]r?|descart[ao]r?|ignor[ao]r?|no\s+tomar|no\s+considerar|no\s+recodificar|no\s+hay\s+(?:valores?\s+)?(?:\d+|siete|ocho|nueve|cuatro)|no\s+hay\s+faltantes|sin\s+(?:datos\s+)?faltantes?|cero\s+faltantes?|no\s+tiene\s+(?:datos\s+)?faltantes?|ning[uú]n\s+(?:dato\s+)?faltante|sin\s+na|dejar?\s+(?:los\s+)?faltantes)\b"
    return bool(re.search(pat, text))

def test_value_exists_in_profile(na_value: str) -> dict:
    """Idéntico a Test-ValueExistsInProfile (líneas 76-105 de charly_core.ps1)."""
    if not na_value or not str(na_value).strip():
        return {"Exists": True}
    prof = load_dataset_profile_json()
    columnas = prof.get("columnas")
    if not isinstance(columnas, dict):
        return {"Exists": True}

    nums = re.findall(r"\b(\d+)\b", str(na_value))
    if not nums:
        return {"Exists": True}

    for n_str in nums:
        val_int = int(n_str)
        val_found = False
        max_obs_all = 0
        for col_name, c_obj in columnas.items():
            if not isinstance(c_obj, dict):
                continue
            c_max = c_obj.get("max")
            if isinstance(c_max, (int, float)) and c_max > max_obs_all:
                max_obs_all = c_max
            vals_det = c_obj.get("valores_detectados") or []
            if not isinstance(vals_det, list):
                vals_det = [vals_det]
            if val_int in vals_det or str(val_int) in [str(x) for x in vals_det]:
                val_found = True
                break
        if not val_found and max_obs_all < val_int:
            return {"Exists": False, "MissingVal": val_int, "MaxObs": max_obs_all}
    return {"Exists": True}

def get_profile_columns_and_values() -> tuple[list[str], list, dict]:
    """
    Extrae (colNames, allValsGlobal, colInfo) de workspace/dataset_profile.json
    igual que Get-StructuredNaRules / Get-StructuredCategoryCleaning.
    """
    prof = load_dataset_profile_json()
    columnas = prof.get("columnas")
    if not isinstance(columnas, dict):
        return [], [], {}

    col_names = list(columnas.keys())
    all_vals_set = []
    col_info = {}
    for c_name, c_val in columnas.items():
        if isinstance(c_val, dict):
            v_det = c_val.get("valores_detectados")
            if v_det is not None:
                if not isinstance(v_det, list):
                    v_det = [v_det]
                col_info[c_name] = v_det
                for v in v_det:
                    if v not in all_vals_set:
                        all_vals_set.append(v)
    try:
        all_vals_set = sorted(all_vals_set, key=lambda x: float(x) if str(x).replace(".", "", 1).lstrip("-").isdigit() else str(x))
    except Exception:
        pass
    return col_names, all_vals_set, col_info

def parse_directives_and_archetype(custom_goal: str) -> dict:
    """
    Llama a Get-ArrowDirectives, Get-MediationDirectives, Get-TotalEffectsDirectives
    y Get-CanonicalArchetype en PowerShell exactamente como líneas 1087-1113 de charly_core.ps1.
    """
    goal_path = V4_WORKSPACE / "user_goal.txt"
    goal_path.write_text(custom_goal, encoding="utf-8")

    ps_code = f"""
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    . {ps_quote(CHARLY_V4_DIR / 'runtime' / 'psico_parser.ps1')}
    . {ps_quote(CHARLY_V4_DIR / 'runtime' / 'contract_builder.ps1')}
    $customGoal = Get-Content -LiteralPath {ps_quote(goal_path)} -Raw -Encoding UTF8
    $arrowDirs = @(Get-ArrowDirectives -UserPrompt $customGoal)
    $medDirs = @(Get-MediationDirectives -UserPrompt $customGoal)
    $totDirs = @(Get-TotalEffectsDirectives -UserPrompt $customGoal)
    $arch = Get-CanonicalArchetype -UserPrompt $customGoal -ArrowDirectives $arrowDirs
    $out = @{{
        CanonicalArchetype = $arch
        ArrowDirectives = $arrowDirs
        MediationDirectives = $medDirs
        TotalEffectsDirectives = $totDirs
    }}
    $out | ConvertTo-Json -Depth 10 -Compress
    """
    res = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_code],
        cwd=str(CHARLY_V4_DIR),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    out = (res.stdout or "").strip()
    for line in reversed(out.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                data = json.loads(line)
                for k in ("ArrowDirectives", "MediationDirectives", "TotalEffectsDirectives"):
                    v = data.get(k)
                    if v is None:
                        data[k] = []
                    elif isinstance(v, dict) or isinstance(v, str):
                        data[k] = [v]
                for ad in data.get("ArrowDirectives", []):
                    if isinstance(ad, dict):
                        origs = ad.get("Origenes")
                        if isinstance(origs, str):
                            ad["Origenes"] = [origs]
                        elif origs is None:
                            ad["Origenes"] = []
                return data
            except Exception:
                pass
    return {
        "CanonicalArchetype": "AFC_Primer_Orden",
        "ArrowDirectives": [],
        "MediationDirectives": [],
        "TotalEffectsDirectives": [],
    }

def invoke_semantic_parser(current_goal_context: str) -> dict:
    """
    Idéntico a líneas 1571-1583 de charly_core.ps1:
    Ejecuta runtime/semantic_parser.ps1 -UserPrompt $currentGoalContext.
    """
    parser_path = CHARLY_V4_DIR / "runtime" / "semantic_parser.ps1"
    prompt_file = V4_WORKSPACE / "semantic_prompt.txt"
    prompt_file.write_text(current_goal_context or "", encoding="utf-8")
    res = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(parser_path),
            "-UserPromptFile",
            str(prompt_file),
        ],
        cwd=str(CHARLY_V4_DIR),
        env=get_engine_env(),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    out = (res.stdout or "").strip()
    if (res.stderr or "").strip():
        log.warning("invoke_semantic_parser: %s", (res.stderr or "").strip()[:300])
    meds = []
    tots = []
    try:
        for line in reversed(out.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                obj = json.loads(line)
                raw_m = obj.get("mediaciones") or []
                if isinstance(raw_m, str):
                    raw_m = [raw_m]
                meds = [m.strip() for m in raw_m if str(m).strip()]
                raw_t = obj.get("efectos_totales") or []
                if isinstance(raw_t, str):
                    raw_t = [raw_t]
                tots = [t.strip() for t in raw_t if str(t).strip()]
                break
    except Exception:
        pass
    return {"mediaciones": meds, "efectos_totales": tots}

def get_all_causal_paths(arrow_directives: list[dict], max_paths: int = 500, max_len: int = 10) -> list[str]:
    """
    Idéntico a Get-AllCausalPaths (líneas 492-528 de charly_core.ps1): todos los caminos simples de >= 3 nodos.
    [G5] Antes se hacia un DFS completo por CADA par (origen, destino) (trabajo repetido, exponencial en grafos densos)
    y sin limite. Ahora: un DFS por origen, mismo orden de salida que antes, y acotado por max_paths / max_len
    (se registra un aviso en charly.log si se trunca).
    """
    adj: dict[str, list[str]] = {}
    all_nodes: list[str] = []
    for ad in arrow_directives or []:
        dst = str(ad.get("Destino", "")).strip()
        for orig in ad.get("Origenes") or []:
            u = str(orig).strip()
            if not u or not dst:
                continue
            adj.setdefault(u, []).append(dst)
            if u not in all_nodes:
                all_nodes.append(u)
            if dst not in all_nodes:
                all_nodes.append(dst)

    paths: list[str] = []
    truncated = False
    for src in all_nodes:
        by_dst: dict[str, list[str]] = {}
        stack = [(src, [src])]  # DFS iterativo; se apila en orden inverso para conservar el orden recursivo
        while stack and not truncated:
            curr, curr_path = stack.pop()
            if len(curr_path) >= 3:
                by_dst.setdefault(curr, []).append(" -> ".join(curr_path))
            if len(curr_path) >= max_len:
                continue
            for nxt in reversed(adj.get(curr, [])):
                if nxt not in curr_path:
                    stack.append((nxt, curr_path + [nxt]))
            if sum(len(v) for v in by_dst.values()) + len(paths) >= max_paths:
                truncated = True
        for dst in all_nodes:  # misma agrupacion/orden que el algoritmo original
            if dst != src:
                paths.extend(by_dst.get(dst, []))
        if truncated:
            break
    if truncated:
        paths = paths[:max_paths]
        log.warning("get_all_causal_paths: resultado truncado a %d caminos (max_len=%d)", max_paths, max_len)
    return paths

def build_and_format_contract(
    custom_goal: str,
    clean_na_codes: str,
    inversion_directive: str,
    continuous_exc_directive: str,
    selected_estimator: str,
    selected_missing: str,

    mediation_directives_list: list[str],

    total_effects_directives_list: list[str],
    canonical_archetype: str = "",

) -> dict:

    """
    Idéntico a las líneas 1702-1715 de charly_core.ps1:
    Llama a Build-PsychometricContract y Format-PsychometricContractDisplay
    y guarda workspace/contract_specs.json.
    """
    goal_path = V4_WORKSPACE / "user_goal.txt"
    goal_path.write_text(custom_goal, encoding="utf-8")

    payload = {
        "InteractiveNaCodes": clean_na_codes or "",
        "InteractiveInversions": inversion_directive or "",
        "InteractiveContinuous": continuous_exc_directive or "",
        "InteractiveEstimator": selected_estimator or "WLSMV",
        "InteractiveMissing": selected_missing or "pairwise",

        "MediationDirectives": mediation_directives_list or [],

        "TotalEffectsDirectives": total_effects_directives_list or [],
        "CanonicalArchetype": canonical_archetype or "",

    }

    payload_path = V4_WORKSPACE / "temp_contract_args.json"
    payload_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

    ps_code = f"""
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    . {ps_quote(CHARLY_V4_DIR / 'runtime' / 'psico_parser.ps1')}
    . {ps_quote(CHARLY_V4_DIR / 'runtime' / 'contract_builder.ps1')}

    $customGoal = Get-Content -LiteralPath {ps_quote(goal_path)} -Raw -Encoding UTF8
    $argsObj = Get-Content -LiteralPath {ps_quote(payload_path)} -Raw -Encoding UTF8 | ConvertFrom-Json
    $arrowDirectives = @(Get-ArrowDirectives -UserPrompt $customGoal)
    $medList = @()
    if ($argsObj.MediationDirectives) {{
        foreach ($m in $argsObj.MediationDirectives) {{ $medList += [string]$m }}
    }}
    $totList = @()
    if ($argsObj.TotalEffectsDirectives) {{
        foreach ($t in $argsObj.TotalEffectsDirectives) {{ $totList += [string]$t }}

    }}

    $contractObj = Build-PsychometricContract `
        -CanonicalArchetype ([string]$argsObj.CanonicalArchetype) `
        -UserPrompt $customGoal `
        -InteractiveNaCodes ([string]$argsObj.InteractiveNaCodes) `
        -InteractiveInversions ([string]$argsObj.InteractiveInversions) `
        -InteractiveContinuous ([string]$argsObj.InteractiveContinuous) `
        -InteractiveEstimator ([string]$argsObj.InteractiveEstimator) `
        -InteractiveMissing ([string]$argsObj.InteractiveMissing) `
        -ArrowDirectives $arrowDirectives `
        -MediationDirectives $medList `
        -TotalEffectsDirectives $totList `
        -InteractivePriority

    $contractJson = $contractObj | ConvertTo-Json -Depth 6

    Set-Content -LiteralPath {ps_quote(V4_WORKSPACE / 'contract_specs.json')} -Value $contractJson -Encoding UTF8

    Write-Output "===ARCHETYPE_NAME_START==="
    Write-Output $contractObj.Modelado.NombreArquetipo
    Write-Output "===ARCHETYPE_NAME_END==="
    Write-Output "===CONTRACT_DISPLAY_START==="
    Format-PsychometricContractDisplay -Contract $contractObj
    Write-Output "===CONTRACT_DISPLAY_END==="
    """
    res = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_code],
        cwd=str(CHARLY_V4_DIR),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    out = res.stdout or ""
    arch_name = ""
    m_arch = re.search(
        r"===ARCHETYPE_NAME_START===\r?\n(.*?)\r?\n===ARCHETYPE_NAME_END===",
        out,
        flags=re.DOTALL,
    )
    if m_arch:
        arch_name = m_arch.group(1).strip()

    display_text = ""
    m_disp = re.search(
        r"===CONTRACT_DISPLAY_START===\r?\n(.*?)\r?\n===CONTRACT_DISPLAY_END===",
        out,
        flags=re.DOTALL,
    )
    if m_disp:
        display_text = m_disp.group(1).strip()

    sync_workspaces(from_v4_to_app=True)
    return {
        "success": bool(display_text),
        "archetype_name": arch_name,
        "display": display_text,
    }

_PS_DETECT_DEPVAR = r"""[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Remove-Diacritics([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    return ($s.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', '')
}
# Clave de comparacion de nombres de variable: sin acentos, minusculas y sin separadores ( _ . - espacio )
function Get-NameKey([string]$s) {
    return ((Remove-Diacritics $s).ToLowerInvariant() -replace '[\s_\.\-]+', '')
}
$customGoal = Get-Content -LiteralPath @@GOAL@@ -Raw -Encoding UTF8
$cleanNaCodes = Get-Content -LiteralPath @@NA@@ -Raw -Encoding UTF8
$categoryCleanDirective = if (Test-Path @@CATCLEAN@@) { Get-Content -LiteralPath @@CATCLEAN@@ -Raw -Encoding UTF8 } else { "" }
$cleanGoalNorm = Remove-Diacritics $customGoal
$depVarName = ""
$profObj = if (Test-Path "workspace/dataset_profile.json") { try { Get-Content "workspace/dataset_profile.json" -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }

# 1) Con perfil: se busca cada columna REAL junto a 'variable dependiente'. El objetivo se normaliza sin
#    acentos, asi que el NOMBRE de la columna tambien (antes 'genero'/'edad_anos' nunca coincidian).
if ($profObj -and $profObj.columnas) {
    foreach ($p in $profObj.columnas.PSObject.Properties) {
        $colEsc = [regex]::Escape((Remove-Diacritics $p.Name)) -replace '_', '[ _]+'
        $pats = @(
            "(?i)\b$colEsc\s+como\s+variable\s+dependiente\b",
            "(?i)\b(?:variable\s+)?dependiente\s*(?::\s*|\s+es\s+|\s+)$colEsc\b"
        )
        foreach ($pt in $pats) {
            if ($cleanGoalNorm -match $pt) { $depVarName = $p.Name; break }
        }
        if ($depVarName) { break }
    }
}

# 2) Respaldo (columna no encontrada): el nombre es UNA sola palabra pegada a 'como variable dependiente'
#    (antes se capturaba toda la frase previa: 'Quiero una regresion probit con ansiedad').
if (-not $depVarName) {
    $depMatch = [regex]::Match($cleanGoalNorm, '(?i)([a-zA-Z0-9_\.]+)\s+como\s+variable\s+dependiente|variable\s+dependiente\s*(?::\s*|\s+es\s+|\s+)([a-zA-Z0-9_\.]+)')
    if ($depMatch.Success) {
        $depVarName = if ($depMatch.Groups[1].Success -and ![string]::IsNullOrWhiteSpace($depMatch.Groups[1].Value)) { $depMatch.Groups[1].Value.Trim() } else { $depMatch.Groups[2].Value.Trim() }
    }
}

$isBinary = $false
if ($profObj -and $profObj.columnas -and $depVarName) {
    try {
        $cObj = $null
        $depKey = Get-NameKey $depVarName
        foreach ($p in $profObj.columnas.PSObject.Properties) {
            if ((Get-NameKey $p.Name) -eq $depKey) {
                $cObj = $p.Value
                $depVarName = $p.Name
                break
            }
        }
        if ($cObj) {
            $vals = @($cObj.valores_detectados)
            $naValsToDrop = [System.Collections.Generic.List[int]]::new()
            if (![string]::IsNullOrWhiteSpace($cleanNaCodes)) {
                $numMatches = [regex]::Matches($cleanNaCodes, '\b\d+\b')
                foreach ($nm in $numMatches) {
                    $vInt = [int]$nm.Value
                    if (-not $naValsToDrop.Contains($vInt)) { $naValsToDrop.Add($vInt) }
                }
            }
            foreach ($dVal in $naValsToDrop) {
                $vals = @($vals | Where-Object { "$_" -ne "$dVal" })

            }

            # Si la variable dependiente fue filtrada en categoryCleanDirective a categorias especificas:
            if (![string]::IsNullOrWhiteSpace($categoryCleanDirective) -and $depVarName) {

                $escDep = [regex]::Escape($depVarName)

                $depFiltPat = '(?i)' + $escDep + '[\s''"\]]*%in%\s*c\(([^)]+)\)'
                if ($categoryCleanDirective -match $depFiltPat) {
                    $allowedCats = @($matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") })
                    $vals = @($vals | Where-Object { "$_" -in $allowedCats })
                }
            }
            if ($vals.Count -le 2 -and $vals.Count -gt 0) { $isBinary = $true }
        }
    } catch {}
}

if (-not $isBinary) {
    if ($cleanGoalNorm -match '(?i)\bbinari[ao]\b') {
        $isBinary = $true
    }
}

$asksLogisticOrdinal = ($cleanGoalNorm -match '(?i)logistica\s+ordinal')
$asksProbitOrdinal   = ($cleanGoalNorm -match '(?i)probit\s+ordinal')
$isProbit = if ($asksLogisticOrdinal) { $false } elseif ($asksProbitOrdinal) { $true } else { ($cleanGoalNorm -match '(?i)\bprobit\b') -and -not ($cleanGoalNorm -match '(?i)\blogistica\b') }

@{ DepVar = $depVarName; IsBinary = $isBinary; IsProbit = $isProbit } | ConvertTo-Json -Compress
"""

def detect_direct_regression_binary(custom_goal: str, clean_na_codes: str, category_clean_directive: str = "") -> tuple[str, bool, bool]:
    """
    Idéntico a las líneas 1366-1468 de charly_core.ps1:
    Determina (depVarName, isBinary, isProbit) para Regresión Directa.
    """
    goal_path = V4_WORKSPACE / "user_goal.txt"
    goal_path.write_text(custom_goal, encoding="utf-8")
    na_path = V4_WORKSPACE / "temp_reg_na.txt"
    na_path.write_text(clean_na_codes or "", encoding="utf-8")
    cat_path = V4_WORKSPACE / "temp_reg_catclean.txt"
    cat_path.write_text(category_clean_directive or "", encoding="utf-8")

    ps_code = _PS_DETECT_DEPVAR.replace("@@GOAL@@", ps_quote(goal_path)).replace("@@NA@@", ps_quote(na_path)).replace("@@CATCLEAN@@", ps_quote(cat_path))
    res = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_code],
        cwd=str(CHARLY_V4_DIR),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    out = (res.stdout or "").strip()
    for line in reversed(out.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                d = json.loads(line)
                return str(d.get("DepVar", "")), bool(d.get("IsBinary", False)), bool(d.get("IsProbit", False))
            except Exception:
                pass
    return "", False, False

def run_step3_env_inspector() -> tuple[bool, str]:
    """Idéntico a líneas 1761-1767 de charly_core.ps1."""
    rscript = find_rscript()
    if not rscript:
        return False, "Error en la introspeccion de R."
    res = subprocess.run(
        [rscript, "inspector/env_inspector.R"],
        cwd=str(CHARLY_V4_DIR),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    sync_workspaces(from_v4_to_app=True)
    out = ((res.stdout or "") + ("\n" + res.stderr if res.stderr else "")).strip()

    return res.returncode == 0, out

def run_step4_prompt_builder(canonical_archetype: str = "") -> tuple[bool, str]:
    """Idéntico a líneas 1770-1771 de charly_core.ps1."""
    cmd = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "templates/prompt_builder.ps1",
    ]
    if canonical_archetype:
        cmd.extend(["-CanonicalArchetype", canonical_archetype])
    res = subprocess.run(
        cmd,

        cwd=str(CHARLY_V4_DIR),

        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    sync_workspaces(from_v4_to_app=True)
    out = ((res.stdout or "") + ("\n" + res.stderr if res.stderr else "")).strip()
    return res.returncode == 0, out

def run_cloud_engine_ps1() -> tuple[bool, list[tuple[str, str]]]:
    """Idéntico a líneas 1775-1777 de charly_core.ps1."""
    res = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "engine/gemini_engine.ps1",
        ],
        cwd=str(CHARLY_V4_DIR),
        env=get_engine_env(),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    out = (res.stdout or "") + ("\n" + res.stderr if res.stderr else "")
    lines: list[tuple[str, str]] = []
    for l in out.splitlines():
        if not l.strip():
            continue
        col = "White"
        if "[EXITO]" in l or "exitosamente" in l.lower():
            col = "Green"
        elif "[NUBE]" in l or "[GEMINI]" in l:
            col = "Cyan"
        elif "[AVISO]" in l:
            col = "Yellow"
        elif "[ERROR" in l or "[FALLO" in l:
            col = "Red"
        lines.append((l, col))

    script_out = V4_WORKSPACE / "generated_script.R"
    sync_workspaces(from_v4_to_app=True)
    return (res.returncode == 0 and script_out.exists()), lines

def run_local_engine_stream(on_line=None, on_token=None) -> tuple[bool, list[tuple[str, str]]]:
    """
    Ejecuta engine/local_engine.ps1 o el streaming directo sobre workspace/full_prompt.txt
    escribiendo workspace/generated_script.R.
    """
    prompt_out = V4_WORKSPACE / "full_prompt.txt"
    script_out = V4_WORKSPACE / "generated_script.R"
    log_lines: list[tuple[str, str]] = []

    def emit(msg: str, color: str = "White"):
        log_lines.append((msg, color))
        if on_line:
            on_line(msg, color)

    if not prompt_out.exists():
        emit("[ERROR CRITICO] No existe workspace/full_prompt.txt", "Red")
        return False, log_lines

    prompt_content = prompt_out.read_text(encoding="utf-8-sig", errors="replace")

    try:
        tune_llama_server((charly_secrets.load_settings().get("local_host") or "http://127.0.0.1:8090"))
    except Exception:
        pass

    cfg = charly_secrets.load_settings()
    local_host = (cfg.get("local_host") or "http://127.0.0.1:8090").rstrip("/")
    local_model_name = (cfg.get("local_model_name") or "local-model").strip() or "local-model"

    emit(
        f"[MODO LOCAL PRIVADO] Conectando con IA Local ({local_model_name}) en {local_host}...",
        "Cyan",
    )
    emit("   -> Pista: Tus datos NO salen de tu computadora. Procesando localmente...", "DarkGray")
    emit("   -> [ETAPA 1/3] Leyendo tus datos y preparando la memoria (12K)...", "Yellow")

    payload = {
        "model": local_model_name,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Eres un bioestadistico e investigador en psicometria experto en R. "
                    "Tu unica funcion es devolver UNICAMENTE el bloque de codigo R ejecutable entre ```r y ```, "
                    "sin explicaciones. Piensa de forma ultra-concisa: solo mapea los nombres "
                    "de las variables reales y escribe el codigo inmediatamente."
                ),
            },
            {"role": "user", "content": prompt_content},
        ],
        "temperature": 0.1,
        # [E2E] max_tokens cubre razonamiento + codigo (contexto del servidor: 12K). Con el razonamiento ya acotado
        # (reasoning_format=deepseek) 6000 deja margen; antes 4096 se agotaban pensando y el codigo quedaba cortado.
        "max_tokens": 6000,
        # [E2E] Con reasoning_format=none (valor actual del servidor) el razonamiento llega mezclado en 'content' y el
        # presupuesto --reasoning-budget NO se respeta (control: 1500 tokens sin terminar, finish=length). Con 'deepseek'
        # el razonamiento va en reasoning_content y se corta en el presupuesto (misma consulta: 821 tokens, finish=stop).
        "reasoning_format": "deepseek",
        "stream": True,
        "chat_template_kwargs": {
            "enable_thinking": True,
        },
    }

    req = urllib.request.Request(
        f"{local_host}/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",

    )

    full_code_parts: list[str] = []
    code_pre_buffer: list[str] = []
    is_thinking = False
    is_writing_code = False
    in_think_tag = False
    code_stream_started = False
    code_stream_ended = False

    finish_reason = None

    got_done = False
    bad_chunks = 0
    resp = None

    def _save_partial():
        partial = "".join(full_code_parts).strip()
        if partial:
            try:
                (V4_WORKSPACE / "generated_script.partial.R").write_text(partial, encoding="utf-8")
                emit("   -> Se guardo lo generado hasta el corte en workspace/generated_script.partial.R", "Yellow")
            except Exception:
                pass

    try:
        with _LOCAL_OPENER.open(req, timeout=1800) as resp:
            with _ACTIVE_LOCK:
                _ACTIVE_RESP.add(resp)
            for json_str in _sse_data(resp):
                if CANCEL_EVENT.is_set():
                    break
                if json_str == "[DONE]":
                    got_done = True
                    break
                try:
                    chunk = json.loads(json_str)
                except json.JSONDecodeError:
                    bad_chunks += 1
                    if bad_chunks > 5:
                        raise ValueError("El servidor local envio demasiados fragmentos JSON invalidos.")
                    continue
                if isinstance(chunk, dict) and chunk.get("error"):
                    raise RuntimeError(f"El servidor local reporto un error durante la generacion: {chunk['error']}")
                choices = (chunk.get("choices") if isinstance(chunk, dict) else None) or []
                if not choices:
                    continue  # p.ej. chunk final solo con 'usage'
                finish_reason = choices[0].get("finish_reason") or finish_reason
                delta = choices[0].get("delta") or {}
                r_tok = delta.get("reasoning_content")
                c_tok = delta.get("content")

                if c_tok and not in_think_tag and "</think>" in c_tok:
                    # cierre de razonamiento que llega en 'content' (p.ej. al agotarse el presupuesto): lo anterior es razonamiento
                    r_tok = (r_tok or "") + c_tok.split("</think>", 1)[0]
                    c_tok = c_tok.split("</think>", 1)[1]
                if c_tok:
                    if "<think>" in c_tok:
                        in_think_tag = True
                    if in_think_tag:
                        r_tok = (r_tok or "") + c_tok
                        if "</think>" in c_tok:
                            in_think_tag = False
                            c_tok = c_tok.split("</think>", 1)[1]
                        else:
                            c_tok = ""

                if r_tok:
                    if not is_thinking:
                        emit(
                            "   -> [ETAPA 2/3] Razonando estructura psicometrica (Presupuesto: 400 tokens)...",
                            "Magenta",
                        )
                        is_thinking = True
                    if on_token:

                        on_token(".", "Magenta")

                if c_tok:
                    full_code_parts.append(c_tok)
                    if code_stream_ended:
                        pass
                    elif code_stream_started:
                        if "```" in c_tok:
                            before_closing = c_tok.split("```", 1)[0]
                            if before_closing and on_token:
                                on_token(before_closing, "Cyan")
                            code_stream_ended = True
                            current_so_far = "".join(full_code_parts)
                            matched_blocks = re.findall(r"```[ \t]*(?:\{?[rR]\}?|rscript)?[ \t]*\r?\n(.*?)```", current_so_far, re.S)
                            complete_blocks = [
                                b for b in matched_blocks
                                if len(b.strip()) > 500
                                and re.search(r"\b(?:sem|cfa|lavaan|glm|polr|fa|principal)\s*\(", b)
                                and re.search(r"\b(?:print|summary|parameterEstimates)\s*\(", b)
                            ]
                            if complete_blocks:
                                got_done = True
                                break
                        else:
                            if on_token:
                                on_token(c_tok, "Cyan")
                    else:
                        code_pre_buffer.append(c_tok)
                        accumulated = "".join(code_pre_buffer)
                        m_fence = re.search(r"```(?:r|R)?(?:\s*\r?\n|\s+)(.*)$", accumulated, re.DOTALL)
                        if m_fence:
                            code_stream_started = True
                            if not is_writing_code:
                                emit("   -> [ETAPA 3/3] Escribiendo codigo R en vivo:", "Green")
                                emit("   --------------------------------------------------------------------", "DarkGray")
                                is_writing_code = True
                            initial_code = m_fence.group(1)
                            if "```" in initial_code:
                                clean_init = initial_code.split("```", 1)[0]
                                if clean_init and on_token:
                                    on_token(clean_init, "Cyan")
                                code_stream_ended = True
                                current_so_far = "".join(full_code_parts)
                                matched_blocks = re.findall(r"```[ \t]*(?:\{?[rR]\}?|rscript)?[ \t]*\r?\n(.*?)```", current_so_far, re.S)
                                complete_blocks = [
                                    b for b in matched_blocks
                                    if len(b.strip()) > 500
                                    and re.search(r"\b(?:sem|cfa|lavaan|glm|polr|fa|principal)\s*\(", b)
                                    and re.search(r"\b(?:print|summary|parameterEstimates)\s*\(", b)
                                ]
                                if complete_blocks:
                                    got_done = True
                                    break
                            elif initial_code and on_token:
                                on_token(initial_code, "Cyan")
                        elif len(accumulated) > 250 and re.search(r"(?m)^\s*(?:library|require|datos\s*<-|#)", accumulated):
                            code_stream_started = True
                            if not is_writing_code:
                                emit("   -> [ETAPA 3/3] Escribiendo codigo R en vivo:", "Green")
                                emit("   --------------------------------------------------------------------", "DarkGray")
                                is_writing_code = True
                            if on_token:
                                on_token(accumulated, "Cyan")

        with _ACTIVE_LOCK:
            _ACTIVE_RESP.discard(resp)
        if CANCEL_EVENT.is_set():
            emit("[CANCELADO] Generacion local detenida por el usuario.", "Yellow")
            return False, log_lines
        emit("   --------------------------------------------------------------------", "DarkGray")

        # [FIX C5] Si finish_reason == "length", verificar si cerro al menos un bloque valido antes de abortar
        raw_answer = "".join(full_code_parts).strip()
        raw_answer_clean = re.sub(r"(?s)<think>.*?</think>", "", raw_answer.split("</think>")[-1]).strip()
        closed_blocks = [b.strip() for b in re.findall(r"```[ \t]*(?:\{?[rR]\}?|rscript)?[ \t]*\r?\n(.*?)```", raw_answer_clean, re.S) if len(b.strip()) > 200]
        complete_blocks = [
            b for b in closed_blocks
            if len(b.strip()) > 400
            and re.search(r"\b(?:sem|cfa|lavaan|glm|polr|fa|principal)\s*\(", b)
        ]

        if finish_reason == "length" and not complete_blocks and not closed_blocks:
            emit("[ERROR] El modelo llego al limite de tokens (max_tokens): el codigo R esta INCOMPLETO.", "Red")
            emit("   -> Simplifica la consulta o aumenta max_tokens/contexto del servidor local.", "Yellow")
            _save_partial()
            return False, log_lines

        if not got_done and finish_reason is None and not complete_blocks and not closed_blocks:
            emit("[ERROR] El servidor local cerro la conexion sin terminar la respuesta (sin [DONE] ni finish_reason).", "Red")
            emit("   -> Posible caida o falta de memoria de llama-server.", "Yellow")
            _save_partial()
            return False, log_lines

        # Priorizar el bloque completo mas largo
        blocks = complete_blocks if complete_blocks else closed_blocks
        if not blocks:
            blocks = [b.strip() for b in _FENCE_RE.findall(raw_answer_clean)]
        raw_code = max(blocks, key=len) if blocks else raw_answer_clean.strip()

        if not raw_code:

            emit("[ERROR] El modelo local devolvio una respuesta vacia.", "Red")
            return False, log_lines

        script_out.write_text(raw_code, encoding="utf-8")
        sync_workspaces(from_v4_to_app=True)
        emit("[EXITO] Codigo R generado localmente en tu equipo con privacidad total.", "Green")
        return True, log_lines
    except urllib.error.HTTPError as he:
        try:
            body = he.read().decode("utf-8", errors="replace")[:500]
        except Exception:
            body = ""
        emit(f"[ERROR CRITICO] El servidor local respondio HTTP {he.code} ({local_host}).", "Red")
        if body:
            emit(f"Detalle del servidor: {body}", "DarkGray")
        if he.code in (400, 413) or "context" in body.lower():
            emit("   -> Probablemente la consulta/prompt excede el contexto del modelo local (12K).", "Yellow")
        return False, log_lines
    except (ValueError, RuntimeError) as e:
        _save_partial()
        emit(f"[ERROR] {e}", "Red")
        return False, log_lines
    except Exception as e:
        if CANCEL_EVENT.is_set():
            emit("[CANCELADO] Generacion local detenida por el usuario.", "Yellow")
            return False, log_lines
        if full_code_parts:
            emit(f"[ERROR CRITICO] Se perdio la conexion con la IA local a mitad de la generacion ({local_host}).", "Red")
            emit("   -> ¿Se cerro llama-server o se quedo sin memoria?", "Yellow")
            _save_partial()
        else:
            emit(f"[ERROR CRITICO] No se pudo conectar al servidor local de IA ({local_host}).", "Red")
        emit(f"Detalle tecnico: {type(e).__name__}: {e}", "DarkGray")
        return False, log_lines

def _infer_color_for_repair_line(line: str) -> str:
    l = line.strip()
    if l.startswith("--- [INTENTO"):
        return "Yellow"
    if "[EXITO]" in l or "CONVERGENCIA EXITOSA" in l or "CUMPLIO EL CONTRATO" in l:
        return "Green"
    if "[AUDITOR DE CONTRATO]" in l:
        if "aprobado" in l.lower():
            return "Green"
        if "VIOLACION" in l or "Fallo" in l:
            return "Red"
        return "Yellow"
    if "[BLINDAJE" in l or "[ALINEACION" in l or "[AUTO-REPARACION" in l:
        return "Cyan"
    if "[ERROR" in l or "[FALLO" in l or "VIOLACION" in l:
        return "Red"
    if "[AVISO" in l or "[REPARACION" in l or "[DIAGNOSTICO" in l:
        return "Yellow"
    return "White"

def run_with_repair_pipeline(engine: str, on_line=None) -> dict:
    """
    Idéntico a líneas 1801-1805 de charly_core.ps1:
    Ejecuta runtime/run_with_repair.ps1 -ScriptPath "workspace/generated_script.R" -Engine $Engine

    y abre RStudio con Ensure-RStudioOpen.

    """
    # Purga defensiva de avisos_r.txt en todos los workspaces antes de la nueva ejecucion
    purge_dirs = [V4_WORKSPACE, APP_WORKSPACE]
    if EXT_WORKSPACE and EXT_WORKSPACE.exists():
        purge_dirs.append(EXT_WORKSPACE)
    for pdir in purge_dirs:
        paf = pdir / "avisos_r.txt"
        if paf.exists():
            try:
                paf.unlink()
            except Exception:
                pass

    exit_code, _out = run_proc(

        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            "runtime/run_with_repair.ps1",
            "-ScriptPath",
            "workspace/generated_script.R",
            "-Engine",
            engine,
        ],
        cwd=str(CHARLY_V4_DIR),
        env=get_engine_env(),
        timeout=3600,
        on_line=on_line,
    )
    cancelled = CANCEL_EVENT.is_set()
    sync_workspaces(from_v4_to_app=True)
    if not cancelled:
        ensure_rstudio_open("workspace/generated_script.R")
    res_file = V4_WORKSPACE / "resultados_analisis.txt"
    con_file = V4_WORKSPACE / "consola_rstudio_completa.txt"
    script_out = V4_WORKSPACE / "generated_script.R"
    avisos_file = V4_WORKSPACE / "avisos_r.txt"

    return {
        "avisos": avisos_file.read_text(encoding="utf-8-sig", errors="replace") if (avisos_file.exists() and exit_code == 0) else "",
        "exit_code": exit_code,
        "cancelled": cancelled,
        "success": exit_code == 0 and not cancelled,
        "contract_unmet": exit_code == 2 and not cancelled,  # R ejecuto bien pero el auditor de contrato reporta incumplimientos
        "resultados": res_file.read_text(encoding="utf-8-sig", errors="replace") if res_file.exists() else "",
        "consola": con_file.read_text(encoding="utf-8-sig", errors="replace") if con_file.exists() else "",
        "code": script_out.read_text(encoding="utf-8-sig", errors="replace") if script_out.exists() else "",
    }

def run_data_descriptives(target_file: str) -> dict:
    """
    Idéntico a Show-DataDescriptives (líneas 1899-1914 de charly_core.ps1):
    & $Rscript "profiler/generate_descriptives_report.R" "$targetFile" "$reportOut" "$fileName"
    """
    rscript = find_rscript()
    if not rscript:
        return {"success": False, "output": "No se encontro Rscript.exe"}

    target_abs = str(Path(target_file).resolve())
    file_name = Path(target_abs).name
    report_out = V4_WORKSPACE / "descriptivos_base.txt"

    res = subprocess.run(
        [
            rscript,
            "profiler/generate_descriptives_report.R",
            target_abs,
            "workspace/descriptivos_base.txt",
            file_name,
        ],
        cwd=str(CHARLY_V4_DIR),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=NO_WINDOW,
    )
    sync_workspaces(from_v4_to_app=True)
    if res.returncode == 0 and report_out.exists():
        subprocess.Popen(["notepad.exe", str(report_out.resolve())])
        return {
            "success": True,
            "report_path": str(report_out.resolve()),
            "report_text": report_out.read_text(encoding="utf-8-sig", errors="replace"),
        }
    return {
        "success": False,
        "output": ((res.stdout or "") + "\n" + (res.stderr or "")).strip(),
    }

REQUIRED_R_PACKAGES = ["lavaan", "semTools", "psych", "GPArotation", "MASS", "readxl", "jsonlite", "haven"]

def diagnose_r_environment() -> dict:
    """Verifica la instalación de R y el estado/versión de los paquetes psicométricos requeridos."""
    rscript = find_rscript(force=True)
    if not rscript or not os.path.isfile(rscript):
        return {
            "r_found": False,
            "rscript": "",
            "r_version": "No detectado",
            "packages": {pkg: {"installed": False, "version": ""} for pkg in REQUIRED_R_PACKAGES},
            "missing": list(REQUIRED_R_PACKAGES),
        }

    pkgs_r_vec = ", ".join([f"'{p}'" for p in REQUIRED_R_PACKAGES])
    r_code = (
        f"pkgs <- c({pkgs_r_vec}); "
        "cat('RVER:', R.version.string, '\\n', sep=''); "
        "for (p in pkgs) { "
        "  if (requireNamespace(p, quietly=TRUE)) { "
        "    cat('PKG:', p, ':OK:', as.character(packageVersion(p)), '\\n', sep='') "
        "  } else { "
        "    cat('PKG:', p, ':MISSING:\\n', sep='') "
        "  } "
        "}"
    )
    try:
        # run_proc: sin deadlock, con timeout y matando tambien al R.exe hijo (antes quedaba huerfano)
        _rc, out = run_proc([rscript, "-e", r_code], timeout=90)
        timed_out = "Tiempo maximo excedido" in out
        r_ver = "R no respondio a tiempo (se cancelo la verificacion)" if timed_out else "Detectado"
        pkg_status = {pkg: {"installed": False, "version": ""} for pkg in REQUIRED_R_PACKAGES}
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("RVER:"):
                r_ver = line[5:].strip()
            elif line.startswith("PKG:"):
                parts = line.split(":")
                if len(parts) >= 4:
                    p_name, st, ver = parts[1], parts[2], parts[3]
                    if p_name in pkg_status:
                        pkg_status[p_name] = {"installed": st == "OK", "version": ver}
        missing = [p for p, info in pkg_status.items() if not info["installed"]]
        return {
            "r_found": True,
            "rscript": rscript,
            "r_version": r_ver,
            "packages": pkg_status,
            "missing": missing,
        }
    except Exception as e:
        return {
            "r_found": True,
            "rscript": rscript,
            "r_version": f"Error al consultar R ({e})",
            "packages": {pkg: {"installed": False, "version": ""} for pkg in REQUIRED_R_PACKAGES},
            "missing": list(REQUIRED_R_PACKAGES),
        }

def install_missing_r_packages(packages: list[str] | None = None, on_line=None) -> tuple[bool, str]:
    """Instala automáticamente los paquetes de R faltantes en la librería de usuario (sin requerir permisos de Admin)."""
    diag = diagnose_r_environment()
    if not diag["r_found"]:
        return False, "No se encontró R instalado en la computadora. Primero instala R desde cran.r-project.org."

    to_install = packages if packages is not None else diag["missing"]
    if not to_install:
        return True, "Todos los paquetes psicométricos requeridos ya están instalados y listos."

    rscript = diag["rscript"]
    pkgs_r_vec = ", ".join([f"'{p}'" for p in to_install])
    r_cmd = (
        "user_lib <- Sys.getenv('R_LIBS_USER'); "
        "if (nzchar(user_lib) && !dir.exists(user_lib)) dir.create(user_lib, recursive=TRUE, showWarnings=FALSE); "
        "if (nzchar(user_lib)) .libPaths(c(user_lib, .libPaths())); "
        f"pkgs <- c({pkgs_r_vec}); "
        "for (p in pkgs) { "
        "  if (!requireNamespace(p, quietly=TRUE)) { "
        "    cat('[INSTALANDO PAQUETE R]:', p, '...\\n'); "
        "    install.packages(p, repos='https://cloud.r-project.org', dependencies=NA, Ncpus=min(4L, max(1L, parallel::detectCores() - 1L))) "
        "  } "
        "}; "
        "cat('[VERIFICACION FINAL]\\n')"
    )
    try:
        _rc, _out = run_proc(
            [rscript, "-e", r_cmd],
            timeout=1800,
            on_line=(lambda l, c: on_line(l)) if on_line else None,
        )
        logs = [l for l in _out.splitlines() if l]
        after = diagnose_r_environment()
        if not after["missing"]:
            return True, "Todos los paquetes psicométricos fueron instalados correctamente."
        return False, f"Aún faltan instalar: {', '.join(after['missing'])}.\nDetalle:\n" + "\n".join(logs[-15:])
    except Exception as e:
        return False, str(e)

def test_cloud_connection(api_key: str, model: str = "gemini-flash-lite-latest") -> tuple[bool, str]:
    """Prueba en segundos si la API Key de Google Gemini funciona correctamente."""
    key = (api_key or "").strip()
    if not key:
        return False, "Por favor, pega primero tu clave API Key de Google AI Studio."
    models_to_try = list(dict.fromkeys([model.strip() or "gemini-flash-lite-latest", "gemini-flash-lite-latest", "gemini-flash-latest", "gemini-2.5-flash", "gemini-2.0-flash"]))
    last_err = ""
    for m in models_to_try:
        # [FIX M11] la clave viaja en el encabezado x-goog-api-key, no en la URL (queda en logs de proxy/antivirus)
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{m}:generateContent"
        payload = {
            "contents": [{"role": "user", "parts": [{"text": "Responde solo: OK"}]}],
            "generationConfig": {"temperature": 0.0, "maxOutputTokens": 10},
        }
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json; charset=utf-8", "x-goog-api-key": key},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status == 200:
                    return True, f"✅ Conexión exitosa con Google Gemini ({m}). ¡Ya puedes analizar en la Nube!"
        except urllib.error.HTTPError as he:
            try:
                err_body = he.read().decode("utf-8", errors="replace")
            except Exception:
                err_body = str(he)
            if he.code in (400, 401, 403) and ("API_KEY_INVALID" in err_body or "key" in err_body.lower()):
                return False, "❌ La API Key ingresada no es válida. Verifícala en Google AI Studio (aistudio.google.com)."
            last_err = f"HTTP {he.code}: {err_body[:160]}"
        except Exception as e:
            last_err = str(e)
    return False, f"❌ No se pudo conectar con Google Gemini: {last_err}"

_GGUF_SPLIT_RE = re.compile(r"-(\d{5})-of-(\d{5})\.gguf$", re.IGNORECASE)
_GGUF_AUX_TOKENS = ("mmproj", "mtp-", "adapter", "vae", "lora")

def _is_auxiliary_gguf(path_or_name: str | Path) -> bool:
    """
    Descarta archivos que no son un modelo de texto cargable: proyectores multimodales (mmproj), modulos MTP,
    adaptadores/LoRA/VAE (en cualquier parte del nombre) y fragmentos de modelos partidos que NO son el primero
    (llama-server necesita '...-00001-of-0000N.gguf' y localiza el resto solo).
    """
    name = Path(path_or_name).name.lower()
    if any(tok in name for tok in _GGUF_AUX_TOKENS):
        return True
    m = _GGUF_SPLIT_RE.search(name)
    return bool(m and m.group(1) != "00001")

def _gguf_size_bytes(p: Path) -> int:
    """Tamano real del modelo; en modelos partidos suma todos los fragmentos."""
    try:
        m = _GGUF_SPLIT_RE.search(p.name)
        if m:
            stem = p.name[: m.start()]
            return sum(
                q.stat().st_size
                for q in p.parent.glob("*.gguf")
                if q.name.startswith(stem) and _GGUF_SPLIT_RE.search(q.name)
            )
        return p.stat().st_size
    except OSError:
        return 0

def _select_best_gguf(models_dir: Path, preferred_path: str = "") -> Path | None:
    """
    Selecciona el .gguf mas adecuado de models_dir:
    1) Si preferred_path existe y es un modelo de texto valido, lo respeta (si es un fragmento 'k-of-N' usa el 1.o).
    2) Prioriza Qwen3.6-35B-A3B -> Qwen3-Coder-30B-A3B -> qwen2.5-coder-32b -> otros qwen.
    3) Dentro de cada familia elige la cuantizacion MAS GRANDE QUE ENTRE EN LA RAM (<= 80 % de la RAM total, para dejar
       lugar al KV-cache y al sistema); antes elegia siempre la mas pesada, aunque no cupiera.
    4) Si ninguno entra, devuelve el mas chico (para que al menos cargue) en vez del mas grande.
    """
    if preferred_path:
        pref = Path(preferred_path)
        if pref.is_file() and pref.suffix.lower() == ".gguf":
            m = _GGUF_SPLIT_RE.search(pref.name)
            if m and m.group(1) != "00001":
                first = pref.with_name(pref.name[: m.start()] + f"-00001-of-{m.group(2)}.gguf")
                if first.is_file():
                    return first
            elif not _is_auxiliary_gguf(pref):
                return pref

    if not models_dir.exists():
        return None

    valid_ggufs = [p for p in models_dir.glob("*.gguf") if p.is_file() and not _is_auxiliary_gguf(p)]
    if not valid_ggufs:
        return None

    _free_gb, total_gb = get_ram_status()
    budget = total_gb * 0.80 * (1024**3) if total_gb > 0 else float("inf")

    def pick(cands: list[Path]) -> Path | None:
        fitting = [p for p in cands if _gguf_size_bytes(p) <= budget]
        return max(fitting, key=_gguf_size_bytes) if fitting else None

    priority_patterns = ["qwen3.6-35b-a3b", "qwen3-coder-30b-a3b", "qwen2.5-coder-32b", "qwen"]
    for pat in priority_patterns:
        best = pick([p for p in valid_ggufs if pat in p.name.lower()])
        if best:
            return best
    best = pick(valid_ggufs)
    if best:
        return best
    return min(valid_ggufs, key=_gguf_size_bytes)  # nada entra en RAM: el mas liviano

def test_local_ai_connection(settings: dict) -> tuple[bool, str]:
    """Verifica el estado del motor de IA Local según el modo elegido (Opción A: URL vs Opción B: llama-server + .gguf)."""
    free_gb, total_gb = get_ram_status()
    ram_info = f"RAM detectada: {free_gb} GB libres de {total_gb} GB totales."
    mode = settings.get("local_mode") or "llama_server"
    host = (settings.get("local_host") or "http://127.0.0.1:8090").rstrip("/")

    if mode == "llama_server":
        srv_exe = (settings.get("llama_server_exe") or r"C:\llama-cpp\llama-server.exe").strip()
        mod_path = (settings.get("gguf_model_path") or "").strip()
        if not mod_path or not os.path.isfile(mod_path) or _is_auxiliary_gguf(mod_path):
            best = _select_best_gguf(Path(r"C:\llama-cpp\models"), mod_path)
            if best:
                mod_path = str(best)
                settings["gguf_model_path"] = mod_path

        if mod_path and _is_auxiliary_gguf(mod_path):
            return (
                False,
                f"❌ El archivo seleccionado ({Path(mod_path).name}) es un módulo auxiliar (mmproj/mtp), no un modelo de lenguaje .gguf.\n{ram_info}",
            )

        missing_parts = []
        if not os.path.isfile(srv_exe):
            missing_parts.append(f"Ejecutable llama-server.exe ({srv_exe})")
        if not mod_path or not os.path.isfile(mod_path):
            missing_parts.append(f"Modelo .gguf ({mod_path or 'no especificado'})")

        if missing_parts:
            return (
                False,
                f"⚠️ En Opción B faltan configurar archivos válidos: {', '.join(missing_parts)}.\n"
                f"Si usas Ollama o LM Studio, cambia arriba a 'Opción A'.\n{ram_info}",
            )

        size_gb = round(os.path.getsize(mod_path) / (1024**3), 2)
        srv_running = False
        for ep in (f"{host}/health", f"{host}/v1/models", "http://127.0.0.1:8090/health"):
            try:
                req = urllib.request.Request(ep, method="GET")
                with _LOCAL_OPENER.open(req, timeout=2) as resp:
                    if resp.status == 200:
                        srv_running = True
                        break
            except Exception:
                pass

        if srv_running:
            return (
                True,
                f"✅ Opción B activa: llama-server respondiendo en {host} con {Path(mod_path).name} ({size_gb} GB).\n{ram_info}",
            )
        return (
            True,
            f"✅ Archivos Opción B verificados: {Path(srv_exe).name} + {Path(mod_path).name} ({size_gb} GB).\n"
            f"El servidor se encenderá solo automáticamente cuando elijas [2] Modo Local.\n{ram_info}",
        )

    # Modo Opción A: Endpoint por URL (Ollama, LM Studio, Jan, GPT4All, etc.)
    configured_model = (settings.get("local_model_name") or "").strip()
    detected_models: list[str] = []
    server_alive = False

    try:
        req = urllib.request.Request(f"{host}/v1/models", method="GET")
        with _LOCAL_OPENER.open(req, timeout=2.5) as resp:
            if resp.status == 200:
                server_alive = True
                raw = json.loads(resp.read().decode("utf-8", errors="replace"))
                for item in raw.get("data") or []:
                    mid = item.get("id")
                    if mid:
                        detected_models.append(str(mid))
    except Exception:
        pass

    if _port_of(host) == 11434 and not detected_models:
        try:
            req = urllib.request.Request(f"{host}/api/tags", method="GET")
            with _LOCAL_OPENER.open(req, timeout=2.5) as resp:
                if resp.status == 200:
                    server_alive = True
                    raw = json.loads(resp.read().decode("utf-8", errors="replace"))
                    for item in raw.get("models") or []:
                        mname = item.get("name")
                        if mname:
                            detected_models.append(str(mname))
        except Exception:
            pass

    if not server_alive:
        try:
            req = urllib.request.Request(f"{host}/health", method="GET")
            with _LOCAL_OPENER.open(req, timeout=2.5) as resp:
                if resp.status == 200:
                    server_alive = True
        except Exception:
            pass

    if not server_alive:
        return (
            False,
            f"⚠️ No se detectó ningún servidor local activo en {host}.\n"
            f"Abre primero tu programa (Ollama en 11434, LM Studio en 1234, Jan en 1337 o GPT4All en 4891), o cambia a Opción B si usas llama-server.exe.\n{ram_info}",
        )

    if detected_models:
        if not configured_model or configured_model == "local-model" or configured_model not in detected_models:
            # Si el nombre puesto no coincide con los modelos reales del servidor, sugerir/ajustar al primero disponible
            chosen = detected_models[0]
            settings["local_model_name"] = chosen
            return (
                True,
                f"✅ Servidor activo en {host}. Modelo ajustado automáticamente a '{chosen}'.\n{ram_info}",
            )
        return (
            True,
            f"✅ Servidor activo en {host} con el modelo '{configured_model}' verificado.\n{ram_info}",
        )

    if _port_of(host) in (11434, 1234):
        return (
            False,
            f"⚠️ El servidor en {host} está abierto, pero no tiene ningún modelo descargado o cargado en memoria.\n"
            f"Carga o descarga primero un modelo en tu programa de IA Local.\n{ram_info}",
        )

    return True, f"✅ Servidor IA Local respondiendo en {host}.\n{ram_info}"

def auto_detect_local_ai(preferred_mode: str | None = None) -> dict:
    """
    Escanea inteligentemente la IA local del usuario:
    - Si está en Opción B (o si tiene C:\\llama-cpp con Qwen3.6/Qwen3), prioriza Llama.cpp y selecciona el mejor .gguf real (ignorando mmproj/mtp y orden alfabético).
    - En servidores de Opción A (Ollama, LM Studio, Jan, GPT4All), exige que tengan al menos 1 modelo real cargado antes de reportarlos como activos.
    """
    cfg = charly_secrets.load_settings()
    mode_hint = preferred_mode or cfg.get("local_mode") or "llama_server"
    custom_srv = (cfg.get("llama_server_exe") or "").strip()
    custom_gguf = (cfg.get("gguf_model_path") or "").strip()

    default_srv = custom_srv if (custom_srv and os.path.isfile(custom_srv)) else r"C:\llama-cpp\llama-server.exe"
    models_dir = Path(custom_gguf).parent if (custom_gguf and os.path.isfile(custom_gguf)) else Path(r"C:\llama-cpp\models")
    best_gguf = _select_best_gguf(models_dir, custom_gguf)
    gguf_str = str(best_gguf) if best_gguf else ""
    gguf_label = best_gguf.name if best_gguf else "local-model"

    # 1. Verificar si llama-server ya está corriendo en 8090 o 8080
    for port in (8090, 8080):
        base_url = f"http://127.0.0.1:{port}"
        try:
            req = urllib.request.Request(f"{base_url}/health", method="GET")
            with _LOCAL_OPENER.open(req, timeout=1.5) as resp:
                if resp.status == 200:
                    return {
                        "found": True,
                        "provider": "Llama.cpp (llama-server)",
                        "mode": "llama_server",
                        "host": base_url,
                        "model_name": "local-model",
                        "llama_server_exe": default_srv if os.path.isfile(default_srv) else "",
                        "gguf_model_path": gguf_str,
                        "message": f"✅ Detectado Llama.cpp activo en {base_url} ({gguf_label}).",
                    }
        except Exception:
            pass

    # 2. Si el usuario eligió explícitamente Opción B y existe llama-server.exe + .gguf en disco, devolverlo directo sin pisarlo con un Ollama vacío
    if mode_hint == "llama_server" and os.path.isfile(default_srv) and best_gguf:
        size_gb = round(best_gguf.stat().st_size / (1024**3), 2)
        return {
            "found": True,
            "provider": "Llama.cpp en disco",
            "mode": "llama_server",
            "host": "http://127.0.0.1:8090",
            "model_name": "local-model",
            "llama_server_exe": default_srv,
            "gguf_model_path": gguf_str,
            "message": f"✅ Configurado Llama.cpp (Opción B) con {best_gguf.name} ({size_gb} GB). Se encenderá automáticamente al analizar.",
        }

    # 3. Escanear servidores de Opción A (Ollama, LM Studio, Jan AI, GPT4All, KoboldCpp) verificando que tengan al menos 1 modelo real
    endpoint_candidates = [
        ("Ollama", "http://127.0.0.1:11434"),
        ("LM Studio", "http://127.0.0.1:1234"),
        ("Jan AI", "http://127.0.0.1:1337"),
        ("GPT4All", "http://127.0.0.1:4891"),
        ("KoboldCpp / TextGenWebUI", "http://127.0.0.1:5000"),
        ("KoboldCpp (5001)", "http://127.0.0.1:5001"),
    ]
    for label, base_url in endpoint_candidates:
        if _port_of(base_url) == 11434:
            try:
                req = urllib.request.Request(f"{base_url}/api/tags", method="GET")
                with _LOCAL_OPENER.open(req, timeout=1.5) as resp:
                    if resp.status == 200:
                        raw = json.loads(resp.read().decode("utf-8", errors="replace"))
                        models = raw.get("models") or []
                        if models and models[0].get("name"):
                            mod_name = str(models[0]["name"])
                            return {
                                "found": True,
                                "provider": "Ollama",
                                "mode": "endpoint",
                                "host": base_url,
                                "model_name": mod_name,
                                "message": f"✅ Detectado Ollama activo en {base_url} con el modelo '{mod_name}'.",
                            }
            except Exception:
                pass

        try:
            req = urllib.request.Request(f"{base_url}/v1/models", method="GET")
            with _LOCAL_OPENER.open(req, timeout=1.5) as resp:
                if resp.status == 200:
                    raw = json.loads(resp.read().decode("utf-8", errors="replace"))
                    data_list = raw.get("data") or []
                    if isinstance(data_list, list) and data_list and data_list[0].get("id"):
                        mod_name = str(data_list[0]["id"])
                        return {
                            "found": True,
                            "provider": label,
                            "mode": "endpoint",
                            "host": base_url,
                            "model_name": mod_name,
                            "message": f"✅ Detectado {label} activo en {base_url} con el modelo '{mod_name}'.",
                        }
        except Exception:
            pass

    # 4. Respaldo final: verificar llama-server.exe en disco aunque el usuario estuviera en Opción A
    if os.path.isfile(default_srv) and best_gguf:
        size_gb = round(best_gguf.stat().st_size / (1024**3), 2)
        return {
            "found": True,
            "provider": "Llama.cpp en disco",
            "mode": "llama_server",
            "host": "http://127.0.0.1:8090",
            "model_name": "local-model",
            "llama_server_exe": default_srv,
            "gguf_model_path": gguf_str,
            "message": f"✅ Detectado llama-server.exe + {best_gguf.name} ({size_gb} GB) en disco.",
        }

    return {
        "found": False,
        "message": (
            "⚠️ No se detectó ninguna IA local con modelos cargados en este momento.\n"
            "Si tienes Ollama, LM Studio, Jan o GPT4All, ábrelo con un modelo cargado y vuelve a pulsar '🔎 Autodetectar Mi IA Local'."
        ),
    }
