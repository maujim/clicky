import { open } from '/opt/homebrew/lib/node_modules/glimpseui/src/glimpse.mjs';

const INTERVAL = 3; // seconds

const win = open(`
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
  .bar { height: 100%; border-radius: 2px; transition: width 0.5s; }
  .bar-label { display: flex; justify-content: space-between; font-size: 0.75rem; color: #64748b; margin-top: 0.25rem; }
  .full { grid-column: 1 / -1; }
  .row { display: flex; justify-content: space-between; align-items: center; }
  .model { font-size: 0.8rem; color: #64748b; font-family: monospace; }
  .time { font-size: 0.75rem; color: #475569; }
  .badge { background: #0f172a; color: #38bdf8; padding: 0.15rem 0.5rem; border-radius: 4px; font-size: 0.7rem; font-family: monospace; }
  .idle { color: #ef4444; font-size: 0.9rem; margin-top: 0.5rem; }
  .ok { color: #22c55e; font-size: 0.9rem; margin-top: 0.5rem; }
</style></head>
<body>
  <h1>⚡ llama-server <span id="status">connecting...</span></h1>
  <div class="grid">
    <div class="card">
      <div class="label">Generation Speed</div>
      <div class="value" id="ts">— <span class="unit">tok/s</span></div>
      <div class="bar-container"><div class="bar" id="ts-bar" style="width:0%;background:#64748b"></div></div>
      <div class="bar-label"><span>0</span><span>100+ tok/s</span></div>
    </div>
    <div class="card">
      <div class="label">Prompt Processing</div>
      <div class="value" id="ps">— <span class="unit">tok/s</span></div>
    </div>
    <div class="card">
      <div class="label">KV Cache Usage</div>
      <div class="value" id="kv">— <span class="unit">%</span></div>
      <div class="bar-container"><div class="bar" id="kv-bar" style="width:0%"></div></div>
      <div class="bar-label"><span>0%</span><span>100%</span></div>
    </div>
    <div class="card">
      <div class="label">Total Tokens</div>
      <div class="value" id="tt">— <span class="unit">tokens</span></div>
    </div>
    <div class="card full">
      <div class="row">
        <div class="model" id="model">—</div>
        <div class="badge" id="badge">waiting...</div>
      </div>
      <div class="time" id="updated">—</div>
      <div id="status-msg"></div>
    </div>
  </div>
</body></html>
`, {
  width: 420,
  height: 380,
  title: 'llama-server Metrics',
  floating: true,
});

win.on('ready', () => {
  let counter = 0;

  function update() {
    fetch('http://127.0.0.1:8080/metrics')
      .then(res => res.text())
      .then(text => {
        // Parse prometheus text format
        const getVal = (name) => {
          const match = text.match(new RegExp(name + ' ([0-9.]+)'));
          return match ? parseFloat(match[1]) : null;
        };

        const promptTokens = getVal('llamacpp:prompt_tokens_total');
        const promptSecs = getVal('llamacpp:prompt_seconds_total');
        const genTokens = getVal('llamacpp:tokens_predicted_total');
        const genSecs = getVal('llamacpp:tokens_predicted_seconds_total');
        const kvCache = getVal('llamacpp:kv_cache_usage_ratio');
        const totalTokens = (promptTokens || 0) + (genTokens || 0);

        let genSpeed = 0, promptSpeed = 0;
        if (genSecs && genSecs > 0) genSpeed = genTokens / genSecs;
        if (promptSecs && promptSecs > 0) promptSpeed = promptTokens / promptSecs;

        const ts = genSpeed.toFixed(1);
        const ps = promptSpeed.toFixed(1);
        const kv = kvCache !== null ? (kvCache * 100).toFixed(0) : '0';
        const tt = totalTokens.toFixed(0);

        // Color for gen speed
        let color = '#64748b';
        if (genSpeed > 0) color = genSpeed < 10 ? '#ef4444' : genSpeed < 30 ? '#f59e0b' : '#22c55e';

        const now = new Date().toLocaleTimeString();

        win.send(`
          document.getElementById('status').textContent = 'live';
          document.getElementById('status').style.color = '#22d55e';
          document.getElementById('ts').innerHTML = '${ts} <span class="unit">tok/s</span>';
          document.getElementById('ts-bar').style.width = '${Math.min(genSpeed * 1.5, 100)}%';
          document.getElementById('ts-bar').style.background = '${color}';
          document.getElementById('ps').innerHTML = '${ps} <span class="unit">tok/s</span>';
          document.getElementById('kv').innerHTML = '${kv} <span class="unit">%</span>';
          document.getElementById('kv-bar').style.width = '${kv}%';
          document.getElementById('kv-bar').style.background = '${parseFloat(kv) > 80 ? '#ef4444' : '#38bdf8'}';
          document.getElementById('tt').innerHTML = '${tt} <span class="unit">tokens</span>';
          document.getElementById('badge').textContent = 'every ${INTERVAL}s';
          document.getElementById('updated').textContent = 'updated: ${now}';

          const msgEl = document.getElementById('status-msg');
          if (${genSpeed} > 0 || ${promptSpeed} > 0) {
            msgEl.innerHTML = '<div class="ok">✓ Active — processing requests</div>';
          } else if (${totalTokens} > 0) {
            msgEl.innerHTML = '<div class="ok">✓ Idle — ${tt} tokens served</div>';
          } else {
            msgEl.innerHTML = '<div class="idle">○ Server running, waiting for requests</div>';
          }
        `);
      })
      .catch(() => {
        win.send(`
          document.getElementById('status').textContent = 'disconnected';
          document.getElementById('status').style.color = '#ef4444';
          document.getElementById('badge').textContent = 'retrying...';
          document.getElementById('status-msg').innerHTML = '<div class="idle">✗ Cannot connect to port 8080</div>';
        `);
      });

    counter++;
  }

  update();
  setInterval(update, INTERVAL * 1000);
});
