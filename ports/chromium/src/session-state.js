// A portable page checkpoint. Secrets and file handles are deliberately never
// serialized. A page holding them stays awake instead of silently losing them.
export function capturePage() {
  const fields = [];
  let sensitive = false;
  const selector = element => {
    if (element.id) return `#${CSS.escape(element.id)}`;
    const parts = [];
    for (let item = element; item && item !== document.documentElement; item = item.parentElement) {
      const siblings = [...item.parentElement.children].filter(sibling => sibling.tagName === item.tagName);
      parts.unshift(`${item.tagName.toLowerCase()}:nth-of-type(${siblings.indexOf(item) + 1})`);
    }
    return `html>${parts.join('>')}`;
  };
  for (const element of document.querySelectorAll('input,textarea,select,[contenteditable="true"]')) {
    const secret = element.type === 'password' || element.type === 'file' ||
      /password|secret|token|card|cvv|cvc|otp|pin|ssn/i.test(`${element.name} ${element.id} ${element.autocomplete}`);
    if (secret) { if (element.value || element.files?.length) sensitive = true; continue; }
    if (element.type === 'hidden') continue;
    fields.push({ selector: selector(element), value: element.isContentEditable ? element.textContent : element.value,
      checked: element.checked, selected: element.tagName === 'SELECT' ? [...element.options].map(option => option.selected) : undefined });
  }
  const playing = [...document.querySelectorAll('video,audio')].some(element => !element.paused && !element.ended);
  let entries = {};
  try { entries = Object.fromEntries(Object.entries(sessionStorage)); } catch { /* Opaque blank origin. */ }
  return { url: location.href, scroll: { x: scrollX, y: scrollY }, fields,
    sessionStorage: entries, busy: sensitive || playing,
    reason: sensitive ? 'Page holds a password, sensitive form value, or file selection' : playing ? 'Media is playing' : null };
}

export function restorePage(checkpoint) {
  if (!checkpoint || checkpoint.url !== location.href) return false;
  for (const field of checkpoint.fields || []) {
    const element = document.querySelector(field.selector);
    if (!element || element.type === 'password' || element.type === 'file' || element.type === 'hidden') continue;
    if (element.isContentEditable) element.textContent = field.value;
    else if ('value' in element) element.value = field.value;
    if (field.checked !== undefined) element.checked = field.checked;
    if (field.selected && element.options) [...element.options].forEach((option, index) => { option.selected = Boolean(field.selected[index]); });
  }
  for (const [key, value] of Object.entries(checkpoint.sessionStorage || {})) sessionStorage.setItem(key, value);
  requestAnimationFrame(() => scrollTo(checkpoint.scroll?.x || 0, checkpoint.scroll?.y || 0));
  return true;
}
