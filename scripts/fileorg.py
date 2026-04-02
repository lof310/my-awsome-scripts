#!/usr/bin/env python3
"""File Organizer - Organize files by type, date, or custom rules."""

# =============================================================================
# Imports & Constants
# =============================================================================
import sys
import os
import shutil
import argparse
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Callable
from collections import defaultdict

SCRIPT_NAME = "fileorg"
VERSION = "1.0.0"

# Terminal colors
C = {'R': '\033[0;31m', 'G': '\033[0;32m', 'Y': '\033[1;33m', 'B': '\033[0;34m',
     'C': '\033[0;36m', 'BD': '\033[1m', 'NC': '\033[0m'}

# File type categories
FILE_CATEGORIES = {
    'images': ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.svg', '.webp', '.ico', '.tiff'],
    'documents': ['.pdf', '.doc', '.docx', '.txt', '.rtf', '.odt', '.xls', '.xlsx', '.ppt', '.pptx'],
    'videos': ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v'],
    'audio': ['.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a'],
    'archives': ['.zip', '.tar', '.gz', '.bz2', '.7z', '.rar', '.xz'],
    'code': ['.py', '.js', '.ts', '.java', '.c', '.cpp', '.h', '.hpp', '.cs', '.go', '.rs', '.rb'],
    'web': ['.html', '.htm', '.css', '.scss', '.less', '.php', '.asp', '.aspx'],
    'data': ['.json', '.xml', '.yaml', '.yml', '.csv', '.sql', '.db'],
}


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


def log_debug(msg: str, verbose: bool = False) -> None:
    """Print debug message if verbose mode is enabled."""
    if verbose:
        print(f"{C['B']}[DEBUG]{C['NC']} {msg}", file=sys.stderr)


# =============================================================================
# File Organization Functions
# =============================================================================
def get_file_category(file_path: Path) -> str:
    """Get category for a file based on its extension."""
    ext = file_path.suffix.lower()
    
    for category, extensions in FILE_CATEGORIES.items():
        if ext in extensions:
            return category
    
    return 'other'


def get_date_folder(file_path: Path, date_format: str) -> str:
    """Get folder name based on file modification date."""
    try:
        mtime = os.path.getmtime(file_path)
        dt = datetime.fromtimestamp(mtime)
        return dt.strftime(date_format)
    except Exception:
        return 'unknown'


def organize_by_type(
    source: Path, 
    dest: Path, 
    dry_run: bool = False,
    verbose: bool = False
) -> Dict[str, int]:
    """Organize files by their type/category."""
    stats = defaultdict(int)
    
    if not source.exists():
        log_error(f"Source directory does not exist: {source}")
        return stats
    
    for file_path in source.iterdir():
        if not file_path.is_file():
            continue
        
        category = get_file_category(file_path)
        target_dir = dest / category
        
        if not dry_run:
            target_dir.mkdir(parents=True, exist_ok=True)
        
        target_path = target_dir / file_path.name
        
        # Handle duplicate names
        counter = 1
        while target_path.exists():
            stem = file_path.stem
            suffix = file_path.suffix
            target_path = target_dir / f"{stem}_{counter}{suffix}"
            counter += 1
        
        log_debug(f"Moving {file_path} -> {target_path}", verbose)
        
        if not dry_run:
            try:
                shutil.move(str(file_path), str(target_path))
            except Exception as e:
                log_warn(f"Failed to move {file_path}: {e}")
                continue
        
        stats[category] += 1
    
    return dict(stats)


def organize_by_date(
    source: Path,
    dest: Path,
    date_format: str = "%Y/%m",
    dry_run: bool = False,
    verbose: bool = False
) -> Dict[str, int]:
    """Organize files by their modification date."""
    stats = defaultdict(int)
    
    if not source.exists():
        log_error(f"Source directory does not exist: {source}")
        return stats
    
    for file_path in source.iterdir():
        if not file_path.is_file():
            continue
        
        date_folder = get_date_folder(file_path, date_format)
        target_dir = dest / date_folder
        
        if not dry_run:
            target_dir.mkdir(parents=True, exist_ok=True)
        
        target_path = target_dir / file_path.name
        
        # Handle duplicate names
        counter = 1
        while target_path.exists():
            stem = file_path.stem
            suffix = file_path.suffix
            target_path = target_dir / f"{stem}_{counter}{suffix}"
            counter += 1
        
        log_debug(f"Moving {file_path} -> {target_path}", verbose)
        
        if not dry_run:
            try:
                shutil.move(str(file_path), str(target_path))
            except Exception as e:
                log_warn(f"Failed to move {file_path}: {e}")
                continue
        
        stats[date_folder] += 1
    
    return dict(stats)


def organize_by_extension(
    source: Path,
    dest: Path,
    dry_run: bool = False,
    verbose: bool = False
) -> Dict[str, int]:
    """Organize files by their exact extension."""
    stats = defaultdict(int)
    
    if not source.exists():
        log_error(f"Source directory does not exist: {source}")
        return stats
    
    for file_path in source.iterdir():
        if not file_path.is_file():
            continue
        
        ext = file_path.suffix.lower().lstrip('.') or 'no_extension'
        target_dir = dest / ext
        
        if not dry_run:
            target_dir.mkdir(parents=True, exist_ok=True)
        
        target_path = target_dir / file_path.name
        
        # Handle duplicate names
        counter = 1
        while target_path.exists():
            stem = file_path.stem
            suffix = file_path.suffix
            target_path = target_dir / f"{stem}_{counter}{suffix}"
            counter += 1
        
        log_debug(f"Moving {file_path} -> {target_path}", verbose)
        
        if not dry_run:
            try:
                shutil.move(str(file_path), str(target_path))
            except Exception as e:
                log_warn(f"Failed to move {file_path}: {e}")
                continue
        
        stats[ext] += 1
    
    return dict(stats)


def scan_directory(source: Path, verbose: bool = False) -> Dict[str, Dict]:
    """Scan directory and show what would be organized."""
    stats = defaultdict(lambda: {'count': 0, 'size': 0})
    
    if not source.exists():
        log_error(f"Source directory does not exist: {source}")
        return {}
    
    for file_path in source.iterdir():
        if not file_path.is_file():
            continue
        
        category = get_file_category(file_path)
        try:
            size = file_path.stat().st_size
        except Exception:
            size = 0
        
        stats[category]['count'] += 1
        stats[category]['size'] += size
    
    return dict(stats)


# =============================================================================
# Usage / Help
# =============================================================================
def print_usage():
    """Print usage information."""
    print(f"""{C['BD']}Usage:{C['NC']} {SCRIPT_NAME} [OPTIONS] SOURCE [DESTINATION]

{C['BD']}File Organizer v{VERSION}{C['NC']} - Organize files by type, date, or extension

{C['BD']}Arguments:{C['NC']}
  SOURCE                Source directory to organize
  DESTINATION           Destination directory (default: SOURCE/organized)

{C['BD']}Options:{C['NC']}
  --by-type, -t         Organize by file type/category (default)
  --by-date, -d         Organize by modification date
  --by-extension, -e    Organize by exact file extension
  --date-format, -F FMT Date format string (default: %%Y/%%m)
  --dry-run, -n         Show what would be done without moving files
  --scan, -s            Scan and show statistics without organizing
  --verbose, -v         Enable verbose output
  --version             Show version
  --help, -h            Show this help message

{C['BD']}Categories:{C['NC']}
  images, documents, videos, audio, archives, code, web, data, other

{C['BD']}Examples:{C['NC']}
  {SCRIPT_NAME} ~/Downloads -n          # Dry run on Downloads folder
  {SCRIPT_NAME} ~/Downloads -t          # Organize by type
  {SCRIPT_NAME} ~/Photos ./sorted -d    # Organize photos by date
  {SCRIPT_NAME} . -e                    # Organize current dir by extension
""")


# =============================================================================
# Main
# =============================================================================
def main() -> int:
    """Main entry point."""
    p = argparse.ArgumentParser(
        description=f"{SCRIPT_NAME} v{VERSION} - File organizer",
        add_help=False
    )
    p.add_argument("source", nargs="?", help="Source directory")
    p.add_argument("destination", nargs="?", default=None, help="Destination directory")
    p.add_argument("--by-type", "-t", action="store_true", help="Organize by type")
    p.add_argument("--by-date", "-d", action="store_true", help="Organize by date")
    p.add_argument("--by-extension", "-e", action="store_true", help="Organize by extension")
    p.add_argument("--date-format", "-F", default="%Y/%m", help="Date format (default: %%Y/%%m)")
    p.add_argument("--dry-run", "-n", action="store_true", help="Dry run")
    p.add_argument("--scan", "-s", action="store_true", help="Scan only")
    p.add_argument("--verbose", "-v", action="store_true")
    p.add_argument("--version", action="store_true")
    p.add_argument("--help", "-h", action="store_true")
    
    args = p.parse_args()

    if args.version:
        print(f"{SCRIPT_NAME} {VERSION}")
        return 0

    if args.help or not args.source:
        print_usage()
        return 0

    source = Path(args.source).expanduser().resolve()
    
    if args.destination:
        dest = Path(args.destination).expanduser().resolve()
    else:
        dest = source / "organized"
    
    if args.scan:
        # Scan mode - just show statistics
        stats = scan_directory(source, args.verbose)
        
        if not stats:
            log_info("No files found to organize")
            return 0
        
        print(f"\n{C['BD']}Directory Scan Results:{C['NC']}")
        total_files = 0
        total_size = 0
        
        for category, data in sorted(stats.items()):
            count = data['count']
            size = data['size']
            total_files += count
            total_size += size
            
            size_str = f"{size / 1024:.1f} KB" if size < 1024 * 1024 else f"{size / (1024*1024):.1f} MB"
            print(f"  {category:<15} {count:>5} files  ({size_str})")
        
        print(f"\n  {'Total:':<15} {total_files:>5} files  ({total_size / (1024*1024):.1f} MB)")
        return 0
    
    # Determine organization method
    if args.by_date:
        organize_func = organize_by_date
        kwargs = {'date_format': args.date_format}
    elif args.by_extension:
        organize_func = organize_by_extension
        kwargs = {}
    else:
        # Default: by type
        organize_func = organize_by_type
        kwargs = {}
    
    if args.dry_run:
        log_info(f"Dry run - organizing {source} by {organize_func.__name__}")
    
    stats = organize_func(source, dest, args.dry_run, args.verbose, **kwargs)
    
    if not stats:
        log_info("No files were organized")
        return 0
    
    print(f"\n{C['BD']}Organization Complete:{C['NC']}")
    for category, count in sorted(stats.items()):
        print(f"  {category:<20} {count} file(s)")
    
    total = sum(stats.values())
    print(f"\n  Total: {total} file(s) organized")
    
    if args.dry_run:
        log_info("This was a dry run. Run again without -n to actually move files.")
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
