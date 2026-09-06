import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const port = 9333;
const proc = spawn(chrome, [
  `--remote-debugging-port=${port}`,
  "--headless=new",
  "--disable-gpu",
  "--no-first-run",
  "--user-data-dir=/tmp/boardlift-chrome-bench"
], { stdio: "pipe" });

async function waitForDevtools() {
  for (let i = 0; i < 40; i++) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (response.ok) return;
    } catch (_) {}
    await sleep(100);
  }
  throw new Error("Chrome DevTools did not start");
}

async function openPage(url) {
  const response = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: "PUT" });
  return response.json();
}

function cdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let id = 0;
  const pending = new Map();
  const ready = new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve);
    ws.addEventListener("error", reject);
  });
  ws.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  });
  return {
    ready,
    send(method, params = {}) {
      const next = ++id;
      ws.send(JSON.stringify({ id: next, method, params }));
      return new Promise(resolve => pending.set(next, resolve));
    },
    close() { ws.close(); }
  };
}

async function evaluate(url, expression, waitMs) {
  const target = await openPage(url);
  const client = cdp(target.webSocketDebuggerUrl);
  await client.ready;
  await client.send("Runtime.enable");
  await client.send("Page.enable");
  await sleep(waitMs);
  const result = await client.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true
  });
  client.close();
  return result.result?.result?.value ?? result;
}

const engineUrl = "http://127.0.0.1:5000/static/perf-bench.html";
const boardUrl = "http://127.0.0.1:5000/board/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb?bench=1&perf=1";

try {
  await waitForDevtools();
  const engine = await evaluate(engineUrl, "document.getElementById('out')?.textContent || document.body.innerText", 4500);
  console.log("ENGINE_BENCH");
  console.log(engine);
  const board = await evaluate(
    boardUrl,
    `new Promise(resolve => {
      const wait = () => {
        const node = document.getElementById("bench-result");
        if (node?.textContent) resolve(node.textContent);
        else setTimeout(wait, 100);
      };
      wait();
    })`,
    1500
  );
  console.log("CAMERA_BENCH");
  console.log(board);
} finally {
  proc.kill("SIGTERM");
}
