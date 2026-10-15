#!/bin/bash
# Pre-update check (read-only): is this recipe in step with what it builds on, and would an update apply?
#   1. the base: the Flash recipe's TensorFold image and revision (its scripts/supervise.py IMAGE and docker/Dockerfile
#      pin) against ours (local/pins.env);
#   2. the Flash recipe's local TensorFold patches (its local/patches/tensorfold/00*.patch) against our copies;
#   3. our whole patch stack (Flash's upstream patches, its local ones, then our 01*.patch) on the TensorFold revision
#      the Flash recipe now pins, in a scratch tree (TensorFold source cached in ~/recipes/.cache/tensorfold-src/<rev>);
#   4. the weights: the HF branch's newest revision against our pin.
# Exit 0 = up to date or compatible (local/update.sh can apply it), 3 = incompatible (do not update; adapt our
# 01*.patch as LOCAL_CHANGES.md says), 1 = the check itself failed (network, missing Flash recipe).
set -uo pipefail
source "$(dirname "$0")/config.sh"
cd "$RECIPE_DIR"
SRC_CACHE=~/recipes/.cache/tensorfold-src
F="$FLASH_RECIPE"
bad=(); warn=()
fail() { bad+=("$1"); echo "  INCOMPATIBLE: $1"; }
note() { warn+=("$1"); echo "  note: $1"; }
[ -d "$F/local/patches/tensorfold" ] || { echo "Flash recipe not found at $F (FLASH_RECIPE)"; exit 1; }

echo "== 1. base: the Flash recipe's TensorFold image and revision"
F_IMAGE="$(sed -n 's/^IMAGE = "\(.*\)"$/\1/p' "$F/scripts/supervise.py")"
F_REV="$(grep -o 'fetch --depth 1 origin [0-9a-f]\{40\}' "$F/docker/Dockerfile" | awk '{print $NF}')"
[ -n "$F_IMAGE" ] && [ -n "$F_REV" ] || { echo "  cannot read the Flash recipe's image / TensorFold pin"; exit 1; }
if [ "$F_IMAGE" = "$BASE_IMAGE" ] && [ "$F_REV" = "$TENSORFOLD_REV" ]; then echo "  same: $BASE_IMAGE ($TENSORFOLD_REV)"
else
  note "the Flash recipe now builds on $F_IMAGE (TensorFold $F_REV); we pin $BASE_IMAGE ($TENSORFOLD_REV)"
  docker image inspect "$F_IMAGE" >/dev/null 2>&1 || note "$F_IMAGE is not built yet: build the Flash recipe first ($F/local/build.sh)"
fi

echo "== 2. the Flash recipe's local TensorFold patches vs our copies (local/patches/tensorfold/00*.patch)"
same=1
for p in "$F"/local/patches/tensorfold/{000?,0010}-*.patch; do   # Flash 0011+ are Flash-only (hc_gemv, n-gram); not followed
  cmp -s "$p" "local/patches/tensorfold/$(basename "$p")" || { same=0; note "changed or new in the Flash recipe: $(basename "$p")"; }
done
for p in local/patches/tensorfold/{000?,0010}-*.patch; do
  [ -f "$F/local/patches/tensorfold/$(basename "$p")" ] || { same=0; note "gone from the Flash recipe: $(basename "$p")"; }
done
[ $same = 1 ] && echo "  same"

echo "== 3. the patch stack on TensorFold $F_REV (the Flash recipe's upstream + local patches, then ours)"
TF=$(mktemp -d /tmp/q36-tf-XXXX); trap 'rm -rf "$TF"' EXIT
if [ ! -d "$SRC_CACHE/$F_REV/.git" ]; then
  mkdir -p "$SRC_CACHE"; rm -rf "$SRC_CACHE/$F_REV"
  git init -q "$SRC_CACHE/$F_REV" && git -C "$SRC_CACHE/$F_REV" remote add origin https://github.com/ashhart/TensorFold.git
  git -C "$SRC_CACHE/$F_REV" fetch -q --depth 1 origin "$F_REV" && git -C "$SRC_CACHE/$F_REV" checkout -q --detach FETCH_HEAD \
    || { rm -rf "$SRC_CACHE/$F_REV"; echo "  could not fetch TensorFold $F_REV (network?)"; exit 1; }
fi
cp -a "$SRC_CACHE/$F_REV/." "$TF/"; git -C "$TF" checkout -q -- . ; git -C "$TF" clean -qfd
for p in $(grep -o 'git -C /opt/TensorFold apply /opt/recipe/patches/[^ ]*' "$F/docker/Dockerfile" | awk '{print $NF}' | sed 's#/opt/recipe/##'); do
  git -C "$TF" apply "$F/$p" && echo "  Flash upstream $p applied" || fail "the Flash recipe's own $p does not apply to TensorFold $F_REV?"
done
for p in "$F"/local/patches/tensorfold/*.patch "$RECIPE_DIR"/local/patches/tensorfold/01*.patch; do
  if git -C "$TF" apply --check "$p" 2>/tmp/q36-check-apply.err; then git -C "$TF" apply "$p"; echo "  $(basename "$p") applies"
  else fail "$(basename "$p") does not apply: $(head -3 /tmp/q36-check-apply.err | tr '\n' ' ')"; fi
done

echo "== 4. weights: $MODEL_REPO@$MODEL_BRANCH"
REMOTE=$(curl -sf "https://huggingface.co/api/models/$MODEL_REPO/revision/$MODEL_BRANCH" | jq -r .sha 2>/dev/null)
if [ -z "$REMOTE" ] || [ "$REMOTE" = null ]; then note "could not read the branch's revision (network?)"
elif [ "$REMOTE" = "$MODEL_REVISION" ]; then echo "  pinned revision is the newest ($MODEL_REVISION)"
else note "the branch moved: $MODEL_REVISION -> $REMOTE (local/download.sh --follow re-pins and downloads ~27 GB)"; fi

echo
if [ ${#bad[@]} -gt 0 ]; then
  echo "== RESULT: INCOMPATIBLE (${#bad[@]} problem(s)) — do not update. Rebase our 01*.patch per LOCAL_CHANGES.md."
  exit 3
fi
echo "== RESULT: COMPATIBLE${warn:+ with ${#warn[@]} note(s)} — local/update.sh can apply it."
exit 0
