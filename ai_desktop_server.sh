#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH="${ROOT_PATH}:${PATH:-}"

EXPECTED_DEBIAN_VERSION="13.5"
EXPECTED_DEBIAN_MAJOR="13"
EXPECTED_ARCH="amd64"

APP_NAME_WAS_SET="${APP_NAME+x}"
AI_BASE_DIR_WAS_SET="${AI_BASE_DIR+x}"
COMFY_DIR_WAS_SET="${COMFY_DIR+x}"
COMFY_VENV_WAS_SET="${COMFY_VENV+x}"
COMFY_CUSTOM_NODES_DIR_WAS_SET="${COMFY_CUSTOM_NODES_DIR+x}"
COMFY_MANAGER_DIR_WAS_SET="${COMFY_MANAGER_DIR+x}"
COMFY_CRYSTOOLS_DIR_WAS_SET="${COMFY_CRYSTOOLS_DIR+x}"
COMFY_HOME_LINK_WAS_SET="${COMFY_HOME_LINK+x}"

DEFAULT_APP_NAME="ai_desktop_server"
APP_NAME="${APP_NAME:-${DEFAULT_APP_NAME}}"
AI_BASE_DIR="${AI_BASE_DIR:-/opt/${APP_NAME}}"
COMFY_DIR="${COMFY_DIR:-${AI_BASE_DIR}/ComfyUI}"
COMFY_VENV="${COMFY_VENV:-${COMFY_DIR}/.venv}"
COMFY_HOST="${COMFY_HOST:-0.0.0.0}"
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_STARTUP_TEST_PORT="${COMFY_STARTUP_TEST_PORT:-18188}"
COMFY_EXTRA_ARGS="${COMFY_EXTRA_ARGS:-}"
COMFY_SERVICE="/etc/systemd/system/comfyui.service"
COMFY_CUSTOM_NODES_DIR="${COMFY_CUSTOM_NODES_DIR:-${COMFY_DIR}/custom_nodes}"
COMFY_MANAGER_DIR="${COMFY_MANAGER_DIR:-${COMFY_CUSTOM_NODES_DIR}/comfyui-manager}"
COMFY_CRYSTOOLS_DIR="${COMFY_CRYSTOOLS_DIR:-${COMFY_CUSTOM_NODES_DIR}/comfyui-crystools}"
NVIDIA_DRIVER_REBOOT_REQUIRED="no"
NVIDIA_RUN_DRIVER_VERSION="${NVIDIA_RUN_DRIVER_VERSION:-595.84}"
NVIDIA_RUN_DRIVER_URL="${NVIDIA_RUN_DRIVER_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_RUN_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_RUN_DRIVER_VERSION}.run}"
NVIDIA_PREFERRED_APT_PACKAGES="${NVIDIA_PREFERRED_APT_PACKAGES:-nvidia-driver-570-server-open nvidia-driver-570-open nvidia-open nvidia-driver-570-server nvidia-driver-570 nvidia-driver-open}"
NVIDIA_DRIVER_DIR="${NVIDIA_DRIVER_DIR:-/opt/nvidia-drivers}"
NVIDIA_RUN_DRIVER_FILE="${NVIDIA_DRIVER_DIR}/NVIDIA-Linux-x86_64-${NVIDIA_RUN_DRIVER_VERSION}.run"
NVIDIA_RUN_INSTALL_SCRIPT="${NVIDIA_DRIVER_DIR}/install-nvidia-runfile.sh"
NVIDIA_RUN_SYSTEMD_SERVICE="/etc/systemd/system/nvidia-runfile-install.service"
NVIDIA_POST_REBOOT_MARKER="${NVIDIA_DRIVER_DIR}/after-reboot-run-comfyui-profile-2"
NVIDIA_AUTO_REBOOT_SECONDS="${NVIDIA_AUTO_REBOOT_SECONDS:-20}"

LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
LMSTUDIO_HOST="${LMSTUDIO_HOST:-0.0.0.0}"
LMSTUDIO_SERVICE="/etc/systemd/system/lmstudio.service"
LMSTUDIO_DESKTOP_DIR="${LMSTUDIO_DESKTOP_DIR:-/opt/lmstudio}"
LMSTUDIO_DESKTOP_APPIMAGE="${LMSTUDIO_DESKTOP_APPIMAGE:-${LMSTUDIO_DESKTOP_DIR}/LM-Studio.AppImage}"
LMSTUDIO_DESKTOP_FILE="/usr/share/applications/lmstudio.desktop"
LMSTUDIO_DESKTOP_URL="${LMSTUDIO_DESKTOP_URL:-https://lmstudio.ai/download/latest/linux/x64}"

OPENOFFICE_VERSION="${OPENOFFICE_VERSION:-4.1.16}"
OPENOFFICE_LANG="${OPENOFFICE_LANG:-de}"
OPENOFFICE_URL="${OPENOFFICE_URL:-https://sourceforge.net/projects/openofficeorg.mirror/files/${OPENOFFICE_VERSION}/binaries/${OPENOFFICE_LANG}/Apache_OpenOffice_${OPENOFFICE_VERSION}_Linux_x86-64_install-deb_${OPENOFFICE_LANG}.tar.gz/download}"

LOGIND_NO_SLEEP_CONF="${LOGIND_NO_SLEEP_CONF:-/etc/systemd/logind.conf.d/no-sleep.conf}"
DASH_TO_PANEL_UUID="${DASH_TO_PANEL_UUID:-dash-to-panel@jderose9.github.com}"
NETSPEED_UUID="${NETSPEED_UUID:-netspeed@hedayaty.gmail.com}"
NETSPEED_SEARCH="${NETSPEED_SEARCH:-netspeed}"

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
  read -r -p "Welcher normale Linux-Benutzer soll LM Studio/ComfyUI ausfuehren? " TARGET_USER
fi

if ! id "${TARGET_USER}" >/dev/null 2>&1; then
  echo "Benutzer '${TARGET_USER}' existiert nicht."
  exit 1
fi

TARGET_GROUP="$(id -gn "${TARGET_USER}")"
USER_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
LMSTUDIO_HOME="${LMSTUDIO_HOME:-${USER_HOME}/.lmstudio}"
LMSTUDIO_BIN="${LMSTUDIO_BIN:-${LMSTUDIO_HOME}/bin/lms}"
USER_BIN="${USER_HOME}/.local/bin"
USER_APPLICATIONS_DIR="${USER_HOME}/.local/share/applications"
COMFY_HOME_LINK="${COMFY_HOME_LINK:-${USER_HOME}/ComfyUI}"
COMFY_LAUNCHER_SCRIPT="${COMFY_LAUNCHER_SCRIPT:-${USER_BIN}/start-comfyui.sh}"
COMFY_APPLICATION_FILE="${COMFY_APPLICATION_FILE:-${USER_APPLICATIONS_DIR}/comfyui.desktop}"
SERVICE_PATH="${LMSTUDIO_HOME}/bin:${USER_BIN}:/usr/local/bin:/usr/bin:/bin"

if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
  echo "Home-Verzeichnis fuer '${TARGET_USER}' nicht gefunden."
  exit 1
fi

need_sudo() {
  if [[ -n "${SUDO}" ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "sudo ist nicht installiert."
      echo "Starte das Skript bitte als root, z.B.:"
      echo "  su -"
      echo "  cd /pfad/zum/script"
      echo "  TARGET_USER=$(id -un) bash ./ai_desktop_server.sh"
      exit 1
    fi

    if ! sudo -v; then
      echo
      echo "Dein Benutzer '$(id -un)' darf sudo nicht verwenden."
      echo "Starte das Skript bitte als root und gib den Zielbenutzer explizit an:"
      echo "  su -"
      echo "  cd /pfad/zum/script"
      echo "  TARGET_USER=$(id -un) bash ./ai_desktop_server.sh"
      echo
      echo "Alternative: root kann den Benutzer zur sudo-Gruppe hinzufuegen:"
      echo "  usermod -aG sudo $(id -un)"
      echo "Danach einmal abmelden und neu anmelden."
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
      sudo -u "${TARGET_USER}" -H env \
        HOME="${USER_HOME}" \
        USER="${TARGET_USER}" \
        LOGNAME="${TARGET_USER}" \
        PATH="${SERVICE_PATH}" \
        "$@"
    elif command -v runuser >/dev/null 2>&1; then
      runuser -u "${TARGET_USER}" -- env \
        HOME="${USER_HOME}" \
        USER="${TARGET_USER}" \
        LOGNAME="${TARGET_USER}" \
        PATH="${SERVICE_PATH}" \
        "$@"
    else
      echo "Weder sudo noch runuser gefunden. Kann nicht zu '${TARGET_USER}' wechseln."
      return 1
    fi
  else
    env HOME="${USER_HOME}" USER="${TARGET_USER}" LOGNAME="${TARGET_USER}" PATH="${SERVICE_PATH}" "$@"
  fi
}

run_user_shell() {
  if [[ "${EUID}" -eq 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo -u "${TARGET_USER}" -H env \
        HOME="${USER_HOME}" \
        USER="${TARGET_USER}" \
        LOGNAME="${TARGET_USER}" \
        PATH="${SERVICE_PATH}" \
        bash -lc "$1"
    elif command -v runuser >/dev/null 2>&1; then
      runuser -u "${TARGET_USER}" -- env \
        HOME="${USER_HOME}" \
        USER="${TARGET_USER}" \
        LOGNAME="${TARGET_USER}" \
        PATH="${SERVICE_PATH}" \
        bash -lc "$1"
    else
      echo "Weder sudo noch runuser gefunden. Kann nicht zu '${TARGET_USER}' wechseln."
      return 1
    fi
  else
    env HOME="${USER_HOME}" USER="${TARGET_USER}" LOGNAME="${TARGET_USER}" PATH="${SERVICE_PATH}" bash -lc "$1"
  fi
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

pause_hint() {
  echo
  echo "Hinweis: Nach Docker-Gruppenrechten kann ein Logout/Login noetig sein."
  echo
}

section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

primary_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

comfy_lan_url() {
  local ip
  ip="$(primary_lan_ip)"
  echo "http://${ip:-127.0.0.1}:${COMFY_PORT}/"
}

print_comfy_webui_urls() {
  local lan_url
  lan_url="$(comfy_lan_url)"
  echo "ComfyUI lokal:    http://127.0.0.1:${COMFY_PORT}/"
  echo "ComfyUI Netzwerk: ${lan_url}"
  echo "Browser-Adresse immer roh kopieren, ohne eckige Klammern oder Markdown."
  echo "Bild-API Beispiel: ${lan_url}api/view?filename=DATEI.png&type=output&subfolder=ORDNER"
}

apt_update() {
  run_root apt-get update
}

apt_install() {
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

apt_remove() {
  run_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@"
  run_root env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
}

apt_purge() {
  run_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@"
  run_root env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
}

command_ok() {
  command -v "$1" >/dev/null 2>&1
}

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

service_exists() {
  [[ -f "$1" ]]
}

sanitize_app_name() {
  local raw="$1"
  local sanitized
  raw="${raw// /_}"
  sanitized="$(printf '%s' "${raw}" | tr -cd 'A-Za-z0-9._-')"
  while [[ "${sanitized}" == .* || "${sanitized}" == -* ]]; do
    sanitized="${sanitized:1}"
  done
  if [[ -z "${sanitized}" ]]; then
    sanitized="${DEFAULT_APP_NAME}"
  fi
  echo "${sanitized}"
}

configure_app_name() {
  local input
  local sanitized

  if [[ -z "${APP_NAME_WAS_SET}" && -z "${AI_BASE_DIR_WAS_SET}" && ! -d "/opt/${DEFAULT_APP_NAME}" && ! -d "${AI_BASE_DIR}" ]]; then
    section "Erstinstallation: APP_NAME"
    echo "Der APP_NAME bestimmt den Basisordner unter /opt."
    echo "Beispiel: APP_NAME='${APP_NAME}' erstellt den Ordner /opt/${APP_NAME}"
    echo "Erlaubt sind Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich."
    read -r -p "APP_NAME fuer diese Installation [${APP_NAME}]: " input
    input="${input:-${APP_NAME}}"
    sanitized="$(sanitize_app_name "${input}")"
    if [[ "${sanitized}" != "${input}" ]]; then
      echo "Hinweis: Der Name wurde fuer den Pfad angepasst: '${input}' -> '${sanitized}'"
    fi
    APP_NAME="${sanitized}"
  else
    APP_NAME="$(sanitize_app_name "${APP_NAME}")"
  fi

  if [[ -z "${AI_BASE_DIR_WAS_SET}" ]]; then
    AI_BASE_DIR="/opt/${APP_NAME}"
  fi
  if [[ -z "${COMFY_DIR_WAS_SET}" ]]; then
    COMFY_DIR="${AI_BASE_DIR}/ComfyUI"
  fi
  if [[ -z "${COMFY_VENV_WAS_SET}" ]]; then
    COMFY_VENV="${COMFY_DIR}/.venv"
  fi
  if [[ -z "${COMFY_CUSTOM_NODES_DIR_WAS_SET}" ]]; then
    COMFY_CUSTOM_NODES_DIR="${COMFY_DIR}/custom_nodes"
  fi
  if [[ -z "${COMFY_MANAGER_DIR_WAS_SET}" ]]; then
    COMFY_MANAGER_DIR="${COMFY_CUSTOM_NODES_DIR}/comfyui-manager"
  fi
  if [[ -z "${COMFY_CRYSTOOLS_DIR_WAS_SET}" ]]; then
    COMFY_CRYSTOOLS_DIR="${COMFY_CUSTOM_NODES_DIR}/comfyui-crystools"
  fi
  if [[ -z "${COMFY_HOME_LINK_WAS_SET}" ]]; then
    COMFY_HOME_LINK="${USER_HOME}/ComfyUI"
  fi
}

lmstudio_headless_installed() {
  [[ -x "${LMSTUDIO_BIN}" ]] || command_ok lms
}

lmstudio_desktop_installed() {
  [[ -x "${LMSTUDIO_DESKTOP_APPIMAGE}" ]] || [[ -f "${LMSTUDIO_DESKTOP_FILE}" ]]
}

lmstudio_installed() {
  lmstudio_headless_installed || lmstudio_desktop_installed
}

libreoffice_installed() {
  command_ok libreoffice || command_ok libreoffice7.6 || package_installed libreoffice
}

openoffice_installed() {
  command_ok openoffice4 || [[ -d /opt/openoffice4 ]]
}

power_saving_disabled() {
  [[ -f "${LOGIND_NO_SLEEP_CONF}" ]] && grep -q '^IdleAction=ignore$' "${LOGIND_NO_SLEEP_CONF}" 2>/dev/null
}

power_saving_status() {
  if power_saving_disabled; then
    echo "deaktiviert"
  else
    echo "aktiv/Standard"
  fi
}

dash_to_panel_installed() {
  package_installed gnome-shell-extension-dash-to-panel || [[ -d "/usr/share/gnome-shell/extensions/${DASH_TO_PANEL_UUID}" ]]
}

dash_to_panel_uuid() {
  local dir
  for dir in \
    "/usr/share/gnome-shell/extensions/${DASH_TO_PANEL_UUID}" \
    /usr/share/gnome-shell/extensions/*dash-to-panel* \
    /usr/local/share/gnome-shell/extensions/*dash-to-panel* \
    "${USER_HOME}/.local/share/gnome-shell/extensions/"*dash-to-panel*; do
    if [[ -d "${dir}" ]]; then
      basename "${dir}"
      return 0
    fi
  done

  echo "${DASH_TO_PANEL_UUID}"
}

dash_to_panel_status() {
  if dash_to_panel_installed; then
    echo "installiert"
  else
    echo "fehlt"
  fi
}

netspeed_installed() {
  local dir
  if package_installed gnome-shell-extension-netspeed || [[ -d "/usr/share/gnome-shell/extensions/${NETSPEED_UUID}" ]]; then
    return 0
  fi

  for dir in \
    /usr/share/gnome-shell/extensions/*netspeed* \
    /usr/share/gnome-shell/extensions/*net-speed* \
    /usr/local/share/gnome-shell/extensions/*netspeed* \
    /usr/local/share/gnome-shell/extensions/*net-speed* \
    "${USER_HOME}/.local/share/gnome-shell/extensions/"*netspeed* \
    "${USER_HOME}/.local/share/gnome-shell/extensions/"*net-speed*; do
    if [[ -d "${dir}" ]]; then
      return 0
    fi
  done

  return 1
}

netspeed_uuid() {
  local dir
  for dir in \
    "/usr/share/gnome-shell/extensions/${NETSPEED_UUID}" \
    /usr/share/gnome-shell/extensions/*netspeed* \
    /usr/share/gnome-shell/extensions/*net-speed* \
    /usr/local/share/gnome-shell/extensions/*netspeed* \
    /usr/local/share/gnome-shell/extensions/*net-speed* \
    "${USER_HOME}/.local/share/gnome-shell/extensions/"*netspeed* \
    "${USER_HOME}/.local/share/gnome-shell/extensions/"*net-speed*; do
    if [[ -d "${dir}" ]]; then
      basename "${dir}"
      return 0
    fi
  done

  echo "${NETSPEED_UUID}"
}

netspeed_status() {
  if netspeed_installed; then
    echo "installiert"
  else
    echo "fehlt"
  fi
}

safe_rm_dir() {
  local path="$1"
  local label="$2"

  if [[ -z "${path}" || "${path}" == "/" || "${path}" == "/home" || "${path}" == "/opt" ]]; then
    echo "Unsicherer Pfad, loesche nicht: ${path}"
    return 1
  fi

  if [[ -e "${path}" ]] && ask_yes_no "${label} '${path}' wirklich loeschen?" "n"; then
    run_root rm -rf --one-file-system "${path}"
  fi
}

check_operating_system() {
  section "Betriebssystem pruefen"

  local os_id=""
  local version_id=""
  local version_codename=""
  local debian_version=""
  local arch=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    version_codename="${VERSION_CODENAME:-}"
  fi

  debian_version="$(cat /etc/debian_version 2>/dev/null || true)"
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  echo "Gefunden: ID=${os_id:-unbekannt}, VERSION_ID=${version_id:-unbekannt}, Debian=${debian_version:-unbekannt}, Codename=${version_codename:-unbekannt}, Arch=${arch}"
  echo "Erwartet: debian-${EXPECTED_DEBIAN_VERSION}.0-${EXPECTED_ARCH}-DVD-1.iso bzw. Debian ${EXPECTED_DEBIAN_VERSION}.x ${EXPECTED_ARCH}"

  local ok="yes"
  if [[ "${os_id}" != "debian" ]]; then
    ok="no"
  fi
  if [[ "${version_id}" != "${EXPECTED_DEBIAN_MAJOR}" && "${debian_version}" != ${EXPECTED_DEBIAN_VERSION}* ]]; then
    ok="no"
  fi
  if [[ "${debian_version}" != ${EXPECTED_DEBIAN_VERSION}* ]]; then
    ok="no"
  fi
  if [[ "${arch}" != "${EXPECTED_ARCH}" ]]; then
    ok="no"
  fi

  if [[ "${ok}" != "yes" ]]; then
    echo
    echo "WARNUNG: Dieses System passt nicht exakt zur erwarteten Debian-Version."
    echo "Installationen koennen fehlschlagen oder andere Paketnamen/Repos brauchen."
    if ! ask_yes_no "Trotzdem fortfahren?" "n"; then
      exit 1
    fi
  fi
}

check_nvidia_post_reboot_marker() {
  if [[ ! -f "${NVIDIA_POST_REBOOT_MARKER}" ]]; then
    return 0
  fi

  section "NVIDIA nach Neustart"
  if detect_nvidia_cuda_ready; then
    echo "nvidia-smi funktioniert jetzt."
    echo "Bitte ComfyUI reparieren/aktualisieren und Profil 2 waehlen, damit PyTorch/ComfyUI auf GPU umgestellt wird."
    echo "Pfad:"
    echo "  ComfyUI -> r"
    echo "  PyTorch/ComfyUI Installationsprofil -> 2"
    run_root rm -f "${NVIDIA_POST_REBOOT_MARKER}" || true
  else
    echo "Marker gefunden, aber nvidia-smi funktioniert noch nicht."
    echo "Bitte pruefen:"
    echo "  nvidia-smi"
    echo "  /var/log/nvidia-installer.log"
  fi
}

offer_update_upgrade() {
  section "APT Update/Upgrade"
  if ask_yes_no "Paketlisten aktualisieren und System-Upgrade ausfuehren?" "y"; then
    apt_update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  elif ask_yes_no "Nur Paketlisten aktualisieren?" "y"; then
    apt_update
  fi
}

scan_status() {
  section "Vorhandene Anwendungen"
  printf "%-24s %s\n" "curl" "$(command_ok curl && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "nano" "$(command_ok nano && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "LibreOffice" "$(libreoffice_installed && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "OpenOffice" "$(openoffice_installed && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "Visual Studio Code" "$(command_ok code && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "LM Studio Headless" "$(lmstudio_headless_installed && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "LM Studio Desktop" "$(lmstudio_desktop_installed && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "Docker" "$(command_ok docker && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "Docker Compose" "$(docker compose version >/dev/null 2>&1 && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "ComfyUI" "$([[ -d "${COMFY_DIR}" ]] && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "ComfyUI Manager" "$([[ -d "${COMFY_MANAGER_DIR}" ]] && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "Crystools Monitor" "$([[ -d "${COMFY_CRYSTOOLS_DIR}" ]] && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "ComfyUI Shortcut" "$([[ -f "${COMFY_APPLICATION_FILE}" ]] && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "ComfyUI Home-Link" "$([[ -L "${COMFY_HOME_LINK}" ]] && echo installiert || echo fehlt)"
  printf "%-24s %s\n" "NVIDIA SMI" "$(detect_nvidia_cuda_ready && echo aktiv || echo fehlt)"
  printf "%-24s %s\n" "NVIDIA Post-Reboot" "$([[ -f "${NVIDIA_POST_REBOOT_MARKER}" ]] && echo ausstehend || echo '-')"
  printf "%-24s %s\n" "LM Autostart" "$(service_exists "${LMSTUDIO_SERVICE}" && systemctl is-enabled lmstudio.service 2>/dev/null || echo fehlt)"
  printf "%-24s %s\n" "ComfyUI Autostart" "$(service_exists "${COMFY_SERVICE}" && systemctl is-enabled comfyui.service 2>/dev/null || echo fehlt)"
  printf "%-24s %s\n" "Energiesparen" "$(power_saving_status)"
  printf "%-24s %s\n" "Windows-artige Taskleiste" "$(dash_to_panel_status)"
  printf "%-24s %s\n" "NetSpeed Anzeige" "$(netspeed_status)"
  echo
  echo "Zielbenutzer: ${TARGET_USER}"
  echo "Home:         ${USER_HOME}"
  echo "APP_NAME:     ${APP_NAME}"
  echo "Basis:        ${AI_BASE_DIR}"
  echo "ComfyUI:      ${COMFY_DIR}"
  echo "Comfy Link:   ${COMFY_HOME_LINK}"
  echo "Custom Nodes: ${COMFY_CUSTOM_NODES_DIR}"
  echo "Comfy Start:  ${COMFY_LAUNCHER_SCRIPT}"
  echo "LM Headless:  ${LMSTUDIO_HOME}"
  echo "LM Desktop:   ${LMSTUDIO_DESKTOP_APPIMAGE}"
}

choose_action() {
  local title="$1"
  local installed="$2"
  local answer

  echo
  echo "${title}: $([[ "${installed}" == "yes" ]] && echo installiert || echo nicht installiert)"

  if [[ "${installed}" == "yes" ]]; then
    echo "Optionen: [s] ueberspringen, [r] reparieren/aktualisieren, [u] deinstallieren"
    while true; do
      read -r -p "Auswahl fuer ${title}: " answer
      case "${answer,,}" in
        ""|s|skip) ACTION="skip"; return 0 ;;
        r|repair|reparieren) ACTION="repair"; return 0 ;;
        u|uninstall|deinstallieren) ACTION="uninstall"; return 0 ;;
        *) echo "Bitte s, r oder u eingeben." ;;
      esac
    done
  else
    echo "Optionen: [i] installieren, [s] ueberspringen"
    while true; do
      read -r -p "Auswahl fuer ${title}: " answer
      case "${answer,,}" in
        i|install|installieren) ACTION="install"; return 0 ;;
        ""|s|skip) ACTION="skip"; return 0 ;;
        *) echo "Bitte i oder s eingeben." ;;
      esac
    done
  fi
}

install_curl() {
  apt_install ca-certificates curl
}

uninstall_curl() {
  apt_purge curl
}

install_nano() {
  apt_install nano
  run_root update-alternatives --install /usr/bin/editor editor /bin/nano 50
}

uninstall_nano() {
  apt_purge nano
}

install_libreoffice() {
  section "LibreOffice installieren/reparieren"
  apt_install libreoffice libreoffice-l10n-de libreoffice-help-de
}

uninstall_libreoffice() {
  section "LibreOffice deinstallieren"
  apt_purge libreoffice libreoffice-core libreoffice-common libreoffice-l10n-de libreoffice-help-de || true
}

install_openoffice() {
  section "Apache OpenOffice installieren/reparieren"
  apt_install curl tar gzip desktop-file-utils

  local download_url="${OPENOFFICE_URL}"
  echo "Standard-Download: ${download_url}"
  read -r -p "Andere OpenOffice DEB tar.gz URL verwenden? Leer = Standard: " custom_url
  if [[ -n "${custom_url}" ]]; then
    download_url="${custom_url}"
  fi

  local tmp_dir
  local archive
  local debs_dir
  local dpkg_status
  tmp_dir="$(mktemp -d)"
  archive="${tmp_dir}/openoffice.tar.gz"

  if ! run_root curl -fL "${download_url}" -o "${archive}"; then
    echo "Download fehlgeschlagen. Bitte aktuellen Linux x86-64 DEB-Link von https://www.openoffice.org/download/ nutzen:"
    echo "OPENOFFICE_URL='https://...' ./ai_desktop_server.sh"
    run_root rm -rf --one-file-system "${tmp_dir}"
    return 1
  fi

  run_root tar -xzf "${archive}" -C "${tmp_dir}"
  debs_dir="$(find "${tmp_dir}" -type d -name DEBS | head -n 1)"
  if [[ -z "${debs_dir}" || ! -d "${debs_dir}" ]]; then
    echo "Keine DEBS-Installation im OpenOffice-Archiv gefunden."
    run_root rm -rf --one-file-system "${tmp_dir}"
    return 1
  fi

  set +e
  run_root bash -c "dpkg -i '${debs_dir}'/*.deb"
  dpkg_status="$?"
  set -e
  if [[ "${dpkg_status}" -ne 0 ]]; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get -f install -y
  fi

  if [[ -d "${debs_dir}/desktop-integration" ]]; then
    set +e
    run_root bash -c "dpkg -i '${debs_dir}/desktop-integration'/*.deb"
    dpkg_status="$?"
    set -e
    if [[ "${dpkg_status}" -ne 0 ]]; then
      run_root env DEBIAN_FRONTEND=noninteractive apt-get -f install -y
    fi
  fi

  run_root rm -rf --one-file-system "${tmp_dir}"
  echo "Apache OpenOffice installiert/repariert."
}

uninstall_openoffice() {
  section "Apache OpenOffice deinstallieren"
  local packages
  packages="$(dpkg-query -W -f='${Package}\n' 'openoffice*' 2>/dev/null || true)"
  if [[ -n "${packages}" ]]; then
    # shellcheck disable=SC2086
    apt_purge ${packages}
  else
    echo "Keine openoffice*-Pakete gefunden."
  fi

  safe_rm_dir "/opt/openoffice4" "Apache OpenOffice Programmverzeichnis"
}

install_vscode() {
  section "Visual Studio Code installieren/reparieren"
  apt_install curl wget gpg apt-transport-https ca-certificates
  local key_tmp
  key_tmp="$(mktemp)"
  run_root curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o "${key_tmp}"
  run_root install -d -m 0755 /usr/share/keyrings
  run_root bash -c "gpg --dearmor < '${key_tmp}' > /usr/share/keyrings/microsoft.gpg"
  run_root chmod 0644 /usr/share/keyrings/microsoft.gpg
  rm -f "${key_tmp}"
  run_root tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
  apt_update
  apt_install code
  if command_ok code; then
    run_root update-alternatives --install /usr/bin/editor editor "$(command -v code)" 30 || true
  fi
}

uninstall_vscode() {
  section "Visual Studio Code deinstallieren"
  apt_purge code || true
  if ask_yes_no "VS Code APT-Repository und Key entfernen?" "n"; then
    run_root rm -f /etc/apt/sources.list.d/vscode.sources /usr/share/keyrings/microsoft.gpg
    apt_update
  fi
}

docker_codename() {
  local codename=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi
  if [[ -z "${codename}" && -r /etc/debian_version ]]; then
    case "$(cut -d. -f1 /etc/debian_version)" in
      13) codename="trixie" ;;
      12) codename="bookworm" ;;
      11) codename="bullseye" ;;
    esac
  fi
  echo "${codename}"
}

install_docker() {
  section "Docker und Docker Compose installieren/reparieren"
  apt_install ca-certificates curl gnupg lsb-release
  local codename
  codename="$(docker_codename)"
  if [[ -z "${codename}" ]]; then
    read -r -p "Debian-Codename nicht erkannt. Bitte eingeben, z.B. trixie: " codename
  fi

  run_root install -m 0755 -d /etc/apt/keyrings
  run_root curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  run_root chmod a+r /etc/apt/keyrings/docker.asc
  run_root tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_root systemctl enable --now docker
  run_root usermod -aG docker "${TARGET_USER}"
  pause_hint
}

uninstall_docker() {
  section "Docker und Docker Compose deinstallieren"
  run_root systemctl disable --now docker 2>/dev/null || true
  apt_purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
  if ask_yes_no "Docker Daten unter /var/lib/docker und /var/lib/containerd loeschen?" "n"; then
    run_root rm -rf --one-file-system /var/lib/docker /var/lib/containerd
  fi
  if ask_yes_no "Docker APT-Repository und Key entfernen?" "n"; then
    run_root rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
    apt_update
  fi
}

create_lmstudio_service() {
  local cors_flag=""
  if ask_yes_no "LM Studio Server mit CORS starten? Nur fuer Web-Frontends aktivieren." "n"; then
    cors_flag=" --cors"
  fi

  run_root tee "${LMSTUDIO_SERVICE}" >/dev/null <<EOF
[Unit]
Description=LM Studio Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${TARGET_USER}
Group=${TARGET_GROUP}
Environment="HOME=${USER_HOME}"
Environment="USER=${TARGET_USER}"
Environment="LOGNAME=${TARGET_USER}"
Environment="PATH=${SERVICE_PATH}"
Environment="LMS_SERVER_HOST=${LMSTUDIO_HOST}"
ExecStartPre=${LMSTUDIO_BIN} daemon up
ExecStart=${LMSTUDIO_BIN} server start --bind ${LMSTUDIO_HOST} --port ${LMSTUDIO_PORT}${cors_flag}
ExecStop=${LMSTUDIO_BIN} server stop
ExecStopPost=${LMSTUDIO_BIN} daemon down
TimeoutStartSec=120
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

  run_root systemctl daemon-reload
  run_root systemctl enable lmstudio.service
  run_root systemctl restart lmstudio.service
  run_root systemctl status lmstudio.service --no-pager || true
  echo "LM Studio API: http://$(primary_lan_ip):${LMSTUDIO_PORT}/v1/models"
}

remove_lmstudio_service() {
  run_root systemctl disable --now lmstudio.service 2>/dev/null || true
  run_root rm -f "${LMSTUDIO_SERVICE}"
  run_root systemctl daemon-reload
}

install_lmstudio_headless() {
  section "LM Studio Headless-Server/lms installieren/reparieren"
  install_curl
  local installer
  installer="$(mktemp)"
  curl -fsSL https://lmstudio.ai/install.sh -o "${installer}"
  chmod 0755 "${installer}"
  run_user bash "${installer}"
  rm -f "${installer}"

  if [[ ! -x "${LMSTUDIO_BIN}" ]]; then
    echo "WARNUNG: ${LMSTUDIO_BIN} wurde nicht gefunden. Suche lms im PATH..."
    if command_ok lms; then
      LMSTUDIO_BIN="$(command -v lms)"
      echo "Nutze ${LMSTUDIO_BIN}"
    else
      echo "lms wurde nicht gefunden. Installation bitte pruefen."
      return 1
    fi
  fi

  run_user "${LMSTUDIO_BIN}" --help >/dev/null || true

  if ask_yes_no "LM Studio als Server-Autostart einrichten/aktualisieren?" "y"; then
    create_lmstudio_service
  fi
}

install_lmstudio_desktop() {
  section "LM Studio Desktop-App installieren/reparieren"
  install_curl
  apt_install ca-certificates libglib2.0-0 libnss3 libxss1 libatk-bridge2.0-0 libgtk-3-0 xdg-utils
  apt_install libasound2t64 || apt_install libasound2 || true
  apt_install libfuse2t64 || apt_install libfuse2 || true

  local download_url="${LMSTUDIO_DESKTOP_URL}"
  echo "Standard-Download: ${download_url}"
  read -r -p "Andere LM Studio Linux AppImage URL verwenden? Leer = Standard: " custom_url
  if [[ -n "${custom_url}" ]]; then
    download_url="${custom_url}"
  fi

  run_root install -d -m 0755 "${LMSTUDIO_DESKTOP_DIR}"
  if ! run_root curl -fL "${download_url}" -o "${LMSTUDIO_DESKTOP_APPIMAGE}"; then
    echo "Download fehlgeschlagen. Bitte aktuellen Linux-AppImage-Link von https://lmstudio.ai/download nutzen:"
    echo "LMSTUDIO_DESKTOP_URL='https://...' ./ai_desktop_server.sh"
    return 1
  fi
  run_root chmod 0755 "${LMSTUDIO_DESKTOP_APPIMAGE}"

  run_root tee "${LMSTUDIO_DESKTOP_FILE}" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=LM Studio
Comment=Run local LLMs with LM Studio
Exec=${LMSTUDIO_DESKTOP_APPIMAGE} %U
Icon=lmstudio
Terminal=false
Categories=Development;Utility;
StartupWMClass=LM Studio
EOF

  if command_ok update-desktop-database; then
    run_root update-desktop-database /usr/share/applications || true
  fi

  echo "LM Studio Desktop-App installiert: ${LMSTUDIO_DESKTOP_APPIMAGE}"
  echo "Sie sollte im Desktop-App-Menue als 'LM Studio' erscheinen."
}

install_lmstudio() {
  section "LM Studio installieren/reparieren"
  local choice
  echo "Welche Variante soll installiert/repariert werden?"
  echo "1) LM Studio als Headless-Server fuer LLM/API"
  echo "2) LM Studio als normale Desktop-App"
  echo "3) Beide Varianten"
  read -r -p "Auswahl [1]: " choice
  choice="${choice:-1}"

  case "${choice}" in
    2) install_lmstudio_desktop ;;
    3)
      install_lmstudio_headless
      install_lmstudio_desktop
      ;;
    *) install_lmstudio_headless ;;
  esac
}

uninstall_lmstudio_headless() {
  section "LM Studio Headless-Server/lms deinstallieren"
  remove_lmstudio_service
  safe_rm_dir "${LMSTUDIO_HOME}" "LM Studio Home inklusive Modelle/Runtime"
}

uninstall_lmstudio_desktop() {
  section "LM Studio Desktop-App deinstallieren"
  run_root rm -f "${LMSTUDIO_DESKTOP_FILE}" "${LMSTUDIO_DESKTOP_APPIMAGE}"
  safe_rm_dir "${LMSTUDIO_DESKTOP_DIR}" "LM Studio Desktop-Verzeichnis"
  if command_ok update-desktop-database; then
    run_root update-desktop-database /usr/share/applications || true
  fi
}

uninstall_lmstudio() {
  section "LM Studio deinstallieren"
  local choice
  echo "Welche Variante soll deinstalliert werden?"
  echo "1) Headless-Server/lms"
  echo "2) Desktop-App"
  echo "3) Beide Varianten"
  read -r -p "Auswahl [3]: " choice
  choice="${choice:-3}"

  case "${choice}" in
    1) uninstall_lmstudio_headless ;;
    2) uninstall_lmstudio_desktop ;;
    *) 
      uninstall_lmstudio_headless
      uninstall_lmstudio_desktop
      ;;
  esac
}

choose_torch_install() {
  local choice
  echo >&2
  echo "PyTorch/ComfyUI Installationsprofil:" >&2
  echo "1) Auto: aktiven NVIDIA-Treiber nutzen, sonst CPU" >&2
  echo "2) NVIDIA CUDA RTX6000pro/Blackwell (570+/Open/Runfile(v595.84)" >&2
  echo "3) NVIDIA CUDA normaler Debian-Treiber (v550.xx)" >&2
  echo "4) NVIDIA CUDA ohne Treiberinstallation" >&2
  echo "5) CPU only installieren" >&2
  echo "6) AMD ROCm installieren" >&2
  echo "7) Intel XPU installieren" >&2
  echo "8) PyTorch ueberspringen, nur requirements.txt" >&2
  read -r -p "ComfyUI PyTorch-Profil Auswahl [1]: " choice
  choice="${choice:-1}"

  case "${choice}" in
    2) echo "nvidia_blackwell" ;;
    3) echo "nvidia_driver" ;;
    4) echo "nvidia" ;;
    5) echo "cpu" ;;
    6) echo "amd" ;;
    7) echo "intel" ;;
    8) echo "skip" ;;
    *) echo "auto" ;;
  esac
}

detect_nvidia_cuda_ready() {
  if command_ok nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

detect_nvidia_gpu_present() {
  if command_ok lspci && lspci 2>/dev/null | grep -qi "nvidia"; then
    return 0
  fi
  return 1
}

nvidia_blackwell_gpu_present() {
  command_ok lspci || return 1
  lspci 2>/dev/null | grep -Eiq "GB20|Blackwell|RTX PRO 6000"
}

nvidia_kernel_log_reports_unsupported_gpu() {
  journalctl -k -b --no-pager 2>/dev/null | grep -Eiq "specific graphics driver download page|Supported NVIDIA GPU Products|None of the NVIDIA devices were initialized"
}

nvidia_driver_package_installed() {
  package_installed nvidia-driver || package_installed nvidia-driver-full || package_installed nvidia-tesla-535-driver
}

apt_package_has_candidate() {
  local package_name="$1"
  LC_ALL=C apt-cache policy "${package_name}" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vqE '^\(none\)$|^$'
}

nvidia_preferred_apt_package() {
  local package_name
  for package_name in ${NVIDIA_PREFERRED_APT_PACKAGES}; do
    if apt_package_has_candidate "${package_name}"; then
      echo "${package_name}"
      return 0
    fi
  done
  return 1
}

show_nvidia_apt_diagnostics() {
  echo
  echo "NVIDIA/APT Diagnose:"
  echo "---- apt-cache policy nvidia-driver ----"
  LC_ALL=C apt-cache policy nvidia-driver || true
  echo "---- apt-cache search nvidia-driver ----"
  LC_ALL=C apt-cache search '^nvidia-driver$|^nvidia-driver-' || true
  echo "---- Debian APT Quellen mit contrib/non-free/nvidia ----"
  run_root bash -c "grep -RHiE 'contrib|non-free|nvidia|deb.debian.org|security.debian.org' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true"
  echo "----------------------------------------"
  echo
}

show_nvidia_runtime_diagnostics() {
  echo
  echo "NVIDIA Laufzeit-Diagnose:"
  echo "---- GPU per lspci ----"
  lspci 2>/dev/null | grep -i "nvidia" || true
  echo "---- installierte NVIDIA Pakete ----"
  dpkg-query -W -f='${Package} ${Version}\n' 'nvidia*' 2>/dev/null | sort || true
  echo "---- nvidia-smi ----"
  nvidia-smi 2>&1 || true
  echo "---- modprobe nvidia ----"
  modprobe nvidia 2>&1 || true
  echo "---- geladene Kernelmodule ----"
  lsmod 2>/dev/null | grep -Ei 'nvidia|nouveau' || true
  echo "---- DKMS ----"
  dkms status 2>/dev/null || true
  echo "---- Secure Boot ----"
  if command_ok mokutil; then
    mokutil --sb-state 2>/dev/null || true
  else
    echo "mokutil nicht installiert."
  fi
  echo "---- Kernel-Log NVIDIA/Nouveau/SecureBoot ----"
  journalctl -k -b --no-pager 2>/dev/null | grep -Ei 'nvidia|nouveau|secure boot|module verification|dkms|firmware' | tail -n 80 || true
  echo "--------------------------------"
  echo
  echo "Wenn Secure Boot aktiv ist, blockiert Debian oft unsignierte NVIDIA-Kernelmodule."
  echo "Dann im BIOS/UEFI Secure Boot deaktivieren oder MOK/Modulsignierung einrichten."
  echo "Wenn nouveau geladen ist, nach Treiberinstallation neu starten."
  echo
}

graphics_session_running() {
  if [[ -e /tmp/.X0-lock ]]; then
    local lock_pid
    lock_pid="$(tr -cd '0-9' </tmp/.X0-lock 2>/dev/null || true)"
    if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
      return 0
    fi
  fi
  command_ok pgrep && pgrep -x Xorg >/dev/null 2>&1 && return 0
  command_ok pgrep && pgrep -x Xwayland >/dev/null 2>&1 && return 0
  command_ok pgrep && pgrep -x gdm3 >/dev/null 2>&1 && return 0
  command_ok pgrep && pgrep -x lightdm >/dev/null 2>&1 && return 0
  command_ok pgrep && pgrep -x sddm >/dev/null 2>&1 && return 0
  return 1
}

prepare_nvidia_runfile_installer() {
  section "NVIDIA-Runfile-Installer vorbereiten"

  apt_install curl build-essential dkms linux-headers-amd64 pkg-config
  run_root install -d -m 0755 "${NVIDIA_DRIVER_DIR}"

  if [[ ! -f "${NVIDIA_RUN_DRIVER_FILE}" ]]; then
    if ! run_root curl -fL "${NVIDIA_RUN_DRIVER_URL}" -o "${NVIDIA_RUN_DRIVER_FILE}"; then
      echo "Download fehlgeschlagen. Du kannst den Link ueberschreiben:"
      echo "NVIDIA_RUN_DRIVER_URL='https://...' TARGET_USER=${TARGET_USER} bash ./ai_desktop_server.sh"
      return 1
    fi
  fi
  run_root chmod 0755 "${NVIDIA_RUN_DRIVER_FILE}"

  run_root tee "${NVIDIA_RUN_INSTALL_SCRIPT}" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ -e /tmp/.X0-lock ]]; then
  LOCK_PID="\$(tr -cd '0-9' </tmp/.X0-lock 2>/dev/null || true)"
  if [[ -n "\${LOCK_PID}" ]] && kill -0 "\${LOCK_PID}" 2>/dev/null; then
    echo "Grafische Sitzung laeuft noch. Bitte zuerst in TTY/SSH arbeiten und Desktop stoppen:"
    echo "  systemctl isolate multi-user.target"
    exit 1
  fi
  echo "Entferne veraltete /tmp/.X0-lock."
  rm -f /tmp/.X0-lock
fi

if pgrep -x Xorg >/dev/null 2>&1 || pgrep -x Xwayland >/dev/null 2>&1 || pgrep -x gdm3 >/dev/null 2>&1 || pgrep -x lightdm >/dev/null 2>&1 || pgrep -x sddm >/dev/null 2>&1; then
  echo "Grafische Sitzung laeuft noch. Bitte zuerst in TTY/SSH arbeiten und Desktop stoppen:"
  echo "  systemctl isolate multi-user.target"
  exit 1
fi

systemctl stop comfyui.service 2>/dev/null || true
apt-get purge -y 'nvidia*' 'libnvidia*' || true
apt-get autoremove -y || true
"${NVIDIA_RUN_DRIVER_FILE}" --silent --dkms --no-questions --disable-nouveau --install-libglvnd --kernel-module-type=open
modprobe nvidia || true
nvidia-smi || true
mkdir -p "${NVIDIA_DRIVER_DIR}"
cat > "${NVIDIA_POST_REBOOT_MARKER}" <<'MARKER'
NVIDIA Runfile installation was executed.
After reboot, run ai_desktop_server.sh again and choose:
ComfyUI -> r
PyTorch/ComfyUI Installationsprofil -> 2
MARKER
echo
echo "Wenn nvidia-smi funktioniert: systemctl reboot"
echo "Nach dem Reboot ai_desktop_server.sh erneut starten und ComfyUI Profil 2 waehlen."
echo "Wenn nvidia-smi nicht funktioniert: /var/log/nvidia-installer.log pruefen."
EOF
  run_root chmod 0755 "${NVIDIA_RUN_INSTALL_SCRIPT}"

  echo "Vorbereitet:"
  echo "  ${NVIDIA_RUN_DRIVER_FILE}"
  echo "  ${NVIDIA_RUN_INSTALL_SCRIPT}"
  echo
  echo "Ausfuehrung empfohlen per SSH oder TTY:"
  echo "  su -"
  echo "  systemctl isolate multi-user.target"
  echo "  ${NVIDIA_RUN_INSTALL_SCRIPT}"
  echo "  systemctl reboot"
}

countdown_notice() {
  local message="$1"
  local seconds="${2:-10}"
  local i

  echo
  for ((i=seconds; i>=1; i--)); do
    echo "${message} ${i}"
    sleep 1
  done
  echo
}

create_nvidia_runfile_systemd_service() {
  run_root tee "${NVIDIA_RUN_SYSTEMD_SERVICE}" >/dev/null <<EOF
[Unit]
Description=One-shot NVIDIA Runfile Driver Installer
After=multi-user.target

[Service]
Type=oneshot
ExecStartPre=-/usr/bin/systemctl disable nvidia-runfile-install.service
ExecStart=${NVIDIA_RUN_INSTALL_SCRIPT}
ExecStartPost=/usr/bin/systemctl reboot
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  run_root systemctl daemon-reload
  run_root systemctl enable nvidia-runfile-install.service
}

start_nvidia_runfile_auto_install() {
  section "NVIDIA Auto-Installation vorbereiten"

  prepare_nvidia_runfile_installer || return 1
  create_nvidia_runfile_systemd_service

  echo "Das Skript beendet jetzt die grafische Sitzung automatisch."
  echo "Danach laeuft ein einmaliger systemd-Job:"
  echo "  ${NVIDIA_RUN_SYSTEMD_SERVICE}"
  echo "Er installiert den NVIDIA-Runfile-Treiber und startet danach automatisch neu."
  echo
  echo "WICHTIG: Nach dem Neustart dieses Skript erneut starten und ComfyUI Profil 2 waehlen."
  echo "Alles speichern, was noch offen ist."

  countdown_notice "NVIDIA Installation + Desktop beenden + Reboot in" "${NVIDIA_AUTO_REBOOT_SECONDS}"
  run_root systemctl isolate multi-user.target
  exit 0
}

install_nvidia_preferred_apt_driver() {
  local package_name
  package_name="$(nvidia_preferred_apt_package || true)"
  if [[ -z "${package_name}" ]]; then
    return 1
  fi

  section "NVIDIA-Treiber aus APT installieren"
  echo "Gefundenes bevorzugtes NVIDIA-Paket: ${package_name}"
  echo "Das ist besser fuer Blackwell als Debians nvidia-driver 550, falls es aus einer passenden Quelle kommt."

  if ! ask_yes_no "${package_name} jetzt installieren?" "y"; then
    return 1
  fi

  apt_install linux-headers-amd64 "${package_name}"
  if apt_package_has_candidate firmware-misc-nonfree; then
    apt_install firmware-misc-nonfree
  fi
  if apt_package_has_candidate nvidia-smi; then
    apt_install nvidia-smi
  fi

  run_root modprobe nvidia 2>/dev/null || true
  if detect_nvidia_cuda_ready; then
    echo "NVIDIA-Treiber ist jetzt aktiv:"
    nvidia-smi || true
    return 0
  fi

  NVIDIA_DRIVER_REBOOT_REQUIRED="yes"
  echo "NVIDIA-Paket wurde installiert, ist aber noch nicht aktiv."
  echo "Bitte ausfuehren:"
  echo "  systemctl reboot"
  return 0
}

install_nvidia_official_runfile_driver() {
  section "Offiziellen NVIDIA-Runfile-Treiber installieren"

  echo "Diese GPU wirkt neuer als Debians nvidia-driver 550."
  echo "Offizieller NVIDIA-Treiber: ${NVIDIA_RUN_DRIVER_VERSION}"
  echo "Download: ${NVIDIA_RUN_DRIVER_URL}"
  echo
  echo "Hinweis: Das ist nicht der normale Debian-Paketweg."
  echo "Fuer Blackwell wird das offene NVIDIA-Kernelmodul verwendet."
  echo "Am besten aus einer TTY oder per SSH ausfuehren, nicht aus einer laufenden Desktop-Sitzung."
  echo "Der Installer kann fehlschlagen, wenn die grafische Sitzung die NVIDIA-Karte gerade benutzt."

  if ! ask_yes_no "Offiziellen NVIDIA-Runfile-Treiber jetzt installieren?" "n"; then
    return 1
  fi

  if graphics_session_running; then
    echo "Grafische Sitzung/X-Server laeuft. Der NVIDIA-Installer wuerde jetzt abbrechen."
    echo "Das Skript kann die Installation automatisch ueber multi-user.target ausfuehren."
    if ask_yes_no "Jetzt automatisch Desktop beenden, NVIDIA installieren und danach rebooten?" "y"; then
      start_nvidia_runfile_auto_install
    else
      echo "Ich bereite die Installation nur vor und entferne keine NVIDIA-Pakete in der laufenden Desktop-Sitzung."
      prepare_nvidia_runfile_installer
    fi
    return 1
  fi

  local run_file
  prepare_nvidia_runfile_installer || return 1
  run_file="${NVIDIA_RUN_DRIVER_FILE}"

  if ask_yes_no "Vorher Debian NVIDIA-Pakete entfernen? Fuer Runfile-Installation empfohlen." "y"; then
    run_root systemctl stop comfyui.service 2>/dev/null || true
    run_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y 'nvidia*' 'libnvidia*' || true
    run_root env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
  fi

  echo "Starte NVIDIA-Installer. Das kann einige Minuten dauern."
  set +e
  run_root "${run_file}" --silent --dkms --no-questions --disable-nouveau --install-libglvnd --kernel-module-type=open
  local installer_status="$?"
  set -e

  if [[ "${installer_status}" -ne 0 ]]; then
    echo "NVIDIA-Runfile-Installer ist fehlgeschlagen."
    echo "Bitte aus TTY/SSH erneut versuchen oder Installer-Log pruefen:"
    echo "  /var/log/nvidia-installer.log"
    return 1
  fi

  run_root modprobe nvidia 2>/dev/null || true
  if detect_nvidia_cuda_ready; then
    echo "Offizieller NVIDIA-Treiber ist aktiv:"
    nvidia-smi || true
    return 0
  fi

  NVIDIA_DRIVER_REBOOT_REQUIRED="yes"
  echo "Offizieller NVIDIA-Treiber wurde installiert, ist aber noch nicht aktiv."
  echo "Bitte ausfuehren:"
  echo "  systemctl reboot"
  return 0
}

install_nvidia_blackwell_driver() {
  section "NVIDIA CUDA RTX6000pro/Blackwell"

  if detect_nvidia_cuda_ready; then
    echo "NVIDIA-Treiber ist bereits aktiv:"
    nvidia-smi || true
    return 0
  fi

  echo "Dieser Modus ueberspringt Debians nvidia-driver 550."
  echo "Er versucht zuerst ein 570+/Open-Kernelmodul-Paket aus APT."
  echo "Wenn keines verfuegbar ist, wird der offizielle NVIDIA-Runfile-Installer vorbereitet."
  echo "ComfyUI nutzt GPU erst, wenn 'nvidia-smi' funktioniert."

  if install_nvidia_preferred_apt_driver; then
    return 0
  fi

  install_nvidia_official_runfile_driver || {
    echo "NVIDIA Blackwell-Treiber wurde nicht installiert."
    echo "ComfyUI wird fuer diesen Lauf mit CPU vorbereitet."
    NVIDIA_DRIVER_REBOOT_REQUIRED="no"
    return 0
  }
}

ensure_debian_nonfree_sources() {
  local codename
  codename="$(docker_codename)"
  if [[ -z "${codename}" ]]; then
    read -r -p "Debian-Codename nicht erkannt. Bitte eingeben, z.B. trixie: " codename
  fi

  echo "Bereinige alte doppelte NVIDIA-APT-Quelle, falls vorhanden."
  run_root rm -f /etc/apt/sources.list.d/debian-nonfree.sources
  run_root rm -f /etc/apt/sources.list.d/debian-nvidia.sources

  echo "Aktiviere Debian-Komponenten fuer NVIDIA: contrib non-free"
  run_root tee /etc/apt/sources.list.d/debian-nvidia.list >/dev/null <<EOF
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian ${codename} contrib non-free
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian ${codename}-updates contrib non-free
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://security.debian.org/debian-security ${codename}-security contrib non-free
EOF
  apt_update
}

ensure_nvidia_driver_available() {
  apt_update
  if apt_package_has_candidate nvidia-driver; then
    return 0
  fi

  echo "Das Paket 'nvidia-driver' ist aktuell nicht in den APT-Quellen verfuegbar."
  echo "Debian braucht dafuer normalerweise contrib/non-free/non-free-firmware."
  if ask_yes_no "Debian non-free Quellen fuer NVIDIA-Treiber einrichten?" "y"; then
    ensure_debian_nonfree_sources
  else
    return 1
  fi

  if apt_package_has_candidate nvidia-driver; then
    return 0
  fi

  show_nvidia_apt_diagnostics
  return 1
}

install_nvidia_driver() {
  section "NVIDIA-Treiber installieren/pruefen"
  local driver_was_installed="no"
  local modprobe_output

  if detect_nvidia_cuda_ready; then
    echo "NVIDIA-Treiber ist aktiv:"
    nvidia-smi || true
    return 0
  fi

  if ! detect_nvidia_gpu_present; then
    echo "Keine NVIDIA-GPU per lspci erkannt."
    return 1
  fi

  echo "NVIDIA-GPU erkannt, aber nvidia-smi funktioniert noch nicht."
  if nvidia_driver_package_installed; then
    driver_was_installed="yes"
  fi

  if ! ensure_nvidia_driver_available; then
    echo "NVIDIA-Treiberpakete sind nicht verfuegbar. Installiere Treiber manuell oder pruefe APT-Quellen."
    return 1
  fi

  apt_install linux-headers-amd64 nvidia-driver
  if apt_package_has_candidate firmware-misc-nonfree; then
    apt_install firmware-misc-nonfree
  else
    echo "Hinweis: firmware-misc-nonfree ist nicht verfuegbar. Fahre ohne dieses Paket fort."
  fi
  if apt_package_has_candidate nvidia-smi; then
    apt_install nvidia-smi
  fi
  set +e
  modprobe_output="$(run_root modprobe nvidia 2>&1)"
  set -e
  if [[ -n "${modprobe_output}" ]]; then
    echo "modprobe nvidia Ausgabe:"
    echo "${modprobe_output}"
  fi

  if detect_nvidia_cuda_ready; then
    echo "NVIDIA-Treiber ist jetzt aktiv."
    nvidia-smi || true
    return 0
  fi

  show_nvidia_runtime_diagnostics

  if nvidia_blackwell_gpu_present || nvidia_kernel_log_reports_unsupported_gpu; then
    echo "Die erkannte GPU ist sehr wahrscheinlich neuer als der Debian-Treiber 550."
    echo "Bei RTX PRO 6000 Blackwell/GB202 braucht es einen neueren NVIDIA-Treiber."
    echo "Bevorzugt wird ein 570+/Open-Kernelmodul-Paket, falls es in APT verfuegbar ist."
    if install_nvidia_preferred_apt_driver; then
      return 0
    fi
    if install_nvidia_official_runfile_driver; then
      return 0
    fi
    echo "Bleibe fuer diesen Lauf bei CPU-Fallback."
    echo "Falls der Runfile-Installer vorbereitet wurde, fuehre danach die angezeigten TTY/SSH-Schritte aus."
    NVIDIA_DRIVER_REBOOT_REQUIRED="no"
    return 0
  fi

  if [[ "${driver_was_installed}" == "yes" ]]; then
    echo "NVIDIA-Treiberpakete waren bereits installiert, aber der Treiber ist weiterhin nicht aktiv."
    echo "Noch ein weiterer Neustart loest das wahrscheinlich nicht."
    echo "Pruefe besonders Secure Boot, DKMS-Fehler und ob nouveau geladen ist."
    NVIDIA_DRIVER_REBOOT_REQUIRED="no"
    return 0
  fi

  NVIDIA_DRIVER_REBOOT_REQUIRED="yes"
  echo "NVIDIA-Treiber wurde gerade installiert, ist aber noch nicht aktiv."
  echo "Ein Neustart ist jetzt sinnvoll. Wenn es danach wieder passiert, zeigt das Skript die Diagnose statt erneut nur Neustart zu verlangen."
  return 0
}

reinstall_torch() {
  run_user "${COMFY_VENV}/bin/pip" uninstall -y torch torchvision torchaudio || true
  run_user "${COMFY_VENV}/bin/pip" install "$@"
}

torch_cuda_available() {
  [[ -x "${COMFY_VENV}/bin/python" ]] || return 1
  run_user "${COMFY_VENV}/bin/python" -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" >/dev/null 2>&1
}

comfy_args_have_cpu() {
  [[ " ${COMFY_EXTRA_ARGS} " == *" --cpu "* ]]
}

remove_comfy_cpu_arg() {
  local normalized
  normalized=" ${COMFY_EXTRA_ARGS} "
  normalized="${normalized// --cpu / }"
  COMFY_EXTRA_ARGS="$(printf '%s\n' "${normalized}" | awk '{$1=$1; print}')"
}

force_comfy_cpu_if_cuda_unavailable() {
  if torch_cuda_available; then
    if comfy_args_have_cpu; then
      remove_comfy_cpu_arg
      echo "PyTorch CUDA ist verfuegbar. Entferne --cpu aus den ComfyUI-Startargumenten."
    fi
    return 0
  fi

  if ! comfy_args_have_cpu; then
    COMFY_EXTRA_ARGS="${COMFY_EXTRA_ARGS:+${COMFY_EXTRA_ARGS} }--cpu"
    echo "PyTorch CUDA ist nicht verfuegbar. Starte ComfyUI automatisch mit --cpu."
  fi
}

wait_for_comfyui() {
  local url="http://127.0.0.1:${COMFY_PORT}/"
  local i

  echo "Warte darauf, dass ComfyUI lokal auf ${url} erreichbar ist..."
  for i in $(seq 1 60); do
    if command_ok curl && curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    if command_ok ss && ss -ltn 2>/dev/null | grep -q ":${COMFY_PORT} "; then
      return 0
    fi
    sleep 1
  done

  return 1
}

install_comfy_torch() {
  local profile="$1"
  if [[ "${profile}" == "auto" ]]; then
    if detect_nvidia_cuda_ready; then
      echo "NVIDIA-Treiber aktiv: installiere PyTorch CUDA."
      profile="nvidia"
    else
      if detect_nvidia_gpu_present; then
        echo "NVIDIA-GPU gefunden, aber kein funktionierender NVIDIA-Treiber/nvidia-smi."
        echo "Auto installiert keinen Treiber. Fuer RTX6000pro/Blackwell bitte Profil 2 waehlen."
        echo "Installiere deshalb PyTorch CPU, damit ComfyUI erstmal startet."
        profile="cpu"
      else
        echo "Keine NVIDIA-GPU erkannt: installiere PyTorch CPU."
        profile="cpu"
      fi
    fi
  fi

  case "${profile}" in
    nvidia_blackwell)
      COMFY_EXTRA_ARGS=""
      install_nvidia_blackwell_driver
      reinstall_torch torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130
      if ! torch_cuda_available; then
        echo "PyTorch CUDA ist fuer Blackwell noch nicht verfuegbar."
        echo "Wenn der Runfile-Installer vorbereitet wurde, fuehre die angezeigten TTY/SSH-Schritte aus."
        echo "ComfyUI wird fuer diesen Lauf mit --cpu vorbereitet."
        COMFY_EXTRA_ARGS="--cpu"
      fi
      ;;
    nvidia_driver)
      COMFY_EXTRA_ARGS=""
      install_nvidia_driver || {
        echo "NVIDIA-Treiber konnte nicht installiert/aktiviert werden."
        return 1
      }
      reinstall_torch torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130
      if ! torch_cuda_available; then
        echo "PyTorch CUDA ist nach der Installation noch nicht verfuegbar."
        echo "ComfyUI wird fuer diesen Lauf mit --cpu vorbereitet."
        COMFY_EXTRA_ARGS="--cpu"
      fi
      ;;
    nvidia)
      COMFY_EXTRA_ARGS=""
      reinstall_torch torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130
      if ! torch_cuda_available; then
        echo "PyTorch CUDA ist nicht verfuegbar. NVIDIA-Treiber pruefen oder Profil 2/4 waehlen."
        echo "Setze fuer diesen Lauf --cpu, damit ComfyUI nicht abstuerzt."
        COMFY_EXTRA_ARGS="--cpu"
      fi
      ;;
    cpu)
      COMFY_EXTRA_ARGS="--cpu"
      reinstall_torch torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
      ;;
    amd)
      COMFY_EXTRA_ARGS=""
      reinstall_torch torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm7.2
      ;;
    intel)
      COMFY_EXTRA_ARGS=""
      reinstall_torch torch torchvision torchaudio --index-url https://download.pytorch.org/whl/xpu
      ;;
    skip)
      echo "PyTorch-Installation uebersprungen."
      ;;
  esac
}

test_comfyui_start() {
  local log_file
  local status
  log_file="$(mktemp)"

  force_comfy_cpu_if_cuda_unavailable
  echo "Teste ComfyUI-Start direkt vor systemd..."
  set +e
  run_user_shell "cd '${COMFY_DIR}' && timeout 30 '${COMFY_VENV}/bin/python' '${COMFY_DIR}/main.py' --listen 127.0.0.1 --port '${COMFY_STARTUP_TEST_PORT}' ${COMFY_EXTRA_ARGS}" >"${log_file}" 2>&1
  status="$?"
  set -e

  if [[ "${status}" -eq 124 ]]; then
    echo "ComfyUI-Starttest OK."
    rm -f "${log_file}"
    return 0
  fi

  echo "ComfyUI-Starttest fehlgeschlagen. Ausgabe:"
  tail -n 120 "${log_file}"
  rm -f "${log_file}"
  return 1
}

install_or_update_comfy_custom_node() {
  local name="$1"
  local repo_url="$2"
  local target_dir="$3"

  run_root install -d -o "${TARGET_USER}" -g "${TARGET_GROUP}" -m 0755 "${COMFY_CUSTOM_NODES_DIR}"

  if [[ -d "${target_dir}/.git" ]]; then
    echo "${name}: aktualisiere ${target_dir}"
    run_user git -C "${target_dir}" pull --ff-only
  elif [[ -e "${target_dir}" ]]; then
    echo "${name}: ${target_dir} existiert, ist aber kein Git-Checkout."
    echo "Bitte sichern/verschieben oder den Ordner manuell entfernen."
    return 1
  else
    echo "${name}: installiere nach ${target_dir}"
    run_user git clone "${repo_url}" "${target_dir}"
  fi

  if [[ -f "${target_dir}/requirements.txt" ]]; then
    run_user_shell "cd '${target_dir}' && '${COMFY_VENV}/bin/pip' install -r requirements.txt"
  fi
}

install_comfy_manager() {
  section "ComfyUI Manager installieren/aktualisieren"
  install_or_update_comfy_custom_node \
    "ComfyUI Manager" \
    "https://github.com/ltdrdata/ComfyUI-Manager.git" \
    "${COMFY_MANAGER_DIR}"
}

install_comfy_crystools() {
  section "ComfyUI Crystools Monitor installieren (old Version install over ComfyUI-Manager from user crystian)"
  install_or_update_comfy_custom_node \
    "ComfyUI Crystools" \
    "https://github.com/crystian/comfyui-crystools.git" \
    "${COMFY_CRYSTOOLS_DIR}"
  echo "Crystools zeigt CPU, RAM, GPU, VRAM, Temperatur und Storage in ComfyUI an."
  echo "GPU/VRAM/Temperatur brauchen einen funktionierenden GPU-Treiber, z.B. nvidia-smi bei NVIDIA."
}

offer_comfy_extensions() {
  section "ComfyUI Zusatzmodule"

  if ask_yes_no "ComfyUI Manager installieren/aktualisieren?" "y"; then
    install_comfy_manager
  fi

  if ask_yes_no "CPU/RAM/GPU/VRAM/Temp Anzeige installieren/aktualisieren? (ComfyUI-Crystools)" "y"; then
    install_comfy_crystools
  fi
}

restart_comfy_service_if_present() {
  if service_exists "${COMFY_SERVICE}"; then
    if ask_yes_no "ComfyUI Service neu starten, damit Zusatzmodule geladen werden?" "y"; then
      echo "Aktualisiere vorhandenen ComfyUI systemd-Service mit aktuellen Startargumenten."
      create_comfy_service_file
      run_root systemctl daemon-reload
      run_root systemctl restart comfyui.service
      if wait_for_comfyui; then
        run_root systemctl status comfyui.service --no-pager || true
        print_comfy_webui_urls
      else
        echo "ComfyUI lauscht nach dem Neustart nicht auf Port ${COMFY_PORT}."
        echo "Logs anzeigen mit:"
        echo "  journalctl -u comfyui.service -n 120 --no-pager"
        run_root systemctl status comfyui.service --no-pager || true
      fi
    fi
  fi
}

create_comfy_home_link() {
  section "ComfyUI Verknuepfung im persoenlichen Ordner"

  if [[ ! -d "${COMFY_DIR}" ]]; then
    echo "ComfyUI-Ordner existiert noch nicht: ${COMFY_DIR}"
    return 1
  fi

  if [[ -e "${COMFY_HOME_LINK}" && ! -L "${COMFY_HOME_LINK}" ]]; then
    echo "Kann Verknuepfung nicht erstellen: ${COMFY_HOME_LINK} existiert bereits und ist kein Symlink."
    echo "Bitte umbenennen/verschieben oder COMFY_HOME_LINK anders setzen."
    return 1
  fi

  run_root ln -sfn "${COMFY_DIR}" "${COMFY_HOME_LINK}"
  run_root chown -h "${TARGET_USER}:${TARGET_GROUP}" "${COMFY_HOME_LINK}" || true
  echo "Verknuepfung: ${COMFY_HOME_LINK} -> ${COMFY_DIR}"
}

remove_comfy_home_link() {
  if [[ -L "${COMFY_HOME_LINK}" ]]; then
    run_root rm -f "${COMFY_HOME_LINK}"
  fi
}

get_user_desktop_dir() {
  local desktop_dir=""

  if command -v xdg-user-dir >/dev/null 2>&1; then
    desktop_dir="$(run_user xdg-user-dir DESKTOP 2>/dev/null || true)"
  fi

  if [[ -z "${desktop_dir}" || "${desktop_dir}" == "${USER_HOME}" || "${desktop_dir}" == *"not found"* ]]; then
    if [[ -d "${USER_HOME}/Desktop" ]]; then
      desktop_dir="${USER_HOME}/Desktop"
    elif [[ -d "${USER_HOME}/Schreibtisch" ]]; then
      desktop_dir="${USER_HOME}/Schreibtisch"
    else
      desktop_dir="${USER_HOME}/Desktop"
    fi
  fi

  echo "${desktop_dir}"
}

create_comfy_desktop_shortcut() {
  local desktop_dir
  local desktop_file
  desktop_dir="$(get_user_desktop_dir)"
  desktop_file="${desktop_dir}/ComfyUI.desktop"

  force_comfy_cpu_if_cuda_unavailable
  section "ComfyUI Desktop-Starter erstellen/aktualisieren"
  run_root install -d -o "${TARGET_USER}" -g "${TARGET_GROUP}" -m 0755 "${USER_BIN}" "${USER_APPLICATIONS_DIR}" "${desktop_dir}"

  run_root tee "${COMFY_LAUNCHER_SCRIPT}" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

export HOME="${USER_HOME}"
export USER="${TARGET_USER}"
export LOGNAME="${TARGET_USER}"
export PATH="${COMFY_VENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOCAL_URL="http://127.0.0.1:${COMFY_PORT}/"
LAN_IP="\$(hostname -I 2>/dev/null | awk '{print \$1}')"
LAN_URL="http://\${LAN_IP:-127.0.0.1}:${COMFY_PORT}/"

open_comfyui() {
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "\${LOCAL_URL}" >/dev/null 2>&1 || true
  fi
}

if command -v curl >/dev/null 2>&1 && curl -fsS "\${LOCAL_URL}" >/dev/null 2>&1; then
  echo "ComfyUI laeuft bereits."
  echo "Lokal:    \${LOCAL_URL}"
  echo "Netzwerk: \${LAN_URL}"
  echo "Browser-Adresse roh kopieren, ohne eckige Klammern oder Markdown."
  open_comfyui
  exit 0
fi

echo "Starte ComfyUI..."
echo "Lokal:    \${LOCAL_URL}"
echo "Netzwerk: \${LAN_URL}"
echo "Browser-Adresse roh kopieren, ohne eckige Klammern oder Markdown."
echo
echo "Dieses Terminal offen lassen, solange ComfyUI laufen soll."

if command -v xdg-open >/dev/null 2>&1; then
  (sleep 8; xdg-open "\${LOCAL_URL}" >/dev/null 2>&1 || true) &
fi

cd "${COMFY_DIR}"
exec "${COMFY_VENV}/bin/python" "${COMFY_DIR}/main.py" --listen "${COMFY_HOST}" --port "${COMFY_PORT}" ${COMFY_EXTRA_ARGS}
EOF

  run_root chown "${TARGET_USER}:${TARGET_GROUP}" "${COMFY_LAUNCHER_SCRIPT}"
  run_root chmod 0755 "${COMFY_LAUNCHER_SCRIPT}"

  run_root tee "${COMFY_APPLICATION_FILE}" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=ComfyUI
Comment=Start ComfyUI WebUI
Exec=${COMFY_LAUNCHER_SCRIPT}
Icon=applications-graphics
Terminal=true
Categories=Graphics;Development;
StartupNotify=true
EOF

  run_root cp "${COMFY_APPLICATION_FILE}" "${desktop_file}"
  run_root chown "${TARGET_USER}:${TARGET_GROUP}" "${COMFY_APPLICATION_FILE}" "${desktop_file}"
  run_root chmod 0755 "${COMFY_APPLICATION_FILE}" "${desktop_file}"

  if command_ok update-desktop-database; then
    run_root update-desktop-database "${USER_APPLICATIONS_DIR}" || true
  fi

  echo "Desktop-Starter: ${desktop_file}"
  echo "App-Menue-Starter: ${COMFY_APPLICATION_FILE}"
}

create_comfy_service_file() {
  force_comfy_cpu_if_cuda_unavailable
  run_root tee "${COMFY_SERVICE}" >/dev/null <<EOF
[Unit]
Description=ComfyUI Web Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
Group=${TARGET_GROUP}
WorkingDirectory=${COMFY_DIR}
Environment="HOME=${USER_HOME}"
Environment="USER=${TARGET_USER}"
Environment="LOGNAME=${TARGET_USER}"
Environment="PATH=${COMFY_VENV}/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=${COMFY_VENV}/bin/python ${COMFY_DIR}/main.py --listen ${COMFY_HOST} --port ${COMFY_PORT} ${COMFY_EXTRA_ARGS}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

create_comfy_service() {
  create_comfy_service_file

  run_root systemctl daemon-reload
  run_root systemctl enable comfyui.service
  run_root systemctl restart comfyui.service
  if wait_for_comfyui; then
    run_root systemctl status comfyui.service --no-pager || true
    print_comfy_webui_urls
  else
    echo "ComfyUI lauscht nach 60 Sekunden nicht auf Port ${COMFY_PORT}."
    echo "Logs anzeigen mit:"
    echo "  journalctl -u comfyui.service -n 120 --no-pager"
    run_root systemctl status comfyui.service --no-pager || true
  fi
}

remove_comfy_service() {
  run_root systemctl disable --now comfyui.service 2>/dev/null || true
  run_root rm -f "${COMFY_SERVICE}"
  run_root systemctl daemon-reload
}

remove_comfy_desktop_shortcut() {
  local desktop_dir
  local desktop_file
  desktop_dir="$(get_user_desktop_dir)"
  desktop_file="${desktop_dir}/ComfyUI.desktop"

  run_root rm -f "${COMFY_APPLICATION_FILE}" "${desktop_file}" "${COMFY_LAUNCHER_SCRIPT}"
  if command_ok update-desktop-database; then
    run_root update-desktop-database "${USER_APPLICATIONS_DIR}" || true
  fi
}

install_comfyui() {
  section "ComfyUI installieren/reparieren"
  apt_install curl git python3 python3-venv python3-pip python3-dev build-essential ffmpeg libgl1 libglib2.0-0 iproute2 pciutils xdg-utils xdg-user-dirs dkms mokutil
  run_root install -d -o "${TARGET_USER}" -g "${TARGET_GROUP}" -m 0755 "${AI_BASE_DIR}"

  if [[ -d "${COMFY_DIR}/.git" ]]; then
    run_user git -C "${COMFY_DIR}" pull --ff-only
  elif [[ -e "${COMFY_DIR}" ]]; then
    echo "${COMFY_DIR} existiert, ist aber kein Git-Checkout."
    echo "Bitte sichern/verschieben oder COMFY_DIR anders setzen."
    return 1
  else
    run_user git clone https://github.com/Comfy-Org/ComfyUI.git "${COMFY_DIR}"
  fi

  run_user python3 -m venv "${COMFY_VENV}"
  run_user "${COMFY_VENV}/bin/pip" install --upgrade pip wheel setuptools
  local torch_profile
  torch_profile="$(choose_torch_install)"
  install_comfy_torch "${torch_profile}"
  run_user_shell "cd '${COMFY_DIR}' && '${COMFY_VENV}/bin/pip' install -r requirements.txt"

  if [[ "${NVIDIA_DRIVER_REBOOT_REQUIRED}" == "yes" ]]; then
    force_comfy_cpu_if_cuda_unavailable
    create_comfy_home_link || true
    create_comfy_desktop_shortcut
    echo
    echo "NVIDIA-Treiber wurde installiert, braucht aber einen Neustart."
    echo "Bitte ausfuehren:"
    echo "  systemctl reboot"
    echo "Danach dieses Skript erneut starten und ComfyUI mit Profil 2 reparieren/aktualisieren."
    echo "ComfyUI-Service wird jetzt noch nicht gestartet."
    return 0
  fi

  test_comfyui_start || {
    echo "ComfyUI wurde installiert, startet aber noch nicht sauber."
    echo "Pruefe die Fehlermeldung oben. Oft hilft: ComfyUI reparieren und PyTorch-Profil NVIDIA CUDA oder CPU waehlen."
    return 1
  }

  offer_comfy_extensions
  test_comfyui_start || {
    echo "ComfyUI startet nach Installation der Zusatzmodule nicht sauber."
    echo "Pruefe die Fehlermeldung oben. Ein Custom Node kann inkompatibel sein."
    return 1
  }

  create_comfy_home_link || true
  create_comfy_desktop_shortcut

  local service_created="no"
  if ask_yes_no "ComfyUI als Website/Server-Autostart einrichten/aktualisieren?" "y"; then
    create_comfy_service
    service_created="yes"
  fi

  if [[ "${service_created}" != "yes" ]]; then
    restart_comfy_service_if_present
  fi
}

uninstall_comfyui() {
  section "ComfyUI deinstallieren"
  remove_comfy_service
  remove_comfy_desktop_shortcut
  remove_comfy_home_link
  safe_rm_dir "${COMFY_DIR}" "ComfyUI Installation"
}

restart_systemd_logind() {
  if command_ok systemctl; then
    echo "Starte systemd-logind neu, damit die Einstellung sofort gilt..."
    run_root systemctl restart systemd-logind
    run_root systemctl restart gdm3
  else
    echo "systemctl nicht gefunden. Bitte systemd-logind manuell neu starten oder rebooten."
  fi
}

disable_global_power_saving() {
  section "Energiesparfunktionen deaktivieren (Global-Login-Screen)"
  echo "Diese Einstellung wirkt systemweit ueber systemd-logind, auch am Login-Screen."
  echo "Datei: ${LOGIND_NO_SLEEP_CONF}"
  echo
  if ! ask_yes_no "Energiesparfunktionen global deaktivieren?" "y"; then
    echo "Energiesparen: unveraendert."
    return 0
  fi

  run_root systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
  run_root systemctl daemon-reload
  run_root mkdir -p "$(dirname "${LOGIND_NO_SLEEP_CONF}")"
  run_root tee "${LOGIND_NO_SLEEP_CONF}" >/dev/null <<'EOF'
[Login]
IdleAction=ignore
IdleActionSec=0
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  restart_systemd_logind
  echo "Energiesparfunktionen am Login-Screen sind deaktiviert."
}

enable_global_power_saving() {
  section "Energiesparfunktionen aktivieren (Global-Login-Screen)"
  echo "Entferne die vom Skript erstellte Drop-in-Datei:"
  echo "  ${LOGIND_NO_SLEEP_CONF}"
  echo

  if [[ ! -f "${LOGIND_NO_SLEEP_CONF}" ]]; then
    echo "Keine no-sleep-Konfiguration gefunden. Energiesparen ist bereits aktiv/Standard."
    return 0
  fi

  if ! ask_yes_no "Energiesparfunktionen wieder aktivieren?" "y"; then
    echo "Energiesparen: unveraendert."
    return 0
  fi
  run_root systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
  run_root systemctl daemon-reload

  run_root rm -f "${LOGIND_NO_SLEEP_CONF}"
  restart_systemd_logind
  echo "Energiesparfunktionen sind wieder auf Systemstandard."
}

manage_power_saving() {
  local choice
  section "Energiesparfunktionen Aktivieren/Deaktivieren (Global-Login-Screen)"
  echo "Status: $(power_saving_status)"
  echo "Wichtig: Diese Option braucht root/su, weil /etc/systemd/logind.conf.d geaendert wird."
  echo
  echo "i) Energiesparfunktionen deaktivieren"
  echo "r) Energiesparfunktionen Systemstandard wiederherstellen"
  echo "s) ueberspringen"
  read -r -p "Auswahl [s]: " choice
  choice="${choice:-s}"

  case "${choice}" in
    i) disable_global_power_saving ;;
    r) enable_global_power_saving ;;
    s|skip) echo "Energiesparen: uebersprungen." ;;
    *) echo "Ungueltige Auswahl, Energiesparen uebersprungen." ;;
  esac
}

set_dash_to_panel_gsettings() {
  local uuid="$1"
  local action="$2"

  if ! command_ok dbus-run-session || ! command_ok gsettings || ! command_ok python3; then
    return 1
  fi

  run_user dbus-run-session -- python3 -c '
import ast
import subprocess
import sys

uuid = sys.argv[1]
action = sys.argv[2]
schema = "org.gnome.shell"

def get_list(key):
    try:
        raw = subprocess.check_output(["gsettings", "get", schema, key], text=True).strip()
        items = ast.literal_eval(raw)
    except Exception:
        items = []

    if not isinstance(items, list):
        items = []
    return items

enabled = get_list("enabled-extensions")
disabled = get_list("disabled-extensions")

if action == "enable":
    subprocess.call(["gsettings", "set", schema, "disable-user-extensions", "false"])
    if uuid not in enabled:
        enabled.append(uuid)
    disabled = [item for item in disabled if item != uuid]
elif action == "disable":
    enabled = [item for item in enabled if item != uuid]
    if uuid not in disabled:
        disabled.append(uuid)

subprocess.check_call(["gsettings", "set", schema, "enabled-extensions", str(enabled)])
subprocess.call(["gsettings", "set", schema, "disabled-extensions", str(disabled)])
' "${uuid}" "${action}"
}

set_dash_to_panel_live() {
  local uuid="$1"
  local action="$2"
  local uid
  local runtime_dir
  local bus

  if ! command_ok gnome-extensions; then
    return 1
  fi

  uid="$(id -u "${TARGET_USER}")"
  runtime_dir="/run/user/${uid}"
  bus="${runtime_dir}/bus"
  if [[ ! -S "${bus}" ]]; then
    return 1
  fi

  if [[ "${action}" == "enable" ]] && command_ok gsettings; then
    run_user env \
      XDG_RUNTIME_DIR="${runtime_dir}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
      DISPLAY="${DISPLAY:-:0}" \
      gsettings set org.gnome.shell disable-user-extensions false || true
  fi

  run_user env \
    XDG_RUNTIME_DIR="${runtime_dir}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
    DISPLAY="${DISPLAY:-:0}" \
    gnome-extensions "${action}" "${uuid}"
}

enable_windows_taskbar() {
  local uuid
  section "Windows-artige Taskleiste aktivieren"

  echo "Installiere Dash to Panel und GNOME-Erweiterungen-App."
  apt_install gnome-shell-extension-dash-to-panel gnome-shell-extension-prefs

  uuid="$(dash_to_panel_uuid)"
  echo "Dash-to-Panel UUID: ${uuid}"

  if set_dash_to_panel_live "${uuid}" enable || set_dash_to_panel_gsettings "${uuid}" enable; then
    echo "Dash to Panel wurde fuer Benutzer '${TARGET_USER}' aktiviert."
  else
    echo "Dash to Panel wurde installiert, konnte aber nicht automatisch aktiviert werden."
    echo "Melde dich als '${TARGET_USER}' am Desktop an und starte:"
    echo "  gnome-extensions-app"
    echo "Dort 'Dash to Panel' aktivieren."
  fi

  echo "Falls die Taskleiste nicht sofort sichtbar ist: einmal abmelden/anmelden."
}

disable_windows_taskbar() {
  local uuid
  section "Windows-artige Taskleiste deaktivieren"

  uuid="$(dash_to_panel_uuid)"
  echo "Dash-to-Panel UUID: ${uuid}"

  set_dash_to_panel_live "${uuid}" disable || set_dash_to_panel_gsettings "${uuid}" disable || true

  if ask_yes_no "Dash to Panel und GNOME-Erweiterungen-App per apt entfernen?" "y"; then
    apt_remove gnome-shell-extension-dash-to-panel gnome-shell-extension-prefs || true
    echo "Pakete entfernt: gnome-shell-extension-dash-to-panel gnome-shell-extension-prefs"
  else
    echo "Pakete bleiben installiert, Dash to Panel wurde nur in GNOME deaktiviert."
  fi

  echo "Falls die Standard-Leiste nicht sofort zurueck ist: einmal abmelden/anmelden."
}

manage_windows_taskbar() {
  local choice
  section "Windows-artige Taskleiste Installieren?"
  echo "Status: $(dash_to_panel_status)"
  echo "Installiert wird: gnome-shell-extension-dash-to-panel gnome-shell-extension-prefs"
  echo "Zielbenutzer: ${TARGET_USER}"
  echo
  echo "i) Windows-artige Taskleiste installieren/aktivieren"
  echo "r) Windows-artige Taskleiste deaktivieren/entfernen"
  echo "s) ueberspringen"
  read -r -p "Auswahl [s]: " choice
  choice="${choice:-s}"

  case "${choice}" in
    i) enable_windows_taskbar ;;
    r) disable_windows_taskbar ;;
    s|skip) echo "Windows-artige Taskleiste: uebersprungen." ;;
    *) echo "Ungueltige Auswahl, Windows-artige Taskleiste uebersprungen." ;;
  esac
}

install_gnome_extension_from_extensions_site() {
  local search="$1"
  local preferred_uuid="$2"
  local tmp_dir
  local info_file
  local uuid
  local download_url
  local target_dir

  apt_install ca-certificates curl unzip python3 gnome-shell-extension-prefs

  tmp_dir="$(mktemp -d)"
  info_file="${tmp_dir}/extension-info.txt"

  if ! python3 - "${search}" "${preferred_uuid}" >"${info_file}" <<'PY'
import json
import re
import sys
import urllib.parse
import urllib.request
import zipfile
from io import BytesIO

search = sys.argv[1]
preferred_uuid = sys.argv[2]

def fetch_json(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))

def shell_versions():
    versions = []
    try:
        import subprocess
        out = subprocess.check_output(["gnome-shell", "--version"], text=True).strip()
        match = re.search(r"(\d+(?:\.\d+)*)", out)
        if match:
            full = match.group(1)
            versions.append(full)
            versions.append(full.split(".", 1)[0])
    except Exception:
        pass
    versions.extend(["48", "47", "46", "45", "44", "43"])
    result = []
    for version in versions:
        if version and version not in result:
            result.append(version)
    return result

def fetch_extension_candidates(searches):
    seen = set()
    result = []
    for term in searches:
        query_url = "https://extensions.gnome.org/extension-query/?" + urllib.parse.urlencode({"search": term})
        try:
            data = fetch_json(query_url)
        except Exception:
            continue
        for ext in data.get("extensions", []):
            uuid = ext.get("uuid")
            if uuid and uuid not in seen:
                seen.add(uuid)
                result.append(ext)
    return result

extensions = fetch_extension_candidates([search, "net speed", "network speed", "netspeed"])
if not extensions:
    raise SystemExit(f"Keine GNOME-Erweiterung gefunden fuer Suche: {search}")

def score(ext):
    name = (ext.get("name") or "").lower()
    uuid = (ext.get("uuid") or "").lower()
    if preferred_uuid and ext.get("uuid") == preferred_uuid:
        return 100
    if name == "netspeed" or uuid == "netspeed@hedayaty.gmail.com":
        return 90
    if "netspeed" in name or "netspeed" in uuid:
        return 80
    if "net speed" in name or "net-speed" in uuid:
        return 70
    return 10

extensions.sort(key=score, reverse=True)

last_error = None

def zip_looks_compatible(download_url, shell_version):
    try:
        blob = urllib.request.urlopen(download_url, timeout=30).read()
        with zipfile.ZipFile(BytesIO(blob)) as zf:
            metadata = json.loads(zf.read("metadata.json").decode("utf-8"))
            shell_versions = [str(v) for v in metadata.get("shell-version", [])]
            if shell_versions and shell_version not in shell_versions and shell_version.split(".", 1)[0] not in shell_versions:
                return False
            for name in zf.namelist():
                if name.endswith(".js"):
                    text = zf.read(name).decode("utf-8", errors="ignore")
                    if "imports.misc.extensionUtils" in text:
                        return False
        return True
    except Exception as exc:
        global last_error
        last_error = exc
        return False

for chosen in extensions:
    uuid = chosen.get("uuid")
    if not uuid:
        continue
    for shell_version in shell_versions():
        url = "https://extensions.gnome.org/extension-info/?" + urllib.parse.urlencode({
            "uuid": uuid,
            "shell_version": shell_version,
        })
        try:
            info = fetch_json(url)
        except Exception as exc:
            last_error = exc
            continue
        download_url = info.get("download_url")
        if not download_url:
            continue
        if download_url.startswith("/"):
            download_url = "https://extensions.gnome.org" + download_url
        if zip_looks_compatible(download_url, shell_version):
            print(uuid)
            print(download_url)
            raise SystemExit(0)

raise SystemExit(f"Keine kompatible moderne NetSpeed/Network-Speed-Erweiterung gefunden. Letzter Fehler: {last_error}")
PY
  then
    echo "Download-Informationen fuer GNOME-Erweiterung konnten nicht ermittelt werden."
    cat "${info_file}" 2>/dev/null || true
    rm -rf "${tmp_dir}"
    return 1
  fi

  uuid="$(sed -n '1p' "${info_file}")"
  download_url="$(sed -n '2p' "${info_file}")"
  if [[ -z "${uuid}" || -z "${download_url}" ]]; then
    echo "Ungueltige Download-Informationen fuer GNOME-Erweiterung."
    cat "${info_file}" 2>/dev/null || true
    rm -rf "${tmp_dir}"
    return 1
  fi

  echo "GNOME-Erweiterung: ${uuid}"
  echo "Download: ${download_url}"

  run_root curl -fL "${download_url}" -o "${tmp_dir}/extension.zip"
  target_dir="/usr/share/gnome-shell/extensions/${uuid}"
  run_root rm -rf "${target_dir}"
  run_root install -d -m 0755 "${target_dir}"
  run_root unzip -q "${tmp_dir}/extension.zip" -d "${target_dir}"
  run_root chmod -R a+rX "${target_dir}"
  if [[ -d "${target_dir}/schemas" ]] && command_ok glib-compile-schemas; then
    run_root glib-compile-schemas "${target_dir}/schemas" || true
  fi

  NETSPEED_UUID="${uuid}"
  rm -rf "${tmp_dir}"
}

enable_netspeed_indicator() {
  local uuid
  section "NetSpeed Anzeige aktivieren"

  echo "Installiere NetSpeed GNOME-Erweiterung und GNOME-Erweiterungen-App."
  apt_install gnome-shell-extension-prefs
  if apt_package_has_candidate gnome-shell-extension-netspeed; then
    apt_install gnome-shell-extension-netspeed
  else
    echo "Paket gnome-shell-extension-netspeed ist in den aktuellen APT-Quellen nicht verfuegbar."
    echo "Installiere NetSpeed stattdessen ueber extensions.gnome.org."
    set_dash_to_panel_live "${NETSPEED_UUID}" disable || set_dash_to_panel_gsettings "${NETSPEED_UUID}" disable || true
    install_gnome_extension_from_extensions_site "${NETSPEED_SEARCH}" "${NETSPEED_UUID}" || return 1
  fi

  uuid="$(netspeed_uuid)"
  echo "NetSpeed UUID: ${uuid}"

  if set_dash_to_panel_live "${uuid}" enable || set_dash_to_panel_gsettings "${uuid}" enable; then
    echo "NetSpeed wurde fuer Benutzer '${TARGET_USER}' aktiviert."
  else
    echo "NetSpeed wurde installiert, konnte aber nicht automatisch aktiviert werden."
    echo "Melde dich als '${TARGET_USER}' am Desktop an und starte:"
    echo "  gnome-extensions-app"
    echo "Dort 'NetSpeed' aktivieren."
  fi

  echo "Falls die Anzeige nicht sofort sichtbar ist: einmal abmelden/anmelden."
}

disable_netspeed_indicator() {
  local uuid
  local target_dir
  local dir
  section "NetSpeed Anzeige deaktivieren"

  uuid="$(netspeed_uuid)"
  echo "NetSpeed UUID: ${uuid}"

  set_dash_to_panel_live "${uuid}" disable || set_dash_to_panel_gsettings "${uuid}" disable || true

  if ask_yes_no "NetSpeed GNOME-Erweiterung per apt entfernen?" "y"; then
    apt_remove gnome-shell-extension-netspeed || true
    echo "Paket entfernt: gnome-shell-extension-netspeed"
  else
    echo "Paket bleibt installiert, NetSpeed wurde nur in GNOME deaktiviert."
  fi

  target_dir="/usr/share/gnome-shell/extensions/${uuid}"
  if [[ -d "${target_dir}" ]] && ask_yes_no "Manuell installierte NetSpeed-Erweiterung '${target_dir}' entfernen?" "y"; then
    run_root rm -rf --one-file-system "${target_dir}"
    echo "NetSpeed-Erweiterungsordner entfernt: ${target_dir}"
  fi

  for dir in /usr/share/gnome-shell/extensions/*netspeed* /usr/share/gnome-shell/extensions/*net-speed*; do
    if [[ -d "${dir}" && "${dir}" != "${target_dir}" ]] && ask_yes_no "Weitere NetSpeed-Erweiterung '${dir}' entfernen?" "y"; then
      run_root rm -rf --one-file-system "${dir}"
      echo "NetSpeed-Erweiterungsordner entfernt: ${dir}"
    fi
  done

  echo "Falls die Anzeige nicht sofort verschwindet: einmal abmelden/anmelden."
}

manage_netspeed_indicator() {
  local choice
  section "NetSpeed Anzeige Installieren?"
  echo "Status: $(netspeed_status)"
  echo "Installiert wird: gnome-shell-extension-netspeed gnome-shell-extension-prefs"
  echo "Zielbenutzer: ${TARGET_USER}"
  echo
  echo "i) NetSpeed Anzeige installieren/aktivieren"
  echo "r) NetSpeed Anzeige deaktivieren/entfernen"
  echo "s) ueberspringen"
  read -r -p "Auswahl [s]: " choice
  choice="${choice:-s}"

  case "${choice}" in
    i) enable_netspeed_indicator ;;
    r) disable_netspeed_indicator ;;
    s|skip) echo "NetSpeed Anzeige: uebersprungen." ;;
    *) echo "Ungueltige Auswahl, NetSpeed Anzeige uebersprungen." ;;
  esac
}

handle_app() {
  local name="$1"
  local installed="$2"
  local install_fn="$3"
  local uninstall_fn="$4"

  choose_action "${name}" "${installed}"
  case "${ACTION}" in
    install|repair) "${install_fn}" ;;
    uninstall) "${uninstall_fn}" ;;
    skip) echo "${name}: uebersprungen." ;;
  esac
}

main() {
  need_sudo
  configure_app_name
  check_operating_system
  check_nvidia_post_reboot_marker
  offer_update_upgrade
  scan_status

  section "Installieren / Reparieren / Deinstallieren"
  handle_app "curl" "$(command_ok curl && echo yes || echo no)" install_curl uninstall_curl
  handle_app "nano" "$(command_ok nano && echo yes || echo no)" install_nano uninstall_nano
  handle_app "LibreOffice" "$(libreoffice_installed && echo yes || echo no)" install_libreoffice uninstall_libreoffice
  handle_app "OpenOffice" "$(openoffice_installed && echo yes || echo no)" install_openoffice uninstall_openoffice
  handle_app "Visual Studio Code" "$(command_ok code && echo yes || echo no)" install_vscode uninstall_vscode
  handle_app "LM Studio" "$(lmstudio_installed && echo yes || echo no)" install_lmstudio uninstall_lmstudio
  handle_app "Docker und Docker Compose" "$(command_ok docker && docker compose version >/dev/null 2>&1 && echo yes || echo no)" install_docker uninstall_docker
  handle_app "ComfyUI" "$([[ -d "${COMFY_DIR}" ]] && echo yes || echo no)" install_comfyui uninstall_comfyui
  manage_power_saving
  manage_windows_taskbar
  manage_netspeed_indicator

  section "Fertig"
  scan_status
  echo "Start: chmod +x ./ai_desktop_server.sh && ./ai_desktop_server.sh"
}

main "$@"
