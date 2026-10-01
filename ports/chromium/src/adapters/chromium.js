import { chromium, firefox, webkit } from 'playwright-core';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { CONTRACT_VERSION, BrowserError } from '../contract.js';
import { hiddenStyle, shouldBlock } from '../page-scripts.js';
import { policyBootstrap, policyFor, elementPicker } from '../page-policy.js';

export class PlaywrightAdapter {
  constructor({ id = 'chromium', kind = 'chromium', executablePath, directory, headless = true } = {}) {
    this.id = id;
    this.version = CONTRACT_VERSION;
    this.capabilities = Object.freeze({
      navigation: true, privateTabs: true, spaces: true, cookies: true,
      storageTransfer: true, automation: true, screenshots: true, input: true,
      find: true, reader: true, hiddenElements: true, shield: true, downloads: true,
      devtools: false, printing: false, extensions: false, passwords: false,
      passkeys: false, pictureInPicture: false, nativeMessaging: false, signedUpdates: false,
    });
    this.executablePath = executablePath;
    this.kind = kind;
    this.browserType = { chromium, firefox, webkit }[kind];
    if (!this.browserType) throw new BrowserError('INVALID_ENGINE', `Unsupported Playwright engine: ${kind}`);
    this.directory = directory;
    this.headless = headless;
    this.contexts = new Map();
    this.pages = new Map();
    this.metadata = new Map();
    this.downloads = new Map();
    this.storage = {};
    this.viewport = { width: 1100, height: 720 };
    this.policyRevision = 0;
  }

  setCallbacks(callbacks) { this.callbacks = callbacks; }

  async start(callbacks) {
    this.setCallbacks(callbacks);
    if (this.directory) {
      try {
        this.storage = JSON.parse(await readFile(path.join(this.directory, 'chromium-state.json'), 'utf8'));
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    this.browser = await this.browserType.launch({
      executablePath: this.executablePath, headless: this.headless,
      chromiumSandbox: process.env.SEARCH_CHROMIUM_SANDBOX !== 'off',
      env: { ...process.env,
        XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME || path.resolve(this.directory || '.profile', 'config'),
        XDG_CACHE_HOME: process.env.XDG_CACHE_HOME || path.resolve(this.directory || '.profile', 'cache'),
      },
    });
  }

  async context(tab) {
    const key = tab.private ? `private:${tab.id}` : `space:${this.callbacks.storageKey?.(tab) || tab.space}`;
    if (this.contexts.has(key)) return this.contexts.get(key);
    const context = await this.browser.newContext({
      viewport: this.viewport,
      storageState: this.storage[key],
      acceptDownloads: true,
      serviceWorkers: 'allow',
    });
    await context.route('**/*', async route => {
      let firstParty = '';
      try {
        const request = route.request();
        if (!request.isNavigationRequest()) firstParty = request.frame().page().url();
      } catch {
        firstParty = route.request().serviceWorker()?.url() || '';
      }
      if (firstParty && shouldBlock(route.request().url(), firstParty, this.callbacks.shield(firstParty))) await route.abort();
      else await route.continue();
    });
    this.contexts.set(key, context);
    return context;
  }

  page(id) {
    const page = this.pages.get(id);
    if (!page) throw new BrowserError('TAB_NOT_FOUND', `Renderer has no tab ${id}`);
    return page;
  }

  async create(tab) {
    const context = await this.context(tab);
    const page = await context.newPage();
    this.pages.set(tab.id, page);
    this.metadata.set(tab.id, { ...tab, failure: null });
    page.on('popup', popup => {
      popup.once('domcontentloaded', () => {
        this.callbacks.popup(popup.url());
        popup.close().catch(() => {});
      });
    });
    const update = async loading => {
      try { this.callbacks.changed(tab.id, { ...await this.inspect(tab.id), loading }); } catch { /* Closing tab. */ }
    };
    page.on('domcontentloaded', () => {
      page.evaluate(policyBootstrap, policyFor(this.callbacks, ++this.policyRevision)).catch(() => {});
      update(false);
    });
    page.on('framenavigated', frame => { if (frame === page.mainFrame()) update(true); });
    page.on('load', () => update(false));
    page.on('crash', () => this.callbacks.changed(tab.id, { loading: false, failure: 'Renderer process crashed' }));
    page.on('download', download => {
      // Downloads remain in Chromium's temporary area until explicitly saved.
      // Do not trust a site's suggested filename as an output path.
      const id = randomUUID(); this.downloads.set(id, { tab: tab.id, download });
      this.callbacks.download({ id, tab: tab.id, name: download.suggestedFilename(), state: 'awaiting-save' });
      this.metadata.get(tab.id).downloadId = id;
    });
    await page.addInitScript(policyBootstrap, policyFor(this.callbacks, ++this.policyRevision));
    const runtime = this.runtime?.[tab.id];
    if (runtime) await page.addInitScript(({ origin, entries }) => {
      if (location.origin === origin) {
        for (const [key, value] of Object.entries(entries)) sessionStorage.setItem(key, value);
      }
    }, runtime);
    await this.navigate(tab.id, tab.url);
  }

  async navigate(id, url) {
    const metadata = this.metadata.get(id);
    metadata.url = url;
    metadata.failure = null;
    this.callbacks.changed(id, { url, loading: true, failure: null });
    try {
      await this.page(id).goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });
    } catch (error) {
      metadata.failure = error.message;
      this.callbacks.changed(id, { url, loading: false, failure: error.message });
      // A navigation failure is page state, not a broken browser installation.
    }
    this.callbacks.changed(id, await this.inspect(id));
  }

  async inspect(id) {
    const page = this.page(id);
    const state = await page.evaluate(() => ({ loading: document.readyState === 'loading', title: document.title })).catch(() => ({ loading: true, title: '' }));
    const metadata = this.metadata.get(id);
    return { ...state, url: metadata.failure ? metadata.url : page.url(), failure: metadata.failure };
  }
  async evaluate(id, script, argument) { return this.page(id).evaluate(script, argument); }
  async zoom(id, value) { await this.page(id).evaluate(value => { document.documentElement.style.zoom = value; }, value); }
  async refreshPolicies() {
    const policy = policyFor(this.callbacks, ++this.policyRevision);
    for (const page of this.pages.values()) {
      await page.addInitScript(policyBootstrap, policy);
      await page.evaluate(policyBootstrap, policy);
    }
  }
  async applyStyles(id, selectors) { await this.page(id).evaluate(hiddenStyle, { selectors }); }
  async pickHide(id) {
    const state = await this.page(id).evaluate(elementPicker);
    if (state.picking) {
      const timer = setInterval(async () => {
        const result = await this.page(id).evaluate(() => ({ live: window.__searchPicker?.live, selection: window.__searchPicker?.selection })).catch(() => ({ live: false }));
        if (!result.live) { clearInterval(timer); if (result.selection) this.callbacks.picked(id, result.selection.selector); }
      }, 100);
      timer.unref();
      setTimeout(() => clearInterval(timer), 90000).unref();
    }
    return state;
  }
  async back(id) { await this.page(id).goBack({ waitUntil: 'domcontentloaded' }); }
  async forward(id) { await this.page(id).goForward({ waitUntil: 'domcontentloaded' }); }
  async reload(id) { await this.page(id).reload({ waitUntil: 'domcontentloaded' }); }
  async activate(id) { await this.page(id).bringToFront(); }
  async setBounds(bounds) {
    this.viewport = bounds;
    for (const page of this.pages.values()) await page.setViewportSize(bounds);
  }
  async screenshot(id) { return this.page(id).screenshot({ type: 'png' }); }
  async find(id, text, backward) {
    return { found: await this.page(id).evaluate(({ text, backward }) => window.find(text, false, backward), { text, backward }) };
  }
  async input(id, event) {
    const page = this.page(id);
    if (event.kind === 'click') await page.mouse.click(Number(event.x), Number(event.y), { button: event.button || 'left' });
    else if (event.kind === 'wheel') await page.mouse.wheel(Number(event.dx || 0), Number(event.dy || 0));
    else if (event.kind === 'text') await page.keyboard.insertText(String(event.text));
    else if (event.kind === 'key') await page.keyboard.press(String(event.key));
    else throw new BrowserError('INVALID_INPUT', 'Unknown input event');
    return { ok: true };
  }
  async saveDownload(id, destination, downloadId = this.metadata.get(id)?.downloadId) {
    const download = this.downloads.get(downloadId)?.download;
    if (!download) throw new BrowserError('NO_DOWNLOAD', 'No download awaits saving in this tab');
    await download.saveAs(destination);
    return { path: destination };
  }
  async downloadBytes(id, downloadId = this.metadata.get(id)?.downloadId) {
    const download = this.downloads.get(downloadId)?.download;
    if (!download) throw new BrowserError('NO_DOWNLOAD', 'No download awaits saving');
    const filename = await download.path();
    const bytes = await readFile(filename);
    if (bytes.length > 64 * 1024 * 1024) throw new BrowserError('DOWNLOAD_TOO_LARGE', 'Use download-save for files over 64 MB');
    return { name: download.suggestedFilename(), base64: bytes.toString('base64') };
  }
  async exportState() {
    const contexts = {};
    const runtime = {};
    for (const [key, context] of this.contexts) contexts[key] = await context.storageState({ indexedDB: true });
    for (const [id, page] of this.pages) {
      runtime[id] = await page.evaluate(() => ({ origin: location.origin, entries: Object.fromEntries(Object.entries(sessionStorage)) })).catch(() => null);
    }
    return { format: 'playwright-storage-v1', contexts: { ...this.storage, ...contexts }, runtime };
  }
  async importState(state) {
    if (state.format !== 'playwright-storage-v1') throw new BrowserError('INCOMPATIBLE_STORAGE', 'This engine cannot import the source storage format');
    this.storage = state.contexts;
    this.runtime = state.runtime;
  }
  async close(id) {
    const page = this.pages.get(id);
    const metadata = this.metadata.get(id);
    this.pages.delete(id);
    this.metadata.delete(id);
    await page?.close();
    if (metadata?.private) {
      for (const [downloadId, entry] of this.downloads) if (entry.tab === id) { await entry.download.delete().catch(() => {}); this.downloads.delete(downloadId); }
      const key = `private:${id}`;
      await this.contexts.get(key)?.close();
      this.contexts.delete(key);
      delete this.storage[key];
    }
  }
  async stop({ persist = true } = {}) {
    if (!this.browser) return;
    if (this.directory && persist) {
      const state = await this.exportState();
      const normal = Object.fromEntries(Object.entries(state.contexts).filter(([key]) => !key.startsWith('private:')));
      await mkdir(this.directory, { recursive: true, mode: 0o700 });
      const temporary = path.join(this.directory, `chromium-state-${this.id}.tmp`);
      await writeFile(temporary, JSON.stringify(normal), { mode: 0o600 });
      await rename(temporary, path.join(this.directory, 'chromium-state.json'));
    }
    await this.browser.close();
    this.browser = null;
  }
}

export class ChromiumAdapter extends PlaywrightAdapter {
  constructor(options = {}) {
    super({ executablePath: process.env.SEARCH_CHROMIUM_PATH || '/usr/bin/chromium', ...options, kind: 'chromium' });
  }
}
