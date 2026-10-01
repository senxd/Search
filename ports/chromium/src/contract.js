// Hosts implement this contract; the model and agent protocol never import a
// rendering framework. Version every adapter against this API.
export const CONTRACT_VERSION = 1;
export const FEATURES = Object.freeze([
  'navigation', 'privateTabs', 'spaces', 'cookies', 'storageTransfer',
  'automation', 'screenshots', 'input', 'find', 'reader', 'hiddenElements',
  'shield', 'downloads', 'devtools', 'printing', 'extensions', 'passwords',
  'passkeys', 'pictureInPicture', 'nativeMessaging', 'signedUpdates',
]);
export const REQUIRED_METHODS = Object.freeze([
  'start', 'stop', 'create', 'close', 'navigate', 'inspect', 'evaluate',
  'back', 'forward', 'reload', 'activate', 'setBounds',
  'setCallbacks',
]);
const FEATURE_METHODS = {
  screenshots: ['screenshot'], input: ['input'], find: ['find'],
  downloads: ['saveDownload'], storageTransfer: ['exportState', 'importState'],
  devtools: ['devtools'], printing: ['print'],
  extensions: ['extensions'], passwords: ['password'],
  pictureInPicture: ['pictureInPicture'], nativeMessaging: ['nativeMessaging'],
};

export class BrowserError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.code = code;
    this.details = details;
  }
}

export function requireFeature(adapter, feature) {
  if (adapter.capabilities[feature] !== true) {
    throw new BrowserError('FEATURE_UNAVAILABLE', `${adapter.id} cannot provide ${feature}`, {
      engine: adapter.id, feature,
    });
  }
}

export class EngineRegistry {
  #factories = new Map();
  register(id, factory) {
    if (!/^[a-z][a-z0-9-]*$/.test(id) || this.#factories.has(id)) {
      throw new BrowserError('INVALID_ENGINE', `Invalid or duplicate engine: ${id}`);
    }
    this.#factories.set(id, factory);
  }
  create(id, options = {}) {
    const factory = this.#factories.get(id);
    if (!factory) throw new BrowserError('UNKNOWN_ENGINE', `Engine is not registered: ${id}`);
    const adapter = factory(options);
    if (adapter.version !== CONTRACT_VERSION || adapter.id !== id) {
      throw new BrowserError('INVALID_ADAPTER', 'Adapter identity or contract version does not match');
    }
    if (!adapter.capabilities || typeof adapter.capabilities !== 'object') throw new BrowserError('INVALID_ADAPTER', 'Adapter must declare its capabilities');
    for (const method of REQUIRED_METHODS) {
      if (typeof adapter[method] !== 'function') {
        throw new BrowserError('INVALID_ADAPTER', `${id} is missing ${method}`);
      }
    }
    for (const [feature, methods] of Object.entries(FEATURE_METHODS)) {
      if (!adapter.capabilities[feature]) continue;
      for (const method of methods) if (typeof adapter[method] !== 'function') {
        throw new BrowserError('INVALID_ADAPTER', `${id} advertises ${feature} but is missing ${method}`);
      }
    }
    return adapter;
  }
  list() {
    return [...this.#factories.keys()].map(id => {
      const adapter = this.create(id);
      return { id, version: adapter.version, capabilities: adapter.capabilities };
    });
  }
}
