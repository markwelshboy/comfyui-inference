FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    VENV=/opt/venv

# ---- OS + Python 3.11 + tooling ----
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.11 python3.11-venv python3.11-dev \
      git git-lfs curl ca-certificates jq \
      build-essential gcc g++ cmake ninja-build pkg-config \
      ffmpeg aria2 rsync tmux unzip wget vim less nano \
      libgl1 libglib2.0-0 \
      openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && git lfs install --system \
    && python3.11 -m venv "${VENV}"

ENV PATH="${VENV}/bin:${PATH}"

# ---- pip tooling: pin pip to avoid known metadata breakages ----
# (pip>=24.1 rejects old torchsde metadata; pip<24.1 accepts it)
RUN python -m pip install -U "pip<24.1" setuptools wheel

# ---- Copy constraints in (you'll provide this file) ----
COPY constraints.txt /tmp/constraints.txt

# ---- Install matched torch/vision/audio from the nightly cu128 index ----
# IMPORTANT: install them together, pinned, from the same index-url.
ARG TORCH=2.10.0.dev20251114+cu128
ARG TV=0.25.0.dev20251118+cu128
ARG TA=2.10.0.dev20251118+cu128

RUN python -m pip install --no-cache-dir --pre \
      "torch==${TORCH}" \
      "torchvision==${TV}" \
      "torchaudio==${TA}" \
      --index-url https://download.pytorch.org/whl/nightly/cu128

# ---- Base libs you want broadly ----
RUN python -m pip install --no-cache-dir -c /tmp/constraints.txt \
      pyyaml gdown triton \
      huggingface_hub==0.36.0 \
      onnxruntime-gpu opencv-python-headless \
      jupyterlab ipykernel

# ---- ComfyUI (clone exact ref) ----
ARG COMFY_REF=v0.9.2
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI \
 && cd /ComfyUI \
 && git checkout "${COMFY_REF}"

# ---- Install ComfyUI requirements but DO NOT let it re-install torch stack ----
# 1) remove torchaudio from requirements if you want (optional now because we have it)
# 2) install with --no-deps for torch/vision/audio already satisfied
RUN cd /ComfyUI && \
    awk '!/^torchaudio([<=>].*)?$/' requirements.txt > /tmp/requirements.noaudio.txt && \
    python -m pip install --no-cache-dir -c /tmp/constraints.txt -r /tmp/requirements.noaudio.txt

EXPOSE 22 8188 8288 8888
WORKDIR /workspace

CMD ["bash", "-lc", "cd /ComfyUI && python main.py --listen --port 8188"]
