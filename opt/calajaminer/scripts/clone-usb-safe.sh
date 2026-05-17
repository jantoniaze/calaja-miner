#!/bin/bash
set -e

# ==================================================
# CALAJA CLONER PRO v6
# Clone USB seguro + firstboot correto + SSH + Agent
# ==================================================

# ===== VISUAL =====
log() {
    echo ""
    echo "=========================================="
    echo ">> $1"
    echo "=========================================="
}

ok() {
    echo "✔ $1"
}

erro() {
    echo "❌ $1"
    exit 1
}

clear
echo "===== CALAJA CLONER PRO v6 ====="
echo ""

# ===== CHECKS =====
[ "$EUID" -ne 0 ] && erro "Execute com sudo."

if ! command -v pv >/dev/null 2>&1; then
    erro "pv não instalado. Instale com: sudo apt install -y pv"
fi

ROOT_DEV=$(findmnt -no SOURCE /)
SRC=$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)
SRC_DEV="/dev/$SRC"

[ -z "$SRC" ] && erro "Não consegui detectar o disco de origem."

log "ORIGEM DETECTADA"
echo "Disco origem: $SRC_DEV"

log "DISCOS DISPONÍVEIS"
lsblk -o NAME,SIZE,MODEL,TYPE,MOUNTPOINT

echo ""
read -p "Digite o disco DESTINO (ex: sdb): " DST
DST="${DST#/dev/}"
DST_DEV="/dev/$DST"

[ -z "$DST" ] && erro "Destino vazio."
[ "$SRC" = "$DST" ] && erro "Destino igual à origem."
[ ! -b "$DST_DEV" ] && erro "Disco destino inválido: $DST_DEV"

echo ""
read -p "Confirme novamente o disco DESTINO (ex: sdb): " DST2
DST2="${DST2#/dev/}"

[ "$DST" != "$DST2" ] && erro "Destino não confere. Cancelado."

SRC_SIZE=$(blockdev --getsize64 "$SRC_DEV")
DST_SIZE=$(blockdev --getsize64 "$DST_DEV")

if [ "$DST_SIZE" -lt "$SRC_SIZE" ]; then
    echo "Origem : $SRC_SIZE bytes"
    echo "Destino: $DST_SIZE bytes"
    erro "Destino menor que origem."
fi

log "CONFIRMAÇÃO FINAL"
echo "ORIGEM : $SRC_DEV"
echo "DESTINO: $DST_DEV"
echo ""
echo "ATENÇÃO: tudo no destino será apagado."
read -p "Confirmar clonagem? (clonar/sim/yes): " CONF

CONF=$(echo "$CONF" | tr '[:lower:]' '[:upper:]')

if [[ "$CONF" != "CLONAR" && "$CONF" != "SIM" && "$CONF" != "YES" ]]; then
    echo "Cancelado."
    exit 0
fi

# ===== DESMONTAR DESTINO =====
log "DESMONTANDO DESTINO"

umount ${DST_DEV}?* 2>/dev/null || true
umount ${DST_DEV}* 2>/dev/null || true

ok "Destino desmontado"

# ===== CLONAR =====
log "CLONANDO DISCO"

echo "Isso pode demorar. Acompanhe o progresso abaixo:"
echo ""

dd if="$SRC_DEV" bs=4M status=progress \
| pv -s "$SRC_SIZE" -p -t -e -r -b \
| dd of="$DST_DEV" bs=4M conv=fsync status=progress

sync
partprobe "$DST_DEV" || true
udevadm settle || true
sleep 5

ok "Clone bruto finalizado"

# ===== DETECTAR PARTIÇÕES =====
log "DETECTANDO PARTIÇÕES DO CLONE"

EFI_PART="${DST_DEV}1"
ROOT_PART="${DST_DEV}2"

if [ ! -b "$EFI_PART" ] || [ ! -b "$ROOT_PART" ]; then
    echo "Não encontrei:"
    echo "EFI : $EFI_PART"
    echo "ROOT: $ROOT_PART"
    echo ""
    lsblk "$DST_DEV"
    erro "Partições não detectadas."
fi

echo "EFI : $EFI_PART"
echo "ROOT: $ROOT_PART"

# ===== MONTAR CLONE =====
log "MONTANDO SISTEMA CLONADO"

mkdir -p /mnt/calaja-clone
mount "$ROOT_PART" /mnt/calaja-clone

mkdir -p /mnt/calaja-clone/boot/efi
mount "$EFI_PART" /mnt/calaja-clone/boot/efi

mount --bind /dev /mnt/calaja-clone/dev
mount --bind /proc /mnt/calaja-clone/proc
mount --bind /sys /mnt/calaja-clone/sys
mount --bind /run /mnt/calaja-clone/run

ok "Clone montado"

# ===== REDE UNIVERSAL =====
log "CONFIGURANDO REDE UNIVERSAL DHCP"

mkdir -p /mnt/calaja-clone/etc/netplan
rm -f /mnt/calaja-clone/etc/netplan/*.yaml || true

cat > /mnt/calaja-clone/etc/netplan/00-calaja-dhcp.yaml <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all:
      match:
        name: "*"
      dhcp4: true
      dhcp6: false
      optional: true
EOF

chmod 600 /mnt/calaja-clone/etc/netplan/00-calaja-dhcp.yaml

ok "Netplan universal configurado"

# ===== FIRSTBOOT CORRETO =====
log "INSTALANDO FIRSTBOOT CORRETO"

mkdir -p /mnt/calaja-clone/opt/calajaminer/scripts
mkdir -p /mnt/calaja-clone/opt/calajaminer

cat > /mnt/calaja-clone/opt/calajaminer/scripts/calaja-firstboot.sh <<'EOF'
#!/bin/bash
set -e

LOG="/var/log/calaja-firstboot.log"
DONE="/opt/calajaminer/.firstboot_done"

exec >> "$LOG" 2>&1

echo "===== CalajaMinerOS First Boot v6 ====="
date

if [ -f "$DONE" ]; then
    echo "Firstboot já executado."
    exit 0
fi

echo "[1] Corrigindo rede DHCP universal..."

mkdir -p /etc/netplan

cat > /etc/netplan/00-calaja-dhcp.yaml <<'EON'
network:
  version: 2
  renderer: networkd
  ethernets:
    all:
      match:
        name: "*"
      dhcp4: true
      dhcp6: false
      optional: true
EON

chmod 600 /etc/netplan/00-calaja-dhcp.yaml
rm -f /etc/netplan/00-installer-config.yaml || true

netplan generate || true
netplan apply || true
systemctl restart systemd-networkd || true

echo "[2] Regenerando machine-id..."

rm -f /etc/machine-id || true
systemd-machine-id-setup || true

rm -f /var/lib/dbus/machine-id || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

echo "[3] Regenerando chaves SSH..."

rm -f /etc/ssh/ssh_host_* || true
ssh-keygen -A || true

echo "[4] Garantindo SSH ativo..."

systemctl enable ssh || true
systemctl restart ssh || true

echo "[5] Aguardando IP..."

IP=""
for i in $(seq 1 30); do
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

echo "[6] Atualizando hostname..."

hostnamectl set-hostname "$NEW_HOSTNAME" || true

if grep -q "127.0.1.1" /etc/hosts; then
    sed -i "s/127.0.1.1.*/127.0.1.1    $NEW_HOSTNAME/g" /etc/hosts
else
    echo "127.0.1.1    $NEW_HOSTNAME" >> /etc/hosts
fi

echo "[7] Atualizando configuração do agent..."

AGENT_CONFIG="/opt/calajaminer/agent/config.json"

if [ -f "$AGENT_CONFIG" ]; then
python3 - <<PYEOF
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
PYEOF
else
    echo "AVISO: não achei $AGENT_CONFIG"
fi

echo "[8] Atualizando configuração do XMRig..."

XMRIG_CONFIG="/opt/calajaminer/config.json"

if [ -f "$XMRIG_CONFIG" ]; then
python3 - <<PYEOF
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
PYEOF
else
    echo "AVISO: não achei $XMRIG_CONFIG"
fi

echo "[9] Garantindo boot fallback UEFI..."

mkdir -p /boot/efi/EFI/BOOT || true

if [ -f /boot/efi/EFI/ubuntu/shimx64.efi ]; then
    cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI || true
elif [ -f /boot/efi/EFI/ubuntu/grubx64.efi ]; then
    cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI || true
fi

update-grub || true

echo "[10] Reiniciando serviços Calaja..."

systemctl daemon-reload || true

systemctl enable ssh || true
systemctl restart ssh || true

systemctl enable xmrig || true
systemctl restart xmrig || true

systemctl enable calaja-agent || true
systemctl restart calaja-agent || true

echo "[11] Marcando firstboot concluído..."

mkdir -p /opt/calajaminer
touch "$DONE"

echo "===== First Boot concluído ====="
date

systemctl disable calaja-firstboot.service || true

exit 0
EOF

chmod +x /mnt/calaja-clone/opt/calajaminer/scripts/calaja-firstboot.sh

cat > /mnt/calaja-clone/etc/systemd/system/calaja-firstboot.service <<'EOF'
[Unit]
Description=CalajaMinerOS First Boot
Wants=network-online.target
After=network-online.target systemd-networkd-wait-online.service

[Service]
Type=oneshot
ExecStart=/opt/calajaminer/scripts/calaja-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

rm -f /mnt/calaja-clone/opt/calajaminer/.firstboot_done || true

chroot /mnt/calaja-clone systemctl daemon-reload || true
chroot /mnt/calaja-clone systemctl enable systemd-networkd-wait-online.service || true
chroot /mnt/calaja-clone systemctl enable calaja-firstboot.service || true

ok "Firstboot instalado em /opt/calajaminer/scripts/calaja-firstboot.sh"

# ===== SSH =====
log "PREPARANDO SSH"

chroot /mnt/calaja-clone apt install -y openssh-server >/dev/null 2>&1 || true
chroot /mnt/calaja-clone systemctl enable ssh || true

rm -f /mnt/calaja-clone/etc/ssh/ssh_host_* || true
rm -f /mnt/calaja-clone/etc/machine-id || true
touch /mnt/calaja-clone/etc/machine-id
rm -f /mnt/calaja-clone/var/lib/dbus/machine-id || true

ok "SSH preparado para gerar chaves novas no primeiro boot"

# ===== AGENT =====
log "GARANTINDO AGENT CALAJA"

if [ -f /mnt/calaja-clone/etc/systemd/system/calaja-agent.service ]; then
    chroot /mnt/calaja-clone systemctl enable calaja-agent.service || true
    ok "calaja-agent.service habilitado"
else
    echo "AVISO: não achei /etc/systemd/system/calaja-agent.service no clone."
fi

if [ -f /mnt/calaja-clone/etc/systemd/system/xmrig.service ]; then
    chroot /mnt/calaja-clone systemctl enable xmrig.service || true
    ok "xmrig.service habilitado"
else
    echo "AVISO: não achei xmrig.service no clone."
fi

# ===== FSTAB =====
log "CORRIGINDO FSTAB"

NEW_ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
NEW_EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")

cat > /mnt/calaja-clone/etc/fstab <<EOF
UUID=$NEW_ROOT_UUID / ext4 defaults 0 1
UUID=$NEW_EFI_UUID /boot/efi vfat umask=0077 0 1
EOF

ok "fstab corrigido"

# ===== BOOT UEFI =====
log "CORRIGINDO BOOT UEFI"

chroot /mnt/calaja-clone grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck || true
chroot /mnt/calaja-clone update-grub || true
chroot /mnt/calaja-clone update-initramfs -u || true

mkdir -p /mnt/calaja-clone/boot/efi/EFI/BOOT

if [ -f /mnt/calaja-clone/boot/efi/EFI/ubuntu/shimx64.efi ]; then
    cp /mnt/calaja-clone/boot/efi/EFI/ubuntu/shimx64.efi /mnt/calaja-clone/boot/efi/EFI/BOOT/BOOTX64.EFI || true
elif [ -f /mnt/calaja-clone/boot/efi/EFI/ubuntu/grubx64.efi ]; then
    cp /mnt/calaja-clone/boot/efi/EFI/ubuntu/grubx64.efi /mnt/calaja-clone/boot/efi/EFI/BOOT/BOOTX64.EFI || true
else
    echo "AVISO: não encontrei shimx64.efi nem grubx64.efi."
fi

ok "Boot UEFI ajustado"

# ===== LIMPEZA =====
log "LIMPANDO CACHE E TEMPORÁRIOS"

rm -rf /mnt/calaja-clone/tmp/* || true
rm -rf /mnt/calaja-clone/var/tmp/* || true
rm -rf /mnt/calaja-clone/var/log/* || true

ok "Limpeza concluída"

# ===== DESMONTAR =====
log "DESMONTANDO CLONE"

umount /mnt/calaja-clone/run || true
umount /mnt/calaja-clone/sys || true
umount /mnt/calaja-clone/proc || true
umount /mnt/calaja-clone/dev || true
umount /mnt/calaja-clone/boot/efi || true
umount /mnt/calaja-clone || true

sync

echo ""
echo "=========================================="
echo "CLONE FINALIZADO COM SUCESSO 🚀"
echo "Destino: $DST_DEV"
echo ""
echo "No primeiro boot do clone ele vai:"
echo "- gerar machine-id novo"
echo "- gerar chaves SSH novas"
echo "- aplicar rede DHCP universal"
echo "- criar hostname único"
echo "- atualizar rig_id e worker"
echo "- reiniciar xmrig"
echo "- reiniciar calaja-agent"
echo ""
echo "Log no clone:"
echo "/var/log/calaja-firstboot.log"
echo "=========================================="
