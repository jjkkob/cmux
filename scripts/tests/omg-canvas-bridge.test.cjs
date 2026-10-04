'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const resources = path.resolve(__dirname, '../../Resources/omg-canvas');
const bridge = require(path.join(resources, 'bridge.js'));
const messages = require(path.join(resources, 'messages.js'));
// The native producer and browser consumer share this production-shaped fixture.
const fixture = require(path.join(resources, 'bridge-fixture.json'));
const clone = value => JSON.parse(JSON.stringify(value));

test('native create remains standalone when another node was selected', async () => {
  const sent = [];
  let current;
  const receive = bridge.createStateReceiver(state => { current = state; });
  receive(clone(fixture.beforeCreateSnapshot));
  assert.equal(current.selectedId, current.nodes[0].id);
  const client = bridge.createClient(async body => { sent.push(body); return clone(fixture.response); }, () => fixture.request.id);
  const result = await client.create(clone(fixture.request.params));
  assert.deepEqual(sent, [fixture.request]);
  assert.deepEqual(Object.keys(sent[0].params).sort(), ['runtime', 'title']);
  receive(result.snapshot);
  assert.equal(current.nodes.find(node => node.id === result.nodeId).title, 'Research CLI');
  assert.equal(current.selectedId, result.nodeId);
  assert.equal(current.terminalOpen, true);
  assert.equal(current.nodes.length, 2);
  assert.deepEqual(current.edges, []);
  assert.equal(current.nodes[0].runtime, 'unknown');
});

test('only the later explicit connect action adds the recorded relationship', async () => {
  let current;
  const receive = bridge.createStateReceiver(state => { current = state; });
  receive(clone(fixture.response.value.snapshot));
  assert.deepEqual(current.edges, []);
  const sent = [];
  const client = bridge.createClient(async body => { sent.push(body); return clone(fixture.linkResponse); }, () => fixture.linkRequest.id);
  receive(await client.send('canvas.link', clone(fixture.linkRequest.params)));
  assert.deepEqual(sent, [fixture.linkRequest]);
  assert.equal(current.edges.length, 1);
  assert.deepEqual(current.edges[0], fixture.linkResponse.value.edges[0]);
  assert.equal(current.edges[0].kind, 'linked');
});

test('obsolete create parent context is rejected before reaching the native transport', () => {
  let calls = 0;
  const client = bridge.createClient(() => { calls++; return fixture.response; }, () => fixture.request.id);
  assert.throws(() => client.create(fixture.obsoleteParentRequest.params), error => error.code === 'invalid_request');
  assert.equal(calls, 0);
});

test('layout requests preserve the native contract and capture submitted values', async () => {
  let sent;
  const params = clone(fixture.positionsRequest.params);
  const client = bridge.createClient(async body => { sent = body; return {ok: true, value: fixture.response.value.snapshot}; }, () => fixture.positionsRequest.id);
  const pending = client.send('canvas.setPositions', params);
  params.positions[0].x = 9000;
  bridge.snapshot(await pending);
  assert.deepEqual(sent, fixture.positionsRequest);
});

test('an unknown creation outcome keeps the same id on an identical explicit retry', async () => {
  const calls = [];
  let counter = 0, fail = true;
  const client = bridge.createClient(async body => {
    calls.push(body);
    if (fail) { fail = false; throw new Error('Transport interrupted after creation'); }
    return clone(fixture.response);
  }, () => `request-${++counter}`);
  const params = clone(fixture.request.params);
  await assert.rejects(client.create(params), /Transport interrupted/);
  assert.equal(calls.length, 1, 'no automatic mutation retry');
  await client.create(params);
  assert.equal(calls[0].id, calls[1].id);
  await client.create({...params, title: 'Different intent'});
  assert.notEqual(calls[1].id, calls[2].id);
  client.resetCreate();
  await client.create({...params, title: 'Different intent'});
  assert.notEqual(calls[2].id, calls[3].id);
});

test('mutations serialize, and a failed request does not block later work', async () => {
  const calls = [];
  let release;
  const client = bridge.createClient(body => {
    calls.push(body.method);
    if (calls.length === 1) return new Promise(resolve => { release = resolve; });
    return Promise.resolve({ok: true, value: fixture.response.value.snapshot});
  }, () => 'request-id');
  const first = client.send('canvas.setPositions', {positions: []});
  const second = client.send('session.open', {id: fixture.response.value.nodeId});
  await Promise.resolve();
  assert.deepEqual(calls, ['canvas.setPositions']);
  release(fixture.errorResponse);
  await assert.rejects(first, error => error.code === 'unavailable');
  await second;
  assert.deepEqual(calls, ['canvas.setPositions', 'session.open']);
});

test('late replies cannot replace a newer native selection or change the bound workspace', () => {
  const received = [];
  const accept = bridge.createStateReceiver(state => received.push(state));
  const current = clone(fixture.response.value.snapshot);
  current.revision = 10; current.terminalOpen = false;
  assert.equal(accept(current), true);
  assert.equal(accept(fixture.response.value.snapshot), false);
  assert.equal(received.length, 1);
  assert.equal(received[0].terminalOpen, false);
  const otherWorkspace = clone(current); otherWorkspace.workspace.id = 'different-workspace';
  assert.throws(() => accept(otherWorkspace), error => error.code === 'workspace_changed');
  assert.equal(received.length, 1);
});

test('unobserved runtime and availability remain unknown, without invented lifecycle status', () => {
  const value = clone(fixture.response.value.snapshot);
  value.nodes[0].runtime = 'unrecognized-provider'; delete value.nodes[0].available;
  const node = bridge.snapshot(value).nodes[0];
  assert.equal(node.runtime, 'unknown'); assert.equal(node.available, null);
  assert.equal(Object.hasOwn(node, 'status'), false);
});

test('invalid or dangling relationships are rejected rather than called created_from', () => {
  const value = clone(fixture.linkResponse.value);
  value.edges[0].kind = 'merge';
  assert.throws(() => bridge.snapshot(value), error => error.code === 'invalid_snapshot');
  value.edges[0].kind = 'linked'; value.edges[0].target = 'missing-node';
  assert.throws(() => bridge.snapshot(value), error => error.code === 'invalid_snapshot');
});

test('native history snapshot preserves identity, dates, evidence and recorded metadata without live status', () => {
  const saved = bridge.snapshot(clone(fixture.historySnapshot));
  assert.deepEqual(saved.nodes, fixture.historySnapshot.nodes);
  assert.deepEqual(saved.edges, fixture.historySnapshot.edges);
  assert.equal(saved.nodes[0].available, false);
  assert.equal(saved.nodes[0].canResume, true);
  assert.equal(saved.nodes[3].createdAt, '', 'unknown source date must remain unknown');
  assert.deepEqual(saved.edges.map(edge => edge.kind), ['spawn', 'fork', 'handoff', 'continuation']);
  assert.equal(saved.nodes[2].history.sessionId, 'synthetic-worker:3');
});

test('resume uses only the exact imported canvas identity and preserves native failures', async () => {
  let sent;
  const client = bridge.createClient(async body => { sent=body; return fixture.errorResponse; }, () => fixture.historyResumeRequest.id);
  await assert.rejects(client.send('session.resume',fixture.historyResumeRequest.params), error => error.code === 'unavailable');
  assert.deepEqual(sent, fixture.historyResumeRequest);
  assert.throws(() => client.send('session.resume',{...fixture.historyResumeRequest.params,command:'run'}), error => error.code === 'invalid_request');
  assert.throws(() => client.send('session.resume',{}), error => error.code === 'invalid_request');
});

test('main and mission default keeps only existing visible-endpoint edges; show all reveals workers and observations', () => {
  const saved=bridge.snapshot(clone(fixture.historySnapshot));
  const normal=bridge.visibleGraph(saved);
  assert.deepEqual(normal.matching.map(node => node.history.role), ['main','mission','main']);
  assert.deepEqual(normal.edges.map(edge => edge.kind), ['spawn','handoff']);
  assert.equal(normal.hiddenEdges,2);
  const all=bridge.visibleGraph(saved,{includeAll:true});
  assert.equal(all.nodes.length,5);
  assert.deepEqual(all.edges,saved.edges);
  assert.deepEqual(saved,bridge.snapshot(fixture.historySnapshot),'filters never mutate imported graph');
});

test('search finds hidden workers by original session identity without synthesizing lineage', () => {
  const saved=bridge.snapshot(clone(fixture.historySnapshot));
  const found=bridge.visibleGraph(saved,{query:'synthetic-worker:3'});
  assert.equal(found.matching.length,1);
  assert.equal(found.matching[0].history.role,'worker');
  assert.deepEqual(found.edges,[]);
  assert.equal(found.hiddenEdges,4);
  const absent=bridge.visibleGraph(saved,{query:'No such session'});
  assert.equal(absent.nodes.length,0);
});

test('large historical graphs retain all records while mounting only nearby nodes', () => {
  const saved=bridge.snapshot(clone(fixture.historySnapshot));
  saved.nodes=Array.from({length:1601},(_,i) => ({...saved.nodes[0],id:`synthetic-${i}`,x:(i%40)*360,y:Math.floor(i/40)*240}));
  saved.edges=[];
  const visible=bridge.visibleGraph(saved,{includeAll:true,view:{x:0,y:0,scale:1},width:1200,height:800});
  assert.equal(visible.matching.length,1601);
  assert.ok(visible.nodes.length>0 && visible.nodes.length<40);
  const later=bridge.visibleGraph(saved,{includeAll:true,view:{x:-7200,y:-4800,scale:1},width:1200,height:800});
  assert.ok(later.nodes.some(node => !visible.nodes.includes(node)));
  assert.equal(saved.nodes.length,1601);
});

test('culling keeps a real edge crossing the viewport even with both nodes outside it', () => {
  const saved=bridge.snapshot(clone(fixture.historySnapshot));
  saved.nodes=saved.nodes.slice(0,2);
  saved.nodes[0].x=-800; saved.nodes[1].x=1600; saved.nodes.forEach(node => {node.y=200;});
  saved.edges=saved.edges.slice(0,1);
  const visible=bridge.visibleGraph(saved,{view:{x:0,y:0,scale:1},width:1000,height:700,overscan:0});
  assert.equal(visible.nodes.length,0);
  assert.deepEqual(visible.edges,saved.edges);
});

test('malformed historical metadata fails as a contract error', () => {
  const saved=clone(fixture.historySnapshot);
  saved.nodes[0].history.source='';
  assert.throws(() => bridge.snapshot(saved),error => error.code === 'invalid_snapshot');
  saved.nodes[0].history.source='codex'; saved.nodes[0].history.summary={text:'not a string'};
  assert.throws(() => bridge.snapshot(saved),error => error.code === 'invalid_snapshot');
  saved.nodes[0].history.summary='Valid'; saved.nodes[0].canResume='yes';
  assert.throws(() => bridge.snapshot(saved),error => error.code === 'invalid_snapshot');
});

test('explicit relationships from saved history remain intact without inventing new ones', () => {
  const value = clone(fixture.linkResponse.value);
  value.edges[0].kind = 'created_from';
  const saved = bridge.snapshot(value);
  assert.deepEqual(saved.edges, value.edges);
  assert.equal(saved.edges.length, 1);
});

test('native errors retain their code and message; malformed replies are distinct', () => {
  assert.throws(() => bridge.unwrap(fixture.errorResponse), error => error.code === 'unavailable' && error.message === fixture.errorResponse.error.message);
  assert.throws(() => bridge.unwrap({ok: true}), error => error.code === 'invalid_reply');
  assert.throws(() => bridge.request('terminal.sendText', {text: 'run'}, 'id'), error => error.code === 'unsupported_method');
});

test('pointer-anchored zoom preserves the same world point without modifying the input', () => {
  const original = {x: -120, y: 40, scale: .8}, pointer = {x: 300, y: 240};
  const result = bridge.zoom(original, pointer.x, pointer.y, 1.7);
  assert.equal((pointer.x - original.x) / original.scale, (pointer.x - result.x) / result.scale);
  assert.equal((pointer.y - original.y) / original.scale, (pointer.y - result.y) / result.scale);
  assert.deepEqual(original, {x: -120, y: 40, scale: .8});
  assert.equal(bridge.zoom(original, 0, 0, 99).scale, 2.2);
});

test('nine locale catalogs have matching keys and preserve interpolation values', () => {
  assert.deepEqual(Object.keys(messages.catalogs).sort(), ['ar', 'de', 'en', 'es', 'fr', 'ja', 'ko', 'zh-Hans', 'zh-Hant'].sort());
  for (const [locale, catalog] of Object.entries(messages.catalogs)) {
    assert.deepEqual(Object.keys(catalog), messages.keys);
    assert.match(messages.translate(locale, 'added', {date: '2026-10-03'}), /2026-10-03/);
    assert.ok(messages.translate(locale, 'connectSession'));
    assert.match(messages.translate(locale,'shownCount',{shown:155,total:1601}),/155/);
    assert.match(messages.translate(locale,'shownCount',{shown:155,total:1601}),/1601/);
    assert.ok(messages.translate(locale,'resumeUnavailable'));
  }
  assert.equal(messages.localeFor('en_US'), 'en');
  assert.equal(messages.localeFor('zh-TW'), 'zh-Hant');
  assert.equal(messages.localeFor('zh-CN'), 'zh-Hans');
  assert.equal(messages.localeFor('fr-FR'), 'fr');
});
