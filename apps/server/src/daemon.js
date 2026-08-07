import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";

const STOP_TIMEOUT_MS = 5000;
const STOP_POLL_MS = 100;

export function daemonPaths(stateDirectory) {
  const stateDir = path.resolve(stateDirectory);
  return {
    stateDir,
    pidFile: process.env.CLOUDEX_PID_FILE || path.join(stateDir, "server.pid"),
    stdoutLog: path.join(stateDir, "server.stdout.log"),
    stderrLog: path.join(stateDir, "server.stderr.log"),
  };
}

export async function readPidRecord(pidFile) {
  try {
    const record = JSON.parse(await fsp.readFile(pidFile, "utf8"));
    const pid = Number(record?.pid);
    if (!Number.isInteger(pid) || pid <= 0) return null;
    return { ...record, pid };
  } catch {
    return null;
  }
}

export function isProcessRunning(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

async function waitForProcessExit(pid, timeoutMs = STOP_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs;
  while (isProcessRunning(pid) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, STOP_POLL_MS));
  }
  return !isProcessRunning(pid);
}

async function stopWindowsProcessTree(pid, force = false) {
  const taskkill = spawn("taskkill", ["/PID", String(pid), "/T", ...(force ? ["/F"] : [])], {
    stdio: "ignore",
    windowsHide: true,
  });
  await new Promise((resolve) => {
    taskkill.once("error", resolve);
    taskkill.once("exit", resolve);
  });
}

export async function stopProcess(pid) {
  if (!isProcessRunning(pid)) return { stopped: false, stale: true };

  if (process.platform === "win32") {
    await stopWindowsProcessTree(pid);
    if (await waitForProcessExit(pid)) return { stopped: true, forced: false };
    await stopWindowsProcessTree(pid, true);
    return { stopped: !isProcessRunning(pid), forced: true };
  }

  try {
    process.kill(pid, "SIGTERM");
  } catch (error) {
    if (error?.code !== "ESRCH") throw error;
  }

  if (await waitForProcessExit(pid)) return { stopped: true, forced: false };

  process.kill(pid, "SIGKILL");
  return { stopped: !isProcessRunning(pid), forced: true };
}

export async function startDetachedServer({ packageRoot, cwd, env, paths, metadata = {} }) {
  await fsp.mkdir(paths.stateDir, { recursive: true });
  const stdout = fs.openSync(paths.stdoutLog, "a");
  const stderr = fs.openSync(paths.stderrLog, "a");
  let child;
  try {
    child = spawn(process.execPath, [path.join(packageRoot, "bin", "cloudex.js"), "serve", "--foreground"], {
      cwd,
      env: { ...process.env, ...env },
      detached: true,
      stdio: ["ignore", stdout, stderr],
      windowsHide: true,
    });
  } finally {
    fs.closeSync(stdout);
    fs.closeSync(stderr);
  }

  if (!child.pid) throw new Error("无法启动 Cloudex 后台进程");
  await fsp.writeFile(paths.pidFile, JSON.stringify({
    pid: child.pid,
    startedAt: new Date().toISOString(),
    cwd,
    ...metadata,
  }, null, 2) + "\n", "utf8");
  child.unref();
  return child.pid;
}

export async function removePidFile(pidFile) {
  await fsp.rm(pidFile, { force: true });
}
