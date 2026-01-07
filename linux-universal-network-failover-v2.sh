#!/bin/bash

#############################################################################
# Universal Network Failover - v2.0
# - DÜZELTME: "sudo" yazmayı unutsanız bile otomatik yetki alır.
# - Auto-Pilot: Docker ve Servisleri otomatik tarar ve yönetir.
# - Config gerektirmez, tak-çalıştır.
#############################################################################

# --- OTOMATİK ROOT YETKİSİ ALMA (AUTO-SUDO) ---
if [ "$EUID" -ne 0 ]; then
    # Root değilse, sudo ile aynı komutu tekrar çalıştır
    exec sudo "$0" "$@"
fi

# Renkli çıktı
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Sabitler
CONFIG_FILE="/etc/network-failover.conf"
LOG_FILE="/var/log/network-failover.log"
PID_FILE="/var/run/network-failover.pid"

# Varsayılan Değerler
CHECK_INTERVAL=5
PING_TARGETS="8.8.8.8 1.1.1.1"
AUTO_RESTART_DOCKER=true   # Docker konteynerlerini otomatik restart et
AUTO_SCAN_SERVICES=true    # Systemd servislerini otomatik tara
FORCE_DNS_UPDATE=true      # DNS çökmesini önlemek için 8.8.8.8 zorla

# --- CONFIG YÖNETİMİ ---
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        # Config yoksa sessizce varsayılanları kullan
        :
    else
        source "$CONFIG_FILE"
    fi
}

# --- AKILLI TARAMA MOTORU ---
detect_impacted_services() {
    local services_to_restart=""

    # 1. DOCKER KONTEYNER TARAMASI
    if [ "$AUTO_RESTART_DOCKER" == "true" ] && command -v docker &>/dev/null; then
        local containers=$(docker ps --format '{{.Names}}')
        if [ -n "$containers" ]; then
            for cont in $containers; do
                services_to_restart+="docker:$cont "
            done
        fi
    fi

    # 2. SYSTEMD SERVİS TARAMASI
    if [ "$AUTO_SCAN_SERVICES" == "true" ]; then
        local keywords="cloudflared|tailscale|zerotier|openvpn|wireguard|adguard|pihole|nginx|apache|caddy|frp|tunnel|proxy|vpn"
        local sys_services=$(systemctl list-units --type=service --state=active --no-legend | awk '{print $1}' | grep -E "$keywords")
        
        for svc in $sys_services; do
            services_to_restart+="systemd:$svc "
        done
        
        # CasaOS servisi kontrolü
        if systemctl is-active --quiet casaos; then
             services_to_restart+="systemd:casaos.service "
        fi
    fi

    echo "$services_to_restart"
}

# --- HAT DEĞİŞİKLİĞİ YÖNETİCİSİ ---
handle_wan_change() {
    local new_iface=$1
    log_message "INFO" "⚠️  HAT DEĞİŞİKLİĞİ: Yeni Çıkış -> $new_iface"
    
    # 1. DNS Zorlama
    if [ "$FORCE_DNS_UPDATE" == "true" ]; then
        if [ -w "/etc/resolv.conf" ]; then
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            echo "nameserver 1.1.1.1" >> /etc/resolv.conf
            log_message "INFO" "Acil durum DNS'i uygulandı (8.8.8.8)."
        fi
    fi

    # 2. Servis Restart
    local target_list=$(detect_impacted_services)
    
    if [ -z "$target_list" ]; then
        log_message "INFO" "Yeniden başlatılacak kritik servis bulunamadı."
        return
    fi

    log_message "INFO" "🔄 Servisler yeni ağa adapte ediliyor..."
    for item in $target_list; do
        local type=$(echo "$item" | cut -d: -f1)
        local name=$(echo "$item" | cut -d: -f2)

        if [ "$type" == "docker" ]; then
            docker restart "$name" >/dev/null 2>&1 &
        elif [ "$type" == "systemd" ]; then
            systemctl restart "$name" >/dev/null 2>&1 &
        fi
    done
    wait
    log_message "INFO" "✅ Adaptasyon tamamlandı."
}

# --- STANDART FONKSİYONLAR ---
log_message() {
    local level=$1; shift; local message="$@"
    local timestamp=$(date '+%H:%M:%S')
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt 5242880 ]; then mv "$LOG_FILE" "${LOG_FILE}.1"; fi
    fi
    case "$level" in
        ERROR|WARN|INFO) echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE" 2>/dev/null ;;
    esac
}

get_gateway() {
    local gw=$(ip route show dev "$1" | grep default | awk '{print $3}')
    if [ -z "$gw" ]; then
        gw=$(ip route show dev "$1" | grep src | head -1 | awk '{print $1}' | sed 's/\.0\/.*$/.1/')
    fi
    echo "$gw"
}

test_connectivity() {
    for host in $PING_TARGETS; do
        if ping -c 1 -W 1 -I "$1" "$host" &>/dev/null; then return 0; fi
    done
    return 1
}

setup_routing() {
    local iface=$1; local metric=$2
    local gateway=$(get_gateway "$iface")
    if [ -z "$gateway" ]; then return 1; fi
    ip route replace default via "$gateway" dev "$iface" metric "$metric" 2>/dev/null
}

detect_interfaces() {
    local EXCLUDE_LIST="lo|docker|veth|br-|virbr|tun|tap|tailscale|wg"
    for syspath in /sys/class/net/*; do
        local iface=$(basename "$syspath")
        if [[ "$iface" =~ $EXCLUDE_LIST ]]; then continue; fi
        local state=$(cat "$syspath/operstate" 2>/dev/null)
        if [ "$state" != "up" ] && [ "$state" != "unknown" ]; then continue; fi

        local metric=999
        local type="Unknown"

        if [[ ("$iface" == enp* || "$iface" == eth*) && "$iface" != enx* ]]; then
            type="Ethernet"
            metric=100
        elif [[ "$iface" == wlp* ]]; then
            type="Internal-WiFi"
            metric=110
        elif [[ "$iface" == enx* ]]; then
            type="USB-Ethernet/Tether"
            metric=200
        elif [[ "$iface" == wlx* || "$iface" == wlan* ]]; then
            type="USB-WiFi"
            metric=300
        elif [[ "$iface" == ppp* || "$iface" == wwan* || "$iface" == usb* ]]; then
            type="USB/Modem"
            metric=400
        else
            type="Other"
            metric=500
        fi
        echo "$iface:$type:$metric"
    done
}

monitor_connections() {
    if [ -w "/var/run" ]; then echo $$ > "$PID_FILE"; fi
    load_config
    echo -e "${GREEN}Auto-Pilot Mode (v2.0 Auto-Sudo) Başlatıldı...${NC}"
    
    local last_active_iface=""
    while true; do
        mapfile -t ifaces < <(detect_interfaces)
        echo -e "\n${BLUE}═══ Kontrol $(date '+%H:%M:%S') ═══${NC}"
        
        local best_iface=""
        local best_metric=9999
        
        for entry in "${ifaces[@]}"; do
            local iface=$(echo "$entry" | cut -d: -f1)
            local type=$(echo "$entry" | cut -d: -f2)
            local base_metric=$(echo "$entry" | cut -d: -f3)
            
            if test_connectivity "$iface"; then
                echo -e "${GREEN}✓${NC} $iface ($type): OK (Metrik: $base_metric)"
                if [ $base_metric -lt $best_metric ]; then best_metric=$base_metric; best_iface=$iface; fi
                setup_routing "$iface" "$base_metric"
            else
                echo -e "${YELLOW}!${NC} $iface ($type): İNTERNET YOK (Metrik: 5000)"
                setup_routing "$iface" "5000"
            fi
        done
        
        if [ -n "$best_iface" ]; then
            local gw=$(get_gateway "$best_iface")
            if [ -n "$gw" ]; then
                ip route replace default via "$gw" dev "$best_iface" metric 50 2>/dev/null
                if [ "$best_iface" != "$last_active_iface" ]; then
                    if [ -n "$last_active_iface" ]; then handle_wan_change "$best_iface"; else last_active_iface="$best_iface"; fi
                    last_active_iface="$best_iface"
                fi
            fi
        else
            echo -e "${RED} HİÇBİR AĞDA İNTERNET YOK! ${NC}"
        fi
        sleep "$CHECK_INTERVAL"
    done
}

show_detected_services() {
    echo -e "${CYAN}--- OTOMATİK TARAMA RAPORU ---${NC}"
    local list=$(detect_impacted_services)
    if [ -z "$list" ]; then
        echo -e "${YELLOW}Kritik servis bulunamadı.${NC}"
    else
        for item in $list; do
            echo -e "Bulunan: ${GREEN}${item/:/ -> }${NC}"
        done
    fi
    echo "----------------------------------------------"
}

install_service() {
    # Config oluşturma (varsa elleme)
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "AUTO_RESTART_DOCKER=true" > "$CONFIG_FILE"
        echo "AUTO_SCAN_SERVICES=true" >> "$CONFIG_FILE"
        echo "FORCE_DNS_UPDATE=true" >> "$CONFIG_FILE"
    fi
    
    if ! command -v curl &>/dev/null; then apt-get install -y curl; fi
    
    cat > /etc/systemd/system/network-failover.service << EOF
[Unit]
Description=Universal Network Failover (Auto-Pilot)
After=network.target docker.service
[Service]
ExecStart=/usr/local/bin/network-failover.sh monitor
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    cp "$0" /usr/local/bin/network-failover.sh
    chmod +x /usr/local/bin/network-failover.sh
    systemctl daemon-reload
    systemctl enable network-failover.service
    systemctl start network-failover.service
    echo "Kuruldu."
}

uninstall_service() {
    systemctl stop network-failover.service
    systemctl disable network-failover.service
    rm -f /etc/systemd/system/network-failover.service
    rm -f /usr/local/bin/network-failover.sh
    echo "Kaldırıldı."
}

show_menu() {
    while true; do
        clear
        echo -e "${CYAN}--- FAILOVER v2.0 ---${NC}"
        echo "1) Install Service"
        echo "2) Monitor Mode"
        echo "3) Show Detected Services"
        echo "4) Uninstall"
        echo "0) Exit"
        read -p "Seçim: " c
        case $c in
            1) install_service; read -p "..." ;;
            2) monitor_connections ;;
            3) show_detected_services; read -p "..." ;;
            4) uninstall_service; read -p "..." ;;
            0) exit 0 ;;
        esac
    done
}

if [ -z "$1" ]; then show_menu; else
    case "$1" in
        install) install_service ;;
        monitor) monitor_connections ;;
        uninstall) uninstall_service ;;
    esac
fi
