# Our image = the Flash recipe's upstream TensorFold image (TensorFold 609ca419 + its vision-prefix-cache.patch, at
# /opt/TensorFold) + our TensorFold patches, applied in name order, + our serve wrapper. Built offline by local/build.sh.
ARG BASE
FROM ${BASE}
COPY local/patches/tensorfold/ /opt/recipe-qwen36/patches/
RUN set -e; cd /opt/TensorFold; \
    for p in /opt/recipe-qwen36/patches/*.patch; do git apply --check "$p"; git apply "$p"; echo "applied $p"; done; \
    python3 -m pip install --no-deps --no-build-isolation --no-index /opt/TensorFold
COPY local/serve_local.py /opt/recipe-qwen36/serve_local.py
LABEL qwen.local.patches=1 qwen.recipe=qwen36-35b-a3b-exl3-tensorfold
WORKDIR /opt/recipe-qwen36
ENTRYPOINT ["python3", "/opt/recipe-qwen36/serve_local.py"]
