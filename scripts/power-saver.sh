#!/bin/bash
set -euo pipefail

# ===== Constants =====
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

readonly LOG_FILE="/var/log/power-saver.log"
readonly BACKUP_DIR="/var/backups/power-saver"
readonly CONFIG_DIR="/etc/power-saver"
readonly CONFIG_FILE="$CONFIG_DIR/power-saver.conf"
readonly GRUB_CONFIG="/etc/default/grub"
readonly UPDATE_GRUB_CMD="update-grub"
readonly DEPENDENCIES="tlp powertop linux-cpupower"

# Terminal Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Configuration Arrays
declare -A CPU_GOV CPU_EPP MAX_FREQ_PCT TURBO SMT BRIGHTNESS_PCT USB_AUTO PCI_POWER SATA_LPM WIFI_POWER BLUETOOTH
CPU_GOV[0]="performance"; CPU_EPP[0]="performance"; MAX_FREQ_PCT[0]=100; TURBO[0]=1; SMT[0]="on"
BRIGHTNESS_PCT[0]=100; USB_AUTO[0]=0; PCI_POWER[0]="on"; SATA_LPM[0]="max_performance"; WIFI_POWER[0]=0; BLUETOOTH[0]=1
CPU_GOV[1]="ondemand"; CPU_EPP[1]="balance_performance"; MAX_FREQ_PCT[1]=65; TURBO[1]=1; SMT[1]="on"
BRIGHTNESS_PCT[1]=50; USB_AUTO[1]=1; PCI_POWER[1]="auto"; SATA_LPM[1]="med_power_with_dipm"; WIFI_POWER[1]=1; BLUETOOTH[1]=1
CPU_GOV[2]="powersave"; CPU_EPP[2]="balance_power"; MAX_FREQ_PCT[2]=35; TURBO[2]=0; SMT[2]="on"
BRIGHTNESS_PCT[2]=25; USB_AUTO[2]=1; PCI_POWER[2]="auto"; SATA_LPM[2]="min_power"; WIFI_POWER[2]=1; BLUETOOTH[2]=0
CPU_GOV[3]="powersave"; CPU_EPP[3]="power"; MAX_FREQ_PCT[3]=10; TURBO[3]=0; SMT[3]="off"
BRIGHTNESS_PCT[3]=0; USB_AUTO[3]=1; PCI_POWER[3]="auto"; SATA_LPM[3]="min_power"; WIFI_POWER[3]=1; BLUETOOTH[3]=0

declare -A KERNEL_PARAMS
KERNEL_PARAMS[0]=""
KERNEL_PARAMS[1]="intel_idle.max_cstate=9 processor.max_cstate=9 pcie_aspm=powersupersave"
KERNEL_PARAMS[2]="intel_idle.max_cstate=9 processor.max_cstate=9 pcie_aspm=force nohz_full=1"
KERNEL_PARAMS[3]="intel_idle.max_cstate=9 processor.max_cstate=9 pcie_aspm=force nohz_full=1-3"

CPU_VENDOR=""
HAS_INTEL_PSTATE=false
HAS_AMD_PSTATE=false
HAS_CPUFREQ_BOOST=false
HAS_SMT=false
HAS_BACKLIGHT=false

# ===== Logging =====
log() {
    local level msg timestamp
    level="$1"; shift
    msg="$*"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    case "$level" in
        ERROR)   echo -e "${RED}[ERROR]${NC} $msg" >&2 ;;
        WARNING) echo -e "${YELLOW}[WARNING]${NC} $msg" ;;
        INFO)    echo -e "${GREEN}[INFO]${NC} $msg" ;;
        DEBUG)   [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $msg" ;;
    esac
}
log_info()   { log "INFO" "$@"; }
log_warn()   { log "WARNING" "$@"; }
log_error()  { log "ERROR" "$@"; }
log_debug()  { log "DEBUG" "$@"; }

# ===== Help =====
usage() {
    cat <<USAGE_EOF
Usage: $SCRIPT_NAME [OPTIONS] COMMAND [LEVEL]

Advanced power management script for laptops with hardware detection and monitoring.

Commands:
  --runtime --level N      Apply runtime power settings for level N (0-3).
  --permanent --level N    Apply permanent kernel parameters for level N (requires reboot).
  --status                 Show comprehensive current runtime and permanent configuration.
  --battery                Show detailed battery information and health.
  --power-report           Show current power consumption and energy statistics.
  --config --show          Display current configuration for all levels.
  --install                Install this script to /usr/local/bin as 'power-saver'.
  --install-dependencies   Install required packages (apt).
  --restore                Restore previous runtime and grub backups.
  --auto                   Apply level 0 on AC, level 2 on battery.
  --sleep                  Suspend to RAM.
  --hibernate              Suspend to disk.
  --hybrid-sleep           Suspend then hibernate.
  --detect-hardware        Detect and display hardware power management capabilities.
  --create-systemd-service Create systemd service for auto-mode.
  --help                   Show this help.

Levels:
  0: Performance (max speed, min power savings)
  1: Balanced (moderate savings)
  2: Power-saver (aggressive savings)
  3: Extreme (maximum savings, may affect usability)

Examples:
  sudo $SCRIPT_NAME --runtime --level 2
  sudo $SCRIPT_NAME --permanent --level 1
  sudo $SCRIPT_NAME --status
  sudo $SCRIPT_NAME --battery
  sudo $SCRIPT_NAME --detect-hardware
USAGE_EOF
}

# ===== Utilities =====
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

get_power_source() {
    if [[ -d /sys/class/power_supply ]]; then
        for supply in /sys/class/power_supply/*; do
            if [[ -f "$supply/type" ]] && grep -qi "Battery" "$supply/type" 2>/dev/null; then
                if grep -q "Discharging" "$supply/status" 2>/dev/null; then
                    echo "Battery"; return
                elif grep -q "Full\|Charging" "$supply/status" 2>/dev/null; then
                    echo "AC"; return
                fi
            fi
        done
    fi
    for supply in /sys/class/power_supply/*; do
        if [[ -f "$supply/type" ]] && grep -qi "Mains" "$supply/type" 2>/dev/null; then
            if [[ -f "$supply/online" ]] && [[ "$(cat "$supply/online" 2>/dev/null)" == "1" ]]; then
                echo "AC"; return
            fi
        fi
    done
    echo "AC"
}

# ===== Hardware Detection =====
detect_hardware() {
    log_info "Detecting hardware power management capabilities..."
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="Intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="AMD"
    elif grep -q "ARM" /proc/cpuinfo 2>/dev/null; then
        CPU_VENDOR="ARM"
    else
        CPU_VENDOR="Unknown"
    fi
    [[ -d /sys/devices/system/cpu/intel_pstate ]] && HAS_INTEL_PSTATE=true
    [[ -d /sys/devices/system/cpu/amd_pstate ]] && HAS_AMD_PSTATE=true
    [[ -f /sys/devices/system/cpu/cpufreq/boost ]] && HAS_CPUFREQ_BOOST=true
    [[ -f /sys/devices/system/cpu/smt/control ]] && HAS_SMT=true
    [[ -d /sys/class/backlight ]] && HAS_BACKLIGHT=true
    
    echo -e "${GREEN}Hardware Detection Results:${NC}"
    echo "  CPU Vendor: $CPU_VENDOR"
    echo "  Intel P-State: $([[ "$HAS_INTEL_PSTATE" == "true" ]] && echo "Yes" || echo "No")"
    echo "  AMD P-State: $([[ "$HAS_AMD_PSTATE" == "true" ]] && echo "Yes" || echo "No")"
    echo "  CPUFreq Boost: $([[ "$HAS_CPUFREQ_BOOST" == "true" ]] && echo "Yes" || echo "No")"
    echo "  SMT Control: $([[ "$HAS_SMT" == "true" ]] && echo "Yes" || echo "No")"
    echo "  Backlight Control: $([[ "$HAS_BACKLIGHT" == "true" ]] && echo "Yes" || echo "No")"
    [[ -f /sys/class/dmi/id/product_name ]] && echo "  System: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "N/A")"
    [[ -f /sys/class/dmi/id/bios_version ]] && echo "  BIOS Version: $(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "N/A")"
    log_info "Hardware detection complete."
}

# ===== Battery Information =====
show_battery_info() {
    echo -e "${GREEN}Battery Information:${NC}"
    [[ ! -d /sys/class/power_supply ]] && { echo "  No battery information available."; return 1; }
    for supply in /sys/class/power_supply/*; do
        if [[ -f "$supply/type" ]] && grep -qi "Battery" "$supply/type" 2>/dev/null; then
            local name capacity capacity_level status
            name="$(basename "$supply")"
            echo ""
            echo "  ${CYAN}$name:${NC}"
            [[ -f "$supply/capacity" ]] && echo "    Current Charge: $(cat "$supply/capacity" 2>/dev/null)%"
            [[ -f "$supply/capacity_level" ]] && echo "    Capacity Level: $(cat "$supply/capacity_level" 2>/dev/null)"
            [[ -f "$supply/status" ]] && echo "    Status: $(cat "$supply/status" 2>/dev/null)"
            if [[ -f "$supply/energy_full" && -f "$supply/energy_full_design" ]]; then
                local ef efd hp
                ef=$(cat "$supply/energy_full" 2>/dev/null)
                efd=$(cat "$supply/energy_full_design" 2>/dev/null)
                [[ "$efd" -gt 0 ]] && { hp=$((ef * 100 / efd)); echo "    Battery Health: ${hp}% (${ef}uWh / ${efd}uWh)"; }
            fi
            [[ -f "$supply/voltage_now" ]] && echo "    Voltage: $(($(cat "$supply/voltage_now" 2>/dev/null) / 1000000))V"
            [[ -f "$supply/time_to_empty_now" ]] && { local t=$(cat "$supply/time_to_empty_now" 2>/dev/null); [[ "$t" -gt 0 ]] && echo "    Time to Empty: $((t/3600))h $(((t%3600)/60))m"; }
        fi
    done
}

# ===== Power Report =====
show_power_report() {
    echo -e "${GREEN}Power Consumption Report:${NC}"
    if [[ -d /sys/class/powercap ]]; then
        echo -e "\n  ${CYAN}RAPL Power Domains:${NC}"
        for domain in /sys/class/powercap/*; do
            [[ -f "$domain/name" && -f "$domain/energy_uj" ]] && echo "    $(cat "$domain/name" 2>/dev/null): $(($(cat "$domain/energy_uj" 2>/dev/null) / 1000000))J (cumulative)"
        done
    fi
    echo -e "\n  ${CYAN}CPU Frequency Summary:${NC}"
    local tf=0 cc=0
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -f "$policy/scaling_cur_freq" ]] && { tf=$((tf + $(cat "$policy/scaling_cur_freq" 2>/dev/null))); cc=$((cc + 1)); }
    done
    [[ $cc -gt 0 ]] && echo "    Average CPU Frequency: $((tf / cc))kHz across $cc policies"
    echo -e "\n  ${CYAN}Thermal Zones:${NC}"
    [[ -d /sys/class/thermal ]] && for zone in /sys/class/thermal/thermal_zone*; do
        [[ -f "$zone/type" && -f "$zone/temp" ]] && echo "    $(cat "$zone/type" 2>/dev/null): $(($(cat "$zone/temp" 2>/dev/null) / 1000))C"
    done
    echo -e "\n  Power Source: $(get_power_source)"
}

# ===== Runtime Operations =====
backup_runtime() {
    mkdir -p "$BACKUP_DIR"
    local ts="$(date '+%Y%m%d_%H%M%S')"
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -f "$policy/scaling_governor" ]] && cat "$policy/scaling_governor" > "$BACKUP_DIR/$(basename "$policy")_gov" 2>/dev/null || true
        [[ -f "$policy/scaling_max_freq" ]] && cat "$policy/scaling_max_freq" > "$BACKUP_DIR/$(basename "$policy")_max" 2>/dev/null || true
        [[ -f "$policy/energy_performance_preference" ]] && cat "$policy/energy_performance_preference" > "$BACKUP_DIR/$(basename "$policy")_epp" 2>/dev/null || true
    done
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && cat /sys/devices/system/cpu/intel_pstate/no_turbo > "$BACKUP_DIR/intel_no_turbo" 2>/dev/null || true
    [[ -f /sys/devices/system/cpu/cpufreq/boost ]] && cat /sys/devices/system/cpu/cpufreq/boost > "$BACKUP_DIR/cpufreq_boost" 2>/dev/null || true
    [[ -f /sys/devices/system/cpu/smt/control ]] && cat /sys/devices/system/cpu/smt/control > "$BACKUP_DIR/smt_control" 2>/dev/null || true
    echo "$ts" > "$BACKUP_DIR/backup_timestamp"
    log_info "Runtime state saved to $BACKUP_DIR (timestamp: $ts)"
}

restore_runtime() {
    [[ ! -d "$BACKUP_DIR" ]] && { log_warn "No backup found."; return 1; }
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        local n=$(basename "$policy")
        [[ -f "$BACKUP_DIR/${n}_gov" ]] && cat "$BACKUP_DIR/${n}_gov" > "$policy/scaling_governor" 2>/dev/null || true
        [[ -f "$BACKUP_DIR/${n}_max" ]] && cat "$BACKUP_DIR/${n}_max" > "$policy/scaling_max_freq" 2>/dev/null || true
        [[ -f "$BACKUP_DIR/${n}_epp" ]] && cat "$BACKUP_DIR/${n}_epp" > "$policy/energy_performance_preference" 2>/dev/null || true
    done
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo && -f "$BACKUP_DIR/intel_no_turbo" ]] && cat "$BACKUP_DIR/intel_no_turbo" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    [[ -f /sys/devices/system/cpu/cpufreq/boost && -f "$BACKUP_DIR/cpufreq_boost" ]] && cat "$BACKUP_DIR/cpufreq_boost" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    [[ -f /sys/devices/system/cpu/smt/control && -f "$BACKUP_DIR/smt_control" ]] && cat "$BACKUP_DIR/smt_control" > /sys/devices/system/cpu/smt/control 2>/dev/null || true
    log_info "Runtime restored."
    rm -rf "$BACKUP_DIR"
}

apply_runtime() {
    local level="$1"
    log_info "Applying runtime level $level..."
    local gov="${CPU_GOV[$level]}" epp="${CPU_EPP[$level]}" pct="${MAX_FREQ_PCT[$level]}" turbo="${TURBO[$level]}" smt="${SMT[$level]}"
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -f "$policy/scaling_governor" ]] && echo "$gov" > "$policy/scaling_governor" 2>/dev/null || true
        [[ -f "$policy/energy_performance_preference" ]] && echo "$epp" > "$policy/energy_performance_preference" 2>/dev/null || true
        if [[ -f "$policy/cpuinfo_max_freq" && -f "$policy/scaling_max_freq" ]]; then
            local max=$(cat "$policy/cpuinfo_max_freq" 2>/dev/null) || continue
            echo "$((max * pct / 100))" > "$policy/scaling_max_freq" 2>/dev/null || true
        fi
    done
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && echo "$((1 - turbo))" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    [[ -f /sys/devices/system/cpu/cpufreq/boost ]] && echo "$turbo" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    [[ -f /sys/devices/system/cpu/smt/control ]] && echo "$smt" > /sys/devices/system/cpu/smt/control 2>/dev/null || true
    local bpct="${BRIGHTNESS_PCT[$level]}"
    for bl in /sys/class/backlight/*; do
        [[ -f "$bl/max_brightness" ]] && echo "$(($(cat "$bl/max_brightness" 2>/dev/null) * bpct / 100))" > "$bl/brightness" 2>/dev/null || true
    done
    local usb="${USB_AUTO[$level]}"
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/power/control" ]] && echo "$([[ $usb -eq 1 ]] && echo "auto" || echo "on")" > "$dev/power/control" 2>/dev/null || true
    done
    local pci="${PCI_POWER[$level]}"
    for dev in /sys/bus/pci/devices/*; do
        [[ -f "$dev/power/control" ]] && echo "$pci" > "$dev/power/control" 2>/dev/null || true
    done
    local sata="${SATA_LPM[$level]}"
    for host in /sys/class/scsi_host/host*; do
        [[ -f "$host/link_power_management_policy" ]] && echo "$sata" > "$host/link_power_management_policy" 2>/dev/null || true
    done
    local wifi="${WIFI_POWER[$level]}"
    command -v iw >/dev/null 2>&1 && for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
        [[ -n "$iface" ]] && iw dev "$iface" set power_save "$([[ $wifi -eq 1 ]] && echo "on" || echo "off")" 2>/dev/null || true
    done
    local bt="${BLUETOOTH[$level]}"
    command -v rfkill >/dev/null 2>&1 && rfkill "$([[ $bt -eq 1 ]] && echo "unblock" || echo "block")" bluetooth 2>/dev/null || true
    log_info "Runtime level $level applied successfully."
}

# ===== Permanent Operations =====
backup_grub() {
    mkdir -p "$BACKUP_DIR"
    if [[ -f "$GRUB_CONFIG" ]]; then
        cp "$GRUB_CONFIG" "$BACKUP_DIR/grub.orig.$(date '+%Y%m%d_%H%M%S')"
        log_info "GRUB configuration backed up."
    else
        log_warn "GRUB config file not found at $GRUB_CONFIG"
    fi
}

restore_permanent() {
    local latest=$(ls -t "$BACKUP_DIR"/grub.orig.* 2>/dev/null | head -1)
    if [[ -n "$latest" && -f "$latest" ]]; then
        cp "$latest" "$GRUB_CONFIG"
        $UPDATE_GRUB_CMD && log_info "GRUB restored from $latest." || log_error "GRUB restore failed."
    else
        log_warn "No GRUB backup found."
    fi
}

apply_permanent() {
    local level="$1" params="${KERNEL_PARAMS[$level]}"
    [[ ! -f "$GRUB_CONFIG" ]] && { log_error "GRUB config not found at $GRUB_CONFIG"; return 1; }
    backup_grub
    sed -i 's/ intel_idle\.max_cstate=[0-9]*//g; s/ processor\.max_cstate=[0-9]*//g; s/ pcie_aspm=[a-z]*//g; s/ nohz_full=[0-9,-]*//g' "$GRUB_CONFIG"
    [[ -n "$params" ]] && {
        if grep -q "GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_CONFIG"; then
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $params\"/" "$GRUB_CONFIG"
        else
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$params\"" >> "$GRUB_CONFIG"
        fi
    }
    $UPDATE_GRUB_CMD && log_info "Kernel parameters updated for level $level (reboot required)." || log_error "GRUB update failed."
}

# ===== Status =====
show_status() {
    echo -e "${GREEN}Runtime status:${NC}"
    echo "  CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")"
    echo "  EPP: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A")"
    echo "  CPU freq: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")kHz (max limit: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "N/A")kHz)"
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && echo "  Turbo boost: $([ $((1 - $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo 0))) -eq 1 ] && echo "ON" || echo "OFF")"
    [[ -f /sys/devices/system/cpu/cpufreq/boost ]] && echo "  CPU boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo "N/A")"
    [[ -f /sys/devices/system/cpu/smt/control ]] && echo "  SMT: $(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo "N/A")"
    for bl in /sys/class/backlight/*; do
        if [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]]; then
            local c=$(cat "$bl/brightness" 2>/dev/null) m=$(cat "$bl/max_brightness" 2>/dev/null)
            [[ "$m" -gt 0 ]] && echo "  Brightness: $c/$m ($((c * 100 / m))%)" && break
        fi
    done
    local usb_s=$(find /sys/bus/usb/devices -name control -path "*/power/control" 2>/dev/null | head -1)
    [[ -n "$usb_s" ]] && echo "  USB autosuspend (sample): $(cat "$usb_s" 2>/dev/null)"
    local pci_s=$(find /sys/bus/pci/devices -name control -path "*/power/control" 2>/dev/null | head -1)
    [[ -n "$pci_s" ]] && echo "  PCI power (sample): $(cat "$pci_s" 2>/dev/null)"
    local sata_s=$(find /sys/class/scsi_host -name link_power_management_policy 2>/dev/null | head -1)
    [[ -n "$sata_s" ]] && echo "  SATA link power: $(cat "$sata_s" 2>/dev/null)"
    command -v iw >/dev/null 2>&1 && for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
        [[ -n "$iface" ]] && echo "  WiFi ($iface) power save: $(iw dev "$iface" get power_save 2>/dev/null | awk '{print $NF}')"
    done
    command -v rfkill >/dev/null 2>&1 && { local bt=$(rfkill list bluetooth 2>/dev/null | grep -i "Soft blocked" | head -1 | awk '{print $NF}'); echo "  Bluetooth: $([ "$bt" = "yes" ] && echo "blocked" || echo "unblocked")"; }
    echo "  Power source: $(get_power_source)"
    echo -e "\n${GREEN}Permanent kernel parameters:${NC}"
    [[ -f "$GRUB_CONFIG" ]] && echo "  GRUB_CMDLINE_LINUX_DEFAULT: $(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_CONFIG" 2>/dev/null | sed 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/\1/')"
    echo "  Current kernel command line:"
    cat /proc/cmdline
}

# ===== Configuration Display =====
show_config() {
    echo -e "${GREEN}Runtime configuration per level:${NC}"
    for level in 0 1 2 3; do
        echo -e "\n  ${CYAN}Level $level:${NC}"
        echo "    CPU_GOV: ${CPU_GOV[$level]}"
        echo "    CPU_EPP: ${CPU_EPP[$level]}"
        echo "    MAX_FREQ_PCT: ${MAX_FREQ_PCT[$level]}%"
        echo "    TURBO: ${TURBO[$level]}"
        echo "    SMT: ${SMT[$level]}"
        echo "    BRIGHTNESS_PCT: ${BRIGHTNESS_PCT[$level]}%"
        echo "    USB_AUTO: ${USB_AUTO[$level]}"
        echo "    PCI_POWER: ${PCI_POWER[$level]}"
        echo "    SATA_LPM: ${SATA_LPM[$level]}"
        echo "    WIFI_POWER: ${WIFI_POWER[$level]}"
        echo "    BLUETOOTH: ${BLUETOOTH[$level]}"
        echo "    KERNEL_PARAMS: ${KERNEL_PARAMS[$level]:-none}"
    done
}

# ===== Installation =====
install_self() {
    local dest="/usr/local/bin/power-saver"
    cp "$0" "$dest"
    chmod 755 "$dest"
    log_info "Installed to $dest. Now you can run 'power-saver'."
}

install_deps() {
    log_info "Updating package lists..."
    apt update -qq
    # shellcheck disable=SC2086
    apt install -y $DEPENDENCIES
    log_info "Dependencies installed."
}

# ===== Sleep/Hibernate =====
do_sleep() {
    [[ -f /sys/power/state ]] && echo "mem" > /sys/power/state 2>/dev/null || log_error "Suspend failed."
}

do_hibernate() {
    [[ -f /sys/power/state ]] && echo "disk" > /sys/power/state 2>/dev/null || log_error "Hibernate failed."
}

do_hybrid_sleep() {
    if [[ -f /sys/power/state ]]; then
        echo "hybrid" > /sys/power/state 2>/dev/null || { log_info "Hybrid sleep not supported, attempting suspend..."; do_sleep; }
    else
        log_error "/sys/power/state not available."
    fi
}

# ===== Auto Mode =====
auto_mode() {
    local src=$(get_power_source)
    if [[ "$src" == "AC" ]]; then
        apply_runtime 0
        log_info "Auto mode: applied level 0 (Performance) on AC power."
    else
        apply_runtime 2
        log_info "Auto mode: applied level 2 (Power Saver) on battery."
    fi
}

# ===== Create Systemd Service =====
create_systemd_service() {
    check_root
    local sf="/etc/systemd/system/power-saver-auto.service"
    cat > "$sf" << 'SVCEOF'
[Unit]
Description=Power Saver Auto Mode Service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/power-saver --auto
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
    log_info "Created systemd service at $sf"
    log_info "To enable: systemctl enable power-saver-auto.service"
    log_info "To start: systemctl start power-saver-auto.service"
    echo -e "\n${YELLOW}Note:${NC} For automatic switching on AC power change, consider using:"
    echo "  - systemd power-profiles-daemon"
    echo "  - TLP with default settings"
    echo "  - Custom udev rules for power supply changes"
}

# ===== Main =====
main() {
    local cmd="" level=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --runtime)        cmd="runtime"; shift;;
            --permanent)      cmd="permanent"; shift;;
            --status)         cmd="status"; shift;;
            --battery)        cmd="battery"; shift;;
            --power-report)   cmd="power-report"; shift;;
            --config)         shift; [[ "$1" == "--show" ]] && cmd="config"; shift || { log_error "--config requires --show"; exit 1; };;
            --install)        cmd="install"; shift;;
            --install-dependencies) cmd="install-deps"; shift;;
            --restore)        cmd="restore"; shift;;
            --auto)           cmd="auto"; shift;;
            --sleep)          cmd="sleep"; shift;;
            --hibernate)      cmd="hibernate"; shift;;
            --hybrid-sleep)   cmd="hybrid-sleep"; shift;;
            --detect-hardware) cmd="detect"; shift;;
            --create-systemd-service) cmd="create-systemd"; shift;;
            --level)          level="$2"; shift 2;;
            --help|-h)        usage; exit 0;;
            *)                log_error "Unknown option: $1"; usage; exit 1;;
        esac
    done
    [[ -z "$cmd" ]] && { usage; exit 0; }
    if [[ "$cmd" == "runtime" || "$cmd" == "permanent" ]]; then
        [[ ! "$level" =~ ^[0-3]$ ]] && { log_error "Level must be 0,1,2,3."; exit 1; }
    fi
    case "$cmd" in
        runtime|permanent|restore|install-deps|auto|sleep|hibernate|hybrid-sleep|create-systemd)
            check_root
            ;;
    esac
    case "$cmd" in
        runtime)     backup_runtime; apply_runtime "$level";;
        permanent)   apply_permanent "$level";;
        status)      show_status;;
        battery)     show_battery_info;;
        power-report) show_power_report;;
        config)      show_config;;
        install)     install_self;;
        install-deps) install_deps;;
        restore)     restore_runtime; restore_permanent;;
        auto)        auto_mode;;
        sleep)       do_sleep;;
        hibernate)   do_hibernate;;
        hybrid-sleep) do_hybrid_sleep;;
        detect)      detect_hardware;;
        create-systemd) create_systemd_service;;
    esac
}

main "$@"
