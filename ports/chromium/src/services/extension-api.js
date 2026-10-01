import { BrowserError } from '../contract.js';

export function matchesHost(pattern, address) {
  let url; try { url = new URL(address); } catch { return false; }
  if (!['http:', 'https:'].includes(url.protocol)) return false;
  if (pattern === '<all_urls>') return true;
  const match = /^(\*|https?|file):\/\/(\*|\*\.[^/]+|[^/]+)(\/.*)$/.exec(pattern);
  if (!match || match[1] !== '*' && `${match[1]}:` !== url.protocol) return false;
  const host = match[2];
  if (host !== '*' && !(host.startsWith('*.') ? url.hostname === host.slice(2) || url.hostname.endsWith(host.slice(1)) : url.hostname === host)) return false;
  const path = new RegExp(`^${match[3].split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`);
  return path.test(url.pathname + url.search);
}

export class ExtensionAPI {
  constructor({ state, command, inject, manifest }) {
    Object.assign(this, { state, command, inject, manifest });
    this.ids = new Map(); this.sequence = 0; this.grants = new Map();
  }
  id(tab) { if (!tab) throw new BrowserError('TAB_NOT_FOUND', 'No normal active tab'); if (!this.ids.has(tab.id)) this.ids.set(tab.id, ++this.sequence); return this.ids.get(tab.id); }
  tab(id) {
    const tab = this.state().tabs.find(tab => this.ids.get(tab.id) === id && !tab.private && !tab.bench);
    if (!tab) throw new BrowserError('TAB_NOT_FOUND', 'Unknown extension tab'); return tab;
  }
  grant(extension, tab) { if (tab) this.grants.set(extension, { id: tab.id, origin: new URL(tab.url).origin }); }
  allowed(extension, manifest, tab) {
    const grant = this.grants.get(extension);
    return (manifest.host_permissions || []).concat((manifest.permissions || []).filter(value => value.includes('://') || value === '<all_urls>')).some(pattern => matchesHost(pattern, tab.url)) || Boolean(manifest.permissions?.includes('activeTab') && grant?.id === tab.id && grant.origin === new URL(tab.url).origin);
  }
  describe(extension, manifest, tab) {
    const state = this.state();
    const info = { id: this.id(tab), windowId: 1, active: state.active === tab.id, pinned: Boolean(tab.pin), index: state.tabs.indexOf(tab), incognito: false, status: tab.loading ? 'loading' : 'complete', discarded: Boolean(tab.sleeping), groupId: -1 };
    if (manifest.permissions?.includes('tabs') || this.allowed(extension, manifest, tab)) Object.assign(info, { url: tab.url, title: tab.title || '' });
    return info;
  }
  async invoke(extension, request) {
    const manifest = await this.manifest(extension);
    const describe = tab => this.describe(extension, manifest, tab);
    const normal = () => this.state().tabs.filter(tab => !tab.private && !tab.bench);
    for (const tab of normal()) this.id(tab);
    const [first, second] = request.args || [];
    switch (request.api) {
      case 'tabs.query': return normal().filter(tab => {
        const query = first || {};
        if (query.active !== undefined && query.active !== (tab.id === this.state().active)) return false;
        if (query.pinned !== undefined && query.pinned !== Boolean(tab.pin)) return false;
        if (query.windowId !== undefined && ![1, -2].includes(query.windowId)) return false;
        if (query.url && (!manifest.permissions?.includes('tabs') && !this.allowed(extension, manifest, tab) || !(Array.isArray(query.url) ? query.url : [query.url]).some(pattern => matchesHost(pattern, tab.url)))) return false;
        return true;
      }).map(describe);
      case 'tabs.get': return describe(this.tab(first));
      case 'tabs.create': {
        const created = await this.command({ do: 'open', url: first?.url || 'about:blank', select: first?.active !== false });
        const tab = normal().find(tab => tab.id === created.id);
        if (first?.pinned) await this.command({ do: 'pin', id: tab.id, on: true });
        return describe(tab);
      }
      case 'tabs.update': {
        const id = typeof first === 'number' ? first : this.id(normal().find(tab => tab.id === this.state().active));
        const tab = this.tab(id); const properties = typeof first === 'number' ? second : first;
        if (properties?.url) await this.command({ do: 'go', id: tab.id, url: properties.url });
        if (properties?.pinned !== undefined) await this.command({ do: 'pin', id: tab.id, on: properties.pinned });
        if (properties?.active) await this.command({ do: 'select', id: tab.id });
        return describe(tab);
      }
      case 'tabs.remove': for (const id of Array.isArray(first) ? first : [first]) await this.command({ do: 'close', id: this.tab(id).id }); return;
      case 'tabs.reload': {
        const tab = first === undefined ? normal().find(tab => tab.id === this.state().active) : this.tab(first);
        if (!tab) throw new BrowserError('TAB_NOT_FOUND', 'No normal active tab');
        return this.command({ do: 'reload', id: tab.id });
      }
      case 'windows.getCurrent': case 'windows.getLastFocused': case 'windows.get': case 'windows.getAll': {
        if (request.api === 'windows.get' && first !== 1) throw new BrowserError('WINDOW_NOT_FOUND', 'Unknown browser window');
        const options = request.api === 'windows.get' ? second : first;
        const window = { id: 1, type: 'normal', focused: true, incognito: false, ...(options?.populate ? { tabs: normal().map(describe) } : {}) };
        return request.api === 'windows.getAll' ? [window] : window;
      }
      case 'scripting.executeScript': {
        if (!manifest.permissions?.includes('scripting')) throw new BrowserError('EXTENSION_PERMISSION_REQUIRED', 'The scripting permission is required');
        const tab = this.tab(first?.target?.tabId);
        if (!this.allowed(extension, manifest, tab)) throw new BrowserError('EXTENSION_PERMISSION_REQUIRED', 'Host access or an explicit activeTab grant is required');
        if (first.target.allFrames || first.target.frameIds?.some(id => id !== 0)) throw new BrowserError('FEATURE_UNAVAILABLE', 'Only the top frame supports host scripting');
        if (first.world && !['MAIN', 'ISOLATED'].includes(first.world)) throw new BrowserError('INVALID_COMMAND', 'Unknown execution world');
        return [{ frameId: 0, result: await this.inject(extension, tab, first) }];
      }
      default: throw new BrowserError('FEATURE_UNAVAILABLE', `Extension API ${request.api} is unavailable`);
    }
  }
}

// Runs only inside extension pages and extension workers. Functions cross IPC
// as source strings; no website receives the host bridge or its permissions.
export function installExtensionAPI() {
  if (!globalThis.chrome?.runtime || !globalThis.searchExtensionHost) return;
  const call = (api, args) => {
    const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
    const result = searchExtensionHost.invoke({ api, args });
    if (!callback) return result;
    result.then(value => callback(value), error => {
      Object.defineProperty(chrome.runtime, 'lastError', { configurable: true, value: { message: error.message } });
      try { callback(); } finally { delete chrome.runtime.lastError; }
    });
  };
  for (const [group, names] of Object.entries({ tabs: ['query', 'get', 'create', 'update', 'remove', 'reload'], windows: ['getCurrent', 'getLastFocused', 'get', 'getAll'] })) {
    chrome[group] ||= {};
    for (const name of names) chrome[group][name] = (...args) => call(`${group}.${name}`, args);
  }
  chrome.scripting ||= {};
  chrome.scripting.executeScript = (options, callback) => {
    const transferable = { ...options, ...(options.func ? { functionSource: options.func.toString(), func: undefined } : {}) };
    return call('scripting.executeScript', callback ? [transferable, callback] : [transferable]);
  };
}
