import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { config } from "./config.js";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class CodexError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "CodexError";
    Object.assign(this, details);
  }
}

// `codex app-server proxy` is intentionally a byte proxy. The app-server
// control socket speaks WebSocket, so this small transport performs the
// standard client handshake/framing without adding a third-party dependency.
class ProxyWebSocket extends EventEmitter {
  constructor(child) {
    super();
    this.child = child;
    this.buffer = Buffer.alloc(0);
    this.handshakeDone = false;
    this.closed = false;
    this.fragments = [];
  }

  connect() {
    return new Promise((resolve, reject) => {
      const fail = (error) => {
        if (this.handshakeDone || this.closed) return;
        this.closed = true;
        reject(error);
      };
      this.once("open", resolve);
      this.once("handshakeError", fail);
      this.child.stdout.on("data", (chunk) => this.receive(Buffer.from(chunk)));
      this.child.on("error", fail);
      this.child.on("exit", (code, signal) => {
        const error = new CodexError(`Codex proxy exited (${code ?? signal})`);
        if (!this.handshakeDone) fail(error);
        this.closed = true;
        this.emit("close", error);
      });
      this.child.stdin.on("error", (error) => this.emit("close", error));

      const key = crypto.randomBytes(16).toString("base64");
      const request = [
        "GET / HTTP/1.1",
        "Host: localhost",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        "\r\n",
      ].join("\r\n");
      this.child.stdin.write(request);
    });
  }

  receive(chunk) {
    if (this.closed) return;
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (!this.handshakeDone) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;
      const header = this.buffer.subarray(0, headerEnd).toString("utf8");
      this.buffer = this.buffer.subarray(headerEnd + 4);
      if (!/^HTTP\/1\.1 101\b/m.test(header)) {
        this.emit("handshakeError", new CodexError(`Control socket rejected WebSocket upgrade: ${header.split("\r\n")[0]}`));
        return;
      }
      this.handshakeDone = true;
      this.emit("open");
    }
    this.readFrames();
  }

  readFrames() {
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      let offset = 2;
      let length = second & 0x7f;
      if (length === 126) {
        if (this.buffer.length < offset + 2) return;
        length = this.buffer.readUInt16BE(offset);
        offset += 2;
      } else if (length === 127) {
        if (this.buffer.length < offset + 8) return;
        const longLength = this.buffer.readBigUInt64BE(offset);
        if (longLength > BigInt(Number.MAX_SAFE_INTEGER)) {
          this.close(new CodexError("Control socket frame is too large"));
          return;
        }
        length = Number(longLength);
        offset += 8;
      }
      const masked = (second & 0x80) !== 0;
      let mask;
      if (masked) {
        if (this.buffer.length < offset + 4) return;
        mask = this.buffer.subarray(offset, offset + 4);
        offset += 4;
      }
      if (this.buffer.length < offset + length) return;
      let payload = this.buffer.subarray(offset, offset + length);
      this.buffer = this.buffer.subarray(offset + length);
      if (masked) payload = Buffer.from(payload.map((value, index) => value ^ mask[index % 4]));

      const opcode = first & 0x0f;
      const final = (first & 0x80) !== 0;
      if (opcode === 0x8) return this.close();
      if (opcode === 0x9) {
        this.sendFrame(0xA, payload);
        continue;
      }
      if (opcode === 0x0) this.fragments.push(payload);
      else if (opcode === 0x1) this.fragments = [payload];
      else continue;
      if (final) {
        this.emit("message", Buffer.concat(this.fragments).toString("utf8"));
        this.fragments = [];
      }
    }
  }

  send(text) {
    this.sendFrame(0x1, Buffer.from(text));
  }

  sendFrame(opcode, payload) {
    if (this.closed || !this.handshakeDone) throw new CodexError("Control socket is not connected");
    const length = payload.length;
    let header;
    if (length < 126) header = Buffer.from([0x80 | opcode, 0x80 | length]);
    else if (length <= 0xffff) {
      header = Buffer.alloc(4);
      header[0] = 0x80 | opcode;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(length, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x80 | opcode;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(length), 2);
    }
    const mask = crypto.randomBytes(4);
    const masked = Buffer.alloc(length);
    for (let index = 0; index < length; index += 1) masked[index] = payload[index] ^ mask[index % 4];
    this.child.stdin.write(Buffer.concat([header, mask, masked]));
  }

  close(error) {
    if (this.closed) return;
    this.closed = true;
    try { this.child.stdin.end(); } catch {}
    if (!this.child.killed) this.child.kill("SIGTERM");
    this.emit("close", error);
  }
}

export class CodexClient extends EventEmitter {
  constructor() {
    super();
    this.socket = null;
    this.child = null;
    this.connecting = null;
    this.nextId = 1;
    this.pending = new Map();
    this.pendingServerRequests = new Map();
    this.activeTurns = new Map();
    this.subscribedThreads = new Set();
    this.subscriptionRequests = new Map();
  }

  async start() {
    await this.ensureConnected();
  }

  async ensureConnected() {
    if (this.socket && !this.socket.closed) return;
    if (this.connecting) return this.connecting;
    this.connecting = this.connectWithRetry().finally(() => { this.connecting = null; });
    return this.connecting;
  }

  async connectWithRetry() {
    let lastError;
    for (let attempt = 0; attempt < 30; attempt += 1) {
      try {
        await this.connectProxy();
        await this.request("initialize", {
          clientInfo: { name: "cloudex-codex-control", title: "Cloudex local controller", version: "0.2.0" },
        });
        this.notify("initialized", {});
        this.emit("ready");
        return;
      } catch (error) {
        lastError = error;
        this.closeProxy();
        await sleep(Math.min(1000, 150 + attempt * 50));
      }
    }
    throw new CodexError(`Unable to connect to managed Codex app-server: ${lastError?.message || "unknown error"}`);
  }

  async connectProxy() {
    this.child = spawn(config.codexBin, ["app-server", "proxy", "--sock", config.controlSocketPath], {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
      windowsHide: true,
    });
    this.child.stderr.on("data", (chunk) => this.emit("log", chunk.toString()));
    const socket = new ProxyWebSocket(this.child);
    socket.on("message", (raw) => this.onMessage(raw));
    socket.on("close", () => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.subscribedThreads.clear();
      this.subscriptionRequests.clear();
      this.pendingServerRequests.clear();
      this.rejectPending(new CodexError("Managed Codex app-server connection closed"));
      this.emit("disconnected");
    });
    await socket.connect();
    this.socket = socket;
  }

  onMessage(raw) {
    let message;
    try { message = JSON.parse(String(raw)); } catch { return; }
    if (message.id !== undefined && message.method) {
      this.pendingServerRequests.set(String(message.id), message);
      this.emit("serverRequest", message);
      return;
    }
    if (message.id !== undefined && this.pending.has(String(message.id))) {
      const pending = this.pending.get(String(message.id));
      this.pending.delete(String(message.id));
      if (message.error) pending.reject(new CodexError(message.error.message || "Codex request failed", { error: message.error }));
      else pending.resolve(message.result);
      return;
    }
    if (message.method) {
      if (message.method === "serverRequest/resolved") {
        const requestId = message.params?.requestId;
        if (requestId !== undefined) this.pendingServerRequests.delete(String(requestId));
      }
      this.trackNotification(message);
      this.emit("notification", message);
    }
  }

  trackNotification(message) {
    const params = message.params || {};
    const threadId = params.threadId || params.thread?.id;
    if (message.method === "thread/started" && threadId) this.subscribedThreads.add(threadId);
    if (message.method === "turn/started" && threadId && params.turn?.id) this.activeTurns.set(threadId, params.turn.id);
    if ([
      "turn/completed",
      "turn/failed",
      "turn/interrupted",
      "turn/cancelled",
    ].includes(message.method) && threadId) this.activeTurns.delete(threadId);
  }

  request(method, params = {}) {
    return this.ensureConnected().then(() => new Promise((resolve, reject) => {
      const id = String(this.nextId++);
      this.pending.set(id, { resolve, reject });
      try { this.socket.send(JSON.stringify({ id, method, params })); }
      catch (error) { this.pending.delete(id); reject(error); }
    }));
  }

  notify(method, params = {}) {
    if (!this.socket || this.socket.closed) throw new CodexError("Managed Codex app-server connection is closed");
    this.socket.send(JSON.stringify({ method, params }));
  }

  respondServerRequest(id, result) {
    if (!this.socket || this.socket.closed) throw new CodexError("Managed Codex app-server connection is closed");
    const key = String(id);
    const request = this.pendingServerRequests.get(key);
    if (!request) throw new CodexError("Codex approval request is no longer pending");
    this.socket.send(JSON.stringify({ id: request.id, result }));
    this.pendingServerRequests.delete(key);
  }

  async subscribeThread(threadId) {
    await this.ensureConnected();
    if (this.subscribedThreads.has(threadId)) return;
    if (this.subscriptionRequests.has(threadId)) return this.subscriptionRequests.get(threadId);
    const request = this.request("thread/resume", { threadId })
      .then((result) => {
        this.subscribedThreads.add(threadId);
        return result;
      })
      .finally(() => this.subscriptionRequests.delete(threadId));
    this.subscriptionRequests.set(threadId, request);
    return request;
  }

  markThreadSubscribed(threadId) {
    this.subscribedThreads.add(threadId);
  }

  rejectPending(error) {
    for (const { reject } of this.pending.values()) reject(error);
    this.pending.clear();
  }

  getActiveTurn(threadId) {
    return this.activeTurns.get(threadId);
  }

  setActiveTurn(threadId, turnId) {
    if (threadId && turnId) this.activeTurns.set(threadId, turnId);
  }

  clearActiveTurn(threadId) {
    this.activeTurns.delete(threadId);
  }

  closeProxy() {
    const socket = this.socket;
    this.socket = null;
    socket?.close();
    if (this.child && !this.child.killed) this.child.kill("SIGTERM");
    this.child = null;
    this.subscribedThreads.clear();
    this.subscriptionRequests.clear();
    this.pendingServerRequests.clear();
  }

  async stop() {
    this.rejectPending(new CodexError("Controller shutting down"));
    this.closeProxy();
  }
}
