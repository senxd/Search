// Fake provider and fake tool bridge: no network or live data.
import assert from 'node:assert/strict';
globalThis.window = globalThis;
const posts = [], events = [];
let waiting;
window.__native = {post(m) {
  posts.push(m);
  if (m.kind === 'permissions') setTimeout(() => __h._tool(m.id, { mode: 'guard', confirmationCriteria: ['Sending messages', 'Destructive actions'] }), 0);
  if (m.kind === 'event') events.push(m);
  if (m.kind === 'tool') waiting = m;
  if (m.kind === 'fetch') setTimeout(() => {
    __h._fetchMeta(m.id, 200, '{}');
    __h._fetchLine(m.id, 'data: ' + JSON.stringify({choices:[{delta:{tool_calls:[
      {index:0,id:'first',function:{name:'click',arguments:'{"tab":"fake","text":"Send"}'}},
      {index:1,id:'second',function:{name:'click',arguments:'{"tab":"fake","text":"Delete"}'}}
    ]}}]}));
    __h._fetchLine(m.id, 'data: [DONE]');
    __h._fetchEnd(m.id, 200, null, null);
  }, 0);
}};
await import('../../Runtime/ask/harness.js');
const wait = async predicate => {
  for (let i=0;i<200;i++) { if(predicate()) return; await Bun.sleep(10); }
  throw new Error('Timed out waiting for harness');
};
for (const code of ['GUARD_CANCELLED','GUARD_CHANGED','GUARD_UNAVAILABLE']) {
  waiting = null; posts.length=0; events.length=0;
  const chat = crypto.randomUUID();
  __h.run({chat:{id:chat,model:'openrouter/mock',messages:[{role:'you',text:'Test fake actions'}]},tabs:[],text:'Test'});
  await wait(() => waiting);
  await Bun.sleep(50);
  assert.equal(posts.filter(m=>m.kind==='tool').length,1,'batch proceeds while approval waits');
  assert.equal(posts.filter(m=>m.kind==='fetch').length,1,'model runs while approval waits');
  __h._tool(waiting.id,{error:'Guard stopped action',code,guardStopped:true});
  await wait(() => events.some(m=>m.name==='done' && m.data.chat===chat));
  assert.equal(posts.filter(m=>m.kind==='tool').length,1,'second action ran after cancellation/change');
  assert.equal(posts.filter(m=>m.kind==='fetch').length,1,'model retried denied action');
  await Bun.sleep(0);
}
console.log('PASS harness waits without more tools/model calls and stops cancelled, changed, unavailable batches');
