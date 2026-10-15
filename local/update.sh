#!/bin/bash
# Safe update: check first (local/check-update.sh); only if compatible, follow the Flash recipe's base image, TensorFold
# revision and fork commit (pin them in local/pins.env), commit, and build our image.
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
F_FORK_REV="$(sed -n 's/^TENSORFOLD_FORK_REV=//p' "$F/local/pins.env")"
if [ "$F_IMAGE" != "$BASE_IMAGE" ] || [ "$F_REV" != "$TENSORFOLD_REV" ] || [ "$F_FORK_REV" != "$TENSORFOLD_FORK_REV" ]; then
  sed -i "s#^BASE_IMAGE=.*#BASE_IMAGE=$F_IMAGE#; s/^TENSORFOLD_REV=.*/TENSORFOLD_REV=$F_REV/; s/^TENSORFOLD_FORK_REV=.*/TENSORFOLD_FORK_REV=$F_FORK_REV/" local/pins.env
  git add local/pins.env
  git commit -q -m "follow the Flash recipe: base $F_IMAGE (TensorFold ${F_REV:0:8}), fork ${F_FORK_REV:0:8}" &&
    echo "== recipe updated (git log -1; roll back: git revert HEAD)"
else
  echo "== base and fork unchanged"
fi
echo "== building the image"
"$HERE/local/build.sh" || { echo "image build failed: the previous image is still there; roll back with: git revert HEAD"; exit 1; }
echo "== done. Next model start uses it (CUDA extensions rebuild on its first start). Then re-measure (LOCAL_CHANGES.md)."
