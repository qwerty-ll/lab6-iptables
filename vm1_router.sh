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

say "Определение интерфейсов"
[ -n "$EXT" ] || EXT="$(ip -o -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -z "$EXT" ]; then
  FIRST_IF="$(ls /sys/class/net | grep -Ev '^(lo|docker.*|virbr.*|br-.*|veth.*|tun.*|tap.*|wl.*)$' | head -n1)"
  [ -n "$FIRST_IF" ] && { ip link set "$FIRST_IF" up; dhclient "$FIRST_IF" 2>/dev/null || true; }
  EXT="$(ip -o -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
[ -n "$EXT" ] || die "не найден внешний интерфейс (нет маршрута по умолчанию). Укажи: $0 N enp0s3 enp0s8"

if [ -z "$INT" ]; then
  INT="$(ls /sys/class/net | grep -Ev "^(lo|$EXT|docker.*|virbr.*|br-.*|veth.*|tun.*|tap.*|wl.*)$" | head -n1)"
fi
[ -n "$INT" ] || die "не найден внутренний интерфейс (проверь, что в VirtualBox на VM1 включён Адаптер 2 -> Внутренняя сеть 'intnet')"
run "ip link set $INT up"

# Поддержка обеих схем адресации: ЛР6 (192.168.(100+N).0/24) и ЛР5 (192.168.(10+N).0/24)
NET100="192.168.$((100+N))"
NET10="192.168.$((10+N))"
CIDR="$NET100.1/24"
IPADDR="$NET100.1"
NET="$NET100.0/24"
ALT_NET="$NET10.0/24"

ip -4 addr show dev "$INT" | grep -q "$NET100.1/" || run "ip addr add $NET100.1/24 dev $INT"
ip -4 addr show dev "$INT" | grep -q "$NET10.1/"  || ip addr add "$NET10.1/24" dev "$INT" 2>/dev/null || true

# Если установлен isc-dhcp-server из ЛР5 — убеждаемся, что он раздаёт адреса на $INT
if [ -f /etc/dhcp/dhcpd.conf ] && command -v dhcpd >/dev/null 2>&1; then
  sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$INT\"/" /etc/default/isc-dhcp-server 2>/dev/null || true
  systemctl restart isc-dhcp-server 2>/dev/null || true
fi

echo "Внешний: $EXT | Внутренний: $INT ($CIDR, доп. $NET10.1/24) | Подсеть: $NET" | tee -a "$LOG"
run "ip -br addr"
run "ip route"

say "Задание 1. Включение IP-форвардинга (sysctl.conf)"
if grep -Eq '^[#[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf; then
  sed -i -E 's/^[#[:space:]]*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
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

# Разрешаем также подсеть из ЛР5 (192.168.(10+N).0/24), если VM2 получила адрес от DHCP ЛР5
if [ "$ALT_NET" != "$NET" ]; then
  iptables -A FORWARD -s "$ALT_NET" -j ACCEPT
  iptables -A FORWARD -d "$ALT_NET" -j ACCEPT
  iptables -t nat -A POSTROUTING -o "$EXT" -s "$ALT_NET" -j MASQUERADE
fi

run "iptables -L -v -n"
run "iptables -t nat -L -v -n"

say "Задание 3. Сохранение правил и сервис systemd"
run "mkdir -p /etc/iptables-conf"
run "iptables-save -f /etc/iptables-conf/iptables.ipv4"
run "cat /etc/iptables-conf/iptables.ipv4"

RESTORE_BIN="$(command -v iptables-restore || echo /sbin/iptables-restore)"
cat > /etc/systemd/system/iptables-firewall.service <<UNIT
[Unit]
Description=iptables firewall service
After=network.target

[Service]
Type=oneshot
ExecStart=$RESTORE_BIN /etc/iptables-conf/iptables.ipv4
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
echo "Шлюз для VM2: $IPADDR (или $NET10.1)  |  Подсеть: $NET" | tee -a "$LOG"
echo "Лог для отчёта: $LOG" | tee -a "$LOG"
