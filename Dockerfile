# syntax=docker/dockerfile:1.7

ARG CUDA_BASE_IMAGE=nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04
FROM ${CUDA_BASE_IMAGE} AS final

ARG CUDA_VARIANT=cu130
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
ARG TORCH_CUDA_PREFIX=13.0
ARG CUPY_PACKAGE=cupy-cuda13x
ARG COMFYUI_REF
ARG COMFYUI_REQUESTED_REF=unknown
ARG COMFYUI_VERSION=unknown

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    PIP_PREFER_BINARY=1 \
    HF_XET_HIGH_PERFORMANCE=1 \
    VENV=/opt/venv \
    COMFY_APP=/opt/ComfyUI \
    COMFYUI_PATH=/opt/ComfyUI \
    COMFY_STATE=/workspace/ComfyUI \
    COMFY_HOME=/workspace/ComfyUI

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev python3-pip \
      git git-lfs curl ca-certificates jq \
      build-essential gcc g++ cmake ninja-build pkg-config \
      ffmpeg aria2 rsync tmux unzip wget vim less nano \
      libgl1 libglib2.0-0 libgoogle-perftools4 \
      openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /var/run/sshd /workspace /workspace/logs \
    && git lfs install --system \
    && python3.12 -m venv "${VENV}"

ENV PATH="${VENV}/bin:${PATH}"

# The selected CUDA profile supplies a small set of binary/ABI guardrails.
# Fast-moving application packages (HF/Transformers/etc.) are intentionally
# not frozen here; modern custom nodes must be able to move that layer forward.
COPY pip.conf /etc/pip.conf
COPY constraints /opt/constraints.d
RUN cp "/opt/constraints.d/${CUDA_VARIANT}.txt" /opt/constraints.txt \
    && echo "== Active image constraints (${CUDA_VARIANT}) ==" \
    && cat /opt/constraints.txt

ENV PIP_CONSTRAINT=/opt/constraints.txt \
    PIP_BUILD_CONSTRAINT=/opt/constraints.txt \
    CUDA_VARIANT=${CUDA_VARIANT}

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade "pip<25.2" "setuptools>=66.1,<82" "wheel>=0.38" \
    && pip install --index-url "${TORCH_INDEX_URL}" \
         torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 \
    && python - <<PY
import torch
expected = "${TORCH_CUDA_PREFIX}"
actual = torch.version.cuda or ""
print("torch:", torch.__version__)
print("torch CUDA:", actual)
assert actual.startswith(expected), (actual, expected)
PY

# COMFYUI_REF is resolved to an immutable commit SHA by the build script.
RUN git init "${COMFY_APP}" \
    && git -C "${COMFY_APP}" remote add origin https://github.com/Comfy-Org/ComfyUI.git \
    && git -C "${COMFY_APP}" fetch --depth=1 origin "${COMFYUI_REF}" \
    && git -C "${COMFY_APP}" checkout --detach FETCH_HEAD \
    && git -C "${COMFY_APP}" rev-parse HEAD | tee /opt/comfyui-commit.txt

WORKDIR ${COMFY_APP}

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt \
    && pip install \
         "huggingface_hub>=1.22.0" \
         "transformers>=5.5" \
         hf_transfer \
         onnxruntime-gpu \
         "${CUPY_PACKAGE}" \
         watchdog \
         opencv-python==4.12.0.88

# Both CUDA variants are intended to be workload-neutral. Assert the native
# Krea2 and MiniMax H3 capabilities that let pod-runtime choose the workload at
# launch rather than forcing model-family-specific Docker images.
RUN test -f "${COMFY_APP}/comfy/text_encoders/krea2.py" \
    && test -f "${COMFY_APP}/comfy_extras/nodes_minimax_h3.py" \
    && python - <<'PY'
from importlib.metadata import version
from packaging.version import Version
import onnxruntime as ort

hub = Version(version("huggingface-hub"))
transformers = Version(version("transformers"))
assert hub >= Version("1.22.0"), hub
assert transformers >= Version("5.5"), transformers
providers = ort.get_available_providers()
assert "CUDAExecutionProvider" in providers, providers
print("huggingface-hub:", hub)
print("transformers:", transformers)
print("onnxruntime providers:", providers)
PY

RUN python -m pip check \
    && python - <<'PY' > /opt/image-stack.txt
from importlib.metadata import PackageNotFoundError, version
packages = [
    "torch", "torchvision", "torchaudio", "numpy", "Pillow",
    "opencv-python", "comfy-aimdo", "comfy-kitchen",
    "huggingface-hub", "transformers", "tokenizers", "safetensors",
    "onnxruntime-gpu",
]
for package in packages:
    try:
        print(f"{package:20s} {version(package)}")
    except PackageNotFoundError:
        print(f"{package:20s} <not installed>")
PY

RUN mkdir -p \
      /workspace/ComfyUI/custom_nodes \
      /workspace/ComfyUI/models \
      /workspace/ComfyUI/input \
      /workspace/ComfyUI/output \
      /workspace/ComfyUI/user \
      /workspace/ComfyUI/cache \
      /workspace/logs

COPY src/start_script.sh /opt/comfyui-inference/start_script.sh
RUN chmod +x /opt/comfyui-inference/start_script.sh

WORKDIR /workspace
EXPOSE 22 8188 8288 8388 8888
ENTRYPOINT ["/opt/comfyui-inference/start_script.sh"]

# Volatile metadata stays at the end so changing labels does not invalidate the
# expensive CUDA/Python/ComfyUI dependency layers above.
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown
ARG IMAGE_VERSION=dev

LABEL org.opencontainers.image.title="comfyui-inference" \
      org.opencontainers.image.description="Headless ComfyUI inference runtime with CUDA 12.8 and CUDA 13.0 build profiles" \
      org.opencontainers.image.source="https://github.com/markwelshboy/comfyui-inference" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      io.markwelshboy.comfy.cuda_variant="${CUDA_VARIANT}" \
      io.markwelshboy.comfy.comfyui_ref="${COMFYUI_REF}" \
      io.markwelshboy.comfy.comfyui_requested_ref="${COMFYUI_REQUESTED_REF}" \
      io.markwelshboy.comfy.comfyui_version="${COMFYUI_VERSION}"
