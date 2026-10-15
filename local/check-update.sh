#!/bin/bash
# Pre-update check (read-only): is this recipe in step with the Flash recipe it builds on?
#   1. the base: the Flash recipe's TensorFold image (its scripts/supervise.py IMAGE) and upstream TensorFold revision
#      (its docker/Dockerfile pin) against ours (local/pins.env);
#   2. the fork: the Flash recipe's TENSORFOLD_FORK_REV (its local/pins.env) against ours. The new commit must contain
#      ours (our 35B commits are in it) and be based on the base image's TensorFold revision;
#   3. the weights: the HF branch's newest revision against our pin.
# Exit 0 = up to date or compatible (local/update.sh can apply it), 3 = incompatible (do not update; fix the fork as
# LOCAL_CHANGES.md says), 1 = the check itself failed (network, missing Flash recipe).
set -uo pipefail
source "$(dirname "$0")/config.sh"
cd "$RECIPE_DIR"
F="$FLASH_RECIPE"
bad=(); warn=()
fail() { bad+=("$1"); echo "  INCOMPATIBLE: $1"; }
note() { warn+=("$1"); echo "  note: $1"; }
[ -f "$F/local/pins.env" ] || { echo "Flash recipe not found at $F (FLASH_RECIPE)"; exit 1; }

echo "== 1. base: the Flash recipe's TensorFold image and revision"
F_IMAGE="$(sed -n 's/^IMAGE = "\(.*\)"$/\1/p' "$F/scripts/supervise.py")"
F_REV="$(grep -o 'fetch --depth 1 origin [0-9a-f]\{40\}' "$F/docker/Dockerfile" | awk '{print $NF}')"
F_FORK_REV="$(sed -n 's/^TENSORFOLD_FORK_REV=//p' "$F/local/pins.env")"
[ -n "$F_IMAGE" ] && [ -n "$F_REV" ] && [ -n "$F_FORK_REV" ] || { echo "  cannot read the Flash recipe's image / pins"; exit 1; }
if [ "$F_IMAGE" = "$BASE_IMAGE" ] && [ "$F_REV" = "$TENSORFOLD_REV" ]; then echo "  same: $BASE_IMAGE ($TENSORFOLD_REV)"
else
  note "the Flash recipe now builds on $F_IMAGE (TensorFold $F_REV); we pin $BASE_IMAGE ($TENSORFOLD_REV)"
  docker image inspect "$F_IMAGE" >/dev/null 2>&1 || note "$F_IMAGE is not built yet: build the Flash recipe first ($F/local/build.sh)"
fi

echo "== 2. fork: the Flash recipe's TensorFold-spark commit"
if [ "$F_FORK_REV" = "$TENSORFOLD_FORK_REV" ]; then echo "  same: $TENSORFOLD_FORK_REV"
else
  SRC="$(local/tensorfold-src.sh "$F_FORK_REV")" && local/tensorfold-src.sh >/dev/null \
    || { echo "  could not fetch the fork (network or GH_TOKEN?)"; exit 1; }
  git -C "$SRC" merge-base --is-ancestor "$TENSORFOLD_FORK_REV" "$F_FORK_REV" \
    && note "fork moves $TENSORFOLD_FORK_REV -> $F_FORK_REV" \
    || fail "the Flash recipe's fork commit $F_FORK_REV does not contain ours ($TENSORFOLD_FORK_REV)"
  git -C "$SRC" merge-base --is-ancestor "$F_REV" "$F_FORK_REV" 2>/dev/null \
    || fail "fork commit $F_FORK_REV is not based on TensorFold $F_REV (the base image's)"
  git -C "$SRC" cat-file -e "$F_FORK_REV:src/tensorfold/families/qwen3_5_moe/cuda/exl3.py" 2>/dev/null \
    || fail "fork commit $F_FORK_REV has no Qwen3.6 EXL3 path (qwen3_5_moe/cuda/exl3.py)"
fi

echo "== 3. weights: $MODEL_REPO@$MODEL_BRANCH"
REMOTE=$(curl -sf "https://huggingface.co/api/models/$MODEL_REPO/revision/$MODEL_BRANCH" | jq -r .sha 2>/dev/null)
if [ -z "$REMOTE" ] || [ "$REMOTE" = null ]; then note "could not read the branch's revision (network?)"
elif [ "$REMOTE" = "$MODEL_REVISION" ]; then echo "  pinned revision is the newest ($MODEL_REVISION)"
else note "the branch moved: $MODEL_REVISION -> $REMOTE (local/download.sh --follow re-pins and downloads ~27 GB)"; fi

echo
if [ ${#bad[@]} -gt 0 ]; then
  echo "== RESULT: INCOMPATIBLE (${#bad[@]} problem(s)) — do not update. Fix the fork per LOCAL_CHANGES.md."
  exit 3
fi
echo "== RESULT: COMPATIBLE${warn:+ with ${#warn[@]} note(s)} — local/update.sh can apply it."
exit 0
