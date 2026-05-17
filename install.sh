#!/usr/bin/env bash
# llama-turboquant-installer
# Hardware-agnostic installer for llama-cpp-turboquant.
# Supports macOS (arm64/x86_64) and Linux (x86_64/arm64) with
# Metal / CUDA / ROCm / Vulkan / CPU backends.

set -euo pipefail

# ---------- helpers ----------
info()  { printf "\033[1;34m[INFO]\033[0m  %s\n" "$*" >&2; }
warn()  { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*" >&2; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

ask() { local r; read -rp "? $* " r; echo "$r"; }

confirm() {
    if [[ "${ASSUME_YES:-0}" -eq 1 ]]; then return 0; fi
    local r
    read -rp "? $* [y/N] " r
    [[ "$r" =~ ^[yY]([eE][sS])?$ ]]
}

run() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        printf "\033[1;35m[DRY]\033[0m   %s\n" "$*" >&2
    else
        "$@"
    fi
}

# ---------- paths ----------
HOME_DIR="${HOME}"
BIN_DIR="${HOME_DIR}/.local/bin"
SHARE_DIR="${HOME_DIR}/.local/share/llama-cpp-turboquant"
MODEL_DIR="${SHARE_DIR}/models"
SRC_DIR="${SHARE_DIR}/src"
CONFIG_FILE="${HOME_DIR}/.llm-server.env"
LAUNCHER_SCRIPT="${BIN_DIR}/llm-server"

REPO_URL="${REPO_URL:-https://github.com/TheTom/llama-cpp-turboquant.git}"
REPO_RELEASES_API="${REPO_RELEASES_API:-https://api.github.com/repos/TheTom/llama-cpp-turboquant/releases/latest}"

# ---------- CLI ----------
ASSUME_YES=0
RESUME=0
UNINSTALL=0
DRY_RUN=0
CLI_USE_CASE=""
CLI_MODEL=""
CLI_PORT=""
CLI_CONTEXT=""
CLI_GPU=""
CLI_EXTRA=""

usage() {
    cat <<'USAGE'
llama-turboquant-installer

Usage: install.sh [options]

Options:
  --use-case {1|2|3}        1=chat, 2=code, 3=research
  --model <hf-repo-id>      Hugging Face GGUF repo (e.g. bartowski/Qwen2.5-7B-Instruct-GGUF)
  --port <int>              llama-server port (default 8000)
  --context <int>           context length, tokens
  --gpu-layers <int>        layers to offload to GPU (default 99 w/GPU, 0 w/CPU)
  --extra-args <str>        appended to the llama-server invocation
  --yes, -y                 non-interactive; accept defaults
  --resume                  reuse existing ~/.llm-server.env without asking
  --uninstall               remove installed files and exit
  --dry-run                 print actions without executing
  -h, --help                show this help

Examples:
  install.sh                # interactive
  install.sh --yes --use-case 2
  install.sh --yes --model bartowski/Qwen2.5-7B-Instruct-GGUF --port 8001
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --use-case)    CLI_USE_CASE="${2:?--use-case requires value}"; shift 2 ;;
        --model)       CLI_MODEL="${2:?--model requires value}"; shift 2 ;;
        --port)        CLI_PORT="${2:?--port requires value}"; shift 2 ;;
        --context)     CLI_CONTEXT="${2:?--context requires value}"; shift 2 ;;
        --gpu-layers)  CLI_GPU="${2:?--gpu-layers requires value}"; shift 2 ;;
        --extra-args)  CLI_EXTRA="${2:?--extra-args requires value}"; shift 2 ;;
        --yes|-y)      ASSUME_YES=1; shift ;;
        --resume)      RESUME=1; shift ;;
        --uninstall)   UNINSTALL=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) error "Unknown flag: $1 (try --help)" ;;
    esac
done

# ---------- uninstall ----------
do_uninstall() {
    info "Uninstalling llama-turboquant-installer artifacts"
    for p in "$SHARE_DIR" "$CONFIG_FILE" "$LAUNCHER_SCRIPT"; do
        if [[ -e "$p" ]]; then
            info "  removing $p"
            run rm -rf "$p"
        fi
    done
    info "Uninstall complete."
    exit 0
}

# ---------- platform detect ----------
detect_platform() {
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
    else
        local kb
        kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        MEM_GB=$(( kb / 1024 / 1024 ))
        PHYS_CORES="$(nproc 2>/dev/null || echo 2)"
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

    info "Platform: $OS/$ARCH  RAM: ${MEM_GB} GB  Cores: ${PHYS_CORES}  GPU: ${GPU_BACKEND}"
}

# ---------- prereqs ----------
pkg_hint() {
    local pkg="$1"
    if [[ "$OS" == macos ]]; then
        if command -v brew &>/dev/null; then echo "brew install $pkg"
        else echo "install Homebrew from https://brew.sh, then 'brew install $pkg'"
        fi
    elif command -v apt-get &>/dev/null; then echo "sudo apt-get install -y $pkg"
    elif command -v dnf      &>/dev/null; then echo "sudo dnf install -y $pkg"
    elif command -v pacman   &>/dev/null; then echo "sudo pacman -S --noconfirm $pkg"
    elif command -v zypper   &>/dev/null; then echo "sudo zypper install -y $pkg"
    else echo "install '$pkg' via your package manager"
    fi
}

check_tools() {
    info "=== Prerequisite check ==="
    local missing=()
    for tool in git cmake curl awk; do
        if command -v "$tool" &>/dev/null; then
            info "  $tool: OK"
        else
            missing+=("$tool")
        fi
    done
    if ! command -v c++ &>/dev/null && ! command -v g++ &>/dev/null && ! command -v clang++ &>/dev/null; then
        missing+=("C++ compiler (clang or g++)")
    fi
    if (( ${#missing[@]} > 0 )); then
        echo "Missing tools:" >&2
        for t in "${missing[@]}"; do
            echo "  • $t — $(pkg_hint "$t")" >&2
        done
        error "Install the missing prerequisites and re-run."
    fi
}

ensure_hf_cli() {
    if command -v huggingface-cli &>/dev/null; then return 0; fi
    info "huggingface-cli not found — attempting pip install"
    pip3 install --user "huggingface_hub[cli]" 2>/dev/null \
        || python3 -m pip install --user "huggingface_hub[cli]" 2>/dev/null \
        || warn "Could not install huggingface-cli; will use curl fallback."
}

# ---------- model download ----------
download_model() {
    local model_id="$1" dest="$2"
    run mkdir -p "$dest"
    info "Fetching model: $model_id → $dest"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "${dest}/__dryrun__.gguf"
        return 0
    fi

    if command -v huggingface-cli &>/dev/null; then
        info "→ huggingface-cli"
        huggingface-cli download "$model_id" \
            --local-dir "$dest" --resume-download >/dev/null \
            || error "huggingface-cli download failed for $model_id"
    else
        info "→ HF API fallback"
        local api="https://huggingface.co/api/models/${model_id}"
        local listing
        listing="$(curl -sfL "$api")" || error "Cannot reach HF API for $model_id"
        local files
        files="$(printf '%s' "$listing" \
            | grep -oE '"rfilename"[[:space:]]*:[[:space:]]*"[^"]*\.gguf"' \
            | sed -E 's/.*"([^"]+)"$/\1/')"
        [[ -z "$files" ]] && error "No GGUF files listed in $model_id"

        local pick
        pick="$(printf '%s\n' "$files" | grep -m1 -i 'Q4_K_M' || true)"
        [[ -z "$pick" ]] && pick="$(printf '%s\n' "$files" | grep -m1 -i 'Q5_K_M' || true)"
        [[ -z "$pick" ]] && pick="$(printf '%s\n' "$files" | head -n1)"
        info "Downloading $pick"
        curl -fL "https://huggingface.co/${model_id}/resolve/main/${pick}" \
            -o "${dest}/$(basename "$pick")" \
            || error "Download failed for $pick"
    fi

    local gguf
    gguf="$(find "$dest" -name '*.gguf' -type f | head -n1 || true)"
    [[ -z "$gguf" ]] && error "No GGUF file found in $dest after download"
    echo "$gguf"
}

# ---------- prebuilt vs source ----------
prebuilt_asset_pattern() {
    # Echo a regex matching the asset name for this platform, or empty if none.
    # The upstream repo currently ships only macOS arm64 Metal as a Unix-friendly asset.
    case "$OS-$ARCH-$GPU_BACKEND" in
        macos-arm64-metal) echo 'macos-arm64-metal\.tar\.gz' ;;
        *) echo "" ;;
    esac
}

install_prebuilt() {
    info "=== Downloading prebuilt binary ==="
    local pat
    pat="$(prebuilt_asset_pattern)"
    if [[ -z "$pat" ]]; then
        info "No prebuilt asset for $OS/$ARCH/$GPU_BACKEND — will build from source"
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
    if ! run curl -fL "$url" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    run mkdir -p "${SHARE_DIR}/bin"
    run tar -xzf "$tmp" -C "$SHARE_DIR"
    rm -f "$tmp"
    find "$SHARE_DIR" -maxdepth 3 -type f -name 'llama-*' \
        ! -path "${SHARE_DIR}/bin/*" \
        -exec mv {} "${SHARE_DIR}/bin/" \; 2>/dev/null || true
    info "Installed to ${SHARE_DIR}/bin"
    return 0
}

build_from_source() {
    info "=== Building from source ==="
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
    info "Binaries placed in ${SHARE_DIR}/bin"
}

get_llama_server_path() {
    if [[ -x "${SHARE_DIR}/bin/llama-server" ]]; then
        echo "${SHARE_DIR}/bin/llama-server"; return
    fi
    local hb
    hb="$(command -v llama-server 2>/dev/null || true)"
    [[ -n "$hb" ]] && { echo "$hb"; return; }
    echo ""
}

choose_binary_method() {
    LLAMA_SERVER_PATH="$(get_llama_server_path)"
    if [[ -n "$LLAMA_SERVER_PATH" ]]; then
        info "Found existing llama-server: $LLAMA_SERVER_PATH"
        return 0
    fi
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        install_prebuilt || build_from_source
    else
        echo "Obtain llama-cpp-turboquant:" >&2
        echo "  1) Prebuilt (fall back to source if unavailable) [default]" >&2
        echo "  2) Build from source" >&2
        local c
        read -rp "? Choose [1-2, default 1]: " c
        c="${c:-1}"
        case "$c" in
            1) install_prebuilt || build_from_source ;;
            2) build_from_source ;;
            *) error "Invalid selection" ;;
        esac
    fi
    LLAMA_SERVER_PATH="$(get_llama_server_path)"
    if [[ -z "$LLAMA_SERVER_PATH" && "${DRY_RUN:-0}" -ne 1 ]]; then
        error "llama-server not found after install/build"
    fi
    info "llama-server: ${LLAMA_SERVER_PATH:-<dry-run>}"
}

# ---------- recommendations ----------
fits_under() {
    awk -v size="$1" -v mem="$MEM_GB" -v mult="$2" \
        'BEGIN { exit !(size < mem * mult) }'
}

show_recommendations() {
    info "=== Recommendations for ${MEM_GB} GB / ${PHYS_CORES} cores ==="
    local entries=(
        "bartowski/Qwen2.5-7B-Instruct-GGUF:4.5"
        "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF:4.8"
        "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:5.5"
        "bartowski/Meta-Llama-3.1-70B-Instruct-GGUF:40.0"
    )
    for entry in "${entries[@]}"; do
        local name="${entry%%:*}" gb="${entry##*:}"
        if fits_under "$gb" 1.2; then
            echo "  [OK]    $name (~${gb} GB) — fits comfortably"
        elif fits_under "$gb" 1.5; then
            echo "  [TIGHT] $name (~${gb} GB) — tight on ${MEM_GB} GB"
        else
            echo "  [BIG]   $name (~${gb} GB) — too large for ${MEM_GB} GB"
        fi
    done
    echo
}

# ---------- wizard ----------
default_for_use_case() {
    case "$1" in
        1) REC_CONTEXT=8192;  DEFAULT_MODEL="bartowski/Qwen2.5-7B-Instruct-GGUF" ;;
        2) REC_CONTEXT=16384; DEFAULT_MODEL="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF" ;;
        3)
            if (( MEM_GB >= 48 )); then
                REC_CONTEXT=32768; DEFAULT_MODEL="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF"
            else
                REC_CONTEXT=16384; DEFAULT_MODEL="bartowski/Qwen2.5-7B-Instruct-GGUF"
            fi ;;
        *) error "Invalid use-case: $1" ;;
    esac
}

gpu_layers_default() {
    if [[ "$GPU_BACKEND" == "cpu" ]]; then echo 0; else echo 99; fi
}

maybe_resume() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    if [[ "$RESUME" -ne 1 ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then return 1; fi
        confirm "Existing config at $CONFIG_FILE — reuse it?" || return 1
    fi
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    info "Resumed config from $CONFIG_FILE"
    USE_CASE="${USE_CASE:-1}"
    MODEL_ID="${MODEL_ID:-}"
    USER_CTX="${LLM_CONTEXT:-8192}"
    USER_PORT="${LLM_PORT:-8000}"
    USER_GPU="${GPU_LAYERS:-$(gpu_layers_default)}"
    EXTRA_ARGS="${EXTRA_ARGS:-}"
    [[ -n "$CLI_USE_CASE" ]] && USE_CASE="$CLI_USE_CASE"
    [[ -n "$CLI_MODEL"    ]] && MODEL_ID="$CLI_MODEL"
    [[ -n "$CLI_PORT"     ]] && USER_PORT="$CLI_PORT"
    [[ -n "$CLI_CONTEXT"  ]] && USER_CTX="$CLI_CONTEXT"
    [[ -n "$CLI_GPU"      ]] && USER_GPU="$CLI_GPU"
    [[ -n "$CLI_EXTRA"    ]] && EXTRA_ARGS="$CLI_EXTRA"
    return 0
}

run_setup_wizard() {
    if maybe_resume; then return; fi

    if [[ "$ASSUME_YES" -ne 1 ]] && confirm "Show hardware-based model recommendations?"; then
        show_recommendations
    fi

    USE_CASE="${CLI_USE_CASE:-}"
    if [[ -z "$USE_CASE" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            USE_CASE=1
        else
            echo "=== Use case ===" >&2
            echo "  1) General chat / assistant" >&2
            echo "  2) Programming / code assistance" >&2
            echo "  3) Research / long-context analysis" >&2
            while true; do
                local _uc
                read -rp "? Your choice [1-3, default 1]: " _uc
                _uc="${_uc:-1}"
                if [[ "$_uc" =~ ^[1-3]$ ]]; then USE_CASE="$_uc"; break; fi
                echo "Enter 1, 2, or 3." >&2
            done
        fi
    fi
    [[ "$USE_CASE" =~ ^[1-3]$ ]] || error "Invalid --use-case: $USE_CASE"
    default_for_use_case "$USE_CASE"

    MODEL_ID="${CLI_MODEL:-}"
    if [[ -z "$MODEL_ID" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            MODEL_ID="$DEFAULT_MODEL"
        else
            echo "Recommended model for use-case $USE_CASE: $DEFAULT_MODEL" >&2
            local accept
            while true; do
                read -rp "? Accept this model? [Y/n] " accept
                accept="$(printf '%s' "${accept:-y}" | tr '[:upper:]' '[:lower:]')"
                [[ "$accept" =~ ^[yn]$ ]] && break
            done
            if [[ "$accept" == n ]]; then
                while [[ -z "${MODEL_ID:-}" ]]; do
                    read -rp "? Enter HuggingFace repo ID (owner/repo): " MODEL_ID
                done
            else
                MODEL_ID="$DEFAULT_MODEL"
            fi
        fi
    fi

    USER_CTX="${CLI_CONTEXT:-}"
    if [[ -z "$USER_CTX" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            USER_CTX="$REC_CONTEXT"
        else
            while true; do
                local _c
                read -rp "? Context size [$REC_CONTEXT]: " _c
                USER_CTX="${_c:-$REC_CONTEXT}"
                [[ "$USER_CTX" =~ ^[0-9]+$ ]] && break
                echo "Enter a number." >&2
            done
        fi
    fi
    [[ "$USER_CTX" =~ ^[0-9]+$ ]] || error "Invalid --context: $USER_CTX"

    USER_PORT="${CLI_PORT:-}"
    if [[ -z "$USER_PORT" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            USER_PORT=8000
        else
            while true; do
                local _p
                read -rp "? Server port [8000]: " _p
                USER_PORT="${_p:-8000}"
                [[ "$USER_PORT" =~ ^[0-9]+$ ]] && break
                echo "Enter a number." >&2
            done
        fi
    fi
    [[ "$USER_PORT" =~ ^[0-9]+$ ]] || error "Invalid --port: $USER_PORT"

    USER_GPU="${CLI_GPU:-}"
    local gpu_def
    gpu_def="$(gpu_layers_default)"
    if [[ -z "$USER_GPU" ]]; then
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            USER_GPU="$gpu_def"
        else
            while true; do
                local _g
                read -rp "? GPU layers to offload [$gpu_def]: " _g
                USER_GPU="${_g:-$gpu_def}"
                [[ "$USER_GPU" =~ ^[0-9]+$ ]] && break
                echo "Enter a number." >&2
            done
        fi
    fi
    [[ "$USER_GPU" =~ ^[0-9]+$ ]] || error "Invalid --gpu-layers: $USER_GPU"

    EXTRA_ARGS="${CLI_EXTRA:-}"
    if [[ -z "$EXTRA_ARGS" && "$ASSUME_YES" -ne 1 ]]; then
        EXTRA_ARGS="$(ask 'Extra llama-server args (blank for none):')"
    fi
}

# ---------- config + launcher ----------
write_config() {
    info "=== Writing config $CONFIG_FILE ==="
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] would write USE_CASE=$USE_CASE MODEL_ID=$MODEL_ID PORT=$USER_PORT CTX=$USER_CTX GPU=$USER_GPU"
        return
    fi
    {
        echo "# Auto-generated by llama-turboquant-installer — $(date)"
        echo "USE_CASE=\"$USE_CASE\""
        echo "MODEL_ID=\"$MODEL_ID\""
        echo "GPU_LAYERS=\"$USER_GPU\""
        echo "EXTRA_ARGS=\"$EXTRA_ARGS\""
        echo "LLM_PORT=\"$USER_PORT\""
        echo "LLM_CONTEXT=\"$USER_CTX\""
        echo "LL_THREADS=\"$PHYS_CORES\""
        echo "GPU_BACKEND=\"$GPU_BACKEND\""
        echo "LLAMA_BUILD_DIR=\"${SHARE_DIR}/bin\""
    } > "$CONFIG_FILE"
    info "Config saved → $CONFIG_FILE"
}

generate_launcher() {
    info "=== Creating launcher $LAUNCHER_SCRIPT ==="
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] would write launcher"
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
CTX="${LLM_CONTEXT:-8192}"
GPU="${GPU_LAYERS:-99}"
THREADS="${LL_THREADS:-2}"

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

exec "$LLAMA_SERVER" \
    -m "$MODEL" \
    -c "$CTX" \
    --n-gpu-layers "$GPU" \
    -t "$THREADS" \
    --port "$PORT" \
    ${EXTRA_ARGS:-}
LAUNCHER_EOF

    sed -i.bak \
        -e "s|__CONFIG_FILE__|${CONFIG_FILE}|g" \
        -e "s|__LLAMA_SERVER__|${LLAMA_SERVER_PATH}|g" \
        "$LAUNCHER_SCRIPT"
    rm -f "${LAUNCHER_SCRIPT}.bak"
    chmod +x "$LAUNCHER_SCRIPT"
    info "Launcher created: $LAUNCHER_SCRIPT"
}

# ---------- main ----------
main() {
    [[ "$UNINSTALL" -eq 1 ]] && do_uninstall

    detect_platform
    check_tools
    ensure_hf_cli

    run mkdir -p "$BIN_DIR" "$MODEL_DIR" "$SHARE_DIR"

    run_setup_wizard
    choose_binary_method

    MODEL_GGUF=""
    if [[ -n "${MODEL_ID:-}" ]]; then
        if [[ -f "$MODEL_ID" ]]; then
            MODEL_GGUF="$MODEL_ID"
            info "Using local model: $MODEL_GGUF"
        else
            MODEL_GGUF="$(download_model "$MODEL_ID" "$MODEL_DIR")"
        fi
        MODEL_ID="$MODEL_GGUF"
    fi

    write_config
    generate_launcher

    info "=== Setup complete ==="
    cat >&2 <<EOF

  Platform           : $OS/$ARCH ($GPU_BACKEND)
  RAM / cores        : ${MEM_GB} GB / $PHYS_CORES
  llama-server       : ${LLAMA_SERVER_PATH:-<dry-run>}
  Model              : ${MODEL_GGUF:-<not downloaded>}
  Context            : $USER_CTX
  GPU layers         : $USER_GPU
  Port               : $USER_PORT
  Config             : $CONFIG_FILE
  Launcher           : $LAUNCHER_SCRIPT

EOF
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) info "Tip: add $BIN_DIR to your PATH to run 'llm-server' directly." ;;
    esac

    if [[ "$ASSUME_YES" -ne 1 ]] && [[ "$DRY_RUN" -ne 1 ]] && confirm "Start server now?"; then
        info "Launching $LAUNCHER_SCRIPT"
        exec "$LAUNCHER_SCRIPT"
    else
        info "Done. Run '$LAUNCHER_SCRIPT' to start the server."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
