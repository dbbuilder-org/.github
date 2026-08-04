/**
 * Cloudflare Worker: GitHub <-> Linear status-sync forwarder
 *
 * Two independent routes, both ending in a repository_dispatch to
 * dbbuilder-org/.github so a GitHub Actions workflow does the actual write:
 *
 *  POST /            — projects_v2_item webhooks from the DBBuilder Workflow
 *                       GitHub App. Forwards board drags as `project_drag`
 *                       for project-drag.yml.
 *  POST /linear-webhook — Issue webhooks from Linear. Forwards state changes
 *                       as `linear_status_change` for linear-drag.yml, and
 *                       priority changes as `linear_priority_change` for
 *                       linear-priority-drag.yml (independently — either or
 *                       both can fire from the same delivery).
 *
 * Required environment variables (set as Worker secrets in Cloudflare dashboard):
 *   WEBHOOK_SECRET        — secret configured on the GitHub App webhook
 *   APP_ID                — the numeric GitHub App ID
 *   APP_PRIVATE_KEY       — the full PEM private key for the GitHub App
 *   INSTALLATION_ID        — the installation ID for dbbuilder-org
 *
 *   LINEAR_WEBHOOK_SECRET  — secret configured on the Linear webhook
 *   LINEAR_API_KEY         — Linear API key, used to resolve an updated
 *                            issue's linked GitHub URL via its attachments
 */

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }

    const { pathname } = new URL(request.url);
    if (pathname === '/linear-webhook') {
      return handleLinearWebhook(request, env);
    }
    return handleGithubWebhook(request, env);
  },
};

// ── GitHub Project drag -> project-drag.yml ───────────────────────────────────

async function handleGithubWebhook(request, env) {
  const body = await request.text();

  // ── Verify GitHub webhook signature ──────────────────────────────────────
  const sigHeader = request.headers.get('X-Hub-Signature-256');
  if (!sigHeader) {
    return new Response('Unauthorized: missing signature', { status: 401 });
  }

  const encoder = new TextEncoder();
  const hmacKey = await crypto.subtle.importKey(
    'raw',
    encoder.encode(env.WEBHOOK_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify']
  );
  const sigBytes = hexToBytes(sigHeader.replace('sha256=', ''));
  const valid = await crypto.subtle.verify('HMAC', hmacKey, sigBytes, encoder.encode(body));
  if (!valid) {
    return new Response('Unauthorized: invalid signature', { status: 401 });
  }

  // ── Filter to relevant events ─────────────────────────────────────────────
  const githubEvent = request.headers.get('X-Github-Event');

  // TEMPORARY debug capture — remove once payload shapes are confirmed.
  if (githubEvent === 'issue_dependencies' || githubEvent === 'sub_issues') {
    const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);
    await dispatch(token, 'debug_payload', { event: githubEvent, raw: body });
    return new Response('OK (debug)', { status: 200 });
  }

  if (githubEvent !== 'projects_v2_item') {
    return new Response('Ignored: not a projects_v2_item event', { status: 200 });
  }

  const payload = JSON.parse(body);

  if (payload.action !== 'edited') {
    return new Response('Ignored: not an edited action', { status: 200 });
  }
  const contentType = payload.projects_v2_item?.content_type;
  if (contentType !== 'PullRequest' && contentType !== 'Issue') {
    return new Response('Ignored: not a PullRequest or Issue item', { status: 200 });
  }

  const fieldChange = payload.changes?.field_value;
  if (!fieldChange || fieldChange.field_type !== 'single_select') {
    return new Response('Ignored: no single_select field change', { status: 200 });
  }

  // ── Generate a short-lived GitHub App installation token ─────────────────
  const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);

  // ── Forward as repository_dispatch ───────────────────────────────────────
  const resp = await dispatch(token, 'project_drag', {
    content_node_id: payload.projects_v2_item.content_node_id,
    content_type:    contentType,
    item_node_id:    payload.projects_v2_item.node_id,
    field_node_id:   fieldChange.field_node_id,
    from_status:     fieldChange.from?.name ?? '',
    to_status:       fieldChange.to?.name ?? '',
    sender:          payload.sender?.login ?? '',
  });

  if (!resp.ok) {
    const text = await resp.text();
    return new Response(`Dispatch failed: ${text}`, { status: 500 });
  }

  return new Response('OK', { status: 200 });
}

// ── Linear Issue state change -> linear-drag.yml ──────────────────────────────

async function handleLinearWebhook(request, env) {
  const body = await request.text();

  // ── Verify Linear webhook signature ───────────────────────────────────────
  const sigHeader = request.headers.get('Linear-Signature');
  if (!sigHeader) {
    return new Response('Unauthorized: missing signature', { status: 401 });
  }

  const encoder = new TextEncoder();
  const hmacKey = await crypto.subtle.importKey(
    'raw',
    encoder.encode(env.LINEAR_WEBHOOK_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify']
  );
  const sigBytes = hexToBytes(sigHeader);
  const valid = await crypto.subtle.verify('HMAC', hmacKey, sigBytes, encoder.encode(body));
  if (!valid) {
    return new Response('Unauthorized: invalid signature', { status: 401 });
  }

  const payload = JSON.parse(body);

  if (payload.type !== 'Issue' || payload.action !== 'update') {
    return new Response('Ignored: not an Issue update', { status: 200 });
  }

  // TEMPORARY debug capture — remove once payload shape is confirmed.
  if (payload.updatedFrom && 'parentId' in payload.updatedFrom) {
    const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);
    await dispatch(token, 'debug_payload', { event: 'linear_parent_change', raw: body });
  }

  const stateChanged = !!payload.updatedFrom && 'stateId' in payload.updatedFrom;
  const priorityChanged = !!payload.updatedFrom && 'priority' in payload.updatedFrom;
  if (!stateChanged && !priorityChanged) {
    return new Response('Ignored: no relevant field changed', { status: 200 });
  }

  const issueId = payload.data?.id;
  if (!issueId) {
    return new Response('Ignored: missing issue id', { status: 200 });
  }

  // ── Resolve the linked GitHub issue via Linear's own attachment data ──────
  const attachResp = await fetch('https://api.linear.app/graphql', {
    method: 'POST',
    headers: {
      'Authorization': env.LINEAR_API_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      query: 'query($id: String!) { issue(id: $id) { attachments { nodes { url sourceType } } } }',
      variables: { id: issueId },
    }),
  });
  const attachData = await attachResp.json();
  const githubUrl = attachData?.data?.issue?.attachments?.nodes
    ?.find((a) => a.sourceType === 'github')?.url;
  if (!githubUrl) {
    return new Response('Ignored: no linked GitHub issue', { status: 200 });
  }

  const match = githubUrl.match(/github\.com\/([^/]+)\/([^/]+)\/issues\/(\d+)/);
  if (!match) {
    return new Response('Ignored: unrecognized GitHub URL shape', { status: 200 });
  }
  const [, owner, repo, number] = match;

  // ── Forward whichever changed as repository_dispatch(es) ─────────────────
  const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);
  const results = [];

  if (stateChanged && payload.data?.state?.name) {
    results.push(await dispatch(token, 'linear_status_change', {
      owner,
      repo,
      issue_number: Number(number),
      new_status: payload.data.state.name,
    }));
  }
  if (priorityChanged && payload.data?.priority !== undefined && payload.data?.priority !== null) {
    results.push(await dispatch(token, 'linear_priority_change', {
      owner,
      repo,
      issue_number: Number(number),
      new_priority: payload.data.priority,
    }));
  }

  const failed = results.find((r) => !r.ok);
  if (failed) {
    const text = await failed.text();
    return new Response(`Dispatch failed: ${text}`, { status: 500 });
  }

  return new Response('OK', { status: 200 });
}

async function dispatch(token, eventType, clientPayload) {
  return fetch(
    'https://api.github.com/repos/dbbuilder-org/.github/dispatches',
    {
      method: 'POST',
      headers: githubHeaders(token, { 'Content-Type': 'application/json' }),
      body: JSON.stringify({ event_type: eventType, client_payload: clientPayload }),
    }
  );
}

// ── GitHub App JWT + installation token ──────────────────────────────────────

function githubHeaders(token, extra = {}) {
  return {
    'Authorization': `Bearer ${token}`,
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'DBBuilder-Workflow-Worker',
    ...extra,
  };
}

async function getInstallationToken(appId, pemKey, installationId) {
  const jwt = await generateJWT(appId, pemKey);

  const resp = await fetch(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: 'POST',
      headers: githubHeaders(jwt),
    }
  );

  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`Failed to get installation token: ${text}`);
  }

  const data = await resp.json();
  return data.token;
}

async function generateJWT(appId, pemKey) {
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iat: now - 60,   // issued 60s ago to account for clock skew
    exp: now + 540,  // expires in 9 minutes (max is 10)
    iss: appId,
  };

  const header = { alg: 'RS256', typ: 'JWT' };
  const headerB64  = base64url(JSON.stringify(header));
  const payloadB64 = base64url(JSON.stringify(payload));
  const signingInput = `${headerB64}.${payloadB64}`;

  const privateKey = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(pemKey),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  );

  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    privateKey,
    new TextEncoder().encode(signingInput)
  );

  return `${signingInput}.${base64url(signature)}`;
}

function pemToDer(pem) {
  const b64 = pem
    .replace(/-----BEGIN[^-]+-----/, '')
    .replace(/-----END[^-]+-----/, '')
    .replace(/\s/g, '');
  return Uint8Array.from(atob(b64), c => c.charCodeAt(0));
}

function base64url(data) {
  let b64;
  if (typeof data === 'string') {
    b64 = btoa(data);
  } else {
    b64 = btoa(String.fromCharCode(...new Uint8Array(data)));
  }
  return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.slice(i, i + 2), 16);
  }
  return bytes;
}
