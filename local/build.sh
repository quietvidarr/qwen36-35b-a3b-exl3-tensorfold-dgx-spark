#!/bin/bash
# Build our image: BASE_IMAGE (local/pins.env; built by the Flash recipe's local/build.sh, never pulled here) with
# TensorFold from our fork at the pinned commit (local/tensorfold-src.sh: needs the network once) and our serve
# wrapper. The docker build itself is offline. Prints the image tag on its last line.
#   local/build.sh          build what is missing
#   local/build.sh --force  rebuild our layer even if the tag exists
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$RECIPE_DIR"
IMG="$(TF_LOCAL_IMAGE= local_image)"     # always the tag of the pinned inputs (TF_LOCAL_IMAGE only pins what start.sh runs)
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || {
  log "base image $BASE_IMAGE missing: build the Flash recipe first ($FLASH_RECIPE/local/build.sh builds it)"
  exit 1; }
if [ "${1:-}" != --force ] && docker image inspect "$IMG" >/dev/null 2>&1; then
  log "have $IMG"; echo "$IMG"; exit 0
fi
SRC="$(local/tensorfold-src.sh)"
ctx=$(mktemp -d); trap 'rm -rf "$ctx"' EXIT
mkdir -p "$ctx/local" "$ctx/tensorfold"; cp local/Dockerfile local/serve_local.py "$ctx/local/"
git -C "$SRC" archive "$TENSORFOLD_FORK_REV" | tar -x -C "$ctx/tensorfold"
echo "$TENSORFOLD_FORK_REV" > "$ctx/tensorfold/.fork-rev"
docker build --network none --build-arg BASE="$BASE_IMAGE" --build-arg TENSORFOLD_FORK_REV="$TENSORFOLD_FORK_REV" \
  -f "$ctx/local/Dockerfile" -t "$IMG" "$ctx"
# the patched runtime imports (CPU only, no GPU): the 35B's EXL3 path, the 256-column strips, the kept-ends cache
docker run --rm --network none --entrypoint python3 "$IMG" -c '
import inspect
from tensorfold.families import qwen3_5_moe as fam
from tensorfold.families.qwen3_5_moe.cuda import exl3, multi
from tensorfold.cuda.exl3 import experts
assert "exl3" in fam.QUANT_METHODS["cuda"] and fam.CUDA_CHECKPOINT_SLOTS
assert experts.PREFILL_COLS_NARROW == 256 and issubclass(multi.KeptEnds, multi.PrefixCache)
assert "moe=None" in inspect.signature(__import__("tensorfold.families.qwen3_5.cuda.exl3_load", fromlist=["x"]).load_exl3).__str__()
print("patched runtime OK")'
log "built $IMG"
echo "$IMG"
