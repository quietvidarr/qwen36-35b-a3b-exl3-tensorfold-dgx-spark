#!/usr/bin/env python3
"""`tensorfold serve` (TensorFold's own CLI) for this recipe, plus an opt-in kernel profiler.

local/start.sh passes every serve flag on the container's command line (visible in `docker inspect`); this wrapper
only adds the profiler (TF_PROFILE=1) and a startup line, then runs tensorfold.cli.main with those flags."""
import os
import sys


def _profiler(trigger="/cache/profile.trigger"):
    """Opt-in (TF_PROFILE=1): touch /cache/profile.trigger (the recipe's runtime-cache/) and the next N seconds (the
    file's content, default 20) of CUDA kernels are summed into /cache/profile-<time>.txt. Off by default."""
    import threading
    import time

    def run():
        import torch
        from torch.profiler import ProfilerActivity, profile
        while True:
            time.sleep(1)
            if not os.path.exists(trigger):
                continue
            try:
                secs = float(open(trigger).read().strip() or 20)
            except ValueError:
                secs = 20.0
            os.remove(trigger)
            with profile(activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA]) as prof:
                time.sleep(secs)
                torch.cuda.synchronize()
            out = f"/cache/profile-{time.strftime('%H%M%S')}.txt"
            with open(out, "w") as f:
                f.write(prof.key_averages().table(sort_by="self_cuda_time_total", row_limit=60, max_name_column_width=90))
            if os.environ.get("TF_PROFILE_TRACE") == "1":      # the kernel timeline too (GPU idle gaps)
                prof.export_chrome_trace(out[:-4] + ".json")
            print(f"[serve_local] profile written to {out}", flush=True)

    threading.Thread(target=run, daemon=True, name="tf-profile").start()


if os.environ.get("TF_PROFILE") == "1":
    _profiler()
argv = sys.argv[1:]
print(f"[serve_local] tensorfold serve {' '.join(argv)}", flush=True)
from tensorfold.cli import main  # noqa: E402

raise SystemExit(main(["serve", *argv]))
