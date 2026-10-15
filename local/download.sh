#!/bin/bash
# Download the pinned weights into the Hugging Face cache (local/hf-download.sh: resumable curl, 8 parallel,
# sha256-checked), then verify every file against local/manifest.json.
#   local/download.sh            the pinned revision (local/pins.env)
#   local/download.sh --follow   first re-pin to the branch's newest revision (local/pin-weights.sh), then download
# Used by the router's weights update (models.json "weights_update": "./local/download.sh --follow").
set -euo pipefail
HERE="$(dirname "$0")"
[ "${1:-}" = --follow ] && "$HERE/pin-weights.sh"
source "$HERE/config.sh"
REF="$MODEL_BRANCH" "$RECIPE_DIR/local/hf-download.sh" "$MODEL_REPO" "$MODEL_REVISION"
python3 "$RECIPE_DIR/local/verify_weights.py"
