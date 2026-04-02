#!/usr/bin/env python3
"""System Monitor - Display system information and resource usage."""

# =============================================================================
# Imports & Constants
# =============================================================================
import sys
import os
import argparse
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Tuple

SCRIPT_NAME = "sysmon"
VERSION = "1.0.0"

# Terminal colors
C = {'R': '\033[0;31m', 'G': '\033[0;32m', 'Y': '\033[1;33m', 'B': '\033[0;34m',
     'C': '\033[0;36m', 'BD': '\033[1m', 'NC': '\033[0m'}


# =============================================================================
# Logging Helpers
# =============================================================================
def log_error(msg: str) -> None:
    """Print error message to stderr."""
    print(f"{C['R']}[ERROR]{C['NC']} {msg}", file=sys.stderr)


def log_warn(msg: str) -> None:
    """Print warning message to stderr."""
    print(f"{C['Y']}[WARNING]{C['NC']} {msg}", file=sys.stderr)


def log_info(msg: str) -> None:
    """Print info message to stdout."""
    print(f"{C['G']}[INFO]{C['NC']} {msg}")


# =============================================================================
# System Information Functions
# =============================================================================
def get_cpu_usage() -> float:
    """Get current CPU usage percentage."""
    try:
        with open('/proc/stat', 'r') as f:
            line = f.readline()
            parts = line.split()
            if parts[0] == 'cpu':
                values = [int(x) for x in parts[1:8]]
                idle = values[3]
                total = sum(values)
                # Simple snapshot (not delta-based)
                return 0.0  # Would need two samples for accurate measurement
    except Exception:
        pass
    return 0.0


def get_memory_info() -> Dict[str, int]:
    """Get memory information in KB."""
    mem_info = {}
    try:
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                parts = line.split(':')
                if len(parts) == 2:
                    key = parts[0].strip()
                    value = int(parts[1].strip().split()[0])
                    mem_info[key] = value
    except Exception:
        pass
    return mem_info


def get_disk_usage(path: str = "/") -> Dict[str, int]:
    """Get disk usage for given path."""
    try:
        stat = os.statvfs(path)
        total = stat.f_blocks * stat.f_frsize
        free = stat.f_bfree * stat.f_frsize
        available = stat.f_bavail * stat.f_frsize
        used = total - free
        return {
            'total': total,
            'used': used,
            'free': free,
            'available': available,
            'percent': (used / total * 100) if total > 0 else 0
        }
    except Exception:
        return {}


def get_cpu_temp() -> Optional[float]:
    """Get CPU temperature in Celsius."""
    temp_paths = [
        '/sys/class/thermal/thermal_zone0/temp',
        '/sys/class/hwmon/hwmon0/temp1_input',
        '/sys/class/hwmon/hwmon1/temp1_input',
    ]
    
    for path in temp_paths:
        try:
            with open(path, 'r') as f:
                temp = int(f.read().strip())
                # Some sensors report in millidegrees, some in degrees
                if temp > 1000:
                    return temp / 1000.0
                return float(temp)
        except Exception:
            continue
    return None


def get_battery_info() -> List[Dict[str, str]]:
    """Get battery information."""
    batteries = []
    try:
        supply_dir = Path('/sys/class/power_supply')
        if supply_dir.exists():
            for supply in supply_dir.iterdir():
                if supply.is_dir() and 'BAT' in supply.name:
                    bat_info = {'name': supply.name}
                    
                    files = {
                        'status': 'status',
                        'capacity': 'capacity',
                        'voltage_now': 'voltage_now',
                        'energy_full': 'energy_full',
                        'energy_full_design': 'energy_full_design',
                    }
                    
                    for key, filename in files.items():
                        try:
                            with open(supply / filename, 'r') as f:
                                bat_info[key] = f.read().strip()
                        except Exception:
                            pass
                    
                    batteries.append(bat_info)
    except Exception:
        pass
    
    return batteries


def get_network_stats() -> List[Dict[str, str]]:
    """Get network interface statistics."""
    interfaces = []
    try:
        with open('/proc/net/dev', 'r') as f:
            lines = f.readlines()[2:]  # Skip header
            for line in lines:
                parts = line.split(':')
                if len(parts) == 2:
                    name = parts[0].strip()
                    stats = parts[1].split()
                    if len(stats) >= 9:
                        interfaces.append({
                            'name': name,
                            'rx_bytes': stats[0],
                            'rx_packets': stats[1],
                            'tx_bytes': stats[8],
                            'tx_packets': stats[9],
                        })
    except Exception:
        pass
    
    return interfaces


def get_top_processes(n: int = 10) -> List[Dict[str, str]]:
    """Get top processes by CPU usage."""
    processes = []
    try:
        result = subprocess.run(
            ['ps', 'aux', '--sort=-%cpu'],
            capture_output=True,
            text=True,
            timeout=5
        )
        lines = result.stdout.strip().split('\n')[1:n+1]  # Skip header
        for line in lines:
            parts = line.split(None, 10)
            if len(parts) >= 11:
                processes.append({
                    'user': parts[0],
                    'pid': parts[1],
                    'cpu': parts[2],
                    'mem': parts[3],
                    'command': parts[10]
                })
    except Exception:
        pass
    
    return processes


# =============================================================================
# Display Functions
# =============================================================================
def format_size(size_kb: int) -> str:
    """Format size in human-readable format."""
    if size_kb < 1024:
        return f"{size_kb} KB"
    elif size_kb < 1024 * 1024:
        return f"{size_kb / 1024:.1f} MB"
    else:
        return f"{size_kb / (1024 * 1024):.1f} GB"


def format_bytes(size_bytes: int) -> str:
    """Format bytes in human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


def display_memory():
    """Display memory information."""
    print(f"\n{C['BD']}Memory Usage:{C['NC']}")
    mem = get_memory_info()
    
    if not mem:
        print("  Unable to read memory information")
        return
    
    total = mem.get('MemTotal', 0)
    free = mem.get('MemFree', 0)
    available = mem.get('MemAvailable', free)
    buffers = mem.get('Buffers', 0)
    cached = mem.get('Cached', 0)
    used = total - free - buffers - cached
    
    print(f"  Total:     {format_size(total)}")
    print(f"  Used:      {format_size(used)} ({used/total*100:.1f}%)")
    print(f"  Free:      {format_size(free)}")
    print(f"  Available: {format_size(available)}")
    print(f"  Buffers:   {format_size(buffers)}")
    print(f"  Cached:    {format_size(cached)}")


def display_disk(paths: List[str] = None):
    """Display disk usage."""
    print(f"\n{C['BD']}Disk Usage:{C['NC']}")
    
    if paths is None:
        paths = ['/']
    
    for path in paths:
        disk = get_disk_usage(path)
        if disk:
            percent = disk.get('percent', 0)
            color = C['G'] if percent < 70 else C['Y'] if percent < 90 else C['R']
            print(f"  {path}:")
            print(f"    Total:     {format_bytes(disk['total'])}")
            print(f"    Used:      {color}{format_bytes(disk['used'])} ({percent:.1f}%){C['NC']}")
            print(f"    Available: {format_bytes(disk['available'])}")


def display_battery():
    """Display battery information."""
    batteries = get_battery_info()
    
    if not batteries:
        return
    
    print(f"\n{C['BD']}Battery:{C['NC']}")
    for bat in batteries:
        name = bat.get('name', 'Unknown')
        status = bat.get('status', 'N/A')
        capacity = bat.get('capacity', 'N/A')
        
        if capacity != 'N/A':
            cap_int = int(capacity)
            if cap_int < 20:
                color = C['R']
            elif cap_int < 50:
                color = C['Y']
            else:
                color = C['G']
            capacity = f"{color}{capacity}%{C['NC']}"
        
        print(f"  {name}:")
        print(f"    Status:   {status}")
        print(f"    Capacity: {capacity}")


def display_cpu():
    """Display CPU information."""
    print(f"\n{C['BD']}CPU:{C['NC']}")
    
    # CPU model
    try:
        with open('/proc/cpuinfo', 'r') as f:
            for line in f:
                if line.startswith('model name'):
                    model = line.split(':')[1].strip()
                    print(f"  Model: {model}")
                    break
    except Exception:
        pass
    
    # CPU count
    cpu_count = os.cpu_count()
    print(f"  Cores: {cpu_count}")
    
    # Temperature
    temp = get_cpu_temp()
    if temp is not None:
        if temp < 50:
            color = C['G']
        elif temp < 70:
            color = C['Y']
        else:
            color = C['R']
        print(f"  Temperature: {color}{temp:.1f}°C{C['NC']}")


def display_network():
    """Display network statistics."""
    interfaces = get_network_stats()
    
    if not interfaces:
        return
    
    print(f"\n{C['BD']}Network:{C['NC']}")
    for iface in interfaces:
        if iface['name'] == 'lo':
            continue
        
        rx = format_bytes(int(iface['rx_bytes']))
        tx = format_bytes(int(iface['tx_bytes']))
        print(f"  {iface['name']}:")
        print(f"    RX: {rx}")
        print(f"    TX: {tx}")


def display_top_processes(n: int = 10):
    """Display top processes."""
    processes = get_top_processes(n)
    
    if not processes:
        return
    
    print(f"\n{C['BD']}Top {n} Processes (by CPU):{C['NC']}")
    print(f"  {'USER':<12} {'PID':>8} {'CPU%':>6} {'MEM%':>6}  COMMAND")
    print(f"  {'-'*12} {'-'*8} {'-'*6} {'-'*6}  {'-'*40}")
    
    for proc in processes:
        cmd = proc['command'][:40]
        print(f"  {proc['user']:<12} {proc['pid']:>8} {proc['cpu']:>6} {proc['mem']:>6}  {cmd}")


# =============================================================================
# Usage / Help
# =============================================================================
def print_usage():
    """Print usage information."""
    print(f"""{C['BD']}Usage:{C['NC']} {SCRIPT_NAME} [OPTIONS]

{C['BD']}System Monitor v{VERSION}{C['NC']} - Display system information and resource usage

{C['BD']}Options:{C['NC']}
  --all, -a             Show all system information
  --memory, -m          Show memory usage
  --disk, -d [PATHS]    Show disk usage (default: /)
  --cpu, -c             Show CPU information
  --battery, -b         Show battery information
  --network, -n         Show network statistics
  --top, -t [N]         Show top N processes (default: 10)
  --json, -j            Output in JSON format
  --no-color            Disable colored output
  --version             Show version
  --help, -h            Show this help message

{C['BD']}Examples:{C['NC']}
  {SCRIPT_NAME} --all
  {SCRIPT_NAME} -m -d / /home
  {SCRIPT_NAME} --top 5
  {SCRIPT_NAME} --battery --cpu
""")


# =============================================================================
# Main
# =============================================================================
def main() -> int:
    """Main entry point."""
    p = argparse.ArgumentParser(
        description=f"{SCRIPT_NAME} v{VERSION} - System monitor",
        add_help=False
    )
    p.add_argument("--all", "-a", action="store_true", help="Show all information")
    p.add_argument("--memory", "-m", action="store_true", help="Show memory usage")
    p.add_argument("--disk", "-d", nargs='*', metavar='PATH', help="Show disk usage")
    p.add_argument("--cpu", "-c", action="store_true", help="Show CPU information")
    p.add_argument("--battery", "-b", action="store_true", help="Show battery information")
    p.add_argument("--network", "-n", action="store_true", help="Show network statistics")
    p.add_argument("--top", "-t", nargs='?', type=int, const=10, metavar='N', 
                   help="Show top N processes")
    p.add_argument("--json", "-j", action="store_true", help="JSON output")
    p.add_argument("--no-color", action="store_true", help="Disable colors")
    p.add_argument("--version", action="store_true")
    p.add_argument("--help", "-h", action="store_true")
    
    args = p.parse_args()

    if args.version:
        print(f"{SCRIPT_NAME} {VERSION}")
        return 0

    if args.help or (not args.all and not any([
        args.memory, args.disk, args.cpu, args.battery, 
        args.network, args.top is not None
    ])):
        print_usage()
        return 0

    if args.no_color:
        global C
        C = {k: '' for k in C.keys()}

    if args.json:
        # JSON output mode
        import json
        data = {}
        if args.all or args.memory:
            data['memory'] = get_memory_info()
        if args.all or args.disk:
            paths = args.disk if args.disk else ['/']
            data['disk'] = {p: get_disk_usage(p) for p in paths}
        if args.all or args.cpu:
            data['cpu'] = {
                'count': os.cpu_count(),
                'temperature': get_cpu_temp()
            }
        if args.all or args.battery:
            data['battery'] = get_battery_info()
        if args.all or args.network:
            data['network'] = get_network_stats()
        if args.top is not None:
            data['top_processes'] = get_top_processes(args.top)
        
        print(json.dumps(data, indent=2))
        return 0

    # Normal output
    if args.all:
        display_cpu()
        display_memory()
        display_disk(args.disk if args.disk else None)
        display_battery()
        display_network()
        if args.top is not None:
            display_top_processes(args.top)
    else:
        if args.cpu:
            display_cpu()
        if args.memory:
            display_memory()
        if args.disk is not None:
            display_disk(args.disk if args.disk else ['/'])
        if args.battery:
            display_battery()
        if args.network:
            display_network()
        if args.top is not None:
            display_top_processes(args.top)

    return 0


if __name__ == "__main__":
    sys.exit(main())
