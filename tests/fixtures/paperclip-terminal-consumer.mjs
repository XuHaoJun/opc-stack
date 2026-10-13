#!/usr/bin/env node
// This process is spawned by acpx's real terminal callback, never by the driver.
import assert from 'node:assert/strict';
const [mode, agentId, companyId, runId, canonicalOrigin, library] = process.argv.slice(2);
let stage = 'server-authority-isolation';
let httpStatus = null;
try {
  for (const key of ['BETTER_AUTH_SECRET', 'PAPERCLIP_AGENT_JWT_SECRET']) {
    assert.equal(Object.hasOwn(process.env, key), false, 'server authority leaked');
  }
  stage = 'run-key-present';
  assert.ok(process.env.PAPERCLIP_API_KEY, 'run authority missing');
  stage = 'run-environment-identities';
  assert.equal(process.env.PAPERCLIP_AGENT_ID, agentId, 'agent environment mismatch');
  assert.equal(process.env.PAPERCLIP_COMPANY_ID, companyId, 'company environment mismatch');
  assert.equal(process.env.PAPERCLIP_RUN_ID, runId, 'run environment mismatch');
  stage = 'jwt-identities';
  const parts = process.env.PAPERCLIP_API_KEY.split('.');
  assert.equal(parts.length, 3, 'not a run JWT');
  const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  assert.equal(claims.sub, agentId, 'JWT actor mismatch');
  assert.equal(claims.company_id, companyId, 'JWT company mismatch');
  assert.equal(claims.run_id, runId, 'JWT run mismatch');
  assert.equal(claims.adapter_type, 'claude_local', 'JWT adapter mismatch');
  stage = 'request-environment-overlay';
  const base = new URL(process.env.PAPERCLIP_API_URL);
  assert.ok([canonicalOrigin, 'http://paperclip:3100'].includes(base.origin), 'unexpected API origin refused');
  if (mode === 'override') {
    assert.equal(base.origin, 'http://paperclip:3100', 'request overlay missing');
    assert.equal(process.env.OPC_TERMINAL_BLANK, '', 'blank overlay not preserved');
  } else {
    assert.equal(process.env.OPC_TERMINAL_BLANK, 'base', 'base environment mutated');
  }
  stage = 'real-api-request';
  const response = await fetch(new URL('/api/agents/me', base), {
    headers: {Authorization: `Bearer ${process.env.PAPERCLIP_API_KEY}`, 'X-Paperclip-Run-Id': runId},
    signal: AbortSignal.timeout(15000),
  });
  httpStatus = response.status;
  stage = 'real-api-authentication';
  assert.equal(response.status, 200, 'real API rejected run authority');
  const actor = await response.json();
  stage = 'real-api-actor';
  assert.equal(actor.id, agentId, 'real API actor mismatch');
  assert.equal(actor.companyId, companyId, 'real API company mismatch');
  console.log(JSON.stringify({type: 'opc_terminal_authority', library, mode, agentId, companyId, runId,
    httpStatus: response.status, jwtClaimsMatch: true, serverAuthorityAbsent: true}));
} catch {
  // Never serialize an exception carrying a URL, response, environment or JWT.
  console.error(JSON.stringify({type: 'opc_terminal_failure', library, mode, stage, httpStatus,
    reason: 'terminal authentication or isolation assertion failed'}));
  process.exitCode = 1;
}
