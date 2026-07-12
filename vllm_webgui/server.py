#!/usr/bin/env python3
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse


APP_NAME = os.environ.get("APP_NAME", "ai_desktop_server")
BASE_DIR = Path(os.environ.get("VLLM_WEBGUI_BASE_DIR", f"/opt/{APP_NAME}/vllm_webgui"))
CONFIG_FILE = Path(os.environ.get("VLLM_WEBGUI_CONFIG", str(BASE_DIR / "containers.json")))
HF_CACHE_BASE = Path(os.environ.get("VLLM_WEBGUI_HF_CACHE_DIR", str(BASE_DIR / "huggingface-cache")))
STATIC_DIR = Path(os.environ.get("VLLM_WEBGUI_STATIC_DIR", str(BASE_DIR / "static")))
STARTUP_STATS_FILE = Path(os.environ.get("VLLM_WEBGUI_STARTUP_STATS", str(BASE_DIR / "startup_stats.json")))
UI_SETTINGS_FILE = Path(os.environ.get("VLLM_WEBGUI_UI_SETTINGS", str(BASE_DIR / "ui_settings.json")))
HOST = os.environ.get("VLLM_WEBGUI_HOST", "0.0.0.0")
PORT = int(os.environ.get("VLLM_WEBGUI_PORT", "18000"))

DEFAULT_IMAGE = "vllm/vllm-openai:latest"
DEFAULT_MODEL = "Qwen/Qwen3-0.6B"
RUNNER_VERSION = "2026-07-12-gguf-container-cache"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{1,63}$")
PERCENT_RE = re.compile(r"(?<!\d)(100|[0-9]{1,2})(?:\.\d+)?%")
SIZE_RE = re.compile(r"([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)\s*/\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)", re.IGNORECASE)
SPLIT_GGUF_RE = re.compile(r"^(?P<prefix>.+-)(?P<index>\d+)-of-(?P<total>\d+)(?P<suffix>\.gguf)$", re.IGNORECASE)

jobs = {}
jobs_lock = threading.Lock()
config_lock = threading.Lock()
startup_lock = threading.Lock()
ui_settings_lock = threading.Lock()
cpu_lock = threading.Lock()
last_cpu_sample = None

DEFAULT_UI_SETTINGS = {
    "theme": "dark",
    "design": "default",
    "poll": {
        "overview": 5000,
        "system": 2000,
        "containers": 3000,
        "logs": 1500,
    },
    "cards": {
        "overview": True,
        "system": True,
        "form": True,
        "logs": True,
    },
    "view": {
        "containerLimit": 5,
        "modelSizeWarnReserveGb": 8,
        "containerSort": "port",
        "containerSortDirection": "asc",
        "ramSizeUnit": "GB",
        "vramSizeUnit": "GB",
        "diskSizeUnit": "GB",
        "systemTempUnit": "C",
    },
    "selected_disks": None,
}


def run(cmd, check=False, timeout=None):
    proc = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)
    if check and proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or f"command failed: {cmd}")
    return proc


def docker_available():
    return shutil.which("docker") is not None


def nvidia_smi_ok():
    return shutil.which("nvidia-smi") is not None and run(["nvidia-smi"]).returncode == 0


def nvidia_container_toolkit_ok():
    if shutil.which("nvidia-ctk") is None:
        return False
    proc = run(["dpkg-query", "-W", "-f=${Status}", "nvidia-container-toolkit"])
    return proc.returncode == 0 and "install ok installed" in proc.stdout


def docker_nvidia_runtime_ok():
    return '"nvidia"' in docker_info_runtimes()


def load_config():
    with config_lock:
        if not CONFIG_FILE.exists():
            return {"containers": []}
        try:
            return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except Exception:
            return {"containers": []}


def save_config(cfg):
    with config_lock:
        BASE_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG_FILE.write_text(json.dumps(cfg, indent=2, sort_keys=True), encoding="utf-8")
        os.chmod(CONFIG_FILE, 0o600)


def ui_int(value, default, minimum):
    try:
        return max(minimum, int(value))
    except (TypeError, ValueError):
        return default


def normalize_ui_settings(data):
    data = data if isinstance(data, dict) else {}
    poll = data.get("poll") if isinstance(data.get("poll"), dict) else {}
    cards = data.get("cards") if isinstance(data.get("cards"), dict) else {}
    view = data.get("view") if isinstance(data.get("view"), dict) else {}
    selected_disks = data.get("selected_disks")
    if selected_disks is not None:
        selected_disks = [str(item) for item in selected_disks] if isinstance(selected_disks, list) else None
    sort_fields = {"port", "name", "startup", "status", "api_ready"}
    sort_directions = {"asc", "desc"}
    size_units = {"GB", "TB"}
    temp_units = {"C", "F"}
    container_sort = view.get("containerSort")
    if container_sort == "running":
        container_sort = "status"
    container_sort_direction = view.get("containerSortDirection")
    old_system_size_unit = view.get("systemSizeUnit")
    ram_size_unit = view.get("ramSizeUnit", old_system_size_unit)
    vram_size_unit = view.get("vramSizeUnit", old_system_size_unit)
    disk_size_unit = view.get("diskSizeUnit", old_system_size_unit)
    system_temp_unit = view.get("systemTempUnit")
    return {
        "theme": data.get("theme") if data.get("theme") in ("dark", "day") else DEFAULT_UI_SETTINGS["theme"],
        "design": data.get("design") if data.get("design") in ("default", "neonsys-cyberpunk", "aurora-mesh-gradient", "aura-glassmorphism") else DEFAULT_UI_SETTINGS["design"],
        "poll": {
            "overview": ui_int(poll.get("overview"), DEFAULT_UI_SETTINGS["poll"]["overview"], 1000),
            "system": ui_int(poll.get("system"), DEFAULT_UI_SETTINGS["poll"]["system"], 500),
            "containers": ui_int(poll.get("containers"), DEFAULT_UI_SETTINGS["poll"]["containers"], 1000),
            "logs": ui_int(poll.get("logs"), DEFAULT_UI_SETTINGS["poll"]["logs"], 500),
        },
        "cards": {
            "overview": bool(cards.get("overview", DEFAULT_UI_SETTINGS["cards"]["overview"])),
            "system": bool(cards.get("system", DEFAULT_UI_SETTINGS["cards"]["system"])),
            "form": bool(cards.get("form", DEFAULT_UI_SETTINGS["cards"]["form"])),
            "logs": bool(cards.get("logs", DEFAULT_UI_SETTINGS["cards"]["logs"])),
        },
        "view": {
            "containerLimit": ui_int(view.get("containerLimit"), DEFAULT_UI_SETTINGS["view"]["containerLimit"], 1),
            "modelSizeWarnReserveGb": ui_int(view.get("modelSizeWarnReserveGb"), DEFAULT_UI_SETTINGS["view"]["modelSizeWarnReserveGb"], 0),
            "containerSort": container_sort if container_sort in sort_fields else DEFAULT_UI_SETTINGS["view"]["containerSort"],
            "containerSortDirection": container_sort_direction if container_sort_direction in sort_directions else DEFAULT_UI_SETTINGS["view"]["containerSortDirection"],
            "ramSizeUnit": ram_size_unit if ram_size_unit in size_units else DEFAULT_UI_SETTINGS["view"]["ramSizeUnit"],
            "vramSizeUnit": vram_size_unit if vram_size_unit in size_units else DEFAULT_UI_SETTINGS["view"]["vramSizeUnit"],
            "diskSizeUnit": disk_size_unit if disk_size_unit in size_units else DEFAULT_UI_SETTINGS["view"]["diskSizeUnit"],
            "systemTempUnit": system_temp_unit if system_temp_unit in temp_units else DEFAULT_UI_SETTINGS["view"]["systemTempUnit"],
        },
        "selected_disks": selected_disks,
    }


def load_ui_settings():
    with ui_settings_lock:
        if not UI_SETTINGS_FILE.exists():
            return normalize_ui_settings(DEFAULT_UI_SETTINGS)
        try:
            return normalize_ui_settings(json.loads(UI_SETTINGS_FILE.read_text(encoding="utf-8")))
        except Exception:
            return normalize_ui_settings(DEFAULT_UI_SETTINGS)


def save_ui_settings(settings):
    cleaned = normalize_ui_settings(settings)
    with ui_settings_lock:
        BASE_DIR.mkdir(parents=True, exist_ok=True)
        UI_SETTINGS_FILE.write_text(json.dumps(cleaned, indent=2, sort_keys=True), encoding="utf-8")
        os.chmod(UI_SETTINGS_FILE, 0o600)
    return cleaned


def load_startup_stats_unlocked():
    if not STARTUP_STATS_FILE.exists():
        return {"containers": {}}
    try:
        return json.loads(STARTUP_STATS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {"containers": {}}


def save_startup_stats_unlocked(stats):
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    STARTUP_STATS_FILE.write_text(json.dumps(stats, indent=2, sort_keys=True), encoding="utf-8")
    os.chmod(STARTUP_STATS_FILE, 0o600)


def startup_entry_unlocked(stats, name):
    containers = stats.setdefault("containers", {})
    return containers.setdefault(name, {"cold": [], "restart": []})


def rename_startup_stats(old_name, new_name):
    if not old_name or old_name == new_name:
        return
    with startup_lock:
        stats = load_startup_stats_unlocked()
        containers = stats.setdefault("containers", {})
        if old_name not in containers:
            return
        new_entry = containers.setdefault(new_name, {"cold": [], "restart": []})
        old_entry = containers.pop(old_name)
        for key, value in old_entry.items():
            if key not in new_entry or not new_entry.get(key):
                new_entry[key] = value
        save_startup_stats_unlocked(stats)


def record_start_attempt(name, kind):
    with startup_lock:
        stats = load_startup_stats_unlocked()
        entry = startup_entry_unlocked(stats, name)
        entry["active"] = {"started_at": time.time(), "kind": kind}
        save_startup_stats_unlocked(stats)


def clear_start_attempt(name):
    with startup_lock:
        stats = load_startup_stats_unlocked()
        entry = stats.get("containers", {}).get(name)
        if entry and entry.pop("active", None):
            save_startup_stats_unlocked(stats)


def record_api_ready(name):
    with startup_lock:
        stats = load_startup_stats_unlocked()
        entry = stats.get("containers", {}).get(name)
        if not entry or not entry.get("active"):
            return
        active = entry.pop("active")
        duration = max(0, int(time.time() - float(active.get("started_at", time.time()))))
        if duration < 2:
            save_startup_stats_unlocked(stats)
            return
        kind = active.get("kind") if active.get("kind") in ("cold", "restart") else "restart"
        samples = entry.setdefault(kind, [])
        samples.append({"duration": duration, "ts": int(time.time())})
        entry[kind] = samples[-8:]
        entry["last"] = {"duration": duration, "kind": kind, "ts": int(time.time())}
        save_startup_stats_unlocked(stats)


def average_duration(samples):
    durations = [int(sample.get("duration", 0)) for sample in samples if int(sample.get("duration", 0)) > 0]
    if not durations:
        return None
    return int(sum(durations[-5:]) / len(durations[-5:]))


def format_duration(seconds):
    if seconds is None:
        return ""
    seconds = max(0, int(seconds))
    minutes, secs = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes:02d}m"
    if minutes:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


def format_runtime_duration(seconds):
    seconds = max(0, int(seconds or 0))
    minutes, secs = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    days, hours = divmod(hours, 24)
    if days:
        return f"{days}d {hours:02d}h"
    if hours:
        return f"{hours}h {minutes:02d}m"
    if minutes:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


def runtime_status_for(name, api_ready):
    now = time.time()
    with startup_lock:
        stats = load_startup_stats_unlocked()
        entry = startup_entry_unlocked(stats, name)
        runtime = entry.setdefault("runtime", {})
        total = max(0.0, float(runtime.get("total_seconds", 0) or 0))
        last_seen = runtime.get("last_ready_seen_at")
        changed = False

        if api_ready:
            if last_seen:
                delta = max(0.0, now - float(last_seen))
                if delta >= 0.5:
                    total += delta
                    changed = True
            else:
                runtime["active_since"] = now
                changed = True
            runtime["last_ready_seen_at"] = now
            runtime["active"] = True
            runtime["total_seconds"] = int(total)
            runtime["updated_at"] = int(now)
        else:
            if runtime.get("active") or runtime.get("last_ready_seen_at") or runtime.get("active_since"):
                runtime["active"] = False
                runtime.pop("last_ready_seen_at", None)
                runtime.pop("active_since", None)
                runtime["updated_at"] = int(now)
                changed = True

        if changed:
            save_startup_stats_unlocked(stats)

        total_seconds = int(runtime.get("total_seconds", 0) or 0)
        return {
            "total_seconds": total_seconds,
            "text": f"Laufzeit {format_runtime_duration(total_seconds)}",
            "active": bool(api_ready),
        }


def finalize_runtime_tracking(name):
    now = time.time()
    with startup_lock:
        stats = load_startup_stats_unlocked()
        entry = stats.get("containers", {}).get(name)
        if not entry:
            return
        runtime = entry.setdefault("runtime", {})
        last_seen = runtime.get("last_ready_seen_at")
        total = max(0.0, float(runtime.get("total_seconds", 0) or 0))
        if last_seen:
            total += max(0.0, now - float(last_seen))
        runtime["total_seconds"] = int(total)
        runtime["active"] = False
        runtime.pop("last_ready_seen_at", None)
        runtime.pop("active_since", None)
        runtime["updated_at"] = int(now)
        save_startup_stats_unlocked(stats)


def set_runtime_seconds(name, seconds):
    seconds = max(0, int(seconds or 0))
    item = find_config(name)
    api_ready = api_status_ready(item) if item and container_running(name) else False
    now = time.time()
    with startup_lock:
        stats = load_startup_stats_unlocked()
        entry = startup_entry_unlocked(stats, name)
        runtime = entry.setdefault("runtime", {})
        runtime["total_seconds"] = seconds
        runtime["active"] = bool(api_ready)
        runtime["updated_at"] = int(now)
        if api_ready:
            runtime["last_ready_seen_at"] = now
            runtime.setdefault("active_since", now)
        else:
            runtime.pop("last_ready_seen_at", None)
            runtime.pop("active_since", None)
        save_startup_stats_unlocked(stats)
        return {
            "total_seconds": seconds,
            "text": f"Laufzeit {format_runtime_duration(seconds)}",
            "active": bool(api_ready),
        }


def startup_status_for(name, status, api_ready):
    if api_ready:
        record_api_ready(name)
    elif status != "running" and not latest_start_job_for(name):
        clear_start_attempt(name)

    with startup_lock:
        stats = load_startup_stats_unlocked()
        entry = stats.get("containers", {}).get(name, {})
        active = entry.get("active")
        last = entry.get("last")

        if active and not api_ready:
            kind = active.get("kind") if active.get("kind") in ("cold", "restart") else "restart"
            elapsed = max(0, int(time.time() - float(active.get("started_at", time.time()))))
            estimate = average_duration(entry.get(kind, []))
            if estimate:
                text = f"Startzeit: {format_duration(elapsed)} / ca. {format_duration(estimate)}"
                title = "Schaetzung aus bisherigen normalen Neustarts." if kind == "restart" else "Schaetzung aus bisherigen Erststarts/Neuaufbauten mit Pull/Download."
                sort_seconds = estimate
            else:
                text = f"Startzeit: Berechnung ({format_duration(elapsed)})"
                title = "Noch keine verlaessliche Startzeit. Erststart, Docker-Pull und Modelldownload koennen deutlich laenger dauern."
                sort_seconds = None
            return {"text": text, "title": title, "state": "measuring", "kind": kind, "sort_seconds": sort_seconds}

        restart_estimate = average_duration(entry.get("restart", []))
        cold_estimate = average_duration(entry.get("cold", []))
        if restart_estimate:
            title = "Ungefaehre API-Startzeit nach einem normalen Neustart. Erststart/Pull/Download dauert laenger."
            return {"text": f"Startzeit ca. {format_duration(restart_estimate)}", "title": title, "state": "estimated", "kind": "restart", "sort_seconds": restart_estimate}
        if cold_estimate:
            title = "Bisher nur Erststart/Neuaufbau gemessen. Normale Neustarts werden spaeter genauer."
            return {"text": f"Startzeit ca. {format_duration(cold_estimate)}", "title": title, "state": "estimated", "kind": "cold", "sort_seconds": cold_estimate}
        if last:
            duration = int(last.get("duration", 0) or 0)
            return {"text": f"Letzter Start {format_duration(duration)}", "title": "Noch zu wenig Daten fuer eine stabile Schaetzung.", "state": "last", "kind": last.get("kind", ""), "sort_seconds": duration or None}
    return {"text": "Startzeit: Berechnung", "title": "Noch keine erfolgreiche Startzeit gemessen.", "state": "unknown", "kind": "", "sort_seconds": None}


def list_configured():
    cfg = load_config()
    return cfg.get("containers", [])


def find_config(name):
    for item in list_configured():
        if item.get("name") == name:
            return item
    return None


def upsert_config(item):
    cfg = load_config()
    containers = [c for c in cfg.get("containers", []) if c.get("name") != item["name"]]
    containers.append(item)
    cfg["containers"] = sorted(containers, key=lambda c: c.get("name", ""))
    save_config(cfg)


def rename_cache_dir(old_name, new_name):
    if not old_name or old_name == new_name:
        return
    old_dir = HF_CACHE_BASE / old_name
    new_dir = HF_CACHE_BASE / new_name
    if not old_dir.exists():
        return
    if new_dir.exists():
        if new_dir.is_dir() and not any(new_dir.iterdir()):
            new_dir.rmdir()
        else:
            raise ValueError(f"Cache-Ordner fuer neuen Namen existiert bereits: {new_dir}")
    if new_dir.exists():
        raise ValueError(f"Cache-Ordner fuer neuen Namen existiert bereits: {new_dir}")
    old_dir.rename(new_dir)


def hf_repo_cache_name(repo_id):
    return "models--" + repo_id.replace("/", "--")


def repo_id_from_cache_name(name):
    if not name.startswith("models--"):
        return ""
    return name.removeprefix("models--").replace("--", "/")


def is_hf_repo_id(value):
    text = str(value or "").strip()
    if not text or text.startswith("/") or "://" in text:
        return False
    if ":" in text:
        text = text.split(":", 1)[0]
    return "/" in text and not text.startswith(".")


def hf_repo_refs(item):
    refs = set()
    candidates = []
    if item.get("model_format") == "hf":
        candidates.append(item.get("model", ""))
    if item.get("model_format") == "gguf":
        candidates.extend([
            item.get("gguf_repo", ""),
            item.get("tokenizer", ""),
            item.get("hf_config_path", ""),
        ])
    for value in candidates:
        if is_hf_repo_id(value):
            refs.add(str(value).strip().split(":", 1)[0])
    return refs


def cleanup_stale_hf_cache(item):
    cache_dir = HF_CACHE_BASE / item["name"]
    if not cache_dir.exists() or not cache_dir.is_dir():
        return []

    keep = {hf_repo_cache_name(repo) for repo in hf_repo_refs(item)}
    removed = []
    for base in (cache_dir, cache_dir / "hub"):
        if not base.exists() or not base.is_dir():
            continue
        for child in base.iterdir():
            if not child.is_dir() or not child.name.startswith("models--"):
                continue
            if child.name in keep:
                continue
            shutil.rmtree(child)
            removed.append(repo_id_from_cache_name(child.name) or str(child))
    return removed


def ensure_inside_hf_cache(path):
    base = HF_CACHE_BASE.resolve()
    target = path.resolve()
    if target == base or base not in target.parents:
        raise RuntimeError(f"Ungueltiger Cache-Pfad: {target}")


def delete_config(name):
    cfg = load_config()
    cfg["containers"] = [c for c in cfg.get("containers", []) if c.get("name") != name]
    save_config(cfg)


def default_image(profile, machine=None):
    if profile == "rocm":
        return "vllm/vllm-openai-rocm:latest"
    if profile == "xpu":
        return "vllm/vllm-openai-xpu:latest"
    if profile == "cpu":
        arch = machine or os.uname().machine
        if arch in ("aarch64", "arm64"):
            return "vllm/vllm-openai-cpu:latest-arm64"
        return "vllm/vllm-openai-cpu:latest-x86_64"
    return DEFAULT_IMAGE


def validate_container(data, old_name=None):
    item = {
        "name": str(data.get("name", "")).strip(),
        "profile": str(data.get("profile", "nvidia")).strip() or "nvidia",
        "model_format": str(data.get("model_format", "hf")).strip() or "hf",
        "image": str(data.get("image", "")).strip(),
        "model": str(data.get("model", DEFAULT_MODEL)).strip() or DEFAULT_MODEL,
        "gguf_repo": str(data.get("gguf_repo", "")).strip(),
        "gguf_file": str(data.get("gguf_file", "")).strip(),
        "gguf_url": str(data.get("gguf_url", "")).strip(),
        "tokenizer": str(data.get("tokenizer", "")).strip(),
        "hf_config_path": str(data.get("hf_config_path", "")).strip(),
        "port": int(data.get("port", 8000)),
        "hf_token": str(data.get("hf_token", "")),
        "extra_args": str(data.get("extra_args", "")),
        "docker_extra_args": str(data.get("docker_extra_args", "")),
        "autostart": bool(data.get("autostart", False)),
    }
    if not NAME_RE.match(item["name"]):
        raise ValueError("Container-Name: 2-64 Zeichen, erlaubt A-Z a-z 0-9 _ . -")
    if item["profile"] not in ("nvidia", "rocm", "xpu", "cpu"):
        raise ValueError("Unbekanntes Profil")
    if item["model_format"] not in ("hf", "gguf"):
        raise ValueError("Unbekanntes Modellformat")
    if item["model_format"] == "gguf":
        if not item["gguf_url"] and not (item["gguf_repo"] and item["gguf_file"]) and not item["gguf_file"].startswith("/"):
            raise ValueError("GGUF braucht entweder Repo + konkrete .gguf Datei, eine GGUF-URL oder einen lokalen .gguf Pfad.")
        if not item["tokenizer"]:
            raise ValueError("GGUF braucht einen Tokenizer/Base-Model-Pfad, z.B. Qwen/Qwen3-32B.")
    if not item["image"]:
        item["image"] = default_image(item["profile"])
    if item["port"] < 1 or item["port"] > 65535:
        raise ValueError("Port muss zwischen 1 und 65535 liegen")
    ensure_port_free(item["port"], item["name"] if old_name is None else old_name)
    return item


def configured_port_users(port, except_name=None):
    users = []
    for item in list_configured():
        if item.get("name") != except_name and int(item.get("port", 0)) == int(port):
            users.append(item.get("name"))
    return users


def host_ports_in_use():
    ports = set()
    if shutil.which("ss"):
        proc = run(["ss", "-ltnH"])
        for line in proc.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                addr = parts[3]
                if ":" in addr:
                    try:
                        ports.add(int(addr.rsplit(":", 1)[1]))
                    except ValueError:
                        pass
    return ports


def docker_container_port(name):
    proc = run(["docker", "port", name, "8000/tcp"])
    if proc.returncode != 0:
        return None
    text = proc.stdout.strip().splitlines()
    if not text:
        return None
    try:
        return int(text[0].rsplit(":", 1)[1])
    except ValueError:
        return None


def ensure_port_free(port, except_name=None):
    users = configured_port_users(port, except_name)
    if users:
        raise ValueError(f"Port {port} ist bereits in der GUI vergeben: {', '.join(users)}")
    if port in host_ports_in_use():
        if except_name and docker_container_port(except_name) == int(port):
            return
        raise ValueError(f"Port {port} ist bereits auf dem Host belegt")


def container_exists(name):
    if not docker_available():
        return False
    proc = run(["docker", "inspect", name])
    return proc.returncode == 0


def container_running(name):
    if not docker_available():
        return False
    proc = run(["docker", "inspect", "-f", "{{.State.Running}}", name])
    return proc.returncode == 0 and proc.stdout.strip() == "true"


def container_labels(name):
    proc = run(["docker", "inspect", "-f", "{{json .Config.Labels}}", name])
    if proc.returncode != 0:
        return {}
    try:
        return json.loads(proc.stdout.strip() or "{}") or {}
    except Exception:
        return {}


def container_hf_token(name):
    proc = run(["docker", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", name])
    if proc.returncode != 0:
        return ""
    for line in proc.stdout.splitlines():
        if line.startswith("HF_TOKEN="):
            return line.split("=", 1)[1]
    return ""


def container_runtime_current(name, item):
    return (
        container_labels(name).get("ai.vllm.webgui.config") == config_hash(item)
        and container_hf_token(name) == item.get("hf_token", "")
    )


def config_hash(item):
    keys = [
        "profile",
        "model_format",
        "image",
        "model",
        "gguf_repo",
        "gguf_file",
        "gguf_url",
        "tokenizer",
        "hf_config_path",
        "port",
        "extra_args",
        "docker_extra_args",
        "autostart",
    ]
    payload = json.dumps({"runner_version": RUNNER_VERSION, **{k: item.get(k) for k in keys}}, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


def docker_info_runtimes():
    proc = run(["docker", "info", "--format", "{{json .Runtimes}}"])
    return proc.stdout if proc.returncode == 0 else ""


def human_size(num):
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(num)
    for unit in units:
        if value < 1000 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} {unit}"
        value /= 1000
    return f"{value:.1f} TB"


def path_size_bytes(path):
    path = Path(path)
    if not path.exists():
        return 0
    if path.is_file():
        return path.stat().st_size
    total = 0
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    try:
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(Path(entry.path))
                        elif entry.is_file(follow_symlinks=False):
                            total += entry.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except OSError:
            continue
    return total


def model_cache_paths(item):
    cache_dir = HF_CACHE_BASE / item["name"]
    if item.get("model_format") == "gguf":
        gguf_file = item.get("gguf_file", "").strip()
        gguf_url = item.get("gguf_url", "").strip()
        gguf_repo = item.get("gguf_repo", "").strip()
        if gguf_file.startswith("/"):
            return split_gguf_paths(Path(gguf_file))
        if gguf_url:
            return [cache_dir / "gguf" / name for name in split_gguf_filenames(filename_from_url(gguf_url))]
        if gguf_repo and gguf_file.lower().endswith(".gguf"):
            return [cache_dir / "gguf" / name for name in split_gguf_filenames(Path(gguf_file).name)]
        if gguf_repo:
            return [
                cache_dir / "hub" / hf_repo_cache_name(gguf_repo),
                cache_dir / hf_repo_cache_name(gguf_repo),
            ]
        return [cache_dir / "gguf"]
    repo = item.get("model", "").strip()
    if is_hf_repo_id(repo):
        return [
            cache_dir / "hub" / hf_repo_cache_name(repo),
            cache_dir / hf_repo_cache_name(repo),
        ]
    return []


def model_size_for(item):
    total = 0
    seen = set()
    for path in model_cache_paths(item):
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        if resolved in seen:
            continue
        seen.add(resolved)
        total += path_size_bytes(path)
    return total


def hf_resolve_url(repo, filename):
    clean_file = filename.lstrip("/")
    quoted_file = urllib.parse.quote(clean_file, safe="/")
    return f"https://huggingface.co/{repo}/resolve/main/{quoted_file}"


def split_gguf_filenames(filename):
    name = Path(filename).name
    match = SPLIT_GGUF_RE.match(name)
    if not match:
        return [name]
    total = int(match.group("total"))
    index_width = len(match.group("index"))
    total_text = match.group("total")
    return [
        f"{match.group('prefix')}{str(index).zfill(index_width)}-of-{total_text}{match.group('suffix')}"
        for index in range(1, total + 1)
    ]


def split_gguf_paths(path):
    return [path.with_name(name) for name in split_gguf_filenames(path.name)]


def gguf_sort_key(path):
    name = Path(path).name
    match = SPLIT_GGUF_RE.match(name)
    if match:
        return (match.group("prefix").lower(), int(match.group("index")), name.lower())
    return (name.lower(), 0, name.lower())


def cached_quant_gguf_files(cache_dir, repo, quant):
    repo_dir = cache_dir / "hub" / hf_repo_cache_name(repo)
    snapshots_dir = repo_dir / "snapshots"
    if not snapshots_dir.exists():
        return []

    quant_lower = quant.lower()
    matches = []
    for path in snapshots_dir.rglob("*.gguf"):
        rel_parts = [part.lower() for part in path.relative_to(snapshots_dir).parts]
        if quant_lower in path.name.lower() or quant_lower in rel_parts:
            matches.append(path)
    return sorted(matches, key=gguf_sort_key)


def materialize_gguf_files(job_id, source_paths, cache_dir):
    if not source_paths:
        return ""
    gguf_dir = cache_dir / "gguf"
    gguf_dir.mkdir(parents=True, exist_ok=True)
    first_name = Path(source_paths[0]).name
    for source in source_paths:
        source = Path(source)
        source_real = source.resolve()
        dest = gguf_dir / source.name
        if dest.exists() and dest.stat().st_size == source_real.stat().st_size:
            append_job(job_id, f"GGUF Datei bereits bereitgestellt: {dest}")
            continue
        if dest.exists():
            dest.unlink()
        try:
            os.link(source_real, dest)
        except OSError:
            shutil.copy2(source_real, dest)
        append_job(job_id, f"GGUF Datei bereitgestellt: {dest}")
    return f"/root/.cache/huggingface/gguf/{first_name}"


def sibling_url(url, filename):
    parsed = urllib.parse.urlparse(url)
    path = Path(urllib.parse.unquote(parsed.path))
    sibling_path = str(path.with_name(filename))
    return urllib.parse.urlunparse(parsed._replace(path=urllib.parse.quote(sibling_path, safe="/")))


def filename_from_url(url):
    parsed = urllib.parse.urlparse(url)
    name = Path(urllib.parse.unquote(parsed.path)).name
    if not name:
        raise ValueError("Aus der GGUF-URL konnte kein Dateiname erkannt werden.")
    return name


def download_file(job_id, url, dest, hf_token=""):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        append_job(job_id, f"GGUF Datei bereits vorhanden: {dest}")
        return

    tmp = dest.with_name(dest.name + ".part")
    request = urllib.request.Request(url)
    if hf_token:
        request.add_header("Authorization", f"Bearer {hf_token}")
    append_job(job_id, f"GGUF Download: {url}")

    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            total = int(response.headers.get("Content-Length") or 0)
            downloaded = 0
            last_report = 0.0
            with tmp.open("wb") as handle:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    handle.write(chunk)
                    downloaded += len(chunk)
                    now = time.time()
                    if now - last_report >= 1.0:
                        last_report = now
                        if total:
                            percent = downloaded / total * 100
                            append_job(job_id, f"GGUF Download: {percent:.1f}% {human_size(downloaded)} / {human_size(total)}")
                        else:
                            append_job(job_id, f"GGUF Download: {human_size(downloaded)}")
        tmp.replace(dest)
        append_job(job_id, f"GGUF Download fertig: {dest}")
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)


def prepare_gguf_model(job_id, item):
    gguf_file = item.get("gguf_file", "").strip()
    gguf_url = item.get("gguf_url", "").strip()
    gguf_repo = item.get("gguf_repo", "").strip()
    cache_dir = HF_CACHE_BASE / item["name"]
    local_mounts = []

    if gguf_file.startswith("/"):
        host_path = Path(gguf_file)
        if not host_path.exists() or not host_path.is_file():
            raise RuntimeError(f"Lokale GGUF-Datei nicht gefunden: {host_path}")
        missing_parts = [path for path in split_gguf_paths(host_path) if not path.exists()]
        if missing_parts:
            raise RuntimeError("Lokale GGUF-Split-Dateien fehlen: " + ", ".join(str(path) for path in missing_parts))
        container_dir = "/models/gguf-local"
        local_mounts.append(f"{host_path.parent}:{container_dir}:ro")
        return f"{container_dir}/{host_path.name}", local_mounts

    if gguf_url:
        filename = filename_from_url(gguf_url)
        for name in split_gguf_filenames(filename):
            dest = cache_dir / "gguf" / name
            download_file(job_id, sibling_url(gguf_url, name), dest, item.get("hf_token", ""))
        return f"/root/.cache/huggingface/gguf/{filename}", local_mounts

    if gguf_repo and gguf_file.lower().endswith(".gguf"):
        filename = Path(gguf_file).name
        parent = str(Path(gguf_file).parent)
        parent = "" if parent == "." else parent.strip("/")
        for name in split_gguf_filenames(filename):
            repo_file = f"{parent}/{name}" if parent else name
            dest = cache_dir / "gguf" / name
            download_file(job_id, hf_resolve_url(gguf_repo, repo_file), dest, item.get("hf_token", ""))
        return f"/root/.cache/huggingface/gguf/{filename}", local_mounts

    if gguf_repo and gguf_file:
        cached_files = cached_quant_gguf_files(cache_dir, gguf_repo, gguf_file)
        if cached_files:
            append_job(job_id, f"GGUF Quantisierung lokal gefunden: {gguf_file} ({len(cached_files)} Datei(en))")
            return materialize_gguf_files(job_id, cached_files, cache_dir), local_mounts
        append_job(job_id, f"GGUF Hugging-Face Direktformat: {gguf_repo}:{gguf_file}")
        append_job(job_id, "Hinweis: Wenn das Plugin danach Dateien in snapshots/<hash>/<quant>/ findet, aber nicht startet, Container erneut starten; die WebGUI nutzt dann den lokalen Cache direkt.")
        return f"{gguf_repo}:{gguf_file}", local_mounts

    raise RuntimeError("GGUF-Konfiguration unvollstaendig.")


def prepare_model(job_id, item):
    if item.get("model_format") == "gguf":
        return prepare_gguf_model(job_id, item)
    return item["model"], []


def write_gguf_patch_script(cache_dir):
    patch_script = cache_dir / "vllm-gguf-patch.py"
    patch_script.write_text(
        """#!/usr/bin/env python3
import pathlib
import re

import vllm_gguf_plugin.weights_adapter.default as default_adapter


path = pathlib.Path(default_adapter.__file__)
source = path.read_text()
before = source

if "_vllm_webgui_qwen35_text_config_patch" not in source:
    source = re.sub(
        r"(text_config = config\\.get_text_config\\(\\)\\n)",
        r"\\1"
        "        # _vllm_webgui_qwen35_text_config_patch\\n"
        "        if getattr(config, \\"model_type\\", None) == \\"qwen3_5\\":\\n"
        "            for _key, _value in text_config.to_dict().items():\\n"
        "                if not hasattr(config, _key):\\n"
        "                    setattr(config, _key, _value)\\n"
        "            if hasattr(config, \\"vision_config\\"):\\n"
        "                config.vision_config = None\\n",
        source,
        count=1,
    )

source = re.sub(
    r"is_multimodal = \\(\\n\\s+hasattr\\(config, \\"vision_config\\"\\)",
    "is_multimodal = (\\n"
    "            model_type != \\"qwen3_5\\"\\n"
    "            and hasattr(config, \\"vision_config\\")",
    source,
    count=1,
)

needle = 'if model_type == "gemma3_text":\\n            model_type = "gemma3"'
patch = needle + '\\n        if model_type == "qwen3_5":\\n            model_type = "qwen3"'
if 'if model_type == "qwen3_5"' not in source:
    source = source.replace(needle, patch)

path.write_text(source)
print("GGUF plugin patch:", "applied" if source != before else "already-present-or-not-matched")
""",
        encoding="utf-8",
    )
    os.chmod(patch_script, 0o755)
    return patch_script


def build_run_args(item, model_arg=None, extra_mounts=None):
    cache_dir = HF_CACHE_BASE / item["name"]
    cache_dir.mkdir(parents=True, exist_ok=True)
    if item.get("model_format") == "gguf":
        write_gguf_patch_script(cache_dir)
    restart_policy = "unless-stopped" if item.get("autostart") else "no"
    model_arg = model_arg or item["model"]
    extra_mounts = extra_mounts or []
    args = [
        "docker", "run", "-d",
        "--name", item["name"],
        "--restart", restart_policy,
        "-p", f"0.0.0.0:{item['port']}:8000",
        "--ipc=host",
        "-v", f"{cache_dir}:/root/.cache/huggingface",
        "--env", f"HF_TOKEN={item.get('hf_token', '')}",
        "--label", "ai.vllm.webgui=1",
        "--label", f"ai.vllm.webgui.config={config_hash(item)}",
    ]
    for mount in extra_mounts:
        args += ["-v", mount]
    if item.get("model_format") == "gguf":
        args += ["--entrypoint", "/bin/bash"]
    profile = item.get("profile", "nvidia")
    if profile == "nvidia":
        if '"nvidia"' in docker_info_runtimes():
            args += ["--runtime", "nvidia"]
        args += ["--gpus", "all"]
    elif profile == "rocm":
        args += ["--group-add=video", "--cap-add=SYS_PTRACE", "--security-opt", "seccomp=unconfined", "--device", "/dev/kfd", "--device", "/dev/dri"]
    elif profile == "xpu":
        args += ["--device", "/dev/dri", "--group-add=render"]
    elif profile == "cpu":
        args += ["--security-opt", "seccomp=unconfined", "--cap-add", "SYS_NICE", "--shm-size=4g", "--env", "VLLM_CPU_KVCACHE_SPACE=4"]
    if item.get("docker_extra_args"):
        args += shlex.split(item["docker_extra_args"])
    args.append(item["image"])
    if item.get("model_format") == "gguf":
        install_and_serve = (
            "if command -v uv >/dev/null 2>&1; then "
            "uv pip install --system --upgrade vllm-gguf-plugin || uv pip install --upgrade vllm-gguf-plugin; "
            "else python3 -m pip install --upgrade vllm-gguf-plugin; fi; "
            "python3 /root/.cache/huggingface/vllm-gguf-patch.py; "
            "model_arg=\"$1\"; "
            "if printf '%s' \"$model_arg\" | grep -Eq '^[^/]+/[^:]+:[^:]+$'; then "
            "repo=\"${model_arg%%:*}\"; quant=\"${model_arg#*:}\"; repo_cache=\"models--${repo//\\//--}\"; "
            "snapshots=\"/root/.cache/huggingface/hub/$repo_cache/snapshots\"; "
            "if [ -d \"$snapshots\" ]; then "
            "found=\"$(find -L \"$snapshots\" -type f -name '*.gguf' | awk -v q=\"/$quant/\" -v q2=\"$quant\" 'index(tolower($0), tolower(q)) || index(tolower($0), tolower(q2)) { print; exit }')\"; "
            "if [ -n \"$found\" ]; then "
            "echo \"GGUF cache preflight: using local file $found\"; "
            "shift; set -- \"$found\" \"$@\"; "
            "else echo \"GGUF cache preflight: no local file for $model_arg in $snapshots\"; fi; "
            "else echo \"GGUF cache preflight: snapshots not found: $snapshots\"; fi; "
            "fi; "
            "exec vllm serve \"$@\""
        )
        args += [
            "-lc",
            install_and_serve,
            "vllm-gguf",
            model_arg,
            "--tokenizer",
            item["tokenizer"],
            "--served-model-name",
            item["model"],
        ]
        if item.get("hf_config_path"):
            args += ["--hf-config-path", item["hf_config_path"]]
    else:
        args.append(model_arg)
    if item.get("extra_args"):
        args += shlex.split(item["extra_args"])
    return args


def set_job(job_id, **kwargs):
    with jobs_lock:
        job = jobs.setdefault(job_id, {"id": job_id, "log": []})
        job.update(kwargs)
        return job


def append_job(job_id, line):
    with jobs_lock:
        job = jobs.setdefault(job_id, {"id": job_id, "log": []})
        job.setdefault("log", []).append(line.rstrip())
        job["log"] = job["log"][-500:]


def start_background(label, target, *args):
    job_id = str(uuid.uuid4())
    set_job(job_id, label=label, status="running", started=time.time())
    thread = threading.Thread(target=run_job, args=(job_id, target, args), daemon=True)
    thread.start()
    return job_id


def run_job(job_id, target, args):
    try:
        target(job_id, *args)
        set_job(job_id, status="done", finished=time.time())
    except Exception as exc:
        append_job(job_id, f"FEHLER: {exc}")
        set_job(job_id, status="error", error=str(exc), finished=time.time())


def stream_command(job_id, cmd):
    append_job(job_id, "$ " + " ".join(shlex.quote(x) for x in cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert proc.stdout is not None
    for line in proc.stdout:
        append_job(job_id, line)
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"Command failed ({rc}): {' '.join(cmd)}")


def job_start_container(job_id, name):
    item = find_config(name)
    if not item:
        raise RuntimeError("Container-Konfiguration nicht gefunden")
    ensure_port_free(item["port"], name)
    exists_before = container_exists(name)
    runtime_current = exists_before and container_runtime_current(name, item)
    already_ready = runtime_current and container_running(name) and api_status_ready(item)
    if not already_ready:
        record_start_attempt(name, "restart" if runtime_current else "cold")
    if exists_before:
        if runtime_current:
            stream_command(job_id, ["docker", "update", "--restart", "unless-stopped" if item.get("autostart") else "no", name])
            if not container_running(name):
                stream_command(job_id, ["docker", "start", name])
            append_job(job_id, "Container existierte bereits und wurde gestartet.")
            return
        if container_hf_token(name) != item.get("hf_token", ""):
            append_job(job_id, "HF_TOKEN hat sich geaendert oder wurde wiederhergestellt. Container wird neu erstellt.")
        stream_command(job_id, ["docker", "rm", "-f", name])
    stream_command(job_id, ["docker", "pull", item["image"]])
    model_arg, extra_mounts = prepare_model(job_id, item)
    stream_command(job_id, build_run_args(item, model_arg, extra_mounts))
    append_job(job_id, f"OpenAI Base URL: http://{local_ip()}:{item['port']}/v1")


def job_stop_container(job_id, name):
    finalize_runtime_tracking(name)
    if container_exists(name):
        stream_command(job_id, ["docker", "stop", name])
        clear_start_attempt(name)
        append_job(job_id, "Container gestoppt. Modell ist aus VRAM entladen.")
    else:
        append_job(job_id, "Container existiert nicht.")


def job_remove_container(job_id, name, remove_cache=False):
    finalize_runtime_tracking(name)
    if container_exists(name):
        stream_command(job_id, ["docker", "rm", "-f", name])
    clear_start_attempt(name)
    delete_config(name)
    if remove_cache:
        cache_dir = HF_CACHE_BASE / name
        if cache_dir.exists() and cache_dir.is_dir():
            ensure_inside_hf_cache(cache_dir)
            shutil.rmtree(cache_dir)
            append_job(job_id, f"Cache geloescht: {cache_dir}")


def job_clear_model_cache(job_id, name):
    item = find_config(name)
    if not item:
        raise RuntimeError("Container-Konfiguration nicht gefunden")
    if container_running(name):
        append_job(job_id, "Container laeuft. Stoppe Container, damit Modell/VRAM freigegeben wird.")
        stream_command(job_id, ["docker", "stop", name])
    cache_dir = HF_CACHE_BASE / name
    if not cache_dir.exists():
        append_job(job_id, f"Kein Cache vorhanden: {cache_dir}")
        return
    if not cache_dir.is_dir():
        raise RuntimeError(f"Cache-Pfad ist kein Ordner: {cache_dir}")
    ensure_inside_hf_cache(cache_dir)
    removed = []
    for child in cache_dir.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
        removed.append(child.name)
    if removed:
        append_job(job_id, f"Hugging-Face-Modellcache geloescht: {cache_dir}")
        for name_part in removed:
            append_job(job_id, f"geloescht: {name_part}")
    else:
        append_job(job_id, f"Cache war bereits leer: {cache_dir}")


def job_unload_container(job_id, name):
    job_stop_container(job_id, name)


def job_repair_nvidia(job_id):
    if not nvidia_smi_ok():
        raise RuntimeError("nvidia-smi funktioniert nicht. Erst NVIDIA-Treiber reparieren.")
    stream_command(job_id, ["apt-get", "install", "-y", "ca-certificates", "curl", "gnupg2"])
    stream_command(job_id, ["bash", "-lc", "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"])
    stream_command(job_id, ["bash", "-lc", "curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list"])
    stream_command(job_id, ["apt-get", "update"])
    stream_command(job_id, ["apt-get", "install", "-y", "nvidia-container-toolkit"])
    stream_command(job_id, ["nvidia-ctk", "runtime", "configure", "--runtime=docker"])
    stream_command(job_id, ["systemctl", "restart", "docker"])
    run(["install", "-d", "-m", "0755", "/var/run/cdi"])
    stream_command(job_id, ["nvidia-ctk", "cdi", "generate", "--output=/var/run/cdi/nvidia.yaml"])
    append_job(job_id, "NVIDIA Docker Runtime repariert.")


def local_ip():
    proc = run(["hostname", "-I"])
    return (proc.stdout.strip().split() or ["127.0.0.1"])[0]


def read_cpu_sample():
    try:
        first = Path("/proc/stat").read_text(encoding="utf-8").splitlines()[0]
        parts = [int(value) for value in first.split()[1:]]
    except Exception:
        return None
    idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
    total = sum(parts)
    return total, idle


def cpu_percent():
    global last_cpu_sample
    sample = read_cpu_sample()
    if not sample:
        return 0
    with cpu_lock:
        previous = last_cpu_sample
        last_cpu_sample = sample
    if not previous:
        return 0
    total_delta = sample[0] - previous[0]
    idle_delta = sample[1] - previous[1]
    if total_delta <= 0:
        return 0
    return round(max(0, min(100, (1 - idle_delta / total_delta) * 100)), 1)


def memory_status():
    values = {}
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            key, raw = line.split(":", 1)
            values[key] = int(raw.strip().split()[0]) * 1024
    except Exception:
        return {"percent": 0, "used": 0, "total": 0}
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    used = max(0, total - available)
    percent = round(used / total * 100, 1) if total else 0
    return {"percent": percent, "used": used, "total": total}


def gpu_status():
    if shutil.which("nvidia-smi") is None:
        return {"available": False, "gpu_percent": 0, "vram_percent": 0, "vram_used": 0, "vram_total": 0, "temp": None}
    query = "utilization.gpu,memory.used,memory.total,temperature.gpu"
    proc = run(["nvidia-smi", f"--query-gpu={query}", "--format=csv,noheader,nounits"], timeout=4)
    if proc.returncode != 0 or not proc.stdout.strip():
        return {"available": False, "gpu_percent": 0, "vram_percent": 0, "vram_used": 0, "vram_total": 0, "temp": None}
    try:
        values = [part.strip() for part in proc.stdout.splitlines()[0].split(",")]
        gpu = float(values[0])
        used = int(float(values[1])) * 1024 * 1024
        total = int(float(values[2])) * 1024 * 1024
        temp = int(float(values[3]))
    except Exception:
        return {"available": False, "gpu_percent": 0, "vram_percent": 0, "vram_used": 0, "vram_total": 0, "temp": None}
    return {
        "available": True,
        "gpu_percent": round(max(0, min(100, gpu)), 1),
        "vram_percent": round(used / total * 100, 1) if total else 0,
        "vram_used": used,
        "vram_total": total,
        "temp": temp,
    }


def disk_status():
    proc = run(["df", "-B1", "--output=source,target,size,used,pcent", "-x", "tmpfs", "-x", "devtmpfs"], timeout=4)
    if proc.returncode != 0:
        return []
    disks = []
    seen = set()
    for line in proc.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        source, target, size, used, percent = parts[:5]
        if not source.startswith("/dev/"):
            continue
        key = (source, target)
        if key in seen:
            continue
        seen.add(key)
        try:
            size_int = int(size)
            used_int = int(used)
            percent_float = float(percent.rstrip("%"))
        except ValueError:
            continue
        if size_int <= 0:
            continue
        disks.append({
            "source": source,
            "mount": target,
            "used": used_int,
            "total": size_int,
            "percent": round(max(0, min(100, percent_float)), 1),
        })
    disks.sort(key=lambda item: (item["mount"] != "/", item["mount"]))
    return disks


def system_metrics():
    gpu = gpu_status()
    return {
        "cpu": {"percent": cpu_percent()},
        "ram": memory_status(),
        "gpu": gpu,
        "disks": disk_status(),
    }


def size_to_bytes(value, unit):
    factors = {
        "B": 1,
        "KB": 1000,
        "MB": 1000 ** 2,
        "GB": 1000 ** 3,
        "TB": 1000 ** 4,
        "KIB": 1024,
        "MIB": 1024 ** 2,
        "GIB": 1024 ** 3,
        "TIB": 1024 ** 4,
    }
    return float(value) * factors.get(unit.upper(), 1)


def extract_progress_percent(text):
    values = []
    for match in PERCENT_RE.finditer(text):
        try:
            values.append((match.start(), float(match.group(1))))
        except ValueError:
            pass
    for match in SIZE_RE.finditer(text):
        current = size_to_bytes(match.group(1), match.group(2))
        total = size_to_bytes(match.group(3), match.group(4))
        if total > 0:
            values.append((match.start(), min(100.0, max(0.0, current / total * 100.0))))
    if not values:
        return None
    values.sort(key=lambda item: item[0])
    return int(values[-1][1])


def progress_from_text(text, allow_complete=False):
    percent = extract_progress_percent(text)
    if percent is None:
        return None
    if percent >= 100 and not allow_complete:
        return None
    return max(0, min(99 if not allow_complete else 100, percent))


def latest_start_job_for(name):
    with jobs_lock:
        matching = [
            job for job in jobs.values()
            if job.get("label") == f"start {name}" and job.get("status") == "running"
        ]
        if not matching:
            return None
        return max(matching, key=lambda job: job.get("started", 0))


def download_progress_for(item, status, api_ready):
    name = item["name"]
    if api_ready:
        return {"percent": 100, "active": False, "label": "API bereit"}

    job = latest_start_job_for(name)
    if job:
        text = "\n".join(job.get("log", []))
        percent = progress_from_text(text)
        return {
            "percent": percent,
            "active": True,
            "label": "Download/Start laeuft" if percent is None else f"{percent}%",
        }

    if status == "running":
        logs = tail_logs(name, lines=220)
        if "Application startup complete" in logs:
            percent = 99
            active = True
            label = "Server startet, API pruefen"
        elif "Graph capturing finished" in logs:
            percent = 95
            active = True
            label = "Startet 95%"
        elif "Loading weights took" in logs or "Model loading took" in logs:
            percent = 80
            active = True
            label = "Laedt Modell 80%"
        elif "Loading model from scratch" in logs:
            percent = 50
            active = True
            label = "Laedt Modell 50%"
        else:
            percent = progress_from_text(logs)
            active = True
            label = "Download/Start laeuft" if percent is None else f"{percent}%"
        return {
            "percent": percent,
            "active": active,
            "label": label,
        }

    return {"percent": 0, "active": False, "label": "0%"}


def api_status_ready(item):
    try:
      port = int(item.get("port", 0))
    except Exception:
      return False
    if port <= 0:
      return False

    request = (
        f"GET /v1/models HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode("ascii")
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.6) as sock:
            sock.settimeout(0.8)
            sock.sendall(request)
            data = sock.recv(128)
    except OSError:
        return False
    return data.startswith(b"HTTP/1.1 200") or data.startswith(b"HTTP/1.0 200")


def diagnose_logs(logs):
    if "DeepseekV4 fp8_ds_mla layout only supports fp8 kv-cache" in logs:
        return "DeepSeek-V4 braucht fuer dieses FP8/MLA-Layout einen FP8-KV-Cache. In Extra Args z.B. --kv-cache-dtype fp8 setzen und Container neu starten."
    if "Downloaded GGUF files not found" in logs and "quant_type" in logs:
        return "GGUF-Plugin findet die geladene Quantisierung nicht, obwohl sie im HF-Cache liegen kann. Container erneut starten: die WebGUI nutzt dann vorhandene Dateien aus snapshots/<hash>/<quant>/ direkt als lokale GGUF-Dateien."
    if "Can't get gguf config for qwen3_vl" in logs:
        return "Qwen3-VL GGUF wird vom vLLM-GGUF-Plugin nicht unterstuetzt. Nutze dafuer das normale Hugging-Face/Safetensors-Modell oder eine andere Runtime."
    gguf_config_error = re.search(r"Can't get gguf config for ([A-Za-z0-9_.-]+)", logs)
    if gguf_config_error:
        return f"GGUF nicht von vLLM-Plugin unterstuetzt: config fuer {gguf_config_error.group(1)} fehlt."
    if "Failed to map GGUF parameters" in logs and "linear_attn" in logs:
        return "GGUF nicht von vLLM-Plugin unterstuetzt: linear_attn/GDN-Gewichte koennen nicht gemappt werden. Der fast-path-Hinweis ist nur eine Warnung."
    if "Unknown gguf model_type: qwen3_5" in logs:
        return "GGUF-Plugin kennt qwen3_5 nicht. Container neu erstellen, damit der WebGUI-Patch greift."
    unknown_type = re.search(r"Unknown gguf model_type: ([A-Za-z0-9_.-]+)", logs)
    if unknown_type:
        return f"GGUF nicht von vLLM-Plugin unterstuetzt: model_type {unknown_type.group(1)} ist unbekannt."
    if "Qwen3_5VisionConfig" in logs or "Qwen3_5Config" in logs:
        return "Qwen3.5/3.6 GGUF braucht Plugin-Kompatibilitaets-Patch. Container neu erstellen."
    if "CUDA out of memory" in logs or "out of memory" in logs.lower():
        return "Nicht genug VRAM/RAM. Max Model Len senken oder kleineres/staerker quantisiertes Modell nutzen."
    return ""


def docker_status_for(item):
    name = item["name"]
    status = "missing"
    if container_exists(name):
        status = "running" if container_running(name) else "stopped"
    labels = container_labels(name) if status != "missing" else {}
    api_ready = api_status_ready(item) if status == "running" else False
    api_url = f"http://{local_ip()}:{item['port']}/v1"
    progress = download_progress_for(item, status, api_ready)
    diagnostic = diagnose_logs(tail_logs(name, lines=260)) if status != "missing" and not api_ready else ""
    startup_status = startup_status_for(name, status, api_ready)
    runtime_status = runtime_status_for(name, api_ready)
    model_size = model_size_for(item)
    return {
        "status": status,
        "api_status": "ready" if api_ready else "not_ready",
        "api_ready": api_ready,
        "api_url": api_url if api_ready else "",
        "api_models_url": f"{api_url}/models" if api_ready else "",
        "diagnostic": diagnostic,
        "startup_status": startup_status,
        "runtime_status": runtime_status,
        "runtime_total_seconds": runtime_status["total_seconds"],
        "runtime_total_text": runtime_status["text"],
        "download_progress": progress,
        "model_size_bytes": model_size,
        "model_size_label": human_size(model_size) if model_size else "",
        "config_current": status != "missing" and container_runtime_current(name, item),
        "url": api_url,
    }


def tail_logs(name, lines=160):
    if not docker_available():
        return ""
    if not container_exists(name):
        return ""
    proc = run(["docker", "logs", name, "--tail", str(lines)])
    return (proc.stdout or "") + (proc.stderr or "")


def container_status():
    cfg_items = list_configured()
    containers = []
    for item in cfg_items:
        merged = dict(item)
        merged.pop("hf_token", None)
        merged["hf_token_set"] = bool(item.get("hf_token"))
        merged.update(docker_status_for(item))
        containers.append(merged)
    containers.sort(key=lambda c: (int(c.get("port", 0)), c.get("name", "")))
    return {
        "containers": containers,
        "ports_in_use": sorted(host_ports_in_use()),
    }


def overview_status():
    return {
        "runner_version": RUNNER_VERSION,
        "docker": docker_available(),
        "nvidia_smi": nvidia_smi_ok(),
        "nvidia_container_toolkit": nvidia_container_toolkit_ok(),
        "docker_nvidia_runtime": docker_nvidia_runtime_ok(),
        "ip": local_ip(),
        "web_port": PORT,
    }


def jobs_status():
    with jobs_lock:
        job_values = list(jobs.values())[-20:]
    return {"jobs": job_values}


def system_status():
    containers = container_status()
    overview = overview_status()
    jobs_data = jobs_status()
    return {
        **overview,
        "ports_in_use": containers["ports_in_use"],
        "system": system_metrics(),
        "containers": containers["containers"],
        "jobs": jobs_data["jobs"],
    }


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def send_json(self, data, code=200):
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/status":
            self.send_json(system_status())
            return
        if parsed.path == "/api/overview":
            self.send_json(overview_status())
            return
        if parsed.path == "/api/system":
            self.send_json({"system": system_metrics()})
            return
        if parsed.path == "/api/containers":
            self.send_json(container_status())
            return
        if parsed.path == "/api/ui-settings":
            self.send_json({"settings": load_ui_settings()})
            return
        if parsed.path == "/api/jobs":
            self.send_json(jobs_status())
            return
        if parsed.path.startswith("/api/containers/") and parsed.path.endswith("/logs"):
            name = parsed.path.split("/")[3]
            self.send_json({"name": name, "logs": tail_logs(name)})
            return
        if parsed.path.startswith("/api/jobs/"):
            job_id = parsed.path.rsplit("/", 1)[-1]
            with jobs_lock:
                job = jobs.get(job_id)
            self.send_json(job or {"error": "job not found"}, 200 if job else 404)
            return
        return super().do_GET()

    def do_POST(self):
        try:
            parsed = urlparse(self.path)
            if parsed.path == "/api/containers":
                data = self.read_json()
                old_name = data.get("old_name") or data.get("name")
                old_item = find_config(old_name) if old_name else None
                item = validate_container(data, old_name=old_name)
                if not item.get("hf_token") and old_item and old_item.get("hf_token"):
                    item["hf_token"] = old_item["hf_token"]
                rename_cache_dir(old_name, item["name"])
                rename_startup_stats(old_name, item["name"])
                removed_cache = cleanup_stale_hf_cache(item)
                upsert_config(item)
                self.send_json({
                    "ok": True,
                    "container": {k: v for k, v in item.items() if k != "hf_token"},
                    "removed_cache": removed_cache,
                })
                return
            if parsed.path == "/api/nvidia/repair":
                job_id = start_background("repair nvidia docker", job_repair_nvidia)
                self.send_json({"ok": True, "job_id": job_id})
                return
            if parsed.path == "/api/ui-settings":
                settings = save_ui_settings(self.read_json())
                self.send_json({"ok": True, "settings": settings})
                return
            if parsed.path.startswith("/api/containers/"):
                parts = parsed.path.strip("/").split("/")
                name = parts[2]
                action = parts[3] if len(parts) > 3 else ""
                if action == "runtime":
                    data = self.read_json()
                    seconds = int(data.get("seconds", 0) or 0)
                    self.send_json({"ok": True, "runtime_status": set_runtime_seconds(name, seconds)})
                    return
                if action == "start":
                    job_id = start_background(f"start {name}", job_start_container, name)
                    self.send_json({"ok": True, "job_id": job_id})
                    return
                if action == "stop":
                    job_id = start_background(f"stop {name}", job_stop_container, name)
                    self.send_json({"ok": True, "job_id": job_id})
                    return
                if action == "unload":
                    job_id = start_background(f"unload {name}", job_unload_container, name)
                    self.send_json({"ok": True, "job_id": job_id})
                    return
                if action == "clear-cache":
                    job_id = start_background(f"clear cache {name}", job_clear_model_cache, name)
                    self.send_json({"ok": True, "job_id": job_id})
                    return
            self.send_json({"error": "not found"}, 404)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 400)

    def do_DELETE(self):
        try:
            parsed = urlparse(self.path)
            if parsed.path.startswith("/api/containers/"):
                name = parsed.path.rsplit("/", 1)[-1]
                remove_cache = parse_qs(parsed.query).get("remove_cache", ["0"])[0] == "1"
                job_id = start_background(f"remove {name}", job_remove_container, name, remove_cache)
                self.send_json({"ok": True, "job_id": job_id})
                return
            self.send_json({"error": "not found"}, 404)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 400)


def main():
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    HF_CACHE_BASE.mkdir(parents=True, exist_ok=True)
    STATIC_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"vLLM WebGUI listening on http://{HOST}:{PORT}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
