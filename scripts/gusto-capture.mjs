#!/usr/bin/env node

import { spawn, execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import process from "node:process";

const DEFAULT_START_URL = "https://app.gusto.com/benefits";
const DEFAULT_PROFILE = "Default";
const DEFAULT_MAX_PAGES = 20;
const DEFAULT_PORT = 9333;
const DEFAULT_WIDTH = 1440;
const DEFAULT_HEIGHT = 1200;
const DEFAULT_HEADLESS = false;
const CHROME_APP =
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const CHROME_USER_DATA = path.join(
  os.homedir(),
  "Library/Application Support/Google/Chrome",
);

const args = parseArgs(process.argv.slice(2));
const timestamp = new Date().toISOString().replaceAll(":", "-");
const workspaceRoot = process.cwd();
const tempRoot = path.join(workspaceRoot, ".tmp", `gusto-profile-${timestamp}`);
const outputRoot = path.join(workspaceRoot, "captures", `gusto-${timestamp}`);
const manifestPath = path.join(outputRoot, "manifest.json");

let chromeProcess = null;
let client = null;

process.on("SIGINT", async () => {
  await cleanup();
  process.exit(130);
});

process.on("SIGTERM", async () => {
  await cleanup();
  process.exit(143);
});

main().catch(async (error) => {
  console.error(`\nCapture failed: ${error.message}`);
  await cleanup({ keepProfileCopy: true });
  process.exit(1);
});

async function main() {
  ensureChromeExists();
  await fs.mkdir(outputRoot, { recursive: true });

  console.log(`Copying Chrome profile "${args.profile}" into a disposable workspace...`);
  copyChromeProfile(args.profile, tempRoot);

  console.log(`Launching disposable Chrome on port ${args.port}...`);
  chromeProcess = launchChrome(tempRoot, args.profile, args.port);
  const browserWsUrl = await waitForBrowserWsUrl(args.port);
  client = await CDPClient.connect(browserWsUrl);

  const { targetId } = await client.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await client.send("Target.attachToTarget", {
    targetId,
    flatten: true,
  });

  await client.send("Page.enable", {}, sessionId);
  await client.send("Runtime.enable", {}, sessionId);
  await client.send("Network.enable", {}, sessionId);
  await client.send(
    "Emulation.setDeviceMetricsOverride",
    {
      mobile: false,
      width: args.width,
      height: args.height,
      deviceScaleFactor: 1,
      screenWidth: args.width,
      screenHeight: args.height,
    },
    sessionId,
  );

  const queue = [args.startUrl];
  const visited = new Set();
  const captures = [];

  while (queue.length > 0 && captures.length < args.maxPages) {
    const url = queue.shift();
    const normalized = normalizeUrl(url);

    if (!normalized || visited.has(normalized)) {
      continue;
    }

    visited.add(normalized);
    console.log(`\nNavigating to ${normalized}`);
    await navigateTo(client, sessionId, normalized);
    await waitForChallengeResolution(client, sessionId);

    const currentUrl = normalizeUrl(await evaluate(client, sessionId, "location.href"));
    if (!currentUrl) {
      throw new Error(`Unable to read current URL after navigating to ${normalized}`);
    }

    if (currentUrl.includes("/login") || currentUrl.includes("accounts.google.com")) {
      throw new Error(
        "The copied Chrome profile is not authenticated in Gusto. The saved session may need a fresh Chrome restart with remote debugging enabled.",
      );
    }

    await autoScroll(client, sessionId);
    await delay(1200);

    const title = sanitizeTitle(await evaluate(client, sessionId, "document.title"));
    const screenshotPath = path.join(
      outputRoot,
      `${String(captures.length + 1).padStart(2, "0")}-${slugify(currentUrl)}.png`,
    );
    await captureFullPageScreenshot(client, sessionId, screenshotPath);
    console.log(`Saved ${path.relative(workspaceRoot, screenshotPath)}`);

    captures.push({
      index: captures.length + 1,
      title,
      url: currentUrl,
      file: path.relative(workspaceRoot, screenshotPath),
    });

    const discoveredLinks = await discoverNavigationLinks(client, sessionId);
    for (const discoveredUrl of discoveredLinks) {
      const candidate = normalizeUrl(discoveredUrl);
      if (
        candidate &&
        !visited.has(candidate) &&
        !queue.includes(candidate) &&
        isSafeGustoPage(candidate)
      ) {
        queue.push(candidate);
      }
    }
  }

  await fs.writeFile(manifestPath, JSON.stringify({ capturedAt: new Date().toISOString(), captures }, null, 2));
  console.log(`\nCaptured ${captures.length} page(s). Manifest: ${path.relative(workspaceRoot, manifestPath)}`);

  await client.send("Target.closeTarget", { targetId });
  await cleanup();
}

function parseArgs(argv) {
  const values = {
    profile: DEFAULT_PROFILE,
    startUrl: DEFAULT_START_URL,
    maxPages: DEFAULT_MAX_PAGES,
    port: DEFAULT_PORT,
    width: DEFAULT_WIDTH,
    height: DEFAULT_HEIGHT,
    headless: DEFAULT_HEADLESS,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];

    if (arg === "--profile" && next) {
      values.profile = next;
      i += 1;
    } else if (arg === "--start-url" && next) {
      values.startUrl = next;
      i += 1;
    } else if (arg === "--max-pages" && next) {
      values.maxPages = Number.parseInt(next, 10);
      i += 1;
    } else if (arg === "--port" && next) {
      values.port = Number.parseInt(next, 10);
      i += 1;
    } else if (arg === "--width" && next) {
      values.width = Number.parseInt(next, 10);
      i += 1;
    } else if (arg === "--height" && next) {
      values.height = Number.parseInt(next, 10);
      i += 1;
    } else if (arg === "--headless") {
      values.headless = true;
    }
  }

  return values;
}

function ensureChromeExists() {
  if (!path.isAbsolute(CHROME_APP)) {
    throw new Error("Chrome app path is invalid.");
  }
}

function copyChromeProfile(profileName, destinationRoot) {
  const sourceProfileDir = path.join(CHROME_USER_DATA, profileName);
  const sourceLocalState = path.join(CHROME_USER_DATA, "Local State");
  const destinationProfileDir = path.join(destinationRoot, profileName);

  execFileSync("mkdir", ["-p", destinationRoot], { stdio: "ignore" });
  execFileSync("mkdir", ["-p", destinationProfileDir], { stdio: "ignore" });
  copyPathIfExists(sourceLocalState, destinationRoot);

  const requiredProfilePaths = [
    "Preferences",
    "Secure Preferences",
    "Network",
    "Cookies",
    "Cookies-journal",
    "Local Storage",
    "Session Storage",
    "IndexedDB/https_app.gusto.com_0.indexeddb.leveldb",
    "IndexedDB/https_app.gusto.com_0.indexeddb.blob",
  ];

  for (const relativePath of requiredProfilePaths) {
    copyPathIfExists(
      path.join(sourceProfileDir, relativePath),
      destinationProfileDir,
    );
  }
}

function copyPathIfExists(sourcePath, destinationDir) {
  if (!existsSync(sourcePath)) {
    return;
  }

  execFileSync(
    "rsync",
    ["-a", sourcePath, destinationDir],
    { stdio: "inherit" },
  );
}

function launchChrome(userDataDir, profileName, port) {
  const chromeArgs = [
    `--user-data-dir=${userDataDir}`,
    `--profile-directory=${profileName}`,
    `--remote-debugging-port=${port}`,
    "--disable-dev-shm-usage",
    "--hide-crash-restore-bubble",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-blink-features=AutomationControlled",
    `--window-size=${args.width},${args.height}`,
    "about:blank",
  ];

  if (args.headless) {
    chromeArgs.splice(3, 0, "--headless=new", "--disable-gpu");
  }

  return spawn(CHROME_APP, chromeArgs, {
    stdio: "ignore",
  });
}

async function waitForBrowserWsUrl(port, timeoutMs = 30000) {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (response.ok) {
        const payload = await response.json();
        if (payload.webSocketDebuggerUrl) {
          return payload.webSocketDebuggerUrl;
        }
      }
    } catch {
      // Chrome is still starting.
    }

    await delay(250);
  }

  throw new Error("Chrome did not expose a DevTools websocket in time.");
}

async function navigateTo(cdp, sessionId, url) {
  const loadEvent = cdp.waitForEvent(
    (message) => message.sessionId === sessionId && message.method === "Page.loadEventFired",
    30000,
  );
  await cdp.send("Page.navigate", { url }, sessionId);
  await loadEvent.catch(() => null);
  await waitForDocumentReady(cdp, sessionId);
  await delay(1000);
}

async function waitForDocumentReady(cdp, sessionId, timeoutMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const readyState = await evaluate(cdp, sessionId, "document.readyState");
    if (readyState === "complete" || readyState === "interactive") {
      return;
    }
    await delay(200);
  }
  throw new Error("Document never reached an interactive state.");
}

async function waitForChallengeResolution(cdp, sessionId, timeoutMs = 45000) {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    const title = String(await evaluate(cdp, sessionId, "document.title"));
    const bodyText = String(
      await evaluate(cdp, sessionId, "document.body ? document.body.innerText.slice(0, 5000) : ''"),
    ).toLowerCase();

    const blocked =
      title.includes("Just a moment") ||
      bodyText.includes("checking your browser") ||
      bodyText.includes("verify you are human");

    if (!blocked) {
      return;
    }

    await delay(1000);
  }

  throw new Error("Gusto stayed on a browser verification page for too long.");
}

async function evaluate(cdp, sessionId, expression) {
  const { result, exceptionDetails } = await cdp.send(
    "Runtime.evaluate",
    {
      expression,
      awaitPromise: true,
      returnByValue: true,
    },
    sessionId,
  );

  if (exceptionDetails) {
    throw new Error(exceptionDetails.text || "Runtime evaluation failed.");
  }

  return result.value;
}

async function autoScroll(cdp, sessionId) {
  await evaluate(
    cdp,
    sessionId,
    `(() => new Promise((resolve) => {
      let currentY = 0;
      const step = 900;
      const timer = setInterval(() => {
        window.scrollTo(0, currentY);
        currentY += step;
        if (currentY >= document.body.scrollHeight) {
          clearInterval(timer);
          window.scrollTo(0, 0);
          resolve(true);
        }
      }, 150);
    }))()`,
  );
}

async function discoverNavigationLinks(cdp, sessionId) {
  const rawLinks = await evaluate(
    cdp,
    sessionId,
    `(() => {
      const links = [...document.querySelectorAll('a[href]')];
      return links
        .map((anchor) => {
          const href = anchor.href;
          const rect = anchor.getBoundingClientRect();
          const visible = rect.width > 0 && rect.height > 0;
          const text = (anchor.innerText || anchor.getAttribute('aria-label') || '').trim();
          const inNavigation = Boolean(
            anchor.closest('nav, aside, header, [role="navigation"], [data-testid*="nav"], [class*="nav"], [class*="sidebar"], [class*="menu"]')
          );
          return { href, visible, text, inNavigation };
        })
        .filter((link) => link.visible && link.inNavigation && link.href);
    })()`,
  );

  return rawLinks
    .map((link) => link.href)
    .filter(Boolean);
}

async function captureFullPageScreenshot(cdp, sessionId, targetPath) {
  const layout = await cdp.send("Page.getLayoutMetrics", {}, sessionId);
  const width = Math.max(1280, Math.ceil(layout.contentSize.width));
  const height = Math.max(900, Math.ceil(layout.contentSize.height));
  const clip = {
    x: 0,
    y: 0,
    width,
    height,
    scale: 1,
  };

  const { data } = await cdp.send(
    "Page.captureScreenshot",
    {
      format: "png",
      fromSurface: true,
      captureBeyondViewport: true,
      clip,
    },
    sessionId,
  );

  await fs.writeFile(targetPath, Buffer.from(data, "base64"));
}

function normalizeUrl(input) {
  try {
    const url = new URL(input);
    if (url.hostname !== "app.gusto.com") {
      return null;
    }

    url.hash = "";

    if (url.searchParams.has("from")) {
      url.searchParams.delete("from");
    }

    return url.toString();
  } catch {
    return null;
  }
}

function isSafeGustoPage(urlString) {
  const url = new URL(urlString);
  const blocked = /(logout|sign[_-]?out|delete|destroy|remove|approve|submit|offboard|terminate|run-payroll|invite|\/new(?:[/?]|$)|\/edit(?:[/?]|$)|\/create(?:[/?]|$))/i;
  return !blocked.test(url.pathname);
}

function slugify(urlString) {
  const url = new URL(urlString);
  const suffix = url.pathname === "/" ? "root" : url.pathname.replace(/^\/+/, "").replaceAll("/", "_");
  const query = [...url.searchParams.entries()]
    .map(([key, value]) => `${key}-${value}`)
    .join("_");
  return `${suffix}${query ? `__${query}` : ""}`.replace(/[^\w.-]+/g, "_");
}

function sanitizeTitle(title) {
  return String(title || "").replace(/\s+/g, " ").trim();
}

function delay(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

async function cleanup(options = {}) {
  if (client) {
    client.close();
    client = null;
  }

  if (chromeProcess && !chromeProcess.killed) {
    chromeProcess.kill("SIGTERM");
    chromeProcess = null;
  }

  if (!options.keepProfileCopy) {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
}

class CDPClient {
  constructor(socket) {
    this.socket = socket;
    this.pending = new Map();
    this.listeners = new Set();
    this.nextId = 1;

    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      if (typeof message.id === "number" && this.pending.has(message.id)) {
        const pending = this.pending.get(message.id);
        this.pending.delete(message.id);

        if (message.error) {
          pending.reject(new Error(message.error.message));
        } else {
          pending.resolve(message.result || {});
        }
        return;
      }

      for (const listener of this.listeners) {
        listener(message);
      }
    });
  }

  static async connect(wsUrl) {
    const socket = new WebSocket(wsUrl);

    await new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener(
        "error",
        (event) => reject(new Error(event.message || "WebSocket connection failed.")),
        { once: true },
      );
    });

    return new CDPClient(socket);
  }

  close() {
    this.socket.close();
  }

  send(method, params = {}, sessionId) {
    const id = this.nextId;
    this.nextId += 1;

    const message = { id, method, params };
    if (sessionId) {
      message.sessionId = sessionId;
    }

    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify(message));
    });
  }

  waitForEvent(predicate, timeoutMs = 10000) {
    return new Promise((resolve, reject) => {
      const onMessage = (message) => {
        if (predicate(message)) {
          cleanupListener();
          resolve(message);
        }
      };

      const timer = setTimeout(() => {
        cleanupListener();
        reject(new Error("Timed out waiting for a Chrome event."));
      }, timeoutMs);

      const cleanupListener = () => {
        clearTimeout(timer);
        this.listeners.delete(onMessage);
      };

      this.listeners.add(onMessage);
    });
  }
}
