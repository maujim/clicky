#!/bin/sh

llama-server \
    -m /Users/mukund/.cache/huggingface/hub/models--LiquidAI--LFM2.5-VL-1.6B-GGUF/snapshots/48c6a306939241d1ddc99b090df552cb47a066c6/LFM2.5-VL-1.6B-BF16.gguf \
    --mmproj /Users/mukund/.cache/huggingface/hub/models--LiquidAI--LFM2.5-VL-1.6B-GGUF/snapshots/48c6a306939241d1ddc99b090df552cb47a066c6/mmproj-LFM2.5-VL-1.6b-BF16.gguf \
    --host 127.0.0.1 --port 8080 \
    --ctx-size 6125 \
    --flash-attn on \
    --temp 0.9 \
    --top-p 0.9 \
    --min-p 0.05 \
    -ngl 999 \
    --no-warmup \
    --metrics

# 16k context — good balance
# Speed boost for bigger ctx
# Slightly more creative
# Standard nucleus
# Filter garbage
# Less repetition
# Even less repetition (new hotness)
# All GPU
