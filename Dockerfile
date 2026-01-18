# -----------------------------------------------------------------------------
# ComfyUI inference image (broad-but-stable)
# - CUDA 12.8.1 + cuDNN (Ubuntu 24.04)
# - Python 3.12 venv at /opt/venv
# - Torch nightly cu128 (PINNED torch + torchvision; NO torchaudio)
# - Constraints file pins numpy/huggingface-hub/torch stack to prevent drift
# - OpenCV headless, broad CV stack (kornia/scipy/pillow/einops/etc)
# - ComfyUI from git (pinned ref)
# - pip check + import sanity checks during build
# -----------------------------------------------------------------------------

FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    VENV=/opt/venv

# ---- OS deps + Python 3.12 + tooling ----
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev \
      build-essential gcc g++ cmake ninja-build \
      git git-lfs curl wget aria2 jq \
      ffmpeg \
      openssh-server tmux rsync net-tools \
      libgl1 libglib2.0-0 \
      ca-certificates unzip less nano vim bash-completion && \
    mkdir -p /run/sshd && \
    git lfs install --system && \
    python3.12 -m venv "${VENV}" && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV PATH="${VENV}/bin:${PATH}"

# ---- pip baseline ----
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -U pip setuptools wheel

# -----------------------------------------------------------------------------
# Build args (pins) - override from build script if you want
# -----------------------------------------------------------------------------
ARG TORCH_INDEX="https://download.pytorch.org/whl/nightly/cu128"
ARG TORCH_VER="2.10.0.dev20251114+cu128"
ARG TORCHVISION_VER="0.25.0.dev20251118+cu128"
ARG COMFYUI_REF="v0.9.2"

# Optional metadata args
ARG IMAGE_TAG="latest"
ARG BUILD_GIT_SHA="unknown"
ARG BUILD_DATE="unknown"
ARG IMAGE_VERSION="0.1.0"

ENV IMAGE_TAG="${IMAGE_TAG}" \
    BUILD_GIT_SHA="${BUILD_GIT_SHA}" \
    BUILD_DATE="${BUILD_DATE}" \
    IMAGE_VERSION="${IMAGE_VERSION}"

# -----------------------------------------------------------------------------
# Constraints: copied in (pins numpy/hf-hub/click + locks torch stack)
# -----------------------------------------------------------------------------
COPY constraints.txt /tmp/constraints.txt

# -----------------------------------------------------------------------------
# Torch (pinned) - no torchaudio
# -----------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --pre --no-cache-dir \
      --index-url "${TORCH_INDEX}" \
      "torch==${TORCH_VER}" \
      "torchvision==${TORCHVISION_VER}"

# -----------------------------------------------------------------------------
# Broad baseline libs (installed under constraints to prevent drift)
# -----------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -c /tmp/constraints.txt \
      packaging pyyaml \
      tqdm einops \
      Pillow scipy \
      kornia \
      onnxruntime-gpu \
      opencv-python-headless \
      psutil \
      safetensors \
      filelock fsspec \
      httpx requests

# Optional: Jupyter (comment out if you don't want it in runtime)
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -c /tmp/constraints.txt \
      jupyterlab jupyterlab-lsp \
      jupyter-server jupyter-server-terminals \
      ipykernel jupyterlab_code_formatter

# -----------------------------------------------------------------------------
# ComfyUI from git (single source of truth)
# -----------------------------------------------------------------------------
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI && \
    cd /ComfyUI && \
    git fetch --tags && \
    git checkout "${COMFYUI_REF}"

# Install ComfyUI requirements BUT exclude torchaudio (conflicts with nightly torch)
RUN --mount=type=cache,target=/root/.cache/pip \
    python - <<'PY'
from pathlib import Path
src = Path("/ComfyUI/requirements.txt").read_text().splitlines()
out = []
for line in src:
    s = line.strip()
    if not s or s.startswith("#"):
        out.append(line); continue
    # drop torchaudio (it pins torch==X.Y.Z and breaks nightly)
    if s.split()[0].lower().startswith("torchaudio"):
        continue
    out.append(line)
Path("/tmp/requirements.noaudio.txt").write_text("\n".join(out) + "\n")
print("Wrote /tmp/requirements.noaudio.txt")
PY

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -c /tmp/constraints.txt -r /tmp/requirements.noaudio.txt

# -----------------------------------------------------------------------------
# Sanity checks (fail build if inconsistent)
# -----------------------------------------------------------------------------
RUN python - <<'PY'
import numpy, torch, torchvision
import cv2
print("numpy:", numpy.__version__)
print("torch:", torch.__version__)
print("torchvision:", torchvision.__version__)
print("cv2:", cv2.__version__)
PY

RUN pip check

# ============================
# Final runtime image
# ============================
FROM base AS final

ENV PATH="/opt/venv/bin:$PATH"

# Ports: SSH + multiple Comfy instances + Jupyter
EXPOSE 22 8188 8288 8388 8888

RUN mkdir -p /var/run/sshd /workspace /workspace/logs

# Copy your startup wrapper
COPY src/start_script.sh /start_script.sh
RUN chmod +x /start_script.sh

ENTRYPOINT ["/start_script.sh"]
