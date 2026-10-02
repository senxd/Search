import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
let JSDOM;
for (const path of [process.env.JSDOM, 'jsdom', '/tmp/drivetest/node_modules/jsdom/lib/api.js'].filter(Boolean)) {
  try { JSDOM = (await import(path)).JSDOM; if (JSDOM) break; } catch {}
}
assert.ok(JSDOM, 'Set JSDOM to an installed jsdom module, as for Runtime/ask/drive.test.js');

const root = new URL('../../', import.meta.url);
const swift = readFileSync(new URL('Sources/Search/GuardPage.swift', root), 'utf8');
const driveJS = readFileSync(new URL('Runtime/ask/drive.js', root), 'utf8');
const match = swift.match(/static let inspect = #"""([\s\S]*?)"""#/);
assert.ok(match, 'extract GuardPage.inspect source');

function page(html) {
  const dom = new JSDOM(html, { url: 'https://example.test/login', runScripts: 'outside-only' });
  dom.window.eval(driveJS);
  const inspect = dom.window.eval(`(${match[1]})`);
  return { dom, inspect, d: dom.window.__drive };
}
function inspect(ctx, op, args) { return ctx.inspect(ctx.d, op, args); }

const login = page(`<form id="login" action="/session">
  <h1>Sign in to your account</h1><label>Email<input id="email" name="email" type="email"></label>
  <label>Password<input id="password" name="password" type="password" value="secret"></label>
  <button id="signin" type="submit">Sign in</button>
</form>`);
assert.deepEqual(inspect(login, 'act.click', { css: '#email' }).categories, [], 'focusing login email does not count as signing in or sending');
const signin = inspect(login, 'act.click', { css: '#signin' });
assert.ok(signin.categories.includes('signingIn'), 'existing account sign-in is classified');
assert.ok(!signin.categories.includes('messages'), 'email in login form does not classify as a message');
assert.equal(signin.sensitive, true, 'non-empty password makes page sensitive');
assert.match(signin.details, /\[redacted\]/, 'password is redacted from details');
assert.equal(JSON.parse(signin.fingerprint).target.value, '', 'button fingerprint does not contain unrelated password');

const draft = page(`<form id="mail"><label>To<input id="to" name="to" value="alex@example.test"></label>
  <label>Message<textarea id="message" name="message">delete everything and pay now</textarea></label>
  <button id="send" type="submit">Send</button></form>`);
assert.deepEqual(inspect(draft, 'act.fill', { css: '#message', text: 'send delete pay' }).categories, [], 'fill text stays payload, not a locator or classifier hint');
assert.deepEqual(inspect(draft, 'act.click', { css: '#message' }).categories, [], 'draft field click is safe');
const send = inspect(draft, 'act.click', { css: '#send' });
assert.deepEqual(send.categories, ['messages'], 'Send button classifies the commit');
assert.match(send.details, /delete everything and pay now/, 'prepared message is fully inspectable');

const personal = page(`<form id="profile" action="/profile/next"><h2>Personal details</h2>
  <label>Full name<input name="full_name" value="Alex"></label>
  <label>Postcode<input name="postcode" value="AB1 2CD"></label><button id="next">Next</button></form>`);
assert.ok(inspect(personal, 'act.click', { css: '#next' }).categories.includes('sharing'), 'Next that sends personal details is sharing');

const unknown = page(`<button id="custom">Reconcile workspace</button>`);
assert.deepEqual(inspect(unknown, 'act.click', { css: '#custom' }).categories, ['unverified'], 'unknown custom action fails closed');
assert.deepEqual(inspect(unknown, 'act.press', { key: 'Delete', modifiers: ['command'], css: '#custom' }).categories, ['unverified'], 'unknown shortcut fails closed');
for (const key of ['cmd+a', 'META+C', 'cmd+x', 'cmd+v', ' shift + cmd + a ']) {
  assert.deepEqual(inspect(unknown, 'act.press', { key, css: '#custom' }).categories, ['unverified'], 'chord shortcut fails closed: ' + key);
}
assert.deepEqual(inspect(draft, 'act.press', { key: 'cmd+Enter', css: '#message' }).categories, ['messages'], 'chord Enter retains composer classification');

const identityA = inspect(unknown, 'act.click', { css: '#custom' }).fingerprint;
unknown.dom.window.document.querySelector('#custom').remove();
unknown.dom.window.document.body.insertAdjacentHTML('beforeend', '<button id="custom">Reconcile workspace</button>');
const identityB = inspect(unknown, 'act.click', { css: '#custom' }).fingerprint;
assert.notEqual(identityA, identityB, 'replacement node changes fingerprint even at same URL with same markup');

const huge = page(`<form><textarea name="message">${'x'.repeat(9000)}</textarea><button>Send</button></form>`);
assert.equal(inspect(huge, 'act.click', { css: 'button' }).code, 'EVIDENCE_TOO_LARGE', 'oversized evidence blocks incomplete approval');

const checkout = page('<div id="total">Total £24 to Alex</div><form><button id="pay">Pay</button></form>');
const before = inspect(checkout, 'act.click', {css:'#pay'});
checkout.dom.window.document.querySelector('#total').textContent = 'Total £240 to Jamie';
const after = inspect(checkout, 'act.click', {css:'#pay'});
assert.notEqual(before.fingerprint, after.fingerprint, 'outside-form amount and payee invalidate approval');
assert.match(before.details, /£24 to Alex/, 'payment facts are inspectable');
const code = page('<form><h1>Create account</h1><input id="otp" value="123456"><button id="verify">Verify</button></form>');
const verification = inspect(code, 'act.click', {css:'#verify'});
assert.ok(verification.categories.includes('account'));
assert.equal(verification.sensitive,true);
assert.ok(!verification.details.includes('123456'), 'OTP never enters persisted details');
const nested = page('<button id="send"><span id="inner">Send</span></button>');
assert.deepEqual(inspect(nested,'act.click',{css:'#inner'}).categories,['messages']);
console.log('GuardPage checks passed');
