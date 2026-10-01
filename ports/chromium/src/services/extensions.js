import { mkdir, readFile, writeFile, rename, cp, rm, realpath, lstat } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID, generateKeyPairSync, createHash } from 'node:crypto';
import { BrowserError } from '../contract.js';
import { verifiedCRX, extractZIP, extensionID } from './crx.js';

export class ExtensionService {
  constructor(directory, { load, unload, fetcher = fetch }) {
    this.directory = directory; this.load = load; this.unload = unload; this.fetcher = fetcher; this.entries = [];
  }
  async start() {
    try { this.entries = JSON.parse(await readFile(path.join(this.directory, 'extensions.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    for (const entry of this.entries) this.ownedFolder(entry.folder);
    for (const entry of this.entries.filter(entry => entry.enabled)) {
      try { await this.load(entry); entry.error = null; } catch (error) { entry.error = error.message; }
    }
  }
  list() { return this.entries.map(({ folder, source, ...entry }) => ({ ...entry, folder, unpacked: Boolean(source) })); }
  ownedFolder(folder) {
    const root = path.resolve(this.directory, 'extensions');
    if (typeof folder !== 'string' || !path.resolve(folder).startsWith(root + path.sep)) throw new BrowserError('UNSAFE_EXTENSION', 'Extension files must be inside the managed directory');
    return folder;
  }
  async persist() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const temporary = path.join(this.directory, 'extensions.json.tmp');
    await writeFile(temporary, JSON.stringify(this.entries, null, 2), { mode: 0o600 });
    await rename(temporary, path.join(this.directory, 'extensions.json'));
  }
  async manifest(folder) {
    const manifest = JSON.parse(await readFile(path.join(folder, 'manifest.json'), 'utf8'));
    if (![2, 3].includes(manifest.manifest_version) || typeof manifest.name !== 'string' || !manifest.version || [manifest.permissions, manifest.host_permissions].some(value => value !== undefined && (!Array.isArray(value) || value.some(item => typeof item !== 'string')))) throw new BrowserError('INVALID_EXTENSION', 'Invalid extension manifest');
    return manifest;
  }
  async inspect(folder) {
    const manifest = await this.manifest(folder);
    const hosts = [...new Set([...(manifest.host_permissions || []), ...(manifest.content_scripts || []).flatMap(script => script.matches || []), ...(manifest.permissions || []).filter(value => value.includes('://') || value === '<all_urls>')])];
    return { name: manifest.name, version: manifest.version, permissions: manifest.permissions || [], hosts, manifest };
  }
  async folder(source, confirmed) {
    if (!confirmed) return { confirmation: await this.inspect(source) };
    const resolved = await realpath(source);
    const managed = path.resolve(this.directory, 'extensions');
    if (managed.startsWith(resolved + path.sep) || resolved === managed) throw new BrowserError('UNSAFE_EXTENSION', 'An extension source cannot contain its managed installation directory');
    // Symlinks can introduce files outside a reviewed directory, including
    // credentials. Reject them throughout unpacked extensions.
    let count = 0; let bytes = 0;
    const verifyTree = async directory => {
      const { readdir } = await import('node:fs/promises');
      for (const name of await readdir(directory)) {
        const target = path.join(directory, name); const stat = await lstat(target);
        if (stat.isSymbolicLink()) throw new BrowserError('UNSAFE_EXTENSION', 'Unpacked extensions cannot contain symlinks');
        if (stat.isDirectory()) await verifyTree(target);
        else {
          count++; bytes += stat.size;
          if (!stat.isFile() || count > 10000 || bytes > 128 * 1024 * 1024 || stat.size > 32 * 1024 * 1024) throw new BrowserError('UNSAFE_EXTENSION', 'Extension files exceed supported types or size limits');
        }
      }
    };
    await verifyTree(resolved);
    const staging = path.join(this.directory, 'extensions', randomUUID());
    await cp(resolved, staging, { recursive: true, errorOnExist: true, force: false });
    const details = await this.inspect(staging);
    // A stable manifest key preserves identity, extension storage, and native
    // host grants across reloads and restarts of an unpacked extension.
    if (!details.manifest.key) {
      details.manifest.key = generateKeyPairSync('rsa', { modulusLength: 2048 }).publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
      await writeFile(path.join(staging, 'manifest.json'), JSON.stringify(details.manifest), { mode: 0o600 });
    }
    const digest = createHash('sha256').update(Buffer.from(details.manifest.key, 'base64')).digest().subarray(0, 16);
    const identity = [...digest].map(byte => String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15))).join('');
    if (this.entries.some(entry => entry.id === identity || entry.source === resolved)) {
      await rm(staging, { recursive: true, force: true });
      throw new BrowserError('EXTENSION_EXISTS', 'Extension is already installed; use reload');
    }
    const entry = { folder: staging, source: resolved, name: details.name, version: details.version, permissions: details.permissions, enabled: true, pinned: false };
    try { entry.id = await this.load(entry); }
    catch (error) { await rm(staging, { recursive: true, force: true }); throw error; }
    this.entries.push(entry); await this.persist();
    return { ...entry };
  }
  async store(reference, confirmed) {
    const id = extensionID(reference);
    if (this.entries.some(entry => entry.id === id)) throw new BrowserError('EXTENSION_EXISTS', 'Extension is already installed; use reload');
    const url = new URL('https://clients2.google.com/service/update2/crx');
    url.search = new URLSearchParams({ response: 'redirect', prodversion: '151.0.0.0', acceptformat: 'crx3', x: `id=${id}&installsource=ondemand&uc` });
    const response = await this.fetcher(url, { signal: AbortSignal.timeout(60000) });
    if (!response.ok) throw new BrowserError('EXTENSION_DOWNLOAD_FAILED', `Chrome Web Store returned ${response.status}`);
    const chunks = []; let size = 0;
    for await (const chunk of response.body) { size += chunk.length; if (size > 64 * 1024 * 1024) throw new BrowserError('INVALID_CRX', 'Extension is too large'); chunks.push(chunk); }
    const verified = verifiedCRX(Buffer.concat(chunks), id);
    const staging = path.join(this.directory, 'extensions', randomUUID());
    try {
      await extractZIP(verified.archive, staging);
      const details = await this.inspect(staging);
      if (!confirmed) return { confirmation: { id, ...details, manifest: undefined } };
      const manifest = { ...details.manifest, key: verified.publicKey };
      await writeFile(path.join(staging, 'manifest.json'), JSON.stringify(manifest), { mode: 0o600 });
      const entry = { id, folder: staging, source: null, name: details.name, version: details.version, permissions: details.permissions, enabled: true, pinned: false };
      const loaded = await this.load(entry);
      if (loaded !== id) throw new BrowserError('INVALID_EXTENSION', 'Loaded extension identity changed');
      this.entries.push(entry); await this.persist(); return { ...entry };
    } finally {
      if (!this.entries.some(entry => entry.folder === staging)) await rm(staging, { recursive: true, force: true });
    }
  }
  entry(id) { const entry = this.entries.find(entry => entry.id === id); if (!entry) throw new BrowserError('EXTENSION_NOT_FOUND', 'Unknown extension'); return entry; }
  async enable(id, enabled) { const entry = this.entry(id); if (enabled) await this.load(entry); else await this.unload(id); entry.enabled = enabled; await this.persist(); return { ok: true }; }
  async remove(id) { const entry = this.entry(id); this.ownedFolder(entry.folder); await this.unload(id); this.entries = this.entries.filter(item => item !== entry); await this.persist(); await rm(entry.folder, { recursive: true, force: true }); return { ok: true }; }
  async pin(id, on) { this.entry(id).pinned = on; await this.persist(); return { ok: true }; }
  async reload(id) {
    const entry = this.entry(id);
    if (!entry.source) { if (entry.enabled) { await this.unload(id); await this.load(entry); } return { ok: true, id }; }
    const original = JSON.parse(await readFile(path.join(entry.folder, 'manifest.json'), 'utf8'));
    // Review changed permissions before executing newly edited source.
    const details = await this.inspect(entry.source);
    const oldDetails = await this.inspect(entry.folder);
    if (JSON.stringify(details.permissions) !== JSON.stringify(entry.permissions) || JSON.stringify(details.hosts) !== JSON.stringify(oldDetails.hosts)) throw new BrowserError('EXTENSION_PERMISSION_CHANGED', 'Permissions changed; remove and review the extension again');
    const staging = `${entry.folder}.reload`;
    const backup = `${entry.folder}.previous`;
    await rm(staging, { recursive: true, force: true });
    await cp(entry.source, staging, { recursive: true, dereference: false, filter: async target => {
      if ((await lstat(target)).isSymbolicLink()) throw new BrowserError('UNSAFE_EXTENSION', 'Unpacked extensions cannot contain symlinks');
      return true;
    } });
    await writeFile(path.join(staging, 'manifest.json'), JSON.stringify({ ...details.manifest, key: original.key }), { mode: 0o600 });
    if (entry.enabled) await this.unload(id);
    await rename(entry.folder, backup); await rename(staging, entry.folder);
    try {
      if (entry.enabled && await this.load(entry) !== id) throw new BrowserError('INVALID_EXTENSION', 'Reload changed extension identity');
      Object.assign(entry, { name: details.name, version: details.version, error: null });
      await this.persist(); await rm(backup, { recursive: true, force: true });
      return { ok: true, id };
    } catch (error) {
      if (entry.enabled) { try { await this.unload(id); } catch {} }
      await rm(entry.folder, { recursive: true, force: true }); await rename(backup, entry.folder);
      if (entry.enabled) await this.load(entry);
      throw error;
    }
  }
}
