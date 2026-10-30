#!/usr/bin/env bash
set -u
[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

N="${1:-}"
EXT="${2:-}"
INT="${3:-}"
LOG="$(pwd)/lab6_vm1_report.txt"
: > "$LOG"

say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
run(){ printf '$ %s\n' "$*" | tee -a "$LOG"; bash -c "$*" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
die(){ echo "ОШИБКА: $*" | tee -a "$LOG"; exit 1; }

say "Определение интерфейсов"
[ -n "$EXT" ] || EXT="$(ip -o -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
[ -n "$EXT" ] || die "не найден внешний интерфейс (нет маршрута по умолчанию). Укажи: $0 N enp0s3 enp0s8"
if [ -z "$INT" ]; then
  INT="$(ls /sys/class/net | grep -Ev "^(lo|$EXT|docker.*|virbr.*|br-.*|veth.*|tun.*|tap.*|wl.*)$" | head -n1)"
fi
[ -n "$INT" ] || die "не найден внутренний интерфейс. Укажи: $0 N enp0s3 enp0s8"
run "ip link set $INT up"

CIDR="$(ip -o -4 addr show dev "$INT" | awk '{print $4}' | head -n1)"
if [ -z "$CIDR" ]; then
  [ -n "$N" ] || die "на $INT нет IPv4-адреса. Запусти так: $0 <N>  (подсеть 192.168.(100+N).0/24)"
  CIDR="192.168.$((100+N)).1/24"
  run "ip addr add $CIDR dev $INT"
fi
IPADDR="${CIDR%/*}"
PREFIX="${CIDR#*/}"
NET="${IPADDR%.*}.0/$PREFIX"
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
add(){ local t="$1"; shift; iptables -t "$t" -C "$@" 2>/dev/null || run "iptables -t $t -A $*"; }
add filter FORWARD -s "$NET" -j ACCEPT
add filter FORWARD -d "$NET" -j ACCEPT
add nat POSTROUTING -o "$EXT" -s "$NET" -j MASQUERADE
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
echo "Шлюз для VM2: $IPADDR  |  Подсеть: $NET" | tee -a "$LOG"
echo "Лог для отчёта: $LOG" | tee -a "$LOG"
