// 无头 Chrome 冒烟：真前端 + 真桥接 + 冻结库。
// 用法：node smoke.mjs <bridgeserve> <冻结目录> <index.html> <输出目录>
// 页面里的 window.webkit.messageHandlers.invoke 接到本地 HTTP，再转给 bridgeserve；设置类命令在这里用内存存，
// 不碰用户的 UserDefaults。逐个页签点开，任何页面错误或桥接错误都算失败。
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { createInterface } from "node:readline";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [serveBin, frozen, indexHtml, outDir] = process.argv.slice(2);
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── 桥接进程 ───────────────────────────────────────────────
const serve = spawn(serveBin, [frozen], { stdio: ["pipe", "pipe", "inherit"] });
const waiting = [];
createInterface({ input: serve.stdout }).on("line", (line) => waiting.shift()?.(line));
const native = (message) =>
  new Promise((resolve) => {
    waiting.push(resolve);
    serve.stdin.write(JSON.stringify(message) + "\n");
  });

const settings = new Map();
const failures = [];
const seen = new Map();
async function invoke(message) {
  const { cmd, args = {} } = message;
  seen.set(cmd, (seen.get(cmd) ?? 0) + 1);
  if (cmd === "get_setting") return JSON.stringify({ result: settings.get(args.key) ?? null });
  if (cmd === "set_setting") {
    settings.set(args.key, args.value);
    return JSON.stringify({ result: null });
  }
  if (cmd === "get_settings") return JSON.stringify({ result: {} });
  const reply = await native(message);
  if (JSON.parse(reply).error) failures.push(`bridge ${cmd}: ${reply.slice(0, 200)}`);
  return reply;
}

// ── 页面与桥接的 HTTP ──────────────────────────────────────
const html = readFileSync(indexHtml);
const server = createServer((req, res) => {
  if (req.method === "POST" && req.url === "/invoke") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", async () => {
      res.setHeader("Content-Type", "application/json");
      res.end(await invoke(JSON.parse(body)));
    });
    return;
  }
  res.setHeader("Content-Type", "text/html");
  res.end(html);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

// ── Chrome ────────────────────────────────────────────────
const profile = mkdtempSync(join(tmpdir(), "ccusage-smoke-"));
const chrome = spawn(CHROME, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
  `--user-data-dir=${profile}`, "--remote-debugging-port=0", "--window-size=1280,900", "about:blank"],
  { stdio: ["ignore", "ignore", "pipe"] });
const wsUrl = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("Chrome 没有起来")), 20000);
  createInterface({ input: chrome.stderr }).on("line", (line) => {
    const hit = line.match(/DevTools listening on (ws:\/\/\S+)/);
    if (hit) { clearTimeout(timer); resolve(hit[1]); }
  });
});

const browser = new WebSocket(wsUrl);
await new Promise((r) => (browser.onopen = r));
let nextId = 1;
const pending = new Map();
const handlers = new Map();
browser.onmessage = (event) => {
  const m = JSON.parse(event.data);
  if (m.id && pending.has(m.id)) {
    const { resolve, reject } = pending.get(m.id);
    pending.delete(m.id);
    m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
  } else if (m.method) {
    handlers.get(m.method)?.(m.params);
  }
};
const send = (method, params = {}, sessionId) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    browser.send(JSON.stringify({ id, method, params, sessionId }));
  });

const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
const page = (method, params) => send(method, params, sessionId);
await page("Page.enable");
await page("Runtime.enable");
await page("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
handlers.set("Runtime.exceptionThrown", (p) => failures.push(`exception: ${p.exceptionDetails?.exception?.description ?? p.exceptionDetails?.text}`));
handlers.set("Runtime.consoleAPICalled", (p) => {
  if (p.type === "error") failures.push(`console.error: ${p.args.map((a) => a.value ?? a.description).join(" ").slice(0, 300)}`);
});
await page("Page.addScriptToEvaluateOnNewDocument", {
  source: `
    window.webkit = { messageHandlers: {
      invoke: { postMessage: (m) => fetch("/invoke", { method: "POST", body: JSON.stringify(m) })
        .then((r) => r.json()).then((x) => { if (x.error) throw new Error(x.error); return x.result; }) },
      embedError: { postMessage: (m) => console.error("embedError " + m) },
    } };`,
});

const evaluate = async (expression) => {
  const r = await page("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.text);
  return r.result.value;
};
const shot = async (name) => {
  const { data } = await page("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(outDir, `${name}.png`), Buffer.from(data, "base64"));
};
const waitFor = async (expression, label, ms = 15000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await evaluate(expression)) return;
    await sleep(150);
  }
  failures.push(`等不到：${label}`);
};
/** 按元素中心坐标点（Radix 认 pointer 事件，el.click() 不一定够）。 */
const clickText = async (selector, text) => {
  const box = await evaluate(`(() => {
    const el = [...document.querySelectorAll(${JSON.stringify(selector)})]
      .find((e) => e.textContent.trim().startsWith(${JSON.stringify(text)}));
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  })()`);
  if (!box) { failures.push(`找不到 ${selector}「${text}」`); return false; }
  for (const type of ["mousePressed", "mouseReleased"]) {
    await page("Input.dispatchMouseEvent", { type, ...box, button: "left", clickCount: 1 });
  }
  return true;
};

await page("Page.navigate", { url: `http://127.0.0.1:${port}/` });
await waitFor(`document.querySelector("#root")?.children.length > 0`, "根节点渲染");
await sleep(1500);

// 冻结数据到 2026-11-05 为止，默认时间范围可能是空的：切到最长的预设，让表格有行。
const report = {};
report.buttons = await evaluate(`[...document.querySelectorAll("button,[role=tab]")].map((b) => b.textContent.trim()).filter(Boolean).slice(0, 40)`);
await shot("01-initial");
for (const [name, text] of [["02-logs", "Request Logs"], ["03-providers", "Provider"], ["04-models", "Model"]]) {
  await clickText('[role="tab"]', text);
  await sleep(1200);
  await shot(name);
  report[name] = {
    rootHasContent: await evaluate(`document.querySelector("#root").innerText.length`),
    rows: await evaluate(`document.querySelectorAll("tbody tr").length`),
  };
  if (!report[name].rootHasContent) failures.push(`${text} 页签白屏`);
}

// 请求详情抽屉（get_request_detail）：回到请求日志，点第一行的时间。
await clickText('[role="tab"]', "Request Logs");
await sleep(800);
const opened = await clickText("tbody tr button", "");
if (opened) {
  await waitFor(`!!document.querySelector('[role="dialog"]')`, "请求详情抽屉");
  await sleep(800);
  await shot("05-detail");
  report.detailText = await evaluate(`document.querySelector('[role="dialog"]')?.innerText.length ?? 0`);
  if (!report.detailText) failures.push("请求详情是空的");
}

report.invoked = Object.fromEntries(seen);
report.failures = failures;
writeFileSync(join(outDir, "report.json"), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));

browser.close();
chrome.kill();
serve.kill();
server.close();
await sleep(300);
rmSync(profile, { recursive: true, force: true });
process.exit(failures.length ? 1 : 0);
