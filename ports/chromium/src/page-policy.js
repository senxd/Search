export const COSMETIC_SELECTORS = [
  '.adsbygoogle', 'ins.adsbygoogle', '[id^="google_ads_"]',
  '[id^="div-gpt-ad"]', '[id^="taboola-"]', '#taboola-below-article',
  'iframe[src*="doubleclick.net"]', 'iframe[src*="googlesyndication"]',
  'iframe[src*="amazon-adsystem"]',
];

// Runs at document start in any renderer. Revision checks make repeated
// Playwright init scripts deterministic when preferences change.
export function policyBootstrap(policy) {
  if (!policy || (window.__searchPolicyRevision || 0) > policy.revision) return;
  window.__searchPolicyRevision = policy.revision;
  const apply = () => {
    if (window.__searchPolicyRevision !== policy.revision) return true;
    if (!document.documentElement) return false;
    const host = location.hostname;
    const selectors = [...(policy.hidden?.[host] || []), ...(policy.shield && !policy.pausedHosts?.includes(host) ? policy.cosmetic : [])];
    let style = document.getElementById('search-hidden-elements');
    if (!style) { style = document.createElement('style'); style.id = 'search-hidden-elements'; document.documentElement.append(style); }
    style.textContent = selectors.map(selector => `${selector}{display:none!important}`).join('\n');
    return true;
  };
  if (!apply()) {
    const observer = new MutationObserver(() => { if (apply()) observer.disconnect(); });
    observer.observe(document, { childList: true, subtree: true });
  }
}

export function elementPicker() {
  if (window.__searchPicker?.live) { window.__searchPicker.stop(); return { picking: false }; }
  const box = document.createElement('div');
  box.id = 'search-element-picker';
  box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #607954;background:#60795422;display:none';
  document.documentElement.append(box);
  let target;
  const selector = element => {
    if (element.id) return `#${CSS.escape(element.id)}`;
    const parts = [];
    for (let current = element; current && current !== document.documentElement; current = current.parentElement) {
      if (current.id) { parts.unshift(`#${CSS.escape(current.id)}`); break; }
      const children = [...current.parentElement.children].filter(child => child.tagName === current.tagName);
      parts.unshift(`${current.tagName.toLowerCase()}:nth-of-type(${children.indexOf(current) + 1})`);
    }
    return parts.join('>');
  };
  const move = event => {
    target = event.target;
    if (!(target instanceof Element) || target === document.body || target === document.documentElement) return;
    const rect = target.getBoundingClientRect();
    Object.assign(box.style, { display: 'block', left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px` });
  };
  const stop = () => {
    document.removeEventListener('pointermove', move, true);
    document.removeEventListener('click', choose, true);
    document.removeEventListener('keydown', key, true);
    box.remove(); window.__searchPicker.live = false;
  };
  const choose = event => {
    event.preventDefault(); event.stopImmediatePropagation();
    target = event.target;
    if (target instanceof Element && target !== document.body && target !== document.documentElement) {
      window.__searchPicker.selection = { selector: selector(target), label: (target.getAttribute('aria-label') || target.innerText || target.tagName).slice(0, 100) };
    }
    stop();
  };
  const key = event => { if (event.key === 'Escape') { event.preventDefault(); stop(); } };
  window.__searchPicker = { live: true, stop, selection: null };
  document.addEventListener('pointermove', move, true);
  document.addEventListener('click', choose, true);
  document.addEventListener('keydown', key, true);
  return { picking: true };
}

export function policyFor(callbacks, revision) {
  return { revision, hidden: callbacks.hiddenRules?.() || {}, shield: callbacks.shield('about:blank'),
    pausedHosts: callbacks.pausedHosts?.() || [], cosmetic: COSMETIC_SELECTORS };
}
