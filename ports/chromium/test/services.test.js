import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, createCipheriv, createDecipheriv, createHash, sign } from 'node:crypto';
import { mkdtemp, readFile, writeFile, mkdir, rm, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Vault, parseCSV, passwordCSV } from '../src/services/vault.js';
import { UpdateService, verifiedManifest } from '../src/services/updates.js';
import { verifiedCRX, extractZIP, zipEntries } from '../src/services/crx.js';
import { NativeMessaging } from '../src/services/native-messaging.js';
import { ExtensionService } from '../src/services/extensions.js';
import { ExtensionAPI, matchesHost } from '../src/services/extension-api.js';
import { LoginOffers } from '../src/services/login-offers.js';

test('vault encrypts all metadata, isolates origins, imports quoted CSV, and refuses insecure storage', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'search-vault-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const key = randomBytes(32);
  const crypto = {
    available: () => true,
    encrypt: text => { const iv = randomBytes(12); const cipher = createCipheriv('aes-256-gcm', key, iv); const data = Buffer.concat([cipher.update(text), cipher.final()]); return Buffer.concat([iv, cipher.getAuthTag(), data]); },
    decrypt: data => { const decipher = createDecipheriv('aes-256-gcm', key, data.subarray(0, 12)); decipher.setAuthTag(data.subarray(12, 28)); return Buffer.concat([decipher.update(data.subarray(28)), decipher.final()]).toString(); },
  };
  const vault = new Vault(directory, crypto);
  await vault.save({ origin: 'https://example.com/login', username: 'test-user', password: 'fake-password-for-test' });
  const contents = await readFile(path.join(directory, 'vault.json'), 'utf8');
  assert.ok(!contents.includes('fake-password-for-test') && !contents.includes('test-user') && !contents.includes('example.com'));
  assert.equal((await stat(path.join(directory, 'vault.json'))).mode & 0o777, 0o600);
  const [account] = await vault.list('https://example.com');
  assert.ok(!('password' in account));
  await assert.rejects(vault.get(account.id, 'https://other.example'), { code: 'PASSWORD_NOT_FOUND' });
  assert.equal((await vault.get(account.id, 'https://example.com')).password, 'fake-password-for-test');
  assert.deepEqual(parseCSV('a,b\r\n"with,comma","with ""quote""\nand newline"'), [['a', 'b'], ['with,comma', 'with "quote"\nand newline']]);
  const csv = 'name,url,username,password\nExample,https://example.com/login,"new,user","fake,secret"';
  assert.equal(passwordCSV(csv)[0].username, 'new,user');
  await vault.importCSV(csv);
  assert.equal((await vault.list()).length, 2);
  const before = await readFile(path.join(directory, 'vault.json'), 'utf8');
  assert.throws(() => vault.importCSV('url,username,password\njavascript:alert(1),user,password'));
  assert.equal(await readFile(path.join(directory, 'vault.json'), 'utf8'), before);
  await vault.remove(account.id);
  assert.equal((await vault.list()).length, 1);
  const insecure = new Vault(directory, { available: () => false });
  await assert.rejects(insecure.list(), { code: 'VAULT_UNAVAILABLE' });
});

test('updates require a valid release signature, device target, freshness, and exact artifact checksum', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'search-update-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const artifact = Buffer.from('verified release fixture');
  const payload = JSON.stringify({ version: '0.2.0', platform: 'linux', arch: 'x64', expires: Date.now() + 60000, url: 'https://releases.example/fixture.zip', size: artifact.length, sha256: createHash('sha256').update(artifact).digest('hex') });
  const envelope = { payload, signature: sign(null, Buffer.from(payload), privateKey).toString('base64') };
  const options = { publicKey: publicKey.export({ type: 'spki', format: 'pem' }), platform: 'linux', arch: 'x64', currentVersion: '0.1.0' };
  assert.equal(verifiedManifest(envelope, options.publicKey, options).version, '0.2.0');
  assert.throws(() => verifiedManifest({ ...envelope, payload: payload.replace('0.2.0', '9.9.9') }, options.publicKey, options), { code: 'BAD_SIGNATURE' });
  assert.throws(() => verifiedManifest(envelope, options.publicKey, { ...options, platform: 'win32' }), { code: 'WRONG_PLATFORM' });
  assert.throws(() => verifiedManifest(envelope, options.publicKey, { ...options, currentVersion: '0.3.0' }), { code: 'UPDATE_NOT_NEWER' });
  let corrupt = false;
  const service = new UpdateService({ ...options, directory, feed: 'https://releases.example/feed.json', fetcher: async url => String(url).endsWith('feed.json') ? Response.json(envelope) : new Response(corrupt ? Buffer.from('wrong artifact') : artifact) });
  const manifest = await service.check();
  const result = await service.stage(manifest);
  assert.deepEqual(await readFile(result.staged), artifact);
  corrupt = true;
  await assert.rejects(service.stage(manifest), { code: 'BAD_CHECKSUM' });
});

test('CRX verifies RSA/EC identity and signatures and ZIP extraction rejects traversal', async t => {
  const zip = await readFile(new URL('fixtures/extension.zip', import.meta.url));
  const directory = await mkdtemp(path.join(os.tmpdir(), 'search-crx-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const varint = value => { const bytes = []; do { bytes.push((value & 127) | (value > 127 ? 128 : 0)); value = Math.floor(value / 128); } while (value); return Buffer.from(bytes); };
  const field = (id, bytes) => Buffer.concat([varint(id * 8 + 2), varint(bytes.length), bytes]);
  for (const [type, options, proofType] of [['rsa', { modulusLength: 2048 }, 2], ['ec', { namedCurve: 'prime256v1' }, 3]]) {
    const { publicKey, privateKey } = generateKeyPairSync(type, options);
    const key = publicKey.export({ type: 'spki', format: 'der' });
    const hash = createHash('sha256').update(key).digest().subarray(0, 16);
    const id = [...hash].map(byte => String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15))).join('');
    const signed = field(1, hash); const length = Buffer.alloc(4); length.writeUInt32LE(signed.length);
    const signature = sign('sha256', Buffer.concat([Buffer.from('CRX3 SignedData\0'), length, signed, zip]), privateKey);
    const proof = Buffer.concat([field(1, key), field(2, signature)]);
    const header = Buffer.concat([field(proofType, proof), field(10000, signed)]);
    const prefix = Buffer.alloc(12); prefix.write('Cr24'); prefix.writeUInt32LE(3, 4); prefix.writeUInt32LE(header.length, 8);
    const crx = Buffer.concat([prefix, header, zip]);
    assert.deepEqual(verifiedCRX(crx, id).archive, zip);
    assert.throws(() => verifiedCRX(crx, 'a'.repeat(32)), { code: 'BAD_SIGNATURE' });
    const changed = Buffer.from(crx); changed[changed.length - 1] ^= 1;
    assert.throws(() => verifiedCRX(changed, id), { code: 'BAD_SIGNATURE' });
  }
  await extractZIP(zip, directory);
  assert.match(await readFile(path.join(directory, 'popup.html'), 'utf8'), /Extension works/);
  const unsafe = await readFile(new URL('fixtures/unsafe.zip', import.meta.url));
  assert.throws(() => zipEntries(unsafe), { code: 'UNSAFE_ZIP' });
});

test('extensions review permissions, persist loading state, and enable/reload/remove', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'search-extension-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const source = path.join(directory, 'source'); await mkdir(source);
  await writeFile(path.join(source, 'manifest.json'), JSON.stringify({ manifest_version: 3, name: 'Fixture', version: '1.0', permissions: ['storage'] }));
  const loaded = new Set(); const id = 'a'.repeat(32);
  const service = new ExtensionService(path.join(directory, 'profile'), { load: async () => { loaded.add(id); return id; }, unload: async key => loaded.delete(key) });
  await service.start();
  assert.deepEqual((await service.folder(source, false)).confirmation.permissions, ['storage']);
  assert.equal(loaded.size, 0);
  const extension = await service.folder(source, true);
  assert.equal(extension.id, id);
  await service.enable(id, false); assert.equal(loaded.size, 0);
  await service.enable(id, true); assert.equal(loaded.size, 1);
  await service.pin(id, true); assert.equal(service.list()[0].pinned, true);
  await service.reload(id); assert.equal(loaded.size, 1);
  await service.remove(id); assert.equal(service.list().length, 0);
});

test('native messaging enforces approval, origin registration, framing, and connection ownership', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'search-native-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const extension = 'a'.repeat(32); const host = 'org.search.fixture';
  const program = path.join(directory, 'echo.cjs');
  await writeFile(program, `#!${process.execPath}\nlet input=Buffer.alloc(0);process.stdin.on('data',chunk=>{input=Buffer.concat([input,chunk]);while(input.length>=4){const size=input.readUInt32LE(0);if(input.length<size+4)return;const data=input.subarray(0,size+4);process.stdout.write(data);input=input.subarray(size+4)}});`, { mode: 0o700 });
  await writeFile(path.join(directory, `${host}.json`), JSON.stringify({ name: host, type: 'stdio', path: program, allowed_origins: [`chrome-extension://${extension}/`] }));
  const broker = new NativeMessaging({ directories: [directory] }); t.after(() => broker.stop());
  await assert.rejects(broker.connect(extension, host), { code: 'NATIVE_PERMISSION_REQUIRED' });
  broker.authorize(extension, host, true);
  const connection = await broker.connect(extension, host);
  broker.post(extension, connection.id, { message: 'hello' });
  let result;
  for (let n = 0; n < 30; n++) { result = broker.poll(extension, connection.id); if (result.messages.length) break; await new Promise(resolve => setTimeout(resolve, 20)); }
  assert.deepEqual(result.messages, [{ message: 'hello' }]);
  assert.throws(() => broker.poll('b'.repeat(32), connection.id), { code: 'NATIVE_CONNECTION_NOT_FOUND' });
  assert.throws(() => broker.post(extension, connection.id, 'x'.repeat(1024 * 1024)), { code: 'NATIVE_MESSAGE_TOO_LARGE' });
  broker.disconnect(extension, connection.id);
});

test('extension host APIs hide private tabs and require scoped grants for page access', async () => {
  const normal = { id: 'normal', url: 'https://example.com/page', title: 'Normal', private: false };
  const privateTab = { id: 'private', url: 'https://secret.example/', title: 'Private', private: true };
  let manifest = { permissions: ['activeTab', 'scripting'], host_permissions: [] };
  const executed = [];
  const api = new ExtensionAPI({ state: () => ({ tabs: [normal, privateTab], active: normal.id }), command: request => executed.push(request), manifest: () => manifest, inject: () => 'injected' });
  assert.equal(matchesHost('https://*.example.com/*', 'https://example.com/page'), true);
  assert.equal(matchesHost('https://*.example.com/*', 'https://sub.example.com/page'), true);
  assert.equal(matchesHost('https://*.example.com/*', 'https://badexample.com/page'), false);
  assert.equal(matchesHost('<all_urls>', 'file:///sensitive'), false);
  const [tab] = await api.invoke('extension', { api: 'tabs.query', args: [{}] });
  assert.equal(tab.url, undefined); assert.equal(tab.id, 1);
  assert.deepEqual(await api.invoke('extension', { api: 'tabs.query', args: [{ url: 'https://example.com/*' }] }), []);
  await assert.rejects(api.invoke('extension', { api: 'scripting.executeScript', args: [{ target: { tabId: tab.id }, functionSource: '()=>1' }] }), { code: 'EXTENSION_PERMISSION_REQUIRED' });
  api.grant('extension', normal);
  assert.equal((await api.invoke('extension', { api: 'tabs.get', args: [tab.id] })).url, normal.url);
  assert.equal((await api.invoke('extension', { api: 'scripting.executeScript', args: [{ target: { tabId: tab.id }, functionSource: '()=>1' }] }))[0].result, 'injected');
  normal.url = 'https://other.example/';
  await assert.rejects(api.invoke('extension', { api: 'scripting.executeScript', args: [{ target: { tabId: tab.id }, functionSource: '()=>1' }] }), { code: 'EXTENSION_PERMISSION_REQUIRED' });
  await assert.rejects(api.invoke('extension', { api: 'tabs.get', args: [2] }), { code: 'TAB_NOT_FOUND' });
  manifest = { permissions: ['tabs'], host_permissions: [] };
  assert.equal((await api.invoke('extension', { api: 'tabs.query', args: [{}] })).length, 1);
  await api.invoke('extension', { api: 'tabs.remove', args: [tab.id] });
  assert.deepEqual(executed, [{ do: 'close', id: normal.id }]);
});

test('login offers require a settled sign-in and explicit approval, never save private or failed logins', async t => {
  const items = []; let approved = false; const prompts = [];
  const vault = { available: () => true, list: async () => items.map((item, id) => ({ ...item, id })), get: async id => items[id], save: async account => { items.push({ origin: account.origin, username: account.username, password: account.password }); } };
  const offers = new LoginOffers({ vault, prompt: async offer => { prompts.push(offer); return approved; } });
  t.after(() => offers.stop());
  const tab = { id: 'tab', private: false }; const account = { username: 'test-user', password: 'fixture-only-password' };
  offers.submitted({ id: 'private', private: true }, 'https://example.com', account);
  assert.equal(offers.pending.size, 0);
  offers.submitted(tab, 'https://example.com', account);
  await offers.settled(tab, true); assert.equal(prompts.length, 0); assert.equal(items.length, 0);
  await offers.settled(tab, false); assert.equal(prompts.length, 1); assert.equal(items.length, 0);
  assert.ok(!('password' in prompts[0]));
  approved = true; offers.submitted(tab, 'https://example.com', account); await offers.settled(tab, false);
  assert.equal(items.length, 1); assert.equal(offers.pending.size, 0);
  offers.submitted(tab, 'https://example.com', account); await offers.settled(tab, false);
  assert.equal(prompts.length, 2);
  offers.submitted(tab, 'https://example.com', { ...account, password: 'changed-fixture' }); await offers.settled(tab, false);
  assert.equal(prompts.at(-1).updating, true);
});
