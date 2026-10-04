'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const bridge = window.OMGCanvasBridge, messages = window.OMGCanvasMessages;
  const canvas = $('canvas'), world = $('world');
  let locale = messages.localeFor(navigator.language), state = null;
  let view = {x: 0, y: 0, scale: 1}, viewGeneration = 0, savedViewGeneration = 0;
  let positions = new Map(), drag = null, menuID = null, linkSource = null;
  let layoutBusy = false, createBusy = false, refreshBusy = false, terminalWasOpen = false;
  let layoutTimer, toastTimer, edgeKey = '', runtimeKey = '', renderFrame = null;
  let nodeIndex = new Map(), graph = null, historyID = null, resumeBusy = false;
  const t = (key, values) => messages.translate(locale, key, values);
  const text = (element, value) => { if (element.textContent !== value) element.textContent = value; };
  const nodeFor = id => nodeIndex.get(id);
  const client = bridge.createClient(async request => {
    const handler = window.webkit?.messageHandlers?.omgCanvas;
    if (!handler) { const error = new Error(t('bridgeUnavailable')); error.code = 'bridge_unavailable'; throw error; }
    return handler.postMessage(request);
  }, () => crypto.randomUUID());
  function errorMessage(error) {
    if (['invalid_snapshot', 'invalid_reply'].includes(error.code)) return t('invalidState');
    if (error.code === 'workspace_changed') return t('workspaceChanged');
    return error.message || t('invalidState');
  }
  function formError(id, value = '') { $(id).textContent = value; $(id).hidden = !value; }
  function notify(value) {
    clearTimeout(toastTimer); text($('toast'), value); $('toast').hidden = false;
    toastTimer = setTimeout(() => { $('toast').hidden = true; }, 5000);
  }
  function connection(error = null) {
    $('connection-dot').className = `status-dot ${error ? 'error' : 'connected'}`;
    text($('connection-label'), error ? t('unavailable') : t('connected'));
    $('connection-error').hidden = !error;
    $('connection-error').querySelector('span').textContent = error ? errorMessage(error) : '';
    $('create-button').disabled = !!error || !state;
    $('empty-create').disabled = !!error || !state;
  }
  function localize() {
    document.documentElement.lang = locale; document.documentElement.dir = locale === 'ar' ? 'rtl' : 'ltr';
    document.querySelectorAll('[data-i18n]').forEach(el => text(el, t(el.dataset.i18n)));
    document.querySelectorAll('[data-i18n-label]').forEach(el => el.setAttribute('aria-label', t(el.dataset.i18nLabel)));
    $('history-search').placeholder = t('searchSessions');
    canvas.setAttribute('aria-label', t('canvas'));
  }
  function applyView() {
    world.style.transform = `translate(${view.x}px,${view.y}px) scale(${view.scale})`;
    canvas.style.backgroundSize = `${24 * view.scale}px ${24 * view.scale}px`;
    canvas.style.backgroundPosition = `${view.x}px ${view.y}px`;
    if (state && !renderFrame) renderFrame = requestAnimationFrame(() => { renderFrame = null; renderGraph(); });
  }
  function scheduleLayout() { clearTimeout(layoutTimer); layoutTimer = setTimeout(saveLayout, 300); }
  async function saveLayout() {
    if (!state || layoutBusy || (!positions.size && viewGeneration === savedViewGeneration)) return;
    layoutBusy = true;
    const batch = [...positions].map(([id, position]) => ({id, ...position}));
    const sentViewGeneration = viewGeneration;
    const params = {positions: batch, viewport: {...view}};
    let success = false;
    try {
      const result = await client.send('canvas.setPositions', params);
      for (const position of batch) {
        const current = positions.get(position.id);
        if (current?.x === position.x && current?.y === position.y) positions.delete(position.id);
      }
      savedViewGeneration = sentViewGeneration;
      receive(result); success = true;
    } catch (error) { notify(`${t('positionError')} ${errorMessage(error)}`); }
    finally { layoutBusy = false; if (success && (positions.size || viewGeneration !== savedViewGeneration)) scheduleLayout(); }
  }
  function runtimeName(node) {
    if (node.runtime === 'unknown') return t('unknownRuntime');
    return state.runtimes.find(runtime => runtime.id === node.runtime)?.label || t('unknownRuntime');
  }
  function roleName(role) {
    return t(({main:'roleConductor', conductor:'roleConductor', mission:'roleMission', worker:'roleWorker', observation:'roleObservation', reference:'roleReference'})[role] || 'roleUnknown');
  }
  function availability(node) { return node.history ? roleName(node.history.role) : t(node.available === true ? 'available' : node.available === false ? 'unavailable' : 'unknownAvailability'); }
  function nodeDate(value, historical = false) {
    const date = new Date(value);
    return !value || Number.isNaN(date.valueOf()) ? t('unknownDate') : t(historical ? 'recordedOn' : 'added', {date: date.toLocaleDateString(locale, {month: 'short', day: 'numeric'})});
  }
  function renderGraph() {
    if (!state) return;
    graph = bridge.visibleGraph(state, {query:$('history-search').value, includeAll:$('include-workers').checked, view, width:window.innerWidth, height:window.innerHeight});
    // Keep a captured drag element mounted while the pointer leaves the viewport.
    if (drag?.nodeId && nodeFor(drag.nodeId) && !graph.nodes.some(node => node.id === drag.nodeId)) graph.nodes.push(nodeFor(drag.nodeId));
    renderNodes(); renderEdges();
    text($('node-count'), t('shownCount', {shown:graph.matching.length, total:state.nodes.length}));
    $('node-count').title = graph.hiddenEdges ? t('filteredLineage', {count:graph.hiddenEdges}) : '';
    text($('filter-hint'), graph.hiddenEdges ? t('filteredLineage', {count:graph.hiddenEdges}) : '');
  }
  function renderSearch() {
    if (!graph) return;
    const query = $('history-search').value.trim();
    $('search-results').hidden = !query;
    $('search-result-list').replaceChildren();
    if (!query) return;
    text($('search-result-count'), graph.matching.length ? t('resultCount', {shown:Math.min(30,graph.matching.length), total:graph.matching.length}) : t('noMatches'));
    for (const node of graph.matching.slice(0,30)) {
      const button = document.createElement('button'); button.type = 'button';
      const title = document.createElement('span'); title.textContent = node.title;
      const subtitle = document.createElement('small'); subtitle.textContent = `${runtimeName(node)} · ${availability(node)} · ${nodeDate(node.createdAt,!!node.history)}`;
      button.append(title,subtitle); button.addEventListener('click', () => { focusNode(node.id); $('search-results').hidden = true; openSession(node.id); });
      $('search-result-list').append(button);
    }
  }
  function focusNode(id) {
    const node = nodeFor(id); if (!node) return;
    view.x = window.innerWidth / 2 - (node.x + 129) * view.scale;
    view.y = window.innerHeight / 2 - (node.y + 77) * view.scale;
    viewGeneration++; renderGraph(); applyView(); scheduleLayout();
  }
  function renderNodes() {
    const previous = new Map([...$('nodes').children].map(el => [el.dataset.id, el]));
    for (const node of graph.nodes) {
      let element = previous.get(node.id);
      if (!element) {
        element = document.createElement('article'); element.className = 'session-node'; element.dataset.id = node.id;
        element.innerHTML = '<button class="node-open-hit" type="button"></button><span class="node-port in"></span><span class="node-port out"></span><div class="node-head"><span class="runtime-badge"></span><button class="node-menu-button" type="button" aria-haspopup="true">···</button></div><h2 class="node-title"></h2><div class="node-foot"><span class="node-availability"><span class="status-dot"></span><span class="availability-text"></span></span><span class="node-time"></span></div>';
        element.addEventListener('pointerdown', event => startNodeDrag(event, node.id));
        element.addEventListener('click', event => {
          if (event.target.closest('.node-menu-button') || Number(element.dataset.suppressUntil || 0) > Date.now()) return;
          openSession(node.id);
        });
        const menuButton = element.querySelector('.node-menu-button');
        menuButton.addEventListener('click', event => { event.stopPropagation(); showMenu(node.id, menuButton); });
        $('nodes').append(element);
      }
      previous.delete(node.id);
      const key = JSON.stringify([node, locale, state.selectedId, runtimeKey]);
      if (element._key === key) continue;
      element._key = key;
      element.style.left = `${node.x}px`; element.style.top = `${node.y}px`;
      element.classList.toggle('selected', node.id === state.selectedId);
      element.classList.toggle('unavailable', !node.history && node.available === false);
      element.classList.toggle('historical', !!node.history);
      element.querySelector('.node-open-hit').setAttribute('aria-label', `${node.title} · ${runtimeName(node)} · ${availability(node)}`);
      element.querySelector('.runtime-badge').className = `runtime-badge ${node.runtime}`;
      text(element.querySelector('.runtime-badge'), runtimeName(node));
      text(element.querySelector('.node-title'), node.title || t('session'));
      text(element.querySelector('.availability-text'), availability(node));
      element.querySelector('.status-dot').className = `status-dot ${node.available === true ? 'connected' : ''}`;
      text(element.querySelector('.node-time'), nodeDate(node.createdAt, !!node.history));
      element.querySelector('.node-menu-button').setAttribute('aria-label', `${t('sessionActions')}: ${node.title}`);
    }
    previous.forEach(element => element.remove());
    $('empty').hidden = !!state.nodes.length;
  }
  function svg(name, attributes) {
    const element = document.createElementNS('http://www.w3.org/2000/svg', name);
    Object.entries(attributes).forEach(([key, value]) => element.setAttribute(key, value)); return element;
  }
  function renderEdges() {
    const key = JSON.stringify([graph.edges.map(edge => [edge, nodeFor(edge.source)?.x,nodeFor(edge.source)?.y,nodeFor(edge.target)?.x,nodeFor(edge.target)?.y]), state.selectedId, historyID, locale]);
    if (key === edgeKey) return; edgeKey = key;
    $('edges').replaceChildren();
    for (const edge of graph.edges) {
      const source = nodeFor(edge.source), target = nodeFor(edge.target);
      if (!source || !target) continue;
      const sx = source.x + 258, sy = source.y + 77, tx = target.x, ty = target.y + 77;
      let path, labelX, labelY;
      if (tx > sx) {
        const bend = Math.min(180, (tx - sx) * .42);
        path = `M${sx} ${sy} C${sx + bend} ${sy} ${tx - bend} ${ty} ${tx} ${ty}`;
        labelX = (sx + tx) / 2; labelY = (sy + ty) / 2 - 10;
      } else {
        const bottom = Math.max(source.y, target.y) + 200;
        path = `M${sx} ${sy} C${sx + 42} ${sy} ${sx + 42} ${bottom} ${sx + 10} ${bottom} L${tx - 10} ${bottom} C${tx - 42} ${bottom} ${tx - 42} ${ty} ${tx} ${ty}`;
        labelX = (sx + tx) / 2; labelY = bottom - 10;
      }
      const active = [state.selectedId,historyID].includes(source.id) || [state.selectedId,historyID].includes(target.id);
      $('edges').append(svg('path', {d: path, class: `connection-path ${edge.kind}${edge.kind === 'linked' ? ' manual' : ''}${active ? ' emphasis' : ''}`}));
      const label = svg('text', {x: labelX, y: labelY, 'text-anchor': 'middle', class: 'edge-label'});
      label.textContent = t(edge.kind === 'created_from' ? 'createdFrom' : edge.kind);
      const group = svg('g', {}); group.append(label); $('edges').append(group);
      $('edges').append(svg('path', {d: `M${tx - 7} ${ty - 4} L${tx} ${ty} L${tx - 7} ${ty + 4}`, fill: 'none', stroke: active ? '#6b835b' : '#adb5a1', 'stroke-width': 1.5}));
    }
  }
  function renderRuntimes() {
    const key = JSON.stringify([state.runtimes, locale]);
    if (runtimeKey === key) return; runtimeKey = key;
    const current = $('session-runtime').value; $('session-runtime').replaceChildren();
    for (const runtime of state.runtimes) {
      if (!['shell', 'python', 'codex', 'claude'].includes(runtime.id)) continue;
      const option = document.createElement('option'); option.value = runtime.id;
      option.textContent = runtime.label + (runtime.available ? '' : ` · ${t('notInstalled')}`); option.disabled = !runtime.available;
      $('session-runtime').append(option);
    }
    if ([...$('session-runtime').options].some(option => option.value === current && !option.disabled)) $('session-runtime').value = current;
    runtimeHelp();
  }
  const accept = bridge.createStateReceiver(next => {
    const oldLocale = locale; locale = messages.localeFor(next.locale || navigator.language);
    if (locale !== oldLocale) { localize(); runtimeKey = ''; }
    state = {...next, nodes: next.nodes.map(node => ({...node, ...(positions.get(node.id) || {})}))};
    nodeIndex = new Map(state.nodes.map(node => [node.id,node]));
    if (drag?.nodeId) { const node = nodeFor(drag.nodeId); if (node) Object.assign(node, drag.position); }
    if (!drag && viewGeneration === savedViewGeneration) view = {...next.viewport};
    text($('workspace-title'), next.workspace.title || t('canvas'));
    renderRuntimes(); renderGraph(); renderSearch(); applyView(); connection();
    $('history-tools').hidden = !state.nodes.some(node => node.history);
    if (historyID && $('history-dialog').open) renderHistory();
    if (state.terminalOpen) $('history-dialog').close();
    canvas.inert = state.terminalOpen; $('toolbar').inert = state.terminalOpen;
    document.body.classList.toggle('terminal-open', state.terminalOpen);
    if (terminalWasOpen && !state.terminalOpen) {
      const selected = [...$('nodes').children].find(node => node.dataset.id === state.selectedId);
      (selected?.querySelector('.node-open-hit') || canvas).focus({preventScroll: true});
    }
    terminalWasOpen = state.terminalOpen;
    if (menuID && !nodeFor(menuID)) hideMenu();
  });
  function receive(raw) { try { return accept(raw); } catch (error) { connection(error); throw error; } }
  async function refresh() {
    if (refreshBusy) return; refreshBusy = true;
    try { receive(await client.send('canvas.snapshot')); }
    catch (error) { connection(error); }
    finally { refreshBusy = false; }
  }
  async function openSession(id, refocus = false) {
    if (drag || (state?.terminalOpen && !refocus)) return;
    hideMenu();
    if (nodeFor(id)?.history && !refocus) { showHistory(id); return; }
    try { receive(await client.send('session.open', {id})); }
    catch (error) { notify(errorMessage(error)); }
  }
  function fullDate(value) {
    const date = new Date(value);
    return !value || Number.isNaN(date.valueOf()) ? t('unknownDate') : date.toLocaleString(locale, {dateStyle:'medium',timeStyle:'short'});
  }
  function metadataRow(list, label, value, wide = false) {
    const row = document.createElement('div'); if (wide) row.className = 'wide';
    const term = document.createElement('dt'); term.textContent = label;
    const detail = document.createElement('dd'); detail.textContent = value;
    row.append(term,detail); list.append(row);
  }
  function renderHistory() {
    const node = nodeFor(historyID); if (!node?.history) { $('history-dialog').close(); return; }
    const history = node.history, metadata = $('history-metadata'); metadata.replaceChildren();
    text($('history-title'), node.title); text($('history-eyebrow'), `${t('history')} · ${roleName(history.role)}`);
    metadataRow(metadata,t('runtimeConfig'),history.runtimeConfig || runtimeName(node));
    metadataRow(metadata,t('recordedStatus'),history.status || t('statusUnknown'));
    metadataRow(metadata,t('originalCreated'),fullDate(node.createdAt));
    metadataRow(metadata,t('updated'),fullDate(history.updatedAt));
    metadataRow(metadata,t('source'),history.source);
    metadataRow(metadata,t('originalSession'),history.sessionId);
    if (history.cwd) metadataRow(metadata,t('workingDirectory'),history.cwd,true);
    text($('history-summary'),history.summary || t('noSummary'));
    const evidence = $('history-evidence'); evidence.replaceChildren();
    if (history.references?.length) {
      for (const reference of history.references) metadataRow(evidence,reference.label,reference.value);
    } else { const missing = document.createElement('p'); missing.className='field-hint'; missing.textContent=t('noEvidence'); evidence.append(missing); }
    const lineage = $('history-lineage'); lineage.replaceChildren();
    const relationships = state.edges.filter(edge => edge.source === node.id || edge.target === node.id);
    if (!relationships.length) { const missing = document.createElement('p'); missing.className='field-hint'; missing.textContent=t('noLineage'); lineage.append(missing); }
    for (const edge of relationships) {
      const incoming = edge.target === node.id, otherID = incoming ? edge.source : edge.target, other = nodeFor(otherID);
      const row = document.createElement('div'); row.className='lineage-row';
      const button = document.createElement('button'); button.type='button';
      button.textContent=`${t(incoming ? 'from' : 'to')} ${other.title} · ${t(edge.kind === 'created_from' ? 'createdFrom' : edge.kind)}`;
      button.addEventListener('click',() => {
        $('history-search').value=''; $('include-workers').checked=true; focusNode(otherID); renderSearch();
        if (other.history) { historyID=otherID; renderHistory(); } else { $('history-dialog').close(); openSession(otherID); }
      });
      row.append(button);
      if (edge.evidence) { const proof = document.createElement('p'); proof.textContent=edge.evidence; row.append(proof); }
      lineage.append(row);
    }
    $('history-resume').disabled=resumeBusy || !(node.available || node.canResume);
    text($('history-resume'),t(resumeBusy ? 'resuming' : node.available ? 'openTerminal' : 'resume'));
    text($('history-resume-hint'),node.available || node.canResume ? t('historicalHint') : node.resumeUnavailableReason || t('resumeUnavailable'));
  }
  function showHistory(id) {
    historyID=id; renderHistory(); $('search-results').hidden=true;
    if (!$('history-dialog').open) $('history-dialog').showModal();
    renderEdges();
  }
  $('history-resume').addEventListener('click',async () => {
    const node=nodeFor(historyID); if (!node || resumeBusy || !(node.available || node.canResume)) return;
    resumeBusy=true; $('history-dialog').close();
    try { receive(await client.send(node.available ? 'session.open' : 'session.resume',{id:node.id})); }
    catch(error) { showHistory(node.id); notify(errorMessage(error)); }
    finally { resumeBusy=false; if ($('history-dialog').open) renderHistory(); }
  });
  $('history-dialog').addEventListener('close',() => { if (!resumeBusy && !$('history-dialog').open) historyID=null; if (state) renderEdges(); });
  $('history-search').addEventListener('input',() => { hideMenu(); renderGraph(); renderSearch(); });
  $('history-search').addEventListener('focus',renderSearch);
  $('include-workers').addEventListener('change',() => { hideMenu(); renderGraph(); renderSearch(); });
  window.addEventListener('resize',() => { if (state) renderGraph(); });
  function hideMenu() { $('node-menu').hidden = true; menuID = null; }
  function showMenu(id, button) {
    menuID = id; const rect = button.getBoundingClientRect(), menu = $('node-menu');
    menu.hidden = false;
    menu.style.left = `${Math.max(12, Math.min(window.innerWidth - menu.offsetWidth - 12, rect.left))}px`;
    menu.style.top = `${Math.max(12, Math.min(window.innerHeight - menu.offsetHeight - 12, rect.bottom + 6))}px`;
    $('menu-link').focus();
  }
  function openCreate() {
    hideMenu(); client.resetCreate(); $('create-form').reset(); formError('create-error');
    text($('create-title'), t('createTitle'));
    text($('create-context'), t('createBody'));
    runtimeHelp(); $('create-dialog').showModal(); $('session-title').focus();
  }
  function runtimeHelp() {
    const value = $('session-runtime').value;
    text($('runtime-help'), value === 'python' ? t('pythonHelp') : ['codex', 'claude'].includes(value) ? t('cliHelp') : '');
  }
  function busyCreate(busy) {
    createBusy = busy; $('create-form').querySelectorAll('button,input,select').forEach(element => { element.disabled = busy; });
    if (!busy) renderRuntimes(); text($('create-submit'), t(busy ? 'creating' : 'createSession'));
  }
  $('create-form').addEventListener('submit', async event => {
    event.preventDefault(); if (createBusy) return;
    const params = {title: $('session-title').value.trim(), runtime: $('session-runtime').value};
    if (!params.title || !$('session-runtime').selectedOptions[0] || $('session-runtime').selectedOptions[0].disabled) return;
    busyCreate(true); formError('create-error');
    try {
      const result = await client.create(params); receive(result.snapshot);
      $('history-search').value=''; renderGraph(); renderSearch(); focusNode(result.nodeId);
      $('create-dialog').close(); client.resetCreate(); notify(t('created'));
      // Closing the web dialog may change focus; make the native terminal the final owner.
      await openSession(result.nodeId, true);
    } catch (error) { formError('create-error', errorMessage(error)); }
    finally { busyCreate(false); }
  });
  $('create-dialog').addEventListener('cancel', event => { if (createBusy) event.preventDefault(); });
  $('session-runtime').addEventListener('change', runtimeHelp);
  function openLink(id) {
    hideMenu(); linkSource = id; const targets = state.nodes.filter(node => node.id !== id);
    if (!targets.length) { notify(t('needAnother')); return; }
    text($('link-context'), nodeFor(id)?.title || t('session')); formError('link-error'); $('link-target').replaceChildren();
    for (const node of targets) { const option = document.createElement('option'); option.value = node.id; option.textContent = node.title || t('session'); $('link-target').append(option); }
    $('link-dialog').showModal(); $('link-target').focus();
  }
  $('link-form').addEventListener('submit', async event => {
    event.preventDefault(); if ($('link-submit').disabled) return; $('link-submit').disabled = true; formError('link-error');
    try { receive(await client.send('canvas.link', {source: linkSource, target: $('link-target').value})); $('link-dialog').close(); }
    catch (error) { formError('link-error', errorMessage(error)); }
    finally { $('link-submit').disabled = false; }
  });
  $('menu-link').addEventListener('click', () => openLink(menuID));
  $('create-button').addEventListener('click', () => openCreate()); $('empty-create').addEventListener('click', () => openCreate());
  $('retry-button').addEventListener('click', () => { refresh().then(() => saveLayout()); });
  document.querySelectorAll('[data-close]').forEach(button => button.addEventListener('click', () => $(button.dataset.close).close()));
  document.addEventListener('pointerdown', event => { if (!event.target.closest('#node-menu,.node-menu-button')) hideMenu(); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && !$('node-menu').hidden) { const id = menuID; hideMenu(); [...$('nodes').children].find(node => node.dataset.id === id)?.querySelector('.node-menu-button').focus(); } });
  function startNodeDrag(event, id) {
    if (event.button !== 0 || event.target.closest('.node-menu-button') || state?.terminalOpen) return;
    const node = nodeFor(id); if (!node) return;
    event.preventDefault(); event.stopPropagation(); hideMenu();
    drag = {pointerID: event.pointerId, nodeId: id, x: event.clientX, y: event.clientY, originX: node.x, originY: node.y, position: {x: node.x, y: node.y}, moved: false, element: event.currentTarget};
    event.currentTarget.setPointerCapture(event.pointerId);
  }
  canvas.addEventListener('pointerdown', event => {
    if (event.button !== 0 || event.target.closest('.session-node,button') || state?.terminalOpen) return;
    hideMenu(); canvas.focus({preventScroll: true});
    drag = {pointerID: event.pointerId, x: event.clientX, y: event.clientY, originX: view.x, originY: view.y, moved: false};
    canvas.setPointerCapture(event.pointerId); canvas.classList.add('dragging');
  });
  window.addEventListener('pointermove', event => {
    if (!drag || drag.pointerID !== event.pointerId) return;
    const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
    if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true;
    if (!drag.moved) return;
    if (drag.nodeId) {
      const node = nodeFor(drag.nodeId); if (!node) return;
      node.x = drag.originX + dx / view.scale; node.y = drag.originY + dy / view.scale;
      drag.position = {x: node.x, y: node.y}; drag.element.style.left = `${node.x}px`; drag.element.style.top = `${node.y}px`; drag.element.classList.add('dragging'); renderEdges();
    } else { view.x = drag.originX + dx; view.y = drag.originY + dy; viewGeneration++; applyView(); }
  });
  function endDrag(event) {
    if (!drag || drag.pointerID !== event.pointerId) return;
    if (drag.nodeId) {
      drag.element.classList.remove('dragging');
      if (drag.moved) { drag.element.dataset.suppressUntil = Date.now() + 350; positions.set(drag.nodeId, {...drag.position}); scheduleLayout(); }
    } else if (drag.moved) scheduleLayout();
    drag = null; canvas.classList.remove('dragging');
  }
  window.addEventListener('pointerup', endDrag); window.addEventListener('pointercancel', endDrag);
  canvas.addEventListener('wheel', event => {
    if (!state || state.terminalOpen || document.querySelector('dialog[open]')) return;
    event.preventDefault(); hideMenu();
    if (event.ctrlKey) view = bridge.zoom(view, event.clientX, event.clientY, view.scale * Math.exp(-event.deltaY * .0025));
    else { const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.innerHeight : 1; view.x -= event.deltaX * unit; view.y -= event.deltaY * unit; }
    viewGeneration++; applyView(); scheduleLayout();
  }, {passive: false});
  window.addEventListener('omg:state', event => { try { receive(event.detail); } catch (_) {} });
  localize(); applyView(); $('create-button').disabled = true; $('empty-create').disabled = true; refresh();
})();
