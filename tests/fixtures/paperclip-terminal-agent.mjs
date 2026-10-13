#!/usr/bin/env node
// JSON-lines ACP transport stimulus. No provider, model, tool emulation or auth minting.
import readline from 'node:readline';
import {randomUUID} from 'node:crypto';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
import {readFileSync} from 'node:fs';
import path from 'node:path';
const filename = fileURLToPath(import.meta.url);
const directory = path.dirname(filename);
const consumer = fileURLToPath(new URL('./paperclip-terminal-consumer.mjs', import.meta.url));
const providerChild = process.argv.includes('--provider-child');
const library = providerChild ? 'acpx@0.13.1' : 'acpx@0.12.0';
const pending = new Map();
let sequence = 0;
const send = message => process.stdout.write(`${JSON.stringify({jsonrpc: '2.0', ...message})}\n`);
function update(sessionId, marker, value) {
  send({method: 'session/update', params: {sessionId, update: {sessionUpdate: 'agent_message_chunk',
    content: {type: 'text', text: `${marker} ${JSON.stringify(value)}\n`}}}});
}
function call(method, params) {
  const id = `terminal-fixture-${++sequence}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('callback timeout')); }, 30000);
    pending.set(id, {resolve, reject, timer});
    send({id, method, params});
  });
}
async function providerPackReports(sessionId) {
  const report = {library: 'acpx@0.13.1', stage: 'provider-module-resolution', mode: null, terminalExitCode: null};
  let runtime;
  let handle;
  let text = '';
  const records = new Map();
  const inheritedSecret = Object.hasOwn(process.env, 'BETTER_AUTH_SECRET');
  const previousSecret = process.env.BETTER_AUTH_SECRET;
  try {
    const requireProvider = createRequire('/opt/paperclip-runner/provider-pack/package.json');
    const manifest = JSON.parse(readFileSync(requireProvider.resolve('acpx/package.json'), 'utf8'));
    if (manifest.version !== '0.13.1') throw new Error('unexpected provider SDK');
    // Use the same public runtime API as the actual provider pack. There is no
    // public acpx/client export; no opaque chunk name or export alias is used.
    const resolved = requireProvider.resolve('acpx/runtime');
    const {createAcpRuntime, createAgentRegistry} = await import(pathToFileURL(resolved).href);
    const safeEnvironment = {...process.env};
    if (Object.hasOwn(safeEnvironment, 'BETTER_AUTH_SECRET') || Object.hasOwn(safeEnvironment, 'PAPERCLIP_AGENT_JWT_SECRET')) {
      report.stage = 'provider-run-environment-isolation';
      throw new Error('unsafe outer run environment');
    }
    // Only this owned fixture process gets a harmless host-only marker AFTER
    // taking its genuine run environment snapshot. No signer/key is minted.
    process.env.BETTER_AUTH_SECRET = 'test-host-only';
    runtime = createAcpRuntime({
      cwd: directory, permissionMode: 'approve-all', nonInteractivePermissions: 'deny', timeoutMs: 60000,
      agentRegistry: createAgentRegistry({overrides: {fixture: ['node', filename, '--provider-child']}}),
      // The real SDK uses this store, but it never leaves this fixture process.
      // Authority is supplied only by the ephemeral factory, not sessionOptions
      // or persisted record fields, so no session save contains the run JWT.
      sessionStore: {
        async load(id) { return records.has(id) ? structuredClone(records.get(id)) : undefined; },
        async save(record) { records.set(record.acpxRecordId, structuredClone(record)); },
      },
      spawnEnvironment: () => ({...safeEnvironment}),
      onSessionNotification: notification => {
        const message = notification.update;
        if (message.sessionUpdate === 'agent_message_chunk' && message.content.type === 'text') text += message.content.text;
      },
    });
    report.stage = 'provider-session-create';
    handle = await runtime.ensureSession({sessionKey: `opc-terminal-${randomUUID()}`, agent: 'fixture',
      mode: 'oneshot', cwd: directory});
    report.stage = 'provider-real-terminal-prompt';
    const turn = runtime.startTurn({handle, text: 'Run only the deterministic terminal authentication fixture.',
      mode: 'prompt', requestId: randomUUID(), timeoutMs: 60000});
    // Drain actual SDK events; success requires the genuine turn result and
    // reports emitted only after real terminal callback HTTP authentication.
    for await (const event of turn.events) {
      if (event.type === 'error') report.stage = 'provider-real-terminal-prompt';
    }
    const result = await turn.result;
    if (result.status !== 'completed') throw new Error('provider turn failed');
    report.stage = 'provider-authenticated-report';
    const match = text.match(/OPC_TERMINAL_REPORT (\[[^\n]*\])/);
    if (!match) throw new Error('provider report absent');
    return JSON.parse(match[1]);
  } catch {
    // Forward only fixture-owned fixed diagnostics, never SDK errors/output.
    for (const match of text.matchAll(/OPC_TERMINAL_FAILURE (\{[^\n]*\})/g)) {
      try { update(sessionId, 'OPC_TERMINAL_FAILURE', JSON.parse(match[1])); } catch { /* Malformed diagnostics are not evidence. */ }
    }
    update(sessionId, 'OPC_TERMINAL_FAILURE', report);
    throw new Error('provider real terminal fixture failed');
  } finally {
    try {
      if (runtime && handle) await runtime.close({handle, reason: 'fixture-complete'});
    } catch {
      update(sessionId, 'OPC_TERMINAL_FAILURE', {...report, stage: 'provider-runtime-close'});
      throw new Error('provider fixture runtime cleanup failed');
    } finally {
      records.clear();
      if (inheritedSecret) process.env.BETTER_AUTH_SECRET = previousSecret;
      else delete process.env.BETTER_AUTH_SECRET;
    }
  }
}
async function prompt(params) {
  const reports = [];
  let diagnostic = {library, mode: null, stage: 'terminal-create', terminalExitCode: null};
  try {
    // The final absent-env call catches mutation of the base by the overlay.
    for (const mode of ['default', 'override', 'default-after-override']) {
      diagnostic = {library, mode, stage: 'terminal-create', terminalExitCode: null};
      const request = {sessionId: params.sessionId, command: 'node', args: [consumer, mode,
        process.env.PAPERCLIP_AGENT_ID, process.env.PAPERCLIP_COMPANY_ID, process.env.PAPERCLIP_RUN_ID,
        new URL(process.env.PAPERCLIP_API_URL).origin, library], outputByteLimit: 8192};
      if (mode === 'override') request.env = [
        {name: 'PAPERCLIP_API_URL', value: 'http://paperclip:3100'},
        {name: 'OPC_TERMINAL_BLANK', value: ''},
      ];
      const {terminalId} = await call('terminal/create', request);
      let output;
      try {
        diagnostic.stage = 'terminal-wait';
        const exit = await call('terminal/wait_for_exit', {sessionId: params.sessionId, terminalId});
        diagnostic.terminalExitCode = exit.exitCode;
        diagnostic.stage = 'terminal-output';
        output = await call('terminal/output', {sessionId: params.sessionId, terminalId});
        diagnostic.stage = 'consumer-result';
        let result;
        try { result = JSON.parse(output.output.trim()); } catch { /* Never preserve arbitrary terminal output. */ }
        if (result?.type === 'opc_terminal_failure') {
          diagnostic.consumerStage = result.stage;
          diagnostic.httpStatus = result.httpStatus;
        }
        if (exit.exitCode !== 0 || output.truncated) throw new Error('terminal failed');
      } finally {
        await call('terminal/release', {sessionId: params.sessionId, terminalId});
      }
      const report = JSON.parse(output.output.trim());
      if (report.type !== 'opc_terminal_authority' || report.mode !== mode || report.library !== library) {
        throw new Error('missing authenticated result');
      }
      reports.push(report);
    }
    if (!providerChild) reports.push(...await providerPackReports(params.sessionId));
    update(params.sessionId, 'OPC_TERMINAL_REPORT', reports);
    return {stopReason: 'end_turn'};
  } catch {
    update(params.sessionId, 'OPC_TERMINAL_FAILURE', diagnostic);
    throw new Error('real terminal authentication or isolation failed');
  }
}
async function handle(message) {
  if (!message.method) {
    const waiter = pending.get(message.id);
    if (waiter) {
      clearTimeout(waiter.timer); pending.delete(message.id);
      if (message.error) waiter.reject(new Error('callback rejected')); else waiter.resolve(message.result);
    }
    return;
  }
  if (message.id === undefined) return;
  try {
    let result;
    switch (message.method) {
      case 'initialize': result = {protocolVersion: 1, agentCapabilities: {loadSession: false}, authMethods: [],
        agentInfo: {name: 'opc-terminal-fixture', version: '1'}}; break;
      case 'session/new': result = {sessionId: randomUUID()}; break;
      case 'session/prompt': result = await prompt(message.params); break;
      case 'session/set_mode': case 'session/set_model': result = {}; break;
      default: send({id: message.id, error: {code: -32601, message: 'Unsupported fixture method'}}); return;
    }
    send({id: message.id, result});
  } catch {
    send({id: message.id, error: {code: -32603, message: 'Real terminal authentication or isolation failed'}});
  }
}
const lines = readline.createInterface({input: process.stdin, crlfDelay: Infinity});
lines.on('line', line => {
  try { void handle(JSON.parse(line)); } catch { process.exitCode = 1; lines.close(); }
});
