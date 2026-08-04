/**
 * Cloudflare Worker: GitHub <-> Linear status-sync forwarder
 *
 * Two independent routes, both ending in a repository_dispatch to
 * dbbuilder-org/.github so a GitHub Actions workflow does the actual write:
 *
 *  POST /            — webhooks from the DBBuilder Workflow GitHub App:
 *                       - projects_v2_item -> `project_drag` for project-drag.yml
 *                       - issue_dependencies (blocked_by_added/removed only —
 *                         GitHub also fires the redundant blocking_added/removed
 *                         for the same edge, ignored here) -> `github_blocked_by_change`
 *                         for linear-relation-sync.yml
 *                       - sub_issues (sub_issue_added/removed only — same
 *                         redundant-pair situation as above with
 *                         parent_issue_added/removed) -> `github_sub_issue_change`
 *                         for linear-relation-sync.yml
 *  POST /linear-webhook — Issue webhooks from Linear. Forwards state changes
 *                       as `linear_status_change` for linear-drag.yml,
 *                       priority changes as `linear_priority_change` for
 *                       linear-priority-drag.yml, and parent/child changes as
 *                       `linear_parent_change` for linear-relation-sync.yml —
 *                       any subset can fire from the same delivery.
 *
 *                       Linear has no webhook resourceType for IssueRelation
 *                       (blocks/blocked-by), so that direction can't be
 *                       event-driven at all — see the scheduled polling job
 *                       (linear-relation-poll.yml) instead.
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

// ── GitHub -> Linear ───────────────────────────────────────────────────────────

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

  const githubEvent = request.headers.get('X-Github-Event');
  const payload = JSON.parse(body);

  if (githubEvent === 'issue_dependencies') {
    return handleIssueDependencies(payload, env);
  }
  if (githubEvent === 'sub_issues') {
    return handleSubIssues(payload, env);
  }
  if (githubEvent === 'projects_v2_item') {
    return handleProjectsV2Item(payload, env);
  }
  return new Response('Ignored: unhandled event type', { status: 200 });
}

async function handleProjectsV2Item(payload, env) {
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

  const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);
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

// GitHub fires both blocked_by_added/removed (on the blocked issue) and
// blocking_added/removed (on the blocking issue) for the same edge, with
// identical blocked_issue/blocking_issue data — only act on one pair.
async function handleIssueDependencies(payload, env) {
  let action;
  if (payload.action === 'blocked_by_added') action = 'add';
  else if (payload.action === 'blocked_by_removed') action = 'remove';
  else return new Response('Ignored: redundant or unhandled action', { status: 200 });

  const blockedUrl = payload.blocked_issue?.html_url;
  const blockingUrl = payload.blocking_issue?.html_url;
  if (!blockedUrl || !blockingUrl) {
    return new Response('Ignored: missing issue URLs', { status: 200 });
  }

  const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);
  const resp = await dispatch(token, 'github_blocked_by_change', {
    blocked_html_url: blockedUrl,
    blocking_html_url: blockingUrl,
    action,
  });

  if (!resp.ok) {
    const text = await resp.text();
    return new Response(`Dispatch failed: ${text}`, { status: 500 });
  }
  return new Response('OK', { status: 200 });
}

// Same redundant-pair situation as issue_dependencies: sub_issue_added/removed
// (on the sub-issue) and parent_issue_added/removed (on the parent) fire for
// the same edge — only act on one pair.
async function handleSubIssues(payload, env) {
  let action;
  if (payload.action === 'sub_issue_added') action = 'add';
  else if (payload.action === 'sub_issue_removed') action = 'remove';
  else return new Response('Ignored: redundant or unhandled action', { status: 200 });

  const subUrl = payload.sub_issue?.html_url;
  const parentUrl = payload.parent_issue?.html_url;
  if (!subUrl || !parentUrl) {
    return new Response('Ignored: missing issue URLs', { status: 200 });
  }

  const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);
  const resp = await dispatch(token, 'github_sub_issue_change', {
    sub_html_url: subUrl,
    parent_html_url: parentUrl,
    action,
  });

  if (!resp.ok) {
    const text = await resp.text();
    return new Response(`Dispatch failed: ${text}`, { status: 500 });
  }
  return new Response('OK', { status: 200 });
}

// ── Linear -> GitHub ───────────────────────────────────────────────────────────

async function handleLinearWebhook(request, env) {
  const body = await request.text();

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

  const stateChanged = !!payload.updatedFrom && 'stateId' in payload.updatedFrom;
  const priorityChanged = !!payload.updatedFrom && 'priority' in payload.updatedFrom;
  const parentChanged = !!payload.updatedFrom && 'parentId' in payload.updatedFrom;
  if (!stateChanged && !priorityChanged && !parentChanged) {
    return new Response('Ignored: no relevant field changed', { status: 200 });
  }

  const issueId = payload.data?.id;
  if (!issueId) {
    return new Response('Ignored: missing issue id', { status: 200 });
  }

  const githubUrl = await resolveLinearIssueGithubUrl(env, issueId);
  if (!githubUrl) {
    return new Response('Ignored: no linked GitHub issue', { status: 200 });
  }
  const match = parseGithubIssueUrl(githubUrl);
  if (!match) {
    return new Response('Ignored: unrecognized GitHub URL shape', { status: 200 });
  }
  const { owner, repo, number } = match;

  const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);
  const results = [];

  if (stateChanged && payload.data?.state?.name) {
    results.push(await dispatch(token, 'linear_status_change', {
      owner, repo, issue_number: number,
      new_status: payload.data.state.name,
    }));
  }
  if (priorityChanged && payload.data?.priority !== undefined && payload.data?.priority !== null) {
    results.push(await dispatch(token, 'linear_priority_change', {
      owner, repo, issue_number: number,
      new_priority: payload.data.priority,
    }));
  }
  if (parentChanged) {
    const newParentId = payload.data?.parentId ?? null;
    const oldParentId = payload.updatedFrom.parentId ?? null;
    // Resolve whichever parent (new, if set — else old, for a removal) to a
    // GitHub URL. A parent with no GitHub link at all means nothing to sync.
    const parentLinearId = newParentId ?? oldParentId;
    if (parentLinearId) {
      const parentGithubUrl = await resolveLinearIssueGithubUrl(env, parentLinearId);
      if (parentGithubUrl) {
        results.push(await dispatch(token, 'linear_parent_change', {
          owner, repo, issue_number: number,
          parent_html_url: parentGithubUrl,
          action: newParentId ? 'add' : 'remove',
        }));
      }
    }
  }

  const failed = results.find((r) => !r.ok);
  if (failed) {
    const text = await failed.text();
    return new Response(`Dispatch failed: ${text}`, { status: 500 });
  }
  return new Response('OK', { status: 200 });
}

async function resolveLinearIssueGithubUrl(env, linearIssueId) {
  const resp = await fetch('https://api.linear.app/graphql', {
    method: 'POST',
    headers: {
      'Authorization': env.LINEAR_API_KEY,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      query: 'query($id: String!) { issue(id: $id) { attachments { nodes { url sourceType } } } }',
      variables: { id: linearIssueId },
    }),
  });
  const data = await resp.json();
  return data?.data?.issue?.attachments?.nodes?.find((a) => a.sourceType === 'github')?.url ?? null;
}

function parseGithubIssueUrl(url) {
  const match = url.match(/github\.com\/([^/]+)\/([^/]+)\/issues\/(\d+)/);
  if (!match) return null;
  const [, owner, repo, number] = match;
  return { owner, repo, number: Number(number) };
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
