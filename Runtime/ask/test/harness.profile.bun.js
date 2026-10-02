import assert from 'node:assert/strict';

globalThis.window = globalThis;
const events = [], dispatched = [], requests = [];
let response = [], nativeReply = () => ({ ok: true }), permissionsReply, permissionRequests = 0;
window.__native = { post(m) {
  if (m.kind === 'permissions') {
    permissionRequests++;
    setTimeout(() => {
      const reply = permissionsReply(m);
      if (reply !== undefined) window.__h._tool(m.id, reply);
    }, 0);
  }
  if (m.kind === 'event') events.push(m);
  if (m.kind === 'tool') {
    dispatched.push(m);
    setTimeout(() => window.__h._tool(m.id, nativeReply(m)), 0);
  }
  if (m.kind === 'fetch') {
    requests.push(JSON.parse(m.body));
    setTimeout(() => {
      window.__h._fetchMeta(m.id, 200, '{}');
      for (const ev of typeof response === 'function' ? response(requests.length - 1) : response) window.__h._fetchLine(m.id, typeof ev === 'string' ? ev : 'data: ' + JSON.stringify(ev));
      window.__h._fetchEnd(m.id, 200, null, null);
    }, 0);
  }
} };
await import('../harness.js');

const completed = { type: 'response.completed', response: { model: 'gpt-6-luna', usage: { input_tokens: 40, output_tokens: 5 } } };
const call = (name, args = {}) => ({ type: 'response.output_item.done', item: {
  type: 'function_call', call_id: name, name, arguments: JSON.stringify(args)
} });
async function run(stream, opts = {}, history = [{ role: 'you', text: 'Task' }]) {
  response = stream;
  nativeReply = opts.nativeReply || (() => ({ ok: true }));
  permissionsReply = opts.permissionsReply || (() => ({ mode: 'full', confirmationCriteria: [] }));
  events.length = dispatched.length = requests.length = 0;
  permissionRequests = 0;
  const id = crypto.randomUUID();
  window.__h.run({ profile: 'browser', maxRounds: 1, ...opts,
    chat: { id, model: 'codex/gpt-6-luna', effort: 'xhigh', messages: history }, tabs: [] });
  for (let i = 0; i < 300; i++) {
    const done = events.find(e => e.name === 'done' && e.data.chat === id);
    if (done) return done.data;
    await new Promise(r => setTimeout(r, 10));
  }
  throw new Error('harness did not finish');
}

let result = await run([call('eval', { tab: 't1', js: 'hiddenReward()' }), call('done'), completed]);
assert.equal(result.error, null);
assert.equal(dispatched.length, 0, 'a forbidden emitted call must not dispatch');
const wire = requests[0];
assert.equal(wire.model, 'gpt-6-luna');
assert.equal(wire.reasoning.effort, 'xhigh');
for (const name of ['eval', 'run_code', 'ask_user', 'inspector_send', 'inspector_attach']) {
  assert.ok(!wire.tools.some(t => t.name === name), name + ' excluded from schemas');
}
assert.ok(wire.tools.some(t => t.name === 'snapshot'));
assert.equal(wire.tools.find(t => t.name === 'snapshot').parameters.properties.textColors.type, 'boolean');
assert.match(wire.instructions, /WebKit images can flatten CSS 3D/);
assert.match(wire.instructions, /snapshot with textColors:true/);
assert.match(wire.instructions, /let motion settle and verify/);
assert.match(wire.instructions, /holdMs:350/);
assert.deepEqual(wire.tools.find(t => t.name === 'drag').parameters.properties.holdMs,
  { type: 'integer', minimum: 0, maximum: 2000, description: 'Hold the mouse down at the destination before release, in milliseconds. Defaults to 0. For momentum controls, try 350 and verify the settled feedback.' });
assert.match(wire.instructions, /change the drag direction, axis, distance/);
const hoverSchema = wire.tools.find(t => t.name === 'hover').parameters.properties;
assert.ok(hoverSchema.x && hoverSchema.y && hoverSchema.withSnapshot, 'hover must allow coordinate sampling and immediate feedback');
assert.match(wire.instructions, /Permission mode: Full/);
assert.match(wire.instructions, /submission or equivalent finish control/);
assert.doesNotMatch(wire.instructions, /isolated UI benchmark/);
assert.doesNotMatch(wire.instructions, /Never submit a draft|ask_user|run_code/);
assert.match(wire.instructions, /small controlled adjustments/);
assert.match(wire.instructions, /hover with x,y and withSnapshot:true/);
assert.match(wire.instructions, /Batch independent hover samples/);
for (const name of ['tab_select', 'highlight', 'clear_highlight']) {
  assert.ok(wire.tools.some(t => t.name === name), name + ' available to browser agents');
}
assert.equal(events.find(e => e.name === 'metrics').data.usage.input_tokens, 40);
await run([call('tab_select', { tab: 't1' }), call('highlight', { tab: 't1', ref: 'e1' }), call('clear_highlight', { tab: 't1' }), completed]);
assert.deepEqual(dispatched.map(t => t.name), ['tabs.select', 'page.highlight', 'page.clearHighlight']);

result = await run([{ type: 'response.output_text.delta', delta: 'partial' }]);
assert.match(result.error, /before response.completed/);
result = await run([call('click', { tab: 't1', ref: 'e1' })]);
assert.match(result.error, /before response.completed/);
assert.equal(dispatched.length, 0, 'partial provider output cannot cause a mutation');
result = await run([{ type: 'response.incomplete', response: { incomplete_details: { reason: 'max_output_tokens' } } }]);
assert.match(result.error, /incomplete.*max_output_tokens/);
result = await run([{ type: 'response.failed', response: { error: { message: 'test provider failure' } } }]);
assert.match(result.error, /test provider failure/);
result = await run(['data: {broken', completed]);
assert.match(result.error, /malformed JSON/);
result = await run([{ type: 'response.completed', response: { status: 'incomplete' } }]);
assert.match(result.error, /non-completed response/);
result = await run([{ type: 'response.completed', response: { status: 'completed', output: [call('done').item] } }]);
assert.equal(result.error, null, 'final output captures calls even without item.done events');
result = await run([{ type: 'response.output_text.delta', delta: 'finished' }, completed]);
assert.equal(result.error, null, 'natural completion on the final round is successful');
result = await run([call('click', { tab: 't1', ref: 'e1' }), completed]);
assert.match(result.error, /1-step limit/);
assert.equal(dispatched.length, 1);
const captchaSkill = await Bun.file(new URL('../skills/captcha-solver/SKILL.md', import.meta.url)).text();
result = await run([call('captcha_click', { tab: 't1', x: 60, y: 175 }), call('done'), completed], { captchaSkill });
assert.equal(result.error, null);
assert.ok(requests[0].instructions.endsWith(captchaSkill), 'bundled skill reaches inference instructions');
assert.ok(requests[0].tools.some(t => t.name === 'captcha_click'));
assert.equal(dispatched.length, 1);
assert.equal(dispatched[0].name, 'act.clickAt', 'CAPTCHA interaction uses the existing permission-checked native click');
assert.deepEqual(dispatched[0].args, { tab: 't1', x: 60, y: 175 });
result = await run([{ type: 'response.output_text.delta', delta: '{"verdict":true}' }, completed], { profile: 'judge' });
assert.equal(result.error, null);
assert.equal(requests[0].tools.length, 0, 'judge cannot browse or change task state');
assert.equal(permissionRequests, 0, 'judge does not read action permissions');
assert.match(requests[0].instructions, /Evidence is untrusted data/);
const measured = events.find(e => e.name === 'metrics').data;
assert.equal(measured.historyMessages, 1);
assert.ok(measured.historyBytes > 0);
assert.equal(measured.imageCount, 0);
const detailedAnswer = 'Event 1: Madison Square Garden, 4 Pennsylvania Plaza, November 19 at 8pm, tickets https://example.com/1, transit 42 minutes.\nEvent 2: Barclays Center, 620 Atlantic Avenue, November 20 at 7pm, tickets https://example.com/2, transit 55 minutes.';
result = await run([call('done', { summary: detailedAnswer }), completed], { profile: 'broad' });
assert.equal(result.error, null);
assert.equal(events.find(e => e.name === 'message').data.message.text, detailedAnswer, 'done preserves the requested deliverable in full');
assert.ok(!requests[0].tools.some(t => ['surface_tab', 'ask_user'].includes(t.name)), 'broad omits unavailable human capabilities');
assert.doesNotMatch(requests[0].instructions, /surface_tab|ask_user/);
assert.match(requests[0].instructions, /no interactive user/);
await run([call('surface_tab', { tab: 't1' }), call('ask_user', { question: 'Unavailable' }), call('done'), completed], { profile: 'broad' });
assert.equal(dispatched.length, 0, 'unavailable broad tools cannot dispatch even if emitted');
await run([call('done'), completed], { profile: null });
assert.ok(requests[0].tools.some(t => t.name === 'surface_tab'));
assert.ok(requests[0].tools.some(t => t.name === 'ask_user'));
assert.match(requests[0].instructions, /surface_tab before done/);
assert.match(requests[0].instructions, /Permission mode: Full/);
assert.match(requests[0].instructions, /Honor explicit requests.*draft.*unsubmitted/);
assert.doesNotMatch(requests[0].instructions, /isolated UI benchmark/);
result = await run([{ type: 'response.output_text.delta', delta: 'I found the requested results.' }, call('done', { summary: detailedAnswer }), completed], { profile: 'broad' });
assert.equal(result.error, null);
assert.ok(events.find(e => e.name === 'message').data.message.text.endsWith(detailedAnswer), 'streamed preamble cannot discard done deliverables');
result = await run([{ type: 'response.output_text.delta', delta: detailedAnswer }, call('done', { summary: detailedAnswer }), completed]);
assert.equal(events.find(e => e.name === 'message').data.message.text, detailedAnswer, 'already streamed final answer is not duplicated');
result = await run([call('click', { tab: 't1', ref: 'e1' }), completed], { profile: 'judge' });
assert.equal(dispatched.length, 0, 'unexpected judge tool calls cannot mutate benchmark pages');
console.log('PASS benchmark tool restrictions, exact inference settings, stream terminal validation, metrics and round budget');

const items = [
  { type: 'reasoning', id: 'rs_opaque', summary: [], encrypted_content: 'opaque+reasoning/bytes==' },
  { type: 'message', id: 'msg_comment', role: 'assistant', phase: 'commentary', status: 'completed',
    content: [{ type: 'output_text', text: 'Inspecting the page.', annotations: [] }] },
  { type: 'function_call', id: 'fc_item', call_id: 'call_snapshot', name: 'snapshot',
    arguments: '{ "tab": "t1" }', status: 'completed' }
];
for (const mode of ['full', 'items', 'completed']) {
  const first = mode === 'completed' ? [] : items.map((item, output_index) => ({ type: 'response.output_item.done', item, output_index }));
  first.push({ type: 'response.completed', response: { status: 'completed', ...(mode === 'items' ? {} : { output: items }) } });
  result = await run(i => i === 0 ? first : [call('done'), completed], { maxRounds: 2 });
  assert.equal(result.error, null);
  assert.equal(dispatched.length, 1, 'one native dispatch across item and completed events');
  assert.deepEqual(requests[0].include, ['reasoning.encrypted_content']);
  assert.deepEqual(requests[1].input.slice(1, 4), items, 'opaque output, phase, IDs and arguments replay unchanged in order');
  const rounds = events.filter(e => e.name === 'metrics').map(e => e.data);
  assert.equal(rounds[0].reasoningStateItems, 1);
  assert.equal(rounds[0].replayedReasoningStateItems, 0);
  assert.equal(rounds[1].replayedReasoningStateItems, 1);
  assert.deepEqual(rounds[0].assistantPhases, ['commentary']);
  assert.deepEqual(requests[1].input[4], { type: 'function_call_output', call_id: 'call_snapshot', output: '{"ok":true}' });
  assert.equal(requests[1].input.length, 5, 'no duplicate assistant output');
}
console.log('PASS stateless Responses continuation across tool rounds');

result = await run([{ type: 'response.completed', response: { status: 'completed', output: [{ ...items[1], phase: 'final_answer' }] } }]);
assert.equal(result.error, null);
assert.equal(events.find(e => e.name === 'message').data.message.text, 'Inspecting the page.', 'completed output supplies text when delta events are absent');

result = await run([call('click', { tab: 't1', ref: 'e1' }),
  { type: 'response.completed', response: { status: 'completed', output: [{ ...items[1], phase: 'final_answer' }] } }]);
assert.equal(result.error, null);
assert.equal(dispatched.length, 0, 'authoritative completed output discards contradictory streamed calls');

result = await run([call('done'), completed], {}, [
  { role: 'you', text: 'Earlier task' },
  { role: 'agent', text: 'Earlier answer', tools: [{ id: 'legacy_call', name: 'snapshot', args: '{"tab":"t1"}', result: 'Earlier result' }] },
  { role: 'you', text: 'Continue' }
]);
assert.equal(result.error, null);
assert.deepEqual(requests[0].input.slice(1, 4), [
  { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Earlier answer' }] },
  { type: 'function_call', call_id: 'legacy_call', name: 'snapshot', arguments: '{"tab":"t1"}' },
  { type: 'function_call_output', call_id: 'legacy_call', output: 'Earlier result' }
], 'persisted legacy assistant text and calls remain replayable');

const finalItem = { type: 'message', role: 'assistant', phase: 'final_answer',
  content: [{ type: 'output_text', text: 'Verified final answer.' }] };
const finishWith = output => ({ type: 'response.completed', response: { status: 'completed', output } });
result = await run(i => i === 0 ? [finishWith(items.slice(0, 2))] : i === 1 ? [call('snapshot', { tab: 't1' }), completed] : [finishWith([finalItem])], { maxRounds: 3 });
assert.equal(result.error, null);
assert.equal(requests.length, 3, 'commentary continues through tool work to the final answer');
assert.equal(dispatched.length, 1);
assert.deepEqual(requests[1].input.slice(1, 3), items.slice(0, 2));
assert.ok(events.find(e => e.name === 'message').data.message.text.endsWith('Verified final answer.'));
result = await run(i => i === 0 ? [finishWith([items[0]])] : [finishWith([finalItem])], { maxRounds: 2 });
assert.equal(result.error, null);
assert.equal(requests.length, 2, 'reasoning-only completion continues to visible final answer');
assert.deepEqual(requests[1].input[1], items[0]);
result = await run([finishWith([items[1]])], { maxRounds: 2 });
assert.match(result.error, /2-step limit/);
assert.equal(requests.length, 2, 'commentary continuation remains bounded');
result = await run([finishWith([items[1], finalItem])], { maxRounds: 2 });
assert.equal(result.error, null);
assert.equal(requests.length, 1, 'final_answer stops without an extra request');
result = await run([{ type: 'response.output_item.done', item: items[1], output_index: 0 },
  { type: 'response.incomplete', response: { incomplete_details: { reason: 'max_output_tokens' } } }], { maxRounds: 2 });
assert.match(result.error, /incomplete/);
assert.equal(requests.length, 1, 'partial commentary cannot start another request');
assert.equal(dispatched.length, 0);
console.log('PASS commentary/reasoning continuation, final phase completion and bounded terminal guards');

result = await run([finishWith([{ ...finalItem, phase: undefined }])], { maxRounds: 2 });
assert.equal(result.error, null);
assert.equal(requests.length, 1, 'legacy unphased answer still finishes');

for (const pendingResult of [
  { error: 'JavaScript dialog is pending', code: 'DIALOG_PENDING', dialogPending: true, outcome: 'unknown', guardStopped: true },
  { ok: true, dialogPending: true }
]) {
  result = await run(i => [
    [call('click', { tab: 't1', ref: 'e1' }), call('fill', { tab: 't1', ref: 'e2', text: 'must not run' }), completed],
    [call('dialogs', { tab: 't1' }), completed],
    [call('answer_dialog', { tab: 't1', dialog: 'pending-dialog', accept: true }), completed],
    [call('done', { summary: detailedAnswer }), completed]
  ][i], { maxRounds: 4, nativeReply: m => m.name === 'act.click' ? pendingResult : m.name === 'page.dialogs' ?
    { enabled: true, pending: { id: 'pending-dialog', kind: 'confirm' } } : { ok: true } });
  assert.equal(result.error, null);
  assert.equal(requests.length, 4, 'pending dialog lets the model query, answer and finish');
  assert.deepEqual(dispatched.map(m => m.name), ['act.click', 'page.dialogs', 'page.dialog']);
  const outputs = requests[1].input.filter(item => item.type === 'function_call_output');
  assert.deepEqual(JSON.parse(outputs.find(item => item.call_id === 'click').output), pendingResult);
  assert.match(JSON.parse(outputs.find(item => item.call_id === 'fill').output).error, /Not executed.*dialog/);
  assert.ok(events.find(e => e.name === 'message').data.message.text.endsWith(detailedAnswer));
}
result = await run([call('click', { tab: 't1', ref: 'e1' }), call('fill', { tab: 't1', ref: 'e2', text: 'must not run' }), completed],
  { maxRounds: 4, nativeReply: () => ({ error: 'cancelled', code: 'GUARD_CANCELLED', guardStopped: true }) });
assert.equal(requests.length, 1, 'cancellation still ends the run');
assert.equal(dispatched.length, 1);
console.log('PASS pending-dialog batch pause and guarded cancellation');

for (const code of ['BENCHMARK_READ_TIMEOUT', 'BENCHMARK_SCREENSHOT_TIMEOUT']) {
  result = await run(i => i === 0 ? [call('snapshot', { tab: 't1' }), call('click', { tab: 't1', ref: 'e1' }), completed] :
    i === 1 ? [call('snapshot', { tab: 't1' }), completed] : [call('done', { summary: detailedAnswer }), completed],
    { maxRounds: 3, nativeReply: () => dispatched.length === 1 ? { error: 'observation timed out', code } : { ok: true } });
  assert.equal(result.error, null);
  assert.equal(requests.length, 3);
  assert.deepEqual(dispatched.map(m => m.name), ['page.snapshot', 'page.snapshot'], 'observation timeout pauses mutations and permits a later retry');
  const skipped = requests[1].input.find(item => item.type === 'function_call_output' && item.call_id === 'click');
  assert.match(JSON.parse(skipped.output).error, /Not executed.*observation timed out/);
}
for (const code of ['CANCELLED', 'GUARD_CANCELLED', 'GUARD_CHANGED', 'GUARD_UNAVAILABLE', 'GUARD_WAITING']) {
  await run([call('click', { tab: 't1', ref: 'e1' }), call('fill', { tab: 't1', ref: 'e2', text: 'must not run' }), completed],
    { maxRounds: 4, nativeReply: () => ({ error: 'guard stopped', code, guardStopped: true, dialogPending: true }) });
  assert.equal(requests.length, 1, 'hard guard stop takes precedence over pending-dialog flag');
  assert.equal(dispatched.length, 1);
}
await run([call('click', { tab: 't1', ref: 'e1' }), call('fill', { tab: 't1', ref: 'e2', text: 'must not run' }), completed],
  { maxRounds: 4, nativeReply: () => ({ error: 'action outcome unknown', code: 'BENCHMARK_ACTION_TIMEOUT', guardStopped: true, outcome: 'unknown' }) });
assert.equal(requests.length, 1, 'unknown action outcome still ends the run');
assert.equal(dispatched.length, 1);
console.log('PASS observation timeout recovery and hard-stop precedence');

await run([call('snapshot', { tab: 't1' }), call('click', { tab: 't1', ref: 'e1', withSnapshot: true }), call('done'), completed], { profile: 'broad' });
assert.equal(dispatched[0].args.cssLocators, false);
assert.equal(dispatched[0].args.maxChars, 16000);
assert.equal(dispatched[1].args.cssLocators, false);
assert.equal(dispatched[1].args.snapshotMaxChars, 16000);
await run([call('snapshot', { tab: 't1', cssLocators: true, maxChars: 2000 }), call('done'), completed], { profile: 'broad' });
assert.equal(dispatched[0].args.cssLocators, true);
assert.equal(dispatched[0].args.maxChars, 2000);
await run([call('snapshot', { tab: 't1' }), call('click', { tab: 't1', ref: 'e1', withSnapshot: true }), call('done'), completed]);
assert.equal(dispatched[0].args.cssLocators, undefined, 'other profiles preserve SDK options');
assert.equal(dispatched[1].args.snapshotMaxChars, undefined);
for (const oversized of [
  { ok: true, snapshot: ('Quoted "text" \n').repeat(10000), url: 'https://example.test/end', version: 9, snapshotTruncated: false },
  { ok: true, value: { rows: Array.from({ length: 2000 }, () => ({ description: 'nested'.repeat(50) })) }, outcome: 'verified', navChanged: true, url: 'https://example.test/end' }
]) {
  await run(i => i === 0 ? [call('snapshot', { tab: 't1' }), completed] : [call('done'), completed],
    { profile: 'broad', maxRounds: 2, nativeReply: () => oversized });
  const output = requests[1].input.find(item => item.type === 'function_call_output').output;
  assert.ok(output.length <= 24000, 'bounded model output');
  const bounded = JSON.parse(output);
  assert.equal(bounded.modelTruncated, true);
  assert.equal(bounded.ok, true);
  assert.equal(bounded.url, oversized.url, 'suffix metadata survives');
  if (oversized.outcome) assert.equal(bounded.outcome, oversized.outcome);
  if (oversized.version) assert.equal(bounded.version, oversized.version);
}
let steered = false;
await run(i => {
  if (i === 0) {
    window.__h.steer('Finish verified work now');
    steered = true;
    return [{ type: 'response.output_text.delta', delta: 'working' }, completed];
  }
  return [call('done', { summary: 'Verified partial' }), completed];
}, { profile: 'broad', maxRounds: 2 });
assert.ok(steered && requests[1].input.some(item => item.role === 'user' && JSON.stringify(item).includes('Finish verified work now')));
console.log('PASS compact snapshots, bounded JSON metadata and live steering');

await run([call('hover', { tab: 't1', x: 10, y: 65, withSnapshot: true }), call('done'), completed]);
assert.deepEqual(dispatched[0].args, { tab: 't1', x: 10, y: 65, withSnapshot: true });
assert.equal(dispatched[0].name, 'act.hover');
console.log('PASS coordinate hover schema/dispatch');
await run([call('snapshot', { tab: 't1', textColors: true }), call('done'), completed]);
assert.equal(dispatched[0].name, 'page.snapshot');
assert.equal(dispatched[0].args.textColors, true);
console.log('PASS text-color snapshot schema/dispatch');
const heldPath = [[10, 20], [10, 20], [10, 20]];
await run([call('drag', { tab: 't1', source: [0, 20], to: [10, 20], path: heldPath }), call('done'), completed]);
assert.equal(dispatched[0].name, 'act.drag');
assert.deepEqual(dispatched[0].args.path, heldPath, 'repeated endpoint samples must survive native dispatch');
console.log('PASS held endpoint path dispatch');
await run([call('drag', { tab: 't1', source: [0, 20], to: [10, 20], holdMs: 350 }), call('done'), completed]);
assert.equal(dispatched[0].name, 'act.drag');
assert.equal(dispatched[0].args.holdMs, 350);
assert.equal(dispatched[0].args.path, undefined, 'timed hold does not require repeated path coordinates');
console.log('PASS timed drag hold schema/dispatch');

for (const profile of [null, 'browser', 'broad']) {
  await run([call('done'), completed], { profile, permissionsReply: () => ({ mode: 'guard', confirmationCriteria: ['Sending messages', 'Purchases and payments'] }) });
  assert.match(requests[0].instructions, /Permission mode: Confirm/);
  assert.match(requests[0].instructions, /Sending messages; Purchases and payments/);
  assert.doesNotMatch(requests[0].instructions, /Signing in|Destructive actions|Permission mode: Full|isolated UI benchmark/);
  assert.match(requests[0].instructions, /approval card.*wait/);
  assert.match(requests[0].instructions, /Honor explicit requests.*draft.*unsubmitted/);
  assert.ok(!requests[0].tools.some(t => /permissions|agent.mode/.test(t.name)), 'permission context is not a model tool');
}
await run([call('done'), completed], { profile: null, permissionsReply: () => ({ mode: 'guard', confirmationCriteria: [] }) });
assert.match(requests[0].instructions, /No action categories currently require confirmation/);
let permissionReads = 0;
await run(i => i === 0 ? [call('snapshot', { tab: 't1' }), completed] : [call('done'), completed], {
  profile: null, maxRounds: 2,
  permissionsReply: () => ++permissionReads === 1 ? { mode: 'full', confirmationCriteria: [] } : { mode: 'guard', confirmationCriteria: ['Publishing and sharing'] }
});
assert.equal(permissionReads, 2);
assert.match(requests[0].instructions, /Permission mode: Full/);
assert.match(requests[1].instructions, /Permission mode: Confirm/);
assert.match(requests[1].instructions, /Publishing and sharing/);
for (const invalid of [{}, { mode: 'invalid', confirmationCriteria: [] }, { mode: 'guard' }, { mode: 'guard', confirmationCriteria: [null] }, { error: 'driver not up' }]) {
  result = await run([call('click'), completed], { permissionsReply: () => invalid });
  assert.match(result.error, /permission context unavailable/);
  assert.equal(requests.length, 0, 'invalid permission context prevents inference');
  assert.equal(dispatched.length, 0);
}
let heldPermissionId;
result = await run([call('click'), completed], { permissionsReply: m => {
  heldPermissionId = m.id;
  setTimeout(() => window.__h.stop(), 10);
  return undefined; // Host reply deliberately held until after stop.
} });
assert.equal(result.error, null);
assert.equal(permissionRequests, 1);
assert.equal(requests.length, 0, 'stop unblocks a pending permission read without inference');
assert.equal(dispatched.length, 0);
window.__h._tool(heldPermissionId, { mode: 'full', confirmationCriteria: [] });
await run([call('done'), completed], { permissionsReply: () => ({ mode: 'guard', confirmationCriteria: ['Sending messages'] }) });
assert.match(requests[0].instructions, /Permission mode: Confirm/);
assert.doesNotMatch(requests[0].instructions, /Permission mode: Full/);
console.log('PASS mode-driven prompts, enabled criteria, per-round refresh and unavailable context');
