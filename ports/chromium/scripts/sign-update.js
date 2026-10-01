// Run by the distributor with an existing Ed25519 key file. This does not
// generate keys, upload releases, or perform OS application signing.
import { createPrivateKey, createHash, sign } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { readFile, writeFile, stat } from 'node:fs/promises';

const options = {};
for (let index = 2; index < process.argv.length; index += 2) {
  const name = process.argv[index]?.slice(2); const value = process.argv[index + 1];
  if (!process.argv[index]?.startsWith('--') || !value || options[name]) throw new Error('Use --key --artifact --version --platform --arch --url --out [--expires-seconds]');
  options[name] = value;
}
for (const name of ['key', 'artifact', 'version', 'platform', 'arch', 'url', 'out']) if (!options[name]) throw new Error(`Missing --${name}`);
const url = new URL(options.url);
if (url.protocol !== 'https:' || url.username || url.password || !/^\d+\.\d+\.\d+$/.test(options.version) || !['linux', 'darwin', 'win32'].includes(options.platform) || !['x64', 'arm64'].includes(options.arch)) throw new Error('Invalid release target, version, or HTTPS artifact URL');
const key = createPrivateKey(await readFile(options.key));
if (key.asymmetricKeyType !== 'ed25519') throw new Error('Release envelopes require an Ed25519 key');
const lifetime = Number(options['expires-seconds'] || 604800);
if (!Number.isFinite(lifetime) || lifetime < 60 || lifetime > 2592000) throw new Error('Expiry must be 60 seconds to 30 days');
const size = (await stat(options.artifact)).size;
if (size < 1 || size > 1024 * 1024 * 1024) throw new Error('Artifact size must be 1 byte to 1 GB');
const hash = createHash('sha256'); for await (const chunk of createReadStream(options.artifact)) hash.update(chunk);
const payload = JSON.stringify({ version: options.version, platform: options.platform, arch: options.arch, expires: Date.now() + lifetime * 1000, url: url.href, size, sha256: hash.digest('hex') });
await writeFile(options.out, JSON.stringify({ payload, signature: sign(null, Buffer.from(payload), key).toString('base64') }, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
console.log('Signed release envelope written. No artifact was uploaded.');
