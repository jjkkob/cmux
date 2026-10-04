(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.OMGCanvasBridge = api;
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';
  const methods = new Set(['canvas.snapshot', 'session.create', 'session.open', 'session.preview', 'session.resume', 'session.dismiss', 'canvas.setPositions', 'canvas.link']);
  const runtimes = new Set(['shell', 'python', 'codex', 'claude']);
  const relationshipKinds = new Set(['created_from', 'linked', 'spawn', 'fork', 'handoff', 'continuation']);
  const finite = Number.isFinite;
  function fail(code, message) { const error = new Error(message); error.code = code; return error; }
  function text(value) { return typeof value === 'string' && value.length > 0; }
  function viewport(value) {
    if (!value || ![value.x, value.y, value.scale].every(finite) || value.scale <= 0) throw fail('invalid_snapshot', 'Invalid canvas viewport.');
    return {x: value.x, y: value.y, scale: Math.max(.25, Math.min(2.2, value.scale))};
  }
  function snapshot(value) {
    if (!value || value.version !== 1 || !text(value.workspace?.id) || !Array.isArray(value.nodes) || !Array.isArray(value.edges) || !Array.isArray(value.runtimes) || !Number.isSafeInteger(value.revision)) throw fail('invalid_snapshot', 'Invalid canvas state.');
    if (value.previewOpen != null && typeof value.previewOpen !== 'boolean') throw fail('invalid_snapshot', 'Invalid preview presentation.');
    const ids = new Set();
    const nodes = value.nodes.map(node => {
      if (!text(node.id) || ids.has(node.id) || ![node.x, node.y].every(finite)) throw fail('invalid_snapshot', 'Invalid session identity or position.');
      ids.add(node.id);
      if (node.history != null) {
        if (!text(node.history.source) || !text(node.history.sessionId)) throw fail('invalid_snapshot', 'Invalid historical session identity.');
        for (const key of ['summary', 'updatedAt', 'role', 'status', 'cwd', 'runtimeConfig']) {
          if (node.history[key] != null && typeof node.history[key] !== 'string') throw fail('invalid_snapshot', 'Invalid historical session metadata.');
        }
        if (node.history.references != null && (!Array.isArray(node.history.references) || node.history.references.some(reference => !text(reference.label) || !text(reference.value)))) throw fail('invalid_snapshot', 'Invalid historical session evidence.');
      }
      if (node.canResume != null && typeof node.canResume !== 'boolean') throw fail('invalid_snapshot', 'Invalid resume availability.');
      return {...node, title: typeof node.title === 'string' ? node.title : '', runtime: runtimes.has(node.runtime) ? node.runtime : 'unknown', available: typeof node.available === 'boolean' ? node.available : null};
    });
    const edgeIDs = new Set();
    const edges = value.edges.map(edge => {
      if (!text(edge.id) || edgeIDs.has(edge.id) || !ids.has(edge.source) || !ids.has(edge.target) || edge.source === edge.target || !relationshipKinds.has(edge.kind) || (edge.evidence != null && typeof edge.evidence !== 'string')) throw fail('invalid_snapshot', 'Invalid session relationship.');
      edgeIDs.add(edge.id); return {...edge};
    });
    return {...value, nodes, edges, viewport: viewport(value.viewport), selectedId: ids.has(value.selectedId) ? value.selectedId : null, terminalOpen: value.terminalOpen === true, previewOpen: value.previewOpen === true};
  }
  function request(method, params, id) {
    if (!methods.has(method)) throw fail('unsupported_method', 'Unsupported canvas action.');
    if (!text(id) || !params || typeof params !== 'object' || Array.isArray(params)) throw fail('invalid_request', 'Invalid canvas request.');
    if (method === 'session.create' && Object.keys(params).some(key => !['title', 'runtime'].includes(key))) throw fail('invalid_request', 'A new terminal accepts only a title and runtime.');
    if (method === 'session.resume' && (Object.keys(params).length !== 1 || !text(params.id))) throw fail('invalid_request', 'Resume requires one existing canvas node identity.');
    if (method === 'session.preview' && (Object.keys(params).some(key => key !== 'id') || (Object.hasOwn(params, 'id') && !text(params.id)))) throw fail('invalid_request', 'Preview accepts only an existing canvas node identity.');
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
  // Filtering never rewrites lineage. Offscreen cards are omitted only from the DOM.
  function visibleGraph(state, {query = '', includeAll = false, view, width, height, overscan = 300} = {}) {
    const search = query.trim().toLocaleLowerCase();
    const matching = state.nodes.filter(node => {
      if (!search && !includeAll && node.history && !['main', 'conductor', 'mission'].includes(node.history.role)) return false;
      if (!search) return true;
      return [node.title, node.runtime, node.history?.summary, node.history?.sessionId, node.history?.source, node.history?.role].some(value => String(value || '').toLocaleLowerCase().includes(search));
    });
    const byID = new Map(matching.map(node => [node.id, node]));
    const matchingEdges = state.edges.filter(edge => byID.has(edge.source) && byID.has(edge.target));
    if (!view || !finite(width) || !finite(height)) return {matching, nodes: matching, edges: matchingEdges, hiddenEdges: state.edges.length - matchingEdges.length};
    const bounds = {left: (-view.x - overscan) / view.scale, right: (width - view.x + overscan) / view.scale, top: (-view.y - overscan) / view.scale, bottom: (height - view.y + overscan) / view.scale};
    const intersects = (left, top, right, bottom) => right >= bounds.left && left <= bounds.right && bottom >= bounds.top && top <= bounds.bottom;
    const nodes = matching.filter(node => intersects(node.x, node.y, node.x + 258, node.y + 154));
    const edges = matchingEdges.filter(edge => {
      const source = byID.get(edge.source), target = byID.get(edge.target);
      return intersects(Math.min(source.x, target.x) - 42, Math.min(source.y, target.y), Math.max(source.x, target.x) + 300, Math.max(source.y, target.y) + 200);
    });
    return {matching, nodes, edges, hiddenEdges: state.edges.length - matchingEdges.length};
  }
  return {request, unwrap, snapshot, createClient, createStateReceiver, zoom, visibleGraph};
});
