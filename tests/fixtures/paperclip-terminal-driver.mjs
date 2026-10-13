#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, realpathSync, existsSync, unlinkSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const directory = fileURLToPath(new URL('.', import.meta.url));
const marker = `opc-terminal-authority-${randomUUID()}`;
const base = 'http://127.0.0.1:3100/api';
const key = readFileSync('/paperclip/.opc/board-api.key', 'utf8').trim();
const evidence = {marker, agentId: null, companyId: null, runs: [], cleanup: {}};
const evidencePath = `${directory}evidence.json`;
let failed = false;
let cleanupStarted = false;
let interrupted = false;
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { interrupted = true; });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const save = () => writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, {mode: 0o600});
async function api(method, path, body, allowed = [200, 201, 202]) {
  const response = await fetch(`${base}${path}`, {method,
    headers: {Authorization: `Bearer ${key}`, 'Content-Type': 'application/json'},
    ...(body === undefined ? {} : {body: JSON.stringify(body)}), signal: AbortSignal.timeout(20000)});
  if (!allowed.includes(response.status)) throw new Error(`API ${method} ${path} HTTP ${response.status}`);
  if (response.status === 204 || response.status === 404) return null;
  return response.json();
}
function sql(statement) {
  const env = {...process.env};
  if (env.DATABASE_URL) {
    const url = new URL(env.DATABASE_URL);
    assert.ok(['postgres:', 'postgresql:'].includes(url.protocol), 'unsupported database URL');
    Object.assign(env, {PGHOST: url.hostname, PGPORT: url.port || '5432',
      PGUSER: decodeURIComponent(url.username), PGPASSWORD: decodeURIComponent(url.password),
      PGDATABASE: decodeURIComponent(url.pathname.slice(1))});
    if (url.searchParams.has('sslmode')) env.PGSSLMODE = url.searchParams.get('sslmode');
  } else {
    Object.assign(env, {PGHOST: env.PAPERCLIP_DB_HOST || '127.0.0.1', PGPORT: env.PAPERCLIP_DB_PORT || '54329',
      PGUSER: env.PAPERCLIP_DB_USER || 'paperclip', PGDATABASE: env.PAPERCLIP_DB_NAME || 'paperclip',
      PGPASSWORD: env.PAPERCLIP_DB_PASSWORD || 'paperclip'});
  }
  const result = spawnSync('psql', ['-X', '-v', 'ON_ERROR_STOP=1', '-At', '-c', statement], {env, encoding: 'utf8'});
  if (result.status !== 0) throw new Error('Owned zero-cost accounting cleanup failed');
  return result.stdout.trim();
}
async function cleanup() {
  if (cleanupStarted) return;
  cleanupStarted = true;
  if (!evidence.agentId) { save(); return; }
  const actor = await api('GET', `/agents/${evidence.agentId}`, undefined, [200, 404]);
  if (!actor) { evidence.cleanup.alreadyAbsent = true; save(); return; }
  assert.equal(actor.name, marker, 'cleanup ownership mismatch');
  assert.equal(actor.metadata?.opcTerminalAuthorityTest, marker, 'cleanup marker mismatch');
  // Only settled owned runs are eligible. A timed-out active run must first drain.
  for (const entry of evidence.runs) {
    let settled = false;
    for (let i = 0; i < 120; i++) {
      const run = await api('GET', `/heartbeat-runs/${entry.runId}`);
      if (!['queued', 'running'].includes(run.status)) { settled = true; break; }
      await sleep(1000);
    }
    assert.ok(settled, 'owned run did not settle; protected from deletion');
    const log = await api('GET', `/heartbeat-runs/${entry.runId}/log?offset=0&limitBytes=1`, undefined, [200, 404]);
    if (log) {
      assert.equal(log.logRef, `${evidence.companyId}/${evidence.agentId}/${entry.runId}.ndjson`, 'owned log reference mismatch');
      entry.logRef = log.logRef;
    }
  }
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  for (const id of [evidence.agentId, evidence.companyId, ...evidence.runs.map(r => r.runId)]) assert.match(id, uuid);
  await api('POST', `/agents/${evidence.agentId}/pause`, {});
  const runs = evidence.runs.map(r => `'${r.runId}'::uuid`).join(',');
  const owned = runs
    ? `company_id='${evidence.companyId}'::uuid AND agent_id='${evidence.agentId}'::uuid AND heartbeat_run_id IN (${runs})`
    : 'FALSE';
  // An unexpected run, NULL run reference or nonzero accounting is protected.
  const guard = `agent_id='${evidence.agentId}'::uuid AND (NOT COALESCE((${owned}),FALSE) OR cost_cents <> 0 OR COALESCE(input_tokens,0) <> 0 OR COALESCE(cached_input_tokens,0) <> 0 OR COALESCE(output_tokens,0) <> 0)`;
  sql(`BEGIN; LOCK TABLE cost_events IN SHARE ROW EXCLUSIVE MODE; DO $$ BEGIN IF EXISTS (SELECT 1 FROM cost_events WHERE ${guard}) THEN RAISE EXCEPTION 'protected fixture accounting'; END IF; END $$; DELETE FROM cost_events WHERE ${owned} AND cost_cents=0 AND COALESCE(input_tokens,0)=0 AND COALESCE(cached_input_tokens,0)=0 AND COALESCE(output_tokens,0)=0; COMMIT;`);
  evidence.cleanup.zeroCostRowsRemoved = true;
  await api('DELETE', `/agents/${evidence.agentId}`, undefined, [200, 204]);
  assert.equal(await api('GET', `/agents/${evidence.agentId}`, undefined, [404]), null);
  evidence.cleanup.agentDeleted = true;
  const logRoot = process.env.RUN_LOG_BASE_PATH || '/paperclip/instances/default/data/run-logs';
  for (const entry of evidence.runs.filter(r => r.logRef)) {
    const filename = path.resolve(logRoot, entry.logRef);
    if (!existsSync(filename)) continue;
    const root = realpathSync(logRoot);
    const actual = realpathSync(filename);
    assert.equal(actual, path.join(root, entry.logRef), 'owned log containment mismatch');
    unlinkSync(actual);
  }
  evidence.cleanup.ownedLogsRemoved = true;
  save();
}
async function runGate() {
  assert.ok(!process.env.RUN_LOG_S3_BUCKET, 'fixture requires local-only run logs (remote mirrors protected)');
  const companies = await api('GET', '/companies');
  const company = process.env.OPC_TERMINAL_COMPANY_ID
    ? companies.find(c => c.id === process.env.OPC_TERMINAL_COMPANY_ID)
    : companies.length === 1 ? companies[0] : null;
  assert.ok(company, 'set OPC_TERMINAL_COMPANY_ID when more than one company exists');
  evidence.companyId = company.id;
  const agent = await api('POST', `/companies/${company.id}/agents`, {
    name: marker, role: 'general', adapterType: 'claude_local',
    adapterConfig: {engine: 'acp', agentCommand: `node ${directory}paperclip-terminal-agent.mjs`,
      mode: 'oneshot', permissionMode: 'approve-all', nonInteractivePermissions: 'deny',
      timeoutSec: 90, stateDir: `${directory}acpx-state`,
      env: {OPC_TERMINAL_BLANK: {type: 'plain', value: 'base'}}},
    instructionsBundle: {files: {'AGENTS.md': 'Deterministic ACP terminal authority fixture. No model or production work.'}},
    runtimeConfig: {heartbeat: {enabled: false, intervalSec: 0, wakeOnDemand: true, maxConcurrentRuns: 1}},
    metadata: {opcTerminalAuthorityTest: marker},
  });
  evidence.agentId = agent.id; save();
  for (let index = 0; index < 2; index++) {
    const wake = await api('POST', `/agents/${agent.id}/wakeup`, {source: 'on_demand', triggerDetail: 'manual',
      reason: marker, forceFreshSession: true, idempotencyKey: `${marker}-${index}`, payload: {}});
    assert.ok(wake.id, 'wakeup returned no genuine run ID');
    const entry = {runId: wake.id, status: 'queued', reports: []};
    evidence.runs.push(entry); save();
    assert.equal(new Set(evidence.runs.map(r => r.runId)).size, evidence.runs.length, 'wake reused run');
    let run;
    for (let attempt = 0; attempt < 120; attempt++) {
      run = await api('GET', `/heartbeat-runs/${wake.id}`);
      if (!['queued', 'running'].includes(run.status)) break;
      await sleep(1000);
    }
    entry.status = run.status;
    entry.exitCode = Number.isInteger(run.exitCode) ? run.exitCode : null;
    const errorCode = run.errorCode ?? run.resultJson?.errorCode;
    entry.errorCode = typeof errorCode === 'string' && /^[a-z0-9_]{1,80}$/i.test(errorCode) ? errorCode : null;
    entry.fixtureError = ['Real terminal authentication or isolation failed', 'Unsupported fixture method']
      .find(message => typeof run.error === 'string' && run.error.includes(message)) ?? null;
    assert.equal(run.agentId, agent.id); assert.equal(run.companyId, company.id);
    const log = await api('GET', `/heartbeat-runs/${wake.id}/log?offset=0&limitBytes=400000`, undefined, [200, 404]);
    let chunks = '';
    if (log) {
      entry.logRef = log.logRef;
      const lines = log.content.split('\n').filter(Boolean).map(line => JSON.parse(line).chunk || '').join('').split('\n');
      for (const line of lines.filter(Boolean)) {
        let event;
        try { event = JSON.parse(line); } catch { continue; }
        if (event.type === 'acpx.text_delta' && event.channel === 'output' && typeof event.text === 'string') chunks += event.text;
      }
    }
    const safeStages = new Set(['server-authority-isolation', 'run-key-present', 'run-environment-identities',
      'jwt-identities', 'request-environment-overlay', 'real-api-request', 'real-api-authentication', 'real-api-actor',
      'terminal-create', 'terminal-wait', 'terminal-output', 'consumer-result', 'provider-module-resolution',
      'provider-run-environment-isolation', 'provider-client-start', 'provider-session-create',
      'provider-real-terminal-prompt', 'provider-authenticated-report', 'provider-runtime-close']);
    entry.fixtureFailures = [];
    for (const match of chunks.matchAll(/OPC_TERMINAL_FAILURE (\{[^\n]*\})/g)) {
      let diagnostic;
      try { diagnostic = JSON.parse(match[1]); } catch { continue; }
      entry.fixtureFailures.push({
        library: ['acpx@0.12.0', 'acpx@0.13.1'].includes(diagnostic.library) ? diagnostic.library : null,
        mode: ['default', 'override', 'default-after-override'].includes(diagnostic.mode) ? diagnostic.mode : null,
        stage: safeStages.has(diagnostic.stage) ? diagnostic.stage : null,
        consumerStage: safeStages.has(diagnostic.consumerStage) ? diagnostic.consumerStage : null,
        terminalExitCode: Number.isInteger(diagnostic.terminalExitCode) ? diagnostic.terminalExitCode : null,
        httpStatus: Number.isInteger(diagnostic.httpStatus) ? diagnostic.httpStatus : null,
      });
    }
    save();
    assert.equal(interrupted, false, 'interrupted; owned run settled before cleanup');
    assert.equal(run.status, 'succeeded', 'real terminal run failed (see safe evidence)');
    // ACP can split text across NDJSON chunks; only consume the provider's
    // marker after successful callbacks, then independently check real wake IDs.
    const match = chunks.match(/OPC_TERMINAL_REPORT (\[[^\n]*\])/);
    assert.ok(match, 'authenticated terminal report absent');
    const reports = JSON.parse(match[1]);
    assert.deepEqual(reports.map(r => [r.library, r.mode]), ['acpx@0.12.0', 'acpx@0.13.1'].flatMap(library =>
      ['default', 'override', 'default-after-override'].map(mode => [library, mode])));
    for (const report of reports) {
      assert.equal(report.type, 'opc_terminal_authority');
      assert.equal(report.agentId, agent.id); assert.equal(report.companyId, company.id);
      assert.equal(report.runId, wake.id); assert.equal(report.httpStatus, 200);
      assert.equal(report.jwtClaimsMatch, true); assert.equal(report.serverAuthorityAbsent, true);
    }
    entry.reports = reports; save();
    console.log(`PASS  genuine run ${index + 1}: acpx .12 + provider-pack .13 default/overlay/unchanged base; real HTTP actor/JWT/run match; signer absent`);
  }
}
try { await runGate(); }
catch (error) {
  failed = true;
  // Assertion messages are literal fixture diagnostics, never API response bodies.
  console.error(`FAIL  ${error.message.split('\n')[0]}`);
  evidence.failure = 'real ACP terminal authority gate failed'; save();
} finally {
  try { await cleanup(); console.log('PASS  owned agent, run and zero-cost accounting cleanup'); }
  catch { failed = true; evidence.cleanup.protected = true; save(); console.error('FAIL  cleanup protected owned artifacts; safe evidence retained for operator'); }
}
process.exitCode = failed ? 1 : 0;
