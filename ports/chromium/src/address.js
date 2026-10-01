import { BrowserError } from './contract.js';

export const SEARCH_ENGINES = Object.freeze({
  google: 'https://www.google.com/search?q=%s',
  duckduckgo: 'https://duckduckgo.com/?q=%s',
  bing: 'https://www.bing.com/search?q=%s',
  ecosia: 'https://www.ecosia.org/search?q=%s',
  startpage: 'https://www.startpage.com/sp/search?query=%s',
  kagi: 'https://kagi.com/search?q=%s',
});

export function validateURL(value) {
  if (typeof value !== 'string' || value.length > 16384) {
    throw new BrowserError('INVALID_URL', 'An address must be a string under 16 KB');
  }
  const url = new URL(value);
  if (!['http:', 'https:', 'about:'].includes(url.protocol) ||
      (url.protocol === 'about:' && url.href !== 'about:blank') || url.username || url.password) {
    throw new BrowserError('INVALID_URL', 'Only HTTP, HTTPS, and about:blank are allowed');
  }
  return url.href;
}

export function searchTemplate(value) {
  if (typeof value !== 'string' || !value.includes('%s')) {
    throw new BrowserError('INVALID_SEARCH', 'Search template must include %s');
  }
  const a = new URL(validateURL(value.replaceAll('%s', 'a')));
  const b = new URL(validateURL(value.replaceAll('%s', 'b')));
  if (a.host !== b.host || !['http:', 'https:'].includes(a.protocol)) {
    throw new BrowserError('INVALID_SEARCH', 'Search words must not change the host');
  }
  return value;
}

export function address(text, template = SEARCH_ENGINES.google) {
  const value = String(text).trim();
  if (!value) return 'about:blank';
  if (/^[a-z][a-z\d+.-]*:/i.test(value) && !/^localhost:\d+/i.test(value)) {
    return validateURL(value);
  }
  if (!/\s/.test(value) && /^(localhost(?::\d+)?|(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?)(?:\/|$)/i.test(value)) {
    return validateURL(`http://${value}`);
  }
  if (!/\s/.test(value) && /^[\w.-]+\.[a-z]{2,}(?::\d+)?(?:[/?#]|$)/i.test(value)) {
    return validateURL(`https://${value}`);
  }
  return validateURL(searchTemplate(template).replaceAll('%s', encodeURIComponent(value)));
}
