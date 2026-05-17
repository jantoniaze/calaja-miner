#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/jantoniaze/calaja-miner.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/calajaminer}"
TMP_DIR="${TMP_DIR:-/tmp/calaja-miner-install}"

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

log() {
    printf '[calaja-install] %s\n' "$*"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Execute como root: sudo bash $0" >&2
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
        curl \
        dmidecode \
        git \
        iproute2 \
        lm-sensors \
        openssh-server \
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

install_files() {
    log "Instalando arquivos em $INSTALL_DIR..."

    if [ -d "$INSTALL_DIR" ]; then
        local backup
        backup="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
        log "Backup do diretorio existente: $backup"
        cp -a "$INSTALL_DIR" "$backup"
    fi

    mkdir -p "$INSTALL_DIR"

    rsync -a --delete \
        --exclude 'agent/venv/' \
        --exclude 'logs/' \
        --exclude '.firstboot_done' \
        "$TMP_DIR/opt/calajaminer/" "$INSTALL_DIR/"

    mkdir -p "$INSTALL_DIR/logs"

    chmod +x "$INSTALL_DIR/scripts/"*.sh || true
    chmod +x "$INSTALL_DIR/xmrig/build/xmrig" || true
}

setup_agent_venv() {
    log "Criando venv do agent..."

    python3 -m venv "$INSTALL_DIR/agent/venv"
    "$INSTALL_DIR/agent/venv/bin/pip" install --upgrade pip
    "$INSTALL_DIR/agent/venv/bin/pip" install -r "$INSTALL_DIR/agent/requirements.txt"
}

write_configs() {
    local suffix rig_id worker pool_pass threads
    suffix="$(detect_suffix)"
    rig_id="${RIG_ID:-calaja-rig-$suffix}"
    worker="${WORKER:-rig$suffix}"
    pool_pass="${POOL_PASS:-$worker}"
    threads="${THREADS:-$(nproc)}"

    log "Configurando rig_id=$rig_id worker=$worker location=$LOCATION"
    log "Central: $CENTRAL_URL"
    log "Pool: $POOL_URL"

    python3 - "$INSTALL_DIR" "$rig_id" "$worker" "$LOCATION" "$CENTRAL_URL" "$XMRIG_TOKEN" "$AGENT_INTERVAL" "$POOL_URL" "$POOL_USER" "$pool_pass" "$threads" "$DONATE_LEVEL" "$CPU_PRIORITY" "$HUGE_PAGES" <<'PY'
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

    systemctl --no-pager --full status xmrig --lines 3 || true
    systemctl --no-pager --full status calaja-agent --lines 3 || true
}

print_summary() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

    cat <<EOF

Instalacao concluida.

Rig IP: ${ip:-unknown}
Agent local: http://${ip:-RIG_IP}:5010/health
XMRig API: http://${ip:-RIG_IP}:16000/2/summary
Central: $CENTRAL_URL

Comandos uteis:
  systemctl status calaja-agent
  systemctl status xmrig
  journalctl -u calaja-agent -f
  journalctl -u xmrig -f

EOF
}

main() {
    require_root
    install_packages
    fetch_repo
    install_files
    setup_agent_venv
    write_configs
    install_services
    tune_system
    start_services
    print_summary
}

main "$@"
