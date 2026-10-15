# Our settings for this recipe (sourced by local/*.sh). Defaults here; put overrides in ./.env (KEY=value lines,
# git-ignored). Pins (base image, TensorFold revision, weights repo/branch/revision) are in local/pins.env.
# See README.md and LOCAL_CHANGES.md.

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$RECIPE_DIR/local/pins.env"
[ -f "$RECIPE_DIR/.env" ] && { set -a; source "$RECIPE_DIR/.env"; set +a; }

: "${CONTAINER_NAME:=Qwen3.6-35B-A3B-EXL3-${MODEL_BRANCH}-TensorFold}"
: "${SERVED_NAME:=$CONTAINER_NAME}"           # the API model id
: "${HOST:=127.0.0.1}"                         # the router reaches models on 127.0.0.1:8001
: "${PORT:=8001}"
: "${KEEP_CONTAINER:=1}"                       # stop.sh keeps the stopped container (no auto-start: restart=no)

# Engine options (tensorfold serve flags, built by local/start.sh)
: "${STREAMS:=8}"                              # --parallel: requests decoded together (upstream default 1 on CUDA)
: "${TF_KEEP:=8}"                              # --checkpoint-slots: prompt states the concurrent decoder keeps
                                               # (upstream 3). Patch 0008 keeps each conversation's latest one, so
                                               # up to TF_KEEP conversations resume their cache. Each is admitted as a
                                               # full window: more = smaller context (see README, "Prompt cache")
: "${CONTEXT:=}"                               # --context: empty = the largest window the admission fits (<= 262144)
: "${MAX_TOKENS:=32768}"                       # --max-tokens: reply cap when a request sets none
: "${MTP_DRAFTS:=8}"                           # --mtp-drafts: 8 = deepest draft (patch 0113; TF_MTP_BY_N picks per stream count); 0 = no drafting
: "${TF_MTP_BY_N:=1:8:0.6;2:3:0.3}"           # patch 0113: streams:drafts:confidence (1 stream 8 drafts, 2+ streams 3)
: "${THINKING:=1}"                             # 0: --no-thinking (requests can still turn it on)
: "${DEFAULT_TEMPERATURE:=}"                   # sampling defaults for fields a request omits; empty = the model's
: "${DEFAULT_TOP_K:=}"                         # generation_config.json (temperature 1.0, top_k 20, top_p 0.95)
: "${DEFAULT_TOP_P:=}"
: "${DEFAULT_MIN_P:=}"
: "${EXTRA_ARGS:=}"                            # more `tensorfold serve` flags, verbatim
: "${TF_PREFILL_STEP:=4096}"                  # patch 0105: prompt rows a prefill step takes while others decode
                                               # (upstream 1024: concurrent prefill ~35% slower; larger = longer
                                               # decode pauses when a prompt arrives)
: "${TF_PREFILL_CHUNK:=4096}"                 # patch 0105: prompt rows a prefill pass (8192: ~+4% prefill, +1.3 GiB)
: "${TENSORFOLD_MEMORY_RESERVE_GIB:=7}"       # memory TensorFold leaves free (the Flash recipe's value)
: "${TF_PROFILE:=0}"                            # 1: kernel profiler on demand (see local/serve_local.py)
: "${TF_PROFILE_TRACE:=0}"                      # 1: the profiler also writes a kernel timeline (.json)
: "${MEMORY_LIMIT:=112g}"                      # container cap (no swap), as the Flash recipe

# Prompt cache on disk (patches 0006 + 0104). Empty PROMPT_CACHE_DIR turns it off.
: "${PROMPT_CACHE_DIR:=${XDG_CACHE_HOME:-$HOME/.cache}/tensorfold-prompt-cache}"   # shared with the Flash recipe; budgets are global
: "${TF_POINTS_LAST:=all}"                      # states at EVERY message start (patch 0010; 3: the last 3; 0: upstream)
: "${TF_POINTS_GAP:=256}"                       # with all: starts before the last 3 at least this far apart (256 = every one; 1024 = cheaper cold prefill of long histories)
: "${TF_PROMPT_CACHE_GIB:=100}"                 # normal points: this many GiB, least recently used out first
: "${TF_PROMPT_CACHE_TTL_H:=72}"                # ... and each deleted this many hours after it was saved
: "${TF_PROMPT_CACHE_PINNED_GIB:=50}"           # pinned points (prompt heads many conversations start with)
: "${TF_PROMPT_CACHE_PIN_AFTER:=3}"             # pinned once this many different continuations resumed from it
: "${TF_PROMPT_CACHE_QUEUE_GIB:=4}"            # host copies waiting for the disk writer; past it points wait on the GPU (0010)
: "${TF_PROMPT_CACHE_EXIT_S:=20}"              # a stopping server waits this long for the writer (stop.sh gives 30 s)

FLASH_RECIPE="${FLASH_RECIPE:-$HOME/recipes/qwen3.8-flash-next-exl3-tensorfold}"   # where BASE_IMAGE comes from
HF_HUB="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"
MODEL_CACHE="$HF_HUB/models--${MODEL_REPO//\//--}"
MODEL_DIR="$MODEL_CACHE/snapshots/$MODEL_REVISION"

# Our image: BASE_IMAGE (the Flash recipe's upstream TensorFold image) plus local/patches/tensorfold/*.patch and our
# serve wrapper, built offline by local/build.sh. Its tag names both inputs, so a change to either asks for a rebuild.
local_image() {
  # TF_LOCAL_IMAGE in .env pins an earlier build (rollback: e.g. the tag before patch 0010); empty = built from patches
  [ -n "${TF_LOCAL_IMAGE:-}" ] && { echo "$TF_LOCAL_IMAGE"; return; }
  local h
  h=$(cat "$RECIPE_DIR"/local/Dockerfile "$RECIPE_DIR"/local/serve_local.py "$RECIPE_DIR"/local/patches/tensorfold/*.patch | sha256sum | cut -c1-12)
  echo "qwen36-35b-a3b-tensorfold-local:${BASE_IMAGE##*:}-$h"
}
log() { printf '[q36-exl3-tf] %s\n' "$*"; }
