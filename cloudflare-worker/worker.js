/**
 * Cloudflare Worker: GitHub Project Drag Forwarder
 *
 * Receives projects_v2_item webhook events from the DBBuilder Workflow GitHub App,
 * verifies the signature, generates a short-lived app token, and forwards drag
 * events as repository_dispatch to dbbuilder-org/.github so the project-drag.yml
 * workflow can handle them.
 *
 * Required environment variables (set as Worker secrets in Cloudflare dashboard):
 *   WEBHOOK_SECRET   — the secret configured on the GitHub App webhook
 *   APP_ID           — the numeric GitHub App ID
 *   APP_PRIVATE_KEY  — the full PEM private key for the GitHub App
 *   INSTALLATION_ID  — the installation ID for dbbuilder-org
 */

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }

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
    if (githubEvent !== 'projects_v2_item') {
      return new Response('Ignored: not a projects_v2_item event', { status: 200 });
    }

    const payload = JSON.parse(body);

    if (payload.action !== 'edited') {
      return new Response('Ignored: not an edited action', { status: 200 });
    }
    if (payload.projects_v2_item?.content_type !== 'PullRequest') {
      return new Response('Ignored: not a PullRequest item', { status: 200 });
    }

    const fieldChange = payload.changes?.field_value;
    if (!fieldChange || fieldChange.field_type !== 'single_select') {
      return new Response('Ignored: no single_select field change', { status: 200 });
    }

    // ── Generate a short-lived GitHub App installation token ─────────────────
    const token = await getInstallationToken(env.APP_ID, env.APP_PRIVATE_KEY, env.INSTALLATION_ID);

    // ── Forward as repository_dispatch ───────────────────────────────────────
    const resp = await fetch(
      'https://api.github.com/repos/dbbuilder-org/.github/dispatches',
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Accept': 'application/vnd.github+json',
          'Content-Type': 'application/json',
          'User-Agent': 'DBBuilder-Workflow-Worker',
        },
        body: JSON.stringify({
          event_type: 'project_drag',
          client_payload: {
            content_node_id: payload.projects_v2_item.content_node_id,
            item_node_id:    payload.projects_v2_item.node_id,
            field_node_id:   fieldChange.field_node_id,
            from_status:     fieldChange.from?.name ?? '',
            to_status:       fieldChange.to?.name ?? '',
          },
        }),
      }
    );

    if (!resp.ok) {
      const text = await resp.text();
      return new Response(`Dispatch failed: ${text}`, { status: 500 });
    }

    return new Response('OK', { status: 200 });
  },
};

// ── GitHub App JWT + installation token ──────────────────────────────────────

async function getInstallationToken(appId, pemKey, installationId) {
  const jwt = await generateJWT(appId, pemKey);

  const resp = await fetch(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${jwt}`,
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'DBBuilder-Workflow-Worker',
      },
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
