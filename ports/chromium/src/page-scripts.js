// DOM behavior is shared by every engine, rather than reimplemented in each
// host. Arguments are passed as values, never interpolated into page scripts.
export function hiddenStyle({ selectors }) {
  let style = document.getElementById('search-hidden-elements');
  if (!style) {
    style = document.createElement('style');
    style.id = 'search-hidden-elements';
    (document.head || document.documentElement).append(style);
  }
  style.textContent = selectors.map(selector => `${selector}{display:none!important}`).join('\n');
}

export function reader() {
  let best = null;
  let score = 0;
  for (const node of document.querySelectorAll('article,main,[role="main"],section,div')) {
    const paragraphs = [...node.querySelectorAll('p')];
    const length = paragraphs.reduce((n, p) => n + p.innerText.length, 0);
    if (paragraphs.length < 2 || length < 400) continue;
    const mark = length / (1 + 14 * node.querySelectorAll('a').length);
    if (mark > score) { best = node; score = mark; }
  }
  if (!best) return false;
  const content = best.cloneNode(true);
  const originals = [...best.querySelectorAll('img')];
  [...content.querySelectorAll('img')].forEach((image, index) => {
    const original = originals[index];
    let source = original.currentSrc || original.getAttribute('src') || '';
    if (!source || source.startsWith('data:image') || original.naturalWidth <= 2) {
      for (const name of ['data-src', 'data-original', 'data-lazy-src', 'data-lazy', 'data-full-src', 'data-hi-res-src', 'data-image', 'data-echo']) {
        if (original.getAttribute(name)) { source = original.getAttribute(name); break; }
      }
    }
    if (source && !source.startsWith('data:image')) { image.src = new URL(source, location.href).href; image.loading = 'eager'; }
    else image.remove();
    image.removeAttribute('srcset');
  });
  for (const frame of content.querySelectorAll('iframe')) {
    const source = frame.getAttribute('src') || frame.getAttribute('data-src') || '';
    try {
      const host = new URL(source, location.href).hostname;
      if (!['youtube.com', 'youtube-nocookie.com', 'youtu.be', 'vimeo.com', 'dailymotion.com', 'loom.com', 'streamable.com', 'wistia.com', 'ted.com'].some(domain => host === domain || host.endsWith(`.${domain}`))) frame.remove();
      else { frame.src = new URL(source, location.href).href; frame.removeAttribute('width'); frame.removeAttribute('height'); }
    } catch { frame.remove(); }
  }
  for (const element of content.querySelectorAll('script,style,noscript,form,nav,aside,footer,button,input,select,textarea,[role="navigation"],[role="complementary"],[aria-hidden="true"]')) element.remove();
  const title = document.createElement('h1');
  title.textContent = document.querySelector('h1')?.textContent || document.title;
  const wrapper = document.createElement('main');
  wrapper.id = 'search-reader';
  wrapper.append(title, content);
  const style = document.createElement('style');
  style.textContent = 'body{margin:0;background:#fafafa;color:#222}#search-reader{max-width:680px;margin:60px auto;padding:0 28px;font:19px/1.7 Georgia,serif}#search-reader img{max-width:100%}#search-reader h1{font:600 36px/1.2 system-ui}';
  document.body.replaceChildren(wrapper);
  document.head.append(style);
  window.scrollTo(0, 0);
  return true;
}

export function pageAction({ action, selector, text }) {
  const element = document.querySelector(selector);
  if (!element) throw new Error(`No element matches ${selector}`);
  if (action === 'click') element.click();
  else if (action === 'type') {
    if (element.isContentEditable) element.textContent = text;
    else {
      const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
      if (!setter) throw new Error('Element cannot accept text');
      setter.call(element, text);
    }
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
  } else if (action === 'submit') {
    const form = element instanceof HTMLFormElement ? element : element.closest('form');
    if (!form) throw new Error('Element is not in a form');
    form.requestSubmit();
  }
  return { ok: true };
}

export function transferSnapshot() {
  return {
    localStorage: Object.fromEntries(Object.entries(localStorage)),
    sessionStorage: Object.fromEntries(Object.entries(sessionStorage)),
    scroll: { x: scrollX, y: scrollY },
  };
}

export const BLOCKED_HOSTS = new Set([
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
  'googletagservices.com', 'google-analytics.com', 'googletagmanager.com',
  'adservice.google.com', 'amazon-adsystem.com', 'adnxs.com', 'adsrvr.org',
  'criteo.com', 'criteo.net', 'taboola.com', 'outbrain.com', 'rubiconproject.com',
  'pubmatic.com', 'openx.net', 'casalemedia.com', 'smartadserver.com',
  'sharethrough.com', 'indexww.com', 'bidswitch.net', '33across.com', 'teads.tv',
  'moatads.com', 'adroll.com', 'scorecardresearch.com', 'quantserve.com',
  'chartbeat.com', 'hotjar.com', 'mouseflow.com', 'fullstory.com', 'clarity.ms',
  'mixpanel.com', 'amplitude.com', 'segment.com', 'segment.io', 'branch.io',
  'appsflyer.com', 'adjust.com', 'analytics.tiktok.com', 'connect.facebook.net',
  'ads-twitter.com', 'analytics.twitter.com',
]);

export function shouldBlock(url, firstParty, enabled = true) {
  if (!enabled) return false;
  try {
    const host = new URL(url).hostname;
    const first = new URL(firstParty).hostname;
    if (host === first) return false;
    return [...BLOCKED_HOSTS].some(domain => host === domain || host.endsWith(`.${domain}`));
  } catch { return false; }
}
