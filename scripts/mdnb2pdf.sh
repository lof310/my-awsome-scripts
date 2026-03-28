#!/bin/bash
set -euo pipefail

# =============================================================================
# Constants
# =============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly CONFIG_DIR="/etc/markdown-to-arxiv"
readonly CONFIG_FILE="$CONFIG_DIR/markdown-to-arxiv.conf"
readonly DEPENDENCIES="pandoc texlive-latex-base texlive-latex-extra texlive-fonts-recommended texlive-xetex fonts-liberation poppler-utils"

# Terminal Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# =============================================================================
# Configuration Arrays (0:draft,1:standard,2:arxiv,3:final)
# =============================================================================
declare -A PAPER_SIZE
declare -A FONT_SIZE
declare -A TEMPLATE
declare -A MARGIN_TOP
declare -A MARGIN_BOTTOM
declare -A MARGIN_LEFT
declare -A MARGIN_RIGHT
declare -A MATH_SUPPORT
declare -A BIBLIOGRAPHY
declare -A TABLE_OF_CONTENTS
declare -A HYPERLINKS

# Level 0 - Draft (quick preview)
PAPER_SIZE[0]="a4"
FONT_SIZE[0]=11
TEMPLATE[0]="default"
MARGIN_TOP[0]=25
MARGIN_BOTTOM[0]=25
MARGIN_LEFT[0]=25
MARGIN_RIGHT[0]=25
MATH_SUPPORT[0]="true"
BIBLIOGRAPHY[0]="false"
TABLE_OF_CONTENTS[0]="false"
HYPERLINKS[0]="true"

# Level 1 - Standard (general purpose)
PAPER_SIZE[1]="letter"
FONT_SIZE[1]=11
TEMPLATE[1]="eisvogel"
MARGIN_TOP[1]=30
MARGIN_BOTTOM[1]=30
MARGIN_LEFT[1]=30
MARGIN_RIGHT[1]=30
MATH_SUPPORT[1]="true"
BIBLIOGRAPHY[1]="true"
TABLE_OF_CONTENTS[1]="true"
HYPERLINKS[1]="true"

# Level 2 - arXiv Compatible (submission ready)
PAPER_SIZE[2]="letter"
FONT_SIZE[2]=10
TEMPLATE[2]="arxiv"
MARGIN_TOP[2]=25
MARGIN_BOTTOM[2]=25
MARGIN_LEFT[2]=25
MARGIN_RIGHT[2]=25
MATH_SUPPORT[2]="true"
BIBLIOGRAPHY[2]="true"
TABLE_OF_CONTENTS[2]="false"
HYPERLINKS[2]="true"

# Level 3 - Final Publication (optimized)
PAPER_SIZE[3]="letter"
FONT_SIZE[3]=10
TEMPLATE[3]="arxiv-final"
MARGIN_TOP[3]=25
MARGIN_BOTTOM[3]=25
MARGIN_LEFT[3]=25
MARGIN_RIGHT[3]=25
MATH_SUPPORT[3]="true"
BIBLIOGRAPHY[3]="true"
TABLE_OF_CONTENTS[3]="true"
HYPERLINKS[3]="true"

# Default settings
DEFAULT_LEVEL=2
DEFAULT_OUTPUT_DIR="./output"
AUTO_VALIDATE="true"

# =============================================================================
# Logging
# =============================================================================
log() {
    local level="$1"
    shift
    local msg="$*"

    case "$level" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} $msg" >&2
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} $msg"
            ;;
        INFO)
            echo -e "${GREEN}[INFO]${NC} $msg"
            ;;
        DEBUG)
            echo -e "${BLUE}[DEBUG]${NC} $msg"
            ;;
    esac
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARNING" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_debug() {
    log "DEBUG" "$@"
}

# =============================================================================
# Help Message
# =============================================================================
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] COMMAND

Markdown and Notebook to arXiv-compatible PDF converter.

COMMANDS:
  --convert --input FILE --output FILE [--level N]
                              Convert single markdown/notebook to PDF.
  --batch --input-dir DIR --output-dir DIR [--level N]
                              Convert all markdown/notebook files in directory.
  --validate FILE             Validate PDF for arXiv compliance.
  --status                    Show current configuration and dependencies.
  --config --show             Display current configuration for all levels.
  --config --get KEY          Get a specific configuration value.
  --config --set KEY VALUE    Set a configuration value persistently.
  --config --reset            Reset configuration to defaults.
  --install                   Install this script to /usr/local/bin.
  --install-dependencies      Install required packages (apt).
  --clean                     Remove temporary files and caches.
  --help                      Show this help message.

LEVELS:
  0  Draft (quick preview, A4, 11pt, no TOC)
  1  Standard (letter, 11pt, eisvogel template, with TOC)
  2  arXiv Compatible (letter, 10pt, embedded fonts, submission ready)
  3  Final Publication (arXiv optimized, all features enabled)

SUPPORTED INPUT FORMATS:
  - Markdown (.md, .markdown)
  - Jupyter Notebooks (.ipynb)
  - LaTeX snippets within markdown (math equations supported)

EXAMPLES:
  sudo $SCRIPT_NAME --install-dependencies
  $SCRIPT_NAME --convert --input paper.md --output paper.pdf --level 2
  $SCRIPT_NAME --convert --input notebook.ipynb --output notebook.pdf --level 2
  $SCRIPT_NAME --batch --input-dir ./papers --output-dir ./pdfs --level 2
  $SCRIPT_NAME --validate paper.pdf
  $SCRIPT_NAME --config --set DEFAULT_LEVEL 1
  $SCRIPT_NAME --config --get DEFAULT_LEVEL

EOF
}

# =============================================================================
# Utility Functions
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

check_dependencies() {
    local missing=()

    for dep in pandoc xelatex pdflatex; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        return 1
    fi

    return 0
}

ensure_config_dir() {
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    fi
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_debug "Configuration loaded from $CONFIG_FILE"
    else
        log_debug "No configuration file found, using defaults"
    fi
}

save_config() {
    ensure_config_dir

    cat > "$CONFIG_FILE" <<EOF
# Markdown to arXiv PDF Converter Configuration
# Generated: $(date)
# Do not edit manually - use --config --set

DEFAULT_LEVEL=$DEFAULT_LEVEL
DEFAULT_OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
AUTO_VALIDATE=$AUTO_VALIDATE
EOF
    log_info "Configuration saved to $CONFIG_FILE"
}

# =============================================================================
# Configuration Management
# =============================================================================
config_show() {
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  Conversion Configuration per Level${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo

    for level in 0 1 2 3; do
        echo -e "${BLUE}Level $level:${NC}"
        echo "  PAPER_SIZE:        ${PAPER_SIZE[$level]}"
        echo "  FONT_SIZE:         ${FONT_SIZE[$level]}pt"
        echo "  TEMPLATE:          ${TEMPLATE[$level]}"
        echo "  MARGIN_TOP:        ${MARGIN_TOP[$level]}mm"
        echo "  MARGIN_BOTTOM:     ${MARGIN_BOTTOM[$level]}mm"
        echo "  MARGIN_LEFT:       ${MARGIN_LEFT[$level]}mm"
        echo "  MARGIN_RIGHT:      ${MARGIN_RIGHT[$level]}mm"
        echo "  MATH_SUPPORT:      ${MATH_SUPPORT[$level]}"
        echo "  BIBLIOGRAPHY:      ${BIBLIOGRAPHY[$level]}"
        echo "  TABLE_OF_CONTENTS: ${TABLE_OF_CONTENTS[$level]}"
        echo "  HYPERLINKS:        ${HYPERLINKS[$level]}"
        echo
    done

    echo -e "${BLUE}Global Settings:${NC}"
    echo "  DEFAULT_LEVEL:     $DEFAULT_LEVEL"
    echo "  DEFAULT_OUTPUT_DIR: $DEFAULT_OUTPUT_DIR"
    echo "  AUTO_VALIDATE:     $AUTO_VALIDATE"
    echo
}

config_get() {
    local key="$1"

    case "$key" in
        DEFAULT_LEVEL)
            echo "$DEFAULT_LEVEL"
            ;;
        DEFAULT_OUTPUT_DIR)
            echo "$DEFAULT_OUTPUT_DIR"
            ;;
        AUTO_VALIDATE)
            echo "$AUTO_VALIDATE"
            ;;
        PAPER_SIZE_*)
            local level="${key#PAPER_SIZE_}"
            echo "${PAPER_SIZE[$level]:-}"
            ;;
        FONT_SIZE_*)
            local level="${key#FONT_SIZE_}"
            echo "${FONT_SIZE[$level]:-}"
            ;;
        TEMPLATE_*)
            local level="${key#TEMPLATE_}"
            echo "${TEMPLATE[$level]:-}"
            ;;
        *)
            log_error "Unknown configuration key: $key"
            return 1
            ;;
    esac
}

config_set() {
    local key="$1"
    local value="$2"

    case "$key" in
        DEFAULT_LEVEL)
            if [[ ! "$value" =~ ^[0-3]$ ]]; then
                log_error "DEFAULT_LEVEL must be 0, 1, 2, or 3"
                return 1
            fi
            DEFAULT_LEVEL="$value"
            ;;
        DEFAULT_OUTPUT_DIR)
            DEFAULT_OUTPUT_DIR="$value"
            ;;
        AUTO_VALIDATE)
            if [[ "$value" != "true" && "$value" != "false" ]]; then
                log_error "AUTO_VALIDATE must be 'true' or 'false'"
                return 1
            fi
            AUTO_VALIDATE="$value"
            ;;
        *)
            log_error "Cannot set configuration key: $key (use --config --show for available keys)"
            return 1
            ;;
    esac

    save_config
    log_info "Configuration '$key' set to '$value'"
}

config_reset() {
    DEFAULT_LEVEL=2
    DEFAULT_OUTPUT_DIR="./output"
    AUTO_VALIDATE="true"

    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        log_info "Configuration file removed"
    fi

    log_info "Configuration reset to defaults"
}

# =============================================================================
# PDF Validation (For arXiv)
# =============================================================================
validate_pdf() {
    local pdf_file="$1"
    local issues=0

    if [[ ! -f "$pdf_file" ]]; then
        log_error "PDF file not found: $pdf_file"
        return 1
    fi

    echo -e "${GREEN}Validating PDF for arXiv compliance:${NC}"
    echo "  File: $pdf_file"
    echo "  Size: $(stat -c%s "$pdf_file" 2>/dev/null || stat -f%z "$pdf_file" 2>/dev/null) bytes"
    echo

    # Check font embedding
    if command -v pdffonts >/dev/null 2>&1; then
        local non_embedded
        non_embedded=$(pdffonts "$pdf_file" 2>/dev/null | awk 'NR>2 && $3=="no"' | wc -l)

        if [[ $non_embedded -gt 0 ]]; then
            log_warn "Found $non_embedded non-embedded fonts (arXiv requires all fonts embedded)"
            ((issues++))
        else
            echo -e "  ${GREEN}✓${NC} All fonts are embedded"
        fi

        # Check for Type3 fonts
        local type3_fonts
        type3_fonts=$(pdffonts "$pdf_file" 2>/dev/null | awk 'NR>2 && $2~/Type3/' | wc -l)

        if [[ $type3_fonts -gt 0 ]]; then
            log_warn "Found $type3_fonts Type3 bitmap fonts (arXiv requires Type1/TrueType)"
            ((issues++))
        else
            echo -e "  ${GREEN}✓${NC} No Type3 bitmap fonts detected"
        fi
    else
        log_warn "pdffonts not available, skipping font validation"
    fi

    # Check file size (arXiv limit: 50MB)
    local file_size
    file_size=$(stat -c%s "$pdf_file" 2>/dev/null || stat -f%z "$pdf_file" 2>/dev/null)

    if [[ $file_size -gt 52428800 ]]; then
        log_warn "PDF file size exceeds 50MB (arXiv limit)"
        ((issues++))
    else
        echo -e "  ${GREEN}✓${NC} File size within arXiv limits"
    fi

    echo

    if [[ $issues -eq 0 ]]; then
        log_info "PDF validation passed: arXiv compatible"
        return 0
    else
        log_error "PDF validation failed with $issues issue(s)"
        return 1
    fi
}

# =============================================================================
# Conversion Operations
# =============================================================================
detect_input_type() {
    local input_file="$1"
    local extension="${input_file##*.}"

    case "$extension" in
        md|markdown)
            echo "markdown"
            ;;
        ipynb)
            echo "notebook"
            ;;
        tex|latex)
            echo "latex"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

convert_single() {
    local input="$1"
    local output="$2"
    local level="$3"

    local paper_size="${PAPER_SIZE[$level]}"
    local font_size="${FONT_SIZE[$level]}"
    local template="${TEMPLATE[$level]}"
    local math_support="${MATH_SUPPORT[$level]}"
    local bibliography="${BIBLIOGRAPHY[$level]}"
    local toc="${TABLE_OF_CONTENTS[$level]}"
    local hyperlinks="${HYPERLINKS[$level]}"

    local input_type
    input_type=$(detect_input_type "$input")

    if [[ "$input_type" == "unknown" ]]; then
        log_error "Unsupported input file type: $input"
        return 1
    fi

    log_info "Converting $input to $output (level $level, type: $input_type)..."

    # Create output directory if it doesn't exist
    local output_dir
    output_dir=$(dirname "$output")
    mkdir -p "$output_dir"

    # Build pandoc command
    local pandoc_cmd="pandoc"

    # Input format based on file type
    if [[ "$input_type" == "notebook" ]]; then
        pandoc_cmd+=" --from ipynb"
    else
        pandoc_cmd+=" --from markdown"
    fi

    # Output format
    pandoc_cmd+=" --to pdf"

    # PDF engine (xelatex for better font support)
    pandoc_cmd+=" --pdf-engine=xelatex"

    # Geometry settings
    pandoc_cmd+=" --variable geometry:paper=$paper_size"
    pandoc_cmd+=" --variable fontsize=${font_size}pt"
    pandoc_cmd+=" --variable margin-top=${MARGIN_TOP[$level]}mm"
    pandoc_cmd+=" --variable margin-bottom=${MARGIN_BOTTOM[$level]}mm"
    pandoc_cmd+=" --variable margin-left=${MARGIN_LEFT[$level]}mm"
    pandoc_cmd+=" --variable margin-right=${MARGIN_RIGHT[$level]}mm"

    # Font settings (Liberation fonts are arXiv compatible)
    pandoc_cmd+=" --variable mainfont='Liberation Serif'"
    pandoc_cmd+=" --variable sansfont='Liberation Sans'"
    pandoc_cmd+=" --variable monofont='Liberation Mono'"

    # Math support (LaTeX equations)
    if [[ "$math_support" == "true" ]]; then
        pandoc_cmd+=" --mathml"
        pandoc_cmd+=" --variable mathjax='true'"
    fi

    # Hyperlinks
    if [[ "$hyperlinks" == "true" ]]; then
        pandoc_cmd+=" --variable colorlinks=true"
    else
        pandoc_cmd+=" --variable colorlinks=false"
    fi

    # Table of contents
    if [[ "$toc" == "true" ]]; then
        pandoc_cmd+=" --toc"
        pandoc_cmd+=" --toc-depth=3"
    fi

    # Bibliography support
    if [[ "$bibliography" == "true" ]]; then
        pandoc_cmd+=" --citeproc"
    fi

    # Embed fonts (required for arXiv)
    pandoc_cmd+=" --embed-fonts"

    # Standalone document
    pandoc_cmd+=" --standalone"

    # Add template if not default
    if [[ "$template" != "default" ]]; then
        local template_path="/usr/share/pandoc/data/templates/${template}.latex"
        if [[ -f "$template_path" ]]; then
            pandoc_cmd+=" --template=$template"
            log_debug "Using template: $template"
        else
            log_debug "Template '$template' not found, using default"
        fi
    fi

    # Output file
    pandoc_cmd+=" --output=$output"

    # Input file
    pandoc_cmd+=" $input"

    log_debug "Executing: $pandoc_cmd"

    # Execute conversion
    if eval "$pandoc_cmd" 2>/dev/null; then
        log_info "Conversion successful: $output"

        # Auto-validate if enabled
        if [[ "$AUTO_VALIDATE" == "true" ]]; then
            validate_pdf "$output" || log_warn "PDF may not be fully arXiv compatible"
        fi

        return 0
    else
        log_error "Conversion failed for $input"
        return 1
    fi
}

convert_batch() {
    local input_dir="$1"
    local output_dir="$2"
    local level="$3"

    local success=0
    local failed=0
    local total=0

    log_info "Batch converting files from $input_dir to $output_dir (level $level)..."

    # Create output directory
    mkdir -p "$output_dir"

    # Find all supported files
    while IFS= read -r -d '' file; do
        ((total++))

        local basename
        basename=$(basename "$file" | sed 's/\.[^.]*$//')
        local output_file="$output_dir/${basename}.pdf"

        if convert_single "$file" "$output_file" "$level"; then
            ((success++))
        else
            ((failed++))
        fi
    done < <(find "$input_dir" -type f \( -name "*.md" -o -name "*.markdown" -o -name "*.ipynb" \) -print0 2>/dev/null)

    echo
    log_info "Batch conversion complete:"
    echo "  Total files:   $total"
    echo -e "  ${GREEN}Succeeded:${NC}     $success"
    echo -e "  ${RED}Failed:${NC}        $failed"
    echo

    if [[ $failed -gt 0 ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# Installation
# =============================================================================
install_self() {
    local dest="/usr/local/bin/markdown-to-arxiv"

    cp "$0" "$dest"
    chmod 755 "$dest"

    log_info "Installed to $dest"
    log_info "You can now run 'markdown-to-arxiv' from anywhere"
}

install_deps() {
    log_info "Updating package lists..."
    apt update -qq

    log_info "Installing dependencies..."
    apt install -y $DEPENDENCIES

    # Create configuration directory
    ensure_config_dir

    # Save default configuration
    save_config

    log_info "Dependencies installed successfully"
    log_info "Configuration created at $CONFIG_FILE"
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    log_info "Cleaning temporary files..."

    rm -rf /tmp/pandoc-* 2>/dev/null || true
    rm -rf /tmp/tex-* 2>/dev/null || true
    rm -rf /tmp/*.aux 2>/dev/null || true
    rm -rf /tmp/*.log 2>/dev/null || true
    rm -rf /tmp/*.out 2>/dev/null || true

    log_info "Cleanup complete"
}

# =============================================================================
# Status Display
# =============================================================================
show_status() {
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}  System Status${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo

    echo -e "${BLUE}Dependencies:${NC}"
    for dep in pandoc xelatex pdflatex pdffonts; do
        if command -v "$dep" >/dev/null 2>&1; then
            local path
            path=$(command -v "$dep")
            echo -e "  ${GREEN}✓${NC} $dep: $path"
        else
            echo -e "  ${RED}✗${NC} $dep: [MISSING]"
        fi
    done
    echo
    
    echo -e "${BLUE}Configuration:${NC}"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  Config file: $CONFIG_FILE"
        echo "  DEFAULT_LEVEL: $DEFAULT_LEVEL"
        echo "  DEFAULT_OUTPUT_DIR: $DEFAULT_OUTPUT_DIR"
        echo "  AUTO_VALIDATE: $AUTO_VALIDATE"
    else
        echo "  No configuration file found (using defaults)"
    fi
    echo

    echo -e "${BLUE}Available Templates:${NC}"
    if [[ -d "/usr/share/pandoc/data/templates" ]]; then
        local templates
        templates=$(ls /usr/share/pandoc/data/templates/*.latex 2>/dev/null | sed 's|.*/||;s|\.latex||' | head -10)
        if [[ -n "$templates" ]]; then
            echo "$templates" | sed 's/^/  /'
        else
            echo "  No custom templates found"
        fi
    else
        echo "  Template directory not found"
    fi
    echo
}

# =============================================================================
# Main Function
# =============================================================================
main() {
    local cmd=""
    local level=""
    local input=""
    local output=""
    local input_dir=""
    local output_dir=""
    local config_key=""
    local config_value=""

    # Load existing configuration
    load_config

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --convert)
                cmd="convert"
                shift
                ;;
            --batch)
                cmd="batch"
                shift
                ;;
            --validate)
                cmd="validate"
                shift
                ;;
            --status)
                cmd="status"
                shift
                ;;
            --config)
                shift
                if [[ "$1" == "--show" ]]; then
                    cmd="config-show"
                    shift
                elif [[ "$1" == "--get" ]]; then
                    cmd="config-get"
                    shift
                    config_key="$1"
                    shift
                elif [[ "$1" == "--set" ]]; then
                    cmd="config-set"
                    shift
                    config_key="$1"
                    shift
                    config_value="$1"
                    shift
                elif [[ "$1" == "--reset" ]]; then
                    cmd="config-reset"
                    shift
                else
                    log_error "--config requires --show, --get, --set, or --reset"
                    exit 1
                fi
                ;;
            --install)
                cmd="install"
                shift
                ;;
            --install-dependencies)
                cmd="install-deps"
                shift
                ;;
            --clean)
                cmd="clean"
                shift
                ;;
            --input)
                input="$1"
                shift
                input="$1"
                shift
                ;;
            --output)
                output="$1"
                shift
                output="$1"
                shift
                ;;
            --input-dir)
                input_dir="$1"
                shift
                input_dir="$1"
                shift
                ;;
            --output-dir)
                output_dir="$1"
                shift
                output_dir="$1"
                shift
                ;;
            --level)
                level="$1"
                shift
                level="$1"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Default to help if no command specified
    if [[ -z "$cmd" ]]; then
        usage
        exit 0
    fi

    # Validate level for conversion commands
    if [[ "$cmd" == "convert" || "$cmd" == "batch" ]]; then
        if [[ -z "$level" ]]; then
            level="$DEFAULT_LEVEL"
            log_debug "Using default level: $level"
        fi

        if [[ ! "$level" =~ ^[0-3]$ ]]; then
            log_error "Level must be 0, 1, 2, or 3"
            exit 1
        fi
    fi
    
    # Validate input/output for conversion commands
    if [[ "$cmd" == "convert" ]]; then
        if [[ -z "$input" ]]; then
            log_error "--input required for convert command"
            exit 1
        fi
        
        if [[ -z "$output" ]]; then
            log_error "--output required for convert command"
            exit 1
        fi

        if [[ ! -f "$input" ]]; then
            log_error "Input file not found: $input"
            exit 1
        fi
    fi

    if [[ "$cmd" == "batch" ]]; then
        if [[ -z "$input_dir" ]]; then
            log_error "--input-dir required for batch command"
            exit 1
        fi

        if [[ -z "$output_dir" ]]; then
            log_error "--output-dir required for batch command"
            exit 1
        fi

        if [[ ! -d "$input_dir" ]]; then
            log_error "Input directory not found: $input_dir"
            exit 1
        fi
    fi

    if [[ "$cmd" == "validate" ]]; then
        if [[ -z "$input" ]]; then
            log_error "PDF file path required for validate command"
            exit 1
        fi
        output="$input"
    fi

    # Root check for installation commands
    case "$cmd" in
        install-deps|install|config-set|config-reset)
            check_root
            ;;
    esac

    # Dependency check for conversion and validation commands
    case "$cmd" in
        convert|batch|validate)
            if ! check_dependencies; then
                log_error "Please run: sudo $SCRIPT_NAME --install-dependencies"
                exit 1
            fi
            ;;
    esac

    # Execute command
    case "$cmd" in
        convert)
            convert_single "$input" "$output" "$level"
            ;;
        batch)
            convert_batch "$input_dir" "$output_dir" "$level"
            ;;
        validate)
            validate_pdf "$output"
            ;;
        status)
            show_status
            ;;
        config-show)
            config_show
            ;;
        config-get)
            config_get "$config_key"
            ;;
        config-set)
            config_set "$config_key" "$config_value"
            ;;
        config-reset)
            config_reset
            ;;
        install)
            install_self
            ;;
        install-deps)
            install_deps
            ;;
        clean)
            cleanup
            ;;
    esac
}

# =============================================================================
# Entry Point
# =============================================================================
main "$@"
