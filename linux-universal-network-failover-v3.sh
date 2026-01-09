#!/bin/bash
# Universal Network Failover v3.4
# - FIX: Gateway ve DNS çift yazma sorunu düzeltildi.
# - FIX: Tablo kayması engellendi.

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

# Renkler
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG_FILE="/var/log/network-failover.log"

# --- VERİ TOPLAMA ---
get_gateway() {
    # Sadece ilk satırı al (head -n 1) ve boşlukları temizle
    local gw=$(ip route show dev "$1" | grep default | awk '{print $3}' | head -n 1)
    if [ -z "$gw" ]; then 
        gw=$(ip route show dev "$1" | grep src | awk '{print $1}' | head -n 1 | sed 's/\.0\/.*$/.1/')
    fi
    echo "$gw" | tr -d '\n'
}

get_dns_info() {
    # Systemd-resolve veya resolvectl
    local d=$(resolvectl status "$1" 2>/dev/null | grep 'DNS Servers' | awk -F: '{print $2}' | xargs | head -n 1)
    # Bulamazsa resolv.conf
    if [ -z "$d" ]; then d=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ' | head -n 1); fi
    # Uzunsa kes ve temizle
    echo "${d// /,}" | cut -c 1-18 | tr -d '\n'
}

test_connectivity() { ping -c 1 -W 1 -I "$1" 8.8.8.8 &>/dev/null || ping -c 1 -W 1 -I "$1" 1.1.1.1 &>/dev/null; }

detect_interfaces() {
    for s in /sys/class/net/*; do
        i=$(basename "$s"); [[ "$i" =~ lo|docker|veth|tun|br ]] && continue
        [ "$(cat $s/operstate 2>/dev/null)" != "up" ] && continue
        local m=999; local t="UNK"
        [[ "$i" == en* ]] && { t="ETH"; m=100; }
        [[ "$i" == wl* ]] && { t="WIFI"; m=110; }
        [[ "$i" == ww* || "$i" == ppp* || "$i" == usb* || "$i" == enx* ]] && { t="MODEM"; m=200; }
        echo "$i:$t:$m"
    done
}

monitor_connections() {
    clear; echo -e "${GREEN}Failover v3.4 (Stable Display) Başlatıldı...${NC}"
    local last_iface=""
    
    while true; do
        # Ekranı temizle ama titretme
        printf "\033[H\033[J"
        echo -e "${BLUE}═══ AĞ PANELİ ($(date '+%H:%M:%S')) ═══${NC}"
        # Sabit genişlikli başlık
        printf "%-12s %-8s %-15s %-15s %-20s %-6s\n" "IFACE" "TYPE" "IP" "GATEWAY" "DNS" "PING"
        echo "--------------------------------------------------------------------------------"
        
        mapfile -t ifaces < <(detect_interfaces)
        local best_iface=""; local best_metric=9999
        
        for entry in "${ifaces[@]}"; do
            IFS=':' read -r iface type metric <<< "$entry"
            
            # Verileri çek ve temizle
            ip_addr=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 | tr -d '\n')
            gw=$(get_gateway "$iface")
            dns=$(get_dns_info "$iface")
            
            color=$NC; ping_stat="FAIL"
            if test_connectivity "$iface"; then
                ping_stat="OK"; color=$GREEN
                [ $metric -lt $best_metric ] && { best_metric=$metric; best_iface=$iface; }
            else
                color=$RED
            fi
            
            # Tabloyu yazdır (Boş veriler için tire koy)
            printf "${color}%-12s %-8s %-15s %-15s %-20s %-6s${NC}\n" \
                "${iface:0:12}" "$type" "${ip_addr:- -}" "${gw:- -}" "${dns:- -}" "$ping_stat"
        done
        echo "--------------------------------------------------------------------------------"

        if [ -n "$best_iface" ]; then
            echo -e "✅ AKTİF HAT: ${GREEN}$best_iface${NC}"
            cur_gw=$(get_gateway "$best_iface")
            if [ -n "$cur_gw" ]; then
                ip route replace default via "$cur_gw" dev "$best_iface" metric 50 2>/dev/null
                if [ "$best_iface" != "$last_iface" ]; then
                    if [ -n "$last_iface" ]; then
                         log_msg="Hat değişimi: $last_iface -> $best_iface"
                         echo -e "${YELLOW}⚠️  $log_msg - Servisler kontrol ediliyor...${NC}"
                         # Servis restart işlemleri burada yapılabilir
                    fi
                    last_iface="$best_iface"
                fi
            fi
        else
            echo -e "${RED}⚠️  HİÇBİR AĞDA İNTERNET YOK!${NC}"
        fi
        sleep 3
    done
}

monitor_connections
