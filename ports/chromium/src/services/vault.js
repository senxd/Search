import { randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { BrowserError } from '../contract.js';
import { validateURL } from '../address.js';

export function parseCSV(text) {
  if (typeof text !== 'string' || text.length > 8 * 1024 * 1024) throw new BrowserError('INVALID_IMPORT', 'CSV is too large');
  const rows = []; let row = []; let value = ''; let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') {
      if (quoted && text[i + 1] === '"') { value += '"'; i++; }
      else if (quoted || value.length === 0) quoted = !quoted;
      else value += char;
    } else if (char === ',' && !quoted) { row.push(value); value = ''; }
    else if ((char === '\n' || char === '\r') && !quoted) {
      if (char === '\r' && text[i + 1] === '\n') i++;
      row.push(value); if (row.some(cell => cell.length)) rows.push(row); row = []; value = '';
    } else value += char;
  }
  if (quoted) throw new BrowserError('INVALID_IMPORT', 'CSV has an unterminated quoted field');
  row.push(value); if (row.some(cell => cell.length)) rows.push(row);
  return rows;
}

export function passwordCSV(text) {
  const [head, ...rows] = parseCSV(text.replace(/^\uFEFF/, ''));
  if (!head) return [];
  const columns = head.map(value => value.trim().toLowerCase());
  const index = names => columns.findIndex(value => names.includes(value));
  const url = index(['url', 'website', 'origin']);
  const username = index(['username', 'user', 'login']);
  const password = index(['password']);
  if ([url, username, password].some(i => i < 0)) throw new BrowserError('INVALID_IMPORT', 'CSV needs url, username, and password columns');
  return rows.map(row => ({ origin: new URL(validateURL(row[url])).origin, username: row[username] || '', password: row[password] || '' }));
}

// Encrypt the entire document using the platform vault. basic_text is never an
// acceptable substitute. No key, password, or credential is saved in settings.
export class Vault {
  constructor(directory, encryptor) { this.directory = directory; this.encryptor = encryptor; this.queue = Promise.resolve(); }
  available() { return Boolean(this.encryptor?.available()); }
  check() { if (!this.available()) throw new BrowserError('VAULT_UNAVAILABLE', 'A secure OS keychain is required; plaintext fallback is disabled'); }
  async read() {
    this.check();
    try {
      const data = JSON.parse(await readFile(path.join(this.directory, 'vault.json'), 'utf8'));
      if (data.version !== 1 || typeof data.ciphertext !== 'string') throw new Error('Invalid vault format');
      return JSON.parse(await this.encryptor.decrypt(Buffer.from(data.ciphertext, 'base64')));
    } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  }
  async write(items) {
    this.check();
    const ciphertext = await this.encryptor.encrypt(JSON.stringify(items));
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const temporary = path.join(this.directory, `vault-${randomUUID()}.tmp`);
    await writeFile(temporary, JSON.stringify({ version: 1, ciphertext: ciphertext.toString('base64') }), { mode: 0o600, flag: 'wx' });
    await rename(temporary, path.join(this.directory, 'vault.json'));
  }
  mutate(fn) {
    const operation = this.queue.then(async () => { const items = await this.read(); const result = fn(items); await this.write(items); return result; });
    this.queue = operation.catch(() => {});
    return operation;
  }
  async list(origin) { return (await this.read()).filter(item => !origin || item.origin === origin).map(({ id, origin, username }) => ({ id, origin, username })); }
  async get(id, origin) {
    const item = (await this.read()).find(item => item.id === id && item.origin === origin);
    if (!item) throw new BrowserError('PASSWORD_NOT_FOUND', 'No saved account matches this page origin');
    return item;
  }
  save(entry) {
    const origin = new URL(validateURL(entry.origin)).origin;
    if (!/^https?:/.test(origin) || typeof entry.password !== 'string' || typeof entry.username !== 'string' || entry.password.length > 16384) throw new BrowserError('INVALID_PASSWORD', 'Invalid account');
    return this.mutate(items => {
      const item = items.find(item => item.origin === origin && item.username === entry.username);
      if (item) item.password = entry.password;
      else items.push({ id: randomUUID(), origin, username: entry.username, password: entry.password });
      return { saved: true };
    });
  }
  remove(id) { return this.mutate(items => { const at = items.findIndex(item => item.id === id); if (at >= 0) items.splice(at, 1); return { removed: at >= 0 }; }); }
  importCSV(text) {
    const entries = passwordCSV(text);
    return this.mutate(items => {
      for (const entry of entries) {
        const existing = items.find(item => item.origin === entry.origin && item.username === entry.username);
        if (existing) existing.password = entry.password; else items.push({ id: randomUUID(), ...entry });
      }
      return { imported: entries.length };
    });
  }
}

export function fillAccount({ origin, username, password }) {
  if (location.origin !== origin) throw new Error('The page origin changed; choose an account again');
  const field = document.querySelector('input[type="password"]');
  if (!field) throw new Error('No password field on this page');
  const form = field.form || document;
  const user = form.querySelector('input[autocomplete="username"],input[type="email"],input[name*="user" i],input[name*="login" i],input[type="text"]');
  const set = (element, value) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(element, value);
    element.dispatchEvent(new Event('input', { bubbles: true })); element.dispatchEvent(new Event('change', { bubbles: true }));
  };
  if (user) set(user, username);
  set(field, password);
  return { filled: true };
}
