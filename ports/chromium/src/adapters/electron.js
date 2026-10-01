import { WebContentsView, BrowserWindow, session, ipcMain, safeStorage, dialog, Menu, clipboard } from 'electron';
import { BrowserError, CONTRACT_VERSION } from '../contract.js';
import { shouldBlock, hiddenStyle } from '../page-scripts.js';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm, chmod, copyFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { policyBootstrap, policyFor, elementPicker } from '../page-policy.js';
import { Vault, fillAccount } from '../services/vault.js';
import { ExtensionService } from '../services/extensions.js';
import { NativeMessaging } from '../services/native-messaging.js';
import { installNativeShim } from '../services/native-shim.js';
import { ExtensionAPI, installExtensionAPI } from '../services/extension-api.js';
import { LoginOffers, watchLogin } from '../services/login-offers.js';

// The desktop host embeds real Chromium page surfaces. The trusted shell and
// remote pages have different webContents and no shared preload or Node bridge.
export class ElectronAdapter {
  constructor({ window, directory, permissionPrompt, passwordPrompt, nativePrompt } = {}) {
    this.id = 'electron';
    this.version = CONTRACT_VERSION;
    this.window = window;
    this.directory = directory;
    this.permissionPrompt = permissionPrompt;
    this.passwordPrompt = passwordPrompt;
    this.nativePrompt = nativePrompt;
    this.metadata = new Map();
    this.policyRevision = 0;
    this.views = new Map();
    this.partitions = new Map();
    this.downloads = new Map();
    this.active = null;
    this.extensionWindows = new Set();
    this.extensionWorlds = new Map(); this.nextWorld = 1000;
    this.bounds = { x: 240, y: 76, width: 940, height: 704 };
    this.capabilities = {
      navigation: true, privateTabs: true, spaces: true, cookies: true,
      storageTransfer: false, automation: true, screenshots: true, input: true,
      find: true, reader: true, hiddenElements: true, shield: true, downloads: true,
      devtools: true, printing: true, extensions: true, passwords: safeStorage.isEncryptionAvailable() && (process.platform !== 'linux' || !['basic_text', 'unknown'].includes(safeStorage.getSelectedStorageBackend())),
      passkeys: true, pictureInPicture: true, nativeMessaging: true, signedUpdates: false,
    };
  }
  setCallbacks(callbacks) { this.callbacks = callbacks; }
  async start(callbacks) {
    this.setCallbacks(callbacks);
    this.downloadDirectory = await mkdtemp(path.join(os.tmpdir(), 'search-downloads-'));
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    this.vault = new Vault(this.directory, {
      available: () => safeStorage.isEncryptionAvailable() && (process.platform !== 'linux' || !['basic_text', 'unknown'].includes(safeStorage.getSelectedStorageBackend())),
      encrypt: value => safeStorage.encryptString(value), decrypt: value => safeStorage.decryptString(value),
    });
    this.capabilities.passwords = this.vault.available();
    this.loginOffers = new LoginOffers({ vault: this.vault, prompt: offer => this.passwordPrompt?.(offer) });
    this.preload = path.join(this.downloadDirectory, 'page-preload.cjs');
    await writeFile(this.preload, `const {ipcRenderer,contextBridge}=require('electron');\nconst policy=ipcRenderer.sendSync('search:page-policy',{url:location.href});\n(${policyBootstrap.toString()})(policy);\nif(/^https?:$/.test(location.protocol))(${watchLogin.toString()})(message=>ipcRenderer.send('search:login',message));\nif(location.protocol==='chrome-extension:'){contextBridge.exposeInMainWorld('searchNativeHost',{invoke:request=>ipcRenderer.invoke('search:native-extension',request)});contextBridge.exposeInMainWorld('searchExtensionHost',{invoke:request=>ipcRenderer.invoke('search:extension-api',request)});contextBridge.executeInMainWorld({func:${installNativeShim.toString()}});contextBridge.executeInMainWorld({func:${installExtensionAPI.toString()}});}`, { mode: 0o600 });
    this.workerPreload = path.join(this.downloadDirectory, 'extension-worker.cjs');
    await writeFile(this.workerPreload, `const {ipcRenderer}=require('electron');if(self.location.protocol==='chrome-extension:'){globalThis.searchNativeHost={invoke:request=>ipcRenderer.invoke('search:native-extension',request)};globalThis.searchExtensionHost={invoke:request=>ipcRenderer.invoke('search:extension-api',request)};(${installNativeShim.toString()})();(${installExtensionAPI.toString()})();}`, { mode: 0o600 });
    this.policyHandler = (event, request) => {
      const entry = [...this.views.entries()].find(([, view]) => view.webContents === event.sender);
      if (!entry || event.senderFrame?.top !== event.senderFrame) { event.returnValue = null; return; }
      event.returnValue = policyFor(this.callbacks, ++this.policyRevision);
    };
    ipcMain.on('search:page-policy', this.policyHandler);
    this.loginHandler = (event, message) => {
      const entry = [...this.views.entries()].find(([, view]) => view.webContents === event.sender);
      if (!entry || event.senderFrame?.top !== event.senderFrame) return;
      const tab = this.metadata.get(entry[0]);
      let origin; try { origin = new URL(event.senderFrame.url).origin; } catch { return; }
      if (message.kind === 'submitted') this.loginOffers.submitted(tab, origin, message);
      if (message.kind === 'settled') this.settleLogin(entry[0]).catch(() => {});
    };
    ipcMain.on('search:login', this.loginHandler);
    this.extensionService = new ExtensionService(this.directory, {
      load: async entry => {
        let id;
        for (const [key, store] of this.partitions) {
          if (!key.startsWith('persist:')) continue;
          const loaded = (entry.id && store.extensions.getExtension(entry.id)) || await store.extensions.loadExtension(entry.folder, { allowFileAccess: false });
          id = loaded.id;
        }
        if (!id && entry.id) return entry.id;
        if (!id) {
          const store = session.fromPartition('persist:search-space-default');
          const loaded = await store.extensions.loadExtension(entry.folder, { allowFileAccess: false });
          id = loaded.id;
        }
        return id;
      },
      unload: id => { for (const [key, store] of this.partitions) if (key.startsWith('persist:')) store.extensions.removeExtension(id); },
    });
    await this.extensionService.start();
    this.extensionAPI = new ExtensionAPI({ state: () => this.callbacks.state(), command: request => this.callbacks.command(request), manifest: async id => {
      const entry = this.extensionService.entry(id);
      if (!entry.enabled) throw new BrowserError('EXTENSION_DISABLED', 'Extension is disabled');
      return this.extensionService.manifest(entry.folder);
    }, inject: async (id, tab, options) => {
      if (!this.views.has(tab.id)) await this.callbacks.command({ do: 'wait', id: tab.id });
      let code;
      if (options.functionSource && !options.files) code = `(${options.functionSource})(...${JSON.stringify(options.args || [])})`;
      else if (Array.isArray(options.files) && options.files.length && options.files.every(file => typeof file === 'string' && !/(^\/|\.\.|[\\\0])/.test(file))) {
        const folder = this.extensionService.entry(id).folder;
        code = (await Promise.all(options.files.map(file => import('node:fs/promises').then(fs => fs.readFile(path.join(folder, file), 'utf8'))))).join('\n;\n');
      } else throw new BrowserError('INVALID_COMMAND', 'Supply a function or safe extension script files');
      const web = this.view(tab.id).webContents;
      const manifest = await this.extensionService.manifest(this.extensionService.entry(id).folder);
      if (!this.extensionAPI.allowed(id, manifest, { ...tab, url: web.getURL() })) throw new BrowserError('EXTENSION_PERMISSION_REQUIRED', 'Page origin changed; extension has no host access');
      if (options.world === 'MAIN') return web.executeJavaScript(code, true);
      if (!this.extensionWorlds.has(id)) this.extensionWorlds.set(id, this.nextWorld++);
      const world = this.extensionWorlds.get(id);
      return web.executeJavaScriptInIsolatedWorld(world, [{ code }], true);
    } });
    ipcMain.handle('search:extension-api', (event, request) => {
      const url = new URL(event.senderFrame.url);
      if (url.protocol !== 'chrome-extension:') throw new BrowserError('FORBIDDEN', 'Only extensions may use extension APIs');
      return this.extensionAPI.invoke(url.hostname, request);
    });
    this.native = new NativeMessaging({ directories: process.platform === 'darwin' ? [path.join(os.homedir(), 'Library/Application Support/Google/Chrome/NativeMessagingHosts')] : [path.join(os.homedir(), '.config/google-chrome/NativeMessagingHosts'), '/etc/opt/chrome/native-messaging-hosts'] });
    ipcMain.handle('search:native-extension', async (event, request) => {
      const url = new URL(event.senderFrame.url);
      if (url.protocol !== 'chrome-extension:') throw new BrowserError('FORBIDDEN', 'Only an extension may use native messaging');
      return this.extensionNativeRequest(url.hostname, request);
    });
  }
  view(id) {
    const view = this.views.get(id);
    if (!view) throw new BrowserError('TAB_NOT_FOUND', `Renderer has no tab ${id}`);
    return view;
  }
  async create(tab) {
    const partition = tab.private ? `private:${tab.id}` : `persist:search-space-${this.callbacks.storageKey?.(tab) || tab.space}`;
    const store = session.fromPartition(partition);
    if (!this.partitions.has(partition)) {
      this.partitions.set(partition, store);
      store.registerPreloadScript({ type: 'frame', filePath: this.preload });
      if (!tab.private) {
        store.registerPreloadScript({ type: 'service-worker', filePath: this.workerPreload });
        store.serviceWorkers.on('running-status-changed', details => {
          if (details.runningStatus !== 'running') return;
          const worker = store.serviceWorkers.getWorkerFromVersionID(details.versionId);
          if (!worker || !worker.scope.startsWith('chrome-extension://')) return;
          const id = new URL(worker.scope).hostname;
          worker.ipc.handle('search:native-extension', (_event, request) => this.extensionNativeRequest(id, request));
          worker.ipc.handle('search:extension-api', (_event, request) => this.extensionAPI.invoke(id, request));
        });
      }
      const approved = new Set();
      store.setPermissionRequestHandler(async (contents, permission, reply, details) => {
        let origin;
        try { origin = new URL(details.requestingUrl || contents.getURL()).origin; }
        catch { reply(false); return; }
        if (origin === 'null') { reply(false); return; }
        const key = `${origin}:${permission}`;
        if (approved.has(key)) { reply(true); return; }
        let allowed = false;
        try { allowed = await this.permissionPrompt?.({ origin, permission, details }); } catch {}
        if (allowed === true) approved.add(key);
        reply(allowed === true);
      });
      store.setPermissionCheckHandler((_contents, permission, origin) => approved.has(`${origin}:${permission}`));
      store.webRequest.onBeforeRequest((details, reply) => {
        const view = [...this.views.values()].find(view => view.webContents.id === details.webContentsId);
        const firstParty = view?.webContents.getURL() || '';
        reply({ cancel: details.resourceType !== 'mainFrame' && shouldBlock(details.url, firstParty, this.callbacks.shield(firstParty)) });
      });
      store.on('will-download', (_event, item, contents) => {
        const entry = [...this.views.entries()].find(([, view]) => view.webContents === contents);
        if (!entry) return;
        // Electron requires a destination during will-download. Use an owned,
        // temporary path; the site's suggested filename is never a local path.
        const temporary = path.join(this.downloadDirectory, randomUUID());
        item.setSavePath(temporary);
        const complete = new Promise((resolve, reject) => item.once('done', (_event, state) => {
          if (state === 'completed') resolve();
          else reject(new BrowserError('DOWNLOAD_FAILED', `Download ${state}`));
        }));
        complete.catch(() => {});
        const id = randomUUID();
        this.downloads.set(id, { tab: entry[0], item, temporary, complete });
        this.metadata.get(entry[0]).downloadId = id;
        this.callbacks.download({ id, tab: entry[0], name: item.getFilename(), state: 'downloading' });
        complete.then(() => this.callbacks.download({ id, state: 'awaiting-save' }), () => this.callbacks.download({ id, state: 'failed' }));
      });
      if (!tab.private) for (const entry of this.extensionService.entries.filter(entry => entry.enabled)) {
        try { if (!entry.id || !store.extensions.getExtension(entry.id)) await store.extensions.loadExtension(entry.folder, { allowFileAccess: false }); }
        catch (error) { entry.error = error.message; }
      }
    }
    const view = new WebContentsView({ webPreferences: {
      session: store, nodeIntegration: false, contextIsolation: true, sandbox: true,
      webSecurity: true, allowRunningInsecureContent: false, navigateOnDragDrop: false,
    } });
    this.views.set(tab.id, view);
    this.metadata.set(tab.id, { ...tab });
    const web = view.webContents;
    web.on('context-menu', (_event, details) => {
      const items = [{ role: 'copy', enabled: Boolean(details.selectionText) }, { role: 'paste', enabled: details.isEditable }, { role: 'selectAll' }];
      if (/^https?:\/\//.test(details.linkURL)) items.push({ type: 'separator' }, { label: 'Open link in new tab', click: () => this.callbacks.popup(details.linkURL) }, { label: 'Copy link', click: () => clipboard.writeText(details.linkURL) });
      if (/^https?:\/\//.test(details.srcURL) && details.mediaType === 'image') items.push({ label: 'Save image', click: () => web.downloadURL(details.srcURL) });
      items.push({ type: 'separator' }, { label: 'Inspect element', click: () => web.inspectElement(details.x, details.y) });
      Menu.buildFromTemplate(items).popup({ window: this.window });
    });
    web.setWindowOpenHandler(({ url }) => {
      if (/^https?:/.test(url)) this.callbacks.popup(url);
      return { action: 'deny' };
    });
    web.on('will-navigate', (event, url) => { if (!/^https?:/.test(url) && url !== 'about:blank') event.preventDefault(); });
    web.on('will-redirect', (event, url) => { if (!/^https?:/.test(url) && url !== 'about:blank') event.preventDefault(); });
    const update = () => { this.inspect(tab.id).then(fields => this.callbacks.changed(tab.id, fields)).catch(() => {}); };
    for (const event of ['did-start-loading', 'did-stop-loading', 'page-title-updated', 'did-navigate-in-page']) web.on(event, update);
    web.on('did-stop-loading', () => this.settleLogin(tab.id).catch(() => {}));
    web.on('dom-ready', async () => {
      await this.evaluate(tab.id, policyBootstrap, policyFor(this.callbacks, ++this.policyRevision)).catch(() => {});
      update();
    });
    web.on('did-fail-load', (_event, code, description, url, mainFrame) => {
      if (mainFrame && code !== -3) this.callbacks.changed(tab.id, { failure: description, url, loading: false });
    });
    web.on('render-process-gone', (_event, details) => this.callbacks.changed(tab.id, { failure: `Renderer ${details.reason}`, loading: false }));
    web.on('before-input-event', (event, input) => {
      if (input.type !== 'keyDown' || !(input.control || input.meta)) return;
      const key = input.key.toLowerCase();
      const actions = { l: 'address', t: input.shift ? 'reopen' : 'new', w: 'close', r: input.shift ? 'reader' : 'reload', k: 'tabs', f: 'find', d: 'bookmark' };
      if (input.shift && key === 'n') actions.n = 'private';
      if (actions[key]) {
        event.preventDefault();
        this.window.webContents.send('search:shortcut', actions[key]);
      }
    });
    this.window.contentView.addChildView(view);
    view.setVisible(false);
    await this.navigate(tab.id, tab.url);
  }
  async navigate(id, url) {
    this.view(id).requestedURL = url;
    this.callbacks.changed(id, { url, loading: true, failure: null });
    await this.view(id).webContents.loadURL(url).catch(error => {
      this.callbacks.changed(id, { failure: error.message, loading: false });
    });
  }
  async settleLogin(id) {
    const tab = this.metadata.get(id);
    if (!tab || !this.loginOffers.pending.has(id)) return;
    const hasPassword = await this.evaluate(id, () => [...document.querySelectorAll('input[type="password"]')].some(field => field.getBoundingClientRect().width > 0));
    await this.loginOffers.settled(tab, hasPassword);
  }
  async inspect(id) {
    const web = this.view(id).webContents;
    const actual = web.getURL();
    return { url: /^(https?:|about:blank$)/.test(actual) ? actual : this.view(id).requestedURL, title: web.getTitle(), loading: web.isLoading(), canGoBack: web.navigationHistory.canGoBack(), canGoForward: web.navigationHistory.canGoForward() };
  }
  async evaluate(id, fn, argument) {
    const expression = typeof fn === 'function' ? `(${fn.toString()})(${JSON.stringify(argument) ?? 'undefined'})` : fn;
    return this.view(id).webContents.executeJavaScript(expression, true);
  }
  async back(id) { const history = this.view(id).webContents.navigationHistory; if (history.canGoBack()) history.goBack(); }
  async forward(id) { const history = this.view(id).webContents.navigationHistory; if (history.canGoForward()) history.goForward(); }
  async reload(id) { this.view(id).webContents.reload(); }
  async activate(id) {
    for (const [key, view] of this.views) if (key !== this.floating?.id) view.setVisible(key === id && !this.overlay);
    this.active = id;
    if (id !== this.floating?.id) this.view(id).setBounds(this.bounds);
  }
  async setBounds(bounds) {
    const x = this.sidebar === false ? 0 : 240;
    const [width, height] = this.window.getContentSize();
    const y = this.sidebar === false ? 112 : 76;
    this.bounds = { x, y, width: Math.max(100, width - x), height: Math.max(100, height - y) };
    for (const [id, view] of this.views) if (id !== this.floating?.id) view.setBounds(this.bounds);
  }
  async shell({ sidebar, overlay }) {
    this.sidebar = sidebar;
    this.overlay = overlay;
    await this.setBounds();
    if (this.active) await this.activate(this.active);
  }
  async screenshot(id) { return (await this.view(id).webContents.capturePage()).toPNG(); }
  async zoom(id, zoom) { this.view(id).webContents.setZoomFactor(zoom); }
  async refreshPolicies() {
    for (const id of this.views.keys()) await this.evaluate(id, policyBootstrap, policyFor(this.callbacks, ++this.policyRevision)).catch(() => {});
  }
  async applyStyles(id, selectors) {
    const policy = policyFor(this.callbacks, ++this.policyRevision);
    policy.hidden[new URL(this.view(id).webContents.getURL()).hostname] = selectors;
    await this.evaluate(id, policyBootstrap, policy);
  }
  async pickHide(id) {
    const state = await this.evaluate(id, elementPicker);
    if (state.picking) {
      const timer = setInterval(async () => {
        const result = await this.evaluate(id, () => ({ live: window.__searchPicker?.live, selection: window.__searchPicker?.selection })).catch(() => ({ live: false }));
        if (!result.live) { clearInterval(timer); if (result.selection) this.callbacks.picked(id, result.selection.selector); }
      }, 100);
      timer.unref(); setTimeout(() => clearInterval(timer), 90000).unref();
    }
    return state;
  }
  async pictureInPicture(id) {
    if (this.floating?.id === id) { await this.returnVideo(); return { floating: false }; }
    if (this.floating) await this.returnVideo();
    const found = await this.evaluate(id, () => {
      const video = [...document.querySelectorAll('video')].find(video => !video.paused) || document.querySelector('video');
      if (!video) return false;
      video.dataset.searchFloating = 'true';
      const style = document.createElement('style'); style.id = 'search-floating-style';
      style.textContent = 'body *{visibility:hidden!important}video[data-search-floating]{visibility:visible!important;position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;background:#000!important;z-index:2147483647!important;object-fit:contain!important}';
      document.head.append(style); return true;
    });
    if (!found) throw new BrowserError('NO_VIDEO', 'No video on this page');
    const view = this.view(id);
    this.window.contentView.removeChildView(view);
    const floating = new BrowserWindow({ width: 460, height: 280, minWidth: 260, minHeight: 160, alwaysOnTop: true, title: 'Search video', autoHideMenuBar: true });
    floating.contentView.addChildView(view); view.setVisible(true);
    const resize = () => { const [width, height] = floating.getContentSize(); view.setBounds({ x: 0, y: 0, width, height }); };
    floating.on('resize', resize); resize();
    floating.on('close', event => { if (!this.returningVideo) { event.preventDefault(); this.returnVideo().catch(() => {}); } });
    this.floating = { id, view, window: floating };
    return { floating: true };
  }
  async returnVideo() {
    const floating = this.floating; if (!floating) return;
    this.floating = null; this.returningVideo = true;
    floating.window.contentView.removeChildView(floating.view);
    this.window.contentView.addChildView(floating.view);
    await this.evaluate(floating.id, () => { document.getElementById('search-floating-style')?.remove(); document.querySelector('[data-search-floating]')?.removeAttribute('data-search-floating'); });
    floating.window.destroy(); this.returningVideo = false;
    floating.view.setBounds(this.bounds); floating.view.setVisible(floating.id === this.active && !this.overlay);
    this.callbacks.changed(floating.id, { floating: false });
  }
  async password(request, tab) {
    if (tab?.private) throw new BrowserError('PRIVATE_TAB', 'Passwords cannot be saved or filled in a private tab');
    const origin = tab ? new URL(tab.url).origin : undefined;
    if (request.action === 'list') return this.vault.list(origin);
    if (request.action === 'save') return this.vault.save({ origin, username: request.username, password: request.password });
    if (request.action === 'remove') return this.vault.remove(request.account);
    if (request.action === 'import') return this.vault.importCSV(request.csv);
    if (request.action === 'fill') {
      const account = await this.vault.get(request.account, origin);
      return this.evaluate(tab.id, fillAccount, account);
    }
    throw new BrowserError('INVALID_COMMAND', 'Unknown password action');
  }
  async extensions(request) {
    const service = this.extensionService;
    if (request.do === 'extensions') return service.list();
    if (request.do === 'ext-folder') return service.folder(request.path, request.yes === true);
    if (request.do === 'ext-add') return service.store(request.id, request.yes === true);
    if (request.do === 'ext-remove') return service.remove(request.id);
    if (request.do === 'ext-reload') return service.reload(request.id);
    if (request.do === 'ext-enable') return service.enable(request.id, request.on === true);
    if (request.do === 'ext-pin') return service.pin(request.id, request.on !== false);
    const entry = service.entry(request.id);
    if (!entry.enabled) throw new BrowserError('EXTENSION_DISABLED', 'Enable the extension first');
    const active = this.callbacks.state().tabs.find(tab => tab.id === this.active && !tab.private);
    if (active) this.extensionAPI.grant(entry.id, active);
    const store = active ? this.view(active.id).webContents.session : this.partitions.get('persist:search-space-default');
    if (!store) throw new BrowserError('NO_EXTENSION_SESSION', 'Open a normal tab before using extensions');
    const manifest = JSON.parse(await (await import('node:fs/promises')).readFile(path.join(entry.folder, 'manifest.json'), 'utf8'));
    const popup = request.path || manifest.action?.default_popup || manifest.browser_action?.default_popup;
    if (!popup || /(^\/|\.\.|[\\\0])/.test(popup)) throw new BrowserError('INVALID_EXTENSION_PAGE', 'No safe popup or page path');
    const window = new BrowserWindow({ width: 420, height: 540, autoHideMenuBar: true, webPreferences: { session: store, sandbox: true, nodeIntegration: false, contextIsolation: true } });
    this.extensionWindows.add(window); window.on('closed', () => this.extensionWindows.delete(window));
    window.webContents.on('will-navigate', (event, url) => { if (!url.startsWith(`chrome-extension://${entry.id}/`)) event.preventDefault(); });
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    await window.loadURL(`chrome-extension://${entry.id}/${popup}`);
    return { opened: true };
  }
  async nativeMessaging(request) {
    if (request.do === 'native-authorize') return this.native.authorize(request.extension, request.host, request.on === true);
    if (request.do === 'native-connect') return this.native.connect(request.extension, request.host);
    if (request.do === 'native-post') return this.native.post(request.extension, request.connection, request.message);
    if (request.do === 'native-poll') return this.native.poll(request.extension, request.connection);
    return this.native.disconnect(request.extension, request.connection);
  }
  async extensionNativeRequest(id, request) {
    const entry = this.extensionService.entry(id);
    if (!entry.enabled || !entry.permissions.includes('nativeMessaging')) throw new BrowserError('FORBIDDEN', 'Extension has no nativeMessaging permission');
    if (!['native-connect', 'native-post', 'native-poll', 'native-disconnect'].includes(request.do)) throw new BrowserError('FORBIDDEN', 'Extension cannot grant its own host permissions');
    if (request.do === 'native-connect' && !this.native.allowed.has(`${id}:${request.host}`)) {
      if (typeof request.host !== 'string' || !/^[a-z0-9_]+(?:\.[a-z0-9_]+)*$/.test(request.host)) throw new BrowserError('INVALID_NATIVE_HOST', 'Invalid native host name');
      if (await this.nativePrompt?.({ extension: entry.name, host: request.host }) !== true) throw new BrowserError('NATIVE_PERMISSION_REQUIRED', 'Native host was not approved');
      this.native.authorize(id, request.host, true);
    }
    return this.nativeMessaging({ ...request, extension: id });
  }
  async devtools(id) { this.view(id).webContents.openDevTools({ mode: 'detach' }); return { ok: true }; }
  async print(id) {
    return new Promise((resolve, reject) => this.view(id).webContents.print({}, (ok, failure) => {
      if (ok) resolve({ ok: true }); else reject(new BrowserError('PRINT_FAILED', failure));
    }));
  }
  async input(id, event) {
    const web = this.view(id).webContents;
    if (event.kind === 'text') web.insertText(String(event.text));
    else if (event.kind === 'click') {
      web.sendInputEvent({ type: 'mouseDown', x: Math.round(event.x), y: Math.round(event.y), button: event.button || 'left', clickCount: 1 });
      web.sendInputEvent({ type: 'mouseUp', x: Math.round(event.x), y: Math.round(event.y), button: event.button || 'left', clickCount: 1 });
    } else if (event.kind === 'wheel') web.sendInputEvent({ type: 'mouseWheel', x: 1, y: 1, deltaX: event.dx || 0, deltaY: event.dy || 0 });
    else if (event.kind === 'key') {
      web.sendInputEvent({ type: 'keyDown', keyCode: String(event.key) });
      web.sendInputEvent({ type: 'keyUp', keyCode: String(event.key) });
    } else throw new BrowserError('INVALID_INPUT', 'Unknown input event');
    return { ok: true };
  }
  async find(id, text, backward) {
    const web = this.view(id).webContents;
    if (!text) { web.stopFindInPage('clearSelection'); return { found: false }; }
    return new Promise(resolve => {
      const listener = (_event, result) => { if (result.finalUpdate) { web.removeListener('found-in-page', listener); resolve(result); } };
      web.on('found-in-page', listener);
      web.findInPage(text, { forward: !backward });
    });
  }
  async saveDownload(id, destination, downloadId = this.metadata.get(id)?.downloadId) {
    const download = this.downloads.get(downloadId);
    if (!download) throw new BrowserError('NO_DOWNLOAD', 'No download awaits saving');
    await download.complete;
    await chmod(download.temporary, 0o600);
    await copyFile(download.temporary, destination);
    await chmod(destination, 0o600);
    return { path: destination };
  }
  async close(id) {
    this.loginOffers?.forget(id);
    if (this.floating?.id === id) await this.returnVideo();
    const view = this.views.get(id);
    if (!view) return;
    const store = view.webContents.session;
    this.window.contentView.removeChildView(view);
    view.webContents.close();
    this.views.delete(id);
    const metadata = this.metadata.get(id); this.metadata.delete(id);
    for (const [downloadId, download] of this.downloads) if (download.tab === id && metadata.private) {
      if (download.item.getState() === 'progressing') download.item.cancel();
      await download.complete.catch(() => {});
      await rm(download.temporary, { force: true });
      this.downloads.delete(downloadId);
    }
    const partition = [...this.partitions.entries()].find(([, entry]) => entry === store)?.[0];
    if (partition?.startsWith('private:')) {
      await store.clearStorageData();
      await store.clearCache();
      this.partitions.delete(partition);
    }
  }
  async stop() {
    for (const window of this.extensionWindows) window.destroy();
    for (const id of [...this.views.keys()]) await this.close(id);
    if (this.downloadDirectory) await rm(this.downloadDirectory, { recursive: true, force: true });
    if (this.policyHandler) ipcMain.removeListener('search:page-policy', this.policyHandler);
    if (this.loginHandler) ipcMain.removeListener('search:login', this.loginHandler);
    ipcMain.removeHandler('search:native-extension');
    ipcMain.removeHandler('search:extension-api');
    this.native?.stop();
    this.loginOffers?.stop();
  }
}
