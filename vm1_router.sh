#!/usr/bin/env bash
set -u
[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

N="${1:-9}"
EXT="${2:-}"
INT="${3:-}"
LOG="$(pwd)/lab6_vm1_report.txt"
: > "$LOG"

say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
run(){ printf '$ %s\n' "$*" | tee -a "$LOG"; bash -c "$*" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
die(){ echo "ОШИБКА: $*" | tee -a "$LOG"; exit 1; }

phys_ifaces(){
  local i
  for i in $(ls /sys/class/net); do
    [ -e "/sys/class/net/$i/device" ] && echo "$i"
  done
}

say "Этап 0. Первоначальная настройка VM1 строго по ЛР5 (netplan + DHCP)"
if [ -z "$EXT" ]; then
  EXT="$(ip -o -4 addr show | awk '$4 ~ /^10\.0\.2\./ {print $2; exit}')"
fi
if [ -z "$EXT" ]; then
  EXT="$(ip -o -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
if [ -z "$EXT" ]; then
  EXT="$(phys_ifaces | head -n1)"
  [ -n "$EXT" ] && { ip link set "$EXT" up; dhclient "$EXT" 2>/dev/null || true; }
fi
[ -n "$EXT" ] || die "не найден внешний интерфейс (NAT). Укажи: $0 N enp0s3 enp0s8"

if [ -z "$INT" ]; then
  for i in $(phys_ifaces); do
    [ "$i" != "$EXT" ] && { INT="$i"; break; }
  done
fi
[ -n "$INT" ] || die "не найден внутренний интерфейс. Укажи: $0 N enp0s3 enp0s8"

NET_PREFIX="192.168.$((N+10))"
NETWORK="$NET_PREFIX.0"
MASK="255.255.255.0"
PREFIX="24"
IPADDR="$NET_PREFIX.1"
CIDR="$IPADDR/$PREFIX"
NET="$NETWORK/$PREFIX"
RANGE_FROM="$NET_PREFIX.100"
RANGE_TO="$NET_PREFIX.200"
VM2_RESERVED_IP="$NET_PREFIX.50"

# Полная очистка старых адресов и маршрутов на внутреннем интерфейсе
ip link set "$INT" down 2>/dev/null || true
ip addr flush dev "$INT" 2>/dev/null || true
ip link set "$INT" up 2>/dev/null || true

# Запись /etc/netplan/60-lab5.yaml строго как в lab5
cat > /etc/netplan/60-lab5.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    $INT:
      dhcp4: false
      addresses: [$CIDR]
NETPLAN
chmod 600 /etc/netplan/60-lab5.yaml
run "netplan generate && netplan apply"
ip addr flush dev "$INT" 2>/dev/null || true
run "ip addr add $CIDR dev $INT"
run "ip link set $INT up"

# Настройка isc-dhcp-server строго как в lab5 (02_vm1_netplan_dhcp.sh + 04_reserve_vm2.sh)
if ! dpkg -s isc-dhcp-server >/dev/null 2>&1; then
  apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y isc-dhcp-server || true
fi
if command -v dhcpd >/dev/null 2>&1; then
  sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$INT\"/" /etc/default/isc-dhcp-server 2>/dev/null || true
  OWN_MACS="$(for i in $(phys_ifaces); do cat "/sys/class/net/$i/address" 2>/dev/null; done)"
  VM2_MAC="$(grep -oE 'hardware ethernet [0-9a-fA-F:]+' /etc/dhcp/dhcpd.conf /var/lib/dhcp/dhcpd.leases 2>/dev/null | awk '{print tolower($3)}' | grep -vxF "$OWN_MACS" | tail -n1 || true)"
  [ -n "$VM2_MAC" ] || VM2_MAC="08:00:27:a4:e7:55"

  cat > /etc/dhcp/dhcpd.conf <<DHCPCONF
authoritative;
default-lease-time 600;
max-lease-time 7200;

subnet $NETWORK netmask $MASK {
  range $RANGE_FROM $RANGE_TO;
  option routers $IPADDR;
  option subnet-mask $MASK;
  option broadcast-address $NET_PREFIX.255;
  option domain-name-servers 8.8.8.8, 1.1.1.1;
}
host vm2 {
  hardware ethernet $VM2_MAC;
  fixed-address $VM2_RESERVED_IP;
}
DHCPCONF
  dhcpd -t -cf /etc/dhcp/dhcpd.conf
  systemctl enable isc-dhcp-server >/dev/null 2>&1 || true
  run "systemctl restart isc-dhcp-server"
fi

echo "Внешний: $EXT | Внутренний: $INT ($CIDR) | Подсеть: $NET" | tee -a "$LOG"
run "ip -br addr"
run "ip route"

say "Задание 1. Включение IP-форвардинга (sysctl.conf)"
if grep -Eq '^[#[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf; then
  sed -i -E 's/^[#[:space:]]*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
run "grep -n 'net.ipv4.ip_forward' /etc/sysctl.conf"
run "sysctl -p"
run "sysctl net.ipv4.ip_forward"
run "cat /proc/sys/net/ipv4/ip_forward"

say "Задание 2. Правила iptables (маскарадинг)"
command -v iptables >/dev/null || { run "apt-get update -y && apt-get install -y iptables" || die "не удалось установить iptables"; }
command -v ufw >/dev/null && ufw disable >/dev/null 2>&1 || true

iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
iptables -t nat -F
iptables -X 2>/dev/null || true

run "iptables -A FORWARD -s $NET -j ACCEPT"
run "iptables -A FORWARD -d $NET -j ACCEPT"
run "iptables -t nat -A POSTROUTING -o $EXT -s $NET -j MASQUERADE"
run "iptables -L -v -n"
run "iptables -t nat -L -v -n"

say "Задание 3. Сохранение правил и сервис systemd"
run "mkdir -p /etc/iptables-conf"
run "iptables-save -f /etc/iptables-conf/iptables.ipv4"
run "cat /etc/iptables-conf/iptables.ipv4"

cat > /etc/systemd/system/iptables-firewall.service <<'UNIT'
[Unit]
Description=iptables firewall service
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables-conf/iptables.ipv4
RemainAfterExit=true
StandardOutput=journal

[Install]
WantedBy=multi-user.target
UNIT
run "cat /etc/systemd/system/iptables-firewall.service"
run "systemctl daemon-reload"
run "systemctl enable iptables-firewall.service"
run "systemctl restart iptables-firewall.service"
run "systemctl status iptables-firewall.service --no-pager"
run "systemctl is-enabled iptables-firewall.service"

say "Проверка после перезапуска сервиса"
run "iptables -F && iptables -t nat -F"
run "iptables -t nat -L POSTROUTING -n"
run "systemctl restart iptables-firewall.service"
run "iptables -L"
run "iptables -t nat -L"
run "journalctl -u iptables-firewall.service --no-pager -n 10"

say "Проверка выхода в интернет с VM1"
run "ping -c 3 -W 2 8.8.8.8"

say "ГОТОВО"
echo "Шлюз для VM2: $IPADDR  |  Подсеть: $NET  |  Резерв VM2: $VM2_RESERVED_IP" | tee -a "$LOG"
echo "Лог для отчёта: $LOG" | tee -a "$LOG"
