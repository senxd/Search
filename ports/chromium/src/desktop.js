import { app, BrowserWindow, ipcMain, Menu, dialog } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, readFile, writeFile, rm, chmod } from 'node:fs/promises';
import http from 'node:http';
import { Browser } from './browser.js';
import { Store } from './store.js';
import { EngineRegistry, BrowserError } from './contract.js';
import { ElectronAdapter } from './adapters/electron.js';
import { UpdateService } from './services/updates.js';
import { startServer } from './server.js';
import { validateURL } from './address.js';

const root = path.dirname(fileURLToPath(import.meta.url));
const smoke = process.argv.includes('--smoke');
const profile = process.env.SEARCH_PROFILE || path.join(app.getPath('appData'), 'Search Chromium');
await mkdir(profile, { recursive: true, mode: 0o700 });
app.setPath('userData', profile);
app.setPath('crashDumps', path.join(profile, 'crashes'));
if (!app.requestSingleInstanceLock()) app.quit();
else {
  await app.whenReady();
  const window = new BrowserWindow({
    title: 'Search Chromium', width: 1180, height: 780, minWidth: 720, minHeight: 420,
    show: !smoke, autoHideMenuBar: true,
    webPreferences: { preload: path.join(root, 'preload.cjs'), contextIsolation: true, sandbox: true, nodeIntegration: false },
  });
  const shortcut = action => window.webContents.send('search:shortcut', action);
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    ...(process.platform === 'darwin' ? [{ label: app.getName(), submenu: [{ role: 'about' }, { type: 'separator' }, { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' }, { role: 'quit' }] }] : []),
    { label: 'File', submenu: [{ label: 'New tab', accelerator: 'CommandOrControl+T', click: () => shortcut('new') }, { label: 'Private tab', accelerator: 'CommandOrControl+Shift+N', click: () => shortcut('private') }, { label: 'Reopen closed tab', accelerator: 'CommandOrControl+Shift+T', click: () => shortcut('reopen') }, { type: 'separator' }, { role: 'close' }] },
    { role: 'editMenu' }, { role: 'viewMenu' }, { role: 'windowMenu' },
  ]));
  const registry = new EngineRegistry();
  registry.register('electron', () => new ElectronAdapter({ window, directory: profile, permissionPrompt: async ({ origin, permission }) => {
    const { response } = await dialog.showMessageBox(window, { type: 'question', title: 'Site permission', message: `${origin} wants to use ${permission}`, buttons: ['Deny', 'Allow for this session'], defaultId: 0, cancelId: 0 });
    return response === 1;
  }, passwordPrompt: async ({ origin, username, updating }) => {
    const { response } = await dialog.showMessageBox(window, { type: 'question', title: updating ? 'Update saved account' : 'Save account', message: `${updating ? 'Update' : 'Save'} the account ${username || '(no username)'} for ${origin}?`, buttons: ['Not now', updating ? 'Update' : 'Save'], defaultId: 0, cancelId: 0 });
    return response === 1;
  }, nativePrompt: async ({ extension, host }) => {
    const { response } = await dialog.showMessageBox(window, { type: 'question', title: 'Native extension host', message: `${extension} wants to communicate with the installed program ${host}.`, buttons: ['Deny', 'Allow for this session'], defaultId: 0, cancelId: 0 });
    return response === 1;
  } }));
  const browser = new Browser({ registry, engine: 'electron', store: new Store(profile) });
  let agentServer;
  const connectionFile = path.join(profile, 'connection.json');
  async function setAgent(on) {
    if (on && !agentServer) {
      agentServer = await startServer(browser, { port: Number(process.env.SEARCH_AGENT_PORT || 0) });
      await writeFile(connectionFile, JSON.stringify({ url: agentServer.url, token: agentServer.token }), { mode: 0o600 });
      await chmod(connectionFile, 0o600);
    } else if (!on && agentServer) {
      await agentServer.stop(); agentServer = null;
      await rm(connectionFile, { force: true });
    }
    return { enabled: Boolean(agentServer) };
  }
  if (process.env.SEARCH_UPDATE_FEED && process.env.SEARCH_UPDATE_PUBLIC_KEY_FILE) {
    browser.updater = new UpdateService({ feed: process.env.SEARCH_UPDATE_FEED, publicKey: await readFile(process.env.SEARCH_UPDATE_PUBLIC_KEY_FILE, 'utf8'), directory: path.join(profile, 'updates'), currentVersion: '0.1.0' });
  }
  const shellURL = new URL('../ui/index.html', import.meta.url).href;
  const allowed = new Set(['manifest', 'parity', 'probe', 'tabs', 'engines', 'open', 'go', 'select', 'close', 'reopen', 'back', 'forward', 'reload', 'reader', 'find', 'bookmark', 'bookmark-remove', 'history-clear', 'settings', 'space', 'group', 'pin', 'sleep', 'devtools', 'print']);
  for (const command of ['suggest', 'search-tabs', 'duplicate', 'rename', 'place', 'step', 'close-others', 'zoom', 'library', 'library-import', 'library-export', 'bookmark-edit', 'hidden-list', 'unhide', 'pick-hide', 'shield-site', 'picture-in-picture', 'password', 'extensions', 'ext-folder', 'ext-add', 'ext-remove', 'ext-reload', 'ext-enable', 'ext-pin', 'ext-press', 'native-authorize', 'update-check', 'update-stage']) allowed.add(command);
  function checkSender(event) {
    if (event.sender !== window.webContents || event.senderFrame?.url !== shellURL) throw new BrowserError('FORBIDDEN', 'Only the trusted shell can invoke browser controls');
  }
  ipcMain.handle('search:command', async (event, request) => {
    checkSender(event);
    if (request.do === 'identity') return { name: app.isPackaged ? 'Browser Lab' : 'Search Chromium' };
    if (request.do === 'agent-status') return { enabled: Boolean(agentServer) };
    if (request.do === 'agent-set') return setAgent(request.on === true);
    if (request.do === 'default-browser') return { registered: app.setAsDefaultProtocolClient('http') && app.setAsDefaultProtocolClient('https') };
    if (request.do === 'download-dialog') {
      const { canceled, filePath } = await dialog.showSaveDialog(window, { title: 'Save download' });
      return canceled ? { canceled: true } : browser.execute({ do: 'download-save', id: request.id, downloadId: request.downloadId, path: filePath });
    }
    if (!allowed.has(request.do)) throw new BrowserError('FORBIDDEN', 'Command is not available to the shell');
    return browser.execute(request);
  });
  ipcMain.handle('search:choose-folder', async event => {
    checkSender(event);
    const { canceled, filePaths } = await dialog.showOpenDialog(window, { title: 'Load extension folder', properties: ['openDirectory'] });
    return canceled ? null : filePaths[0];
  });
  ipcMain.handle('search:shell', async (event, options) => {
    checkSender(event);
    return browser.adapter.shell({ sidebar: options.sidebar !== false, overlay: options.overlay === true });
  });
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.on('resize', () => browser.adapter?.setBounds());
  let closing = false;
  window.on('close', event => {
    if (closing) return;
    event.preventDefault();
    closing = true;
    setAgent(false).then(() => browser.stop()).finally(() => window.destroy());
  });
  app.on('window-all-closed', () => app.quit());
  await browser.start();
  if (process.env.SEARCH_AGENT_PORT || process.argv.includes('--agent')) await setAgent(true);
  async function openExternal(url) {
    try { await browser.execute({ do: 'open', url: validateURL(url) }); if (window.isMinimized()) window.restore(); window.show(); window.focus(); }
    catch (error) { console.error('Cannot open external link:', error.message); }
  }
  app.on('open-url', (event, url) => { event.preventDefault(); openExternal(url); });
  app.on('second-instance', (_event, argv) => { const url = argv.find(argument => /^https?:\/\//.test(argument)); if (url) openExternal(url); else { window.show(); window.focus(); } });
  const initialURL = process.argv.find(argument => /^https?:\/\//.test(argument));
  if (initialURL) await openExternal(initialURL);
  await window.loadURL(shellURL);
  if (smoke) {
    const fixture = http.createServer((request, response) => {
      if (request.url === '/download') {
        response.setHeader('Content-Disposition', 'attachment; filename="sample.txt"');
        response.end('Desktop download');
        return;
      }
      response.setHeader('Content-Type', 'text/html');
      if (request.url !== '/private') response.setHeader('Set-Cookie', 'desktop=normal; SameSite=Lax; Path=/');
      response.end('<title>Desktop fixture</title><input id="name"><button onclick="document.querySelector(\'h1\').textContent=document.querySelector(\'#name\').value">Send</button><h1>Native Chromium</h1><a id="download" href="/download">Download</a>');
    });
    await new Promise(resolve => fixture.listen(0, '127.0.0.1', resolve));
    try {
      await setAgent(true);
      const reply = await fetch(`${agentServer.url}/api/command`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${agentServer.token}` }, body: JSON.stringify({ do: 'eval', js: '1+1' }) });
      if ((await reply.json()).result !== 2) throw new Error('Desktop agent transport failed');
      const result = await browser.execute({ do: 'eval', js: 'typeof require' });
      if (result !== 'undefined') throw new Error('Remote page has a Node bridge');
      const title = await window.webContents.executeJavaScript('document.title');
      if (title !== (app.isPackaged ? 'Browser Lab' : 'Search Chromium')) throw new Error('Shell failed to load');
      const url = `http://localhost:${fixture.address().port}/`;
      const tab = await browser.execute({ do: 'open', url });
      await browser.execute({ do: 'wait', id: tab.id });
      await browser.execute({ do: 'type', id: tab.id, selector: '#name', text: 'Desktop works' });
      await browser.execute({ do: 'click', id: tab.id, selector: 'button' });
      if (!(await browser.execute({ do: 'text', id: tab.id })).includes('Desktop works')) throw new Error('Desktop form failed');
      if (await browser.execute({ do: 'eval', id: tab.id, js: 'typeof window.searchHost' }) !== 'undefined') throw new Error('Remote page has the shell bridge');
      await browser.execute({ do: 'eval', id: tab.id, js: 'localStorage.setItem("desktop-secret","normal")' });
      const privateTab = await browser.execute({ do: 'open', url: `${url}private`, private: true });
      if (await browser.execute({ do: 'eval', id: privateTab.id, js: 'localStorage.getItem("desktop-secret")' }) !== null) throw new Error('Private store leaked');
      if (await browser.execute({ do: 'eval', id: privateTab.id, js: 'document.cookie' }) !== '') throw new Error('Private cookies leaked');
      await browser.execute({ do: 'close', id: privateTab.id });
      await browser.execute({ do: 'click', id: tab.id, selector: '#download' });
      for (let attempt = 0; attempt < 30 && !browser.adapter.metadata.get(tab.id)?.downloadId; attempt++) await new Promise(resolve => setTimeout(resolve, 30));
      const destination = path.join(profile, 'desktop-download.txt');
      await browser.execute({ do: 'download-save', id: tab.id, path: destination });
      if (await readFile(destination, 'utf8') !== 'Desktop download') throw new Error('Desktop download failed');
      await browser.execute({ do: 'select', id: tab.id });
      await browser.execute({ do: 'hide', id: tab.id, selector: 'h1' });
      await browser.execute({ do: 'reload', id: tab.id });
      await browser.execute({ do: 'wait', id: tab.id });
      if (await browser.execute({ do: 'eval', id: tab.id, js: 'getComputedStyle(document.querySelector("h1")).display' }) !== 'none') throw new Error('Document-start policy failed');
      await browser.execute({ do: 'unhide', id: tab.id, selector: 'h1' });
      const web = browser.adapter.view(tab.id).webContents;
      web.debugger.attach('1.3');
      await web.debugger.sendCommand('WebAuthn.enable');
      await web.debugger.sendCommand('WebAuthn.addVirtualAuthenticator', { options: { protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
      const credential = await browser.execute({ do: 'eval', id: tab.id, js: `navigator.credentials.create({publicKey:{rp:{name:'Search test',id:'localhost'},user:{id:new Uint8Array([1]),name:'fixture',displayName:'Fixture'},challenge:new Uint8Array([1,2,3,4]),pubKeyCredParams:[{type:'public-key',alg:-7}],authenticatorSelection:{residentKey:'required',userVerification:'required'},timeout:10000}}).then(credential=>credential.id).catch(error=>{throw new Error(error.name+': '+error.message)})` });
      if (typeof credential !== 'string' || !credential) throw new Error('WebAuthn credential creation failed');
      web.debugger.detach();
      await browser.execute({ do: 'eval', id: tab.id, js: 'document.body.insertAdjacentHTML("beforeend","<video id=video muted></video>")' });
      const identity = web.id;
      await browser.execute({ do: 'picture-in-picture', id: tab.id });
      if (browser.adapter.floating.view.webContents.id !== identity) throw new Error('Picture-in-picture replaced the live page');
      await browser.execute({ do: 'picture-in-picture', id: tab.id });
      const source = path.join(profile, 'fixture-extension');
      await mkdir(source, { recursive: true });
      await writeFile(path.join(source, 'manifest.json'), JSON.stringify({ manifest_version: 3, name: 'Desktop fixture extension', version: '1.0', permissions: ['storage', 'tabs', 'scripting', 'activeTab', 'nativeMessaging'], action: { default_popup: 'popup.html' }, content_scripts: [{ matches: ['http://localhost/*'], js: ['content.js'] }] }));
      await writeFile(path.join(source, 'content.js'), 'document.documentElement.dataset.extensionFixture="works";');
      await writeFile(path.join(source, 'popup.html'), '<title>Fixture popup</title><script src="popup.js"></script>');
      await writeFile(path.join(source, 'popup.js'), `window.fixtureDone=(async()=>{const tabs=await chrome.tabs.query({active:true});if(tabs.length!==1)throw new Error('Extension tabs query failed');const result=await chrome.scripting.executeScript({target:{tabId:tabs[0].id},func:()=>{document.documentElement.dataset.injectedFixture='works';return typeof require}});if(result[0].result!=='undefined')throw new Error('Extension injection got Node access');return chrome.runtime.sendNativeMessage('org.search.fixture',{fixture:'echo'})})().then(result=>({result}),error=>({error:error.message}));`);
      const extension = await browser.execute({ do: 'ext-folder', path: source, yes: true });
      await browser.execute({ do: 'reload', id: tab.id });
      await browser.execute({ do: 'wait', id: tab.id });
      if (await browser.execute({ do: 'eval', id: tab.id, js: 'document.documentElement.dataset.extensionFixture' }) !== 'works') throw new Error('Extension content script failed');
      const hosts = path.join(profile, 'native-hosts'); await mkdir(hosts);
      const program = path.join(hosts, 'echo.cjs');
      await writeFile(program, '#!/usr/bin/env node\nlet input=Buffer.alloc(0);process.stdin.on("data",chunk=>{input=Buffer.concat([input,chunk]);if(input.length>=4&&input.length>=input.readUInt32LE(0)+4)process.stdout.write(input.subarray(0,input.readUInt32LE(0)+4));});', { mode: 0o700 });
      await writeFile(path.join(hosts, 'org.search.fixture.json'), JSON.stringify({ name: 'org.search.fixture', type: 'stdio', path: program, allowed_origins: [`chrome-extension://${extension.id}/`] }));
      browser.adapter.native.directories = [hosts];
      await browser.execute({ do: 'native-authorize', extension: extension.id, host: 'org.search.fixture', on: true });
      await browser.execute({ do: 'ext-press', id: extension.id });
      const popup = [...browser.adapter.extensionWindows][0];
      const nativeResult = await popup.webContents.executeJavaScript('window.fixtureDone');
      if (nativeResult?.result?.fixture !== 'echo') throw new Error(`Extension API/native messaging failed: ${JSON.stringify(nativeResult)}`);
      if (await browser.execute({ do: 'eval', id: tab.id, js: 'document.documentElement.dataset.injectedFixture' }) !== 'works') throw new Error('Extension injection failed');
      popup.destroy();
      const priorIdentity = extension.id;
      const reloaded = await browser.execute({ do: 'ext-reload', id: extension.id });
      if (reloaded.id !== priorIdentity) throw new Error('Extension reload changed identity');
      await browser.execute({ do: 'ext-remove', id: extension.id });
      if (!browser.adapter.capabilities.passwords) {
        try { await browser.execute({ do: 'password', action: 'list' }); throw new Error('Insecure vault was accepted'); }
        catch (error) { if (error.code !== 'FEATURE_UNAVAILABLE') throw error; }
      }
      console.log('Desktop smoke passed: agent transport, navigation, forms, downloads, private isolation, document-start styles, virtual WebAuthn, live-page picture-in-picture, extension content scripts, tab APIs, isolated scripting, native messaging, stable extension reload, and vault availability checks.');
      await new Promise(resolve => fixture.close(resolve));
      window.close();
    } catch (error) { console.error(error); fixture.close(); await browser.stop(); app.exit(1); }
  }
}
