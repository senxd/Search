import { createHash, createPublicKey, verify } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { BrowserError } from '../contract.js';

export function extensionID(text) {
  const id = String(text).toLowerCase().match(/(?<![a-z])[a-p]{32}(?![a-z])/)?.[0];
  if (!id) throw new BrowserError('INVALID_EXTENSION', 'Expected a Chrome Web Store link or extension ID');
  return id;
}
const letters = bytes => [...bytes].map(byte => String.fromCharCode(97 + (byte >> 4), 97 + (byte & 15))).join('');

function fields(buffer) {
  let offset = 0; const output = [];
  const integer = () => {
    let value = 0; let shift = 0;
    while (offset < buffer.length && shift < 49) {
      const byte = buffer[offset++]; value += (byte & 127) * 2 ** shift;
      if (!(byte & 128)) return value; shift += 7;
    }
    throw new BrowserError('INVALID_CRX', 'Invalid protobuf integer');
  };
  while (offset < buffer.length) {
    const tag = integer(); const type = tag & 7; const field = Math.floor(tag / 8);
    if (type === 2) {
      const length = integer();
      if (length > buffer.length - offset) throw new BrowserError('INVALID_CRX', 'Truncated protobuf field');
      output.push([field, buffer.subarray(offset, offset + length)]); offset += length;
    } else if (type === 0) integer();
    else if (type === 1) offset += 8;
    else if (type === 5) offset += 4;
    else throw new BrowserError('INVALID_CRX', 'Unsupported protobuf field');
    if (offset > buffer.length) throw new BrowserError('INVALID_CRX', 'Truncated protobuf');
  }
  return output;
}

export function verifiedCRX(data, requestedID) {
  const id = extensionID(requestedID);
  if (data.length < 12 || data.toString('ascii', 0, 4) !== 'Cr24' || data.readUInt32LE(4) !== 3) throw new BrowserError('INVALID_CRX', 'Expected a CRX3 archive');
  const length = data.readUInt32LE(8);
  if (length > 1024 * 1024 || 12 + length >= data.length) throw new BrowserError('INVALID_CRX', 'Invalid CRX header size');
  const header = fields(data.subarray(12, 12 + length));
  const signed = header.find(([number]) => number === 10000)?.[1];
  if (!signed || letters(fields(signed).find(([number]) => number === 1)?.[1] || []) !== id) throw new BrowserError('BAD_SIGNATURE', 'Extension identity does not match');
  const size = Buffer.alloc(4); size.writeUInt32LE(signed.length);
  const archive = data.subarray(12 + length);
  const message = Buffer.concat([Buffer.from('CRX3 SignedData\0'), size, signed, archive]);
  for (const [number, proof] of header.filter(([number]) => number === 2 || number === 3)) {
    const values = fields(proof); const key = values.find(([n]) => n === 1)?.[1]; const signature = values.find(([n]) => n === 2)?.[1];
    if (!key || !signature || letters(createHash('sha256').update(key).digest().subarray(0, 16)) !== id) continue;
    try {
      const publicKey = createPublicKey({ key, type: 'spki', format: 'der' });
      if ((number === 2 && publicKey.asymmetricKeyType !== 'rsa') || (number === 3 && publicKey.asymmetricKeyType !== 'ec')) continue;
      if (verify('sha256', message, publicKey, signature)) return { archive, publicKey: key.toString('base64'), id };
    } catch { /* A malformed proof does not authenticate the archive. */ }
  }
  throw new BrowserError('BAD_SIGNATURE', 'Extension signature does not verify');
}

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let value = n; for (let bit = 0; bit < 8; bit++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crc32(bytes) { let crc = 0xffffffff; for (const byte of bytes) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8); return (crc ^ 0xffffffff) >>> 0; }

export function zipEntries(zip) {
  let end = -1;
  for (let offset = zip.length - 22; offset >= Math.max(0, zip.length - 65557); offset--) if (zip.readUInt32LE(offset) === 0x06054b50) { end = offset; break; }
  if (end < 0 || zip.readUInt16LE(end + 4) || zip.readUInt16LE(end + 6)) throw new BrowserError('INVALID_ZIP', 'Unsupported ZIP archive');
  const count = zip.readUInt16LE(end + 10); let offset = zip.readUInt32LE(end + 16);
  if (count > 10000 || offset > end) throw new BrowserError('INVALID_ZIP', 'Invalid ZIP directory');
  const output = []; let total = 0; const names = new Set();
  for (let n = 0; n < count; n++) {
    if (offset + 46 > zip.length || zip.readUInt32LE(offset) !== 0x02014b50) throw new BrowserError('INVALID_ZIP', 'Invalid central-directory entry');
    const flags = zip.readUInt16LE(offset + 8); const method = zip.readUInt16LE(offset + 10);
    const crc = zip.readUInt32LE(offset + 16); const compressed = zip.readUInt32LE(offset + 20); const size = zip.readUInt32LE(offset + 24);
    const nameSize = zip.readUInt16LE(offset + 28); const extra = zip.readUInt16LE(offset + 30); const comment = zip.readUInt16LE(offset + 32);
    const mode = zip.readUInt32LE(offset + 38) >>> 16; const local = zip.readUInt32LE(offset + 42);
    const name = zip.toString('utf8', offset + 46, offset + 46 + nameSize);
    offset += 46 + nameSize + extra + comment;
    if (flags & 1 || ![0, 8].includes(method) || (mode & 0xf000) === 0xa000 || /[\\\0:]/.test(name) || name.startsWith('/') || name.split('/').some(part => part === '..') || names.has(name)) throw new BrowserError('UNSAFE_ZIP', 'Unsafe or unsupported archive entry');
    names.add(name); total += size;
    if (total > 128 * 1024 * 1024 || size > 32 * 1024 * 1024 || local + 30 > zip.length || zip.readUInt32LE(local) !== 0x04034b50) throw new BrowserError('INVALID_ZIP', 'Archive exceeds limits or is malformed');
    const start = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
    if (start + compressed > zip.length) throw new BrowserError('INVALID_ZIP', 'Truncated file');
    const bytes = method === 0 ? zip.subarray(start, start + compressed) : inflateRawSync(zip.subarray(start, start + compressed), { maxOutputLength: Math.max(1, size) });
    if (bytes.length !== size || crc32(bytes) !== crc) throw new BrowserError('INVALID_ZIP', 'ZIP checksum mismatch');
    output.push({ name, bytes, directory: name.endsWith('/') });
  }
  return output;
}

export async function extractZIP(zip, directory) {
  const entries = zipEntries(zip); // Validate every path before writing any file.
  await mkdir(directory, { recursive: true, mode: 0o700 });
  for (const entry of entries) {
    const destination = path.join(directory, entry.name);
    if (entry.directory) await mkdir(destination, { recursive: true, mode: 0o700 });
    else { await mkdir(path.dirname(destination), { recursive: true, mode: 0o700 }); await writeFile(destination, entry.bytes, { mode: 0o600, flag: 'wx' }); }
  }
}
