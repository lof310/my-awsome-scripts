#!/usr/bin/env python3
"""Tiny File Search Tool - Keyword highlighting with multithreading."""

# =============================================================================
# Imports & Constants
# =============================================================================
import os, sys, re, argparse, threading, queue, json
from pathlib import Path

SCRIPT_NAME = "tiny-search"
CONFIG_DIR = "/etc/tiny-search"
CONFIG_FILE = f"{CONFIG_DIR}/tiny-search.conf"

# Terminal colors
C = {'R': '\033[0;31m', 'G': '\033[0;32m', 'Y': '\033[1;33m', 'B': '\033[0;34m',
     'C': '\033[0;36m', 'BD': '\033[1m', 'NC': '\033[0m'}

# Defaults
DEFAULTS = {
    "max_depth": 10, "max_threads": 4, "content_search": True, "filename_search": True,
    "case_sensitive": False, "show_line_numbers": True, "context_lines": 0,
    "exclude_patterns": [".git", "__pycache__", "node_modules", ".venv"],
    "file_extensions": [], "max_file_size_mb": 50, "highlight_color": "31",
}

# =============================================================================
# Configuration
# =============================================================================
class Config:
    def __init__(self):
        for k, v in DEFAULTS.items():
            setattr(self, k, v.copy() if isinstance(v, list) else v)
        self._load()

    def _load(self):
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE) as f:
                    for k, v in json.load(f).items():
                        if hasattr(self, k):
                            setattr(self, k, v)
            except: pass

    def save(self):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_FILE, 'w') as f:
            json.dump({k: getattr(self, k) for k in DEFAULTS}, f, indent=2)

config = Config()

# =============================================================================
# Logging helpers
# =============================================================================
def log_error(msg): print(f"{C['R']}[ERROR]{C['NC']} {msg}", file=sys.stderr)
def log_warn(msg): print(f"{C['Y']}[WARNING]{C['NC']} {msg}", file=sys.stderr)
def log_info(msg): print(f"{C['G']}[INFO]{C['NC']} {msg}")
def log_debug(msg):
    if os.environ.get("TINY_SEARCH_DEBUG"):
        print(f"{C['B']}[DEBUG]{C['NC']} {msg}", file=sys.stderr)

# =============================================================================
# Core search logic
# =============================================================================
def should_exclude(path: Path) -> bool:
    return any(p in str(path) for p in config.exclude_patterns)

def should_search_file(path: Path) -> bool:
    if not path.is_file(): return False
    try:
        if path.stat().st_size > config.max_file_size_mb * 1024 * 1024: return False
        if config.file_extensions:
            ext = path.suffix.lower()
            allowed = [e.lower() if e.startswith('.') else f'.{e.lower()}' for e in config.file_extensions]
            if ext not in allowed: return False
        with open(path, 'r', encoding='utf-8', errors='ignore') as f: f.read(1)
        return True
    except: return False

def highlight(text: str, keyword: str) -> str:
    flags = 0 if config.case_sensitive else re.IGNORECASE
    return re.compile(re.escape(keyword), flags).sub(
        f"{C['BD']}\033[{config.highlight_color}m\\g<0>{C['NC']}", text
    )

def search_filename(path: Path, keyword: str, results: queue.Queue):
    flags = 0 if config.case_sensitive else re.IGNORECASE
    if re.search(re.escape(keyword), path.name, flags):
        results.put(("filename", str(path), path.name))

def search_content(path: Path, keyword: str, results: queue.Queue):
    flags = 0 if config.case_sensitive else re.IGNORECASE
    pattern = re.compile(re.escape(keyword), flags)
    try:
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            for num, line in enumerate(f, 1):
                if pattern.search(line):
                    results.put(("content", str(path), num, line.rstrip()))
    except: pass

def worker(files: queue.Queue, results: queue.Queue, keyword: str):
    while True:
        try: path = files.get(timeout=0.5)
        except queue.Empty: return
        try:
            if config.filename_search: search_filename(path, keyword, results)
            if config.content_search and should_search_file(path):
                search_content(path, keyword, results)
        finally: files.task_done()

def collect_files(root: Path) -> list:
    """Iterative DFS to collect files respecting depth and excludes."""
    files = []
    stack = [(root, 0)]
    while stack:
        path, depth = stack.pop()
        if depth > config.max_depth: continue
        try:
            for item in path.iterdir():
                if should_exclude(item): continue
                if item.is_file():
                    files.append(item)
                elif item.is_dir():
                    stack.append((item, depth + 1))
        except: pass
    return files

def search(root: str, keyword: str) -> list:
    root_path = Path(root).resolve()
    if not root_path.exists() or not root_path.is_dir():
        log_error(f"Invalid path: {root}")
        return []

    log_info(f"Searching '{keyword}' in {root_path}")
    files_queue, results_queue = queue.Queue(), queue.Queue()

    for f in collect_files(root_path):
        files_queue.put(f)

    threads = [threading.Thread(target=worker, args=(files_queue, results_queue, keyword), daemon=True)
               for _ in range(min(config.max_threads, files_queue.qsize()))]
    for t in threads: t.start()
    files_queue.join()
    for t in threads: t.join(timeout=1)

    # Collect all results from queue (safe after threads joined)
    results = []
    while not results_queue.empty():
        results.append(results_queue.get_nowait())
    return results

def format_result(result, keyword: str) -> str:
    if result[0] == "filename":
        _, path, name = result
        return f"{C['C']}{path}{C['NC']}:{C['BD']}{highlight(name, keyword)}{C['NC']}"
    else:
        _, path, num, line = result
        highlighted = highlight(line, keyword)
        if config.show_line_numbers:
            return f"{C['C']}{path}{C['NC']}:{C['Y']}{num}{C['NC']}:{highlighted}"
        return f"{C['C']}{path}{C['NC']}:{highlighted}"

def print_results(results, keyword: str):
    if not results:
        log_info("No matches found.")
        return
    print(f"\n{C['G']}{'=' * 60}{C['NC']}\n{C['BD']}Found {len(results)} match(es){C['NC']}\n{C['G']}{'=' * 60}{C['NC']}\n")
    for r in results:
        print(format_result(r, keyword))
    print()

# =============================================================================
# Configuration commands
# =============================================================================
def cmd_config(op, key=None, value=None):
    if op == "show":
        print(f"{C['G']}{'=' * 60}{C['NC']}\n{C['BD']}Tiny Search Configuration{C['NC']}\n{C['G']}{'=' * 60}{C['NC']}\n")
        print(f"  Config: {CONFIG_FILE}\n")
        for k in DEFAULTS:
            print(f"  {k}: {getattr(config, k)}")
        print()
    elif op == "get":
        if not hasattr(config, key): log_error(f"Unknown key: {key}"); sys.exit(1)
        print(getattr(config, key))
    elif op == "set":
        if not hasattr(config, key): log_error(f"Unknown key: {key}"); sys.exit(1)
        current = getattr(config, key)
        if isinstance(current, bool): value = value.lower() in ('true', '1', 'yes')
        elif isinstance(current, int): value = int(value)
        elif isinstance(current, list): value = [v.strip() for v in value.split(',')] if value else []
        setattr(config, key, value)
        config.save()
        log_info(f"'{key}' set to '{value}'")
    elif op == "reset":
        for k, v in DEFAULTS.items():
            setattr(config, k, v.copy() if isinstance(v, list) else v)
        config.save()
        log_info("Configuration reset")

# =============================================================================
# Help
# =============================================================================
def usage():
    print(f"""{C['BD']}Usage:{C['NC']} {SCRIPT_NAME} [OPTIONS] KEYWORD [PATH]

{C['BD']}Arguments:{C['NC']}
  KEYWORD               Search keyword (required)
  PATH                  Directory to search (default: .)

{C['BD']}Options:{C['NC']}
  --config --show       Display configuration
  --config --get KEY    Get configuration value
  --config --set KEY VALUE  Set configuration value
  --config --reset      Reset to defaults
  --depth N             Max directory depth (default: {DEFAULTS['max_depth']})
  --threads N           Search threads (default: {DEFAULTS['max_threads']})
  --content-only        Search contents only
  --filename-only       Search filenames only
  --case-sensitive      Case-sensitive search
  --no-line-numbers     Hide line numbers
  --ext EXT1,EXT2       Filter extensions (.py,.md)
  --exclude PAT1,PAT2   Exclude patterns (.git,node_modules)
  --max-size N          Max file size MB (default: {DEFAULTS['max_file_size_mb']})
  --color CODE          Highlight ANSI color (default: {DEFAULTS['highlight_color']})
  --debug               Enable debug output
  --version             Show version
  --help, -h            Show help

{C['BD']}Examples:{C['NC']}
  {SCRIPT_NAME} "function" ./src
  {SCRIPT_NAME} "something" --content-only --ext .py,.js
  {SCRIPT_NAME} --config --set max_threads 8
""")

# =============================================================================
# Main
# =============================================================================
def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument('keyword', nargs='?', default=None)
    p.add_argument('path', nargs='?', default='.')
    p.add_argument('--config', action='store_true')
    p.add_argument('--show', action='store_true')
    p.add_argument('--get', metavar='KEY')
    p.add_argument('--set', nargs=2, metavar=('KEY', 'VALUE'))
    p.add_argument('--reset', action='store_true')
    p.add_argument('--depth', type=int)
    p.add_argument('--threads', type=int)
    p.add_argument('--content-only', action='store_true')
    p.add_argument('--filename-only', action='store_true')
    p.add_argument('--case-sensitive', action='store_true')
    p.add_argument('--no-line-numbers', action='store_true')
    p.add_argument('--ext', metavar='EXT')
    p.add_argument('--exclude', metavar='PAT')
    p.add_argument('--max-size', type=int)
    p.add_argument('--color', metavar='CODE')
    p.add_argument('--debug', action='store_true')
    p.add_argument('--version', action='store_true')
    p.add_argument('-h', '--help', action='store_true')

    args = p.parse_args()

    if args.version:
        print(f"{SCRIPT_NAME} 1.0")
        sys.exit(0)

    if args.help or (not args.keyword and not args.config):
        usage()
        sys.exit(0)

    if args.debug:
        os.environ["TINY_SEARCH_DEBUG"] = "1"

    if args.config:
        if args.show: cmd_config("show")
        elif args.get: cmd_config("get", args.get)
        elif args.set: cmd_config("set", args.set[0], args.set[1])
        elif args.reset: cmd_config("reset")
        else: log_error("--config requires --show, --get, --set, or --reset"); sys.exit(1)
        sys.exit(0)

    if not args.keyword:
        log_error("KEYWORD required")
        sys.exit(1)

    # Override config with command-line options
    if args.depth: config.max_depth = args.depth
    if args.threads: config.max_threads = args.threads
    if args.content_only: config.content_search, config.filename_search = True, False
    if args.filename_only: config.content_search, config.filename_search = False, True
    if args.case_sensitive: config.case_sensitive = True
    if args.no_line_numbers: config.show_line_numbers = False
    if args.ext: config.file_extensions = [e.strip() for e in args.ext.split(',')]
    if args.exclude: config.exclude_patterns = [p.strip() for p in args.exclude.split(',')]
    if args.max_size: config.max_file_size_mb = args.max_size
    if args.color: config.highlight_color = args.color

    print_results(search(args.path, args.keyword), args.keyword)

if __name__ == "__main__":
    main()
