import { spawn, execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { BrowserError } from '../contract.js';
import { promisify } from 'node:util';

async function windowsRegistration(host) {
  for (const hive of ['HKCU', 'HKLM']) for (const vendor of ['Google\\Chrome', 'Chromium', 'Microsoft\\Edge']) {
    try {
      const { stdout } = await promisify(execFile)('reg.exe', ['query', `${hive}\\Software\\${vendor}\\NativeMessagingHosts\\${host}`, '/ve'], { windowsHide: true, timeout: 3000 });
      const match = /REG_SZ\s+(.+)/.exec(stdout);
      if (match) return match[1].trim();
    } catch {}
  }
  return null;
}

export class NativeMessaging {
  constructor({ directories = [], allowed = [], platform = process.platform, registration = windowsRegistration } = {}) { this.directories = directories; this.allowed = new Set(allowed); this.connections = new Map(); this.platform = platform; this.registration = registration; }
  authorize(extension, host, on) {
    if (!/^[a-p]{32}$/.test(extension) || !/^[a-z0-9_]+(?:\.[a-z0-9_]+)*$/.test(host)) throw new BrowserError('INVALID_NATIVE_HOST', 'Invalid extension or host name');
    const key = `${extension}:${host}`;
    if (on) this.allowed.add(key);
    else {
      this.allowed.delete(key);
      for (const connection of this.connections.values()) if (connection.extension === extension && connection.host === host && !connection.closed) this.disconnect(extension, connection.id);
    }
    return { authorized: on === true };
  }
  async connect(extension, host) {
    if (!/^[a-p]{32}$/.test(extension) || !/^[a-z0-9_]+(?:\.[a-z0-9_]+)*$/.test(host)) throw new BrowserError('INVALID_NATIVE_HOST', 'Invalid extension or host name');
    if (!this.allowed.has(`${extension}:${host}`)) throw new BrowserError('NATIVE_PERMISSION_REQUIRED', 'Approve this native host for the extension first');
    if ([...this.connections.values()].filter(connection => !connection.closed).length >= 16) throw new BrowserError('NATIVE_LIMIT', 'At most 16 native hosts can be connected');
    let manifest;
    if (this.platform === 'win32') { const file = await this.registration(host); if (file) manifest = JSON.parse(await readFile(file, 'utf8')); }
    for (const directory of this.directories) {
      if (manifest) break;
      try { manifest = JSON.parse(await readFile(path.join(directory, `${host}.json`), 'utf8')); break; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    const origin = `chrome-extension://${extension}/`;
    if (!manifest || manifest.name !== host || manifest.type !== 'stdio' || !manifest.allowed_origins?.includes(origin) || !path.isAbsolute(manifest.path)) throw new BrowserError('NATIVE_HOST_REFUSED', 'Native host registration does not permit this extension');
    const process = spawn(manifest.path, [origin], { cwd: path.dirname(manifest.path), stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
    const id = randomUUID();
    const connection = { id, extension, host, process, messages: [], buffer: Buffer.alloc(0), error: null, closed: false };
    this.connections.set(id, connection);
    process.on('error', () => { connection.error = 'Native host could not start'; connection.closed = true; });
    process.on('exit', () => { connection.closed = true; });
    process.stdin.on('error', () => { connection.error = 'Native host stopped reading'; connection.closed = true; process.kill(); });
    process.stdin.on('drain', () => { connection.blocked = false; });
    process.stdout.on('data', bytes => {
      connection.buffer = Buffer.concat([connection.buffer, bytes]);
      if (connection.buffer.length > 2 * 1024 * 1024) { connection.error = 'Native host message exceeds the limit'; this.disconnect(extension, id); return; }
      while (connection.buffer.length >= 4) {
        const size = connection.buffer.readUInt32LE(0);
        if (size > 1024 * 1024) { connection.error = 'Native host message exceeds the limit'; this.disconnect(extension, id); return; }
        if (connection.buffer.length < 4 + size) return;
        try { connection.messages.push(JSON.parse(connection.buffer.toString('utf8', 4, 4 + size))); }
        catch { connection.error = 'Native host returned invalid JSON'; this.disconnect(extension, id); return; }
        connection.buffer = connection.buffer.subarray(4 + size);
        if (connection.messages.length > 100) { connection.error = 'Native host queue exceeds the limit'; this.disconnect(extension, id); return; }
      }
    });
    return { id };
  }
  connection(extension, id) {
    const connection = this.connections.get(id);
    if (!connection || connection.extension !== extension) throw new BrowserError('NATIVE_CONNECTION_NOT_FOUND', 'No native connection belongs to this extension');
    return connection;
  }
  post(extension, id, value) {
    const connection = this.connection(extension, id);
    if (connection.closed) throw new BrowserError('NATIVE_HOST_CLOSED', 'Native host disconnected');
    if (connection.blocked) throw new BrowserError('NATIVE_BACKPRESSURE', 'Wait for the native host to read pending messages');
    const body = Buffer.from(JSON.stringify(value));
    if (body.length > 1024 * 1024) throw new BrowserError('NATIVE_MESSAGE_TOO_LARGE', 'Native message exceeds 1 MB');
    const size = Buffer.alloc(4); size.writeUInt32LE(body.length);
    connection.blocked = !connection.process.stdin.write(Buffer.concat([size, body])); return { ok: true };
  }
  poll(extension, id) { const connection = this.connection(extension, id); const result = { messages: connection.messages.splice(0), closed: connection.closed, error: connection.error }; if (connection.closed) this.connections.delete(id); return result; }
  disconnect(extension, id) { const connection = this.connection(extension, id); connection.process.stdin.end(); connection.process.kill(); connection.closed = true; return { ok: true }; }
  stop() { for (const connection of this.connections.values()) if (!connection.closed) this.disconnect(connection.extension, connection.id); this.connections.clear(); }
}
