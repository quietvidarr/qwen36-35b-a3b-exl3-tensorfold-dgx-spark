#!/bin/bash
# Start the model for the router (models.json "start"). Reuses the kept container when its image and settings are
# unchanged; otherwise recreates it. Waits until it serves, or exits non-zero with the log.
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$RECIPE_DIR"
IMG="$(local_image)"
docker image inspect "$IMG" >/dev/null 2>&1 || { log "image $IMG missing: run local/build.sh"; exit 1; }
[ -f "$MODEL_DIR/config.json" ] && [ -f "$MODEL_DIR/model.safetensors.index.json" ] || {
  log "weights missing: run local/download.sh"; exit 1; }
mkdir -p runtime-cache/{home,torch-extensions,triton}

ENVS=(TENSORFOLD_MEMORY_RESERVE_GIB TF_MTP_BY_N TF_PROFILE TF_PROFILE_TRACE PORT SERVED_NAME TF_POINTS_LAST TF_POINTS_GAP TF_PREFILL_STEP TF_PREFILL_CHUNK)
args=(--name "$CONTAINER_NAME" --label qwen.recipe=qwen36-35b-a3b-exl3-tensorfold --restart no
      --gpus all --network host --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" --shm-size 2g
      --read-only --tmpfs /tmp:rw,noexec,nosuid,size=1g --user "$(id -u):$(id -g)"
      -v "$MODEL_CACHE:/hf/model:ro" -v "$RECIPE_DIR/runtime-cache:/cache:rw"
      -e HOME=/cache/home -e TORCH_EXTENSIONS_DIR=/cache/torch-extensions -e TRITON_CACHE_DIR=/cache/triton
      -e MAX_JOBS=1 -e TENSORFOLD_NO_UPDATE_CHECK=1 -e HF_HUB_OFFLINE=1)
for v in "${ENVS[@]}"; do args+=(-e "$v=${!v}"); done
if [ -n "$PROMPT_CACHE_DIR" ]; then              # patches 0006 + 0104: kept prompt states on disk
  mkdir -p "$PROMPT_CACHE_DIR"
  args+=(-v "$PROMPT_CACHE_DIR:/prompt-cache:rw" -e TF_PROMPT_CACHE_DIR=/prompt-cache
         -e "TF_PROMPT_CACHE_KEY=$IMG|$MODEL_REPO@$MODEL_REVISION|bf16")
  for v in TF_PROMPT_CACHE_GIB TF_PROMPT_CACHE_TTL_H TF_PROMPT_CACHE_PINNED_GIB TF_PROMPT_CACHE_PIN_AFTER \
           TF_PROMPT_CACHE_QUEUE_GIB TF_PROMPT_CACHE_EXIT_S; do
    args+=(-e "$v=${!v}"); done
fi
# `tensorfold serve` flags (local/serve_local.py runs TensorFold's own CLI with them)
serve=("/hf/model/snapshots/$MODEL_REVISION" --backend cuda --host "$HOST" --port "$PORT" --name "$SERVED_NAME"
       --parallel "$STREAMS" --checkpoint-slots "$TF_KEEP" --max-tokens "$MAX_TOKENS" --no-update-check)
[ -n "$CONTEXT" ] && serve+=(--context "$CONTEXT")
[ -n "$MTP_DRAFTS" ] && serve+=(--mtp-drafts "$MTP_DRAFTS")
[ "$THINKING" = 0 ] && serve+=(--no-thinking)
[ -n "$DEFAULT_TEMPERATURE" ] && serve+=(--temperature "$DEFAULT_TEMPERATURE")
[ -n "$DEFAULT_TOP_K" ] && serve+=(--top-k "$DEFAULT_TOP_K")
[ -n "$DEFAULT_TOP_P" ] && serve+=(--top-p "$DEFAULT_TOP_P")
[ -n "$DEFAULT_MIN_P" ] && serve+=(--min-p "$DEFAULT_MIN_P")
# shellcheck disable=SC2206
[ -n "$EXTRA_ARGS" ] && serve+=($EXTRA_ARGS)
args+=("$IMG" "${serve[@]}")
want=$(printf '%s\n' "${args[@]}" | sha256sum | cut -c1-16)

have=$(docker inspect -f '{{index .Config.Labels "qwen.local.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)
if [ -n "$have" ] && [ "$have" = "$want" ]; then
  log "starting kept container $CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null
else
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    owner=$(docker inspect -f '{{index .Config.Labels "qwen.recipe"}}' "$CONTAINER_NAME")
    [ "$owner" = qwen36-35b-a3b-exl3-tensorfold ] || { log "a container named $CONTAINER_NAME exists that is not ours"; exit 1; }
    log "settings or image changed: recreating $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null
  fi
  log "creating $CONTAINER_NAME from $IMG (streams $STREAMS, kept states $TF_KEEP, context ${CONTEXT:-auto})"
  docker run -d --label "qwen.local.config=$want" "${args[@]}" >/dev/null
fi

t0=$(date +%s)
until curl -sf "http://127.0.0.1:$PORT/v1/models" | grep -q "\"$SERVED_NAME\""; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != true ]; then
    log "container exited:"; docker logs --tail 40 "$CONTAINER_NAME" 2>&1; exit 1
  fi
  (( $(date +%s) - t0 > ${READY_TIMEOUT:-2400} )) && { log "not ready after ${READY_TIMEOUT:-2400}s"; exit 1; }
  sleep 2
done
log "ready on $HOST:$PORT as $SERVED_NAME after $(( $(date +%s) - t0 ))s"
docker logs "$CONTAINER_NAME" 2>&1 | grep -E "startup estimate|streams of|serving|GiB" | tail -4 || true
