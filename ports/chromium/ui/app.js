const $ = selector => document.querySelector(selector);
const desktop = Boolean(window.searchHost);
let token = location.hash.slice(1);
if (token) history.replaceState(null, '', location.pathname);
let state;
let screenshotURL;
let refreshing = false;
let timer;
let engineChoices = [];

function notice(message) {
  $('#notice').textContent = message;
  $('#notice').hidden = false;
  clearTimeout(timer);
  timer = setTimeout(() => { $('#notice').hidden = true; }, 4000);
}
function guard(handler) {
  return function (...args) {
    try { return Promise.resolve(handler.apply(this, args)).catch(error => notice(error.message)); }
    catch (error) { notice(error.message); }
  };
}
function syncShell() {
  if (desktop && state) window.searchHost.shell({ sidebar: state.settings.sidebar, overlay: Boolean(document.querySelector('dialog[open]')) }).catch(error => notice(error.message));
}
async function choose(label, choices) {
  $('#choices-label').textContent = label;
  $('#choices-list').replaceChildren(...choices.map(choice => {
    const button = document.createElement('button'); button.textContent = choice.label;
    button.onclick = guard(async () => { $('#choices').close(); syncShell(); try { await choice.action(); await refresh(); } catch (error) { notice(error.message); } });
    return button;
  }));
  $('#choices').showModal(); syncShell();
}

async function call(request) {
  try {
    if (desktop) return await window.searchHost.execute(request);
    const response = await fetch('/api/command', {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify(request),
    });
    const value = await response.json();
    if (!response.ok) throw new Error(value.error);
    return value.result;
  } catch (error) { notice(error.message); throw error; }
}

async function act(request) { await call(request); await refresh(); }

function promptText(label, initial = '') {
  return new Promise(resolve => {
    $('#prompt-label').textContent = label;
    $('#prompt-value').value = initial;
    const finish = value => {
      $('#prompt-dialog').close();
      $('#prompt-form').onsubmit = null;
      $('#prompt-cancel').onclick = null;
      $('#prompt-dialog').oncancel = null;
      syncShell();
      resolve(value);
    };
    $('#prompt-form').onsubmit = event => { event.preventDefault(); finish($('#prompt-value').value); };
    $('#prompt-cancel').onclick = () => finish(null);
    $('#prompt-dialog').oncancel = event => { event.preventDefault(); finish(null); };
    $('#prompt-dialog').showModal();
    syncShell();
    $('#prompt-value').focus();
  });
}

function render() {
  document.documentElement.dataset.look = state.settings.look;
  document.body.classList.toggle('no-sidebar', !state.settings.sidebar);
  $('#engine-badge').textContent = state.tabs.find(tab => tab.id === state.active)?.engine || state.engine;
  $('#renderer-control').hidden = desktop || engineChoices.length < 2;
  $('#renderer-choice').replaceChildren(...engineChoices.map(engine => { const option = document.createElement('option'); option.value = engine.id; option.textContent = engine.id; return option; }));
  $('#renderer-choice').value = state.engine;
  $('#spaces').replaceChildren(...state.spaces.map(space => {
    const option = document.createElement('option');
    option.value = space.id;
    option.textContent = space.name;
    return option;
  }));
  $('#spaces').value = state.space;
  const selected = state.tabs.find(tab => tab.id === state.active);
  if (document.activeElement !== $('#address')) $('#address').value = selected?.url === 'about:blank' ? '' : selected?.url || '';
  const makeTab = tab => {
    const row = document.createElement('div');
    row.className = `tab${tab.id === state.active ? ' active' : ''}`;
    const select = document.createElement('button');
    select.textContent = `${tab.private ? '◈ ' : tab.pin ? '● ' : ''}${tab.loading ? '◌ ' : ''}${tab.name || tab.title || (tab.url === 'about:blank' ? 'New tab' : tab.url)}`;
    select.title = tab.url;
    select.onclick = () => act({ do: 'select', id: tab.id }).catch(() => {});
    const close = document.createElement('button');
    close.textContent = '×';
    close.setAttribute('aria-label', `Close ${tab.title || 'tab'}`);
    close.onclick = () => act({ do: 'close', id: tab.id }).catch(() => {});
    row.append(select, close);
    row.classList.toggle('grouped', Boolean(tab.group));
    row.draggable = true;
    row.ondragstart = event => { event.dataTransfer.setData('search/tab', tab.id); };
    row.ondragover = event => event.preventDefault();
    row.ondrop = event => { event.preventDefault(); const id = event.dataTransfer.getData('search/tab'); if (id) act({ do: 'place', id, index: state.tabs.findIndex(item => item.id === tab.id) }).catch(() => {}); };
    row.oncontextmenu = event => {
      event.preventDefault();
      choose(tab.name || tab.title || 'Tab', [
        { label: tab.pin ? 'Unpin' : 'Pin', action: () => act({ do: 'pin', id: tab.id }) },
        { label: 'Rename', action: async () => { const name = await promptText('Rename tab', tab.name || tab.title); if (name !== null) await act({ do: 'rename', id: tab.id, name }); } },
        { label: 'Duplicate', action: () => act({ do: 'duplicate', id: tab.id }) },
        { label: 'New group', action: async () => { const name = await promptText('Name your group'); if (name) await act({ do: 'group', action: 'new', id: tab.id, name }); } },
        { label: 'Remove from group', action: () => act({ do: 'group', action: 'out', id: tab.id }) },
        { label: 'Sleep', action: () => act({ do: 'sleep', id: tab.id }) },
        { label: 'Close other tabs', action: () => act({ do: 'close-others', id: tab.id }) },
      ]).catch(() => {});
    };
    return row;
  };
  const visibleTabs = state.tabs.filter(tab => tab.space === state.space && !tab.bench);
  const grouped = () => {
    const result = []; const visited = new Set();
    for (const tab of visibleTabs) {
      const group = state.groups.find(group => group.id === tab.group);
      if (group && !visited.has(group.id)) {
        visited.add(group.id);
        const chip = document.createElement('div'); chip.className = 'group-chip'; chip.dataset.colour = group.colour || 'sage';
        const toggle = document.createElement('button'); toggle.textContent = `${group.folded ? '▸' : '▾'} ${group.icon || '●'} ${group.name}`;
        toggle.onclick = () => act({ do: 'group', action: 'fold', group: group.id }).catch(() => {});
        chip.append(toggle); chip.ondragover = event => event.preventDefault();
        chip.ondrop = event => { event.preventDefault(); const id = event.dataTransfer.getData('search/tab'); if (id) act({ do: 'group', action: 'add', group: group.id, id }).catch(() => {}); };
        chip.oncontextmenu = event => {
          event.preventDefault(); choose(group.name, [
            { label: 'New tab in group', action: () => act({ do: 'group', action: 'newtab', group: group.id }) },
            { label: 'Rename', action: async () => { const name = await promptText('Rename group', group.name); if (name) await act({ do: 'group', action: 'rename', group: group.id, name }); } },
            { label: 'Colour', action: () => choose('Choose a colour', ['grey','red','orange','yellow','sage','blue','purple','pink'].map(colour => ({ label: colour, action: () => act({ do: 'group', action: 'colour', group: group.id, colour }) }))) },
            { label: 'Icon', action: async () => { const icon = await promptText('Choose an icon', group.icon || '●'); if (icon) await act({ do: 'group', action: 'icon', group: group.id, icon }); } },
            { label: 'Bookmark group', action: () => act({ do: 'group', action: 'bookmark', group: group.id }) },
            { label: 'Move to a new space', action: () => act({ do: 'group', action: 'space', group: group.id }) },
            { label: 'Ungroup', action: () => act({ do: 'group', action: 'ungroup', group: group.id }) },
            { label: 'Close group', action: () => act({ do: 'group', action: 'close', group: group.id }) },
            { label: 'Reopen closed group', action: () => act({ do: 'group', action: 'reopen' }) },
          ]).catch(() => {});
        };
        result.push(chip);
      }
      if (!group?.folded || tab.id === state.active) result.push(makeTab(tab));
    }
    return result;
  };
  $('#tabs').replaceChildren(...grouped());
  const add = document.createElement('button');
  add.textContent = '＋';
  add.setAttribute('aria-label', 'New tab');
  add.onclick = () => shortcut('new').catch(() => {});
  $('#top-tabs').replaceChildren(...grouped(), add);
  $('#appearance').value = state.settings.look;
  $('#search-engine').value = state.settings.search;
  $('#shield').checked = state.settings.shield;
  $('#auto-sleep').checked = state.settings.autoSleep;
  $('#sleep-minutes').value = state.settings.sleepMinutes;
  $('#pip').disabled = !state.capabilities.pictureInPicture;
  $('#devtools').disabled = !state.capabilities.devtools;
  $('#print').disabled = !state.capabilities.printing;
  for (const id of ['password-list', 'password-save', 'password-import']) $(`#${id}`).disabled = !state.capabilities.passwords;
  $('#vault-status').textContent = state.capabilities.passwords ? 'Encrypted using your system keychain.' : 'A secure system keychain is unavailable on this device.';
  for (const id of ['extension-store', 'extension-folder']) $(`#${id}`).disabled = !state.capabilities.extensions;
  for (const key of ['bookmarks', 'history']) {
    const query = $('#library-search').value.toLowerCase();
    $(`#${key}`).replaceChildren(...state[key].filter(item => `${item.title} ${item.url}`.toLowerCase().includes(query)).slice(0, 100).map(item => {
      const row = document.createElement('div'); row.className = 'entry';
      const button = document.createElement('button');
      button.textContent = item.title || item.url;
      button.title = item.url;
      button.onclick = guard(async () => { closeLibrary(); await act({ do: 'open', url: item.url }); });
      row.append(button);
      if (key === 'bookmarks') {
        const edit = document.createElement('button'); edit.textContent = 'Edit';
        edit.onclick = guard(async () => { const title = await promptText('Bookmark title', item.title); if (title !== null) await act({ do: 'bookmark-edit', url: item.url, title }); });
        const remove = document.createElement('button'); remove.textContent = '×'; remove.setAttribute('aria-label', `Remove ${item.title}`);
        remove.onclick = () => act({ do: 'bookmark-remove', url: item.url }).catch(() => {});
        row.append(edit, remove);
      }
      return row;
    }));
  }
  const blank = !selected || selected.url === 'about:blank';
  $('#empty').hidden = !blank || desktop;
  $('#page').hidden = blank || desktop;
  $('#page-failure').hidden = !selected?.failure;
  $('#page-failure').textContent = selected?.failure || '';
  $('#downloads').replaceChildren(...(state.downloads || []).map(item => {
    const row = document.createElement('div'); row.className = 'entry';
    const name = document.createElement('span'); name.textContent = `${item.name} · ${item.state}`;
    const save = document.createElement('button'); save.textContent = 'Save';
    save.onclick = guard(async () => {
      try {
        if (desktop) await act({ do: 'download-dialog', id: item.tab, downloadId: item.id });
        else { const result = await call({ do: 'download-get', id: item.tab, downloadId: item.id }); downloadBlob(Uint8Array.from(atob(result.base64), char => char.charCodeAt(0)), result.name, 'application/octet-stream'); }
      } catch (error) { notice(error.message); }
    });
    row.append(name, save); return row;
  }));
  $('#extensions').replaceChildren(...(state.extensions || []).map(item => {
    const row = document.createElement('div'); row.className = 'entry';
    const open = document.createElement('button'); open.textContent = `${item.name}${item.error ? ' · failed to load' : ''}`;
    open.onclick = () => act({ do: 'ext-press', id: item.id }).catch(() => {});
    for (const [label, command] of [['Reload', 'ext-reload'], [item.enabled ? 'Disable' : 'Enable', 'ext-enable'], ['Remove', 'ext-remove']]) {
      const button = document.createElement('button'); button.textContent = label;
      button.onclick = () => act({ do: command, id: item.id, on: !item.enabled }).catch(() => {});
      row.append(button);
    }
    row.prepend(open); return row;
  }));
  syncShell();
}

async function refresh() {
  if (refreshing || (!desktop && !token)) return;
  refreshing = true;
  try {
    const next = await call({ do: 'probe' });
    const loadedEngines = engineChoices.length === 0;
    if (loadedEngines) engineChoices = await call({ do: 'engines' });
    // Avoid rebuilding focused controls on every screenshot frame.
    if (loadedEngines || JSON.stringify(next) !== JSON.stringify(state)) { state = next; render(); }
    const active = state.tabs.find(tab => tab.id === state.active);
    if (!desktop && active?.url !== 'about:blank' && !document.querySelector('dialog[open]')) {
      const response = await fetch(`/api/screenshot?id=${encodeURIComponent(state.active)}`, { headers: { Authorization: `Bearer ${token}` } });
      if (response.ok) {
        const blob = await response.blob();
        const previous = screenshotURL;
        screenshotURL = URL.createObjectURL(blob);
        $('#page').src = screenshotURL;
        if (previous) URL.revokeObjectURL(previous);
      }
    }
  } catch { /* Errors are shown by call; retry at the next refresh. */ }
  finally { refreshing = false; }
}

function closeLibrary() {
  $('#library').close();
  syncShell();
}

async function shortcut(action) {
  if (action === 'address') { closeLibrary(); $('#address').focus(); $('#address').select(); return; }
  if (action === 'new' || action === 'private') { await act({ do: 'open', private: action === 'private' }); $('#address').focus(); return; }
  if (action === 'tabs') {
    const text = await promptText('Search open tabs');
    if (text !== null) { const tabs = await call({ do: 'search-tabs', text }); await choose('Open tabs', tabs.map(tab => ({ label: tab.name || tab.title || tab.url, action: () => act({ do: 'select', id: tab.id }) }))); }
    return;
  }
  if (action === 'find') {
    const text = await promptText('Find on this page');
    if (text !== null) { closeLibrary(); await act({ do: 'find', text }); }
    return;
  }
  await act({ do: action });
}

$('#address-form').onsubmit = guard(async event => { event.preventDefault(); await act({ do: 'go', text: $('#address').value }); $('#surface').focus(); });
for (const [id, action] of Object.entries({ back: 'back', forward: 'forward', reload: 'reload', bookmark: 'bookmark', 'new-tab': 'new', 'private-tab': 'private', reader: 'reader', find: 'find', reopen: 'reopen' })) {
  $(`#${id}`).onclick = () => shortcut(action).catch(() => {});
}
$('#sidebar-toggle').onclick = () => act({ do: 'settings', sidebar: !state.settings.sidebar }).catch(() => {});
$('#more').onclick = () => {
  $('#library').showModal();
  syncShell();
};
$('#close-library').onclick = closeLibrary;
$('#library').oncancel = () => { setTimeout(syncShell, 0); };
$('#spaces').onchange = () => act({ do: 'space', action: 'go', id: $('#spaces').value }).catch(() => {});
$('#new-space').onclick = guard(async () => {
  const name = await promptText('Name your space');
  if (name) await act({ do: 'space', action: 'new', name, fresh: !$('#shared-space').checked });
});
$('#appearance').onchange = () => act({ do: 'settings', look: $('#appearance').value }).catch(() => {});
$('#search-engine').onchange = () => act({ do: 'settings', search: $('#search-engine').value }).catch(() => {});
$('#shield').onchange = () => act({ do: 'settings', shield: $('#shield').checked }).catch(() => {});
$('#clear-history').onclick = () => act({ do: 'history-clear' }).catch(() => {});
$('#library-search').oninput = render;
$('#custom-search').onchange = () => act({ do: 'settings', search: $('#custom-search').value }).catch(() => {});
$('#auto-sleep').onchange = () => act({ do: 'settings', autoSleep: $('#auto-sleep').checked }).catch(() => {});
$('#sleep-minutes').onchange = () => act({ do: 'settings', sleepMinutes: Number($('#sleep-minutes').value) }).catch(() => {});
$('#address').oninput = guard(async () => {
  const values = await call({ do: 'suggest', text: $('#address').value });
  $('#address-suggestions').replaceChildren(...values.map(item => { const option = document.createElement('option'); option.value = item.url; option.label = item.title; return option; }));
});
$('#tab-search').onclick = () => shortcut('tabs').catch(() => {});
$('#hide-picker').onclick = guard(async () => { closeLibrary(); await act({ do: 'pick-hide' }); notice('Click something to hide. Escape stops picking.'); });
$('#hidden-review').onclick = guard(async () => {
  const result = await call({ do: 'hidden-list' });
  await choose('Hidden on this site', result.selectors.map(selector => ({ label: `Restore ${selector}`, action: () => act({ do: 'unhide', selector }) })));
});
$('#shield-site').onclick = guard(async () => {
  const tab = state.tabs.find(tab => tab.id === state.active); const host = new URL(tab.url).hostname;
  await act({ do: 'shield-site', on: state.settings.pausedHosts.includes(host) });
});
$('#pip').onclick = guard(async () => { closeLibrary(); await act({ do: 'picture-in-picture' }); });
$('#devtools').onclick = () => act({ do: 'devtools' }).catch(() => {});
$('#print').onclick = () => act({ do: 'print' }).catch(() => {});
$('#close-choices').onclick = () => { $('#choices').close(); syncShell(); };
$('#choices').oncancel = () => setTimeout(syncShell, 0);
function downloadBlob(data, name, type) {
  const url = URL.createObjectURL(new Blob([data], { type }));
  const anchor = document.createElement('a'); anchor.href = url; anchor.download = name; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
$('#library-export').onclick = guard(async () => downloadBlob(JSON.stringify(await call({ do: 'library-export' }), null, 2), 'Search-library.json', 'application/json'));
$('#library-import').onclick = () => $('#library-file').click();
$('#library-file').onchange = guard(async () => {
  const file = $('#library-file').files[0]; if (!file) return;
  try {
    const text = await file.text(); let data;
    if (/\.html?$/i.test(file.name)) { const document = new DOMParser().parseFromString(text, 'text/html'); data = { bookmarks: [...document.querySelectorAll('a[href]')].map(anchor => ({ url: anchor.getAttribute('href'), title: anchor.textContent })).filter(item => /^https?:/.test(item.url)) }; }
    else data = JSON.parse(text);
    const result = await call({ do: 'library-import', data }); notice(`Imported ${result.bookmarks} bookmarks and ${result.history} history entries.`); await refresh();
  } catch (error) { notice(error.message); } finally { $('#library-file').value = ''; }
});
$('#extension-folder').onclick = guard(async () => {
  const path = desktop ? await window.searchHost.chooseFolder() : await promptText('Extension folder');
  if (path) await installExtension({ do: 'ext-folder', path });
});
$('#extension-store').onclick = guard(async () => { const id = await promptText('Chrome Web Store link or extension ID'); if (id) await installExtension({ do: 'ext-add', id }); });
async function installExtension(request) {
  const result = await call(request);
  if (result.confirmation) await choose(`Install ${result.confirmation.name}?`, [
    { label: `Allow permissions: ${(result.confirmation.permissions || []).join(', ') || 'none'}. Sites: ${(result.confirmation.hosts || []).join(', ') || 'none'}`, action: () => act({ ...request, yes: true }) },
    { label: 'Cancel', action: () => {} },
  ]);
}
$('#password-list').onclick = guard(async () => {
  const accounts = await call({ do: 'password', action: 'list' });
  await choose('Saved accounts for this page', accounts.flatMap(account => [
    { label: `Fill ${account.username}`, action: async () => { closeLibrary(); await act({ do: 'password', action: 'fill', account: account.id }); } },
    { label: `Remove ${account.username}`, action: () => act({ do: 'password', action: 'remove', account: account.id }) },
  ]));
});
$('#password-save').onclick = () => { $('#account-dialog').showModal(); syncShell(); };
$('#account-cancel').onclick = () => { $('#account-user').value = ''; $('#account-password').value = ''; $('#account-dialog').close(); syncShell(); };
$('#account-dialog').oncancel = () => { $('#account-password').value = ''; setTimeout(syncShell, 0); };
$('#account-form').onsubmit = guard(async event => {
  event.preventDefault();
  try { await call({ do: 'password', action: 'save', username: $('#account-user').value, password: $('#account-password').value }); $('#account-dialog').close(); notice('Account saved.'); }
  finally { $('#account-user').value = ''; $('#account-password').value = ''; syncShell(); }
});
$('#password-import').onclick = () => $('#password-file').click();
$('#password-file').onchange = guard(async () => {
  const file = $('#password-file').files[0]; if (!file) return;
  try { const result = await call({ do: 'password', action: 'import', csv: await file.text() }); notice(`Imported ${result.imported} accounts.`); }
  finally { $('#password-file').value = ''; }
});
$('#update-check').onclick = guard(async () => {
  const manifest = await call({ do: 'update-check' });
  await choose(`Version ${manifest.version} is available`, [{ label: 'Download verified update', action: () => act({ do: 'update-stage', manifest }) }]);
});
$('#mobile-keyboard').onclick = () => $('#page-keyboard').focus();
$('#page-keyboard').oninput = guard(async event => { if (event.data) await call({ do: 'input', kind: 'text', text: event.data }); $('#page-keyboard').value = ''; });
$('#page-keyboard').onkeydown = event => { if (['Backspace', 'Enter', 'Tab'].includes(event.key)) { event.preventDefault(); call({ do: 'input', kind: 'key', key: event.key }).catch(() => {}); } };
document.addEventListener('keydown', event => {
  if (!(event.ctrlKey || event.metaKey)) return;
  const actions = { l: 'address', t: event.shiftKey ? 'reopen' : 'new', w: 'close', r: event.shiftKey ? 'reader' : 'reload', k: 'tabs', f: 'find', d: 'bookmark' };
  if (event.shiftKey && event.key.toLowerCase() === 'n') actions.n = 'private';
  const action = actions[event.key.toLowerCase()];
  if (action) { event.preventDefault(); shortcut(action).catch(() => {}); }
});

if (desktop) {
  const identity = await call({ do: 'identity' }); document.title = identity.name; $('.brand span').textContent = identity.name;
  window.searchHost.onShortcut(action => shortcut(action).catch(() => {}));
  $('#agent-control').hidden = false; $('#default-browser').hidden = false;
  $('#agent-enabled').checked = (await call({ do: 'agent-status' })).enabled;
  $('#agent-enabled').onchange = () => call({ do: 'agent-set', on: $('#agent-enabled').checked }).catch(() => { $('#agent-enabled').checked = !$('#agent-enabled').checked; });
  $('#default-browser').onclick = () => call({ do: 'default-browser' }).then(result => notice(result.registered ? 'Default browser registration requested.' : 'Choose this app in your system default browser settings.')).catch(() => {});
}
else {
  $('#connect-form').onsubmit = guard(async event => {
    event.preventDefault(); token = $('#token').value; $('#token').value = ''; $('#connect').close();
    const result = await call({ do: 'probe' }).catch(() => null);
    if (!result) { token = ''; $('#connect').showModal(); } else { state = result; render(); await refresh(); }
  });
  if (!token) $('#connect').showModal();
  const resize = new ResizeObserver(() => {
    const rect = $('#surface').getBoundingClientRect();
    if (token && rect.width >= 100 && rect.height >= 100) call({ do: 'bounds', width: Math.min(4096, rect.width), height: Math.min(4096, rect.height) }).catch(() => {});
  });
  resize.observe($('#surface'));
  const clickPage = async event => {
    const rect = $('#page').getBoundingClientRect();
    $('#surface').focus();
    await call({ do: 'input', kind: 'click', x: (event.clientX - rect.left) * $('#page').naturalWidth / rect.width, y: (event.clientY - rect.top) * $('#page').naturalHeight / rect.height });
    await refresh();
  };
  let pointer;
  $('#page').onpointerdown = event => {
    pointer = { x: event.clientX, y: event.clientY, startX: event.clientX, startY: event.clientY, moved: false };
    if (event.pointerType === 'touch') $('#page').setPointerCapture(event.pointerId);
  };
  $('#page').onpointermove = event => {
    if (!pointer || event.pointerType !== 'touch') return;
    const dy = pointer.y - event.clientY;
    if (Math.abs(event.clientY - pointer.startY) > 5) pointer.moved = true;
    if (pointer.moved) call({ do: 'input', kind: 'wheel', dy }).catch(() => {});
    pointer.y = event.clientY;
  };
  $('#page').onpointerup = event => {
    if (pointer && !pointer.moved) clickPage(event).catch(() => {});
    pointer = null;
  };
  $('#page').onpointercancel = () => { pointer = null; };
  $('#surface').onwheel = event => { event.preventDefault(); call({ do: 'input', kind: 'wheel', dx: event.deltaX, dy: event.deltaY }).catch(() => {}); };
  $('#surface').onkeydown = event => {
    if (event.ctrlKey || event.metaKey) return;
    event.preventDefault();
    call(event.key.length === 1 ? { do: 'input', kind: 'text', text: event.key } : { do: 'input', kind: 'key', key: event.key }).catch(() => {});
  };
}

await refresh();
$('#renderer-choice').onchange = () => act({ do: 'renderer-set', engine: $('#renderer-choice').value }).then(() => notice('New tabs use this renderer. Existing tabs stay open; sign-ins are separate.')).catch(() => { $('#renderer-choice').value = state.engine; });
setInterval(refresh, desktop ? 600 : 400);
