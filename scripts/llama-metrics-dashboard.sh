#!/bin/bash
# Quick llama-server metrics dashboard via glimpse
# Usage: bash scripts/llama-metrics-dashboard.sh

INTERVAL=3

while true; do
  DATA=$(curl -sf http://127.0.0.1:8080/metrics 2>/dev/null)

  if [ -z "$DATA" ]; then
    HTML="<div style='font-family:system-ui;padding:2rem;color:#ef4444'><h2>⚠️ llama-server not running</h2><p>Make sure it's started on port 8080</p></div>"
  else
    TOKENS_SEC=$(echo "$DATA" | grep -o '"tokens_per_second": [0-9.]*' | head -1 | awk '{print $2}')
    PROMPT_SEC=$(echo "$DATA" | grep -o '"prompt_tokens_per_second": [0-9.]*' | head -1 | awk '{print $2}')
    KV_CACHE=$(echo "$DATA" | grep -o '"kv_cache_usage_ratio": [0-9.]*' | head -1 | awk '{print $2}')
    TOTAL_TOKENS=$(echo "$DATA" | grep -o '"total_tokens": [0-9]*' | head -1 | awk '{print $2}')
    MODEL=$(echo "$DATA" | grep -o '"model": "[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$TOKENS_SEC" ]; then
      # Try prometheus text format
      TOKENS_SEC=$(echo "$DATA" | grep 'llamacpp_inference_tokens_per_second' | awk '{print $2}')
      PROMPT_SEC=$(echo "$DATA" | grep 'llamacpp_prompt_tokens_per_second' | awk '{print $2}')
    fi

    # Pretty numbers
    TS=$(printf "%.1f" "${TOKENS_SEC:-0}")
    PS=$(printf "%.1f" "${PROMPT_SEC:-0}")
    KV=$(printf "%.0f" "$(echo "${KV_CACHE:-0} * 100" | bc -l 2>/dev/null || echo 0)")
    TT=${TOTAL_TOKENS:-0}

    # Determine bar color
    if [ "$(echo "$TS < 10" | bc -l 2>/dev/null)" = "1" ]; then COLOR="#ef4444"; elif [ "$(echo "$TS < 30" | bc -l 2>/dev/null)" = "1" ]; then COLOR="#f59e0b"; else COLOR="#22c55e"; fi

    HTML=$(cat <<EOF
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; padding: 1.5rem; }
  h1 { font-size: 1rem; color: #94a3b8; margin-bottom: 1.5rem; }
  h1 span { color: #22d3ee; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
  .card { background: #1e293b; border-radius: 12px; padding: 1.25rem; border: 1px solid #334155; }
  .card .label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; color: #64748b; }
  .card .value { font-size: 2rem; font-weight: 600; margin-top: 0.25rem; }
  .card .unit { font-size: 0.9rem; color: #94a3b8; }
  .bar-container { margin-top: 0.75rem; height: 4px; background: #334155; border-radius: 2px; }
  .bar { height: 100%; border-radius: 2px; background: $COLOR; width: ${KV}%; transition: width 0.5s; }
  .bar-label { display: flex; justify-content: space-between; font-size: 0.75rem; color: #64748b; margin-top: 0.25rem; }
  .full { grid-column: 1 / -1; }
  .row { display: flex; justify-content: space-between; align-items: center; }
  .model { font-size: 0.8rem; color: #64748b; font-family: monospace; }
  .time { font-size: 0.75rem; color: #475569; }
  .badge { background: #0f172a; color: #38bdf8; padding: 0.15rem 0.5rem; border-radius: 4px; font-size: 0.7rem; font-family: monospace; }
</style></head>
<body>
  <h1>⚡ llama-server <span>live</span></h1>
  <div class="grid">
    <div class="card">
      <div class="label">Generation Speed</div>
      <div class="value">$TS <span class="unit">tok/s</span></div>
      <div class="bar-container"><div class="bar" style="width:${TS}%;background:$COLOR"></div></div>
      <div class="bar-label"><span>0</span><span>100+ tok/s</span></div>
    </div>
    <div class="card">
      <div class="label">Prompt Processing</div>
      <div class="value">$PS <span class="unit">tok/s</span></div>
    </div>
    <div class="card">
      <div class="label">KV Cache Usage</div>
      <div class="value">$KV <span class="unit">%</span></div>
      <div class="bar-container"><div class="bar" style="width:${KV}%"></div></div>
      <div class="bar-label"><span>0%</span><span>100%</span></div>
    </div>
    <div class="card">
      <div class="label">Total Tokens</div>
      <div class="value">$TT <span class="unit">tokens</span></div>
    </div>
    <div class="card full">
      <div class="row">
        <div class="model">$MODEL</div>
        <div class="badge">every ${INTERVAL}s</div>
      </div>
      <div class="time">updated: $(date '+%H:%M:%S')</div>
    </div>
  </div>
</body></html>
EOF
    )
  fi

  # Use Glimpse to display
  echo "$HTML" | glimpse --title "llama-server Metrics" --width 450 --height 380 --stdin 2>/dev/null
  
  sleep $INTERVAL
done
