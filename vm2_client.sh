#!/usr/bin/env bash
set -u
[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

N="${1:-9}"
IF="${2:-}"
LOG="$(pwd)/lab6_vm2_report.txt"
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

say "Этап 0. Очистка и первоначальная настройка VM2 строго по ЛР5"
[ -n "$IF" ] || IF="$(phys_ifaces | head -n1)"
[ -n "$IF" ] || die "не найден сетевой интерфейс"
echo "Внутренний интерфейс VM2: $IF" | tee -a "$LOG"

NET_PREFIX="192.168.$((N+10))"
GW="$NET_PREFIX.1"
RESERVED_IP="$NET_PREFIX.50"

# Если есть второй адаптер (например enp0s8 — сеть аудитории), убираем с него чужие адреса 192.168.* и восстанавливаем его DHCP
for other in $(phys_ifaces); do
  [ "$other" = "$IF" ] && continue
  ip link set "$other" up 2>/dev/null || true
  for addr in $(ip -o -4 addr show dev "$other" | awk '{print $4}' | grep '^192\.168\.' || true); do
    ip addr del "$addr" dev "$other" 2>/dev/null || true
  done
  if [ -z "$(ip -o -4 addr show dev "$other" scope global | awk '{print $4}')" ]; then
    networkctl reconfigure "$other" 2>/dev/null || dhclient "$other" 2>/dev/null || true
  fi
  ip route del default dev "$other" 2>/dev/null || true
done

# Запись /etc/netplan/60-lab5.yaml строго как в lab5 (03_vm2_dhcp_client.sh)
cat > /etc/netplan/60-lab5.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    $IF:
      dhcp4: true
NETPLAN
chmod 600 /etc/netplan/60-lab5.yaml
netplan generate 2>/dev/null && netplan apply 2>/dev/null || true

say "Получение адреса по DHCP от VM1 ($GW) на $IF"
ip link set "$IF" down 2>/dev/null || true
ip addr flush dev "$IF" 2>/dev/null || true
ip link set "$IF" up 2>/dev/null || true

if command -v networkctl >/dev/null && systemctl is-active -q systemd-networkd; then
  run "networkctl reconfigure $IF || netplan apply"
elif command -v dhclient >/dev/null; then
  run "dhclient -r $IF 2>/dev/null || true; timeout 15 dhclient -v $IF || true"
else
  run "netplan apply"
fi

for _ in $(seq 1 15); do
  CUR_IP="$(ip -4 -o addr show dev "$IF" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [ "$CUR_IP" = "$RESERVED_IP" ] || [[ "${CUR_IP:-}" =~ ^$NET_PREFIX\. ]] && break
  sleep 1
done

CUR_IP="$(ip -4 -o addr show dev "$IF" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
if [[ ! "${CUR_IP:-}" =~ ^$NET_PREFIX\. ]]; then
  say "Установка зарезервированного адреса ЛР5 ($RESERVED_IP/24) на $IF"
  run "ip addr flush dev $IF"
  run "ip addr add $RESERVED_IP/24 dev $IF"
fi

# Оставляем маршрут по умолчанию строго через VM1 ($GW на $IF)
for other in $(phys_ifaces); do
  [ "$other" = "$IF" ] && continue
  while ip -4 route show default dev "$other" | grep -q '^default'; do
    ip route del default dev "$other" 2>/dev/null || break
  done
done
run "ip route replace default via $GW dev $IF"

if command -v resolvectl >/dev/null 2>&1; then
  resolvectl dns "$IF" 8.8.8.8 1.1.1.1 2>/dev/null || true
fi
if [ ! -s /etc/resolv.conf ] || ! grep -qE '8\.8\.8\.8|1\.1\.1\.1' /etc/resolv.conf 2>/dev/null; then
  printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf 2>/dev/null || true
fi

say "Сетевые настройки VM2"
run "ip -br addr"
run "ip route"
run "resolvectl status $IF 2>/dev/null | grep -i 'dns servers' || cat /etc/resolv.conf"

say "Проверка маршрутизации через VM1 ($GW)"
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
