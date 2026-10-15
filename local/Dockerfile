# Our image = the Flash recipe's upstream TensorFold image (CUDA, torch, deps) with /opt/TensorFold replaced by our
# fork's tree at TENSORFOLD_FORK_REV (local/pins.env), + our serve wrapper. local/build.sh puts that tree (git archive
# of the pinned commit) in the build context; the build itself is offline.
ARG BASE
FROM ${BASE}
ARG TENSORFOLD_FORK_REV
COPY tensorfold/ /opt/TensorFold.fork/
RUN set -e; test "$(cat /opt/TensorFold.fork/.fork-rev)" = "$TENSORFOLD_FORK_REV"; \
    rm -rf /opt/TensorFold; mv /opt/TensorFold.fork /opt/TensorFold; \
    python3 -m pip install --no-deps --no-build-isolation --no-index /opt/TensorFold
COPY local/serve_local.py /opt/recipe-qwen36/serve_local.py
LABEL qwen.local.patches=1 qwen.recipe=qwen36-35b-a3b-exl3-tensorfold qwen.tensorfold.fork.rev=${TENSORFOLD_FORK_REV}
WORKDIR /opt/recipe-qwen36
ENTRYPOINT ["python3", "/opt/recipe-qwen36/serve_local.py"]
