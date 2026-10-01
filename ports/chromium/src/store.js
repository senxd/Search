import { mkdir, readFile, rename, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export class Store {
  constructor(directory) { this.directory = directory; }
  async read() {
    try {
      const data = JSON.parse(await readFile(path.join(this.directory, 'browser.json'), 'utf8'));
      if (data.version !== 1) throw new Error('Unsupported saved browser state');
      return data;
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw error; // A damaged profile must not be silently replaced.
    }
  }
  async write(data) {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const temporary = path.join(this.directory, `.browser-${randomUUID()}.tmp`);
    try {
      await writeFile(temporary, JSON.stringify(data, null, 2), { mode: 0o600, flag: 'wx' });
      await rename(temporary, path.join(this.directory, 'browser.json'));
    } finally {
      await rm(temporary, { force: true });
    }
  }
}
