#!/usr/bin/env bash
set -u
[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

N="${1:-}"
IF="${2:-}"
LOG="$(pwd)/lab6_vm2_report.txt"
: > "$LOG"

say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
run(){ printf '$ %s\n' "$*" | tee -a "$LOG"; bash -c "$*" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
die(){ echo "ОШИБКА: $*" | tee -a "$LOG"; exit 1; }

say "Определение интерфейса"
[ -n "$IF" ] || IF="$(ls /sys/class/net | grep -Ev '^(lo|docker.*|virbr.*|br-.*|veth.*|tun.*|tap.*|wl.*)$' | head -n1)"
[ -n "$IF" ] || die "не найден сетевой интерфейс"
run "ip link set $IF up"
echo "Интерфейс: $IF" | tee -a "$LOG"

has_gw(){ ip -4 route show default | grep -q "dev $IF"; }

if ! has_gw; then
  say "Получение адреса по DHCP от VM1"
  if command -v dhclient >/dev/null; then
    run "dhclient -r $IF; timeout 20 dhclient -v $IF"
  else
    run "networkctl reconfigure $IF 2>/dev/null || netplan apply"
  fi
  for _ in $(seq 1 15); do has_gw && break; sleep 1; done
fi

if ! has_gw; then
  [ -n "$N" ] || die "DHCP не выдал адрес. Запусти так: $0 <N>  (статический 192.168.(100+N).10)"
  say "DHCP не ответил — статическая настройка"
  NETP="192.168.$((100+N))"
  run "ip addr flush dev $IF"
  run "ip addr add $NETP.10/24 dev $IF"
  run "ip route replace default via $NETP.1 dev $IF"
  command -v resolvectl >/dev/null && run "resolvectl dns $IF 8.8.8.8 1.1.1.1"
fi

GW="$(ip -4 route show default | awk -v d="$IF" '$0 ~ "dev "d {print $3; exit}')"

say "Сетевые настройки VM2"
run "ip -br addr show $IF"
run "ip route"
run "resolvectl status $IF 2>/dev/null | grep -i 'dns servers' || cat /etc/resolv.conf"

say "Проверка маршрутизации через VM1"
run "ping -c 3 -W 2 $GW"
run "ping -c 3 -W 2 8.8.8.8"
run "ping -c 3 -W 2 ya.ru"
if command -v traceroute >/dev/null; then
  run "traceroute -n -m 5 8.8.8.8"
elif command -v tracepath >/dev/null; then
  run "tracepath -n -m 5 8.8.8.8"
fi

say "ГОТОВО"
echo "Лог для отчёта: $LOG" | tee -a "$LOG"
