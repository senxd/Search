import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { writeFile } from 'node:fs/promises';
import { BrowserError, requireFeature } from './contract.js';
import { address, SEARCH_ENGINES, validateURL } from './address.js';
import { hiddenStyle, pageAction, reader } from './page-scripts.js';
import { COMMANDS, parityReport } from './protocol.js';
import { handleFeature, UNHANDLED, restoreCheckpoint } from './features.js';
import { capturePage, restorePage } from './session-state.js';
import { RendererRouter } from './renderer-router.js';

const READ_COMMANDS = new Set(['manifest', 'parity', 'probe', 'tabs', 'engines', 'wait', 'text', 'shot', 'find', 'suggest', 'search-tabs', 'library', 'library-export', 'hidden-list']);

const DEFAULT_FEATURES = ['navigation', 'privateTabs', 'spaces', 'automation', 'screenshots', 'input', 'find', 'reader', 'hiddenElements', 'shield', 'downloads'];

export class Browser extends EventEmitter {
  constructor({ registry, engine, store, engineOptions = {}, liveRouting = false }) {
    super();
    this.registry = registry;
    this.engine = engine;
    this.engineOptions = engineOptions;
    this.liveRouting = liveRouting;
    this.store = store;
    this.tabs = [];
    this.active = null;
    this.closed = [];
    this.closedGroups = [];
    this.groups = [];
    this.spaces = [{ id: 'default', name: 'Main', store: 'default' }];
    this.space = 'default';
    this.bookmarks = [];
    this.history = [];
    this.hidden = {};
    this.settings = { sidebar: true, look: 'system', search: SEARCH_ENGINES.google, shield: true, pausedHosts: [], autoSleep: true, sleepMinutes: 30, sideHides: false, readProgress: true };
    this.required = new Set(DEFAULT_FEATURES);
    this.queue = Promise.resolve();
    this.stopping = false;
  }

  async start() {
    const saved = await this.store?.read();
    if (saved) {
      if (this.liveRouting && saved.engine) this.engine = saved.engine;
      for (const key of ['spaces', 'space', 'bookmarks', 'history', 'hidden', 'settings', 'groups']) {
        if (saved[key] !== undefined) this[key] = key === 'settings' ? { ...this.settings, ...saved[key] } : saved[key];
      }
      this.tabs = saved.tabs.map(tab => ({ ...tab, loading: false, sleeping: true, failure: null, private: false, bench: false }));
      this.active = saved.active;
      for (const feature of saved.required || []) this.required.add(feature);
    }
    this.adapter = this.registry.create(this.engine, this.engineOptions);
    for (const feature of this.required) requireFeature(this.adapter, feature);
    if (this.liveRouting) this.adapter = new RendererRouter(this.registry, this.adapter, this.engineOptions);
    await this.adapter.start(this.callbacks());
    if (this.tabs.length === 0) await this.open({ url: 'about:blank' });
    else await this.select(this.active && this.tabs.some(tab => tab.id === this.active) ? this.active : this.tabs[0].id);
    await this.persist();
    this.sleepTimer = setInterval(() => {
      if (this.settings.autoSleep && !this.stopping) this.execute({ do: 'sleep-idle' }).catch(error => this.emit('notice', error.message));
    }, 60000);
    this.sleepTimer.unref();
    return this;
  }

  callbacks() {
    return {
      changed: (id, fields) => {
        const tab = this.tabs.find(item => item.id === id);
        if (!tab || this.stopping) return;
        const previous = tab.url;
        Object.assign(tab, fields);
        if (fields.url && fields.url !== previous) tab.reader = false;
        if (fields.loading === false && !tab.private && !tab.bench && /^https?:/.test(tab.url)) {
          this.history = [{ url: tab.url, title: tab.title, at: Date.now() }, ...this.history.filter(item => item.url !== tab.url)].slice(0, 2000);
        }
        this.emit('changed', this.snapshot());
      },
      popup: url => { this.execute({ do: 'open', url }).catch(error => this.emit('notice', error.message)); },
      storageKey: tab => this.spaces.find(space => space.id === tab.space)?.store || tab.space,
      state: () => this.snapshot(),
      command: request => this.execute(request),
      hiddenRules: () => structuredClone(this.hidden),
      pausedHosts: () => [...this.settings.pausedHosts],
      hidden: url => {
        try { return this.hidden[new URL(url).hostname] || []; } catch { return []; }
      },
      shield: url => {
        try { return this.settings.shield && !this.settings.pausedHosts.includes(new URL(url).hostname); } catch { return this.settings.shield; }
      },
      picked: (id, selector) => this.execute({ do: 'hide', id, selector }).catch(error => this.emit('notice', error.message)),
      download: item => {
        this.downloads ||= [];
        const previous = this.downloads.find(download => download.id === item.id);
        if (previous) Object.assign(previous, item);
        else this.downloads.unshift({ id: item.id || randomUUID(), at: Date.now(), private: this.tabs.find(tab => tab.id === item.tab)?.private === true, ...item });
        this.emit('download', item);
      },
    };
  }

  snapshot() {
    return {
      version: 1, engine: this.engine, capabilities: this.adapter?.capabilities || {},
      required: [...this.required], active: this.active, space: this.space,
      tabs: this.tabs.map(({ resume, ...tab }) => ({ ...tab })), groups: structuredClone(this.groups),
      spaces: structuredClone(this.spaces), bookmarks: structuredClone(this.bookmarks),
      history: structuredClone(this.history), settings: structuredClone(this.settings),
      downloads: structuredClone((this.downloads || []).filter(item => !item.private)),
      extensions: this.adapter?.extensionService?.list() || [],
    };
  }

  async persist() {
    if (!this.store) return;
    const tabs = this.tabs.filter(tab => !tab.private && !tab.bench).map(({ id, url, title, pin, group, space, name, zoom, engine }) => ({ id, url, title, pin, group, space, name, zoom, engine }));
    await this.store.write({ ...this.snapshot(), capabilities: undefined, tabs,
      active: tabs.some(tab => tab.id === this.active) ? this.active : tabs[0]?.id ?? null,
      hidden: this.hidden, downloads: undefined,
    });
  }

  tab(id = this.active) {
    if (typeof id !== 'string') throw new BrowserError('TAB_NOT_FOUND', 'No tab selected');
    const matches = this.tabs.filter(tab => tab.id === id || tab.id.startsWith(id));
    if (matches.length !== 1) throw new BrowserError('TAB_NOT_FOUND', `Unknown or ambiguous tab: ${id}`);
    return matches[0];
  }
  downloadTab(r) {
    if (!r.downloadId) return this.tab(r.id).id;
    const download = (this.downloads || []).find(item => item.id === r.downloadId);
    if (!download) throw new BrowserError('NO_DOWNLOAD', 'Unknown download');
    return download.tab;
  }

  async ensure(tab) {
    if (tab.sleeping) {
      await this.adapter.create(tab);
      await restoreCheckpoint(this, tab);
      tab.sleeping = false;
    }
    return tab;
  }

  async open({ url = 'about:blank', private: isPrivate = false, bench = false, select = !bench, space = this.space } = {}) {
    if (!this.spaces.some(item => item.id === space)) throw new BrowserError('SPACE_NOT_FOUND', 'Unknown space');
    if (isPrivate) requireFeature(this.adapter, 'privateTabs');
    const tab = {
      id: randomUUID(), url: validateURL(url), title: '', private: Boolean(isPrivate), bench: Boolean(bench),
      sleeping: true, loading: false, failure: null, pin: false, group: null, space,
      lastActive: Date.now(),
    };
    this.tabs.push(tab);
    try {
      if (select) await this.select(tab.id);
      else await this.ensure(tab);
      return { id: tab.id };
    } catch (error) {
      this.tabs = this.tabs.filter(item => item.id !== tab.id);
      await this.adapter.close(tab.id).catch(() => {});
      throw error;
    }
  }

  async select(id) {
    const tab = this.tab(id);
    await this.ensure(tab);
    this.active = tab.id;
    tab.lastActive = Date.now();
    this.space = tab.space;
    await this.adapter.activate(tab.id);
    return { id: tab.id };
  }

  async close(id) {
    const tab = this.tab(id);
    await this.adapter.close(tab.id);
    this.tabs = this.tabs.filter(item => item !== tab);
    if (tab.private) this.downloads = (this.downloads || []).filter(item => item.tab !== tab.id);
    if (!tab.private && !tab.bench) this.closed.unshift({ ...tab, sleeping: true });
    this.closed = this.closed.slice(0, 25);
    if (this.active === tab.id) {
      this.active = null;
      const next = this.tabs.find(item => item.space === this.space && !item.bench) || this.tabs.find(item => !item.bench);
      if (next) await this.select(next.id);
      else if (!this.stopping) await this.open();
    }
    return { ok: true };
  }

  execute(request) {
    const operation = this.queue.then(async () => {
      if (!request || typeof request.do !== 'string') throw new BrowserError('INVALID_COMMAND', 'A command needs a do field');
      const result = await this.dispatch(request);
      if (!READ_COMMANDS.has(request.do)) await this.persist();
      this.emit('changed', this.snapshot());
      return result;
    });
    this.queue = operation.catch(() => {});
    return operation;
  }

  async dispatch(r) {
    const feature = await handleFeature(this, r);
    if (feature !== UNHANDLED) return feature;
    switch (r.do) {
      case 'manifest': return { version: 1, commands: COMMANDS, engines: this.registry.list() };
      case 'parity': return parityReport(this.adapter);
      case 'probe': return this.snapshot();
      case 'tabs': return this.snapshot().tabs;
      case 'engines': return this.registry.list();
      case 'renderer-map': return this.adapter.mapping?.() || this.tabs.filter(tab => !tab.sleeping).map(tab => ({ id: tab.id, engine: this.engine }));
      case 'renderer-set': {
        if (!this.adapter.selectRenderer) throw new BrowserError('FEATURE_UNAVAILABLE', 'This host cannot route live tabs across renderers');
        const result = await this.adapter.selectRenderer(r.engine, [...this.required]);
        this.engine = r.engine;
        return result;
      }
      case 'require':
        if (!Array.isArray(r.features) || r.features.some(feature => typeof feature !== 'string')) throw new BrowserError('INVALID_COMMAND', 'features must be an array of capability names');
        this.adapter.requireFeatures?.(r.features);
        for (const feature of r.features || []) requireFeature(this.adapter, feature);
        for (const feature of r.features || []) this.required.add(feature);
        return { required: [...this.required] };
      case 'engine': return this.swap(r.engine, r.reload === true);
      case 'open': return this.open(r);
      case 'select': return this.select(r.id);
      case 'close':
        if (r.id === 'all') {
          // Agent-owned tabs only. Never close the user's browsing session.
          for (const tab of [...this.tabs].filter(tab => tab.bench)) await this.close(tab.id);
          return { ok: true };
        }
        return this.close(r.id);
      case 'reopen': {
        const tab = this.closed.shift();
        if (!tab) return { ok: false };
        if (!this.spaces.some(space => space.id === tab.space)) { tab.space = this.space; tab.group = null; }
        this.tabs.push(tab);
        await this.select(tab.id);
        return { id: tab.id };
      }
      case 'go': {
        const tab = await this.ensure(this.tab(r.id));
        const url = r.text === undefined ? validateURL(r.url) : address(r.text, this.settings.search);
        await this.adapter.navigate(tab.id, url);
        tab.url = url;
        tab.reader = false;
        return { id: tab.id, url };
      }
      case 'back': case 'forward': case 'reload': {
        const tab = await this.ensure(this.tab(r.id));
        await this.adapter[r.do](tab.id);
        tab.reader = false;
        return { ok: true };
      }
      case 'wait': {
        const tab = await this.ensure(this.tab(r.id));
        const deadline = Date.now() + Math.min(60, Math.max(0, r.seconds ?? 20)) * 1000;
        let state;
        do {
          state = await this.adapter.inspect(tab.id);
          Object.assign(tab, state);
          if (!state.loading) return { ...state, timeout: false };
          await new Promise(resolve => setTimeout(resolve, 50));
        } while (Date.now() < deadline);
        return { ...state, timeout: true };
      }
      case 'text': case 'eval': case 'click': case 'type': case 'submit': case 'reader': case 'hide': {
        const tab = await this.ensure(this.tab(r.id));
        if (r.do === 'text') return this.adapter.evaluate(tab.id, () => document.body.innerText.slice(0, 120000));
        if (r.do === 'eval') {
          requireFeature(this.adapter, 'automation');
          if (typeof r.js !== 'string') throw new BrowserError('INVALID_COMMAND', 'eval requires a JavaScript string');
          return this.adapter.evaluate(tab.id, r.js);
        }
        if (r.do === 'reader') {
          requireFeature(this.adapter, 'reader');
          if (tab.reader) { await this.adapter.reload(tab.id); tab.reader = false; }
          else tab.reader = await this.adapter.evaluate(tab.id, reader);
          return { reader: tab.reader };
        }
        if (r.do === 'hide') {
          requireFeature(this.adapter, 'hiddenElements');
          if (typeof r.selector !== 'string' || r.selector.length > 2000 || /[{}]/.test(r.selector)) throw new BrowserError('INVALID_SELECTOR', 'Invalid CSS selector');
          await this.adapter.evaluate(tab.id, selector => document.querySelector(selector) !== null, r.selector);
          const host = new URL(tab.url).hostname;
          const selectors = [...new Set([...(this.hidden[host] || []), r.selector])];
          await this.adapter.evaluate(tab.id, hiddenStyle, { selectors });
          // Private browsing changes the current page only.
          if (!tab.private) this.hidden[host] = selectors;
          if (!tab.private) await this.adapter.refreshPolicies?.();
          return { ok: true };
        }
        requireFeature(this.adapter, 'automation');
        return this.adapter.evaluate(tab.id, pageAction, { action: r.do, selector: r.selector, text: r.text });
      }
      case 'shot': {
        requireFeature(this.adapter, 'screenshots');
        const tab = await this.ensure(this.tab(r.id));
        const image = await this.adapter.screenshot(tab.id);
        if (r.path) { await writeFile(r.path, image, { mode: 0o600 }); return { path: r.path }; }
        return { mime: 'image/png', base64: image.toString('base64') };
      }
      case 'input': {
        requireFeature(this.adapter, 'input');
        const tab = await this.ensure(this.tab(r.id));
        return this.adapter.input(tab.id, r);
      }
      case 'tap': {
        requireFeature(this.adapter, 'input');
        const tab = await this.ensure(this.tab(r.id));
        if (typeof r.selector !== 'string') throw new BrowserError('INVALID_SELECTOR', 'tap requires a selector');
        const point = await this.adapter.evaluate(tab.id, selector => {
          const element = selector.startsWith('text=') ? [...document.querySelectorAll('button,a,[role="button"]')].find(element => element.textContent.trim() === selector.slice(5)) : document.querySelector(selector);
          if (!element) throw new Error('No matching element');
          element.scrollIntoView({ block: 'center', inline: 'center' });
          const rect = element.getBoundingClientRect(); return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
        }, r.selector);
        await this.adapter.input(tab.id, { kind: 'click', ...point });
        return { ok: true, at: [point.x, point.y] };
      }
      case 'key': return this.dispatch({ do: 'input', id: r.id, kind: r.key ? 'key' : 'text', key: r.key, text: r.text });
      case 'resize': return this.dispatch({ do: 'bounds', width: r.width, height: r.height });
      case 'find': {
        requireFeature(this.adapter, 'find');
        const tab = await this.ensure(this.tab(r.id));
        return this.adapter.find(tab.id, String(r.text ?? ''), r.backward === true);
      }
      case 'download-save': {
        requireFeature(this.adapter, 'downloads');
        if (typeof r.path !== 'string') throw new BrowserError('INVALID_COMMAND', 'Download saving requires an explicit output path');
        const tab = this.downloadTab(r);
        const result = await this.adapter.saveDownload(tab, r.path, r.downloadId);
        const items = (this.downloads || []).filter(item => r.downloadId ? item.id === r.downloadId : item.tab === tab).slice(0, 1);
        for (const item of items) Object.assign(item, { state: 'saved', path: r.path });
        return result;
      }
      case 'devtools': case 'print': {
        requireFeature(this.adapter, r.do === 'print' ? 'printing' : 'devtools');
        const tab = await this.ensure(this.tab(r.id));
        return this.adapter[r.do](tab.id);
      }
      case 'bounds':
        if (![r.width, r.height].every(n => Number.isFinite(n) && n >= 100 && n <= 4096)) throw new BrowserError('INVALID_BOUNDS', 'Viewport dimensions must be between 100 and 4096');
        await this.adapter.setBounds({ width: Math.round(r.width), height: Math.round(r.height) });
        return { ok: true };
      case 'pin': {
        const tab = this.tab(r.id);
        tab.pin = r.on ?? !tab.pin;
        return { ok: true };
      }
      case 'bookmark': {
        const tab = this.tab(r.id);
        if (tab.private) throw new BrowserError('PRIVATE_TAB', 'Bookmark a normal tab to save its address');
        this.bookmarks = [{ url: tab.url, title: tab.title }, ...this.bookmarks.filter(item => item.url !== tab.url)];
        return { ok: true };
      }
      case 'bookmark-remove':
        this.bookmarks = this.bookmarks.filter(item => item.url !== r.url);
        return { ok: true };
      case 'history-clear': this.history = []; return { ok: true };
      default:
        throw new BrowserError('UNKNOWN_COMMAND', `Unknown command: ${r.do}`);
    }
  }

  async swap(engine, reload) {
    if (engine === this.engine) return { engine, changed: false };
    const candidate = this.registry.create(engine, this.engineOptions);
    // Do all static checks before touching the live renderer.
    for (const feature of this.required) requireFeature(candidate, feature);
    if (!reload) throw new BrowserError('RELOAD_REQUIRED', 'Use renderer-set to keep live tabs in place, or reload:true to migrate pages with loss of their JavaScript runtime, navigation history, and media playback.');
    requireFeature(this.adapter, 'storageTransfer');
    requireFeature(candidate, 'storageTransfer');
    const previous = this.adapter;
    const state = await previous.exportState();
    const checkpoints = new Map();
    for (const tab of this.tabs.filter(tab => !tab.sleeping)) {
      const checkpoint = await previous.evaluate(tab.id, capturePage);
      if (checkpoint.busy) throw new BrowserError('ENGINE_BUSY', checkpoint.reason);
      checkpoints.set(tab.id, checkpoint);
    }
    // Candidate callbacks are muted until commit; failure leaves the old host alive.
    try {
      await candidate.start({ ...this.callbacks(), changed: () => {}, popup: () => {}, download: () => {}, picked: () => {} });
      await candidate.importState(state);
      for (const tab of this.tabs.filter(tab => !tab.sleeping)) {
        await candidate.create(tab);
        await candidate.evaluate(tab.id, restorePage, checkpoints.get(tab.id));
      }
      if (this.active) await candidate.activate(this.active);
    } catch (error) {
      await candidate.stop({ persist: false }).catch(() => {});
      throw new BrowserError('ENGINE_SWAP_FAILED', error.message);
    }
    this.adapter = this.liveRouting ? new RendererRouter(this.registry, candidate, this.engineOptions) : candidate;
    this.engine = engine;
    if (this.liveRouting) {
      for (const tab of this.tabs) { tab.engine = engine; if (!tab.sleeping) this.adapter.owners.set(tab.id, engine); }
    }
    this.adapter.setCallbacks(this.callbacks());
    await previous.stop({ persist: false });
    for (const tab of this.tabs.filter(tab => !tab.sleeping)) Object.assign(tab, await candidate.inspect(tab.id), { reader: false });
    return { engine, changed: true, reloaded: true };
  }

  async stop() {
    clearInterval(this.sleepTimer);
    await this.queue;
    this.stopping = true;
    try { await this.persist(); } finally { await this.adapter?.stop(); }
  }
}
