// Install in the isolated preload world. Credentials are held briefly in
// memory and sent only to the owning browser process, never to shell state.
export function watchLogin(send) {
  let pending = false; let timer;
  const pair = () => {
    const password = [...document.querySelectorAll('input[type="password"]')].find(field => field.getBoundingClientRect().width > 0);
    if (!password) return null;
    const scope = password.form || document;
    const username = scope.querySelector('input[autocomplete="username"],input[type="email"],input[name*="user" i],input[name*="login" i],input[type="text"]');
    return { password, username };
  };
  const capture = event => {
    if (!event.isTrusted) return;
    const fields = pair();
    if (!fields?.password.value) return;
    pending = true;
    send({ kind: 'submitted', username: fields.username?.value || '', password: fields.password.value });
  };
  document.addEventListener('submit', capture, true);
  document.addEventListener('keydown', event => { if (event.key === 'Enter' && event.target.matches('input')) capture(event); }, true);
  document.addEventListener('click', event => { if (event.target.closest('button,[role="button"],input[type="submit"]')) capture(event); }, true);
  const observer = new MutationObserver(() => {
    clearTimeout(timer);
    timer = setTimeout(() => { if (pending && !pair()) { pending = false; send({ kind: 'settled' }); } }, 700);
  });
  observer.observe(document, { childList: true, subtree: true, attributes: true });
}

export class LoginOffers {
  constructor({ vault, prompt }) { this.vault = vault; this.prompt = prompt; this.pending = new Map(); this.prompting = new Set(); }
  submitted(tab, origin, account) {
    if (!tab || tab.private || !this.vault.available() || !/^https?:\/\//.test(origin) || typeof account.password !== 'string' || account.password.length > 16384 || typeof account.username !== 'string' || account.username.length > 4096) return;
    this.forget(tab.id);
    const pending = { origin, username: account.username, password: account.password, at: Date.now() };
    pending.timer = setTimeout(() => this.forget(tab.id), 120000); pending.timer.unref?.();
    this.pending.set(tab.id, pending);
  }
  async settled(tab, hasPassword) {
    const account = this.pending.get(tab.id);
    if (!account || hasPassword || this.prompting.has(tab.id)) return;
    this.forget(tab.id);
    if (tab.private || Date.now() - account.at > 120000 || !this.vault.available()) return;
    const accounts = await this.vault.list(account.origin);
    const previous = accounts.find(item => item.username === account.username);
    if (previous && (await this.vault.get(previous.id, account.origin)).password === account.password) return;
    this.prompting.add(tab.id);
    try { if (await this.prompt({ origin: account.origin, username: account.username, updating: Boolean(previous) })) await this.vault.save(account); }
    finally { this.prompting.delete(tab.id); }
  }
  forget(id) { clearTimeout(this.pending.get(id)?.timer); this.pending.delete(id); }
  stop() { for (const id of this.pending.keys()) this.forget(id); }
}
