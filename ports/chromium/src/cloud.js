import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { mkdir, writeFile, rm, chmod } from 'node:fs/promises';
import { Browser } from './browser.js';
import { Store } from './store.js';
import { EngineRegistry } from './contract.js';
import { ChromiumAdapter, PlaywrightAdapter } from './adapters/chromium.js';
import { startServer } from './server.js';

export async function startCloud({ directory = process.env.SEARCH_PROFILE || path.resolve('.profile'), port = Number(process.env.SEARCH_PORT || 4317), executablePath = process.env.SEARCH_CHROMIUM_PATH || '/usr/bin/chromium' } = {}) {
  const registry = new EngineRegistry();
  registry.register('chromium', () => new ChromiumAdapter({ id: 'chromium', directory, executablePath }));
  // Additional engines are installed/configured at host startup, never loaded
  // from arbitrary paths or JavaScript supplied by a web page or agent request.
  const extra = JSON.parse(process.env.SEARCH_RENDERERS || '{}');
  for (const [id, configuration] of Object.entries(extra)) {
    const options = typeof configuration === 'string' ? { kind: 'chromium', executablePath: configuration } : configuration;
    registry.register(id, () => new PlaywrightAdapter({ ...options, id, directory: path.join(directory, 'renderers', id) }));
  }
  const browser = new Browser({ registry, engine: 'chromium', store: new Store(directory), liveRouting: true });
  try { await browser.start(); } catch (error) { await browser.adapter?.stop({ persist: false }).catch(() => {}); throw error; }
  let server;
  try { server = await startServer(browser, { port }); }
  catch (error) { await browser.stop(); throw error; }
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const connectionFile = path.join(directory, 'connection.json');
  await writeFile(connectionFile, JSON.stringify({ url: server.url, token: server.token }), { mode: 0o600 });
  await chmod(connectionFile, 0o600);
  return {
    browser, server,
    async stop() {
      await server.stop();
      await browser.stop();
      await rm(connectionFile, { force: true });
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const instance = await startCloud();
    console.log(`Search Chromium cloud host listening on ${instance.server.url}`);
    console.log('Use npm run agent -- \'{"do":"probe"}\' or read .profile/connection.json for the local UI token.');
    let closing = false;
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
      if (closing) return;
      closing = true;
      await instance.stop();
      process.exit(0);
    });
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
