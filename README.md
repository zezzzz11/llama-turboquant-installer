# llama-turboquant-installer

Hardware-agnostic installer for [llama-cpp-turboquant](https://github.com/TheTom/llama-cpp-turboquant), a fork of llama.cpp with TurboQuant low-bit quantization.

Detects your platform, picks the right GPU backend (Metal / CUDA / ROCm / Vulkan / CPU), downloads a GGUF model from Hugging Face, builds or fetches the server binary, and writes a launcher you can run any time.

## Supported platforms

| OS    | Arch    | GPU backend                                          | Method            |
| ----- | ------- | ---------------------------------------------------- | ----------------- |
| macOS | arm64   | Metal                                                | prebuilt + source |
| macOS | x86_64  | CPU                                                  | source            |
| Linux | x86_64  | CUDA (`nvidia-smi`) / ROCm (`rocminfo`) / Vulkan / CPU | source            |
| Linux | arm64   | same detection, typically CPU or Vulkan              | source            |

Windows isn't covered by this installer. The upstream repo ships a Windows CUDA asset — use it directly.

## Quick start

```bash
git clone https://github.com/zezzzz11/llama-turboquant-installer.git
cd llama-turboquant-installer
./install.sh
```

Non-interactive:

```bash
./install.sh --yes \
    --use-case 4 \
    --model Qwen/Qwen3-8B-GGUF \
    --port 8000 --context 16384
```

## What it does

1. **Detects** OS, arch, RAM, cores, and GPU backend.
2. **Checks** `git`, `cmake`, `curl`, `awk`, and a C++ compiler. Prints the right install command for your package manager if anything is missing.
3. **Asks** (or accepts via flags) use case, model, port, context length, GPU layers, extra server args.
4. **Downloads** the GGUF model via `huggingface-cli` if installed, or the HF API otherwise. Prefers `Q4_K_M`, falls back to `Q5_K_M`, then any GGUF in the repo.
5. **Installs** llama-cpp-turboquant — prebuilt tarball if one matches your platform, otherwise builds from source with the right `cmake` flag for your GPU.
6. **Writes** `~/.llm-server.env` (editable) and a launcher at `~/.local/bin/llm-server`.

## Files installed

| Path                                            | Purpose                                |
| ----------------------------------------------- | -------------------------------------- |
| `~/.local/share/llama-cpp-turboquant/src/`      | source clone                           |
| `~/.local/share/llama-cpp-turboquant/bin/`      | `llama-server`, `llama-cli` binaries   |
| `~/.local/share/llama-cpp-turboquant/models/`   | downloaded GGUF files                  |
| `~/.local/bin/llm-server`                       | launcher script                        |
| `~/.llm-server.env`                             | runtime config (port, context, paths)  |

Add `~/.local/bin` to your `PATH` to run `llm-server` directly.

## Flags

```
--use-case {1|2|3|4}      1=chat, 2=code, 3=research, 4=agents/tools
--model <hf-repo-id>      Hugging Face GGUF repo
--port <int>              llama-server port (default 8000)
--context <int>           context length, tokens
--gpu-layers <int>        layers to offload (default 99 w/GPU, 0 w/CPU)
--extra-args <str>        passed through to llama-server
--yes, -y                 non-interactive; accept defaults
--resume                  reuse existing ~/.llm-server.env
--uninstall               remove installed files and exit
--dry-run                 print actions without executing
--health-check            start the launcher, poll /health, then stop (smoke test)
-h, --help
```

The installer writes a config file you can edit later; rerunning with `--resume` picks it up.

### Model recommendations

The default path is now tuned for local agent runners and OpenAI-compatible clients such as Agent0-style loops, OpenClaw, Hermes, Pi, and OpenCode. The interactive wizard shows a hardware-aware catalog with small, medium, MoE, Hermes, and large agent-tuned options, including:

- `Qwen/Qwen3-8B-GGUF` for a fast default local agent baseline.
- `bartowski/NousResearch_Hermes-4-14B-GGUF` for Hermes-style reasoning and tool use.
- `Qwen/Qwen3-14B-GGUF` and `Qwen/Qwen3-30B-A3B-GGUF` for stronger planning and coding.
- `ggml-org/gemma-4-26B-A4B-it-GGUF` for a Gemma MoE option used in local-agent docs.
- `bartowski/Athene-V2-Agent-GGUF` for high-memory agent workloads.

You can still pass any GGUF repository explicitly with `--model owner/repo`.

### Context size and auto-tuning

The floor is 65 536 tokens across all use cases — enough for modern agentic workloads. After download the installer reads the GGUF's native context length from the file's metadata header; if it's larger than your requested context, **the native value is used instead**. Qwen3.5 reports 256k, Llama 3.1 reports 128k, etc.

KV cache memory is then estimated as:

```
KV bytes ≈ 2 × layers × kv_heads × head_dim × context × 2   # fp16
```

If projected KV exceeds ~40 % of system RAM, the installer automatically appends `--cache-type-k q8_0 --cache-type-v q8_0` to the launcher (halves cache size with negligible quality loss).

On Metal and CUDA backends, `--flash-attn` is also added automatically — large speed and memory gains at long context. Skipped on CPU / Vulkan / HIP where support is partial.

`--jinja` is added on all backends so the model's built-in chat template (from the GGUF) is used. This is required for tool calls to be parsed correctly with modern instruct and agent models (Qwen, Hermes, Gemma, Llama 3.1+, etc.).

Model weights are loaded via mmap (llama.cpp's default), so the OS pages them in from disk on demand. You can keep large models around without burning RAM up front.

### Safety checks

- **Disk space**: before downloading, the installer queries the file size from the Hugging Face tree API and checks `df` — aborts with a clear message if there isn't ~10% headroom.
- **SHA256**: when using the curl fallback (no `huggingface-cli` installed), the installer verifies the downloaded GGUF against the `lfs.oid` reported by the HF API. `huggingface-cli` performs this check internally.
- **Health probe**: `install.sh --health-check` starts the launcher in the background, polls `/health` (60 s timeout), then shuts it down. Useful as a smoke test post-install or in CI.

(Pre-check and sha256 verification require `python3`, which is shipped on macOS and standard on Linux distros. If absent, the installer falls back to a regex-based file pick and skips verification with a warning.)

## Uninstall

```bash
./install.sh --uninstall
```

Removes `~/.local/share/llama-cpp-turboquant/`, `~/.llm-server.env`, and `~/.local/bin/llm-server`.

## Overriding the upstream repo

The installer points at `TheTom/llama-cpp-turboquant`. Override with environment variables if you want to install vanilla llama.cpp or another fork:

```bash
REPO_URL=https://github.com/ggml-org/llama.cpp.git \
REPO_RELEASES_API=https://api.github.com/repos/ggml-org/llama.cpp/releases/latest \
    ./install.sh --yes
```

(For non-turboquant repos, the prebuilt-asset pattern won't match and the installer will build from source. That's expected.)

## License

MIT — see [LICENSE](LICENSE).
