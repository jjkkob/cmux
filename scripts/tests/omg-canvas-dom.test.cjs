'use strict';
// Execute the shipped HTML and scripts in a real browser. Only the native transport is substituted.
// Requires Playwright; OMG_CANVAS_BROWSER may point at an installed Chromium executable.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {chromium} = require(process.env.OMG_CANVAS_PLAYWRIGHT || 'playwright');
const resources = path.resolve(__dirname, '../../Resources/omg-canvas');
const fixture = require(path.join(resources, 'bridge-fixture.json'));

async function canvas(t) {
  const browser = await chromium.launch({headless: true, ...(process.env.OMG_CANVAS_BROWSER ? {executablePath: process.env.OMG_CANVAS_BROWSER} : {})});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport: {width: 1000, height: 700}});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(snapshot => {
    window.canvasRequests = [];
    window.webkit = {messageHandlers: {omgCanvas: {postMessage: async request => {
      window.canvasRequests.push(request);
      if (request.method !== 'canvas.snapshot') throw new Error('Unexpected mutation during canvas startup');
      return {ok: true, value: snapshot};
    }}}};
  }, fixture.beforeCreateSnapshot);
  await page.goto(pathToFileURL(path.join(resources, 'index.html')).href);
  // Snapshot transport and its render callback finish before the next browser frame.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  return {page, errors};
}

test('shipped canvas mounts a native snapshot and opens an enabled new-chat form', async t => {
  const {page, errors} = await canvas(t);
  assert.deepEqual(errors, [], 'The shipped HTML/scripts must initialize without an uncaught DOM error');
  assert.equal(await page.locator('#connection-error').isVisible(), false);
  assert.equal(await page.getByRole('button', {name: 'New chat', exact: true}).isEnabled(), true);
  assert.equal(await page.locator('.session-node').count(), fixture.beforeCreateSnapshot.nodes.length);
  await page.getByRole('button', {name: 'New chat', exact: true}).click();
  assert.equal(await page.getByRole('dialog').isVisible(), true);
  assert.equal(await page.getByRole('textbox', {name: 'Name', exact: true}).isEnabled(), true);
  const runtimes = await page.getByRole('combobox', {name: 'Run', exact: true}).locator('option').evaluateAll(options => options.filter(option => !option.disabled).map(option => option.value));
  assert.ok(runtimes.includes('codex'));
  assert.ok(runtimes.includes('claude'));
  assert.equal(await page.getByRole('button', {name: 'Create session', exact: true}).isEnabled(), true);
  assert.deepEqual(await page.evaluate(() => window.canvasRequests.map(request => request.method)), ['canvas.snapshot']);
  assert.deepEqual(errors, []);
});
