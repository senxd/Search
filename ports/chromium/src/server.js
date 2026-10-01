import http from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const ASSETS = new Map([
  ['/', ['../ui/index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['../ui/app.js', 'text/javascript; charset=utf-8']],
  ['/style.css', ['../ui/style.css', 'text/css; charset=utf-8']],
]);

export async function startServer(browser, { port = 0 } = {}) {
  const token = randomBytes(32).toString('hex');
  let origin;
  const server = http.createServer(async (request, response) => {
    const send = (status, value) => {
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      response.end(JSON.stringify(value));
    };
    try {
      // Reject DNS rebinding and cross-origin requests even if loopback is
      // reachable. No wildcard CORS, query-string token, or unauthenticated API.
      if (request.headers.host !== new URL(origin).host) return send(403, { error: 'Invalid host' });
      if (request.headers.origin && request.headers.origin !== origin) return send(403, { error: 'Invalid origin' });
      const url = new URL(request.url, origin);
      if (request.method === 'GET' && ASSETS.has(url.pathname)) {
        const [file, contentType] = ASSETS.get(url.pathname);
        const body = await readFile(new URL(file, import.meta.url));
        response.writeHead(200, {
          'Content-Type': contentType, 'Cache-Control': 'no-store',
          'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'",
          'X-Content-Type-Options': 'nosniff',
        });
        return response.end(body);
      }
      const supplied = Buffer.from(request.headers.authorization?.replace(/^Bearer /, '') || '');
      const expected = Buffer.from(token);
      if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return send(401, { error: 'Authentication required' });
      if (url.pathname === '/api/state' && request.method === 'GET') return send(200, browser.snapshot());
      if (url.pathname === '/api/screenshot' && request.method === 'GET') {
        const tab = browser.tab(url.searchParams.get('id') || browser.active);
        const result = await browser.execute({ do: 'shot', id: tab.id });
        response.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
        return response.end(Buffer.from(result.base64, 'base64'));
      }
      if (url.pathname === '/api/command' && request.method === 'POST') {
        if (!request.headers['content-type']?.startsWith('application/json')) return send(415, { error: 'JSON required' });
        let body = '';
        for await (const chunk of request) {
          body += chunk.toString('utf8');
          if (Buffer.byteLength(body) > 8 * 1024 * 1024) return send(413, { error: 'Request too large' });
        }
        return send(200, { result: await browser.execute(JSON.parse(body)) });
      }
      send(404, { error: 'Not found' });
    } catch (error) {
      if (!response.headersSent) send(400, { error: error.message, code: error.code || 'COMMAND_FAILED', details: error.details || {} });
      else response.destroy();
    }
  });
  server.requestTimeout = 65000;
  server.headersTimeout = 10000;
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  origin = `http://127.0.0.1:${server.address().port}`;
  return { url: origin, token, stop: () => new Promise(resolve => { server.close(resolve); server.closeIdleConnections(); }) };
}
