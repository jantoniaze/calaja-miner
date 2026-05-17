import time
import json
import os
import socket
import requests
import psutil
import subprocess
import threading
from flask import Flask, request, jsonify

CONFIG_PATH = "/opt/calajaminer/agent/config.json"
XMRIG_CONFIG = "/opt/calajaminer/config.json"

app = Flask(__name__)
MEMORY_INFO_CACHE = None


def load_agent_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def load_xmrig_config():
    with open(XMRIG_CONFIG) as f:
        return json.load(f)


def save_xmrig_config(cfg):
    with open(XMRIG_CONFIG, "w") as f:
        json.dump(cfg, f, indent=4)


def get_ip():
    try:
        return subprocess.check_output(
            "hostname -I | awk '{print $1}'",
            shell=True,
            text=True
        ).strip()
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return None


def generate_rig_id():
    ip = get_ip()
    if ip:
        return f"calaja-rig-{ip.split('.')[-1]}"
    return "calaja-rig-unknown"


def get_temp():
    try:
        out = subprocess.check_output(["sensors"], text=True)
        for line in out.splitlines():
            if "Tctl:" in line or "Package id 0:" in line:
                return line.split()[1]
    except Exception:
        pass
    return None


def get_load():
    try:
        l1, l5, l15 = os.getloadavg()
        return f"{l1:.2f}, {l5:.2f}, {l15:.2f}"
    except Exception:
        return None


def get_cpu_model():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.lower().startswith("model name"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return None


def get_memory_info():
    global MEMORY_INFO_CACHE

    if MEMORY_INFO_CACHE:
        return MEMORY_INFO_CACHE

    info = {
        "ram_total": round(psutil.virtual_memory().total / (1024 ** 3), 1),
        "ram_type": None,
        "ram_speed": None,
        "ram_configured_speed": None,
        "ram_slots": []
    }

    try:
        out = subprocess.check_output(["dmidecode", "-t", "memory"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        MEMORY_INFO_CACHE = info
        return info

    current = {}

    for raw_line in out.splitlines():
        line = raw_line.strip()

        if line.startswith("Memory Device"):
            if current.get("size") and current["size"] != "No Module Installed":
                info["ram_slots"].append(current)
            current = {}
            continue

        if ":" not in line:
            continue

        key, value = [part.strip() for part in line.split(":", 1)]

        if key == "Size":
            current["size"] = value
        elif key == "Type" and value != "Unknown":
            current["type"] = value
        elif key == "Speed" and value != "Unknown":
            current["speed"] = value
        elif key == "Configured Memory Speed" and value != "Unknown":
            current["configured_speed"] = value
        elif key == "Locator":
            current["locator"] = value
        elif key == "Bank Locator":
            current["bank"] = value

    if current.get("size") and current["size"] != "No Module Installed":
        info["ram_slots"].append(current)

    speeds = [slot.get("speed") for slot in info["ram_slots"] if slot.get("speed")]
    configured = [slot.get("configured_speed") for slot in info["ram_slots"] if slot.get("configured_speed")]
    types = [slot.get("type") for slot in info["ram_slots"] if slot.get("type")]

    if types:
        info["ram_type"] = types[0]
    if speeds:
        info["ram_speed"] = max(speeds, key=lambda value: int("".join(ch for ch in value if ch.isdigit()) or 0))
    if configured:
        info["ram_configured_speed"] = max(configured, key=lambda value: int("".join(ch for ch in value if ch.isdigit()) or 0))

    MEMORY_INFO_CACHE = info
    return info


def run_cmd(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return (r.stdout or r.stderr).strip()
    except Exception:
        return "unknown"


def get_miner_status():
    return run_cmd(["systemctl", "is-active", "xmrig"])


def get_miner_enabled():
    return run_cmd(["systemctl", "is-enabled", "xmrig"])


def get_xmrig_api(cfg):
    try:
        r = requests.get(
            cfg["xmrig_api"],
            headers={"Authorization": f"Bearer {cfg['xmrig_token']}"},
            timeout=3
        )
        return r.json()
    except Exception:
        return {}


def get_ping(pool):
    try:
        if not pool:
            return None
        host = pool.split(":")[0]
        out = subprocess.check_output(["ping", "-c", "1", "-W", "1", host], text=True)
        for line in out.splitlines():
            if "time=" in line:
                return float(line.split("time=")[1].split()[0])
    except Exception:
        pass
    return None


def build_payload(agent_cfg, xmrig):
    ip = get_ip()
    memory = get_memory_info()

    try:
        xmrig_cfg = load_xmrig_config()
        threads = len(xmrig_cfg.get("cpu", {}).get("rx", []))
    except Exception:
        threads = None

    pool = xmrig.get("connection", {}).get("pool")

    return {
        "rig_id": generate_rig_id(),
        "worker": agent_cfg.get("worker"),
        "location": agent_cfg.get("location"),
        "hashrate": xmrig.get("hashrate", {}).get("total"),
        "accepted": xmrig.get("connection", {}).get("accepted"),
        "rejected": xmrig.get("connection", {}).get("rejected"),
        "pool": pool,
        "uptime": xmrig.get("uptime"),
        "ip": ip,
        "control_url": f"http://{ip}:5010" if ip else None,
        "cpu_model": get_cpu_model(),
        "cpu_cores": psutil.cpu_count(logical=False),
        "cpu_threads": psutil.cpu_count(logical=True),
        "cpu": psutil.cpu_percent(interval=1),
        "ram_total": memory.get("ram_total"),
        "ram_type": memory.get("ram_type"),
        "ram_speed": memory.get("ram_speed"),
        "ram_configured_speed": memory.get("ram_configured_speed"),
        "ram_slots": memory.get("ram_slots"),
        "ram": psutil.virtual_memory().percent,
        "disk": psutil.disk_usage("/").percent,
        "temp": get_temp(),
        "threads": threads,
        "load": get_load(),
        "ping": get_ping(pool),
        "miner_status": get_miner_status(),
        "miner_enabled": get_miner_enabled()
    }


def send_loop():
    while True:
        try:
            cfg = load_agent_config()
            xmrig = get_xmrig_api(cfg)
            payload = build_payload(cfg, xmrig)

            requests.post(cfg["central_url"], json=payload, timeout=5)
            print("ENVIADO:", payload)

            time.sleep(cfg.get("interval", 10))
        except Exception as e:
            print("ERRO ENVIO:", e)
            time.sleep(10)


def build_threads(n):
    return list(range(int(n)))


def build_config_from_panel(data):
    pool = data.get("pool", {})
    miner = data.get("miner", {})
    agent_cfg = load_agent_config()

    threads = int(miner.get("THREADS", 14))

    return {
        "autosave": True,
        "background": False,
        "colors": False,
        "title": True,
        "http": {
            "enabled": True,
            "host": "0.0.0.0",
            "port": 16000,
            "access-token": agent_cfg.get("xmrig_token", "calaja"),
            "restricted": False
        },
        "cpu": {
            "enabled": True,
            "huge-pages": str(miner.get("HUGE_PAGES", "true")).lower() == "true",
            "priority": int(miner.get("CPU_PRIORITY", 5)),
            "rx": build_threads(threads)
        },
        "donate-level": int(miner.get("DONATE_LEVEL", 0)),
        "pools": [
            {
                "algo": pool.get("ALGO", "rx/0"),
                "url": f"{pool.get('POOL_HOST')}:{pool.get('POOL_PORT')}",
                "user": pool.get("POOL_USER"),
                "pass": pool.get("POOL_PASS"),
                "rig-id": generate_rig_id(),
                "keepalive": True,
                "enabled": True,
                "tls": False
            }
        ],
        "retries": 5,
        "retry-pause": 5,
        "print-time": 60,
        "health-print-time": 60,
        "watch": True
    }


@app.route("/health")
def health():
    return jsonify({"status": "ok", "agent": "calaja-agent"})


@app.route("/api/local/status")
def local_status():
    cfg = load_agent_config()
    xmrig = get_xmrig_api(cfg)
    return jsonify(build_payload(cfg, xmrig))


@app.route("/api/local/config", methods=["GET"])
def get_config():
    try:
        cfg = load_xmrig_config()
        pool = cfg["pools"][0]
        cpu = cfg.get("cpu", {})

        url = pool.get("url", "")
        host = url.split(":")[0] if ":" in url else url
        port = url.split(":")[1] if ":" in url else ""

        return jsonify({
            "pool": {
                "POOL_HOST": host,
                "POOL_PORT": port,
                "POOL_USER": pool.get("user", ""),
                "POOL_PASS": pool.get("pass", ""),
                "ALGO": pool.get("algo", "rx/0")
            },
            "miner": {
                "THREADS": len(cpu.get("rx", [])),
                "MINER": "xmrig",
                "DONATE_LEVEL": cfg.get("donate-level", 0),
                "CPU_PRIORITY": cpu.get("priority", 5),
                "HUGE_PAGES": cpu.get("huge-pages", True)
            }
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/local/config", methods=["POST"])
def update_config():
    data = request.json or {}
    cfg = build_config_from_panel(data)
    save_xmrig_config(cfg)

    subprocess.run(["systemctl", "restart", "xmrig"])

    return jsonify({"ok": True, "message": "config salva e xmrig reiniciado"})


@app.route("/api/local/miner/start", methods=["POST"])
def miner_start():
    subprocess.run(["systemctl", "start", "xmrig"])
    return jsonify({"ok": True})


@app.route("/api/local/miner/stop", methods=["POST"])
def miner_stop():
    subprocess.run(["systemctl", "stop", "xmrig"])
    return jsonify({"ok": True})


@app.route("/api/local/miner/restart", methods=["POST"])
def miner_restart():
    subprocess.run(["systemctl", "restart", "xmrig"])
    return jsonify({"ok": True})


if __name__ == "__main__":
    threading.Thread(target=send_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=5010)
