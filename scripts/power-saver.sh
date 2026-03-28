#!/bin/bash
set -euo pipefail

# ===== Constants =====
readonly SCRIPT_NAME="$(basename "$0")"
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
readonly NC='\033[0m'

# ===== Configuration Arrays (0:performance,1:balanced,2:saver,3:extreme) =====
declare -A CPU_GOV CPU_EPP MAX_FREQ_PCT TURBO SMT BRIGHTNESS_PCT USB_AUTO PCI_POWER SATA_LPM WIFI_POWER BLUETOOTH
# Level 0
CPU_GOV[0]="performance"; CPU_EPP[0]="performance"; MAX_FREQ_PCT[0]=100; TURBO[0]=1; SMT[0]="on"
BRIGHTNESS_PCT[0]=100; USB_AUTO[0]=0; PCI_POWER[0]="on"; SATA_LPM[0]="max_performance"; WIFI_POWER[0]=0; BLUETOOTH[0]=1
# Level 1
CPU_GOV[1]="ondemand"; CPU_EPP[1]="balance_performance"; MAX_FREQ_PCT[1]=65; TURBO[1]=1; SMT[1]="on"
BRIGHTNESS_PCT[1]=50; USB_AUTO[1]=1; PCI_POWER[1]="auto"; SATA_LPM[1]="med_power_with_dipm"; WIFI_POWER[1]=1; BLUETOOTH[1]=1
# Level 2
CPU_GOV[2]="powersave"; CPU_EPP[2]="balance_power"; MAX_FREQ_PCT[2]=35; TURBO[2]=0; SMT[2]="on"
BRIGHTNESS_PCT[2]=25; USB_AUTO[2]=1; PCI_POWER[2]="auto"; SATA_LPM[2]="min_power"; WIFI_POWER[2]=1; BLUETOOTH[2]=0
# Level 3
CPU_GOV[3]="powersave"; CPU_EPP[3]="power"; MAX_FREQ_PCT[3]=10; TURBO[3]=0; SMT[3]="off"
BRIGHTNESS_PCT[3]=0; USB_AUTO[3]=1; PCI_POWER[3]="auto"; SATA_LPM[3]="min_power"; WIFI_POWER[3]=1; BLUETOOTH[3]=0

# Kernel parameters per level (for --permanent)
declare -A KERNEL_PARAMS
KERNEL_PARAMS[0]=""
KERNEL_PARAMS[1]="intel_idle.max_cstate=9 processor.max_cstate=9 pcie_aspm=powersupersave"
KERNEL_PARAMS[2]="intel_idle.max_cstate=9 processor.max_cstate=9 pcie_aspm=force nohz_full=1"
KERNEL_PARAMS[3]="intel_idle.max_cstate=9 processor.max_cstate=9 pcie_aspm=force nohz_full=1-3"

# ===== Logging =====
log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
    case "$level" in
        ERROR)   echo -e "${RED}[ERROR]${NC} $msg" >&2 ;;
        WARNING) echo -e "${YELLOW}[WARNING]${NC} $msg" ;;
        INFO)    echo -e "${GREEN}[INFO]${NC} $msg" ;;
    esac
}
log_info()   { log "INFO" "$@"; }
log_warn()   { log "WARNING" "$@"; }
log_error()  { log "ERROR" "$@"; }

# ===== Help =====
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] COMMAND [LEVEL]

Power management script for laptops. Sets runtime or permanent power profiles.

Commands:
  --runtime --level N      Apply runtime power settings for level N (0-3).
  --permanent --level N    Apply permanent kernel parameters for level N (requires reboot).
  --status                 Show current runtime and permanent configuration.
  --config --show          Display current configuration for all levels.
  --install                Install this script to /usr/local/bin as 'power-saver'.
  --install-dependencies   Install required packages (apt).
  --restore                Restore previous runtime and grub backups.
  --auto                   Apply level 0 on AC, level 2 on battery.
  --sleep                  Suspend to RAM.
  --hibernate              Suspend to disk.
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
  sudo $SCRIPT_NAME --install-dependencies
EOF
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
            if [[ -f "$supply/type" ]] && grep -qi "Battery" "$supply/type"; then
                if grep -q "Discharging" "$supply/status" 2>/dev/null; then
                    echo "Battery"; return
                fi
            fi
        done
    fi
    echo "AC"
}

# ===== Runtime Operations =====
backup_runtime() {
    mkdir -p "$BACKUP_DIR"
    # CPU
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -f "$policy/scaling_governor" ]] && cat "$policy/scaling_governor" > "$BACKUP_DIR/$(basename "$policy")_gov" 2>/dev/null
        [[ -f "$policy/scaling_max_freq" ]] && cat "$policy/scaling_max_freq" > "$BACKUP_DIR/$(basename "$policy")_max" 2>/dev/null
        [[ -f "$policy/energy_performance_preference" ]] && cat "$policy/energy_performance_preference" > "$BACKUP_DIR/$(basename "$policy")_epp" 2>/dev/null
    done
    # Turbo
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]] && cat /sys/devices/system/cpu/intel_pstate/no_turbo > "$BACKUP_DIR/intel_no_turbo"
    [[ -f /sys/devices/system/cpu/cpufreq/boost ]] && cat /sys/devices/system/cpu/cpufreq/boost > "$BACKUP_DIR/cpufreq_boost"
    # SMT
    [[ -f /sys/devices/system/cpu/smt/control ]] && cat /sys/devices/system/cpu/smt/control > "$BACKUP_DIR/smt_control"
    # Brightness
    for bl in /sys/class/backlight/*; do
        [[ -f "$bl/brightness" ]] && cat "$bl/brightness" > "$BACKUP_DIR/$(basename "$bl")_bright"
    done
    # USB
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/power/control" ]] && cat "$dev/power/control" > "$BACKUP_DIR/usb_$(basename "$dev")_ctrl"
    done
    # PCI
    for dev in /sys/bus/pci/devices/*; do
        [[ -f "$dev/power/control" ]] && cat "$dev/power/control" > "$BACKUP_DIR/pci_$(basename "$dev")_ctrl"
    done
    # SATA
    for host in /sys/class/scsi_host/host*; do
        [[ -f "$host/link_power_management_policy" ]] && cat "$host/link_power_management_policy" > "$BACKUP_DIR/$(basename "$host")_lpm"
    done
    log_info "Runtime state saved to $BACKUP_DIR"
}

restore_runtime() {
    [[ ! -d "$BACKUP_DIR" ]] && { log_warn "No backup found."; return 1; }
    # CPU
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        name=$(basename "$policy")
        [[ -f "$BACKUP_DIR/${name}_gov" ]] && cat "$BACKUP_DIR/${name}_gov" > "$policy/scaling_governor" 2>/dev/null
        [[ -f "$BACKUP_DIR/${name}_max" ]] && cat "$BACKUP_DIR/${name}_max" > "$policy/scaling_max_freq" 2>/dev/null
        [[ -f "$BACKUP_DIR/${name}_epp" ]] && cat "$BACKUP_DIR/${name}_epp" > "$policy/energy_performance_preference" 2>/dev/null
    done
    # Turbo
    [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo && -f "$BACKUP_DIR/intel_no_turbo" ]] && cat "$BACKUP_DIR/intel_no_turbo" > /sys/devices/system/cpu/intel_pstate/no_turbo
    [[ -f /sys/devices/system/cpu/cpufreq/boost && -f "$BACKUP_DIR/cpufreq_boost" ]] && cat "$BACKUP_DIR/cpufreq_boost" > /sys/devices/system/cpu/cpufreq/boost
    # SMT
    [[ -f /sys/devices/system/cpu/smt/control && -f "$BACKUP_DIR/smt_control" ]] && cat "$BACKUP_DIR/smt_control" > /sys/devices/system/cpu/smt/control
    # Brightness
    for bl in /sys/class/backlight/*; do
        name=$(basename "$bl")
        [[ -f "$BACKUP_DIR/${name}_bright" ]] && cat "$BACKUP_DIR/${name}_bright" > "$bl/brightness"
    done
    # USB
    for dev in /sys/bus/usb/devices/*; do
        name=$(basename "$dev")
        [[ -f "$BACKUP_DIR/usb_${name}_ctrl" ]] && cat "$BACKUP_DIR/usb_${name}_ctrl" > "$dev/power/control"
    done
    # PCI
    for dev in /sys/bus/pci/devices/*; do
        name=$(basename "$dev")
        [[ -f "$BACKUP_DIR/pci_${name}_ctrl" ]] && cat "$BACKUP_DIR/pci_${name}_ctrl" > "$dev/power/control"
    done
    # SATA
    for host in /sys/class/scsi_host/host*; do
        name=$(basename "$host")
        [[ -f "$BACKUP_DIR/${name}_lpm" ]] && cat "$BACKUP_DIR/${name}_lpm" > "$host/link_power_management_policy"
    done
    log_info "Runtime restored."
    rm -rf "$BACKUP_DIR"
}

apply_runtime() {
    local level="$1"
    log_info "Applying runtime level $level..."

    # CPU governor
    gov="${CPU_GOV[$level]}"
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -f "$policy/scaling_governor" ]] && echo "$gov" > "$policy/scaling_governor" 2>/dev/null
    done
    # EPP
    epp="${CPU_EPP[$level]}"
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -f "$policy/energy_performance_preference" ]] && echo "$epp" > "$policy/energy_performance_preference" 2>/dev/null
    done
    # Frequency limits
    pct="${MAX_FREQ_PCT[$level]}"
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        [[ -f "$policy/cpuinfo_max_freq" && -f "$policy/scaling_max_freq" ]] && {
            max=$(cat "$policy/cpuinfo_max_freq")
            new=$(( max * pct / 100 ))
            echo "$new" > "$policy/scaling_max_freq"
            echo "0" > "$policy/scaling_min_freq"
        }
    done
    # Turbo
    turbo="${TURBO[$level]}"
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        echo $(( 1 - turbo )) > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null
    fi
    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        echo "$turbo" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null
    fi
    # SMT
    smt="${SMT[$level]}"
    [[ -f /sys/devices/system/cpu/smt/control ]] && echo "$smt" > /sys/devices/system/cpu/smt/control 2>/dev/null
    # Brightness
    bright_pct="${BRIGHTNESS_PCT[$level]}"
    for bl in /sys/class/backlight/*; do
        if [[ -f "$bl/max_brightness" ]]; then
            max=$(cat "$bl/max_brightness")
            new=$(( max * bright_pct / 100 ))
            echo "$new" > "$bl/brightness"
        fi
    done
    # USB autosuspend
    usb="${USB_AUTO[$level]}"
    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/power/control" ]] && {
            [[ $usb -eq 1 ]] && echo "auto" > "$dev/power/control" || echo "on" > "$dev/power/control"
        }
    done
    # PCI power
    pci="${PCI_POWER[$level]}"
    for dev in /sys/bus/pci/devices/*; do
        [[ -f "$dev/power/control" ]] && echo "$pci" > "$dev/power/control"
    done
    # SATA link power
    sata="${SATA_LPM[$level]}"
    for host in /sys/class/scsi_host/host*; do
        [[ -f "$host/link_power_management_policy" ]] && echo "$sata" > "$host/link_power_management_policy"
    done
    # WiFi power save
    wifi="${WIFI_POWER[$level]}"
    if command -v iw >/dev/null; then
        for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
            iw dev "$iface" set power_save "$([[ $wifi -eq 1 ]] && echo "on" || echo "off")" 2>/dev/null
        done
    fi
    # Bluetooth
    bt="${BLUETOOTH[$level]}"
    if command -v rfkill >/dev/null; then
        rfkill "$([[ $bt -eq 1 ]] && echo "unblock" || echo "block")" bluetooth 2>/dev/null
    fi
    log_info "Runtime level $level applied."
}

# ===== Permanent Operations =====
backup_grub() {
    mkdir -p "$BACKUP_DIR"
    cp "$GRUB_CONFIG" "$BACKUP_DIR/grub.orig" 2>/dev/null || true
    log_info "GRUB configuration backed up."
}

restore_permanent() {
    if [[ -f "$BACKUP_DIR/grub.orig" ]]; then
        cp "$BACKUP_DIR/grub.orig" "$GRUB_CONFIG"
        $UPDATE_GRUB_CMD && log_info "GRUB restored." || log_error "GRUB restore failed."
    else
        log_warn "No GRUB backup found."
    fi
}

apply_permanent() {
    local level="$1"
    local params="${KERNEL_PARAMS[$level]}"
    backup_grub
    # Remove existing power-related parameters
    sed -i 's/ intel_idle\.max_cstate=[0-9]*//g' "$GRUB_CONFIG"
    sed -i 's/ processor\.max_cstate=[0-9]*//g' "$GRUB_CONFIG"
    sed -i 's/ pcie_aspm=[a-z]*//g' "$GRUB_CONFIG"
    sed -i 's/ nohz_full=[0-9,-]*//g' "$GRUB_CONFIG"
    # Add new parameters if any
    if [[ -n "$params" ]]; then
        if grep -q "GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_CONFIG"; then
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $params\"/" "$GRUB_CONFIG"
        else
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$params\"" >> "$GRUB_CONFIG"
        fi
    fi
    $UPDATE_GRUB_CMD && log_info "Kernel parameters updated for level $level (reboot required)." || log_error "GRUB update failed."
}

# ===== Status =====
show_status() {
    echo -e "${GREEN}Runtime status:${NC}"
    # CPU governor
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    echo "  CPU governor: $gov"
    # EPP
    epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A")
    echo "  EPP: $epp"
    # Frequency limits
    cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")
    max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "N/A")
    echo "  CPU freq: ${cur}kHz (max limit: ${max}kHz)"
    # Turbo
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        turbo=$((1 - $(cat /sys/devices/system/cpu/intel_pstate/no_turbo)))
        echo "  Turbo boost: $([ $turbo -eq 1 ] && echo "ON" || echo "OFF")"
    fi
    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        boost=$(cat /sys/devices/system/cpu/cpufreq/boost)
        echo "  CPU boost: $boost"
    fi
    # SMT
    [[ -f /sys/devices/system/cpu/smt/control ]] && echo "  SMT: $(cat /sys/devices/system/cpu/smt/control)"
    # Brightness
    for bl in /sys/class/backlight/*; do
        [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]] && {
            curr=$(cat "$bl/brightness")
            maxb=$(cat "$bl/max_brightness")
            pct=$((curr * 100 / maxb))
            echo "  Brightness: $curr/$maxb ($pct%)"
            break
        }
    done
    # USB autosuspend (sample)
    usb_sample=$(find /sys/bus/usb/devices -name control -path "*/power/control" 2>/dev/null | head -1)
    [[ -n "$usb_sample" ]] && echo "  USB autosuspend (sample): $(cat "$usb_sample")"
    # PCI power (sample)
    pci_sample=$(find /sys/bus/pci/devices -name control -path "*/power/control" 2>/dev/null | head -1)
    [[ -n "$pci_sample" ]] && echo "  PCI power (sample): $(cat "$pci_sample")"
    # SATA LPM
    sata_sample=$(find /sys/class/scsi_host -name link_power_management_policy 2>/dev/null | head -1)
    [[ -n "$sata_sample" ]] && echo "  SATA link power: $(cat "$sata_sample")"
    # WiFi
    if command -v iw >/dev/null; then
        for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
            ps=$(iw dev "$iface" get power_save 2>/dev/null | awk '{print $NF}')
            echo "  WiFi ($iface) power save: $ps"
        done
    fi
    # Bluetooth
    if command -v rfkill >/dev/null; then
        bt_state=$(rfkill list bluetooth | grep -i "Soft blocked" | head -1 | awk '{print $NF}')
        echo "  Bluetooth: $([ "$bt_state" = "yes" ] && echo "blocked" || echo "unblocked")"
    fi
    # Power source
    echo "  Power source: $(get_power_source)"

    echo -e "\n${GREEN}Permanent kernel parameters:${NC}"
    if [[ -f "$GRUB_CONFIG" ]]; then
        grub_params=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_CONFIG" | sed 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/\1/')
        echo "  GRUB_CMDLINE_LINUX_DEFAULT: $grub_params"
    fi
    echo "  Current kernel command line:"
    cat /proc/cmdline
}

# ===== Configuration Display =====
show_config() {
    echo -e "${GREEN}Runtime configuration per level:${NC}"
    for level in 0 1 2 3; do
        echo "Level $level:"
        echo "  CPU_GOV: ${CPU_GOV[$level]}"
        echo "  CPU_EPP: ${CPU_EPP[$level]}"
        echo "  MAX_FREQ_PCT: ${MAX_FREQ_PCT[$level]}%"
        echo "  TURBO: ${TURBO[$level]}"
        echo "  SMT: ${SMT[$level]}"
        echo "  BRIGHTNESS_PCT: ${BRIGHTNESS_PCT[$level]}%"
        echo "  USB_AUTO: ${USB_AUTO[$level]}"
        echo "  PCI_POWER: ${PCI_POWER[$level]}"
        echo "  SATA_LPM: ${SATA_LPM[$level]}"
        echo "  WIFI_POWER: ${WIFI_POWER[$level]}"
        echo "  BLUETOOTH: ${BLUETOOTH[$level]}"
        echo "  KERNEL_PARAMS: ${KERNEL_PARAMS[$level]}"
        echo
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
    apt update -qq
    apt install -y $DEPENDENCIES
    log_info "Dependencies installed."
}

# ===== Sleep/Hibernate =====
do_sleep() {
    echo "mem" > /sys/power/state 2>/dev/null || log_error "Suspend failed."
}
do_hibernate() {
    echo "disk" > /sys/power/state 2>/dev/null || log_error "Hibernate failed."
}

# ===== Auto =====
auto_mode() {
    source=$(get_power_source)
    if [[ "$source" == "AC" ]]; then
        apply_runtime 0
    else
        apply_runtime 2
    fi
    log_info "Auto mode: applied level $([[ "$source" == "AC" ]] && echo 0 || echo 2)."
}

# ===== Main =====
main() {
    local cmd=""
    local level=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --runtime)        cmd="runtime"; shift;;
            --permanent)      cmd="permanent"; shift;;
            --status)         cmd="status"; shift;;
            --config)         shift; [[ "$1" == "--show" ]] && cmd="config"; shift || { log_error "--config requires --show"; exit 1; };;
            --install)        cmd="install"; shift;;
            --install-dependencies) cmd="install-deps"; shift;;
            --restore)        cmd="restore"; shift;;
            --auto)           cmd="auto"; shift;;
            --sleep)          cmd="sleep"; shift;;
            --hibernate)      cmd="hibernate"; shift;;
            --level)          level="$2"; shift 2;;
            --help|-h)        usage; exit 0;;
            *)                log_error "Unknown option: $1"; usage; exit 1;;
        esac
    done

    # Default to help if no command
    if [[ -z "$cmd" ]]; then
        usage
        exit 0
    fi

    # Level validation for commands that need it
    if [[ "$cmd" == "runtime" || "$cmd" == "permanent" ]]; then
        if [[ ! "$level" =~ ^[0-3]$ ]]; then
            log_error "Level must be 0,1,2,3."
            exit 1
        fi
    fi

    # Root check for commands that modify system
    case "$cmd" in
        runtime|permanent|restore|install-deps|auto|sleep|hibernate)
            check_root
            ;;
    esac

    # Execute command
    case "$cmd" in
        runtime)   backup_runtime; apply_runtime "$level";;
        permanent) apply_permanent "$level";;
        status)    show_status;;
        config)    show_config;;
        install)   install_self;;
        install-deps) install_deps;;
        restore)   restore_runtime; restore_permanent;;
        auto)      auto_mode;;
        sleep)     do_sleep;;
        hibernate) do_hibernate;;
    esac
}

main "$@"
