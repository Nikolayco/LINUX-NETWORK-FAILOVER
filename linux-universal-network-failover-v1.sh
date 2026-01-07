#!/bin/bash

#############################################################################
# Professional Network Failover Script - v1.0 (CUSTOM PRIORITY)
# - ÖZEL SIRALAMA: Kablo(100) > Dahili Wifi(110) > USB Ethernet(200) > Diğerleri
# - Android telefonlar "USB Ethernet" (200) sınıfına girer.
# - Full özellikler (Menü, Disk Koruma, Stabil Ping) dahildir.
#############################################################################

# Root kontrolü
if [ "$EUID" -ne 0 ]; then
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

# Yapılandırma
CHECK_INTERVAL=5
TEST_HOSTS=("8.8.8.8" "1.1.1.1" "208.67.222.222")
LOG_FILE="/var/log/network-failover.log"
LOG_MAX_SIZE=5242880
LOG_MAX_FILES=2
PID_FILE="/var/run/network-failover.pid"
SERVICES_CONFIG="/etc/network-failover-services.conf"

# Sistem tipi otomatik tespit
DESKTOP_ENV=""
USE_NETWORKMANAGER=false

detect_system_type() {
    if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ] || systemctl is-active --quiet gdm || systemctl is-active --quiet lightdm; then
        DESKTOP_ENV="desktop"
        if systemctl is-active --quiet NetworkManager; then
            USE_NETWORKMANAGER=true
        fi
    else
        DESKTOP_ENV="server"
        USE_NETWORKMANAGER=false
    fi
}

# Varsayılan Servisler
DEFAULT_SERVICES=(
    "cloudflared:systemctl is-active cloudflared:5"
    "cloudflare-warp:systemctl is-active warp-svc:5"
    "tailscaled:systemctl is-active tailscaled:3"
    "anydesk:systemctl is-active anydesk:5"
    "teamviewer:systemctl is-active teamviewerd:5"
)

# Paket Kontrolü
check_dependencies() {
    local packages=("curl" "jq") 
    if ! command -v curl &>/dev/null; then apt-get install -y curl; fi
}

log_message() {
    if [ ! -w "$(dirname "$LOG_FILE")" ]; then return; fi
    local level=$1; shift; local message="$@"
    local timestamp=$(date '+%H:%M:%S')
    
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$LOG_MAX_SIZE" ]; then mv "$LOG_FILE" "${LOG_FILE}.1"; fi
    fi
    
    case "$level" in
        ERROR|WARN|INFO) echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE" 2>/dev/null ;;
        DEBUG) echo "${timestamp} [${level}] ${message}" >> "$LOG_FILE" 2>/dev/null ;;
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
    for host in "${TEST_HOSTS[@]}"; do
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

# --- AKILLI DONANIM ALGILAMA (v1.0 - Özel Sıralama) ---
detect_interfaces() {
    local EXCLUDE_LIST="lo|docker|veth|br-|virbr|tun|tap|tailscale|wg"
    
    for syspath in /sys/class/net/*; do
        local iface=$(basename "$syspath")
        if [[ "$iface" =~ $EXCLUDE_LIST ]]; then continue; fi
        
        local state=$(cat "$syspath/operstate" 2>/dev/null)
        if [ "$state" != "up" ] && [ "$state" != "unknown" ]; then continue; fi

        local metric=999
        local type="Unknown"

        # 1. Kablolu Ethernet (enp..., eth...) -> 100
        # (enx hariç, o USB'dir)
        if [[ ("$iface" == enp* || "$iface" == eth*) && "$iface" != enx* ]]; then
            type="Ethernet"
            metric=100

        # 2. Dahili WiFi (wlp...) -> 110 (Öncelik Yükseltildi)
        elif [[ "$iface" == wlp* ]]; then
            type="Internal-WiFi"
            metric=110
            
        # 3. USB Ethernet / Android Tether (enx...) -> 200
        elif [[ "$iface" == enx* ]]; then
            type="USB-Ethernet"
            metric=200
            
        # 4. Harici USB WiFi (wlx...) -> 300
        elif [[ "$iface" == wlx* || "$iface" == wlan* ]]; then
            # wlp değilse wlan genellikle USB veya eski karttır, sonraya atıyoruz
            type="USB-WiFi"
            metric=300
            
        # 5. Diğer Modemler (ppp...) -> 400
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

# --- MONITOR DÖNGÜSÜ ---
monitor_connections() {
    if [ -w "/var/run" ]; then echo $$ > "$PID_FILE"; fi
    echo -e "${GREEN}Özel Sıralama (v1.0) Başlatıldı...${NC}"
    echo -e "Sıra: Ethernet > Dahili Wifi > USB Ethernet > USB Wifi"
    
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
                
                if [ $base_metric -lt $best_metric ]; then
                    best_metric=$base_metric
                    best_iface=$iface
                fi
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
            fi
        else
            echo -e "${RED} HİÇBİR AĞDA İNTERNET YOK! ${NC}"
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# --- MENÜ ---
install_service() {
    cat > /etc/systemd/system/network-failover.service << EOF
[Unit]
Description=Universal Network Failover
After=network.target
[Service]
ExecStart=/usr/local/bin/network-failover.sh monitor
Restart=always
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
        echo -e "${CYAN}--- UNIVERSAL NETWORK FAILOVER v1.0 (CUSTOM PRIORITY) ---${NC}"
        echo "1) Install (Kur)"
        echo "2) Monitor (Canlı İzle)"
        echo "3) Uninstall (Kaldır)"
        echo "0) Exit (Çıkış)"
        read -p "Select (Seç): " c
        case $c in
            1) install_service; read -p "Devam için Enter..." ;;
            2) monitor_connections ;;
            3) uninstall_service; read -p "Devam için Enter..." ;;
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
