# Local changes

No upstream recipe. Built on:

| What | From | Pinned in |
|---|---|---|
| Image `qwen38-flash-next-tensorfold:609ca419` | Flash recipe (souf's `scripts/build_tensorfold.sh`) | `local/pins.env` `BASE_IMAGE`, `TENSORFOLD_REV` |
| Patches 0001-0010 | verbatim copies of the Flash recipe's | the files |
| Patches 0101-0125 | ours, this model | the files |
| Weights | `yeasah/Qwen3.6-35B-A3B-exl3` `6.00bpw` | `local/pins.env`, `local/manifest.json` |

## Update

```bash
local/check-update.sh       # read-only. 0 = ok, 3 = incompatible, 1 = check failed
local/update.sh             # re-checks; if ok: copy Flash patches 00*, update pins, commit, build
local/download.sh --follow  # re-pin weights to newest revision (~27 GB)
```
Check compares the Flash recipe's image/revision and patches, then applies the whole stack on its pinned revision.
Flash base image must be built first. Rollback: `git revert HEAD && local/build.sh`.
Incompatible: rebase our `01*.patch`, commit, re-check.

## Recipe (`local/`)

| File | Purpose |
|---|---|
| `pins.env`, `manifest.json`, `pin-weights.sh` | Pins; every weights file with size + sha256 |
| `config.sh` | Settings; `.env` overrides. Name `Qwen3.6-35B-A3B-EXL3-<branch>-TensorFold`, 127.0.0.1:8001 |
| `start.sh`, `stop.sh` | Named container, host network, `--restart no`, kept when stopped; 112 GiB cap, read-only root, non-root |
| `serve_local.py` | Runs `tensorfold serve`; profiler `TF_PROFILE=1` |
| `Dockerfile`, `build.sh` | `BASE_IMAGE` + patches + `serve_local.py`, offline; CPU import check |
| `prebuild.sh` | Compile CUDA extensions on CPU (sm_121) |
| `download.sh`, `verify_weights.py` | Resumable download, sha256-verified |
| `image.sh` | "Update available" = image not built |
| `check-update.sh`, `update.sh` | Safe update |
| `router-entry.json` | Router models.json entry |

## TensorFold patches (applied in name order)

Each file has a header with details.

| # | Change |
|---|---|
| 0001-0010 | Flash recipe's, unchanged (0001/0003/0009 inert here) |
| 0101 | EXL3 for Qwen3.6-35B-A3B on CUDA (`qwen3_5_moe/cuda/exl3.py`): dense + experts + MTP. Was MLX 4-bit only |
| 0102 | Prompt expert kernel in 256-column strips (320 doesn't divide 512/2048) |
| 0103 | Each conversation keeps its latest state (`KeptEnds`); `TF_KEEP` → `--checkpoint-slots` |
| 0104 | SSD prompt cache adapter for this model |
| 0105 | `TF_PREFILL_STEP` 4096: concurrent prefill +30-37% |
| 0106 | Async cache copies: prefill cost 35% → ~3% |
| 0107 | Cached state never dropped; `keep_rank` eviction |
| 0108-0112 | Prompt MoE v2 (deterministic), exact sum, prompt-path fusions, tests |
| 0113 | One read-back per draft level; `MTP_DRAFTS=8` + `TF_MTP_BY_N` |
| 0114-0124 | Decode kernels: 32-row linear, GDN defer, graphs per rows, router tiles, MoE combine, grouped experts |
| 0125 | Short prompt pieces on the fp16 prompt path: exact resume 8/8 (was 6-7/8) |

Untouched: Flash Next path (`qwen4_exp`), 27B path, other families.
Rollback: `TF_LOCAL_IMAGE=<older tag>` in `.env`.

## Rebase onto new TensorFold

```bash
F=<path to Flash recipe>
d=$(mktemp -d); git -C $d init -q; git -C $d remote add origin https://github.com/ashhart/TensorFold.git
git -C $d fetch -q --depth 1 origin <NEW_REV>; git -C $d checkout -q FETCH_HEAD
git -C $d apply $F/patches/*.patch $F/local/patches/tensorfold/*.patch
git -C $d add -A; git -C $d -c user.name=x -c user.email=x commit -qm base
for p in local/patches/tensorfold/01*.patch; do
  git -C $d apply --3way $p && git -C $d add -A && git -C $d -c user.name=x -c user.email=x commit -qm "$p"
done
```

## Tests

- CPU: 1621 passed, 7 failed (same 7 as Flash image: memory-grant, one prefill plan).
- `local/verify_weights.py`: 19 files, 26.63 GiB OK.
- GPU: `tests/cuda/test_qwen36_exl3_moe.py`, `test_exl3_prompt_strips.py`, `test_exl3_prompt_experts.py`, `test_exl3_experts.py`.

## Measure

```bash
M=Qwen3.6-35B-A3B-EXL3-6.00bpw-TensorFold
docker logs $M 2>&1 | grep -E "startup estimate|streams of|serving"
```
Run benches only when `curl -s 127.0.0.1:8001/health` shows `requests_running` 0.
