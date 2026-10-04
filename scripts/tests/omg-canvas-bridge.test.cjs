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
  value.edges[0].kind = 'fork';
  assert.throws(() => bridge.snapshot(value), error => error.code === 'invalid_snapshot');
  value.edges[0].kind = 'linked'; value.edges[0].target = 'missing-node';
  assert.throws(() => bridge.snapshot(value), error => error.code === 'invalid_snapshot');
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
  }
  assert.equal(messages.localeFor('en_US'), 'en');
  assert.equal(messages.localeFor('zh-TW'), 'zh-Hant');
  assert.equal(messages.localeFor('zh-CN'), 'zh-Hans');
  assert.equal(messages.localeFor('fr-FR'), 'fr');
});
