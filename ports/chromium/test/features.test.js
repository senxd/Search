import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { Browser } from '../src/browser.js';
import { EngineRegistry } from '../src/contract.js';
import { ChromiumAdapter } from '../src/adapters/chromium.js';
import { Store } from '../src/store.js';
import { BLOCKED_HOSTS } from '../src/page-scripts.js';

test('portable feature parity uses real pages and preserves safe page state', async t => {
  let trackerRequests = 0;
  const fixture = http.createServer((request, response) => {
    if (request.url === '/sw-track') { trackerRequests++; response.setHeader('Access-Control-Allow-Origin', '*'); response.end('reached'); return; }
    if (request.url === '/worker.js') {
      response.setHeader('Content-Type', 'text/javascript');
      response.end(`self.addEventListener('install',()=>self.skipWaiting());self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));self.addEventListener('message',event=>{fetch('http://localhost:${fixture.address().port}/sw-track').then(()=>event.source.postMessage('reached')).catch(()=>event.source.postMessage('blocked'))});`); return;
    }
    response.setHeader('Content-Type', 'text/html');
    response.end(`<title>Feature fixture</title><div id="banner">Banner</div><div class="adsbygoogle">Advertisement</div><input id="ordinary"><input type="password" id="password"><select id="choice"><option>One</option><option>Two</option></select><script>window.prepaint=getComputedStyle(document.querySelector('#banner')).display;</script><article><p>${'Article words. '.repeat(60)}</p><p>${'More article words. '.repeat(60)}</p><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-src="/actual.svg"></article><div style="height:3000px"></div>`);
  });
  await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${fixture.address().port}`;
  const directory = await mkdtemp(path.join(os.tmpdir(), 'search-features-'));
  const registry = new EngineRegistry();
  for (const id of ['chromium', 'other']) registry.register(id, () => new ChromiumAdapter({ id, directory }));
  const browser = new Browser({ registry, engine: 'chromium', store: new Store(directory) });
  await browser.start();
  t.after(async () => { await browser.stop(); await new Promise(resolve => fixture.close(resolve)); await rm(directory, { recursive: true, force: true }); BLOCKED_HOSTS.delete('localhost'); });
  const ask = request => browser.execute(request);
  const first = (await ask({ do: 'open', url: `${url}/first` })).id;

  await t.test('autocomplete, tab search, reorder, rename, duplicate, and library edits/import/export', async () => {
    await ask({ do: 'bookmark', id: first });
    await ask({ do: 'bookmark-edit', url: `${url}/first`, title: 'A saved reading' });
    assert.equal((await ask({ do: 'library', text: 'saved' }))[0].title, 'A saved reading');
    assert.ok((await ask({ do: 'suggest', text: '/first' })).some(item => item.url === `${url}/first`));
    await ask({ do: 'rename', id: first, name: 'Research' });
    assert.ok((await ask({ do: 'search-tabs', text: 'fixture' })).some(tab => tab.id === first));
    const copy = (await ask({ do: 'duplicate', id: first })).id;
    await ask({ do: 'place', id: copy, index: 0 }); assert.equal(browser.tabs[0].id, copy);
    await ask({ do: 'library-import', data: { bookmarks: [{ url: `${url}/imported`, title: 'Imported' }] } });
    assert.ok((await ask({ do: 'library-export' })).bookmarks.some(item => item.title === 'Imported'));
    await ask({ do: 'close', id: copy }); await ask({ do: 'select', id: first });
  });

  await t.test('sleep restores ordinary forms, selection, session storage, and scroll; secret fields refuse sleep', async () => {
    await ask({ do: 'type', id: first, selector: '#ordinary', text: 'Keep this form' });
    await ask({ do: 'eval', id: first, js: 'document.querySelector("#choice").selectedIndex=1;sessionStorage.setItem("kept","yes");scrollTo(0,400)' });
    const second = (await ask({ do: 'open', url: `${url}/second` })).id;
    await ask({ do: 'sleep', id: first }); assert.equal(browser.tab(first).sleeping, true);
    assert.ok(!JSON.stringify(browser.snapshot()).includes('Keep this form'));
    await ask({ do: 'select', id: first });
    assert.equal(await ask({ do: 'eval', id: first, js: 'document.querySelector("#ordinary").value' }), 'Keep this form');
    assert.equal(await ask({ do: 'eval', id: first, js: 'document.querySelector("#choice").selectedIndex' }), 1);
    assert.equal(await ask({ do: 'eval', id: first, js: 'sessionStorage.getItem("kept")' }), 'yes');
    await browser.adapter.page(first).waitForFunction(() => scrollY >= 390);
    await ask({ do: 'type', id: first, selector: '#password', text: 'fake-only' });
    await ask({ do: 'select', id: second });
    await assert.rejects(ask({ do: 'sleep', id: first }), { code: 'TAB_BUSY' });
    await assert.rejects(ask({ do: 'engine', engine: 'other', reload: true }), { code: 'ENGINE_BUSY' });
    await ask({ do: 'eval', id: first, js: 'document.querySelector("#password").value=""' });
    await ask({ do: 'select', id: first });
  });

  await t.test('group colour/icon, close/reopen, and shared or fresh spaces preserve identities', async () => {
    const group = await ask({ do: 'group', action: 'new', id: first, name: 'Work' });
    await ask({ do: 'group', action: 'colour', group: group.id, colour: 'blue' });
    await ask({ do: 'group', action: 'icon', group: group.id, icon: '◆' });
    const second = await ask({ do: 'group', action: 'newtab', group: group.id });
    await ask({ do: 'group', action: 'close', group: group.id });
    assert.ok(!browser.tabs.some(tab => tab.id === first || tab.id === second.id));
    await ask({ do: 'group', action: 'reopen' });
    assert.equal(browser.groups.find(item => item.id === group.id).colour, 'blue');
    assert.equal(browser.tab(second.id).group, group.id);
    await ask({ do: 'select', id: first });
    await ask({ do: 'eval', id: first, js: 'localStorage.setItem("shared","kept")' });
    const shared = await ask({ do: 'space', action: 'new', name: 'Shared' });
    await ask({ do: 'go', url: `${url}/shared` });
    assert.equal(await ask({ do: 'eval', js: 'localStorage.getItem("shared")' }), 'kept');
    await ask({ do: 'space', action: 'new', name: 'Fresh', fresh: true });
    await ask({ do: 'go', url: `${url}/fresh` });
    assert.equal(await ask({ do: 'eval', js: 'localStorage.getItem("shared")' }), null);
    await ask({ do: 'space', action: 'delete' }); assert.equal(browser.spaces.some(space => space.name === 'Fresh'), false);
    await ask({ do: 'space', action: 'rename', id: shared.id, name: 'Renamed' });
    await ask({ do: 'select', id: first });
  });

  await t.test('hidden and cosmetic styles run before page scripts, and the picker/unhide API works', async () => {
    await ask({ do: 'hide', id: first, selector: '#banner' });
    const next = (await ask({ do: 'open', url: `${url}/next` })).id;
    assert.equal(await ask({ do: 'eval', id: next, js: 'window.prepaint' }), 'none');
    assert.equal(await ask({ do: 'eval', id: next, js: 'getComputedStyle(document.querySelector(".adsbygoogle")).display' }), 'none');
    await ask({ do: 'unhide', id: next, selector: '#banner' });
    assert.notEqual(await ask({ do: 'eval', id: next, js: 'getComputedStyle(document.querySelector("#banner")).display' }), 'none');
    await ask({ do: 'pick-hide', id: next });
    await browser.adapter.page(next).locator('#banner').click();
    await browser.adapter.page(next).waitForFunction(() => getComputedStyle(document.querySelector('#banner')).display === 'none');
    assert.ok((await ask({ do: 'hidden-list', id: next })).selectors.includes('#banner'));
    await ask({ do: 'reader', id: next });
    assert.equal(await ask({ do: 'eval', id: next, js: 'document.querySelector("#search-reader img").src' }), `${url}/actual.svg`);
    await ask({ do: 'reader', id: next });
  });

  await t.test('service workers work and their third-party network requests obey shield settings', async () => {
    BLOCKED_HOSTS.add('localhost');
    const tab = browser.active;
    await ask({ do: 'eval', id: tab, js: 'navigator.serviceWorker.register("/worker.js")' });
    await browser.adapter.page(tab).waitForFunction(() => navigator.serviceWorker.controller !== null);
    const probe = () => ask({ do: 'eval', id: tab, js: 'new Promise(resolve=>{navigator.serviceWorker.addEventListener("message",event=>resolve(event.data),{once:true});navigator.serviceWorker.controller.postMessage("probe")})' });
    assert.equal(await probe(), 'blocked'); assert.equal(trackerRequests, 0);
    await ask({ do: 'shield-site', id: tab, on: false });
    assert.equal(await probe(), 'reached'); assert.equal(trackerRequests, 1);
    await ask({ do: 'shield-site', id: tab, on: true });
    BLOCKED_HOSTS.delete('localhost');
  });
});
