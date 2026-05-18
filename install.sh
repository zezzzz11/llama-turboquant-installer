#!/usr/bin/env bash
# llama-turboquant-installer
# Hardware-agnostic installer for llama-cpp-turboquant.
# Supports macOS (arm64/x86_64) and Linux (x86_64/arm64) with
# Metal / CUDA / ROCm / Vulkan / CPU backends.

set -euo pipefail

# ════════════════════════════════════════════════════════════════════
#  Colors & formatting
# ════════════════════════════════════════════════════════════════════
# shellcheck disable=SC2034  # some colors are reserved for future use
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[0;31m'
    C_YELLOW=$'\033[0;33m'
    C_MAGENTA=$'\033[0;35m'
    C_BBLUE=$'\033[1;34m'
    C_BGREEN=$'\033[1;32m'
    C_BCYAN=$'\033[1;36m'
    C_BMAGENTA=$'\033[1;35m'
else
    C_RESET="" C_BOLD="" C_DIM=""
    C_RED="" C_YELLOW="" C_MAGENTA=""
    C_BBLUE="" C_BGREEN="" C_BCYAN="" C_BMAGENTA=""
fi

step() {
    local title="$1"
    local pad=$(( 60 - ${#title} - 4 ))
    (( pad < 0 )) && pad=0
    local bar=""
    (( pad > 0 )) && printf -v bar '━%.0s' $(seq 1 "$pad")
    printf "\n${C_BCYAN}━━━ %s${C_RESET} ${C_DIM}%s${C_RESET}\n" "$title" "$bar" >&2
}
info()   { printf "${C_BBLUE}[i]${C_RESET} %s\n" "$*" >&2; }
ok()     { printf "${C_BGREEN}[✓]${C_RESET} %s\n" "$*" >&2; }
warn()   { printf "${C_YELLOW}[!]${C_RESET} %s\n" "$*" >&2; }
error()  { printf "${C_RED}[✗]${C_RESET} %s\n" "$*" >&2; exit 1; }
hint()   { printf "    ${C_DIM}%s${C_RESET}\n" "$*" >&2; }
dim()    { printf "${C_DIM}%s${C_RESET}" "$1"; }

# Max attempts on any interactive prompt before bailing.
PROMPT_MAX_ATTEMPTS=5

# ────────────────────────────────────────────────────────────────────
#  Interactive helpers (bounded retries, default values shown clearly)
# ────────────────────────────────────────────────────────────────────
ask_yn() {
    # ask_yn "<question>" [Y|N]
    local q="$1" def="${2:-N}"
    local hint_str
    if [[ "$def" == "Y" ]]; then hint_str="[${C_BGREEN}Y${C_RESET}/n]"
    else                          hint_str="[y/${C_BGREEN}N${C_RESET}]"
    fi
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
        [[ "$def" == "Y" ]] && return 0 || return 1
    fi
    local r attempts=0
    while (( attempts < PROMPT_MAX_ATTEMPTS )); do
        printf "${C_BMAGENTA}?${C_RESET} ${C_BOLD}%s${C_RESET} %s " "$q" "$hint_str" >&2
        if ! read -r r; then
            warn "Input closed; using default ($def)"
            r="$def"
        fi
        r="${r:-$def}"
        case "$r" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO])     return 1 ;;
        esac
        warn "Please answer y or n (got: \"$r\")"
        attempts=$(( attempts + 1 ))
    done
    error "Too many invalid answers — aborting"
}

ask_number() {
    # ask_number "<question>" <default> [min] [max]
    local q="$1" def="$2" min="${3:-1}" max="${4:-2147483647}"
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
        printf '%s\n' "$def"
        return 0
    fi
    local r attempts=0
    while (( attempts < PROMPT_MAX_ATTEMPTS )); do
        printf "${C_BMAGENTA}?${C_RESET} ${C_BOLD}%s${C_RESET} ${C_DIM}[default${C_RESET} ${C_BGREEN}%s${C_RESET}${C_DIM}]${C_RESET}: " "$q" "$def" >&2
        if ! read -r r; then
            warn "Input closed; using default ($def)"
            printf '%s\n' "$def"
            return 0
        fi
        r="${r:-$def}"
        if [[ "$r" =~ ^[0-9]+$ ]] && (( r >= min && r <= max )); then
            printf '%s\n' "$r"
            return 0
        fi
        warn "Enter a whole number between $min and $max (got: \"$r\")"
        attempts=$(( attempts + 1 ))
    done
    error "Too many invalid answers — aborting"
}

ask_string() {
    # ask_string "<question>" [default]
    local q="$1" def="${2:-}"
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
        printf '%s\n' "$def"
        return 0
    fi
    local r
    if [[ -n "$def" ]]; then
        printf "${C_BMAGENTA}?${C_RESET} ${C_BOLD}%s${C_RESET} ${C_DIM}[default${C_RESET} ${C_BGREEN}%s${C_RESET}${C_DIM}]${C_RESET}: " "$q" "$def" >&2
    else
        printf "${C_BMAGENTA}?${C_RESET} ${C_BOLD}%s${C_RESET} " "$q" >&2
    fi
    if ! read -r r; then r=""; fi
    printf '%s\n' "${r:-$def}"
}

choose_menu() {
    # choose_menu "<title>" <default-idx> <opt1> <opt2> ...
    # Echoes the chosen index (1..N).
    local title="$1" default="$2"; shift 2
    local opts=("$@")
    local n="${#opts[@]}"
    (( n >= 1 )) || error "choose_menu called with no options"
    printf "${C_BOLD}%s${C_RESET}\n" "$title" >&2
    local i
    for i in "${!opts[@]}"; do
        local idx=$(( i + 1 ))
        if [[ "$idx" == "$default" ]]; then
            printf "  ${C_BGREEN}%d)${C_RESET} %s ${C_DIM}(default)${C_RESET}\n" "$idx" "${opts[$i]}" >&2
        else
            printf "  ${C_BOLD}%d)${C_RESET} %s\n" "$idx" "${opts[$i]}" >&2
        fi
    done
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then
        printf '%s\n' "$default"
        return 0
    fi
    local r attempts=0
    while (( attempts < PROMPT_MAX_ATTEMPTS )); do
        printf "${C_BMAGENTA}?${C_RESET} ${C_BOLD}Choose [1-%d]${C_RESET}: " "$n" >&2
        if ! read -r r; then
            warn "Input closed; using default ($default)"
            printf '%s\n' "$default"
            return 0
        fi
        r="${r:-$default}"
        if [[ "$r" =~ ^[0-9]+$ ]] && (( r >= 1 && r <= n )); then
            printf '%s\n' "$r"
            return 0
        fi
        warn "Enter a number between 1 and $n (got: \"$r\")"
        attempts=$(( attempts + 1 ))
    done
    error "Too many invalid answers — aborting"
}

run() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        printf "${C_MAGENTA}[dry]${C_RESET} %s\n" "$*" >&2
    else
        "$@"
    fi
}

# ════════════════════════════════════════════════════════════════════
#  Paths
# ════════════════════════════════════════════════════════════════════
HOME_DIR="${HOME}"
BIN_DIR="${HOME_DIR}/.local/bin"
SHARE_DIR="${HOME_DIR}/.local/share/llama-cpp-turboquant"
MODEL_DIR="${SHARE_DIR}/models"
SRC_DIR="${SHARE_DIR}/src"
CONFIG_FILE="${HOME_DIR}/.llm-server.env"
LAUNCHER_SCRIPT="${BIN_DIR}/llm-server"

REPO_URL="${REPO_URL:-https://github.com/TheTom/llama-cpp-turboquant.git}"
REPO_RELEASES_API="${REPO_RELEASES_API:-https://api.github.com/repos/TheTom/llama-cpp-turboquant/releases/latest}"

# ════════════════════════════════════════════════════════════════════
#  CLI flags
# ════════════════════════════════════════════════════════════════════
ASSUME_YES=0
RESUME=0
UNINSTALL=0
DRY_RUN=0
HEALTH_CHECK=0
REINSTALL=0
REDOWNLOAD=0
CLI_USE_CASE=""
CLI_MODEL=""
CLI_PORT=""
CLI_CONTEXT=""
CLI_GPU=""
CLI_EXTRA=""
CLI_IDLE_SLEEP=""
CLI_IDLE_SHUTDOWN=""

usage() {
    cat <<USAGE
${C_BOLD}llama-turboquant-installer${C_RESET}

${C_BOLD}Usage:${C_RESET}  install.sh [options]

${C_BOLD}Options:${C_RESET}
  --use-case {1|2|3|4}      1=chat, 2=code, 3=research, 4=agents/tools
  --model <hf-repo-id>      Hugging Face GGUF repo
  --port <int>              llama-server port (default 8000)
  --context <int>           context length in tokens
  --gpu-layers <int>        layers to offload to GPU
  --idle-sleep-seconds <n>  llama-server sleep after n idle seconds (-1 disables)
  --idle-shutdown-seconds <n>
                            stop server after n idle seconds (0 disables)
  --extra-args <str>        appended to the llama-server invocation
  --yes, -y                 non-interactive; accept defaults
  --resume                  reuse existing ~/.llm-server.env without asking
  --reinstall               force re-install of llama-server (ignore existing)
  --redownload              force re-download of the model
  --uninstall               remove installed files and exit
  --dry-run                 print actions without executing
  --health-check            start launcher, poll /health, then stop (smoke test)
  -h, --help                show this help

${C_BOLD}Examples:${C_RESET}
  install.sh
  install.sh --yes --use-case 4
  install.sh --yes --model Qwen/Qwen3-8B-GGUF --port 8001
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --use-case)     CLI_USE_CASE="${2:?--use-case requires value}"; shift 2 ;;
        --model)        CLI_MODEL="${2:?--model requires value}"; shift 2 ;;
        --port)         CLI_PORT="${2:?--port requires value}"; shift 2 ;;
        --context)      CLI_CONTEXT="${2:?--context requires value}"; shift 2 ;;
        --gpu-layers)   CLI_GPU="${2:?--gpu-layers requires value}"; shift 2 ;;
        --idle-sleep-seconds)    CLI_IDLE_SLEEP="${2:?--idle-sleep-seconds requires value}"; shift 2 ;;
        --idle-shutdown-seconds) CLI_IDLE_SHUTDOWN="${2:?--idle-shutdown-seconds requires value}"; shift 2 ;;
        --extra-args)   CLI_EXTRA="${2:?--extra-args requires value}"; shift 2 ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        --resume)       RESUME=1; shift ;;
        --reinstall)    REINSTALL=1; shift ;;
        --redownload)   REDOWNLOAD=1; shift ;;
        --uninstall)    UNINSTALL=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --health-check) HEALTH_CHECK=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) error "Unknown flag: $1 (try --help)" ;;
    esac
done

# ════════════════════════════════════════════════════════════════════
#  Uninstall
# ════════════════════════════════════════════════════════════════════
do_uninstall() {
    step "Uninstall"
    if ! ask_yn "This will remove $SHARE_DIR, $CONFIG_FILE, and $LAUNCHER_SCRIPT. Continue?" "N"; then
        info "Aborted"
        exit 0
    fi
    for p in "$SHARE_DIR" "$CONFIG_FILE" "$LAUNCHER_SCRIPT"; do
        if [[ -e "$p" ]]; then
            info "removing $p"
            run rm -rf "$p"
        fi
    done
    ok "Uninstall complete"
    exit 0
}

# ════════════════════════════════════════════════════════════════════
#  Platform detection
# ════════════════════════════════════════════════════════════════════
detect_platform() {
    step "Platform detection"
    local kernel arch
    kernel="$(uname -s)"
    arch="$(uname -m)"
    case "$kernel" in
        Darwin) OS=macos ;;
        Linux)  OS=linux ;;
        *) error "Unsupported OS: $kernel" ;;
    esac
    case "$arch" in
        arm64|aarch64) ARCH=arm64 ;;
        x86_64|amd64)  ARCH=x86_64 ;;
        *) error "Unsupported architecture: $arch" ;;
    esac

    if [[ "$OS" == macos ]]; then
        MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
        PHYS_CORES="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 2)"
        RUN_THREADS="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "$PHYS_CORES")"
    else
        local kb
        kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        MEM_GB=$(( kb / 1024 / 1024 ))
        PHYS_CORES="$(nproc 2>/dev/null || echo 2)"
        RUN_THREADS="$PHYS_CORES"
    fi
    [[ "$RUN_THREADS" =~ ^[0-9]+$ ]] || RUN_THREADS="$PHYS_CORES"
    (( RUN_THREADS >= 1 )) || RUN_THREADS="$PHYS_CORES"
    if (( MEM_GB < 1 )); then
        warn "Could not detect system RAM; assuming 16 GB for recommendations"
        MEM_GB=16
    fi

    GPU_BACKEND="cpu"
    CMAKE_GPU_FLAGS=()
    if [[ "$OS" == macos && "$ARCH" == arm64 ]]; then
        GPU_BACKEND="metal"
        CMAKE_GPU_FLAGS=(-D GGML_METAL=ON)
    elif command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null; then
        GPU_BACKEND="cuda"
        CMAKE_GPU_FLAGS=(-D GGML_CUDA=ON)
    elif command -v rocminfo &>/dev/null; then
        GPU_BACKEND="hip"
        CMAKE_GPU_FLAGS=(-D GGML_HIP=ON)
    elif command -v vulkaninfo &>/dev/null; then
        GPU_BACKEND="vulkan"
        CMAKE_GPU_FLAGS=(-D GGML_VULKAN=ON)
    fi

    info "OS / arch    : ${C_BOLD}$OS${C_RESET} / ${C_BOLD}$ARCH${C_RESET}"
    info "RAM / cores  : ${C_BOLD}${MEM_GB} GB${C_RESET} / ${C_BOLD}${PHYS_CORES}${C_RESET}"
    info "Server threads: ${C_BOLD}${RUN_THREADS}${C_RESET}"
    info "GPU backend  : ${C_BGREEN}${GPU_BACKEND}${C_RESET}"
}

# ════════════════════════════════════════════════════════════════════
#  Pre-flight: tools, network, disk, permissions
# ════════════════════════════════════════════════════════════════════
pkg_hint() {
    local pkg="$1"
    if [[ "$OS" == macos ]]; then
        if command -v brew &>/dev/null; then echo "brew install $pkg"
        else echo "install Homebrew (https://brew.sh) then: brew install $pkg"
        fi
    elif command -v apt-get &>/dev/null; then echo "sudo apt-get install -y $pkg"
    elif command -v dnf      &>/dev/null; then echo "sudo dnf install -y $pkg"
    elif command -v pacman   &>/dev/null; then echo "sudo pacman -S --noconfirm $pkg"
    elif command -v zypper   &>/dev/null; then echo "sudo zypper install -y $pkg"
    else echo "install '$pkg' via your package manager"
    fi
}

preflight() {
    step "Pre-flight checks"

    # Required tools (curl is mandatory; awk/tar/sed; git is needed for source builds)
    local missing=()
    for tool in curl awk tar sed; do
        if command -v "$tool" &>/dev/null; then
            ok "$tool"
        else
            missing+=("$tool")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        for t in "${missing[@]}"; do
            warn "missing: $t  → $(pkg_hint "$t")"
        done
        [[ "$DRY_RUN" -eq 1 ]] || error "Install the missing prerequisites and re-run"
    fi

    # Network reachability
    if curl -sfI --connect-timeout 5 https://huggingface.co >/dev/null 2>&1; then
        ok "network: huggingface.co reachable"
    else
        warn "network: cannot reach huggingface.co — model downloads will fail"
        [[ "$DRY_RUN" -eq 1 ]] || error "Check your connection and try again"
    fi

    # Writable directories
    if ! run mkdir -p "$BIN_DIR" "$MODEL_DIR" "$SHARE_DIR" 2>/dev/null; then
        error "Cannot create install directories (${BIN_DIR}, ${SHARE_DIR})"
    fi
    [[ "$DRY_RUN" -eq 1 ]] || { [[ -w "$BIN_DIR" && -w "$SHARE_DIR" ]] || error "Install directories not writable"; }
    ok "directories writable"

    # Python3 (optional but used for GGUF metadata + sha verification)
    if command -v python3 &>/dev/null; then
        ok "python3 (optional, enables sha256 + GGUF tuning)"
    else
        warn "python3 not found — sha256 verification & native-context detection disabled"
    fi
}

ensure_hf_cli() {
    if command -v huggingface-cli &>/dev/null; then
        ok "huggingface-cli"
        return 0
    fi
    info "huggingface-cli not found — attempting pip install"
    if pip3 install --user "huggingface_hub[cli]" 2>/dev/null \
       || python3 -m pip install --user "huggingface_hub[cli]" 2>/dev/null; then
        ok "huggingface-cli installed"
    else
        warn "Could not install huggingface-cli — falling back to plain curl"
    fi
}

# ════════════════════════════════════════════════════════════════════
#  GGUF metadata reader
# ════════════════════════════════════════════════════════════════════
gguf_metadata() {
    # Echo "key=value" lines for the metadata fields we care about.
    local file="$1"
    [[ -f "$file" ]] || return 1
    command -v python3 &>/dev/null || return 1
    python3 -c '
import struct, sys

WANTED = {"general.architecture": "arch"}
SUFFIXES = {
    ".context_length":           "context_length",
    ".block_count":              "block_count",
    ".attention.head_count":     "head_count",
    ".attention.head_count_kv":  "head_count_kv",
    ".embedding_length":         "embedding_length",
    ".attention.key_length":     "key_length",
}
SIZES = {0:1, 1:1, 2:2, 3:2, 4:4, 5:4, 6:4, 7:1, 10:8, 11:8, 12:8}

def rs(f):
    n = struct.unpack("<Q", f.read(8))[0]
    return f.read(n).decode("utf-8", errors="replace")

def rv(f, t):
    if t == 0:  return struct.unpack("<B", f.read(1))[0]
    if t == 1:  return struct.unpack("<b", f.read(1))[0]
    if t == 2:  return struct.unpack("<H", f.read(2))[0]
    if t == 3:  return struct.unpack("<h", f.read(2))[0]
    if t == 4:  return struct.unpack("<I", f.read(4))[0]
    if t == 5:  return struct.unpack("<i", f.read(4))[0]
    if t == 6:  return struct.unpack("<f", f.read(4))[0]
    if t == 7:  return bool(struct.unpack("<B", f.read(1))[0])
    if t == 8:  return rs(f)
    if t == 9:
        et = struct.unpack("<I", f.read(4))[0]
        n  = struct.unpack("<Q", f.read(8))[0]
        return [rv(f, et) for _ in range(n)]
    if t == 10: return struct.unpack("<Q", f.read(8))[0]
    if t == 11: return struct.unpack("<q", f.read(8))[0]
    if t == 12: return struct.unpack("<d", f.read(8))[0]
    raise ValueError(t)

def skipv(f, t):
    if t in SIZES:
        f.seek(SIZES[t], 1)
    elif t == 8:
        n = struct.unpack("<Q", f.read(8))[0]; f.seek(n, 1)
    elif t == 9:
        et = struct.unpack("<I", f.read(4))[0]
        n  = struct.unpack("<Q", f.read(8))[0]
        if et == 8:
            for _ in range(n):
                m = struct.unpack("<Q", f.read(8))[0]; f.seek(m, 1)
        elif et in SIZES:
            f.seek(SIZES[et] * n, 1)
        else:
            for _ in range(n): skipv(f, et)

out = {}
with open(sys.argv[1], "rb") as f:
    if f.read(4) != b"GGUF": sys.exit(0)
    f.read(4); f.read(8)  # version, tensor_count
    kvn = struct.unpack("<Q", f.read(8))[0]
    for _ in range(kvn):
        k = rs(f)
        t = struct.unpack("<I", f.read(4))[0]
        name = WANTED.get(k)
        if name is None:
            for sfx, n2 in SUFFIXES.items():
                if k.endswith(sfx): name = n2; break
        if name is not None:
            out[name] = rv(f, t)
            if len(out) >= 7: break
        else:
            skipv(f, t)

for k, v in out.items():
    print(f"{k}={v}")
' "$file"
}

tune_for_model() {
    local model_file="$1"
    [[ -f "$model_file" ]] || return 0
    step "Auto-tune from GGUF metadata"

    local meta arch native_ctx layers heads kv_heads emb_len key_len head_dim
    meta="$(gguf_metadata "$model_file" 2>/dev/null || true)"
    if [[ -z "$meta" ]]; then
        warn "Could not read GGUF metadata; skipping auto-tune"
        return 0
    fi

    while IFS='=' read -r k v; do
        case "$k" in
            arch)             arch="$v" ;;
            context_length)   native_ctx="$v" ;;
            block_count)      layers="$v" ;;
            head_count)       heads="$v" ;;
            head_count_kv)    kv_heads="$v" ;;
            embedding_length) emb_len="$v" ;;
            key_length)       key_len="$v" ;;
        esac
    done <<<"$meta"

    : "${kv_heads:=${heads:-1}}"
    if [[ -n "$key_len" ]]; then
        head_dim="$key_len"
    elif [[ -n "$emb_len" && -n "$heads" && "$heads" -gt 0 ]]; then
        head_dim=$(( emb_len / heads ))
    fi

    info "arch=${C_BOLD}${arch:-?}${C_RESET}  model_max_ctx=${C_BOLD}${native_ctx:-?}${C_RESET}  layers=${layers:-?}  heads=${heads:-?}/${kv_heads}  head_dim=${head_dim:-?}"

    if [[ -n "$native_ctx" && "$native_ctx" -gt "$USER_CTX" ]]; then
        ok "Requested context ${USER_CTX}; model maximum is ${native_ctx}. Use --context ${native_ctx} to set it manually."
    elif [[ -n "$native_ctx" && "$USER_CTX" -gt "$native_ctx" ]]; then
        warn "Requested context (${USER_CTX}) is above model maximum (${native_ctx}); this may use extra memory or require extrapolation"
    fi

    if [[ -n "$layers" && -n "$head_dim" && -n "$kv_heads" && "$kv_heads" -gt 0 ]]; then
        local kv_bytes mem_bytes
        kv_bytes=$(( 2 * layers * kv_heads * head_dim * USER_CTX * 2 ))   # fp16
        mem_bytes=$(( MEM_GB * 1024 * 1024 * 1024 ))
        info "KV cache @ ctx=${USER_CTX} ≈ ${C_BOLD}$(( kv_bytes / 1024 / 1024 )) MB${C_RESET} (fp16)"
        if (( mem_bytes > 0 && kv_bytes * 5 > mem_bytes * 2 )); then
            if [[ "${EXTRA_ARGS:-}" != *cache-type-* ]]; then
                ok "KV would exceed ~40% of RAM — enabling q8_0 KV cache"
                EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }--cache-type-k q8_0 --cache-type-v q8_0"
            fi
        fi
    fi

    case "$GPU_BACKEND" in
        metal|cuda)
            if [[ "${EXTRA_ARGS:-}" != *flash-attn* ]]; then
                ok "Enabling --flash-attn on (${GPU_BACKEND} backend)"
                EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }--flash-attn on"
            fi
            ;;
    esac

    if [[ "${EXTRA_ARGS:-}" != *--jinja* ]]; then
        ok "Enabling --jinja (chat template from GGUF, needed for tool calls)"
        EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }--jinja"
    fi
}

# ════════════════════════════════════════════════════════════════════
#  HF API helpers
# ════════════════════════════════════════════════════════════════════
_hf_pick_gguf() {
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ggufs = [f["path"] for f in data if isinstance(f, dict) and f.get("path","").lower().endswith(".gguf")]
def rank(p):
    pl = p.lower()
    return (0 if "q4_k_m" in pl else 1 if "q5_k_m" in pl else 2, len(p))
if ggufs:
    ggufs.sort(key=rank)
    print(ggufs[0])
'
}

_hf_field() {
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
path, what = sys.argv[1], sys.argv[2]
for f in data:
    if isinstance(f, dict) and f.get("path") == path:
        if what == "size":
            print(f.get("size") or (f.get("lfs") or {}).get("size") or 0)
        elif what == "sha":
            print((f.get("lfs") or {}).get("oid", ""))
        break
' "$1" "$2"
}

check_disk_space() {
    local dest="$1" need_bytes="$2"
    [[ "${need_bytes:-0}" -gt 0 ]] || return 0
    local free_kb need_kb
    free_kb="$(df -k "$dest" 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ -z "$free_kb" ]] && { warn "Could not determine free disk space at $dest"; return 0; }
    need_kb=$(( need_bytes / 1024 * 11 / 10 ))
    if (( free_kb < need_kb )); then
        error "Insufficient disk space at $dest: $(( free_kb / 1024 )) MB free, need ~$(( need_kb / 1024 )) MB"
    fi
    ok "Disk space: $(( free_kb / 1024 )) MB free, ${C_DIM}need ~$(( need_kb / 1024 )) MB${C_RESET}"
}

verify_sha256() {
    local file="$1" expected="$2"
    if [[ -z "$expected" ]]; then
        warn "No sha256 from HF API; skipping verification"
        return 0
    fi
    local cmd=""
    if command -v sha256sum &>/dev/null; then cmd="sha256sum"
    elif command -v shasum &>/dev/null; then cmd="shasum -a 256"
    else warn "No sha256 tool found; skipping verification"; return 0; fi
    info "Verifying sha256…"
    local got
    got="$($cmd "$file" | awk '{print $1}')"
    if [[ "$got" != "$expected" ]]; then
        error "sha256 mismatch on $file: expected $expected, got $got"
    fi
    ok "sha256 OK"
}

# ════════════════════════════════════════════════════════════════════
#  Model download
# ════════════════════════════════════════════════════════════════════
download_model() {
    local model_id="$1" dest="$2"
    run mkdir -p "$dest"
    step "Model download"
    info "Model: ${C_BOLD}${model_id}${C_RESET}"
    info "Dest:  ${dest}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        printf '%s\n' "${dest}/__dryrun__.gguf"
        return 0
    fi

    local tree="" pick="" expected_sha="" expected_size=0
    tree="$(curl -sfL "https://huggingface.co/api/models/${model_id}/tree/main" 2>/dev/null || true)"
    if [[ -n "$tree" ]] && command -v python3 &>/dev/null; then
        pick="$(printf '%s' "$tree" | _hf_pick_gguf)"
        if [[ -n "$pick" ]]; then
            expected_sha="$(printf '%s' "$tree" | _hf_field "$pick" sha)"
            expected_size="$(printf '%s' "$tree" | _hf_field "$pick" size)"
            check_disk_space "$dest" "${expected_size:-0}"
        fi
    fi
    if [[ -z "$pick" && -n "$tree" ]]; then
        pick="$(printf '%s' "$tree" \
            | grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]*\.gguf"' \
            | sed -E 's/.*"([^"]+)"$/\1/' \
            | { grep -m1 -i 'Q4_K_M' || head -n1; })"
    fi
    [[ -z "$pick" ]] && error "Could not identify a target GGUF in ${model_id}"
    info "Target file: ${C_BOLD}${pick}${C_RESET}"

    local target_path="${dest}/${pick}"
    local existing_size=0

    if [[ -f "$target_path" ]]; then
        existing_size="$(wc -c < "$target_path" | awk '{print $1}')"
        if (( expected_size > 0 && existing_size < expected_size )); then
            if [[ "$REDOWNLOAD" -eq 1 ]]; then
                info "--redownload: removing partial ${pick}"
                run rm -f "$target_path"
            else
                warn "Partial model found: $(( existing_size / 1024 / 1024 )) MB of ~$(( expected_size / 1024 / 1024 )) MB; resuming"
            fi
        elif (( expected_size > 0 && existing_size > expected_size )); then
            warn "Existing model is larger than expected; re-downloading ${pick}"
            run rm -f "$target_path"
        else
            if [[ "$REDOWNLOAD" -eq 1 ]]; then
                info "--redownload: removing existing ${pick}"
                run rm -f "$target_path"
            elif [[ "$ASSUME_YES" -eq 1 ]]; then
                ok "Model already present — reusing"
                printf '%s\n' "$target_path"
                return 0
            else
                ok "Model file already present: $(du -h "$target_path" | awk '{print $1}')"
                if ask_yn "Reuse it and skip the download?" "Y"; then
                    printf '%s\n' "$target_path"
                    return 0
                fi
                info "Re-downloading"
                run rm -f "$target_path"
            fi
        fi
    fi

    run mkdir -p "$(dirname "$target_path")"
    info "Using curl with resume support"
    if curl -fL -C - --progress-bar "https://huggingface.co/${model_id}/resolve/main/${pick}" \
        -o "$target_path"; then
        verify_sha256 "$target_path" "$expected_sha"
    elif command -v huggingface-cli &>/dev/null; then
        warn "curl download failed; falling back to huggingface-cli"
        huggingface-cli download "$model_id" \
            --local-dir "$dest" \
            --include "$pick" >/dev/null \
            || error "huggingface-cli download failed for ${model_id}"
    else
        error "Download failed for $pick"
    fi

    [[ -f "$target_path" ]] || error "Expected downloaded GGUF not found: $target_path"
    if (( expected_size > 0 )); then
        local actual_size
        actual_size="$(wc -c < "$target_path" | awk '{print $1}')"
        [[ "$actual_size" == "$expected_size" ]] || error "Downloaded size mismatch for $pick: expected $expected_size bytes, got $actual_size"
    fi
    ok "Downloaded: ${target_path}"
    printf '%s\n' "$target_path"
}

# ════════════════════════════════════════════════════════════════════
#  Binary: prebuilt vs source
# ════════════════════════════════════════════════════════════════════
prebuilt_asset_pattern() {
    case "$OS-$ARCH-$GPU_BACKEND" in
        macos-arm64-metal) echo 'macos-arm64-metal\.tar\.gz' ;;
        *) echo "" ;;
    esac
}

install_prebuilt() {
    step "Prebuilt binary"
    local pat
    pat="$(prebuilt_asset_pattern)"
    if [[ -z "$pat" ]]; then
        info "No prebuilt asset for ${OS}/${ARCH}/${GPU_BACKEND} — falling back to source build"
        return 1
    fi
    local url
    url="$(curl -sfL "$REPO_RELEASES_API" \
        | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | grep -E "$pat" \
        | head -n1)"
    if [[ -z "$url" ]]; then
        warn "Latest release has no asset matching /$pat/ — falling back to source"
        return 1
    fi
    info "Downloading: $url"
    local tmp
    tmp="$(mktemp -t llama-tq.XXXXXX)"
    if ! run curl -fL --progress-bar "$url" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    # Extract into a staging dir, then consolidate binaries + dylibs + symlinks
    # into ${SHARE_DIR}/bin/.
    local stage
    stage="$(mktemp -d "${SHARE_DIR}/.stage.XXXXXX")"
    run tar -xzf "$tmp" -C "$stage"
    rm -f "$tmp"
    run mkdir -p "${SHARE_DIR}/bin"
    find "$stage" -mindepth 1 \
        \( -name 'llama-*' -o -name '*.dylib' -o -name '*.so' -o -name '*.metal' \) \
        -exec mv {} "${SHARE_DIR}/bin/" \; 2>/dev/null || true
    rm -rf "$stage"
    ok "Installed to ${SHARE_DIR}/bin"
    return 0
}

check_build_tools() {
    local missing=()
    command -v git   &>/dev/null || missing+=("git")
    command -v cmake &>/dev/null || missing+=("cmake")
    if ! command -v c++ &>/dev/null && ! command -v g++ &>/dev/null && ! command -v clang++ &>/dev/null; then
        missing+=("C++ compiler (clang or g++)")
    fi
    if (( ${#missing[@]} > 0 )); then
        for t in "${missing[@]}"; do
            warn "Source build requires: $t  → $(pkg_hint "$t")"
        done
        if [[ "$DRY_RUN" -eq 1 ]]; then
            warn "Dry-run: continuing despite missing build tools"
        else
            error "Install the missing build tools and re-run"
        fi
    fi
}

build_from_source() {
    step "Source build"
    check_build_tools
    if [[ ! -d "${SRC_DIR}/.git" ]]; then
        info "Cloning $REPO_URL"
        run mkdir -p "$(dirname "$SRC_DIR")"
        run git clone "$REPO_URL" "$SRC_DIR"
    else
        info "Repo exists — pulling"
        ( cd "$SRC_DIR" && run git pull --ff-only ) || warn "git pull failed; using existing checkout"
    fi
    local build="${SRC_DIR}/build"
    info "Configuring CMake (backend: $GPU_BACKEND)"
    run cmake -S "$SRC_DIR" -B "$build" \
        -D CMAKE_BUILD_TYPE=Release \
        "${CMAKE_GPU_FLAGS[@]}" \
        || error "CMake configure failed"
    info "Compiling -j${PHYS_CORES}"
    run cmake --build "$build" -j"$PHYS_CORES" --target llama-server llama-cli \
        || error "Build failed"
    run mkdir -p "${SHARE_DIR}/bin"
    find "$build" -maxdepth 4 -type f \( -name llama-server -o -name llama-cli \) \
        -exec cp {} "${SHARE_DIR}/bin/" \; 2>/dev/null || true
    ok "Binaries placed in ${SHARE_DIR}/bin"
}

verify_binary() {
    local bin="$1"
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    [[ -x "$bin" ]] || { warn "Binary not executable: $bin"; return 1; }
    if ! "$bin" --version >/dev/null 2>&1; then
        warn "Binary failed --version check (likely missing libraries)"
        if [[ "$OS" == macos ]]; then
            otool -L "$bin" 2>/dev/null | grep '@rpath' | head -5 >&2 || true
        else
            ldd "$bin" 2>/dev/null | grep "not found" | head -5 >&2 || true
        fi
        return 1
    fi
    ok "Binary works: $("$bin" --version 2>&1 | head -1)"
    return 0
}

choose_binary_method() {
    step "llama-server binary"
    local local_bin="${SHARE_DIR}/bin/llama-server"
    local sys_bin
    sys_bin="$(command -v llama-server 2>/dev/null || true)"
    [[ "$sys_bin" == "$local_bin" ]] && sys_bin=""

    if [[ "$REINSTALL" -eq 1 ]]; then
        info "--reinstall: removing existing installer binaries"
        run rm -rf "${SHARE_DIR}/bin" "${SRC_DIR}/build"
        local_bin=""
    fi

    if [[ -x "$local_bin" ]] && verify_binary "$local_bin"; then
        LLAMA_SERVER_PATH="$local_bin"
        ok "Using installer-owned binary: ${C_BOLD}${LLAMA_SERVER_PATH}${C_RESET}"
        return 0
    fi

    if [[ -n "$sys_bin" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            warn "System llama-server at ${sys_bin} will be used"
            hint "(likely plain llama.cpp, not TurboQuant — pass --reinstall to install TurboQuant)"
            verify_binary "$sys_bin" || warn "system binary failed --version"
            LLAMA_SERVER_PATH="$sys_bin"
            return 0
        fi
        warn "Found system llama-server: ${C_BOLD}${sys_bin}${C_RESET}"
        hint "This is probably plain llama.cpp, not the TurboQuant fork."
        local choice
        choice=$(choose_menu "How should we proceed?" 2 \
            "Use this binary as-is (no TurboQuant low-bit quants)" \
            "Install TurboQuant prebuilt into ${SHARE_DIR}/bin" \
            "Build TurboQuant from source")
        case "$choice" in
            1) LLAMA_SERVER_PATH="$sys_bin" ;;
            2) install_prebuilt || build_from_source ;;
            3) build_from_source ;;
        esac
    else
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            install_prebuilt || build_from_source
        else
            local choice
            choice=$(choose_menu "No llama-server found. Install it via:" 1 \
                "Prebuilt binary (falls back to source if not available for your platform)" \
                "Build from source")
            case "$choice" in
                1) install_prebuilt || build_from_source ;;
                2) build_from_source ;;
            esac
        fi
    fi

    if [[ -z "${LLAMA_SERVER_PATH:-}" ]]; then
        if [[ -x "$local_bin" ]]; then LLAMA_SERVER_PATH="$local_bin"
        else                           LLAMA_SERVER_PATH="$sys_bin"
        fi
    fi
    if [[ -z "$LLAMA_SERVER_PATH" && "${DRY_RUN:-0}" -ne 1 ]]; then
        error "llama-server not found after install/build"
    fi
    if [[ -n "$LLAMA_SERVER_PATH" ]]; then
        verify_binary "$LLAMA_SERVER_PATH" || warn "Verification failed; the launcher may not start cleanly"
    fi
}

# ════════════════════════════════════════════════════════════════════
#  Recommendations
# ════════════════════════════════════════════════════════════════════
fits_under() {
    awk -v size="$1" -v mem="$MEM_GB" -v mult="$2" \
        'BEGIN { exit !(size < mem * mult) }'
}

MODEL_RECOMMENDATIONS=(
    "Qwen/Qwen3-8B-GGUF|5.1|agents/code|Fast local baseline for Agent0-style loops, OpenClaw, Hermes, and coding"
    "bartowski/NousResearch_Hermes-4-14B-GGUF|8.9|agents/reasoning|Hermes 4 reasoning and tool-use oriented model"
    "Qwen/Qwen3-14B-GGUF|9.3|agents/reasoning|Stronger Qwen3 planner with good tool calling and code ability"
    "ggml-org/gemma-4-26B-A4B-it-GGUF|16.8|agents/general|Gemma MoE option used in local-agent docs; 4B active experts"
    "Qwen/Qwen3-30B-A3B-GGUF|18.6|agents/research|MoE agent model for stronger planning with moderate active params"
    "mradermacher/AgentDoG-Qwen3-4B-GGUF|2.6|small/agents|Small agent-safety tuned Qwen3 variant for constrained machines"
    "mradermacher/Qwen3-4B-Agent-Claude-Gemini-GGUF|2.6|small/agents|Small experimental agent finetune for low RAM"
    "bartowski/Athene-V2-Agent-GGUF|47.4|large/agents|Large agent-tuned model for high-memory workstations"
)

show_recommendations() {
    info "${C_DIM}(reserving ~50% of RAM for KV cache + context shifts + OS)${C_RESET}"
    info "Agent-oriented recommendations for Agent0-style runners, OpenClaw, Hermes, Pi, and OpenAI-compatible clients:"
    for entry in "${MODEL_RECOMMENDATIONS[@]}"; do
        local name gb tags desc
        IFS='|' read -r name gb tags desc <<< "$entry"
        if fits_under "$gb" 0.5; then
            printf "  ${C_BGREEN}[OK]${C_RESET}    %-48s ${C_DIM}~%s GB %-15s %s${C_RESET}\n" "$name" "$gb" "[$tags]" "$desc" >&2
        elif fits_under "$gb" 0.8; then
            printf "  ${C_YELLOW}[TIGHT]${C_RESET} %-48s ${C_DIM}~%s GB %-15s needs q8_0 KV / shorter ctx${C_RESET}\n" "$name" "$gb" "[$tags]" >&2
        else
            printf "  ${C_RED}[BIG]${C_RESET}   %-48s ${C_DIM}~%s GB %-15s too large for ${MEM_GB} GB${C_RESET}\n" "$name" "$gb" "[$tags]" >&2
        fi
    done
}

pick_agent_default() {
    if (( MEM_GB >= 96 )); then
        DEFAULT_MODEL="bartowski/Athene-V2-Agent-GGUF"
    elif (( MEM_GB >= 48 )); then
        DEFAULT_MODEL="Qwen/Qwen3-30B-A3B-GGUF"
    elif (( MEM_GB >= 32 )); then
        DEFAULT_MODEL="ggml-org/gemma-4-26B-A4B-it-GGUF"
    elif (( MEM_GB >= 18 )); then
        DEFAULT_MODEL="Qwen/Qwen3-14B-GGUF"
    elif (( MEM_GB >= 10 )); then
        DEFAULT_MODEL="Qwen/Qwen3-8B-GGUF"
    else
        DEFAULT_MODEL="mradermacher/AgentDoG-Qwen3-4B-GGUF"
    fi
}

choose_model_from_catalog() {
    local labels=()
    local entry name gb tags desc
    for entry in "${MODEL_RECOMMENDATIONS[@]}"; do
        IFS='|' read -r name gb tags desc <<< "$entry"
        labels+=( "$name (~${gb} GB, ${tags}) - ${desc}" )
    done
    labels+=( "Custom Hugging Face repo ID" )

    local choice
    choice=$(choose_menu "Model catalog" 1 "${labels[@]}")
    if (( choice == ${#labels[@]} )); then
        local custom=""
        while [[ -z "$custom" ]]; do
            custom="$(ask_string "Enter HuggingFace repo ID (owner/repo)")"
            [[ -z "$custom" ]] && warn "Cannot be empty"
        done
        printf '%s\n' "$custom"
        return 0
    fi

    entry="${MODEL_RECOMMENDATIONS[$(( choice - 1 ))]}"
    IFS='|' read -r name gb tags desc <<< "$entry"
    printf '%s\n' "$name"
}

# ════════════════════════════════════════════════════════════════════
#  Wizard
# ════════════════════════════════════════════════════════════════════
default_for_use_case() {
    case "$1" in
        1) REC_CONTEXT=65536; DEFAULT_MODEL="bartowski/Qwen2.5-7B-Instruct-GGUF" ;;
        2) REC_CONTEXT=65536; DEFAULT_MODEL="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF" ;;
        3)
            REC_CONTEXT=65536
            if (( MEM_GB >= 64 )); then
                DEFAULT_MODEL="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF"
            else
                DEFAULT_MODEL="bartowski/Qwen2.5-7B-Instruct-GGUF"
            fi ;;
        4) REC_CONTEXT=65536; pick_agent_default ;;
        *) error "Invalid use-case: $1" ;;
    esac
}

gpu_layers_default() {
    [[ "$GPU_BACKEND" == "cpu" ]] && echo 0 || echo 99
}

show_extra_arg_suggestions() {
    info "Optional llama-server arg suggestions; press Enter to skip or paste/edit one:"
    hint "Parallel 1:     single-agent / lowest memory / best per-request consistency"
    hint "Parallel 2:     two clients or UI + agent; higher KV memory use"
    hint "Parallel 4+:    shared server / concurrent users; only with plenty of RAM"
    hint "Agent API:      --parallel 1 --cache-reuse 256 --timeout 1200 --alias local-agent --no-webui"
    hint "Reasoning cap:  --parallel 1 --cache-reuse 256 --reasoning-budget 1024 --timeout 1200 --alias local-agent --no-webui"
    hint "Lower RAM:      --parallel 1 --cache-ram 4096 --no-webui"
    hint "LAN access:     --host 0.0.0.0 --api-key <key> --no-webui"
    warn "Avoid --tools all unless you fully trust every client that can reach this server"
}

maybe_resume() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    if [[ "$RESUME" -ne 1 ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then return 1; fi
        ask_yn "Existing config at $CONFIG_FILE — reuse it?" "Y" || return 1
    fi
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    ok "Resumed config from $CONFIG_FILE"
    USE_CASE="${USE_CASE:-1}"
    MODEL_ID="${MODEL_ID:-}"
    USER_CTX="${LLM_CONTEXT:-65536}"
    USER_PORT="${LLM_PORT:-8000}"
    USER_GPU="${GPU_LAYERS:-$(gpu_layers_default)}"
    EXTRA_ARGS="${EXTRA_ARGS:-}"
    [[ -n "$CLI_USE_CASE" ]] && USE_CASE="$CLI_USE_CASE"
    [[ -n "$CLI_MODEL"    ]] && MODEL_ID="$CLI_MODEL"
    [[ -n "$CLI_PORT"     ]] && USER_PORT="$CLI_PORT"
    [[ -n "$CLI_CONTEXT"  ]] && USER_CTX="$CLI_CONTEXT"
    [[ -n "$CLI_GPU"      ]] && USER_GPU="$CLI_GPU"
    [[ -n "$CLI_EXTRA"    ]] && EXTRA_ARGS="$CLI_EXTRA"
    IDLE_SLEEP_SECONDS="${IDLE_SLEEP_SECONDS:-300}"
    IDLE_SHUTDOWN_SECONDS="${IDLE_SHUTDOWN_SECONDS:-0}"
    [[ -n "$CLI_IDLE_SLEEP"    ]] && IDLE_SLEEP_SECONDS="$CLI_IDLE_SLEEP"
    [[ -n "$CLI_IDLE_SHUTDOWN" ]] && IDLE_SHUTDOWN_SECONDS="$CLI_IDLE_SHUTDOWN"
    return 0
}

run_setup_wizard() {
    step "Configuration"

    if maybe_resume; then return; fi

    if [[ "$ASSUME_YES" -ne 1 ]] && ask_yn "Show hardware-based model recommendations?" "Y"; then
        show_recommendations
    fi

    USE_CASE="${CLI_USE_CASE:-}"
    if [[ -z "$USE_CASE" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            USE_CASE=4
        else
            USE_CASE=$(choose_menu "Use case" 4 \
                "General chat / assistant" \
                "Programming / code assistance" \
                "Research / long-context analysis" \
                "Local agents / tool use (Agent0, OpenClaw, Hermes)")
        fi
    fi
    [[ "$USE_CASE" =~ ^[1-4]$ ]] || error "Invalid --use-case: $USE_CASE"
    default_for_use_case "$USE_CASE"

    MODEL_ID="${CLI_MODEL:-}"
    if [[ -z "$MODEL_ID" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            MODEL_ID="$DEFAULT_MODEL"
        else
            info "Recommended model: ${C_BOLD}${DEFAULT_MODEL}${C_RESET}"
            if ask_yn "Accept this model?" "Y"; then
                MODEL_ID="$DEFAULT_MODEL"
            else
                MODEL_ID="$(choose_model_from_catalog)"
            fi
        fi
    fi

    USER_CTX="${CLI_CONTEXT:-}"
    [[ -z "$USER_CTX" ]] && USER_CTX="$(ask_number "Context size (tokens)" "$REC_CONTEXT" 512 1048576)"
    [[ "$USER_CTX" =~ ^[0-9]+$ ]] || error "Invalid --context: $USER_CTX"

    USER_PORT="${CLI_PORT:-}"
    [[ -z "$USER_PORT" ]] && USER_PORT="$(ask_number "Server port" 8000 1 65535)"
    [[ "$USER_PORT" =~ ^[0-9]+$ ]] || error "Invalid --port: $USER_PORT"

    USER_GPU="${CLI_GPU:-}"
    local gpu_def
    gpu_def="$(gpu_layers_default)"
    [[ -z "$USER_GPU" ]] && USER_GPU="$(ask_number "GPU layers to offload" "$gpu_def" 0 999)"
    [[ "$USER_GPU" =~ ^[0-9]+$ ]] || error "Invalid --gpu-layers: $USER_GPU"

    IDLE_SLEEP_SECONDS="${CLI_IDLE_SLEEP:-}"
    [[ -z "$IDLE_SLEEP_SECONDS" ]] && IDLE_SLEEP_SECONDS="$(ask_string "Sleep after idle seconds (-1 disables)" 300)"
    [[ "$IDLE_SLEEP_SECONDS" =~ ^-?[0-9]+$ ]] || error "Invalid --idle-sleep-seconds: $IDLE_SLEEP_SECONDS"
    (( IDLE_SLEEP_SECONDS >= -1 && IDLE_SLEEP_SECONDS <= 86400 )) || error "--idle-sleep-seconds must be between -1 and 86400"

    IDLE_SHUTDOWN_SECONDS="${CLI_IDLE_SHUTDOWN:-}"
    [[ -z "$IDLE_SHUTDOWN_SECONDS" ]] && IDLE_SHUTDOWN_SECONDS="$(ask_number "Shutdown after idle seconds (0 disables)" 0 0 604800)"
    [[ "$IDLE_SHUTDOWN_SECONDS" =~ ^[0-9]+$ ]] || error "Invalid --idle-shutdown-seconds: $IDLE_SHUTDOWN_SECONDS"

    EXTRA_ARGS="${CLI_EXTRA:-}"
    if [[ -z "$EXTRA_ARGS" && "$ASSUME_YES" -ne 1 ]]; then
        show_extra_arg_suggestions
        EXTRA_ARGS="$(ask_string "Extra llama-server args" "")"
    fi
    return 0
}

# ════════════════════════════════════════════════════════════════════
#  Config & launcher
# ════════════════════════════════════════════════════════════════════
write_config() {
    step "Writing config"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] would write: $CONFIG_FILE"
        return
    fi
    {
        echo "# Auto-generated by llama-turboquant-installer — $(date)"
        echo "USE_CASE=\"$USE_CASE\""
        echo "MODEL_ID=\"$MODEL_ID\""
        echo "GPU_LAYERS=\"$USER_GPU\""
        echo "IDLE_SLEEP_SECONDS=\"$IDLE_SLEEP_SECONDS\""
        echo "IDLE_SHUTDOWN_SECONDS=\"$IDLE_SHUTDOWN_SECONDS\""
        echo "EXTRA_ARGS=\"$EXTRA_ARGS\""
        echo "LLM_PORT=\"$USER_PORT\""
        echo "LLM_CONTEXT=\"$USER_CTX\""
        echo "LL_THREADS=\"$RUN_THREADS\""
        echo "GPU_BACKEND=\"$GPU_BACKEND\""
        echo "LLAMA_BUILD_DIR=\"${SHARE_DIR}/bin\""
    } > "$CONFIG_FILE"
    ok "Wrote $CONFIG_FILE"
}

generate_launcher() {
    step "Generating launcher"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] would write: $LAUNCHER_SCRIPT"
        return
    fi
    mkdir -p "$BIN_DIR"
    cat > "$LAUNCHER_SCRIPT" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# llama-cpp-turboquant launcher — autogenerated, do not edit by hand.
set -euo pipefail

CONFIG_FILE="__CONFIG_FILE__"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

LLAMA_SERVER="${LLAMA_SERVER:-__LLAMA_SERVER__}"
MODEL="${MODEL_ID:-}"
PORT="${LLM_PORT:-8000}"
CTX="${LLM_CONTEXT:-65536}"
GPU="${GPU_LAYERS:-99}"
THREADS="${LL_THREADS:-2}"
IDLE_SLEEP="${IDLE_SLEEP_SECONDS:-300}"
IDLE_SHUTDOWN="${IDLE_SHUTDOWN_SECONDS:-0}"

if [[ ! -f "$MODEL" ]]; then
    echo "Model file not found: $MODEL" >&2
    echo "Edit MODEL_ID in $CONFIG_FILE or re-run installer." >&2
    exit 1
fi
if [[ ! -x "$LLAMA_SERVER" ]]; then
    echo "llama-server not found or not executable: $LLAMA_SERVER" >&2
    exit 1
fi

echo "Starting llama-server"
echo "  Model   : $MODEL"
echo "  Context : $CTX"
echo "  GPU     : $GPU layers"
echo "  Port    : $PORT"
echo "  Threads : $THREADS"
echo "  Sleep   : ${IDLE_SLEEP}s idle (-1 disables)"
echo "  Stop    : ${IDLE_SHUTDOWN}s idle (0 disables)"

args=(
    -m "$MODEL" \
    -c "$CTX" \
    --n-gpu-layers "$GPU" \
    -t "$THREADS" \
    --port "$PORT"
)

if [[ "$IDLE_SLEEP" =~ ^-?[0-9]+$ ]] && (( IDLE_SLEEP >= 0 )) && [[ "${EXTRA_ARGS:-}" != *--sleep-idle-seconds* ]]; then
    args+=(--sleep-idle-seconds "$IDLE_SLEEP")
fi

if [[ -n "${EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra_args=( ${EXTRA_ARGS} )
    args+=("${extra_args[@]}")
fi

slot_busy_or_unknown() {
    local body
    body="$(curl -sf --max-time 2 "http://127.0.0.1:${PORT}/slots" 2>/dev/null || true)"
    [[ -n "$body" ]] || return 0

    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$body" | python3 -c '
import json, sys
try:
    slots = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(slots, list):
    sys.exit(0)
busy = any(bool(slot.get("is_processing")) for slot in slots if isinstance(slot, dict))
sys.exit(0 if busy else 1)
' && return 0 || return 1
    fi

    printf '%s' "$body" | grep -q '"is_processing"[[:space:]]*:[[:space:]]*true'
}

if [[ "$IDLE_SHUTDOWN" =~ ^[0-9]+$ ]] && (( IDLE_SHUTDOWN > 0 )); then
    "$LLAMA_SERVER" "${args[@]}" &
    server_pid=$!
    last_active="$(date +%s)"

    cleanup() {
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    }
    trap cleanup INT TERM EXIT

    while kill -0 "$server_pid" 2>/dev/null; do
        sleep 15
        if slot_busy_or_unknown; then
            last_active="$(date +%s)"
            continue
        fi
        now="$(date +%s)"
        if (( now - last_active >= IDLE_SHUTDOWN )); then
            echo "Idle shutdown after ${IDLE_SHUTDOWN}s; stopping llama-server"
            kill "$server_pid" 2>/dev/null || true
            wait "$server_pid" 2>/dev/null || true
            trap - INT TERM EXIT
            exit 0
        fi
    done

    wait "$server_pid"
    status=$?
    trap - INT TERM EXIT
    exit "$status"
fi

exec "$LLAMA_SERVER" "${args[@]}"
LAUNCHER_EOF

    sed -i.bak \
        -e "s|__CONFIG_FILE__|${CONFIG_FILE}|g" \
        -e "s|__LLAMA_SERVER__|${LLAMA_SERVER_PATH}|g" \
        "$LAUNCHER_SCRIPT"
    rm -f "${LAUNCHER_SCRIPT}.bak"
    chmod +x "$LAUNCHER_SCRIPT"

    # Lint the generated launcher
    if ! bash -n "$LAUNCHER_SCRIPT"; then
        error "Generated launcher failed bash syntax check (this is a bug — file an issue)"
    fi
    ok "Wrote $LAUNCHER_SCRIPT"
}

# ════════════════════════════════════════════════════════════════════
#  Health probe
# ════════════════════════════════════════════════════════════════════
do_health_check() {
    step "Health probe"
    [[ -x "$LAUNCHER_SCRIPT" ]] || error "No launcher at $LAUNCHER_SCRIPT (install first)"
    local port=8000
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        port="${LLM_PORT:-8000}"
    fi
    local url="http://localhost:${port}/health"
    local log="/tmp/llm-server-health.log"

    info "Starting launcher in background (log: $log)"
    "$LAUNCHER_SCRIPT" >"$log" 2>&1 &
    local pid=$!
    trap '[[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null || true' EXIT

    info "Polling $url (60s timeout)"
    local _
    for _ in $(seq 1 30); do
        if curl -sf --connect-timeout 2 "$url" >/dev/null 2>&1; then
            ok "Server healthy at $url"
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            tail -n 30 "$log" >&2 || true
            error "Server process exited before responding. See $log"
        fi
        sleep 2
    done
    kill "$pid" 2>/dev/null || true
    tail -n 30 "$log" >&2 || true
    error "Health check timed out after 60 s. See $log"
}

# ════════════════════════════════════════════════════════════════════
#  Summary
# ════════════════════════════════════════════════════════════════════
print_summary() {
    local title="Setup complete"
    local bar=""
    printf -v bar '═%.0s' $(seq 1 60)
    printf "\n${C_BGREEN}%s${C_RESET}\n" "$bar" >&2
    printf "${C_BGREEN}  %s${C_RESET}\n" "$title" >&2
    printf "${C_BGREEN}%s${C_RESET}\n" "$bar" >&2
    cat >&2 <<EOF

  ${C_BOLD}Platform${C_RESET}      ${OS}/${ARCH} (${GPU_BACKEND})
  ${C_BOLD}RAM/cores${C_RESET}     ${MEM_GB} GB / ${PHYS_CORES}
  ${C_BOLD}Threads${C_RESET}       ${RUN_THREADS}
  ${C_BOLD}Binary${C_RESET}        ${LLAMA_SERVER_PATH:-<dry-run>}
  ${C_BOLD}Model${C_RESET}         ${MODEL_GGUF:-<not downloaded>}
  ${C_BOLD}Context${C_RESET}       ${USER_CTX}
  ${C_BOLD}GPU layers${C_RESET}    ${USER_GPU}
  ${C_BOLD}Port${C_RESET}          ${USER_PORT}
  ${C_BOLD}Idle sleep${C_RESET}    ${IDLE_SLEEP_SECONDS}s (-1 disables)
  ${C_BOLD}Idle stop${C_RESET}     ${IDLE_SHUTDOWN_SECONDS}s (0 disables)
  ${C_BOLD}Extra args${C_RESET}    ${EXTRA_ARGS:-<none>}

  ${C_BOLD}Config${C_RESET}        ${CONFIG_FILE}
  ${C_BOLD}Launcher${C_RESET}      ${LAUNCHER_SCRIPT}

EOF
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) hint "$BIN_DIR isn't on your PATH — add it to use 'llm-server' directly" ;;
    esac
}

# ════════════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════════════
main() {
    [[ "$UNINSTALL" -eq 1 ]]   && do_uninstall
    [[ "$HEALTH_CHECK" -eq 1 ]] && { do_health_check; exit 0; }

    detect_platform
    preflight
    ensure_hf_cli

    run_setup_wizard
    choose_binary_method

    MODEL_GGUF=""
    if [[ -n "${MODEL_ID:-}" ]]; then
        if [[ -f "$MODEL_ID" ]]; then
            MODEL_GGUF="$MODEL_ID"
            ok "Using local model: $MODEL_GGUF"
        else
            MODEL_GGUF="$(download_model "$MODEL_ID" "$MODEL_DIR")"
        fi
        MODEL_ID="$MODEL_GGUF"
        tune_for_model "$MODEL_GGUF"
    fi

    write_config
    generate_launcher
    print_summary

    if [[ "$ASSUME_YES" -ne 1 ]] && [[ "$DRY_RUN" -ne 1 ]] && ask_yn "Start the server now?" "Y"; then
        info "Launching $LAUNCHER_SCRIPT"
        exec "$LAUNCHER_SCRIPT"
    else
        info "Run ${C_BOLD}$LAUNCHER_SCRIPT${C_RESET} to start the server"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
