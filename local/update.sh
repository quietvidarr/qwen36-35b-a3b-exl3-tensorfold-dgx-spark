#!/bin/bash
# Safe update: check first (local/check-update.sh); only if compatible, follow the Flash recipe's TensorFold base and
# local patches (copy its 00*.patch, pin its image + revision in local/pins.env), commit, and build our image.
# Weights are separate: local/download.sh --follow (or the router's weights update) re-pins and downloads.
#   local/update.sh            check + follow + build
#   local/update.sh --check    only the check
# The running model is not restarted; the router picks up the new image at its next start.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; cd "$HERE"
"$HERE/local/check-update.sh"; rc=$?
[ "${1:-}" = --check ] && exit $rc
[ $rc = 0 ] || { echo "update NOT applied (check exit $rc)"; exit $rc; }
source "$HERE/local/config.sh"
F="$FLASH_RECIPE"
F_IMAGE="$(sed -n 's/^IMAGE = "\(.*\)"$/\1/p' "$F/scripts/supervise.py")"
F_REV="$(grep -o 'fetch --depth 1 origin [0-9a-f]\{40\}' "$F/docker/Dockerfile" | awk '{print $NF}')"
changed=0
if [ "$F_IMAGE" != "$BASE_IMAGE" ] || [ "$F_REV" != "$TENSORFOLD_REV" ]; then
  sed -i "s#^BASE_IMAGE=.*#BASE_IMAGE=$F_IMAGE#; s/^TENSORFOLD_REV=.*/TENSORFOLD_REV=$F_REV/" local/pins.env
  changed=1
fi
if ! diff -q <(cd "$F/local/patches/tensorfold" && sha256sum {000?,0010}-*.patch) <(cd local/patches/tensorfold && sha256sum {000?,0010}-*.patch) >/dev/null; then
  git rm -q local/patches/tensorfold/{000?,0010}-*.patch   # 01*.patch are ours
  cp "$F"/local/patches/tensorfold/{000?,0010}-*.patch local/patches/tensorfold/
  git add local/patches/tensorfold
  changed=1
fi
if [ $changed = 1 ]; then
  git add local/pins.env
  git commit -q -m "follow the Flash recipe: base $F_IMAGE (TensorFold ${F_REV:0:8}), its local TensorFold patches" &&
    echo "== recipe updated (git log -1; roll back: git revert HEAD)"
else
  echo "== base and Flash patches unchanged"
fi
echo "== building the image"
"$HERE/local/build.sh" || { echo "image build failed: the previous image is still there; roll back with: git revert HEAD"; exit 1; }
echo "== done. Next model start uses it (CUDA extensions rebuild on its first start). Then re-measure (LOCAL_CHANGES.md)."
