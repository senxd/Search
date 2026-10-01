import { BrowserError, requireFeature } from './contract.js';

const TAB_METHODS = ['navigate', 'inspect', 'evaluate', 'back', 'forward', 'reload', 'screenshot', 'input', 'find', 'zoom', 'applyStyles', 'pickHide', 'devtools', 'print', 'pictureInPicture'];

// Each live page retains its renderer, storage context, and JavaScript heap.
// Switching the default affects future pages only; it never serializes a live
// heap or silently reloads a page. Renderer stores stay separate by design.
export class RendererRouter {
  constructor(registry, adapter, options = {}) {
    this.registry = registry; this.default = adapter.id; this.options = options;
    this.adapters = new Map([[adapter.id, adapter]]); this.owners = new Map(); this.downloadOwners = new Map();
    this.version = adapter.version;
    for (const method of TAB_METHODS) this[method] = (id, ...args) => {
      const host = this.host(id);
      if (typeof host[method] !== 'function') throw new BrowserError('FEATURE_UNAVAILABLE', `${host.id} cannot provide ${method}`);
      return host[method](id, ...args);
    };
  }
  get id() { return this.default; }
  get capabilities() { return this.adapters.get(this.default).capabilities; }
  host(id) {
    const host = this.adapters.get(this.owners.get(id));
    if (!host) throw new BrowserError('TAB_NOT_FOUND', 'The tab has no live renderer');
    return host;
  }
  hostCallbacks(host) { return { ...this.callbacks, changed: (id, fields) => this.callbacks.changed(id, { ...fields, engine: host.id }), download: item => { if (item.id) this.downloadOwners.set(item.id, host.id); this.callbacks.download(item); } }; }
  setCallbacks(callbacks) { this.callbacks = callbacks; for (const host of this.adapters.values()) host.setCallbacks(this.hostCallbacks(host)); }
  async start(callbacks) { this.callbacks = callbacks; const host = this.adapters.get(this.default); await host.start(this.hostCallbacks(host)); }
  async prepare(engine, required = []) {
    let host = this.adapters.get(engine);
    if (!host) {
      host = this.registry.create(engine, this.options);
      for (const feature of required) requireFeature(host, feature);
      try { await host.start(this.hostCallbacks(host)); }
      catch (error) { await host.stop({ persist: false }).catch(() => {}); throw new BrowserError('ENGINE_START_FAILED', error.message); }
      this.adapters.set(engine, host);
    }
    for (const feature of required) requireFeature(host, feature);
    return host;
  }
  async selectRenderer(engine, required) {
    await this.prepare(engine, required);
    this.default = engine;
    return { engine, scope: 'new-tabs', reloaded: false, live: this.mapping(), storage: 'separate-per-renderer' };
  }
  mapping() { return [...this.owners].map(([id, engine]) => ({ id, engine })); }
  requireFeatures(features) { for (const host of this.adapters.values()) for (const feature of features) requireFeature(host, feature); }
  async create(tab) {
    const host = await this.prepare(tab.engine || this.default);
    this.owners.set(tab.id, host.id);
    try { await host.create(tab); this.callbacks.changed(tab.id, { engine: host.id }); }
    catch (error) { this.owners.delete(tab.id); await host.close(tab.id).catch(() => {}); throw error; }
  }
  async close(id) { if (!this.owners.has(id)) return; await this.host(id).close(id); this.owners.delete(id); }
  async activate(id) { return this.host(id).activate(id); }
  downloadHost(id, downloadId) { return downloadId ? this.adapters.get(this.downloadOwners.get(downloadId)) : this.host(id); }
  async saveDownload(id, destination, downloadId) { return this.downloadHost(id, downloadId).saveDownload(id, destination, downloadId); }
  async downloadBytes(id, downloadId) { return this.downloadHost(id, downloadId).downloadBytes(id, downloadId); }
  async setBounds(bounds) { for (const host of this.adapters.values()) await host.setBounds(bounds); }
  async refreshPolicies() { for (const host of this.adapters.values()) await host.refreshPolicies?.(); }
  async exportState() {
    const engines = new Set(this.owners.values());
    if (engines.size > 1) throw new BrowserError('MIXED_RENDERERS', 'Keep existing renderer mappings or close their tabs before a full reload migration');
    return this.adapters.get([...engines][0] || this.default).exportState();
  }
  async importState(state) { return this.adapters.get(this.default).importState(state); }
  async stop(options) { for (const host of this.adapters.values()) await host.stop(options); }
}
