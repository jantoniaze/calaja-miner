#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/jantoniaze/calaja-miner.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/calajaminer}"
TMP_DIR="${TMP_DIR:-/tmp/calaja-miner-install}"

USER_CENTRAL_URL="${CENTRAL_URL:-}"
USER_POOL_URL="${POOL_URL:-}"
USER_POOL_USER="${POOL_USER:-}"
USER_POOL_PASS="${POOL_PASS:-}"
USER_LOCATION="${LOCATION:-}"
USER_XMRIG_TOKEN="${XMRIG_TOKEN:-}"
USER_AGENT_INTERVAL="${AGENT_INTERVAL:-}"
USER_THREADS="${THREADS:-}"
USER_DONATE_LEVEL="${DONATE_LEVEL:-}"
USER_CPU_PRIORITY="${CPU_PRIORITY:-}"
USER_HUGE_PAGES="${HUGE_PAGES:-}"

CENTRAL_URL="${CENTRAL_URL:-http://192.168.3.3:5001/api/status}"
POOL_URL="${POOL_URL:-192.168.3.3:3333}"
POOL_USER="${POOL_USER:-ZEPHYR2G2eYc89an5bmrZFBXre8VsAEPk3ak2ZB1kRDrcQ7stCQVAYpeEG52JS5F9XgyQ4eFah5C8b3gFY7WzL3tfSdSfhfnWbR3i}"
POOL_PASS="${POOL_PASS:-}"
LOCATION="${LOCATION:-home}"
XMRIG_TOKEN="${XMRIG_TOKEN:-calaja}"
AGENT_INTERVAL="${AGENT_INTERVAL:-3}"
THREADS="${THREADS:-}"
DONATE_LEVEL="${DONATE_LEVEL:-1}"
CPU_PRIORITY="${CPU_PRIORITY:-5}"
HUGE_PAGES="${HUGE_PAGES:-true}"
FRESH_INSTALL="${FRESH_INSTALL:-}"
BACKUP_OLD="${BACKUP_OLD:-true}"
INSTALL_MODE="${INSTALL_MODE:-auto}"
PRESERVE_CONFIG="${PRESERVE_CONFIG:-true}"
FORCE_XMRIG_BUILD="${FORCE_XMRIG_BUILD:-false}"

EXISTING_RIG_ID=""
EXISTING_WORKER=""
EXISTING_LOCATION=""
EXISTING_CENTRAL_URL=""
EXISTING_XMRIG_TOKEN=""
EXISTING_AGENT_INTERVAL=""
EXISTING_POOL_URL=""
EXISTING_POOL_USER=""
EXISTING_POOL_PASS=""
EXISTING_THREADS=""
EXISTING_DONATE_LEVEL=""
EXISTING_CPU_PRIORITY=""
EXISTING_HUGE_PAGES=""

log() {
    printf '[calaja-install] %s\n' "$*"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Execute como root: sudo bash $0" >&2
        exit 1
    fi
}

is_interactive() {
    [ -t 0 ] && [ -z "${CI:-}" ]
}

service_exists() {
    systemctl list-unit-files "$1" >/dev/null 2>&1 || systemctl status "$1" >/dev/null 2>&1
}

service_active() {
    systemctl is-active --quiet "$1" >/dev/null 2>&1
}

detect_existing_install() {
    local has_existing="false"

    if [ -d "$INSTALL_DIR" ] || service_exists xmrig.service || service_exists calaja-agent.service || service_active xmrig || service_active calaja-agent; then
        has_existing="true"
    fi

    echo "$has_existing"
}

decide_install_mode() {
    local has_existing
    has_existing="$(detect_existing_install)"

    if [ "$has_existing" != "true" ]; then
        INSTALL_MODE="clean"
        log "Nenhuma instalacao anterior detectada. Modo: clean."
        return
    fi

    log "Instalacao existente detectada."
    [ -d "$INSTALL_DIR" ] && log "Diretorio existente: $INSTALL_DIR"
    service_exists xmrig.service && log "Service encontrado: xmrig.service"
    service_exists calaja-agent.service && log "Service encontrado: calaja-agent.service"
    service_active xmrig && log "Service ativo: xmrig"
    service_active calaja-agent && log "Service ativo: calaja-agent"

    case "${FRESH_INSTALL,,}" in
        true|yes|y|1)
            INSTALL_MODE="clean"
            log "FRESH_INSTALL=true definido. Modo: clean."
            return
            ;;
        false|no|n|0)
            echo "Instalacao cancelada: FRESH_INSTALL=false e ja existe instalacao anterior." >&2
            exit 1
            ;;
    esac

    case "${INSTALL_MODE,,}" in
        auto|"")
            INSTALL_MODE="update"
            log "Modo automatico: update."
            return
            ;;
        update|upgrade)
            INSTALL_MODE="update"
            log "Modo: update."
            return
            ;;
        clean|fresh|reinstall)
            INSTALL_MODE="clean"
            log "Modo: clean."
            return
            ;;
        cancel|false|no|n|0)
            echo "Instalacao cancelada: INSTALL_MODE=cancel." >&2
            exit 1
            ;;
    esac

    if is_interactive; then
        printf 'Escolha o modo: atualizar preservando configuracao [U], instalacao limpa [c], cancelar [q]: '
        read -r answer

        case "${answer,,}" in
            ""|u|update|atualizar)
                INSTALL_MODE="update"
                ;;
            c|clean|fresh|limpa|s|sim)
                INSTALL_MODE="clean"
                ;;
            *)
                echo "Instalacao cancelada pelo usuario."
                exit 1
                ;;
        esac
    else
        cat >&2 <<EOF
INSTALL_MODE invalido: $INSTALL_MODE
Use uma destas opcoes:

  sudo env INSTALL_MODE=update bash /tmp/install-calaja-miner.sh
  sudo env INSTALL_MODE=clean bash /tmp/install-calaja-miner.sh

Compatibilidade antiga:

  sudo env FRESH_INSTALL=true bash /tmp/install-calaja-miner.sh
EOF
        exit 1
    fi
}

detect_suffix() {
    local ip suffix mac
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

    if [ -n "$ip" ]; then
        suffix="$(echo "$ip" | awk -F. '{print $4}')"
    else
        mac="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '00:00:00:00:00:00' | head -n1 | tr -d ':')"
        suffix="$(echo "$mac" | tail -c 7)"
    fi

    if [ -z "${suffix:-}" ]; then
        suffix="$(date +%s)"
    fi

    echo "$suffix"
}

install_packages() {
    log "Instalando dependencias do sistema..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        ca-certificates \
        build-essential \
        cmake \
        curl \
        dmidecode \
        git \
        iproute2 \
        libhwloc-dev \
        libssl-dev \
        libuv1-dev \
        lm-sensors \
        openssh-server \
        pkg-config \
        python3 \
        python3-pip \
        python3-venv \
        rsync
}

fetch_repo() {
    log "Baixando repositorio $REPO_URL ($BRANCH)..."

    rm -rf "$TMP_DIR"

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        git -c "http.extraHeader=Authorization: Bearer $GITHUB_TOKEN" \
            clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP_DIR"
    else
        git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP_DIR"
    fi
}

read_existing_config() {
    if [ "${PRESERVE_CONFIG,,}" == "false" ] || [ ! -d "$INSTALL_DIR" ]; then
        return
    fi

    log "Lendo configuracao atual para preservar rig/worker/pool..."

    while IFS='=' read -r key value; do
        case "$key" in
            rig_id) EXISTING_RIG_ID="$value" ;;
            worker) EXISTING_WORKER="$value" ;;
            location) EXISTING_LOCATION="$value" ;;
            central_url) EXISTING_CENTRAL_URL="$value" ;;
            xmrig_token) EXISTING_XMRIG_TOKEN="$value" ;;
            interval) EXISTING_AGENT_INTERVAL="$value" ;;
            pool_url) EXISTING_POOL_URL="$value" ;;
            pool_user) EXISTING_POOL_USER="$value" ;;
            pool_pass) EXISTING_POOL_PASS="$value" ;;
            threads) EXISTING_THREADS="$value" ;;
            donate_level) EXISTING_DONATE_LEVEL="$value" ;;
            cpu_priority) EXISTING_CPU_PRIORITY="$value" ;;
            huge_pages) EXISTING_HUGE_PAGES="$value" ;;
        esac
    done < <(python3 - "$INSTALL_DIR" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])

def load(path):
    try:
        with path.open() as f:
            return json.load(f)
    except Exception:
        return {}

agent = load(root / "agent" / "config.json")
xmrig = load(root / "config.json")
pool = (xmrig.get("pools") or [{}])[0] if isinstance(xmrig.get("pools"), list) else {}
cpu = xmrig.get("cpu") or {}

values = {
    "rig_id": agent.get("rig_id"),
    "worker": agent.get("worker"),
    "location": agent.get("location"),
    "central_url": agent.get("central_url"),
    "xmrig_token": agent.get("xmrig_token"),
    "interval": agent.get("interval"),
    "pool_url": pool.get("url"),
    "pool_user": pool.get("user"),
    "pool_pass": pool.get("pass"),
    "threads": len(cpu.get("rx") or []) if isinstance(cpu.get("rx"), list) else None,
    "donate_level": xmrig.get("donate-level"),
    "cpu_priority": cpu.get("priority"),
    "huge_pages": cpu.get("huge-pages"),
}

for key, value in values.items():
    if value is not None and value != "":
        print(f"{key}={value}")
PY
)
}

install_files() {
    log "Instalando arquivos em $INSTALL_DIR..."

    if [ -d "$INSTALL_DIR" ]; then
        if [ "${BACKUP_OLD,,}" != "false" ]; then
            local backup
            backup="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
            log "Backup do diretorio existente: $backup"
            cp -a "$INSTALL_DIR" "$backup"
        fi

        if [ "${INSTALL_MODE,,}" == "clean" ]; then
            log "Removendo arquivos antigos de $INSTALL_DIR..."
            rm -rf "$INSTALL_DIR"
        else
            log "Atualizando arquivos existentes em $INSTALL_DIR..."
        fi
    fi

    mkdir -p "$INSTALL_DIR"

    rsync -a --delete \
        --exclude 'agent/venv/' \
        --exclude 'xmrig/build/' \
        --exclude 'logs/' \
        --exclude '.firstboot_done' \
        "$TMP_DIR/opt/calajaminer/" "$INSTALL_DIR/"

    mkdir -p "$INSTALL_DIR/logs"

    chmod +x "$INSTALL_DIR/scripts/"*.sh || true
    chmod +x "$INSTALL_DIR/xmrig/build/xmrig" || true
}

stop_old_services() {
    log "Parando services antigos, se existirem..."

    systemctl stop calaja-agent 2>/dev/null || true
    systemctl stop xmrig 2>/dev/null || true
}

remove_old_services() {
    log "Removendo unit files antigos, se existirem..."

    systemctl disable calaja-agent 2>/dev/null || true
    systemctl disable xmrig 2>/dev/null || true
    systemctl disable calaja-firstboot 2>/dev/null || true

    rm -f /etc/systemd/system/calaja-agent.service
    rm -f /etc/systemd/system/xmrig.service
    rm -f /etc/systemd/system/calaja-firstboot.service

    systemctl daemon-reload || true
    systemctl reset-failed || true
}

setup_agent_venv() {
    log "Criando venv do agent..."

    python3 -m venv "$INSTALL_DIR/agent/venv"
    "$INSTALL_DIR/agent/venv/bin/pip" install --upgrade pip
    "$INSTALL_DIR/agent/venv/bin/pip" install -r "$INSTALL_DIR/agent/requirements.txt"
}

build_xmrig_if_needed() {
    local xmrig_bin source_dir build_dir
    xmrig_bin="$INSTALL_DIR/xmrig/build/xmrig"
    source_dir="$INSTALL_DIR/xmrig"
    build_dir="$source_dir/build"

    if [ "${FORCE_XMRIG_BUILD,,}" == "true" ] && [ -d "$build_dir" ]; then
        log "FORCE_XMRIG_BUILD=true. Removendo build antigo do XMRig..."
        rm -rf "$build_dir"
    fi

    if [ -x "$xmrig_bin" ]; then
        log "XMRig ja existe: $xmrig_bin"
        return
    fi

    log "Binario do XMRig nao encontrado. Compilando localmente..."

    if [ ! -f "$source_dir/CMakeLists.txt" ]; then
        echo "Fonte do XMRig nao encontrada em $source_dir" >&2
        exit 1
    fi

    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    cmake -S "$source_dir" -B "$build_dir" \
        -DWITH_HWLOC=ON \
        -DWITH_TLS=ON \
        -DWITH_OPENCL=OFF \
        -DWITH_CUDA=OFF

    cmake --build "$build_dir" --parallel "$(nproc)"
    chmod +x "$xmrig_bin"
}

write_configs() {
    local suffix rig_id worker location central_url xmrig_token agent_interval pool_url pool_user pool_pass threads donate_level cpu_priority huge_pages
    suffix="$(detect_suffix)"
    rig_id="${RIG_ID:-${EXISTING_RIG_ID:-calaja-rig-$suffix}}"
    worker="${WORKER:-${EXISTING_WORKER:-rig$suffix}}"
    location="${USER_LOCATION:-${EXISTING_LOCATION:-$LOCATION}}"
    central_url="${USER_CENTRAL_URL:-${EXISTING_CENTRAL_URL:-$CENTRAL_URL}}"
    xmrig_token="${USER_XMRIG_TOKEN:-${EXISTING_XMRIG_TOKEN:-$XMRIG_TOKEN}}"
    agent_interval="${USER_AGENT_INTERVAL:-${EXISTING_AGENT_INTERVAL:-$AGENT_INTERVAL}}"
    pool_url="${USER_POOL_URL:-${EXISTING_POOL_URL:-$POOL_URL}}"
    pool_user="${USER_POOL_USER:-${EXISTING_POOL_USER:-$POOL_USER}}"
    pool_pass="${USER_POOL_PASS:-${EXISTING_POOL_PASS:-$worker}}"
    threads="${USER_THREADS:-${EXISTING_THREADS:-$(nproc)}}"
    donate_level="${USER_DONATE_LEVEL:-${EXISTING_DONATE_LEVEL:-$DONATE_LEVEL}}"
    cpu_priority="${USER_CPU_PRIORITY:-${EXISTING_CPU_PRIORITY:-$CPU_PRIORITY}}"
    huge_pages="${USER_HUGE_PAGES:-${EXISTING_HUGE_PAGES:-$HUGE_PAGES}}"

    log "Configurando rig_id=$rig_id worker=$worker location=$location"
    log "Central: $central_url"
    log "Pool: $pool_url"

    python3 - "$INSTALL_DIR" "$rig_id" "$worker" "$location" "$central_url" "$xmrig_token" "$agent_interval" "$pool_url" "$pool_user" "$pool_pass" "$threads" "$donate_level" "$cpu_priority" "$huge_pages" <<'PY'
import json
import sys
from pathlib import Path

(
    install_dir,
    rig_id,
    worker,
    location,
    central_url,
    xmrig_token,
    interval,
    pool_url,
    pool_user,
    pool_pass,
    threads,
    donate_level,
    cpu_priority,
    huge_pages,
) = sys.argv[1:]

root = Path(install_dir)
agent_config = root / "agent" / "config.json"
xmrig_config = root / "config.json"

with agent_config.open() as f:
    agent = json.load(f)

agent.update({
    "rig_id": rig_id,
    "worker": worker,
    "location": location,
    "central_url": central_url,
    "xmrig_api": "http://127.0.0.1:16000/2/summary",
    "xmrig_token": xmrig_token,
    "interval": int(interval),
})

with agent_config.open("w") as f:
    json.dump(agent, f, indent=4)
    f.write("\n")

with xmrig_config.open() as f:
    xmrig = json.load(f)

xmrig.setdefault("http", {})
xmrig["http"].update({
    "enabled": True,
    "host": "0.0.0.0",
    "port": 16000,
    "access-token": xmrig_token,
    "restricted": False,
})

xmrig.setdefault("cpu", {})
xmrig["cpu"]["enabled"] = True
xmrig["cpu"]["huge-pages"] = huge_pages.lower() == "true"
xmrig["cpu"]["priority"] = int(cpu_priority)
xmrig["cpu"]["rx"] = list(range(int(threads)))
xmrig["donate-level"] = int(donate_level)

xmrig["pools"] = [{
    "algo": "rx/0",
    "coin": None,
    "url": pool_url,
    "user": pool_user,
    "pass": pool_pass,
    "rig-id": rig_id,
    "nicehash": False,
    "keepalive": True,
    "enabled": True,
    "tls": False,
    "sni": False,
    "tls-fingerprint": None,
    "daemon": False,
    "socks5": None,
    "self-select": None,
    "submit-to-origin": False,
}]

with xmrig_config.open("w") as f:
    json.dump(xmrig, f, indent=4)
    f.write("\n")
PY
}

install_services() {
    log "Instalando services systemd..."

    install -m 644 "$TMP_DIR/systemd/xmrig.service" /etc/systemd/system/xmrig.service
    install -m 644 "$TMP_DIR/systemd/calaja-agent.service" /etc/systemd/system/calaja-agent.service

    if [ -f "$TMP_DIR/systemd/calaja-firstboot.service" ]; then
        install -m 644 "$TMP_DIR/systemd/calaja-firstboot.service" /etc/systemd/system/calaja-firstboot.service
    fi

    systemctl daemon-reload
    systemctl enable xmrig
    systemctl enable calaja-agent
}

tune_system() {
    log "Aplicando ajustes basicos..."

    systemctl enable ssh || true
    systemctl start ssh || true

    if command -v sensors-detect >/dev/null 2>&1; then
        yes "" | sensors-detect --auto >/dev/null 2>&1 || true
    fi
}

start_services() {
    log "Iniciando services..."

    systemctl restart xmrig
    systemctl restart calaja-agent

    sleep 2

    if ! systemctl is-active --quiet xmrig; then
        echo "ERRO: xmrig.service nao iniciou corretamente." >&2
        systemctl --no-pager --full status xmrig --lines 20 >&2 || true
        journalctl -u xmrig --no-pager -n 30 >&2 || true
        exit 1
    fi

    if ! systemctl is-active --quiet calaja-agent; then
        echo "ERRO: calaja-agent.service nao iniciou corretamente." >&2
        systemctl --no-pager --full status calaja-agent --lines 20 >&2 || true
        journalctl -u calaja-agent --no-pager -n 30 >&2 || true
        exit 1
    fi

    systemctl --no-pager --full status xmrig --lines 3 || true
    systemctl --no-pager --full status calaja-agent --lines 3 || true
}

print_summary() {
    local ip final_central
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    final_central="$(python3 - "$INSTALL_DIR/agent/config.json" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("central_url", ""))
except Exception:
    print("")
PY
)"

    cat <<EOF

Instalacao concluida.

Rig IP: ${ip:-unknown}
Agent local: http://${ip:-RIG_IP}:5010/health
XMRig API: http://${ip:-RIG_IP}:16000/2/summary
Central: ${final_central:-$CENTRAL_URL}

Comandos uteis:
  systemctl status calaja-agent
  systemctl status xmrig
  journalctl -u calaja-agent -f
  journalctl -u xmrig -f

EOF
}

main() {
    require_root
    decide_install_mode
    install_packages
    fetch_repo
    read_existing_config
    stop_old_services
    if [ "${INSTALL_MODE,,}" == "clean" ]; then
        remove_old_services
    fi
    install_files
    setup_agent_venv
    build_xmrig_if_needed
    write_configs
    install_services
    tune_system
    start_services
    print_summary
}

main "$@"
