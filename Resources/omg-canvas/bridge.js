(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.OMGCanvasBridge = api;
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';
  const methods = new Set(['canvas.snapshot', 'session.create', 'session.open', 'session.dismiss', 'canvas.setPositions', 'canvas.link']);
  const runtimes = new Set(['shell', 'python', 'codex', 'claude']);
  const finite = Number.isFinite;
  function fail(code, message) { const error = new Error(message); error.code = code; return error; }
  function text(value) { return typeof value === 'string' && value.length > 0; }
  function viewport(value) {
    if (!value || ![value.x, value.y, value.scale].every(finite) || value.scale <= 0) throw fail('invalid_snapshot', 'Invalid canvas viewport.');
    return {x: value.x, y: value.y, scale: Math.max(.25, Math.min(2.2, value.scale))};
  }
  function snapshot(value) {
    if (!value || value.version !== 1 || !text(value.workspace?.id) || !Array.isArray(value.nodes) || !Array.isArray(value.edges) || !Array.isArray(value.runtimes) || !Number.isSafeInteger(value.revision)) throw fail('invalid_snapshot', 'Invalid canvas state.');
    const ids = new Set();
    const nodes = value.nodes.map(node => {
      if (!text(node.id) || ids.has(node.id) || ![node.x, node.y].every(finite)) throw fail('invalid_snapshot', 'Invalid session identity or position.');
      ids.add(node.id);
      return {...node, title: typeof node.title === 'string' ? node.title : '', runtime: runtimes.has(node.runtime) ? node.runtime : 'unknown', available: typeof node.available === 'boolean' ? node.available : null};
    });
    const edgeIDs = new Set();
    const edges = value.edges.map(edge => {
      if (!text(edge.id) || edgeIDs.has(edge.id) || !ids.has(edge.source) || !ids.has(edge.target) || edge.source === edge.target || !['created_from', 'linked'].includes(edge.kind)) throw fail('invalid_snapshot', 'Invalid session relationship.');
      edgeIDs.add(edge.id); return {...edge};
    });
    return {...value, nodes, edges, viewport: viewport(value.viewport), selectedId: ids.has(value.selectedId) ? value.selectedId : null, terminalOpen: value.terminalOpen === true};
  }
  function request(method, params, id) {
    if (!methods.has(method)) throw fail('unsupported_method', 'Unsupported canvas action.');
    if (!text(id) || !params || typeof params !== 'object' || Array.isArray(params)) throw fail('invalid_request', 'Invalid canvas request.');
    if (method === 'session.create' && Object.keys(params).some(key => !['title', 'runtime'].includes(key))) throw fail('invalid_request', 'A new terminal accepts only a title and runtime.');
    return {version: 1, id, method, params: JSON.parse(JSON.stringify(params))};
  }
  function unwrap(reply) {
    if (reply?.ok === true && Object.hasOwn(reply, 'value')) return reply.value;
    if (reply?.ok === false && typeof reply.error?.message === 'string') throw fail(reply.error.code || 'native_error', reply.error.message);
    throw fail('invalid_reply', 'Invalid native response.');
  }
  function createClient(transport, makeID) {
    let queue = Promise.resolve();
    let createAttempt = null;
    function send(method, params = {}, id = makeID()) {
      const body = request(method, params, id);
      const run = queue.then(async () => unwrap(await transport(body)));
      queue = run.catch(() => {});
      return run;
    }
    return {
      send,
      create(params) {
        const signature = JSON.stringify(params);
        if (!createAttempt || createAttempt.signature !== signature) createAttempt = {signature, id: makeID()};
        return send('session.create', params, createAttempt.id);
      },
      resetCreate() { createAttempt = null; }
    };
  }
  function createStateReceiver(onState) {
    let workspaceID = null, revision = -1;
    return raw => {
      const next = snapshot(raw);
      if (workspaceID && workspaceID !== next.workspace.id) throw fail('workspace_changed', 'The canvas workspace changed. Reopen this canvas.');
      if (next.revision < revision) return false;
      workspaceID = next.workspace.id; revision = next.revision;
      onState(next); return true;
    };
  }
  function zoom(view, x, y, scale) {
    const next = Math.max(.25, Math.min(2.2, scale));
    return {x: x - (x - view.x) / view.scale * next, y: y - (y - view.y) / view.scale * next, scale: next};
  }
  return {request, unwrap, snapshot, createClient, createStateReceiver, zoom};
});
