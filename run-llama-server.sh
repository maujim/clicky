#!/bin/sh
set -eu

# The 1.6B BF16 vision model can exhaust Metal memory while processing
# screenshots, which makes llama-server drop the HTTP connection and then
# segfault. Default to the smaller VL model and lower the context/GPU pressure.
MODEL_SIZE="${CLICKY_VISION_MODEL_SIZE:-450M}"
HOST="${CLICKY_VISION_HOST:-127.0.0.1}"
PORT="${CLICKY_VISION_PORT:-8080}"
CTX_SIZE="${CLICKY_VISION_CTX_SIZE:-4096}"
GPU_LAYERS="${CLICKY_VISION_GPU_LAYERS:-99}"

case "$MODEL_SIZE" in
  450M|450m)
    MODEL_PATH="$HOME/.cache/huggingface/hub/models--LiquidAI--LFM2.5-VL-450M-GGUF/snapshots/a4159447772846ffa1b381688c3d3ca0e4db60ed/LFM2.5-VL-450M-F32.gguf"
    MMPROJ_PATH="$HOME/.cache/huggingface/hub/models--LiquidAI--LFM2.5-VL-450M-GGUF/snapshots/a4159447772846ffa1b381688c3d3ca0e4db60ed/mmproj-LFM2.5-VL-450m-F32.gguf"
    ;;
  1.6B|1.6b|1600M|1600m)
    MODEL_PATH="$HOME/.cache/huggingface/hub/models--LiquidAI--LFM2.5-VL-1.6B-GGUF/snapshots/48c6a306939241d1ddc99b090df552cb47a066c6/LFM2.5-VL-1.6B-BF16.gguf"
    MMPROJ_PATH="$HOME/.cache/huggingface/hub/models--LiquidAI--LFM2.5-VL-1.6B-GGUF/snapshots/48c6a306939241d1ddc99b090df552cb47a066c6/mmproj-LFM2.5-VL-1.6b-BF16.gguf"
    ;;
  *)
    echo "Unknown CLICKY_VISION_MODEL_SIZE: $MODEL_SIZE (expected 450M or 1.6B)" >&2
    exit 1
    ;;
esac

if [ ! -f "$MODEL_PATH" ] || [ ! -f "$MMPROJ_PATH" ]; then
  echo "Missing model files for $MODEL_SIZE. Download the LiquidAI VL GGUF model first." >&2
  exit 1
fi

exec llama-server \
  -m "$MODEL_PATH" \
  --mmproj "$MMPROJ_PATH" \
  --host "$HOST" --port "$PORT" \
  --ctx-size "$CTX_SIZE" \
  --flash-attn off \
  --cache-ram 0 \
  --temp 0.7 \
  --top-p 0.9 \
  --min-p 0.05 \
  -ngl "$GPU_LAYERS" \
  --no-warmup \
  --metrics
