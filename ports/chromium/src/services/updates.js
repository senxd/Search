import { createHash, createPublicKey, verify } from 'node:crypto';
import { mkdir, rename, rm } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import path from 'node:path';
import { BrowserError } from '../contract.js';

export function verifiedManifest(envelope, publicKey, { platform, arch, currentVersion, now = Date.now() } = {}) {
  if (!envelope || typeof envelope.payload !== 'string' || typeof envelope.signature !== 'string') throw new BrowserError('INVALID_UPDATE', 'Update envelope needs a signed payload');
  const key = createPublicKey(publicKey);
  if (key.asymmetricKeyType !== 'ed25519' || !verify(null, Buffer.from(envelope.payload), key, Buffer.from(envelope.signature, 'base64'))) throw new BrowserError('BAD_SIGNATURE', 'Update signature is invalid');
  const manifest = JSON.parse(envelope.payload);
  if (!/^\d+\.\d+\.\d+$/.test(manifest.version) || !Number.isFinite(manifest.expires) || manifest.expires <= now) throw new BrowserError('INVALID_UPDATE', 'Update is invalid or expired');
  if (manifest.platform !== platform || manifest.arch !== arch) throw new BrowserError('WRONG_PLATFORM', 'Update targets another device');
  const parts = version => version.split('.').map(Number);
  const next = parts(manifest.version); const current = parts(currentVersion);
  const difference = next.findIndex((value, index) => value !== current[index]);
  if (difference < 0 || next[difference] < current[difference]) throw new BrowserError('UPDATE_NOT_NEWER', 'Update must be newer than the installed version');
  const url = new URL(manifest.url);
  if (url.protocol !== 'https:' || url.username || url.password || !/^[a-f0-9]{64}$/.test(manifest.sha256) || !Number.isInteger(manifest.size) || manifest.size < 1 || manifest.size > 1024 * 1024 * 1024) throw new BrowserError('INVALID_UPDATE', 'Invalid artifact address, size, or checksum');
  return manifest;
}

export class UpdateService {
  constructor({ feed, publicKey, directory, platform = process.platform, arch = process.arch, currentVersion, fetcher = fetch }) {
    Object.assign(this, { feed, publicKey, directory, platform, arch, currentVersion, fetcher });
  }
  configured() { return Boolean(this.feed && this.publicKey); }
  async check() {
    if (!this.configured()) throw new BrowserError('UPDATE_UNCONFIGURED', 'A release feed and trusted public key must be configured by the distributor');
    const url = new URL(this.feed);
    if (url.protocol !== 'https:') throw new BrowserError('INVALID_UPDATE', 'Release feed requires HTTPS');
    const response = await this.fetcher(url, { redirect: 'error', signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new BrowserError('UPDATE_FAILED', `Feed returned ${response.status}`);
    const chunks = []; let size = 0;
    for await (const chunk of response.body) { size += chunk.length; if (size > 65536) throw new BrowserError('INVALID_UPDATE', 'Feed is too large'); chunks.push(chunk); }
    return verifiedManifest(JSON.parse(Buffer.concat(chunks).toString('utf8')), this.publicKey, this);
  }
  async stage(manifest) {
    // Reverify callers cannot pass an unsigned artifact by calling stage directly.
    const verified = await this.check();
    if (JSON.stringify(verified) !== JSON.stringify(manifest)) throw new BrowserError('UPDATE_CHANGED', 'The release changed; check again');
    const response = await this.fetcher(verified.url, { redirect: 'error', signal: AbortSignal.timeout(120000) });
    if (!response.ok) throw new BrowserError('UPDATE_FAILED', `Artifact returned ${response.status}`);
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const destination = path.join(this.directory, `Browser-Lab-${verified.version}-${this.platform}-${this.arch}.update`);
    const temporary = `${destination}.${randomUUID()}.tmp`; let size = 0;
    const hash = createHash('sha256');
    try {
      await pipeline(Readable.fromWeb(response.body), new Transform({ transform(chunk, _encoding, callback) {
        size += chunk.length;
        if (size > verified.size) { callback(new BrowserError('BAD_CHECKSUM', 'Artifact exceeds its signed size')); return; }
        hash.update(chunk); callback(null, chunk);
      } }), createWriteStream(temporary, { mode: 0o600, flags: 'wx' }));
      if (size !== verified.size || hash.digest('hex') !== verified.sha256) throw new BrowserError('BAD_CHECKSUM', 'Artifact checksum does not match the signed release');
      await rename(temporary, destination);
      return { staged: destination, version: verified.version };
    } finally { await rm(temporary, { force: true }); }
  }
}
