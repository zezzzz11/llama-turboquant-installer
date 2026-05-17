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
HEALTH_CHECK=0
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
  --health-check            start the launcher, poll /health, then stop (smoke test)
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
        --health-check) HEALTH_CHECK=1; shift ;;
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
    for tool in git curl awk tar; do
        if command -v "$tool" &>/dev/null; then
            info "  $tool: OK"
        else
            missing+=("$tool")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        echo "Missing tools:" >&2
        for t in "${missing[@]}"; do
            echo "  • $t — $(pkg_hint "$t")" >&2
        done
        if [[ "$DRY_RUN" -eq 1 ]]; then
            warn "Dry-run: continuing despite missing tools."
        else
            error "Install the missing prerequisites and re-run."
        fi
    fi
}

check_build_tools() {
    # Only needed when we actually build from source.
    local missing=()
    command -v cmake &>/dev/null || missing+=("cmake")
    if ! command -v c++ &>/dev/null && ! command -v g++ &>/dev/null && ! command -v clang++ &>/dev/null; then
        missing+=("C++ compiler (clang or g++)")
    fi
    if (( ${#missing[@]} > 0 )); then
        echo "Source build requires:" >&2
        for t in "${missing[@]}"; do
            echo "  • $t — $(pkg_hint "$t")" >&2
        done
        if [[ "$DRY_RUN" -eq 1 ]]; then
            warn "Dry-run: continuing despite missing build tools."
        else
            error "Install the missing build tools and re-run, or use the prebuilt path if available."
        fi
    fi
}

ensure_hf_cli() {
    if command -v huggingface-cli &>/dev/null; then return 0; fi
    info "huggingface-cli not found — attempting pip install"
    pip3 install --user "huggingface_hub[cli]" 2>/dev/null \
        || python3 -m pip install --user "huggingface_hub[cli]" 2>/dev/null \
        || warn "Could not install huggingface-cli; will use curl fallback."
}

# ---------- GGUF metadata ----------
gguf_metadata() {
    # Echo "key=value" lines for the metadata fields we care about.
    # Requires python3; returns nonzero silently otherwise.
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
    info "=== Inspecting model metadata ==="

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

    info "  arch=${arch:-?}  native_ctx=${native_ctx:-?}  layers=${layers:-?}  heads=${heads:-?}/${kv_heads}  head_dim=${head_dim:-?}"

    # Use native context if larger than what we already have
    if [[ -n "$native_ctx" && "$native_ctx" -gt "$USER_CTX" ]]; then
        info "  Native context (${native_ctx}) > requested ($USER_CTX) — using native"
        USER_CTX="$native_ctx"
    fi

    # Estimate KV cache and auto-shrink if it would crowd RAM
    if [[ -n "$layers" && -n "$head_dim" && -n "$kv_heads" && "$kv_heads" -gt 0 ]]; then
        local kv_bytes mem_bytes
        kv_bytes=$(( 2 * layers * kv_heads * head_dim * USER_CTX * 2 ))   # fp16
        mem_bytes=$(( MEM_GB * 1024 * 1024 * 1024 ))
        info "  KV cache @ ctx=$USER_CTX ≈ $(( kv_bytes / 1024 / 1024 )) MB (fp16)"
        # If KV alone is >40% of RAM, drop to q8_0 (halves it)
        if (( mem_bytes > 0 && kv_bytes * 5 > mem_bytes * 2 )); then
            if [[ "${EXTRA_ARGS:-}" != *cache-type-* ]]; then
                info "  KV would exceed ~40% of RAM — enabling q8_0 KV cache"
                EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }--cache-type-k q8_0 --cache-type-v q8_0"
            fi
        fi
    fi

    # FlashAttention: big speed/memory win on Metal & CUDA at long context.
    # Skipped on CPU/Vulkan/HIP where support is partial or slower.
    # NB: recent llama-server requires a value ('on'|'off'|'auto'), not a bare flag.
    case "$GPU_BACKEND" in
        metal|cuda)
            if [[ "${EXTRA_ARGS:-}" != *flash-attn* ]]; then
                info "  Enabling --flash-attn on ($GPU_BACKEND backend)"
                EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }--flash-attn on"
            fi
            ;;
    esac

    # Jinja: use the model's built-in chat template from GGUF metadata.
    # Near-mandatory for tool calling with modern instruct models.
    if [[ "${EXTRA_ARGS:-}" != *--jinja* ]]; then
        info "  Enabling --jinja (chat template from GGUF, needed for tool calls)"
        EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }--jinja"
    fi
}

# ---------- HF API helpers ----------
_hf_pick_gguf() {
    # Read tree JSON from stdin, echo the best GGUF filename.
    # Prefers Q4_K_M > Q5_K_M > shortest-name GGUF.
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
    # _hf_field <path> {size|sha} — reads tree JSON from stdin
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
    need_kb=$(( need_bytes / 1024 * 11 / 10 ))   # +10% margin
    if (( free_kb < need_kb )); then
        error "Insufficient disk space at $dest: $(( free_kb / 1024 )) MB free, need ~$(( need_kb / 1024 )) MB"
    fi
    info "Disk space OK: $(( free_kb / 1024 )) MB free, need ~$(( need_kb / 1024 )) MB"
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
    info "sha256 OK"
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

    # Use the HF tree API for size pre-check, sha256, and file pick.
    # CRITICAL: without picking a specific file, huggingface-cli downloads the
    # entire repo — bartowski's GGUF repos contain every quant level (50+ GB).
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
    # Regex fallback if python3 isn't available
    if [[ -z "$pick" && -n "$tree" ]]; then
        pick="$(printf '%s' "$tree" \
            | grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]*\.gguf"' \
            | sed -E 's/.*"([^"]+)"$/\1/' \
            | { grep -m1 -i 'Q4_K_M' || head -n1; })"
    fi

    if command -v huggingface-cli &>/dev/null; then
        local include_args=()
        if [[ -n "$pick" ]]; then
            include_args=(--include "$pick")
            info "→ huggingface-cli download $pick"
        else
            warn "Could not identify a specific GGUF — downloading entire repo"
        fi
        huggingface-cli download "$model_id" \
            --local-dir "$dest" --resume-download \
            "${include_args[@]}" >/dev/null \
            || error "huggingface-cli download failed for $model_id"
    else
        info "→ HF API fallback"
        [[ -z "$tree" ]] && error "Cannot reach HF API for $model_id"
        [[ -z "$pick" ]] && error "No GGUF files in $model_id"
        info "Downloading $pick"
        curl -fL "https://huggingface.co/${model_id}/resolve/main/${pick}" \
            -o "${dest}/$(basename "$pick")" \
            || error "Download failed for $pick"
        verify_sha256 "${dest}/$(basename "$pick")" "$expected_sha"
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
    info "    (reserving ~50% of RAM for KV cache, context shifts, OS)"
    local entries=(
        "bartowski/Qwen2.5-7B-Instruct-GGUF:4.5"
        "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF:4.8"
        "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:5.5"
        "bartowski/Meta-Llama-3.1-70B-Instruct-GGUF:40.0"
    )
    # Thresholds are fraction of RAM the model itself occupies.
    # < 0.5 = lots of room for KV at long context.
    # < 0.8 = fits but only with q8_0 KV and/or shorter context.
    # else  = won't fit usefully.
    for entry in "${entries[@]}"; do
        local name="${entry%%:*}" gb="${entry##*:}"
        if fits_under "$gb" 0.5; then
            echo "  [OK]    $name (~${gb} GB) — fits with room for long context"
        elif fits_under "$gb" 0.8; then
            echo "  [TIGHT] $name (~${gb} GB) — fits but needs q8_0 KV / shorter ctx"
        else
            echo "  [BIG]   $name (~${gb} GB) — too large for ${MEM_GB} GB"
        fi
    done
    echo
}

# ---------- wizard ----------
default_for_use_case() {
    # 65 536 is the floor — modern agentic workloads (tool use, long prompts)
    # routinely run past 32k. Qwen2.5 supports up to 128k natively.
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
CTX="${LLM_CONTEXT:-65536}"
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

# ---------- health probe ----------
do_health_check() {
    info "=== Health probe ==="
    [[ -x "$LAUNCHER_SCRIPT" ]] || error "No launcher found at $LAUNCHER_SCRIPT (install first)"
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
            info "✓ Server healthy at $url"
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

# ---------- main ----------
main() {
    [[ "$UNINSTALL" -eq 1 ]] && do_uninstall
    [[ "$HEALTH_CHECK" -eq 1 ]] && { do_health_check; exit 0; }

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
        tune_for_model "$MODEL_GGUF"
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
