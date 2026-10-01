import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import os from 'node:os';
import { mkdtemp, readFile, rm, mkdir } from 'node:fs/promises';
import { Browser } from '../src/browser.js';
import { Store } from '../src/store.js';
import { EngineRegistry } from '../src/contract.js';
import { ChromiumAdapter } from '../src/adapters/chromium.js';
import { startServer } from '../src/server.js';

test('Chromium browser, agent API, and responsive interface', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'search-port-test-'));
  const fixture = http.createServer((request, response) => {
    if (request.url.startsWith('/download')) {
      response.writeHead(200, { 'Content-Disposition': 'attachment; filename="sample.txt"' });
      response.end(request.url.includes('?') ? request.url.split('?')[1] : 'downloaded by Search');
      return;
    }
    response.setHeader('Content-Type', 'text/html');
    if (request.url === '/cookie') response.setHeader('Set-Cookie', 'sample=normal; SameSite=Lax; Path=/');
    response.end(`<!doctype html><title>${request.url === '/next' ? 'Next page' : 'A quiet page'}</title>
      <h1>A quiet page</h1><div id="banner">Newsletter</div>
      <form onsubmit="event.preventDefault();document.querySelector('#answer').textContent=document.querySelector('#name').value"><input id="name"><button id="submit">Send</button></form><p id="answer"></p>
      <a id="next" href="/next">Next</a><a id="download" href="/download">Download</a>
      <article><p>${'Readable words, with no clutter. '.repeat(18)}</p><p>${'A second paragraph about browsing quietly. '.repeat(18)}</p></article>`);
  });
  await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${fixture.address().port}`;
  const registry = new EngineRegistry();
  const executablePath = process.env.SEARCH_CHROMIUM_PATH || '/usr/bin/chromium';
  for (const id of ['chromium', 'alternate']) registry.register(id, () => new ChromiumAdapter({ id, directory, executablePath }));
  registry.register('limited', () => {
    const adapter = new ChromiumAdapter({ id: 'limited', directory, executablePath });
    adapter.capabilities = { ...adapter.capabilities, screenshots: false };
    return adapter;
  });
  registry.register('broken', () => {
    const adapter = new ChromiumAdapter({ id: 'broken', directory, executablePath });
    adapter.start = async () => { throw new Error('Deliberate launch failure'); };
    return adapter;
  });
  let browser = new Browser({ registry, engine: 'chromium', store: new Store(directory) });
  let server;
  t.after(async () => {
    await server?.stop();
    await browser.stop();
    await new Promise(resolve => fixture.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  await browser.start();
  const ask = request => browser.execute(request);
  let normal;

  await t.test('navigation, forms, input, screenshots, and history work', async () => {
    normal = (await ask({ do: 'open', url: `${url}/cookie` })).id;
    const result = await ask({ do: 'wait', id: normal });
    assert.equal(result.loading, false);
    assert.equal(result.timeout, false);
    assert.equal(result.failure, null);
    assert.equal(result.title, 'A quiet page');
    await ask({ do: 'type', id: normal, selector: '#name', text: 'Ada' });
    await ask({ do: 'submit', id: normal, selector: '#name' });
    assert.equal(await ask({ do: 'eval', id: normal, js: 'document.querySelector("#answer").textContent' }), 'Ada');
    await ask({ do: 'input', id: normal, kind: 'key', key: 'Tab' });
    assert.match(await ask({ do: 'text', id: normal }), /Readable words/);
    assert.equal((await ask({ do: 'find', id: normal, text: 'Readable words' })).found, true);
    const image = await ask({ do: 'shot', id: normal });
    assert.equal(Buffer.from(image.base64, 'base64').subarray(1, 4).toString(), 'PNG');
    await ask({ do: 'click', id: normal, selector: '#next' });
    await browser.adapter.page(normal).waitForURL(`${url}/next`);
    await ask({ do: 'back', id: normal });
    assert.equal((await browser.adapter.inspect(normal)).url, `${url}/cookie`);
    await ask({ do: 'forward', id: normal });
    assert.equal((await browser.adapter.inspect(normal)).url, `${url}/next`);
    assert.ok(browser.history.some(entry => entry.url === `${url}/cookie`));
  });

  await t.test('private tabs are isolated and never saved', async () => {
    await ask({ do: 'go', id: normal, url: `${url}/cookie` });
    await ask({ do: 'eval', id: normal, js: 'localStorage.setItem("secret", "normal-only")' });
    const privateID = (await ask({ do: 'open', url: `${url}/private-secret`, private: true })).id;
    assert.equal(await ask({ do: 'eval', id: privateID, js: 'document.cookie' }), '');
    assert.equal(await ask({ do: 'eval', id: privateID, js: 'localStorage.getItem("secret")' }), null);
    await ask({ do: 'eval', id: privateID, js: 'localStorage.setItem("secret", "private-only")' });
    await assert.rejects(ask({ do: 'bookmark', id: privateID }), { code: 'PRIVATE_TAB' });
    const saved = await readFile(path.join(directory, 'browser.json'), 'utf8');
    assert.ok(!saved.includes('private-secret'));
    await ask({ do: 'close', id: privateID });
    assert.equal(await ask({ do: 'eval', id: normal, js: 'localStorage.getItem("secret")' }), 'normal-only');
    assert.equal([...browser.adapter.contexts.keys()].some(key => key.startsWith('private:')), false);
  });

  await t.test('bookmarks, pins, groups, and isolated spaces share the model', async () => {
    await ask({ do: 'bookmark', id: normal });
    await ask({ do: 'pin', id: normal, on: true });
    const group = await ask({ do: 'group', action: 'new', id: normal, name: 'Reading' });
    await ask({ do: 'group', action: 'fold', group: group.id, on: true });
    const space = await ask({ do: 'space', action: 'new', name: 'Work', fresh: true });
    await ask({ do: 'go', url: `${url}/space` });
    assert.equal(await ask({ do: 'eval', js: 'localStorage.getItem("secret")' }), null);
    assert.equal(await ask({ do: 'eval', js: 'document.cookie' }), '');
    assert.equal(browser.space, space.id);
    await ask({ do: 'select', id: normal });
    assert.equal(browser.space, 'default');
    assert.ok(browser.bookmarks.some(entry => entry.url === `${url}/cookie`));
    assert.equal(browser.tab(normal).pin, true);
  });

  await t.test('reader and hidden elements work across navigation', async () => {
    await ask({ do: 'hide', id: normal, selector: '#banner' });
    assert.equal(await ask({ do: 'eval', id: normal, js: 'getComputedStyle(document.querySelector("#banner")).display' }), 'none');
    await ask({ do: 'reload', id: normal });
    await browser.adapter.page(normal).waitForFunction(() => getComputedStyle(document.querySelector('#banner')).display === 'none');
    assert.equal((await ask({ do: 'reader', id: normal })).reader, true);
    assert.equal(await ask({ do: 'eval', id: normal, js: 'Boolean(document.querySelector("#search-reader"))' }), true);
    assert.equal((await ask({ do: 'reader', id: normal })).reader, false);
  });

  await t.test('downloads require an explicit destination', async () => {
    await ask({ do: 'click', id: normal, selector: '#download' });
    for (let n = 0; n < 30 && !browser.adapter.metadata.get(normal).downloadId; n++) await new Promise(resolve => setTimeout(resolve, 30));
    const destination = path.join(directory, 'saved.txt');
    await ask({ do: 'download-save', id: normal, path: destination });
    assert.equal(await readFile(destination, 'utf8'), 'downloaded by Search');
  });

  await t.test('individual download IDs preserve multiple files after the source tab closes', async () => {
    const tab = (await ask({ do: 'open', url, select: false })).id;
    const page = browser.adapter.page(tab);
    for (const marker of ['first-download', 'second-download']) {
      await ask({ do: 'eval', id: tab, js: `document.querySelector('#download').href='/download?${marker}'` });
      const downloaded = page.waitForEvent('download');
      await ask({ do: 'tap', id: tab, selector: '#download' }); await downloaded;
    }
    const files = browser.snapshot().downloads.filter(item => item.tab === tab);
    assert.equal(files.length, 2);
    await ask({ do: 'close', id: tab });
    for (const [index, item] of files.entries()) {
      const destination = path.join(directory, `multiple-${index}.txt`);
      await ask({ do: 'download-save', downloadId: item.id, path: destination });
      assert.equal(await readFile(destination, 'utf8'), index === 0 ? 'second-download' : 'first-download');
    }
    assert.equal(Buffer.from((await ask({ do: 'download-get', downloadId: files[0].id })).base64, 'base64').toString(), 'second-download');
  });

  await t.test('a failed page keeps its intended address and does not break the browser', async () => {
    const failed = (await ask({ do: 'open', url: 'http://127.0.0.1:1/unavailable', bench: true })).id;
    const result = await ask({ do: 'wait', id: failed });
    assert.equal(result.url, 'http://127.0.0.1:1/unavailable');
    assert.ok(result.failure);
    await ask({ do: 'close', id: failed });
    assert.match(await ask({ do: 'text', id: normal }), /Readable words/);
  });

  await t.test('capability checks and failed swaps leave the active engine working', async () => {
    assert.equal((await ask({ do: 'manifest' })).version, 1);
    const parity = await ask({ do: 'parity' });
    assert.equal(parity.complete, false);
    assert.ok(parity.baseline.some(item => item.feature === 'Chrome extensions' && item.status === 'partial' && item.available === false));
    await assert.rejects(ask({ do: 'require', features: ['extensions'] }), { code: 'FEATURE_UNAVAILABLE' });
    await assert.rejects(ask({ do: 'engine', engine: 'limited', reload: true }), { code: 'FEATURE_UNAVAILABLE' });
    await assert.rejects(ask({ do: 'engine', engine: 'alternate' }), { code: 'RELOAD_REQUIRED' });
    await assert.rejects(ask({ do: 'engine', engine: 'broken', reload: true }), { code: 'ENGINE_SWAP_FAILED' });
    assert.equal(browser.engine, 'chromium');
    assert.match(await ask({ do: 'text', id: normal }), /Readable words/);
  });

  await t.test('explicit engine reload transfers cookies, IndexedDB, local/session storage, and browser state', async () => {
    await ask({ do: 'eval', id: normal, js: 'sessionStorage.setItem("session", "same-tab")' });
    await ask({ do: 'eval', id: normal, js: `new Promise(resolve => {const request=indexedDB.open('swap-db',1);request.onupgradeneeded=()=>request.result.createObjectStore('items');request.onsuccess=()=>{const db=request.result;const tx=db.transaction('items','readwrite');tx.objectStore('items').put('kept','key');tx.oncomplete=()=>{db.close();resolve(true)}}})` });
    const result = await ask({ do: 'engine', engine: 'alternate', reload: true });
    assert.equal(result.engine, 'alternate');
    assert.equal(await ask({ do: 'eval', id: normal, js: 'localStorage.getItem("secret")' }), 'normal-only');
    assert.equal(await ask({ do: 'eval', id: normal, js: 'sessionStorage.getItem("session")' }), 'same-tab');
    assert.match(await ask({ do: 'eval', id: normal, js: 'document.cookie' }), /sample=normal/);
    assert.equal(await ask({ do: 'eval', id: normal, js: `new Promise(resolve=>{const request=indexedDB.open('swap-db',1);request.onsuccess=()=>{const db=request.result;const get=db.transaction('items').objectStore('items').get('key');get.onsuccess=()=>{db.close();resolve(get.result)}}})` }), 'kept');
    assert.equal(browser.tab(normal).pin, true);
    assert.equal(browser.groups[0].name, 'Reading');
  });

  await t.test('agent API rejects unauthenticated, cross-origin, and rebinding requests', async () => {
    server = await startServer(browser);
    const endpoint = `${server.url}/api/command`;
    const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${server.token}` };
    assert.equal((await fetch(endpoint, { method: 'POST', body: '{}' })).status, 401);
    assert.equal((await fetch(endpoint, { method: 'POST', headers: { ...headers, Origin: 'https://other.example' }, body: '{}' })).status, 403);
    // fetch normalizes Host; use the HTTP transport to actually send a forged host.
    const reboundStatus = await new Promise((resolve, reject) => {
      const request = http.request(endpoint, { method: 'POST', headers: { ...headers, Host: 'other.example' } }, response => {
        response.resume();
        resolve(response.statusCode);
      });
      request.on('error', reject);
      request.end('{}');
    });
    assert.equal(reboundStatus, 403);
    const response = await fetch(endpoint, { method: 'POST', headers, body: '{"do":"probe"}' });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).result.engine, 'alternate');
    const injection = await fetch(endpoint, { method: 'POST', headers, body: JSON.stringify({ do: 'go', id: normal, url: 'javascript:alert(1)' }) });
    assert.equal(injection.status, 400);
  });

  await t.test('responsive cloud UI navigates real pages and opens private tabs', async () => {
    const context = await browser.adapter.browser.newContext({ viewport: { width: 1180, height: 780 } });
    const page = await context.newPage();
    const failures = [];
    page.on('pageerror', error => failures.push(error.message));
    await page.goto(`${server.url}/#${server.token}`);
    await page.waitForSelector('#tabs .tab');
    await page.locator('#address').fill(`${url}/ui`);
    await page.locator('#address').press('Enter');
    await page.waitForFunction(() => document.querySelector('#address').value.endsWith('/ui'));
    await page.waitForFunction(() => document.querySelector('#page').naturalWidth > 0);
    await page.locator('#more').click();
    await page.waitForSelector('#library[open]');
    await page.locator('#appearance').selectOption('dark');
    await page.waitForFunction(() => document.documentElement.dataset.look === 'dark');
    await page.locator('#close-library').click();
    await page.locator('#private-tab').click();
    await page.waitForFunction(() => document.querySelector('#tabs .active')?.textContent.includes('◈'));
    const privateID = browser.active;
    await ask({ do: 'close', id: privateID });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator('#sidebar-toggle').click();
    await page.waitForFunction(() => document.body.classList.contains('no-sidebar'));
    const output = path.resolve('test-results');
    await mkdir(output, { recursive: true });
    await page.screenshot({ path: path.join(output, 'mobile.png') });
    await page.setViewportSize({ width: 1180, height: 780 });
    await page.locator('#sidebar-toggle').click();
    await page.waitForFunction(() => !document.body.classList.contains('no-sidebar'));
    await page.screenshot({ path: path.join(output, 'desktop.png') });
    assert.deepEqual(failures, []);
    await context.close();
  });

  await t.test('restart restores normal sessions lazily and keeps storage', async () => {
    const bench = (await ask({ do: 'open', url: `${url}/bench-only`, bench: true })).id;
    await ask({ do: 'select', id: normal });
    await browser.stop();
    const saved = await readFile(path.join(directory, 'browser.json'), 'utf8');
    assert.ok(!saved.includes(bench));
    browser = new Browser({ registry, engine: 'chromium', store: new Store(directory) });
    await browser.start();
    assert.equal(browser.active, normal);
    assert.equal(browser.adapter.pages.size, 1);
    assert.equal(await browser.execute({ do: 'eval', id: normal, js: 'localStorage.getItem("secret")' }), 'normal-only');
    assert.ok(!browser.tabs.some(tab => tab.private || tab.bench));
  });
});
