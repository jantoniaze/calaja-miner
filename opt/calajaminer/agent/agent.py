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
BOARD_INFO_CACHE = None


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


def read_number(path):
    try:
        with open(path) as f:
            return float(f.read().strip())
    except Exception:
        return None


def get_cpu_frequency():
    freqs = []

    for cpu in range(psutil.cpu_count(logical=True) or 0):
        value = read_number(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_cur_freq")
        if value:
            freqs.append(value / 1000)

    max_freq = read_number("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")

    if freqs:
        return {
            "current_mhz": round(sum(freqs) / len(freqs), 0),
            "max_mhz": round(max_freq / 1000, 0) if max_freq else None
        }

    try:
        freq = psutil.cpu_freq()
        if freq:
            return {
                "current_mhz": round(freq.current, 0),
                "max_mhz": round(freq.max, 0) if freq.max else None
            }
    except Exception:
        pass

    return {"current_mhz": None, "max_mhz": None}


def get_hwmon_dirs():
    base = "/sys/class/hwmon"

    try:
        names = sorted(os.listdir(base))
    except Exception:
        return []

    return [os.path.join(base, name) for name in names if name.startswith("hwmon")]


def get_cpu_voltage():
    for hwmon in get_hwmon_dirs():
        chip = get_hwmon_name(hwmon).lower()

        if is_gpu_hwmon(chip):
            continue

        labels = {}

        for name in os.listdir(hwmon):
            if name.startswith("in") and name.endswith("_label"):
                try:
                    index = name[2:].split("_", 1)[0]
                    with open(os.path.join(hwmon, name)) as f:
                        labels[index] = f.read().strip().lower()
                except Exception:
                    pass

        for index, label in labels.items():
            if any(token in label for token in ("vcore", "cpu", "svi2_core", "core")):
                value = read_number(os.path.join(hwmon, f"in{index}_input"))
                if value is not None:
                    return round(value / 1000, 3)

    return None


def get_hwmon_name(hwmon):
    try:
        with open(os.path.join(hwmon, "name")) as f:
            return f.read().strip()
    except Exception:
        return os.path.basename(hwmon)


def is_gpu_hwmon(chip):
    return chip.lower() in {"nouveau", "amdgpu", "radeon"} or "nvidia" in chip.lower()


def is_board_hwmon(chip):
    chip = chip.lower()
    board_tokens = ("it", "nct", "w836", "aspeed", "asus", "gigabyte", "superio")
    return any(token in chip for token in board_tokens)


def get_fan_info():
    fans = []
    controls = []

    for hwmon in get_hwmon_dirs():
        chip = get_hwmon_name(hwmon)

        if is_gpu_hwmon(chip) or not is_board_hwmon(chip):
            continue

        for name in os.listdir(hwmon):
            if name.startswith("fan") and name.endswith("_input"):
                index = name[3:].split("_", 1)[0]
                rpm = read_number(os.path.join(hwmon, name))
                if rpm is not None:
                    fans.append({
                        "chip": chip,
                        "index": index,
                        "rpm": int(rpm)
                    })

            if name.startswith("pwm") and name[3:].isdigit():
                path = os.path.join(hwmon, name)
                if os.path.exists(path):
                    controls.append({
                        "chip": chip,
                        "index": name[3:],
                        "path": path,
                        "enable_path": os.path.join(hwmon, f"{name}_enable")
                    })

    return {
        "rpm": fans[0]["rpm"] if fans else None,
        "fans": fans,
        "control_available": bool(controls),
        "controls": controls
    }


def get_gpu_info():
    devices = []

    for hwmon in get_hwmon_dirs():
        chip = get_hwmon_name(hwmon)

        if not is_gpu_hwmon(chip):
            continue

        device = {
            "chip": chip,
            "fan_rpm": None,
            "temp": None,
            "voltage": None
        }

        for name in os.listdir(hwmon):
            if name.startswith("fan") and name.endswith("_input") and device["fan_rpm"] is None:
                rpm = read_number(os.path.join(hwmon, name))
                device["fan_rpm"] = int(rpm) if rpm is not None else None
            elif name.startswith("temp") and name.endswith("_input") and device["temp"] is None:
                temp = read_number(os.path.join(hwmon, name))
                device["temp"] = round(temp / 1000, 1) if temp is not None else None
            elif name.startswith("in") and name.endswith("_input") and device["voltage"] is None:
                voltage = read_number(os.path.join(hwmon, name))
                device["voltage"] = round(voltage / 1000, 3) if voltage is not None else None

        devices.append(device)

    primary = devices[0] if devices else {}

    return {
        "devices": devices,
        "fan_rpm": primary.get("fan_rpm"),
        "temp": primary.get("temp"),
        "voltage": primary.get("voltage")
    }


def set_fan_speed(percent=None, auto=False):
    fan = get_fan_info()

    if not fan["controls"]:
        return False, "Controle PWM indisponivel nesta rig"

    control = fan["controls"][0]

    try:
        if auto:
            with open(control["enable_path"], "w") as f:
                f.write("2\n")
            return True, "Controle automatico da fan ativado"

        percent = max(20, min(100, int(percent)))
        pwm_value = round(percent * 255 / 100)

        if os.path.exists(control["enable_path"]):
            with open(control["enable_path"], "w") as f:
                f.write("1\n")

        with open(control["path"], "w") as f:
            f.write(f"{pwm_value}\n")

        return True, f"Fan ajustada para {percent}%"
    except Exception as exc:
        return False, str(exc)


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


def get_board_info():
    global BOARD_INFO_CACHE

    if BOARD_INFO_CACHE:
        return BOARD_INFO_CACHE

    info = {
        "board_manufacturer": None,
        "board_product": None,
        "board_version": None,
        "board_model": None
    }

    try:
        out = subprocess.check_output(["dmidecode", "-t", "baseboard"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        BOARD_INFO_CACHE = info
        return info

    for raw_line in out.splitlines():
        line = raw_line.strip()

        if ":" not in line:
            continue

        key, value = [part.strip() for part in line.split(":", 1)]

        if not value or value.lower() in {"unknown", "default string", "not specified"}:
            continue

        if key == "Manufacturer":
            info["board_manufacturer"] = value
        elif key == "Product Name":
            info["board_product"] = value
        elif key == "Version":
            info["board_version"] = value

    parts = [info["board_manufacturer"], info["board_product"]]
    info["board_model"] = " ".join(part for part in parts if part) or info["board_product"]

    BOARD_INFO_CACHE = info
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


def get_xmrig_backends(cfg):
    try:
        url = cfg["xmrig_api"].replace("/2/summary", "/2/backends")
        r = requests.get(
            url,
            headers={"Authorization": f"Bearer {cfg['xmrig_token']}"},
            timeout=3
        )
        return r.json()
    except Exception:
        return []


def fmt_hashrate(value):
    if isinstance(value, list):
        vals = [v for v in value if v is not None]
        if vals:
            return round(float(vals[0]), 2)
        return 0
    if value is None:
        return 0
    try:
        return round(float(value), 2)
    except Exception:
        return 0


def build_miner_threads(backends, temp):
    if not isinstance(backends, list):
        return []

    for backend in backends:
        if backend.get("type") != "cpu":
            continue

        rows = []

        for index, thread in enumerate(backend.get("threads") or [], start=1):
            rows.append({
                "index": index,
                "affinity": thread.get("affinity"),
                "intensity": thread.get("intensity"),
                "hashrate": fmt_hashrate(thread.get("hashrate")),
                "temp": temp
            })

        return rows

    return []


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


def build_payload(agent_cfg, xmrig, backends=None):
    ip = get_ip()
    memory = get_memory_info()
    board = get_board_info()
    temp = get_temp()
    cpu_frequency = get_cpu_frequency()
    fan = get_fan_info()
    gpu = get_gpu_info()

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
        "cpu_frequency_mhz": cpu_frequency.get("current_mhz"),
        "cpu_frequency_max_mhz": cpu_frequency.get("max_mhz"),
        "cpu_voltage": get_cpu_voltage(),
        "board_manufacturer": board.get("board_manufacturer"),
        "board_product": board.get("board_product"),
        "board_version": board.get("board_version"),
        "board_model": board.get("board_model"),
        "cpu": psutil.cpu_percent(interval=1),
        "ram_total": memory.get("ram_total"),
        "ram_type": memory.get("ram_type"),
        "ram_speed": memory.get("ram_speed"),
        "ram_configured_speed": memory.get("ram_configured_speed"),
        "ram_slots": memory.get("ram_slots"),
        "ram": psutil.virtual_memory().percent,
        "disk": psutil.disk_usage("/").percent,
        "temp": temp,
        "cpu_fan_rpm": fan.get("rpm"),
        "fan_control_available": fan.get("control_available"),
        "gpu_fan_rpm": gpu.get("fan_rpm"),
        "gpu_temp": gpu.get("temp"),
        "gpu_voltage": gpu.get("voltage"),
        "gpu_sensors": gpu.get("devices"),
        "threads": threads,
        "miner_threads": build_miner_threads(backends or [], temp),
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
            backends = get_xmrig_backends(cfg)
            payload = build_payload(cfg, xmrig, backends)

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
    backends = get_xmrig_backends(cfg)
    return jsonify(build_payload(cfg, xmrig, backends))


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


@app.route("/api/local/system/reboot", methods=["POST"])
def system_reboot():
    subprocess.Popen(["systemctl", "reboot"])
    return jsonify({"ok": True, "action": "reboot"})


@app.route("/api/local/system/reboot-delayed", methods=["POST"])
def system_reboot_delayed():
    subprocess.Popen(["sh", "-c", "sleep 30 && systemctl reboot"])
    return jsonify({"ok": True, "action": "reboot-delayed", "delay_seconds": 30})


@app.route("/api/local/system/shutdown", methods=["POST"])
def system_shutdown():
    subprocess.Popen(["systemctl", "poweroff"])
    return jsonify({"ok": True, "action": "shutdown"})


@app.route("/api/local/fan", methods=["POST"])
def fan_control():
    data = request.json or {}
    ok, message = set_fan_speed(
        percent=data.get("percent"),
        auto=str(data.get("mode", "")).lower() == "auto"
    )
    status = 200 if ok else 400
    return jsonify({"ok": ok, "message": message}), status


if __name__ == "__main__":
    threading.Thread(target=send_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=5010)
