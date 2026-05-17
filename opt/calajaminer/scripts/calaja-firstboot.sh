#!/bin/bash

set -e

LOG="/var/log/calaja-firstboot.log"
DONE="/opt/calajaminer/.firstboot_done"

exec >> "$LOG" 2>&1

echo "===== CalajaMinerOS First Boot ====="
date

if [ -f "$DONE" ]; then
    echo "Firstboot já executado."
    exit 0
fi

echo "[1] Corrigindo rede DHCP universal..."

mkdir -p /etc/netplan

cat > /etc/netplan/00-calaja-dhcp.yaml <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-eth:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: false
    all-en:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
EOF

rm -f /etc/netplan/00-installer-config.yaml || true
netplan generate || true
netplan apply || true

echo "[2] Gerando identificação única..."

IP=""
for i in $(seq 1 20); do
    IP=$(hostname -I | awk '{print $1}')
    if [ -n "$IP" ]; then
        break
    fi
    sleep 2
done

if [ -n "$IP" ]; then
    SUFFIX=$(echo "$IP" | awk -F. '{print $4}')
else
    MAC=$(cat /sys/class/net/*/address 2>/dev/null | grep -v "00:00:00:00:00:00" | head -n1 | tr -d ':')
    SUFFIX=$(echo "$MAC" | tail -c 7)
fi

if [ -z "$SUFFIX" ]; then
    SUFFIX=$(date +%s)
fi

NEW_HOSTNAME="CalajaMinerOS-$SUFFIX"
NEW_RIG_ID="calaja-rig-$SUFFIX"
NEW_WORKER="rig$SUFFIX"

echo "IP: $IP"
echo "Hostname: $NEW_HOSTNAME"
echo "Rig ID: $NEW_RIG_ID"
echo "Worker: $NEW_WORKER"

hostnamectl set-hostname "$NEW_HOSTNAME"

if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/127.0.1.1.*/127.0.1.1    $NEW_HOSTNAME/g" /etc/hosts
else
    echo "127.0.1.1    $NEW_HOSTNAME" >> /etc/hosts
fi

echo "[3] Regenerando machine-id..."

rm -f /etc/machine-id
systemd-machine-id-setup || true
rm -f /var/lib/dbus/machine-id || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

echo "[4] Regenerando SSH host keys..."

rm -f /etc/ssh/ssh_host_* || true
dpkg-reconfigure openssh-server || true

echo "[5] Atualizando agent config..."

AGENT_CONFIG="/opt/calajaminer/agent/config.json"

if [ -f "$AGENT_CONFIG" ]; then
python3 - <<EOF
import json

path = "$AGENT_CONFIG"

with open(path) as f:
    cfg = json.load(f)

cfg["rig_id"] = "$NEW_RIG_ID"
cfg["worker"] = "$NEW_WORKER"
cfg["location"] = cfg.get("location", "home")

with open(path, "w") as f:
    json.dump(cfg, f, indent=4)

print("Agent config atualizado.")
EOF
fi

echo "[6] Atualizando config do XMRig..."

XMRIG_CONFIG="/opt/calajaminer/config.json"

if [ -f "$XMRIG_CONFIG" ]; then
python3 - <<EOF
import json

path = "$XMRIG_CONFIG"

with open(path) as f:
    cfg = json.load(f)

if "pools" in cfg and cfg["pools"]:
    cfg["pools"][0]["pass"] = "$NEW_WORKER"
    cfg["pools"][0]["rig-id"] = "$NEW_RIG_ID"

with open(path, "w") as f:
    json.dump(cfg, f, indent=4)

print("XMRig config atualizado.")
EOF
fi

echo "[7] Garantindo boot fallback..."

mkdir -p /boot/efi/EFI/BOOT || true

if [ -f /boot/efi/EFI/ubuntu/grubx64.efi ]; then
    cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI || true
elif [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
    cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI || true
fi

update-grub || true

echo "[8] Reiniciando serviços..."

systemctl enable xmrig || true
systemctl enable calaja-agent || true
systemctl restart xmrig || true
systemctl restart calaja-agent || true

touch "$DONE"

echo "===== First Boot concluído ====="
date

systemctl disable calaja-firstboot.service || true

exit 0
