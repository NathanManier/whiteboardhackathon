import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";

const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const baseUrl = process.env.BOARDLIFT_QA_URL || "http://127.0.0.1:5000";
const debugPort = Number(process.env.BOARDLIFT_QA_DEBUG_PORT || 9334);
const library = await fetch(`${baseUrl}/api/library`).then(response => response.json());
const guidedBoardId = (library.folders || [])
  .find(folder => folder?.study_guide && folder?.workspace_board_id)
  ?.workspace_board_id;
const boardId = guidedBoardId || (Array.isArray(library.boards)
  ? library.boards.find(board => board?.status === "ready")?.id
  : Object.keys(library.boards || {})[0]);
if (!boardId) throw new Error("Notation QA needs at least one board.");

const browser = spawn(chrome, [
  `--remote-debugging-port=${debugPort}`,
  "--headless=new",
  "--disable-gpu",
  "--hide-scrollbars",
  "--no-first-run",
  "--user-data-dir=/tmp/boardlift-notation-qa"
], { stdio: "ignore" });

async function waitForDevtools() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) return;
    } catch (_) { /* Chrome is still starting. */ }
    await sleep(100);
  }
  throw new Error("Chrome DevTools did not start.");
}

async function openPage(url) {
  const response = await fetch(
    `http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(url)}`,
    { method: "PUT" }
  );
  return response.json();
}

function connect(wsUrl) {
  const socket = new WebSocket(wsUrl);
  let nextId = 0;
  const pending = new Map();
  const ready = new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve);
    socket.addEventListener("error", reject);
  });
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    pending.get(message.id)(message);
    pending.delete(message.id);
  });
  return {
    ready,
    send(method, params = {}) {
      const id = ++nextId;
      socket.send(JSON.stringify({ id, method, params }));
      return new Promise(resolve => pending.set(id, resolve));
    },
    close() {
      socket.close();
    }
  };
}

async function evaluate(client, expression) {
  const message = await client.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true
  });
  if (message.result?.exceptionDetails) {
    const details = message.result.exceptionDetails;
    throw new Error(
      details.exception?.description ||
      details.text ||
      "Browser evaluation failed."
    );
  }
  return message.result?.result?.value;
}

async function screenshot(client, path) {
  const message = await client.send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false
  });
  await writeFile(path, Buffer.from(message.result.data, "base64"));
}

const actualUiPaths = `(() => {
  const body = document.querySelector("#study-body");
  const results = [];
  document.querySelectorAll(".study-note-item").forEach((button, index) => {
    button.click();
    const text = body?.innerText || "";
    results.push({
      context: button.innerText.trim() || \`saved interaction \${index + 1}\`,
      empty: !text.trim(),
      unavailable: text.includes("Notation unavailable")
    });
  });
  const guide = document.querySelector("#study-guide-button");
  if (guide && /study guide/i.test(guide.textContent || "")) {
    guide.click();
    const text = body?.innerText || "";
    results.push({
      context: "actual Study Guide",
      empty: !text.trim(),
      unavailable: text.includes("Notation unavailable")
    });
  }
  return results;
})()`;

const fixture = String.raw`
(() => {
  const sheet = document.querySelector("#study-sheet");
  const title = document.querySelector("#study-title");
  const body = document.querySelector("#study-body");
  if (!sheet || !title || !body || typeof renderStudyMarkdown !== "function" || !katex) {
    throw new Error("Study UI or notation renderer did not load.");
  }
  sheet.hidden = false;
  sheet.classList.add("is-resized");
  sheet.style.width = "min(620px, calc(100vw - 24px))";
  sheet.style.height = "min(900px, calc(100vh - 40px))";
  title.textContent = "Notation fallback QA";
  body.replaceChildren();

  const normal = document.createElement("section");
  normal.dataset.qaContext = "normal-math";
  normal.append(renderStudyMarkdown("Existing math: $E=mc^2$ and $\\frac{a}{b}$."));
  body.append(normal);

  const original = katex.renderToString;
  katex.renderToString = () => { throw new Error("forced renderer failure"); };
  try {
    [
      ["Practice Problems", "What is the charge of $SO_4^{2-}$?\n\nBalance $2H_2 + O_2 \\rightarrow 2H_2O$."],
      ["Check My Work", "Your answer should contain $SO_4^{2-}$."],
      ["AI Explain", "The sulfate ion is $SO_4^{2-}$. The pH uses $pH=-\\log[H^+]$."],
      ["Study Guide", "Equilibrium: $N_2 + 3H_2 \\rightleftharpoons 2NH_3$.\n\nMalformed stays readable: $\\frac$."]
    ].forEach(([heading, source]) => {
      const section = document.createElement("section");
      section.dataset.qaContext = heading;
      const h3 = document.createElement("h3");
      h3.textContent = heading;
      section.append(h3, renderStudyMarkdown(source));
      body.append(section);
    });

    const canvasFixture = document.createElement("div");
    canvasFixture.id = "notation-canvas-qa";
    canvasFixture.className = "canvas-html-text canvas-rich-text";
    canvasFixture.style.cssText = [
      "position:absolute", "left:24px", "top:112px", "width:min(560px,calc(100vw - 48px))",
      "padding:14px", "z-index:25", "font-size:24px", "color:#183153",
      "background:rgba(255,255,255,.96)", "border:2px solid #6aa8e6", "border-radius:12px"
    ].join(";");
    canvasFixture.append(renderStudyMarkdown(
      "**Canvas Practice Problem**\n\nWhat is the charge of $SO_4^{2-}$?"
    ));
    document.querySelector("#primary-frame")?.append(canvasFixture);
  } finally {
    katex.renderToString = original;
  }

  const text = document.body.innerText;
  return {
    unavailable: text.includes("Notation unavailable"),
    fallbackCount: document.querySelectorAll(".study-notation-fallback").length,
    normalKatexCount: normal.querySelectorAll(".katex").length,
    contexts: [...body.querySelectorAll("[data-qa-context]")].map(node => node.dataset.qaContext),
    bodyText: body.innerText,
    canvasText: document.querySelector("#notation-canvas-qa")?.innerText || "",
    horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth,
    sourcePreserved: readableNotationFallback("SO_4^{2-}") === "SO₄²⁻"
  };
})()
`;

try {
  await waitForDevtools();
  const target = await openPage(`${baseUrl}/board/${boardId}`);
  const client = connect(target.webSocketDebuggerUrl);
  await client.ready;
  await client.send("Runtime.enable");
  await client.send("Page.enable");
  await client.send("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 1000,
    deviceScaleFactor: 1,
    mobile: false
  });
  await sleep(1800);
  if (guidedBoardId) {
    await evaluate(client, `new Promise(resolve => {
      const started = Date.now();
      const wait = () => {
        if (document.querySelector(".study-note-item") || Date.now() - started > 35000) resolve();
        else setTimeout(wait, 100);
      };
      wait();
    })`);
  }
  const actualResults = await evaluate(client, actualUiPaths);
  if (!actualResults.length ||
      actualResults.some(result => result.empty || result.unavailable)) {
    throw new Error(`Actual study UI path failed: ${JSON.stringify(actualResults)}`);
  }
  const result = await evaluate(client, fixture);
  if (result.unavailable || result.fallbackCount < 7 || result.normalKatexCount < 2 ||
      !result.sourcePreserved || !result.canvasText.includes("SO₄²⁻")) {
    throw new Error(`Notation QA failed: ${JSON.stringify(result)}`);
  }
  await screenshot(client, "/tmp/notation-qa-desktop.png");
  await client.send("Emulation.setDeviceMetricsOverride", {
    width: 390,
    height: 844,
    deviceScaleFactor: 2,
    mobile: true
  });
  await sleep(250);
  const mobile = await evaluate(client, `({
    horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth,
    sheetWidth: document.querySelector("#study-sheet")?.getBoundingClientRect().width || 0,
    viewportWidth: window.innerWidth
  })`);
  if (mobile.horizontalOverflow || mobile.sheetWidth > mobile.viewportWidth) {
    throw new Error(`Mobile notation layout overflowed: ${JSON.stringify(mobile)}`);
  }
  await screenshot(client, "/tmp/notation-qa-mobile.png");
  console.log(JSON.stringify({ ...result, actualResults, mobile }, null, 2));
  client.close();
} finally {
  browser.kill("SIGTERM");
}
