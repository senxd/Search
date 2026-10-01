import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';

// Engine-neutral JSON requests, matching Search's bench "do" convention.
// Nothing evaluates inside the host process: eval only reaches a page sandbox.
async function ask(request) {
  const directory = process.env.SEARCH_PROFILE || path.resolve('.profile');
  const connection = JSON.parse(await readFile(path.join(directory, 'connection.json'), 'utf8'));
  const response = await fetch(`${connection.url}/api/command`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${connection.token}` },
    body: JSON.stringify(request), signal: AbortSignal.timeout(65000),
  });
  const value = await response.json();
  if (!response.ok) throw Object.assign(new Error(value.error), { code: value.code });
  return value.result;
}

async function run(line) {
  try { console.log(JSON.stringify({ result: await ask(JSON.parse(line)) })); }
  catch (error) { console.log(JSON.stringify({ error: error.message, code: error.code || 'AGENT_FAILED' })); process.exitCode = 1; }
}

if (process.argv[2]) await run(process.argv[2]);
else for await (const line of createInterface({ input: process.stdin })) if (line.trim()) await run(line);
