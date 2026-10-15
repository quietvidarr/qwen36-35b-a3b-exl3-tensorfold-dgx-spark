#!/bin/bash
# Compile the CUDA extensions the 35B's EXL3 path uses, on the CPU (no GPU, no model), into runtime-cache/ where the
# first model start finds them: that start then skips the ~minutes of compiling, and a patch that does not compile
# shows here instead. The extensions are built for GB10 (sm_121), the flags a GPU start uses, so their build keys match.
# Triton kernels still compile on the GPU at the first start (runtime-cache/triton).
#   local/prebuild.sh            (MAX_JOBS=4 by default: nvcc processes in parallel)
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$RECIPE_DIR"
IMG="$(local_image)"
docker image inspect "$IMG" >/dev/null 2>&1 || { log "image $IMG missing: run local/build.sh"; exit 1; }
mkdir -p runtime-cache/{home,torch-extensions,triton}
docker run --rm --network none --user "$(id -u):$(id -g)" -v "$RECIPE_DIR/runtime-cache:/cache:rw" \
  -e HOME=/cache/home -e TORCH_EXTENSIONS_DIR=/cache/torch-extensions -e MAX_JOBS="${MAX_JOBS:-4}" \
  --entrypoint python3 "$IMG" -c '
import importlib, time, torch
torch.cuda.get_device_capability = lambda *a, **k: (12, 1)        # GB10, as a GPU start sees it
torch.cuda.get_device_name = lambda *a, **k: "NVIDIA GB10"
mods = ["tensorfold.cuda.exl3.linear", "tensorfold.cuda.exl3.experts", "tensorfold.families.qwen3_5.cuda.b16",
        "tensorfold.cuda.kernels.gdn", "tensorfold.cuda.kernels.qmm", "tensorfold.cuda.kernels.prefill_attention"]
bad = 0
for name in mods:
    t0 = time.time()
    try:
        importlib.import_module(name)._ext()
        print(f"[prebuild] {name}: OK ({time.time() - t0:.0f}s)", flush=True)
    except Exception as exc:                       # a module that compiled but needs the driver to load is fine
        text = str(exc).splitlines()[-1] if str(exc) else type(exc).__name__
        ok = "libcuda" in text or "CUDA driver" in text or "no CUDA GPUs" in text
        bad += not ok
        status = "compiled (loads on the GPU)" if ok else "FAILED"
        print(f"[prebuild] {name}: {status}: {text[:300]}", flush=True)
raise SystemExit(1 if bad else 0)'
