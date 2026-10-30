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

say "Определение интерфейса и поиск шлюза VM1"
ALL_IFS=($(ls /sys/class/net | grep -Ev '^(lo|docker.*|virbr.*|br-.*|veth.*|tun.*|tap.*|wl.*)$'))
[ "${#ALL_IFS[@]}" -gt 0 ] || die "не найден сетевой интерфейс"
for i in "${ALL_IFS[@]}"; do ip link set "$i" up 2>/dev/null || true; done

NET100="192.168.$((100+N))"
NET10="192.168.$((10+N))"
GW=""

# Если задан конкретный интерфейс — проверяем только его, иначе перебираем доступные (с приоритетом не-NAT интерфейса)
if [ -n "$IF" ]; then
  CAND_IFS=("$IF")
elif [ "${#ALL_IFS[@]}" -ge 2 ]; then
  # Если 2 адаптера (например enp0s3=NAT и enp0s8=intnet), сначала проверяем второй, затем первый
  CAND_IFS=("${ALL_IFS[1]}" "${ALL_IFS[0]}")
else
  CAND_IFS=("${ALL_IFS[0]}")
fi

try_subnet(){
  local dev="$1" netp="$2" host="${3:-10}"
  ip addr flush dev "$dev" 2>/dev/null || true
  ip addr add "$netp.$host/24" dev "$dev" 2>/dev/null || true
  ip link set "$dev" up 2>/dev/null || true
  if ping -c 2 -W 1 -I "$dev" "$netp.1" >/dev/null 2>&1; then
    IF="$dev"
    GW="$netp.1"
    return 0
  fi
  return 1
}

# 1. Проверяем, отвечает ли уже существующий шлюз 192.168.x.1
for dev in "${CAND_IFS[@]}"; do
  CUR_IP="$(ip -4 -o addr show dev "$dev" | awk '{print $4}' | cut -d/ -f1 | grep '^192\.168\.' | head -n1)"
  if [ -n "$CUR_IP" ]; then
    CAND_GW="${CUR_IP%.*}.1"
    if ping -c 2 -W 1 -I "$dev" "$CAND_GW" >/dev/null 2>&1; then
      IF="$dev"
      GW="$CAND_GW"
      echo "Найден рабочий шлюз VM1: $GW на интерфейсе $IF (текущий IP: $CUR_IP)" | tee -a "$LOG"
      break
    fi
  fi
done

# 2. Если ещё не нашли — пробуем подсеть ЛР6 (192.168.(100+N).0/24) и ЛР5 (192.168.(10+N).0/24)
if [ -z "$GW" ]; then
  for dev in "${CAND_IFS[@]}"; do
    if try_subnet "$dev" "$NET100" 10; then
      echo "VM1 ответила по адресу ЛР6: $GW (интерфейс $IF)" | tee -a "$LOG"
      break
    fi
    if try_subnet "$dev" "$NET10" 50; then
      echo "VM1 ответила по адресу ЛР5: $GW (интерфейс $IF)" | tee -a "$LOG"
      break
    fi
  done
fi

# 3. Если статика не ответила — пробуем получить адрес по DHCP от VM1
if [ -z "$GW" ]; then
  IF="${CAND_IFS[0]}"
  say "Попытка получения адреса по DHCP от VM1 на $IF"
  ip addr flush dev "$IF" 2>/dev/null || true
  if command -v dhclient >/dev/null; then
    run "dhclient -r $IF 2>/dev/null || true; timeout 12 dhclient -v $IF || true"
  else
    run "networkctl reconfigure $IF 2>/dev/null || netplan apply || true"
  fi
  CUR_IP="$(ip -4 -o addr show dev "$IF" | awk '{print $4}' | cut -d/ -f1 | grep '^192\.168\.' | head -n1)"
  if [ -n "$CUR_IP" ]; then
    GW="${CUR_IP%.*}.1"
  else
    say "Статическая настройка $NET100.10/24 на $IF"
    run "ip addr flush dev $IF"
    run "ip addr add $NET100.10/24 dev $IF"
    GW="$NET100.1"
  fi
fi

# Удаляем конкурирующие default-маршруты (например 10.0.2.2 от NAT), чтобы весь трафик шёл через VM1
while ip -4 route show default | grep -q '^default'; do
  ip route del default 2>/dev/null || break
done
run "ip route replace default via $GW dev $IF"

if command -v resolvectl >/dev/null 2>&1; then
  resolvectl dns "$IF" 8.8.8.8 1.1.1.1 2>/dev/null || true
fi
if [ ! -s /etc/resolv.conf ] || ! grep -qE '8\.8\.8\.8|1\.1\.1\.1' /etc/resolv.conf 2>/dev/null; then
  printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf 2>/dev/null || true
fi

say "Сетевые настройки VM2"
run "ip -br addr show $IF"
run "ip route"
run "resolvectl status $IF 2>/dev/null | grep -i 'dns servers' || cat /etc/resolv.conf"

say "Проверка маршрутизации через VM1 ($GW)"
if ! run "ping -c 3 -W 2 $GW"; then
  echo "" | tee -a "$LOG"
  echo "ВНИМАНИЕ: VM1 ($GW) не отвечает на ping по интерфейсу $IF!" | tee -a "$LOG"
  ip neigh show dev "$IF" | tee -a "$LOG"
  echo "Проверь 2 вещи:" | tee -a "$LOG"
  echo "  1) В VirtualBox у VM2: Сеть -> Адаптер должен быть переключён из 'NAT' во 'Внутренняя сеть' (имя: intnet), как у 2-го адаптера VM1." | tee -a "$LOG"
  echo "  2) На VM1 выполнен обновлённый скрипт: sudo bash vm1_router.sh $N" | tee -a "$LOG"
  exit 1
fi
run "ping -c 3 -W 2 8.8.8.8"
run "ping -c 3 -W 2 ya.ru"
if command -v traceroute >/dev/null; then
  run "traceroute -n -m 5 8.8.8.8"
elif command -v tracepath >/dev/null; then
  run "tracepath -n -m 5 8.8.8.8"
fi

say "ГОТОВО"
echo "Лог для отчёта: $LOG" | tee -a "$LOG"
