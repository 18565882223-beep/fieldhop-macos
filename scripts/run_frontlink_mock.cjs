#!/usr/bin/env node

const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");

function loadPlaywright() {
  try {
    return require("playwright");
  } catch (_) {
    const bundledPath = path.join(
      os.homedir(),
      ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"
    );
    try {
      return require(bundledPath);
    } catch (error) {
      throw new Error(`未找到 Playwright，请先安装 playwright：${error.message}`);
    }
  }
}

function contentType(filePath) {
  switch (path.extname(filePath)) {
  case ".html": return "text/html; charset=utf-8";
  case ".js": return "text/javascript; charset=utf-8";
  case ".css": return "text/css; charset=utf-8";
  case ".json": return "application/json; charset=utf-8";
  default: return "application/octet-stream";
  }
}

function createStaticServer(rootDirectory) {
  return http.createServer((request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, "http://127.0.0.1").pathname);
      if (pathname === "/favicon.ico") {
        response.writeHead(204).end();
        return;
      }
      const filePath = path.resolve(rootDirectory, pathname.replace(/^\/+/, ""));
      const allowedPrefix = `${rootDirectory}${path.sep}`;
      if (filePath !== rootDirectory && !filePath.startsWith(allowedPrefix)) {
        response.writeHead(403).end("Forbidden");
        return;
      }

      const stat = fs.statSync(filePath);
      if (!stat.isFile()) {
        response.writeHead(404).end("Not Found");
        return;
      }

      response.writeHead(200, { "Content-Type": contentType(filePath), "Cache-Control": "no-store" });
      fs.createReadStream(filePath).pipe(response);
    } catch (_) {
      response.writeHead(404).end("Not Found");
    }
  });
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return server.address().port;
}

async function closeServer(server) {
  await new Promise((resolve) => server.close(resolve));
}

async function run() {
  const projectRoot = path.resolve(__dirname, "..");
  const chromePath = process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  if (!fs.existsSync(chromePath)) throw new Error(`未找到 Chrome：${chromePath}`);

  const { chromium } = loadPlaywright();
  const server = createStaticServer(projectRoot);
  const port = await listen(server);
  let browser;

  try {
    browser = await chromium.launch({ headless: true, executablePath: chromePath });
    const page = await browser.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });

    const url = `http://127.0.0.1:${port}/ChromeExtension/test-pages/frontlink-mock-suite.html`;
    await page.goto(url, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(
      () => ["passed", "failed"].includes(document.documentElement.dataset.smsCodeMockStatus),
      { timeout: 30_000 }
    );

    const outcome = await page.evaluate(() => ({
      status: document.documentElement.dataset.smsCodeMockStatus,
      summary: document.getElementById("status")?.textContent || "",
      report: document.getElementById("report")?.textContent || ""
    }));

    if (outcome.status !== "passed" || errors.length > 0) {
      throw new Error([outcome.summary, outcome.report, ...errors].filter(Boolean).join("\n"));
    }

    process.stdout.write(`${outcome.summary}\n${outcome.report}\n`);
  } finally {
    if (browser) await browser.close();
    await closeServer(server);
  }
}

run().catch((error) => {
  process.stderr.write(`前半链路无头 mock 失败：${error.stack || error.message}\n`);
  process.exitCode = 1;
});
