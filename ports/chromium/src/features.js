import { randomUUID } from 'node:crypto';
import { BrowserError, requireFeature } from './contract.js';
import { address, validateURL, searchTemplate } from './address.js';
import { capturePage, restorePage } from './session-state.js';

export const UNHANDLED = Symbol('unhandled');
const normalTab = tab => !tab.private && !tab.bench;
const groupOf = (browser, id) => {
  const matches = browser.groups.filter(group => group.id === id || typeof id === 'string' && group.id.startsWith(id));
  if (matches.length !== 1) throw new BrowserError('GROUP_NOT_FOUND', 'Unknown or ambiguous group');
  return matches[0];
};
const label = value => String(value || '').trim().slice(0, 80);

export async function handleFeature(b, r) {
  switch (r.do) {
    case 'picture-in-picture': {
      requireFeature(b.adapter, 'pictureInPicture');
      const tab = await b.ensure(b.tab(r.id));
      const result = await b.adapter.pictureInPicture(tab.id);
      tab.floating = result.floating;
      return result;
    }
    case 'download-get': {
      requireFeature(b.adapter, 'downloads');
      return b.adapter.downloadBytes(b.downloadTab(r), r.downloadId);
    }
    case 'password': {
      requireFeature(b.adapter, 'passwords');
      const tab = ['import', 'remove'].includes(r.action) ? null : await b.ensure(b.tab(r.id));
      return b.adapter.password(r, tab);
    }
    case 'extensions': case 'ext-folder': case 'ext-add': case 'ext-remove': case 'ext-reload': case 'ext-enable': case 'ext-pin': case 'ext-press': case 'ext-page': {
      requireFeature(b.adapter, 'extensions');
      return b.adapter.extensions(r);
    }
    case 'native-authorize': case 'native-connect': case 'native-post': case 'native-poll': case 'native-disconnect': {
      requireFeature(b.adapter, 'nativeMessaging');
      return b.adapter.nativeMessaging(r);
    }
    case 'update-check': case 'update-stage': {
      if (!b.updater?.configured()) throw new BrowserError('UPDATE_UNCONFIGURED', 'A trusted release key and feed are required');
      return r.do === 'update-check' ? b.updater.check() : b.updater.stage(r.manifest);
    }
    case 'suggest': {
      const query = String(r.text || '').trim().toLowerCase();
      if (!query) return [];
      const items = [...b.tabs.filter(normalTab), ...b.bookmarks, ...b.history];
      const seen = new Set();
      return items.filter(item => {
        if (seen.has(item.url) || !(item.url + ' ' + item.title).toLowerCase().includes(query)) return false;
        seen.add(item.url); return true;
      }).slice(0, 8).map(({ url, title }) => ({ url, title }));
    }
    case 'search-tabs': {
      const query = String(r.text || '').toLowerCase();
      return b.tabs.filter(tab => `${tab.title} ${tab.url}`.toLowerCase().includes(query)).map(tab => ({ ...tab, resume: undefined }));
    }
    case 'duplicate': {
      const tab = b.tab(r.id);
      return b.open({ url: tab.url, private: tab.private, space: tab.space });
    }
    case 'rename': b.tab(r.id).name = label(r.name); return { ok: true };
    case 'place': {
      const tab = b.tab(r.id);
      if (!Number.isInteger(r.index) || r.index < 0 || r.index >= b.tabs.length) throw new BrowserError('INVALID_INDEX', 'Tab index is out of range');
      b.tabs.splice(b.tabs.indexOf(tab), 1);
      b.tabs.splice(r.index, 0, tab);
      return { ok: true };
    }
    case 'step': {
      const tabs = b.tabs.filter(tab => tab.space === b.space && !tab.bench);
      const index = tabs.findIndex(tab => tab.id === b.active);
      if (!tabs.length) return { ok: false };
      return b.select(tabs[(index + (r.backward ? -1 : 1) + tabs.length) % tabs.length].id);
    }
    case 'close-others': {
      const tab = b.tab(r.id);
      for (const other of [...b.tabs].filter(other => other.space === tab.space && other.id !== tab.id && !other.bench && !other.pin)) await b.close(other.id);
      return { ok: true };
    }
    case 'sleep': {
      const tab = b.tab(r.id);
      if (tab.private || tab.id === b.active || tab.floating) throw new BrowserError('TAB_BUSY', 'Active, private, and floating tabs must stay awake');
      if (tab.sleeping) return { sleeping: true };
      const checkpoint = await b.adapter.evaluate(tab.id, capturePage);
      if (checkpoint.busy) throw new BrowserError('TAB_BUSY', checkpoint.reason);
      tab.resume = checkpoint;
      await b.adapter.close(tab.id);
      tab.sleeping = true;
      return { sleeping: true };
    }
    case 'sleep-idle': {
      const before = Date.now() - Math.max(1, Number(r.minutes || b.settings.sleepMinutes || 30)) * 60000;
      const slept = [];
      for (const tab of [...b.tabs].filter(tab => normalTab(tab) && !tab.sleeping && tab.id !== b.active && !tab.pin && (tab.lastActive || 0) < before)) {
        try { await handleFeature(b, { do: 'sleep', id: tab.id }); slept.push(tab.id); }
        catch (error) { if (error.code !== 'TAB_BUSY') throw error; }
      }
      return { slept };
    }
    case 'zoom': {
      const tab = await b.ensure(b.tab(r.id));
      const zoom = r.reset ? 1 : (tab.zoom || 1) * Number(r.factor || 1);
      if (!Number.isFinite(zoom) || zoom < 0.25 || zoom > 5) throw new BrowserError('INVALID_ZOOM', 'Zoom must be between 25% and 500%');
      if (b.adapter.zoom) await b.adapter.zoom(tab.id, zoom);
      else await b.adapter.evaluate(tab.id, zoom => { document.documentElement.style.zoom = zoom; }, zoom);
      tab.zoom = zoom;
      return { zoom };
    }
    case 'library': {
      const kind = r.kind || 'bookmarks';
      if (!['bookmarks', 'history'].includes(kind)) throw new BrowserError('INVALID_LIBRARY', 'Choose bookmarks or history');
      const query = String(r.text || '').toLowerCase();
      return b[kind].filter(item => `${item.title} ${item.url}`.toLowerCase().includes(query));
    }
    case 'bookmark-edit': {
      const item = b.bookmarks.find(item => item.url === r.url);
      if (!item) throw new BrowserError('BOOKMARK_NOT_FOUND', 'Unknown bookmark');
      const url = r.newURL ? validateURL(r.newURL) : item.url;
      const title = r.title === undefined ? item.title : String(r.title).slice(0, 500);
      Object.assign(item, { url, title });
      return item;
    }
    case 'library-export': return { version: 1, bookmarks: structuredClone(b.bookmarks), history: structuredClone(b.history) };
    case 'library-import': {
      const data = r.data;
      if (!data || !Array.isArray(data.bookmarks || [] ) || !Array.isArray(data.history || [])) throw new BrowserError('INVALID_IMPORT', 'Expected bookmark/history arrays');
      const validate = (items, history) => items.map(item => ({ url: validateURL(item.url), title: String(item.title || '').slice(0, 500), ...(history ? { at: Number.isFinite(item.at) ? item.at : Date.now() } : {}) }));
      const bookmarks = validate(data.bookmarks || [], false);
      const history = validate(data.history || [], true);
      if (bookmarks.length + history.length > 10000) throw new BrowserError('INVALID_IMPORT', 'Import exceeds 10,000 items');
      const merge = (items, extra) => [...new Map([...items, ...extra].map(item => [item.url, item])).values()];
      b.bookmarks = merge(b.bookmarks, bookmarks);
      b.history = merge(b.history, history).sort((a, c) => c.at - a.at).slice(0, 2000);
      return { bookmarks: bookmarks.length, history: history.length };
    }
    case 'hidden-list': {
      const tab = b.tab(r.id);
      return { host: new URL(tab.url).hostname, selectors: [...(b.hidden[new URL(tab.url).hostname] || [])] };
    }
    case 'unhide': {
      const tab = await b.ensure(b.tab(r.id));
      const host = new URL(tab.url).hostname;
      const selectors = r.all ? [] : (b.hidden[host] || []).filter(selector => selector !== r.selector);
      if (!tab.private) b.hidden[host] = selectors;
      await b.adapter.applyStyles?.(tab.id, selectors);
      if (!b.adapter.applyStyles) await b.adapter.reload(tab.id);
      return { ok: true };
    }
    case 'pick-hide': {
      const tab = await b.ensure(b.tab(r.id));
      requireFeature(b.adapter, 'hiddenElements');
      return b.adapter.pickHide(tab.id);
    }
    case 'shield-site': {
      const host = new URL(b.tab(r.id).url).hostname;
      b.settings.pausedHosts = r.on === false ? [...new Set([...b.settings.pausedHosts, host])] : b.settings.pausedHosts.filter(item => item !== host);
      await b.adapter.refreshPolicies?.();
      return { host, enabled: !b.settings.pausedHosts.includes(host) };
    }
    case 'space': {
      requireFeature(b.adapter, 'spaces');
      const action = r.action || r.op;
      if (action === 'new') {
        const source = b.spaces.find(space => space.id === b.space);
        const fresh = r.fresh === true || r.sharesSignIns === false;
        const space = { id: randomUUID(), name: label(r.name) || 'Space', store: fresh ? randomUUID() : source.store || source.id };
        b.spaces.push(space); b.space = space.id;
        await b.open();
        return space;
      }
      if (action === 'go' || action === 'swipe') {
        const current = b.spaces.findIndex(space => space.id === b.space);
        const index = action === 'swipe' ? (current + (Number(r.dx) < 0 ? 1 : -1) + b.spaces.length) % b.spaces.length : r.index === undefined ? b.spaces.findIndex(space => space.id === r.id) : Number(r.index) - 1;
        const space = b.spaces[index];
        if (!space) throw new BrowserError('SPACE_NOT_FOUND', 'Unknown space');
        b.space = space.id;
        const tab = b.tabs.find(tab => tab.space === space.id && !tab.bench);
        return tab ? b.select(tab.id) : b.open();
      }
      const space = b.spaces.find(space => space.id === (r.id || b.space));
      if (!space) throw new BrowserError('SPACE_NOT_FOUND', 'Unknown space');
      if (action === 'rename') { space.name = label(r.name) || 'Space'; return space; }
      if (action === 'delete') {
        if (b.spaces.length === 1) throw new BrowserError('LAST_SPACE', 'Keep at least one space');
        // Move the selection first so closing does not create tabs in the deleted space.
        b.space = b.spaces.find(item => item !== space).id;
        const next = b.tabs.find(tab => tab.space === b.space && !tab.bench);
        if (next) await b.select(next.id); else await b.open();
        for (const tab of [...b.tabs].filter(tab => tab.space === space.id)) await b.close(tab.id);
        b.spaces = b.spaces.filter(item => item !== space);
        b.groups = b.groups.filter(group => group.space !== space.id);
        return { ok: true };
      }
      if (action === 'move') {
        const index = Number(r.index) - 1;
        if (!Number.isInteger(index) || index < 0 || index >= b.spaces.length) throw new BrowserError('INVALID_INDEX', 'Space index is out of range');
        b.spaces.splice(b.spaces.indexOf(space), 1); b.spaces.splice(index, 0, space);
        return { ok: true };
      }
      if (action === 'move-tab') {
        const tab = b.tab(r.tab);
        if (tab.private) throw new BrowserError('PRIVATE_TAB', 'Private tabs cannot change spaces');
        const source = b.spaces.find(item => item.id === tab.space);
        const sameStore = (source.store || source.id) === (space.store || space.id);
        if (!sameStore && !r.reload) throw new BrowserError('RELOAD_REQUIRED', 'Moving to an isolated sign-in store needs reload:true');
        if (!sameStore && !tab.sleeping) {
          const checkpoint = await b.adapter.evaluate(tab.id, capturePage);
          if (checkpoint.busy) throw new BrowserError('TAB_BUSY', checkpoint.reason);
          tab.resume = checkpoint;
          await b.adapter.close(tab.id); tab.sleeping = true;
        }
        tab.space = space.id; tab.group = null;
        await b.select(tab.id);
        return { ok: true };
      }
      throw new BrowserError('INVALID_COMMAND', 'Unknown space action');
    }
    case 'group': {
      const action = r.action || r.op;
      if (action === 'list') return structuredClone(b.groups);
      if (action === 'reopen') {
        const saved = b.closedGroups.shift();
        if (!saved) return { ok: false };
        if (!b.spaces.some(space => space.id === saved.group.space)) throw new BrowserError('SPACE_NOT_FOUND', 'The closed group’s space was deleted');
        b.groups.push(saved.group); b.tabs.push(...saved.tabs);
        await b.select(saved.tabs[0].id);
        return saved.group;
      }
      if (action === 'new') {
        const tab = b.tab(r.id);
        if (!normalTab(tab)) throw new BrowserError('PRIVATE_TAB', 'Only normal tabs can enter saved groups');
        const group = { id: randomUUID(), name: label(r.name) || 'Group', colour: 'sage', icon: '●', folded: false, space: tab.space };
        b.groups.push(group); tab.group = group.id;
        return group;
      }
      if (action === 'out') { b.tab(r.id).group = null; return { ok: true }; }
      const group = groupOf(b, r.group || r.id);
      const members = () => b.tabs.filter(tab => tab.group === group.id);
      switch (action) {
        case 'add': {
          const tab = b.tab(r.tab || r.id);
          if (!normalTab(tab) || tab.space !== group.space) throw new BrowserError('INVALID_GROUP', 'Group members must be normal tabs in the same space');
          tab.group = group.id; break;
        }
        case 'fold': group.folded = r.on ?? !group.folded; break;
        case 'rename': case 'renameui': group.name = label(r.name) || group.name; break;
        case 'colour': group.colour = ['grey', 'red', 'orange', 'yellow', 'sage', 'blue', 'purple', 'pink'].includes(r.colour) ? r.colour : ['grey', 'red', 'orange', 'yellow', 'sage', 'blue', 'purple', 'pink'][Number(r.index)] || 'sage'; break;
        case 'icon': group.icon = String(r.icon || '●').slice(0, 8); break;
        case 'newtab': { const tab = await b.open({ space: group.space }); b.tab(tab.id).group = group.id; return tab; }
        case 'ungroup': for (const tab of members()) tab.group = null; b.groups = b.groups.filter(item => item !== group); break;
        case 'close': {
          const tabs = members().map(tab => ({ ...tab, sleeping: true }));
          b.closedGroups.unshift({ group: { ...group }, tabs }); b.closedGroups = b.closedGroups.slice(0, 25);
          for (const tab of members()) await b.close(tab.id);
          b.groups = b.groups.filter(item => item !== group);
          b.closed = b.closed.filter(tab => tab.group !== group.id);
          break;
        }
        case 'bookmark': {
          for (const tab of members()) if (!b.bookmarks.some(item => item.url === tab.url)) b.bookmarks.push({ url: tab.url, title: tab.title, folder: group.name });
          break;
        }
        case 'space': {
          const source = b.spaces.find(space => space.id === group.space);
          const space = { id: randomUUID(), name: group.name, store: source.store || source.id };
          b.spaces.push(space); group.space = space.id;
          for (const tab of members()) tab.space = space.id;
          if (members().length) await b.select(members()[0].id);
          return space;
        }
        case 'move': {
          const tabs = members();
          const others = b.tabs.filter(tab => tab.group !== group.id);
          const index = Math.min(others.length, Math.max(0, Number(r.index) || 0));
          others.splice(index, 0, ...tabs); b.tabs = others; break;
        }
        default: throw new BrowserError('INVALID_COMMAND', 'Unknown group action');
      }
      return { ...group };
    }
    case 'settings': {
      const settings = structuredClone(b.settings);
      if (r.search !== undefined) settings.search = searchTemplate(r.search);
      for (const key of ['sidebar', 'shield', 'autoSleep', 'sideHides', 'readProgress']) if (r[key] !== undefined) settings[key] = Boolean(r[key]);
      if (r.look !== undefined) {
        if (!['system', 'light', 'dark'].includes(r.look)) throw new BrowserError('INVALID_SETTING', 'Unknown appearance');
        settings.look = r.look;
      }
      if (r.sleepMinutes !== undefined) {
        if (!Number.isFinite(r.sleepMinutes) || r.sleepMinutes < 1 || r.sleepMinutes > 1440) throw new BrowserError('INVALID_SETTING', 'Idle minutes must be 1–1440');
        settings.sleepMinutes = r.sleepMinutes;
      }
      if (r.pausedHost !== undefined) {
        if (typeof r.pausedHost !== 'string' || !/^[a-zA-Z0-9.-]+$/.test(r.pausedHost)) throw new BrowserError('INVALID_SETTING', 'Expected a hostname');
        settings.pausedHosts = [...new Set([...settings.pausedHosts, r.pausedHost])];
      }
      b.settings = settings;
      await b.adapter.refreshPolicies?.();
      return settings;
    }
    default: return UNHANDLED;
  }
}

export async function restoreCheckpoint(browser, tab) {
  if (tab.resume) await browser.adapter.evaluate(tab.id, restorePage, tab.resume);
  if (tab.zoom && browser.adapter.zoom) await browser.adapter.zoom(tab.id, tab.zoom);
  delete tab.resume;
}
