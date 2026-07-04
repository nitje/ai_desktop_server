#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH="${ROOT_PATH}:${PATH:-}"

DEFAULT_APP_NAME="ai_desktop_server"
APP_NAME="${APP_NAME:-${DEFAULT_APP_NAME}}"
AI_BASE_DIR="${AI_BASE_DIR:-/opt/${APP_NAME}}"

VLLM_BASE_DIR="${VLLM_BASE_DIR:-${AI_BASE_DIR}/vllm}"
VLLM_ENV_FILE="${VLLM_ENV_FILE:-${VLLM_BASE_DIR}/vllm.env}"
VLLM_RUN_SCRIPT="${VLLM_RUN_SCRIPT:-${VLLM_BASE_DIR}/run-vllm-container.sh}"
VLLM_SOURCE_DIR="${VLLM_SOURCE_DIR:-${VLLM_BASE_DIR}/source}"
VLLM_SERVICE="${VLLM_SERVICE:-/etc/systemd/system/vllm-openai.service}"
VLLM_CONTAINER_NAME="${VLLM_CONTAINER_NAME:-ai-vllm-openai}"
VLLM_HF_CACHE_DIR="${VLLM_HF_CACHE_DIR:-${VLLM_BASE_DIR}/huggingface-cache}"

VLLM_DEFAULT_PORT="${VLLM_DEFAULT_PORT:-8000}"
VLLM_DEFAULT_MODEL="${VLLM_DEFAULT_MODEL:-Qwen/Qwen3-0.6B}"
VLLM_DEFAULT_PROFILE="${VLLM_DEFAULT_PROFILE:-nvidia}"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
  TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
else
  SUDO="sudo"
  TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
fi

if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  TARGET_USER="$(logname 2>/dev/null || true)"
fi

if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  read -r -p "Welcher normale Linux-Benutzer soll vLLM verwenden? " TARGET_USER
fi

if ! id "${TARGET_USER}" >/dev/null 2>&1; then
  echo "Benutzer '${TARGET_USER}' existiert nicht."
  exit 1
fi

TARGET_UID="$(id -u "${TARGET_USER}")"
TARGET_GID="$(id -g "${TARGET_USER}")"
TARGET_GROUP="$(id -gn "${TARGET_USER}")"
USER_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

need_sudo() {
  if [[ -n "${SUDO}" ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "sudo ist nicht installiert."
      echo "Starte das Skript bitte als root:"
      echo "  su -"
      echo "  cd /pfad/zum/script"
      echo "  TARGET_USER=${TARGET_USER} bash ./ai_desktop_server_vllm.sh"
      exit 1
    fi

    if ! sudo -v; then
      echo
      echo "Dein Benutzer '$(id -un)' darf sudo nicht verwenden."
      echo "Starte das Skript bitte als root:"
      echo "  su -"
      echo "  cd /pfad/zum/script"
      echo "  TARGET_USER=${TARGET_USER} bash ./ai_desktop_server_vllm.sh"
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

run_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo -u "${TARGET_USER}" -H env HOME="${USER_HOME}" USER="${TARGET_USER}" LOGNAME="${TARGET_USER}" "$@"
    elif command -v runuser >/dev/null 2>&1; then
      runuser -u "${TARGET_USER}" -- env HOME="${USER_HOME}" USER="${TARGET_USER}" LOGNAME="${TARGET_USER}" "$@"
    else
      echo "Weder sudo noch runuser gefunden. Kann nicht zu '${TARGET_USER}' wechseln."
      return 1
    fi
  else
    env HOME="${USER_HOME}" USER="${TARGET_USER}" LOGNAME="${TARGET_USER}" "$@"
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

apt_install() {
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

service_exists() {
  [[ -f "$1" ]]
}

primary_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

docker_compose_ok() {
  docker compose version >/dev/null 2>&1
}

docker_image_exists() {
  local image="$1"
  [[ -n "${image}" ]] && command_ok docker && docker image inspect "${image}" >/dev/null 2>&1
}

docker_container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "${VLLM_CONTAINER_NAME}"
}

docker_container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "${VLLM_CONTAINER_NAME}"
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

normalize_vllm_profile() {
  local raw="$1"
  local last

  raw="${raw//$'\r'/}"
  last="$(printf '%s\n' "${raw}" | awk 'NF{line=$0} END{print line}')"

  case "${last}" in
    nvidia|rocm|xpu|cpu|apple) echo "${last}" ;;
    *) echo "${VLLM_DEFAULT_PROFILE}" ;;
  esac
}

load_existing_config() {
  if [[ -r "${VLLM_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${VLLM_ENV_FILE}"
  fi

  VLLM_PROFILE="${VLLM_PROFILE:-${VLLM_DEFAULT_PROFILE}}"
  VLLM_PROFILE="$(normalize_vllm_profile "${VLLM_PROFILE}")"
  VLLM_IMAGE="${VLLM_IMAGE:-}"
  VLLM_MODEL="${VLLM_MODEL:-${VLLM_DEFAULT_MODEL}}"
  VLLM_PORT="${VLLM_PORT:-${VLLM_DEFAULT_PORT}}"
  VLLM_BIND_HOST="${VLLM_BIND_HOST:-0.0.0.0}"
  VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"
  VLLM_DOCKER_EXTRA_ARGS="${VLLM_DOCKER_EXTRA_ARGS:-}"
  VLLM_CPU_KVCACHE_SPACE="${VLLM_CPU_KVCACHE_SPACE:-4}"
  VLLM_CPU_OMP_THREADS_BIND="${VLLM_CPU_OMP_THREADS_BIND:-}"
  VLLM_SHM_SIZE="${VLLM_SHM_SIZE:-4g}"
  VLLM_ENABLE_CUDA_COMPATIBILITY="${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}"
  HF_TOKEN="${HF_TOKEN:-}"
}

default_image_for_profile() {
  local profile="$1"
  case "${profile}" in
    nvidia) echo "vllm/vllm-openai:latest" ;;
    rocm) echo "vllm/vllm-openai-rocm:latest" ;;
    xpu) echo "vllm/vllm-openai-xpu:latest" ;;
    cpu)
      case "$(uname -m)" in
        x86_64|amd64) echo "vllm/vllm-openai-cpu:latest-x86_64" ;;
        aarch64|arm64) echo "vllm/vllm-openai-cpu:latest-arm64" ;;
        *) echo "vllm/vllm-openai-cpu:latest-x86_64" ;;
      esac
      ;;
    apple) echo "" ;;
    *) echo "vllm/vllm-openai:latest" ;;
  esac
}

profile_label() {
  local profile="$1"
  case "${profile}" in
    nvidia) echo "NVIDIA CUDA Docker" ;;
    rocm) echo "AMD ROCm Docker" ;;
    xpu) echo "Intel XPU Docker" ;;
    cpu) echo "CPU Docker" ;;
    apple) echo "Apple Silicon Hinweis" ;;
    *) echo "${profile}" ;;
  esac
}

print_urls() {
  local ip
  ip="$(primary_lan_ip)"
  echo "vLLM lokal:    http://127.0.0.1:${VLLM_PORT}/v1/models"
  echo "vLLM Netzwerk: http://${ip:-127.0.0.1}:${VLLM_PORT}/v1/models"
  echo "OpenAI Base URL fuer VS Code/andere Hosts: http://${ip:-127.0.0.1}:${VLLM_PORT}/v1"
}

wait_for_vllm() {
  local url="http://127.0.0.1:${VLLM_PORT}/v1/models"
  local i

  echo "Warte darauf, dass vLLM lokal auf ${url} erreichbar ist..."
  echo "Der erste Start kann wegen Modell-Download, torch.compile, CUDA Graph Capture und Autotuning mehrere Minuten dauern."
  for i in $(seq 1 600); do
    if command_ok curl && curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    if (( i % 30 == 0 )); then
      echo "vLLM startet noch... ${i}/600 Sekunden"
      run_root docker logs "${VLLM_CONTAINER_NAME}" --tail 8 2>/dev/null || true
    fi
    if docker_container_running; then
      sleep 1
      continue
    fi
    sleep 1
  done

  return 1
}

scan_status() {
  load_existing_config
  section "Vorhandene Anwendungen / vLLM Status"
  printf "%-28s %s\n" "Docker" "$(command_ok docker && echo installiert || echo fehlt)"
  printf "%-28s %s\n" "Docker Compose" "$(command_ok docker && docker_compose_ok && echo installiert || echo fehlt)"
  printf "%-28s %s\n" "NVIDIA SMI" "$(nvidia_smi_ok && echo aktiv || echo fehlt)"
  printf "%-28s %s\n" "NVIDIA Container Toolkit" "$(nvidia_container_toolkit_ok && echo installiert || echo fehlt)"
  printf "%-28s %s\n" "Docker NVIDIA Runtime" "$(docker_nvidia_runtime_ok && echo aktiv || echo fehlt)"
  printf "%-28s %s\n" "vLLM Service" "$(service_exists "${VLLM_SERVICE}" && systemctl is-enabled vllm-openai.service 2>/dev/null || echo fehlt)"
  printf "%-28s %s\n" "vLLM Container" "$(docker_container_running && echo running || (docker_container_exists && echo stopped || echo fehlt))"
  printf "%-28s %s\n" "vLLM Config" "$([[ -f "${VLLM_ENV_FILE}" ]] && echo vorhanden || echo fehlt)"
  printf "%-28s %s\n" "vLLM Image" "$(docker_image_exists "${VLLM_IMAGE:-}" && echo vorhanden || echo fehlt)"
  echo
  echo "Zielbenutzer: ${TARGET_USER}"
  echo "UID/GID:      ${TARGET_UID}:${TARGET_GID} (${TARGET_GROUP})"
  echo "Basis:        ${VLLM_BASE_DIR}"
  echo "Config:       ${VLLM_ENV_FILE}"
  echo "Runner:       ${VLLM_RUN_SCRIPT}"
  echo "HF Cache:     ${VLLM_HF_CACHE_DIR}"
  echo "Profil:       $(profile_label "${VLLM_PROFILE}")"
  echo "Image:        ${VLLM_IMAGE:-$(default_image_for_profile "${VLLM_PROFILE}")}"
  echo "Model:        ${VLLM_MODEL}"
  echo "Port:         ${VLLM_PORT}"
  echo "HF_TOKEN:     $([[ -n "${HF_TOKEN}" ]] && echo gesetzt || echo leer)"
}

choose_action() {
  load_existing_config
  local installed="no"
  if [[ -f "${VLLM_ENV_FILE}" || -f "${VLLM_SERVICE}" || "$(docker_container_exists && echo yes || echo no)" == "yes" ]]; then
    installed="yes"
  fi

  section "Installation / Reparieren / Deinstallieren"
  if [[ "${installed}" == "yes" ]]; then
    echo "Optionen: [s] ueberspringen, [r] reparieren/aktualisieren, [u] deinstallieren"
    while true; do
      read -r -p "Auswahl fuer vLLM: " ACTION
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
      read -r -p "Auswahl fuer vLLM: " ACTION
      case "${ACTION,,}" in
        i|install|installieren) ACTION="install"; return 0 ;;
        ""|s|skip) ACTION="skip"; return 0 ;;
        *) echo "Bitte i oder s eingeben." ;;
      esac
    done
  fi
}

choose_profile() {
  local choice
  echo >&2
  echo "vLLM Docker-Profil:" >&2
  echo "1) NVIDIA CUDA (offizielles Image vllm/vllm-openai)" >&2
  echo "2) AMD ROCm (offizielles Image vllm/vllm-openai-rocm)" >&2
  echo "3) Intel XPU (Image editierbar, je nach Release)" >&2
  echo "4) CPU (offizielles CPU-Image)" >&2
  echo "5) Apple Silicon Hinweis (auf Debian nicht installierbar)" >&2
  read -r -p "Auswahl [1]: " choice >&2
  choice="${choice:-1}"

  case "${choice}" in
    2) echo "rocm" ;;
    3) echo "xpu" ;;
    4) echo "cpu" ;;
    5) echo "apple" ;;
    *) echo "nvidia" ;;
  esac
}

prompt_value() {
  local label="$1"
  local current="$2"
  local answer
  read -r -p "${label} [${current}]: " answer
  echo "${answer:-${current}}"
}

prompt_secret() {
  local current="$1"
  local answer
  if [[ -n "${current}" ]]; then
    read -r -s -p "HF_TOKEN neu eingeben? Leer = vorhandenen behalten: " answer
  else
    read -r -s -p "HF_TOKEN eingeben (leer = ohne Token): " answer
  fi
  echo >&2
  echo "${answer:-${current}}"
}

shell_quote() {
  printf '%q' "$1"
}

write_env_file() {
  run_root install -d -m 0755 "${VLLM_BASE_DIR}" "${VLLM_HF_CACHE_DIR}"
  run_root chown -R "${TARGET_USER}:${TARGET_GROUP}" "${VLLM_HF_CACHE_DIR}"

  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
VLLM_PROFILE=$(shell_quote "${VLLM_PROFILE}")
VLLM_IMAGE=$(shell_quote "${VLLM_IMAGE}")
VLLM_MODEL=$(shell_quote "${VLLM_MODEL}")
VLLM_PORT=$(shell_quote "${VLLM_PORT}")
VLLM_BIND_HOST=$(shell_quote "${VLLM_BIND_HOST}")
VLLM_EXTRA_ARGS=$(shell_quote "${VLLM_EXTRA_ARGS}")
VLLM_DOCKER_EXTRA_ARGS=$(shell_quote "${VLLM_DOCKER_EXTRA_ARGS}")
VLLM_HF_CACHE_DIR=$(shell_quote "${VLLM_HF_CACHE_DIR}")
VLLM_CONTAINER_NAME=$(shell_quote "${VLLM_CONTAINER_NAME}")
VLLM_CPU_KVCACHE_SPACE=$(shell_quote "${VLLM_CPU_KVCACHE_SPACE}")
VLLM_CPU_OMP_THREADS_BIND=$(shell_quote "${VLLM_CPU_OMP_THREADS_BIND}")
VLLM_SHM_SIZE=$(shell_quote "${VLLM_SHM_SIZE}")
VLLM_ENABLE_CUDA_COMPATIBILITY=$(shell_quote "${VLLM_ENABLE_CUDA_COMPATIBILITY}")
HF_TOKEN=$(shell_quote "${HF_TOKEN}")
EOF
  run_root install -m 0600 "${tmp}" "${VLLM_ENV_FILE}"
  rm -f "${tmp}"
}

configure_vllm() {
  section "vLLM konfigurieren"
  load_existing_config

  local old_profile
  old_profile="${VLLM_PROFILE}"
  VLLM_PROFILE="$(choose_profile)"
  if [[ "${VLLM_PROFILE}" == "apple" ]]; then
    echo "Apple Silicon wird von diesem Debian/Docker-Zusatzskript nicht installiert."
    echo "Die vLLM-Doku beschreibt Apple Silicon als experimentell und source-build-basiert auf macOS."
    return 1
  fi

  if [[ -z "${VLLM_IMAGE}" || "${VLLM_PROFILE}" != "${old_profile}" ]]; then
    VLLM_IMAGE="$(default_image_for_profile "${VLLM_PROFILE}")"
  fi
  VLLM_IMAGE="$(prompt_value "Docker Image" "${VLLM_IMAGE}")"
  VLLM_MODEL="$(prompt_value "Hugging Face Model" "${VLLM_MODEL}")"
  VLLM_PORT="$(prompt_value "Host-Port fuer vLLM/OpenAI API" "${VLLM_PORT}")"
  VLLM_BIND_HOST="$(prompt_value "Bind Host fuer Docker-Portmapping" "${VLLM_BIND_HOST}")"
  HF_TOKEN="$(prompt_secret "${HF_TOKEN}")"

  if [[ "${VLLM_PROFILE}" == "cpu" ]]; then
    VLLM_CPU_KVCACHE_SPACE="$(prompt_value "CPU KV Cache Space in GB" "${VLLM_CPU_KVCACHE_SPACE}")"
    VLLM_SHM_SIZE="$(prompt_value "Docker shm-size" "${VLLM_SHM_SIZE}")"
    VLLM_CPU_OMP_THREADS_BIND="$(prompt_value "CPU Threads Bind (leer = automatisch)" "${VLLM_CPU_OMP_THREADS_BIND}")"
  fi

  if [[ "${VLLM_PROFILE}" == "nvidia" ]]; then
    if ask_yes_no "CUDA Compatibility Libraries aktivieren? (fuer aeltere NVIDIA-Treiber)" "n"; then
      VLLM_ENABLE_CUDA_COMPATIBILITY="1"
    else
      VLLM_ENABLE_CUDA_COMPATIBILITY="0"
    fi
  fi

  VLLM_EXTRA_ARGS="$(prompt_value "Weitere vLLM Server-Argumente" "${VLLM_EXTRA_ARGS}")"
  VLLM_DOCKER_EXTRA_ARGS="$(prompt_value "Weitere docker run Argumente" "${VLLM_DOCKER_EXTRA_ARGS}")"
  write_env_file
}

create_runner() {
  run_root install -d -m 0755 "${VLLM_BASE_DIR}"
  run_root tee "${VLLM_RUN_SCRIPT}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${VLLM_ENV_FILE:-__ENV_FILE__}"
if [[ ! -r "${ENV_FILE}" ]]; then
  echo "vLLM Env-Datei fehlt: ${ENV_FILE}"
  exit 1
fi

# shellcheck disable=SC1090
. "${ENV_FILE}"

VLLM_CONTAINER_NAME="${VLLM_CONTAINER_NAME:-ai-vllm-openai}"
VLLM_BIND_HOST="${VLLM_BIND_HOST:-0.0.0.0}"
VLLM_PORT="${VLLM_PORT:-8000}"
VLLM_HF_CACHE_DIR="${VLLM_HF_CACHE_DIR:-/opt/ai_desktop_server/vllm/huggingface-cache}"
VLLM_SHM_SIZE="${VLLM_SHM_SIZE:-4g}"
VLLM_PROFILE="$(printf '%s\n' "${VLLM_PROFILE:-nvidia}" | awk 'NF{line=$0} END{print line}')"
case "${VLLM_PROFILE}" in
  nvidia|rocm|xpu|cpu|apple) ;;
  *) VLLM_PROFILE="nvidia" ;;
esac

docker rm -f "${VLLM_CONTAINER_NAME}" >/dev/null 2>&1 || true

run_args=(
  run
  --rm
  --name "${VLLM_CONTAINER_NAME}"
  -p "${VLLM_BIND_HOST}:${VLLM_PORT}:8000"
  --ipc=host
  -v "${VLLM_HF_CACHE_DIR}:/root/.cache/huggingface"
  --env "HF_TOKEN=${HF_TOKEN:-}"
)

case "${VLLM_PROFILE}" in
  nvidia)
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
      run_args+=(--runtime nvidia)
    fi
    run_args+=(--gpus all)
    if [[ "${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}" == "1" ]]; then
      run_args+=(--env "VLLM_ENABLE_CUDA_COMPATIBILITY=1")
    fi
    ;;
  rocm)
    run_args+=(--group-add=video --cap-add=SYS_PTRACE --security-opt seccomp=unconfined --device /dev/kfd --device /dev/dri)
    ;;
  xpu)
    run_args+=(--device /dev/dri --group-add=render)
    ;;
  cpu)
    run_args+=(--security-opt seccomp=unconfined --cap-add SYS_NICE --shm-size="${VLLM_SHM_SIZE}")
    run_args+=(--env "VLLM_CPU_KVCACHE_SPACE=${VLLM_CPU_KVCACHE_SPACE:-4}")
    if [[ -n "${VLLM_CPU_OMP_THREADS_BIND:-}" ]]; then
      run_args+=(--env "VLLM_CPU_OMP_THREADS_BIND=${VLLM_CPU_OMP_THREADS_BIND}")
    fi
    ;;
  *)
    echo "Unbekanntes vLLM Profil: ${VLLM_PROFILE}"
    exit 1
    ;;
esac

if [[ -n "${VLLM_DOCKER_EXTRA_ARGS:-}" ]]; then
  # Admin-Konfiguration: einfache Shell-Splitting-Unterstuetzung fuer zusaetzliche Docker-Argumente.
  # shellcheck disable=SC2206
  extra_docker_args=(${VLLM_DOCKER_EXTRA_ARGS})
  run_args+=("${extra_docker_args[@]}")
fi

cmd_args=("${VLLM_MODEL}")
if [[ -n "${VLLM_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_vllm_args=(${VLLM_EXTRA_ARGS})
  cmd_args+=("${extra_vllm_args[@]}")
fi

exec docker "${run_args[@]}" "${VLLM_IMAGE}" "${cmd_args[@]}"
EOF
  run_root sed -i "s#__ENV_FILE__#${VLLM_ENV_FILE}#g" "${VLLM_RUN_SCRIPT}"
  run_root chmod 0755 "${VLLM_RUN_SCRIPT}"
}

create_service() {
  run_root tee "${VLLM_SERVICE}" >/dev/null <<EOF
[Unit]
Description=vLLM OpenAI-compatible Server
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Environment="VLLM_ENV_FILE=${VLLM_ENV_FILE}"
ExecStart=${VLLM_RUN_SCRIPT}
ExecStop=-/usr/bin/docker stop ${VLLM_CONTAINER_NAME}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  run_root systemctl daemon-reload
}

ensure_docker_ready() {
  if ! command_ok docker; then
    echo "Docker fehlt. Bitte zuerst Docker mit ai_desktop_server.sh installieren."
    return 1
  fi

  if ! systemctl is-active docker >/dev/null 2>&1; then
    run_root systemctl enable --now docker
  fi
}

configure_nvidia_container_toolkit() {
  section "NVIDIA Container Toolkit fuer Docker pruefen/reparieren"

  if ! nvidia_smi_ok; then
    echo "nvidia-smi funktioniert auf dem Host nicht. Erst NVIDIA-Treiber reparieren."
    return 1
  fi

  if ! nvidia_container_toolkit_ok; then
    echo "Installiere NVIDIA Container Toolkit Repository und Paket."
    apt_install ca-certificates curl gnupg2

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
    apt_install nvidia-container-toolkit
  else
    echo "NVIDIA Container Toolkit ist installiert."
  fi

  echo "Konfiguriere Docker fuer NVIDIA Runtime."
  run_root nvidia-ctk runtime configure --runtime=docker

  if command_ok systemctl; then
    run_root systemctl restart docker
  else
    echo "systemctl nicht gefunden. Docker bitte manuell neu starten."
  fi

  echo "Erzeuge/aktualisiere NVIDIA CDI-Spec fuer Docker."
  if systemctl list-unit-files nvidia-cdi-refresh.service >/dev/null 2>&1; then
    run_root systemctl enable --now nvidia-cdi-refresh.path 2>/dev/null || true
    run_root systemctl restart nvidia-cdi-refresh.service || true
  fi

  run_root install -d -m 0755 /var/run/cdi
  run_root nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml || true

  if docker_nvidia_runtime_ok; then
    echo "Docker NVIDIA Runtime ist aktiv."
  else
    echo "Docker zeigt die NVIDIA Runtime noch nicht an. Pruefe /etc/docker/daemon.json und Docker-Neustart."
  fi
}

pull_image_if_needed() {
  if ask_yes_no "Docker Image jetzt pullen/aktualisieren?" "y"; then
    run_root docker pull "${VLLM_IMAGE}"
  fi
}

install_or_repair_vllm() {
  ensure_docker_ready || return 1
  configure_vllm || return 1
  if [[ "${VLLM_PROFILE}" == "nvidia" ]]; then
    configure_nvidia_container_toolkit || return 1
  fi
  create_runner
  create_service

  if ask_yes_no "vLLM Image aus Source bauen statt pullen?" "n"; then
    build_vllm_image_from_source
  else
    pull_image_if_needed
  fi

  if ask_yes_no "vLLM als systemd-Service aktivieren und starten?" "y"; then
    run_root systemctl enable vllm-openai.service
    run_root systemctl reset-failed vllm-openai.service 2>/dev/null || true
    run_root systemctl restart vllm-openai.service
    if wait_for_vllm; then
      run_root systemctl status vllm-openai.service --no-pager || true
      print_urls
    else
      if docker_container_running; then
        echo "vLLM Container laeuft noch, aber /v1/models antwortet nach 600 Sekunden noch nicht."
        echo "Das kann bei sehr grossen Modellen, langsamerem Download oder erstem Compile-Lauf passieren."
      else
        echo "vLLM wurde gestartet, ist aber nicht erreichbar oder beendet sich wieder."
      fi
      echo "systemd-Status:"
      run_root systemctl status vllm-openai.service --no-pager || true
      echo
      echo "journalctl:"
      run_root journalctl -u vllm-openai.service -n 120 --no-pager || true
      echo
      echo "Docker-Logs:"
      run_root docker logs "${VLLM_CONTAINER_NAME}" --tail 120 2>/dev/null || true
    fi
  else
    echo "Manueller Start:"
    echo "  ${VLLM_RUN_SCRIPT}"
  fi
}

build_vllm_image_from_source() {
  section "vLLM Docker Image aus Source bauen"
  ensure_docker_ready || return 1
  if ! command_ok git; then
    apt_install git ca-certificates
  fi

  local repo_url branch dockerfile target tag build_args
  repo_url="$(prompt_value "vLLM Git Repository" "https://github.com/vllm-project/vllm.git")"
  branch="$(prompt_value "Git Branch/Tag" "main")"

  case "${VLLM_PROFILE}" in
    cpu) dockerfile="docker/Dockerfile.cpu" ;;
    rocm) dockerfile="docker/Dockerfile.rocm" ;;
    *) dockerfile="docker/Dockerfile" ;;
  esac

  dockerfile="$(prompt_value "Dockerfile im Source-Repo" "${dockerfile}")"
  target="$(prompt_value "Docker Build Target" "vllm-openai")"
  tag="$(prompt_value "Lokaler Image-Tag" "${VLLM_IMAGE}")"
  build_args="$(prompt_value "Weitere docker build Argumente" "")"

  run_root install -d -m 0755 "${VLLM_SOURCE_DIR}"
  if [[ -d "${VLLM_SOURCE_DIR}/.git" ]]; then
    run_root git -C "${VLLM_SOURCE_DIR}" fetch --all --tags
    run_root git -C "${VLLM_SOURCE_DIR}" checkout "${branch}"
    run_root git -C "${VLLM_SOURCE_DIR}" pull --ff-only || true
  elif [[ -e "${VLLM_SOURCE_DIR}" && -n "$(ls -A "${VLLM_SOURCE_DIR}" 2>/dev/null)" ]]; then
    echo "${VLLM_SOURCE_DIR} existiert und ist nicht leer."
    return 1
  else
    run_root git clone --branch "${branch}" "${repo_url}" "${VLLM_SOURCE_DIR}"
  fi

  echo "Baue Docker Image. Das kann lange dauern."
  # shellcheck disable=SC2086
  run_root env DOCKER_BUILDKIT=1 docker build "${VLLM_SOURCE_DIR}" \
    --file "${VLLM_SOURCE_DIR}/${dockerfile}" \
    --target "${target}" \
    --tag "${tag}" \
    ${build_args}

  VLLM_IMAGE="${tag}"
  write_env_file
}

uninstall_vllm() {
  section "vLLM deinstallieren"
  run_root systemctl disable --now vllm-openai.service 2>/dev/null || true
  run_root docker rm -f "${VLLM_CONTAINER_NAME}" 2>/dev/null || true
  run_root rm -f "${VLLM_SERVICE}"
  run_root systemctl daemon-reload

  load_existing_config
  if [[ -n "${VLLM_IMAGE:-}" ]] && ask_yes_no "Docker Image '${VLLM_IMAGE}' entfernen?" "n"; then
    run_root docker rmi "${VLLM_IMAGE}" || true
  fi

  if ask_yes_no "vLLM Dateien unter '${VLLM_BASE_DIR}' loeschen? (Config/HF-Cache/Source)" "n"; then
    if [[ -n "${VLLM_BASE_DIR}" && "${VLLM_BASE_DIR}" == /opt/* && "${VLLM_BASE_DIR}" != "/opt" ]]; then
      run_root rm -rf --one-file-system "${VLLM_BASE_DIR}"
    else
      echo "Unsicherer Pfad, loesche nicht: ${VLLM_BASE_DIR}"
    fi
  fi
}

builder_prune() {
  section "Docker Builder Cache bereinigen"
  ensure_docker_ready || return 1
  if ask_yes_no "docker builder prune -f jetzt ausfuehren?" "n"; then
    run_root docker builder prune -f
  fi
}

main() {
  need_sudo
  load_existing_config
  scan_status
  choose_action

  case "${ACTION}" in
    install|repair) install_or_repair_vllm ;;
    uninstall) uninstall_vllm ;;
    skip) echo "vLLM: uebersprungen." ;;
  esac

  if ask_yes_no "Docker Builder Cache bereinigen? (docker builder prune -f)" "n"; then
    builder_prune
  fi

  section "Fertig"
  scan_status
  echo "Start: chmod +x ./ai_desktop_server_vllm.sh && ./ai_desktop_server_vllm.sh"
}

main "$@"
