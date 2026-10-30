#!/usr/bin/env bash
set -u

[ "$(id -u)" -eq 0 ] || { echo "ОШИБКА: Запустите скрипт с правами root: sudo bash $0 $*"; exit 1; }

# Аргументы: [роль: vm1|vm2|auto] [номер варианта: N]
ARG1="${1:-}"
ARG2="${2:-}"

ROLE=""
N=""

for a in "$ARG1" "$ARG2"; do
  [ -z "$a" ] && continue
  if [ "$a" = "vm1" ] || [ "$a" = "1" ] || [ "$a" = "router" ]; then
    ROLE="vm1"
  elif [ "$a" = "vm2" ] || [ "$a" = "2" ] || [ "$a" = "client" ]; then
    ROLE="vm2"
  elif [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -gt 2 ]; then
    N="$a"
  fi
done

# Определение номера варианта
if [ -z "$N" ]; then
  # Извлекаем номер из hostname ws24is01-09-00 -> 9
  N="$(hostname 2>/dev/null | grep -oE -- '-[0-9]{2}-' | tr -d '-' | sed 's/^0*//')"
fi
# Если не удалось из hostname, проверяем существующие IP
if [ -z "$N" ]; then
  CANDIDATE="$(ip -4 addr show 2>/dev/null | grep -oE '192\.168\.(1[0-9]{2}|[1-9][0-9]?)\.' | head -n1 | tr -d '.' | sed 's/^192168//')"
  if [ -n "$CANDIDATE" ]; then
    if [ "$CANDIDATE" -ge 100 ]; then
      N="$((CANDIDATE - 100))"
    elif [ "$CANDIDATE" -ge 10 ]; then
      N="$((CANDIDATE - 10))"
    fi
  fi
fi
[ -n "$N" ] || N=9

phys_ifaces(){
  local i
  for i in $(ls /sys/class/net 2>/dev/null); do
    [ -e "/sys/class/net/$i/device" ] && echo "$i"
  done
}

# Автоопределение роли (VM1 или VM2), если не задана явно
if [ -z "$ROLE" ] || [ "$ROLE" = "auto" ]; then
  # 1. Если есть интерфейс с 10.0.2.x (VirtualBox NAT) -> это VM1
  if ip -4 addr show 2>/dev/null | grep -qE 'inet 10\.0\.2\.'; then
    ROLE="vm1"
  elif ip -4 route show default 2>/dev/null | grep -qE '10\.0\.2\.'; then
    ROLE="vm1"
  # 2. Если есть интерфейс с 172.16.x.x (аудиторная сеть на VM2) -> это VM2
  elif ip -4 addr show 2>/dev/null | grep -qE 'inet 172\.16\.'; then
    ROLE="vm2"
  # 3. Если enp0s3 и enp0s8 существуют, пробуем DHCP на enp0s3
  elif [ -d /sys/class/net/enp0s3 ] && [ -d /sys/class/net/enp0s8 ]; then
    dhclient -nw -1 enp0s3 2>/dev/null || true
    if ip -4 addr show dev enp0s3 2>/dev/null | grep -qE 'inet 10\.0\.2\.'; then
      ROLE="vm1"
    else
      ROLE="vm2"
    fi
  else
    ROLE="vm1"
  fi
fi

LOG="$(pwd)/lab6_${ROLE}_report.txt"
: > "$LOG"

say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
run(){ printf '$ %s\n' "$*" | tee -a "$LOG"; bash -c "$*" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
die(){ echo "ОШИБКА: $*" | tee -a "$LOG"; exit 1; }

NET100="192.168.$((100+N))"
NET10="192.168.$((10+N))"
GW100="$NET100.1"
GW10="$NET10.1"

echo "==========================================================" | tee -a "$LOG"
echo "  Лабораторная работа 6 (Firewall в Linux: iptables NAT) " | tee -a "$LOG"
echo "  Роль: $ROLE | Вариант: N=$N                              " | tee -a "$LOG"
echo "  Подсеть ЛР6: $NET100.0/24 | Шлюз: $GW100                " | tee -a "$LOG"
echo "  Подсеть ЛР5: $NET10.0/24  | Шлюз: $GW10                 " | tee -a "$LOG"
echo "==========================================================" | tee -a "$LOG"

# ==============================================================================
# НАСТРОЙКА VM1 (МАРШРУТИЗАТОР)
# ==============================================================================
if [ "$ROLE" = "vm1" ]; then
  say "1. Определение интерфейсов VM1"
  EXT="$(ip -o -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [ -z "$EXT" ] || [ "$EXT" = "lo" ]; then
    EXT="$(ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^10\.0\.2\./ {print $2; exit}')"
  fi
  if [ -z "$EXT" ] && [ -d /sys/class/net/enp0s3 ]; then
    EXT="enp0s3"
  fi
  if [ -z "$EXT" ]; then
    EXT="$(phys_ifaces | head -n1)"
  fi
  [ -n "$EXT" ] && ip link set "$EXT" up 2>/dev/null || true
  [ -n "$EXT" ] || die "Не найден внешний интерфейс (NAT). Проверьте сетевой адаптер 1 в VirtualBox."

  INT=""
  if [ -d /sys/class/net/enp0s8 ] && [ "$EXT" != "enp0s8" ]; then
    INT="enp0s8"
  else
    for i in $(phys_ifaces); do
      [ "$i" != "$EXT" ] && { INT="$i"; break; }
    done
  fi
  [ -n "$INT" ] || die "Не найден внутренний интерфейс (intnet). Включите Адаптер 2 в VirtualBox."

  echo "Внешний интерфейс (NAT): $EXT | Внутренний (intnet): $INT" | tee -a "$LOG"

  say "2. Настройка внутреннего интерфейса $INT"
  ip link set "$INT" up
  ip addr flush dev "$INT"
  run "ip addr add $GW100/24 dev $INT"
  # Дополнительный алиас для совместимости с ЛР5 (192.168.19.1/24)
  run "ip addr add $GW10/24 dev $INT"

  # Персистентность в Netplan
  if [ -d /etc/netplan ]; then
    cat > /etc/netplan/60-lab6.yaml <<EOF
network:
  version: 2
  ethernets:
    $INT:
      dhcp4: false
      addresses:
        - $GW100/24
        - $GW10/24
EOF
    chmod 600 /etc/netplan/60-lab6.yaml
    netplan generate 2>/dev/null && netplan apply 2>/dev/null || true
  fi

  # Настройка isc-dhcp-server (если установлен)
  if command -v dhcpd >/dev/null 2>&1 || [ -f /etc/dhcp/dhcpd.conf ]; then
    say "Настройка isc-dhcp-server для подсетей $NET100.0/24 и $NET10.0/24"
    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$INT\"/" /etc/default/isc-dhcp-server 2>/dev/null || true
    cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
default-lease-time 600;
max-lease-time 7200;

subnet $NET100.0 netmask 255.255.255.0 {
  range $NET100.100 $NET100.200;
  option routers $GW100;
  option subnet-mask 255.255.255.0;
  option broadcast-address $NET100.255;
  option domain-name-servers 8.8.8.8, 1.1.1.1;
}

subnet $NET10.0 netmask 255.255.255.0 {
  range $NET10.100 $NET10.200;
  option routers $GW10;
  option subnet-mask 255.255.255.0;
  option broadcast-address $NET10.255;
  option domain-name-servers 8.8.8.8, 1.1.1.1;
}
EOF
    systemctl enable isc-dhcp-server 2>/dev/null || true
    systemctl restart isc-dhcp-server 2>/dev/null || true
  fi

  say "3. Задание 1. Включение IP-форвардинга (sysctl.conf)"
  if grep -Eq '^[#[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf; then
    sed -i -E 's/^[#[:space:]]*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  run "sysctl -p /etc/sysctl.conf"
  run "sysctl net.ipv4.ip_forward"

  say "4. Задание 2. Правила iptables (маскарадинг)"
  command -v iptables >/dev/null 2>&1 || { apt-get update -y && apt-get install -y iptables; }
  command -v ufw >/dev/null 2>&1 && ufw disable >/dev/null 2>&1 || true

  iptables -P INPUT ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -F
  iptables -t nat -F
  iptables -X 2>/dev/null || true

  run "iptables -A FORWARD -s $NET100.0/24 -j ACCEPT"
  run "iptables -A FORWARD -d $NET100.0/24 -j ACCEPT"
  run "iptables -A FORWARD -s $NET10.0/24 -j ACCEPT"
  run "iptables -A FORWARD -d $NET10.0/24 -j ACCEPT"
  run "iptables -t nat -A POSTROUTING -o $EXT -s $NET100.0/24 -j MASQUERADE"
  run "iptables -t nat -A POSTROUTING -o $EXT -s $NET10.0/24 -j MASQUERADE"

  run "iptables -L -v -n"
  run "iptables -t nat -L -v -n"

  say "5. Задание 3. Сохранение правил и сервис systemd"
  run "mkdir -p /etc/iptables-conf"
  iptables-save -f /etc/iptables-conf/iptables.ipv4 2>/dev/null || iptables-save > /etc/iptables-conf/iptables.ipv4
  run "cat /etc/iptables-conf/iptables.ipv4"

  RESTORE_BIN="$(command -v iptables-restore || echo /sbin/iptables-restore)"
  [ -x /sbin/iptables-restore ] || ln -sf "$RESTORE_BIN" /sbin/iptables-restore 2>/dev/null || true

  cat > /etc/systemd/system/iptables-firewall.service <<EOF
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
EOF
  run "systemctl daemon-reload"
  run "systemctl enable iptables-firewall.service"
  run "systemctl restart iptables-firewall.service"
  run "systemctl status iptables-firewall.service --no-pager"

  say "6. Проверка восстановления правил"
  iptables -F && iptables -t nat -F
  systemctl restart iptables-firewall.service
  run "iptables -t nat -L POSTROUTING -n"

  say "7. Проверка выхода в интернет с VM1"
  run "ping -c 3 -W 2 8.8.8.8"

  # Запуск локальной раздачи скрипта для VM2 (на случай отсутствия интернета на VM2)
  HTTP_DIR="/tmp/lab6_http"
  mkdir -p "$HTTP_DIR"
  if [ -f "$0" ]; then
    cp "$0" "$HTTP_DIR/run.sh" 2>/dev/null || true
    cp "$0" "$HTTP_DIR/lab6.sh" 2>/dev/null || true
  fi
  curl -sSL "https://raw.githubusercontent.com/qwerty-ll/lab6-iptables/main/run.sh" -o "$HTTP_DIR/run.sh" 2>/dev/null || true
  curl -sSL "https://raw.githubusercontent.com/qwerty-ll/lab6-iptables/main/lab6.sh" -o "$HTTP_DIR/lab6.sh" 2>/dev/null || true
  pkill -f "python3 -m http.server 80" 2>/dev/null || true
  nohup python3 -m http.server 80 --directory "$HTTP_DIR" >/dev/null 2>&1 &

  say "VM1 (МАРШРУТИЗАТОР) УСПЕШНО НАСТРОЕНА!"
  echo "Шлюз для VM2: $GW100 (и $GW10)" | tee -a "$LOG"
  echo "" | tee -a "$LOG"
  echo "==========================================================" | tee -a "$LOG"
  echo "КОМАНДА ДЛЯ ЗАПУСКА НА VM2 (КЛИЕНТ):" | tee -a "$LOG"
  echo "  curl -sSL 192.168.109.1/run.sh | sudo bash" | tee -a "$LOG"
  echo "  (или: wget -qO- 192.168.109.1/run.sh | sudo bash)" | tee -a "$LOG"
  echo "  (или через github: curl -sSL https://raw.githubusercontent.com/qwerty-ll/lab6-iptables/main/run.sh | sudo bash)" | tee -a "$LOG"
  echo "==========================================================" | tee -a "$LOG"

# ==============================================================================
# НАСТРОЙКА VM2 (КЛИЕНТ)
# ==============================================================================
elif [ "$ROLE" = "vm2" ]; then
  say "1. Определение интерфейса VM2"
  IF=""
  # На VM2 адаптер 1 (enp0s3) подключен к intnet
  if [ -d /sys/class/net/enp0s3 ]; then
    IF="enp0s3"
  else
    for i in $(phys_ifaces); do
      if ! ip -4 addr show dev "$i" 2>/dev/null | grep -qE '172\.16\.'; then
        IF="$i"
        break
      fi
    done
  fi
  [ -n "$IF" ] || IF="$(phys_ifaces | head -n1)"
  [ -n "$IF" ] || die "Не найден сетевой интерфейс на VM2."
  echo "Интерфейс внутренней сети: $IF" | tee -a "$LOG"

  # Если есть второй адаптер (аудиторная сеть), снимаем с него маршрут по умолчанию
  for other in $(phys_ifaces); do
    [ "$other" = "$IF" ] && continue
    while ip -4 route show default dev "$other" 2>/dev/null | grep -q '^default'; do
      ip route del default dev "$other" 2>/dev/null || break
    done
  done

  say "2. Настройка IP-адресов и шлюза"
  ip link set "$IF" up
  ip addr flush dev "$IF"

  # Устанавливаем адрес подсети ЛР6 (192.168.109.10/24) + резервный .50 + ЛР5 алиас
  run "ip addr add $NET100.10/24 dev $IF"
  ip addr add "$NET100.50/24" dev "$IF" 2>/dev/null || true
  ip addr add "$NET10.50/24" dev "$IF" 2>/dev/null || true

  # Установка маршрута по умолчанию строго через VM1
  while ip -4 route show default 2>/dev/null | grep -q '^default'; do
    ip route del default 2>/dev/null || break
  done
  run "ip route replace default via $GW100 dev $IF"

  # Настройка DNS
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl dns "$IF" 8.8.8.8 1.1.1.1 2>/dev/null || true
  fi
  printf "nameserver 8.8.8.8\nnameserver 1.1.1.1\n" > /etc/resolv.conf 2>/dev/null || true

  # Персистентность в Netplan
  if [ -d /etc/netplan ]; then
    cat > /etc/netplan/60-lab6.yaml <<EOF
network:
  version: 2
  ethernets:
    $IF:
      dhcp4: false
      addresses:
        - $NET100.10/24
        - $NET100.50/24
        - $NET10.50/24
      routes:
        - to: default
          via: $GW100
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF
    chmod 600 /etc/netplan/60-lab6.yaml
    netplan generate 2>/dev/null && netplan apply 2>/dev/null || true
  fi

  say "3. Текущие сетевые настройки VM2"
  run "ip -br addr"
  run "ip route"

  say "4. Проверка связности и выхода в интернет через VM1"
  say "4.1. Ping до шлюза VM1 ($GW100)"
  run "ping -c 3 -W 2 $GW100" || die "Шлюз VM1 ($GW100) не отвечает! Убедитесь, что скрипт уже запущен на VM1 и сеть в VirtualBox установлена в 'intnet'."

  say "4.2. Ping до внешнего IP (8.8.8.8 через NAT VM1)"
  run "ping -c 3 -W 2 8.8.8.8"

  say "4.3. Ping до домена (ya.ru)"
  run "ping -c 3 -W 2 ya.ru"

  if command -v traceroute >/dev/null 2>&1; then
    run "traceroute -n -m 5 8.8.8.8"
  elif command -v tracepath >/dev/null 2>&1; then
    run "tracepath -n -m 5 8.8.8.8"
  fi

  say "VM2 (КЛИЕНТ) НАСТРОЕНА И ВСЕ ПРОВЕРКИ ПРОШЛИ УСПЕШНО!"
fi

echo "Лог сохранён в: $LOG" | tee -a "$LOG"
