#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH="${ROOT_PATH}:${PATH:-}"

DEFAULT_APP_NAME="ai_desktop_server"
APP_NAME="${APP_NAME:-${DEFAULT_APP_NAME}}"
AI_BASE_DIR="${AI_BASE_DIR:-/opt/${APP_NAME}}"
WEBGUI_SOURCE_DIR="${WEBGUI_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vllm_webgui}"
WEBGUI_BASE_DIR="${VLLM_WEBGUI_BASE_DIR:-${AI_BASE_DIR}/vllm_webgui}"
WEBGUI_STATIC_DIR="${WEBGUI_STATIC_DIR:-${WEBGUI_BASE_DIR}/static}"
WEBGUI_CONFIG="${WEBGUI_CONFIG:-${WEBGUI_BASE_DIR}/containers.json}"
WEBGUI_HF_CACHE_DIR="${WEBGUI_HF_CACHE_DIR:-${WEBGUI_BASE_DIR}/huggingface-cache}"
WEBGUI_SERVICE="${WEBGUI_SERVICE:-/etc/systemd/system/vllm-webgui.service}"
WEBGUI_PORT="${VLLM_WEBGUI_PORT:-17000}"
WEBGUI_HOST="${VLLM_WEBGUI_HOST:-0.0.0.0}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

need_sudo() {
  if [[ -n "${SUDO}" ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "sudo ist nicht installiert. Bitte als root starten:"
      echo "  su -"
      echo "  cd /pfad/zum/script"
      echo "  bash ./ai_desktop_server_vllm_webgui.sh"
      exit 1
    fi
    if ! sudo -v; then
      echo "Keine sudo-Rechte. Bitte als root starten."
      exit 1
    fi
  fi
}

run_root() {
  need_sudo
  if [[ -n "${SUDO}" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  local answer
  if [[ "${default}" == "y" ]]; then
    suffix="[Y/n]"
  fi
  while true; do
    read -r -p "${prompt} ${suffix} " answer
    answer="${answer:-${default}}"
    case "${answer,,}" in
      y|yes|j|ja) return 0 ;;
      n|no|nein) return 1 ;;
      *) echo "Bitte mit y/n antworten." ;;
    esac
  done
}

command_ok() {
  command -v "$1" >/dev/null 2>&1
}

nvidia_smi_ok() {
  command_ok nvidia-smi && nvidia-smi >/dev/null 2>&1
}

nvidia_container_toolkit_ok() {
  command_ok nvidia-ctk && dpkg-query -W -f='${Status}' nvidia-container-toolkit 2>/dev/null | grep -q "install ok installed"
}

docker_nvidia_runtime_ok() {
  command_ok docker && docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'
}

service_exists() {
  [[ -f "$1" ]]
}

primary_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

webgui_installed() {
  [[ -f "${WEBGUI_BASE_DIR}/server.py" && -f "${WEBGUI_SERVICE}" ]]
}

scan_status() {
  section "vLLM WebGUI Status"
  printf "%-26s %s\n" "Python3" "$(command_ok python3 && echo installiert || echo fehlt)"
  printf "%-26s %s\n" "Docker" "$(command_ok docker && echo installiert || echo fehlt)"
  printf "%-26s %s\n" "NVIDIA SMI" "$(nvidia_smi_ok && echo aktiv || echo fehlt)"
  printf "%-26s %s\n" "NVIDIA Container Toolkit" "$(nvidia_container_toolkit_ok && echo installiert || echo fehlt)"
  printf "%-26s %s\n" "Docker NVIDIA Runtime" "$(docker_nvidia_runtime_ok && echo aktiv || echo fehlt)"
  printf "%-26s %s\n" "WebGUI Dateien" "$([[ -f "${WEBGUI_BASE_DIR}/server.py" ]] && echo vorhanden || echo fehlt)"
  printf "%-26s %s\n" "WebGUI Service" "$(service_exists "${WEBGUI_SERVICE}" && systemctl is-enabled vllm-webgui.service 2>/dev/null || echo fehlt)"
  echo
  echo "Quelle:       ${WEBGUI_SOURCE_DIR}"
  echo "Ziel:         ${WEBGUI_BASE_DIR}"
  echo "Static:       ${WEBGUI_STATIC_DIR}"
  echo "Config:       ${WEBGUI_CONFIG}"
  echo "HF Cache:     ${WEBGUI_HF_CACHE_DIR}"
  echo "Port:         ${WEBGUI_PORT}"
  echo "URL lokal:    http://127.0.0.1:${WEBGUI_PORT}/"
  echo "URL Netzwerk: http://$(primary_lan_ip):${WEBGUI_PORT}/"
}

choose_action() {
  if webgui_installed; then
    echo "Optionen: [s] ueberspringen, [r] reparieren/aktualisieren, [u] deinstallieren"
    while true; do
      read -r -p "Auswahl fuer vLLM WebGUI: " ACTION
      case "${ACTION,,}" in
        ""|s|skip) ACTION="skip"; return 0 ;;
        r|repair|reparieren) ACTION="repair"; return 0 ;;
        u|uninstall|deinstallieren) ACTION="uninstall"; return 0 ;;
        *) echo "Bitte s, r oder u eingeben." ;;
      esac
    done
  else
    echo "Optionen: [i] installieren, [s] ueberspringen"
    while true; do
      read -r -p "Auswahl fuer vLLM WebGUI: " ACTION
      case "${ACTION,,}" in
        i|install|installieren) ACTION="install"; return 0 ;;
        ""|s|skip) ACTION="skip"; return 0 ;;
        *) echo "Bitte i oder s eingeben." ;;
      esac
    done
  fi
}

ensure_dependencies() {
  if ! command_ok python3; then
    echo "python3 fehlt. Installiere python3."
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y python3
  fi
  if ! command_ok docker; then
    echo "Docker fehlt. Bitte zuerst Docker mit ai_desktop_server.sh installieren."
    return 1
  fi
}

configure_nvidia_container_toolkit() {
  section "NVIDIA Container Toolkit fuer Docker pruefen/reparieren"

  if ! nvidia_smi_ok; then
    echo "nvidia-smi funktioniert auf dem Host nicht. NVIDIA-Treiber zuerst mit ai_desktop_server.sh reparieren."
    return 1
  fi

  if ! nvidia_container_toolkit_ok; then
    echo "Installiere NVIDIA Container Toolkit Repository und Paket."
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg2

    local key_tmp list_tmp signed_list_tmp
    key_tmp="$(mktemp)"
    list_tmp="$(mktemp)"
    signed_list_tmp="$(mktemp)"

    run_root curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o "${key_tmp}"
    run_root install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
    run_root gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg "${key_tmp}"

    run_root curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o "${list_tmp}"
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' "${list_tmp}" >"${signed_list_tmp}"
    run_root install -m 0644 "${signed_list_tmp}" /etc/apt/sources.list.d/nvidia-container-toolkit.list

    rm -f "${key_tmp}" "${list_tmp}" "${signed_list_tmp}"
    run_root apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
  else
    echo "NVIDIA Container Toolkit ist installiert."
  fi

  echo "Konfiguriere Docker fuer NVIDIA Runtime."
  run_root nvidia-ctk runtime configure --runtime=docker
  run_root systemctl restart docker

  echo "Erzeuge/aktualisiere NVIDIA CDI-Spec."
  if systemctl list-unit-files nvidia-cdi-refresh.service >/dev/null 2>&1; then
    run_root systemctl enable --now nvidia-cdi-refresh.path 2>/dev/null || true
    run_root systemctl restart nvidia-cdi-refresh.service || true
  fi
  run_root install -d -m 0755 /var/run/cdi
  run_root nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml || true

  if docker_nvidia_runtime_ok; then
    echo "Docker NVIDIA Runtime ist aktiv."
  else
    echo "Docker NVIDIA Runtime ist noch nicht aktiv. Docker/daemon.json pruefen."
  fi
}

install_webgui_files() {
  if [[ ! -d "${WEBGUI_SOURCE_DIR}" ]]; then
    echo "Quellordner fehlt: ${WEBGUI_SOURCE_DIR}"
    return 1
  fi

  run_root install -d -m 0755 "${WEBGUI_BASE_DIR}" "${WEBGUI_STATIC_DIR}" "${WEBGUI_HF_CACHE_DIR}"
  run_root install -m 0755 "${WEBGUI_SOURCE_DIR}/server.py" "${WEBGUI_BASE_DIR}/server.py"
  run_root install -m 0644 "${WEBGUI_SOURCE_DIR}/index.html" "${WEBGUI_STATIC_DIR}/index.html"
  run_root install -m 0644 "${WEBGUI_SOURCE_DIR}/style.css" "${WEBGUI_STATIC_DIR}/style.css"
  run_root install -m 0644 "${WEBGUI_SOURCE_DIR}/app.js" "${WEBGUI_STATIC_DIR}/app.js"
  if [[ ! -f "${WEBGUI_CONFIG}" ]]; then
    local tmp
    tmp="$(mktemp)"
    printf '{\n  "containers": []\n}\n' >"${tmp}"
    run_root install -m 0600 "${tmp}" "${WEBGUI_CONFIG}"
    rm -f "${tmp}"
  fi
}

create_service() {
  run_root tee "${WEBGUI_SERVICE}" >/dev/null <<EOF
[Unit]
Description=vLLM WebGUI
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
Environment="APP_NAME=${APP_NAME}"
Environment="VLLM_WEBGUI_BASE_DIR=${WEBGUI_BASE_DIR}"
Environment="VLLM_WEBGUI_STATIC_DIR=${WEBGUI_STATIC_DIR}"
Environment="VLLM_WEBGUI_CONFIG=${WEBGUI_CONFIG}"
Environment="VLLM_WEBGUI_HF_CACHE_DIR=${WEBGUI_HF_CACHE_DIR}"
Environment="VLLM_WEBGUI_HOST=${WEBGUI_HOST}"
Environment="VLLM_WEBGUI_PORT=${WEBGUI_PORT}"
ExecStart=/usr/bin/python3 ${WEBGUI_BASE_DIR}/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  run_root systemctl daemon-reload
}

install_or_repair() {
  section "vLLM WebGUI installieren/reparieren"
  ensure_dependencies || return 1
  if nvidia_smi_ok; then
    if ! nvidia_container_toolkit_ok || ! docker_nvidia_runtime_ok; then
      if ask_yes_no "NVIDIA Container Toolkit/Docker Runtime fuer vLLM jetzt einrichten?" "y"; then
        configure_nvidia_container_toolkit || true
      fi
    fi
  fi
  install_webgui_files
  create_service

  if ask_yes_no "vLLM WebGUI systemd-Service aktivieren und starten?" "y"; then
    run_root systemctl enable vllm-webgui.service
    run_root systemctl restart vllm-webgui.service
    sleep 2
    run_root systemctl status vllm-webgui.service --no-pager || true
    echo "WebGUI: http://$(primary_lan_ip):${WEBGUI_PORT}/"
  fi
}

webgui_container_names_from_config() {
  if [[ ! -r "${WEBGUI_CONFIG}" ]] || ! command_ok python3; then
    return 0
  fi

  python3 - "${WEBGUI_CONFIG}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    data = {}

seen = set()
for item in data.get("containers", []):
    name = str(item.get("name", "")).strip()
    if name and name not in seen:
        seen.add(name)
        print(name)
PY
}

webgui_container_names_from_docker_labels() {
  if ! command_ok docker; then
    return 0
  fi

  docker ps -a --filter "label=ai.vllm.webgui=1" --format '{{.Names}}' 2>/dev/null || true
}

list_webgui_containers() {
  {
    webgui_container_names_from_config
    webgui_container_names_from_docker_labels
  } | awk 'NF && !seen[$0]++'
}

remove_webgui_containers() {
  local names
  mapfile -t names < <(list_webgui_containers)

  if [[ "${#names[@]}" -eq 0 ]]; then
    echo "Keine von der WebGUI verwalteten Container gefunden."
    return 0
  fi

  echo "Von der WebGUI verwaltete Container:"
  printf '  - %s\n' "${names[@]}"
  echo

  if ask_yes_no "Diese Container stoppen und loeschen?" "y"; then
    run_root docker rm -f "${names[@]}" 2>/dev/null || true
    echo "WebGUI-Container entfernt."
  else
    echo "Container bleiben bestehen."
  fi
}

uninstall_webgui() {
  section "vLLM WebGUI deinstallieren"
  remove_webgui_containers
  run_root systemctl disable --now vllm-webgui.service 2>/dev/null || true
  run_root rm -f "${WEBGUI_SERVICE}"
  run_root systemctl daemon-reload
  if ask_yes_no "WebGUI Dateien unter '${WEBGUI_BASE_DIR}' loeschen? (inkl. Config/HF-Cache)" "n"; then
    if [[ -n "${WEBGUI_BASE_DIR}" && "${WEBGUI_BASE_DIR}" == /opt/* && "${WEBGUI_BASE_DIR}" != "/opt" ]]; then
      run_root rm -rf --one-file-system "${WEBGUI_BASE_DIR}"
    else
      echo "Unsicherer Pfad, loesche nicht: ${WEBGUI_BASE_DIR}"
    fi
  fi
}

main() {
  need_sudo
  scan_status
  section "Installation / Reparieren / Deinstallieren"
  choose_action
  case "${ACTION}" in
    install|repair) install_or_repair ;;
    uninstall) uninstall_webgui ;;
    skip) echo "vLLM WebGUI: uebersprungen." ;;
  esac
  section "Fertig"
  scan_status
  echo "Start: chmod +x ./ai_desktop_server_vllm_webgui.sh && ./ai_desktop_server_vllm_webgui.sh"
}

main "$@"
