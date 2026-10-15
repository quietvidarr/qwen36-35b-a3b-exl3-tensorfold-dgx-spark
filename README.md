# Qwen3.6-35B-A3B EXL3 6.00bpw on TensorFold (DGX Spark)

Qwen3.6-35B-A3B in EXL3, served by TensorFold 0.6.5 on one GB10. OpenAI API on 127.0.0.1:8001.

## Install

Install and run through [spark-serving](https://github.com/quietvidarr/spark-serving#setup)'s model router. It installs the Flash recipe and its image first.
The router calls `local/` internally.

## Credits

- Recipe base: souf, [sxuff/qwen38-flash-next-dgx-spark](https://github.com/sxuff/qwen38-flash-next-dgx-spark) (MIT, © 2026 souf): TensorFold base image, `vision-prefix-cache.patch`.
- Weights: [yeasah/Qwen3.6-35B-A3B-exl3](https://huggingface.co/yeasah/Qwen3.6-35B-A3B-exl3).
- Engine: [ashhart/TensorFold](https://github.com/ashhart/TensorFold) (Apache-2.0). TensorFold changes: [quietvidarr/TensorFold-spark](https://github.com/quietvidarr/TensorFold-spark).

## Requirements

- DGX Spark (GB10, 128 GB), Docker with GPU.
- The Flash recipe ([qwen38-flash-next-dgx-spark](https://github.com/quietvidarr/qwen38-flash-next-dgx-spark)) next to this one (else `FLASH_RECIPE`), for the base image. The router installs it.
- ~27 GB disk for weights.

## Config (`.env` overrides `local/config.sh`)

| Setting | Default | Note |
|---|---|---|
| `STREAMS` | 8 | `--parallel` |
| `TF_KEEP` | 8 | kept prompt states; more = shorter context |
| `CONTEXT` | auto | `262144` forces full window |
| `MTP_DRAFTS` | 8 | 0 = no drafting; `TF_MTP_BY_N` per stream count |
| `DEFAULT_TEMPERATURE/TOP_K/TOP_P/MIN_P` | generation_config | 1.0 / 20 / 0.95 |
| `PROMPT_CACHE_DIR` | `~/.cache/tensorfold-prompt-cache` | SSD prompt cache, shared with Flash; empty = off |
| `FLASH_RECIPE` | `../qwen38-flash-next-dgx-spark` | Flash recipe clone (base image, update check) |
| `HF_HUB_CACHE` | `~/.cache/huggingface/hub` | weights |
| `TENSORFOLD_SRC` | `.cache/TensorFold-spark` | fork clone used by the image build |
| `TF_LOCAL_IMAGE` | — | pin an older image (rollback) |

| `TF_KEEP` | 3 | 8 | 12 | 16 |
|---|---:|---:|---:|---:|
| context | 248k-262k | 179k-200k | 147k-164k | 124k-138k |

## Why 6.00bpw

yeasah's published KLD vs bf16 (noise floor 0.0042):

| branch | size | KLD | PPL |
|---|---:|---:|---:|
| 4.00bpw | 18.7 GiB | 0.0115 | 10.122 |
| 5.00bpw | 22.6 GiB | 0.0063 | 10.104 |
| **6.00bpw** | **26.5 GiB** | **0.0049** | **10.097** |

Switch: `local/pin-weights.sh 5.00bpw && local/download.sh`.

## Speed

- Prefill ~3.7-4.3k tok/s alone, ~3.5-4.2k total at 2-8 prompts.
- Decode ~100 tok/s alone (80 at 33k), ~275 total at 8 streams.
- Decode is memory-bound (~200 of ~240 GB/s).

## Notes

- Text only: no vision path for this family in TensorFold 0.6.5.
- bf16 KV only.
- First start compiles kernels: a few minutes.
- Update: the router's `/router/update` (checks compatibility first). Never `git pull`. See [LOCAL_CHANGES.md](LOCAL_CHANGES.md).
