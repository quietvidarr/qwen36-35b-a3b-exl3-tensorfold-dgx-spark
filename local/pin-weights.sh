#!/bin/bash
# Pin the weights: write MODEL_BRANCH / MODEL_REVISION into local/pins.env and the file list (size + sha256 for LFS
# files, git blob sha1 otherwise) into local/manifest.json, from the Hugging Face API. Does not download.
#   local/pin-weights.sh                 re-pin the current branch to its newest revision
#   local/pin-weights.sh 5.00bpw         switch to another branch of the repo (another bpw), newest revision
#   local/pin-weights.sh BRANCH REV      a given revision
# Commits the change when the recipe's git tree has nothing else staged.
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$RECIPE_DIR"
BRANCH="${1:-$MODEL_BRANCH}"
REV="${2:-$(curl -sf "https://huggingface.co/api/models/$MODEL_REPO/revision/$BRANCH" | jq -r .sha)}"
[[ "$REV" =~ ^[0-9a-f]{40}$ ]] || { log "could not resolve $MODEL_REPO@$BRANCH (network?)"; exit 1; }
tmp=$(mktemp)
curl -sf "https://huggingface.co/api/models/$MODEL_REPO/tree/$REV?recursive=true" > "$tmp" || { log "could not list $MODEL_REPO@$REV"; exit 1; }
python3 - "$tmp" "$MODEL_REPO" "$BRANCH" "$REV" > local/manifest.json <<'PY'
import json, sys
tree, repo, branch, rev = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
files = []
for f in tree:
    if f["type"] != "file":
        continue
    lfs = f.get("lfs")
    files.append({"path": f["path"], "bytes": f["size"], "algorithm": "sha256" if lfs else "git-blob-sha1",
                  "digest": lfs["oid"] if lfs else f["oid"]})
json.dump({"repo": repo, "branch": branch, "revision": rev, "files": sorted(files, key=lambda x: x["path"])},
          sys.stdout, indent=1)
print()
PY
rm -f "$tmp"
sed -i "s/^MODEL_BRANCH=.*/MODEL_BRANCH=$BRANCH/; s/^MODEL_REVISION=.*/MODEL_REVISION=$REV/" local/pins.env
log "pinned $MODEL_REPO@$BRANCH = $REV ($(python3 -c "import json;m=json.load(open('local/manifest.json'));print(len(m['files']),'files, %.2f GiB'%(sum(f['bytes'] for f in m['files'])/2**30))"))"
if git diff --quiet --cached && ! git diff --quiet -- local/pins.env local/manifest.json; then
  git add local/pins.env local/manifest.json
  git commit -q -m "pins: weights $MODEL_REPO@$BRANCH $REV" && log "committed the new pins"
fi
[ "$BRANCH" != "$MODEL_BRANCH" ] && log "note: the container and API name follow the branch (Qwen3.6-35B-A3B-EXL3-$BRANCH-TensorFold); update the router entry"
exit 0
