// Claimflow portal — vanilla JS, no build step.
//
// Sign-in is OIDC authorization code + PKCE against Thunder (public client). The code
// exchange goes through this origin's /oidc/token proxy; every API call goes through
// /api/* — the browser never leaves this origin except for the authorize redirect.

const THUNDER = 'https://localhost:8090';           // the browser-facing IdP
const CLIENT_ID = 'claimflow-portal';
const REDIRECT_URI = window.location.origin + '/callback';
const SCOPES = 'openid profile email groups';

// ── Auth ──────────────────────────────────────────────────────────────────────

const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function signIn() {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(48)));
  const challenge = b64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
  const state = b64url(crypto.getRandomValues(new Uint8Array(16)));
  sessionStorage.setItem('pkce', JSON.stringify({ verifier, state }));
  const q = new URLSearchParams({
    response_type: 'code', client_id: CLIENT_ID, redirect_uri: REDIRECT_URI,
    scope: SCOPES, state, code_challenge: challenge, code_challenge_method: 'S256',
  });
  window.location.assign(`${THUNDER}/oauth2/authorize?${q}`);
}

async function handleCallback() {
  const params = new URLSearchParams(window.location.search);
  const code = params.get('code');
  const saved = JSON.parse(sessionStorage.getItem('pkce') || '{}');
  if (!code || params.get('state') !== saved.state) {
    window.history.replaceState({}, '', '/');
    return;
  }
  const res = await fetch('/oidc/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code', code, redirect_uri: REDIRECT_URI,
      client_id: CLIENT_ID, code_verifier: saved.verifier,
    }),
  });
  if (res.ok) {
    const tokens = await res.json();
    sessionStorage.setItem('token', tokens.access_token);
  }
  sessionStorage.removeItem('pkce');
  window.history.replaceState({}, '', '/');
}

const token = () => sessionStorage.getItem('token');
const claims = () => {
  try { return JSON.parse(atob(token().split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); }
  catch { return null; }
};
const me = () => claims()?.username || claims()?.email || null;
const myGroups = () => claims()?.groups || [];
const isDecider = () => myGroups().includes('managers') || myGroups().includes('accountants');
const signOut = () => { sessionStorage.removeItem('token'); window.location.assign('/'); };

const api = (path, init = {}) => fetch(`/api${path}`, {
  ...init,
  headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json', ...(init.headers || {}) },
});

// ── Shell ─────────────────────────────────────────────────────────────────────

const app = document.getElementById('app');
const modal = document.getElementById('modal');
let tab = 'claims';
let activeConversation = null;
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function shell(content) {
  const decider = isDecider();
  app.innerHTML = `
    <div class="tabs">
      <button class="${tab === 'claims' ? 'active' : ''}" onclick="setTab('claims')">My claims</button>
      <button class="${tab === 'smart' ? 'active' : ''}" onclick="setTab('smart')">AI claims</button>
      ${decider ? `<button class="${tab === 'tasks' ? 'active' : ''}" onclick="setTab('tasks')">Decisions</button>` : ''}
    </div>${content}`;
}

window.setTab = (t) => { tab = t; if (t !== 'smart') activeConversation = null; refresh(); };

// ── My claims ─────────────────────────────────────────────────────────────────

async function renderClaims() {
  const res = await api('/claims/my');
  const rows = res.ok ? await res.json() : [];
  const list = rows.length === 0
    ? `<div class="empty"><span class="big">🗂️</span>No claims yet.<br>
       <span class="muted">Start with <b>New claim</b> — or let the AI agent file it from a sentence.</span></div>`
    : rows.map((c) => `
      <div class="card">
        <div class="row">
          <h3>${esc(c.claimId)}</h3>
          <span class="status ${esc(c.status)}">${esc(c.status.replace(/_/g, ' '))}</span>
          ${c.workflowId === 'agent' ? '<span class="ai-badge">🤖 AI filed</span>' : ''}
          <span class="muted">$${esc(c.amount)}</span>
          <div class="spacer" style="flex:1"></div>
          <span class="muted">${esc((c.updatedAt || '').slice(0, 16).replace('T', ' '))}</span>
        </div>
        ${c.note ? `<div class="muted" style="margin-top:.25rem">${esc(c.note)}</div>` : ''}
        ${c.billUrl ? `<div class="muted">bill: <a href="${esc(c.billUrl)}">${esc(c.billUrl.split('/').pop())}</a></div>` : ''}
        ${c.status === 'BILL_REQUESTED' ? `
          <div class="row" style="margin-top:.6rem">
            <input type="file" id="bill-${esc(c.claimId)}" style="width:auto">
            <button class="primary" onclick="uploadBill('${esc(c.claimId)}', '${esc(c.workflowId)}')">Upload &amp; attach bill</button>
          </div>` : ''}
      </div>`).join('');
  shell(`
    <div class="toolbar">
      <h2>My claims</h2>
      <div class="spacer" style="flex:1"></div>
      <button class="primary" onclick="openClaimModal()">＋ New claim</button>
      <button class="ai" onclick="startAiClaim()">🤖 Submit with AI agent</button>
    </div>
    ${list}`);
}

window.openClaimModal = () => {
  modal.hidden = false;
  modal.innerHTML = `
    <div class="box">
      <h3>New claim</h3>
      <div class="muted">A manager reviews every claim; you'll hear back in the bell.</div>
      <label for="m-amount">Amount (USD)</label>
      <input type="number" id="m-amount" placeholder="e.g. 1200" min="1">
      <label for="m-desc">What happened?</label>
      <textarea id="m-desc" rows="3" placeholder="Where, when, and what broke or went missing"></textarea>
      <label for="m-bill">Bill or receipt <span style="font-weight:400">(optional — you can add it later if the reviewer asks)</span></label>
      <input type="file" id="m-bill">
      <div class="row" style="margin-top:1.1rem; justify-content:flex-end">
        <button class="quiet" onclick="closeModal()">Cancel</button>
        <button class="primary" id="m-submit" onclick="submitClaim()">Submit claim</button>
      </div>
    </div>`;
};
window.closeModal = () => { modal.hidden = true; modal.innerHTML = ''; };
modal.addEventListener('click', (e) => { if (e.target === modal) window.closeModal(); });

window.submitClaim = async () => {
  const amount = parseFloat(document.getElementById('m-amount').value);
  const description = document.getElementById('m-desc').value.trim();
  const file = document.getElementById('m-bill').files[0];
  if (!amount || amount <= 0) return alert('An amount is required');
  const btn = document.getElementById('m-submit');
  btn.disabled = true; btn.textContent = 'Submitting…';
  let billUrl;
  if (file) {
    const up = await fetch(`/api/bills/?filename=${encodeURIComponent(file.name)}&owner=${encodeURIComponent(me())}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/octet-stream' },
      body: file,
    });
    if (!up.ok) { btn.disabled = false; btn.textContent = 'Submit claim'; return alert('Bill upload failed: ' + (await up.text())); }
    billUrl = (await up.json()).url;
  }
  // Trailing slash matters: nginx 301s '/api/claims' to '/api/claims/', and a
  // redirected POST arrives as a GET.
  const res = await api('/claims/', { method: 'POST', body: JSON.stringify({ amount, description, billUrl }) });
  if (!res.ok) { btn.disabled = false; btn.textContent = 'Submit claim'; return alert('Submit failed: ' + (await res.text())); }
  window.closeModal();
  refresh();
};

window.uploadBill = async (claimId, workflowId) => {
  const input = document.getElementById(`bill-${claimId}`);
  const file = input.files[0];
  if (!file) return alert('Pick a file first');
  const up = await fetch(`/api/bills/?filename=${encodeURIComponent(file.name)}&owner=${encodeURIComponent(me())}&claimId=${encodeURIComponent(claimId)}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/octet-stream' },
    body: file,
  });
  if (!up.ok) return alert('Upload failed: ' + (await up.text()));
  const { billId } = await up.json();
  const at = await api(`/bills/${billId}/attach`, { method: 'POST', body: JSON.stringify({ workflowId, claimId }) });
  if (!at.ok) return alert('Attach failed: ' + (await at.text()));
  refresh();
};

// ── AI claims: chatting with the durable agent ────────────────────────────────
// Conversations and every turn's correlation token live in the application database,
// so this view survives new sessions, new browsers, and restarts. A pending reply
// usually means the payment is waiting on the accountant — the demo's point.

window.startAiClaim = async () => {
  const created = await api('/agent/conversations', { method: 'POST' });
  if (!created.ok) return alert('Could not start the agent: ' + (await created.text()));
  activeConversation = (await created.json()).conversationId;
  tab = 'smart';
  refresh();
};

async function renderSmart() {
  if (activeConversation) return renderConversation(activeConversation);
  const res = await api('/agent/conversations');
  const rows = res.ok ? await res.json() : [];
  const list = rows.length === 0
    ? `<div class="empty"><span class="big">🤖</span>No AI claims yet.<br>
       <span class="muted">Tell the agent what happened — it files the claim, estimates the payout, and asks the accountant to release the money.</span></div>`
    : rows.map((c) => `
      <div class="card" style="cursor:pointer" onclick="openConversation('${esc(c.conversationId)}')">
        <div class="row">
          <span class="ai-badge">🤖 conversation</span>
          <span class="muted" style="font-family:monospace">${esc(c.conversationId.slice(0, 13))}…</span>
          <div class="spacer" style="flex:1"></div>
          <span class="muted">${esc((c.createdAt || '').slice(0, 16).replace('T', ' '))}</span>
        </div>
      </div>`).join('');
  shell(`
    <div class="toolbar">
      <h2>AI claims</h2>
      <div class="spacer" style="flex:1"></div>
      <button class="ai" onclick="startAiClaim()">🤖 New AI claim</button>
    </div>
    ${list}`);
}

window.openConversation = (id) => { activeConversation = id; refresh(); };

async function renderConversation(id) {
  const res = await api(`/agent/conversations/${id}`);
  const turns = res.ok ? await res.json() : [];
  const log = turns.length === 0
    ? '<div class="empty">Say what happened and roughly what it cost.</div>'
    : turns.map((t) => `
      <div class="bubble-row">
        <div class="bubble ${t.who === 'me' ? 'me' : 'agent'} ${t.pending ? 'pending' : ''}">
          ${t.pending ? '… working (a payment may be waiting on the accountant)' : esc(t.text || '')}
        </div>
      </div>`).join('');
  shell(`
    <div class="toolbar">
      <button class="quiet" onclick="setTab('smart')">← All AI claims</button>
      <span class="ai-badge">🤖 ${esc(id.slice(0, 13))}…</span>
    </div>
    <div class="card">
      <div id="chatlog" style="max-height:24rem;overflow:auto">${log}</div>
      <div class="row" style="margin-top:.8rem">
        <input type="text" id="chatmsg" placeholder="e.g. Broke my laptop on a work trip, about $1200" style="flex:1;min-width:16rem" onkeydown="if(event.key==='Enter')sendChat()">
        <button class="ai" onclick="sendChat()">Send</button>
      </div>
    </div>`);
  const el = document.getElementById('chatlog');
  if (el) el.scrollTop = el.scrollHeight;
  turns.filter((t) => t.pending && t.token).forEach((t) => pollReply(id, t.token));
}

window.sendChat = async () => {
  const input = document.getElementById('chatmsg');
  const text = input.value.trim();
  if (!text || !activeConversation) return;
  input.value = '';
  const sent = await api(`/agent/conversations/${activeConversation}/messages`, {
    method: 'POST', body: JSON.stringify({ message: text }),
  });
  if (!sent.ok) return alert('Send failed: ' + (await sent.text()));
  const { token: turn } = await sent.json();
  await renderConversation(activeConversation);
  pollReply(activeConversation, turn);
};

const polling = new Set();
async function pollReply(id, turn) {
  if (polling.has(turn)) return;
  polling.add(turn);
  // The server long-polls (waitForDataResult); the proxy cuts a poll after ~60s and we
  // simply ask again — a long-held payment gate is successive quiet polls, not an error.
  try {
    for (let i = 0; i < 120; i++) {
      let res;
      try { res = await api(`/agent/conversations/${id}/replies/${turn}`); }
      catch { await new Promise((r) => setTimeout(r, 2000)); continue; }
      if (res.status === 200) {
        if (tab === 'smart' && activeConversation === id) await renderConversation(id);
        return;
      }
      await new Promise((r) => setTimeout(r, 2000));
    }
  } finally {
    polling.delete(turn);
  }
}

// ── Decisions (managers and accountants) ──────────────────────────────────────

async function renderTasks() {
  const res = await api('/claims/tasks');
  const rows = res.ok ? await res.json() : [];
  const list = rows.length === 0
    ? '<div class="empty"><span class="big">✅</span>Nothing waiting on you.</div>'
    : rows.map((t) => {
      const payment = t.userRoles.includes('ACCOUNTANT');
      const p = t.payload || {};
      const facts = ['claimId', 'amount', 'submittedBy', 'payee', 'validation']
        .filter((k) => p[k] !== undefined && p[k] !== null)
        .map((k) => `<span class="muted">${esc(k)}: <b>${esc(p[k])}</b></span>`).join(' · ');
      const bill = p.bill && p.bill.url ? `<div class="muted">bill: <a href="${esc(p.bill.url)}" target="_blank">${esc(p.bill.url.split('/').pop())}</a></div>` : '';
      const buttons = payment
        ? `<button class="good" onclick="decide('${esc(t.taskId)}', {approved: true, account: 'ACC-77'})">Approve payment</button>
           <button class="bad" onclick="decide('${esc(t.taskId)}', {approved: false, comment: comment('${esc(t.taskId)}')})">Refuse</button>`
        : `<button class="good" onclick="decide('${esc(t.taskId)}', {outcome: 'APPROVE'})">Approve</button>
           <button class="warn" onclick="decide('${esc(t.taskId)}', {outcome: 'REQUEST_BILL', comment: comment('${esc(t.taskId)}')})">Request bill</button>
           <button class="bad" onclick="decide('${esc(t.taskId)}', {outcome: 'REJECT', comment: comment('${esc(t.taskId)}')})">Reject</button>`;
      return `
      <div class="card">
        <h3>${esc(t.title)}</h3>
        <div class="row" style="margin-top:.3rem">${facts}</div>${bill}
        <div class="row" style="margin-top:.7rem">
          ${buttons}
          <input type="text" id="c-${esc(t.taskId)}" placeholder="Comment (optional)" style="flex:1;min-width:10rem">
        </div>
        <div class="muted" style="margin-top:.35rem">The full form, payload and history live in the ICP console — this is the fast lane.</div>
      </div>`;
    }).join('');
  shell(`<div class="toolbar"><h2>Decisions</h2></div>${list}`);
}

window.comment = (id) => document.getElementById(`c-${id}`)?.value || undefined;

window.decide = async (taskId, result) => {
  const c = window.comment(taskId);
  if (c && result.comment === undefined) result.comment = c;
  const res = await api(`/claims/tasks/${taskId}/complete`, { method: 'POST', body: JSON.stringify({ result }) });
  if (!res.ok) alert('Could not complete the task: ' + (await res.text()));
  refresh();
};

// ── Inbox ─────────────────────────────────────────────────────────────────────

const bellBtn = document.getElementById('bellBtn');
const bellCount = document.getElementById('bellCount');
const inboxPanel = document.getElementById('inboxPanel');

async function refreshInbox() {
  if (!token()) return;
  const res = await api(`/notifications/?user=${encodeURIComponent(me())}`);
  if (!res.ok) return;
  const notes = await res.json();
  const unread = notes.filter((n) => !n.isRead);
  bellCount.hidden = unread.length === 0;
  bellCount.textContent = unread.length;
  inboxPanel.innerHTML = notes.length === 0
    ? '<div class="empty">Nothing yet.</div>'
    : notes.slice(0, 20).map((n) => `
      <div class="note ${n.isRead ? '' : 'unread'}" onclick="markRead(${n.id})">
        <b>${esc(n.title)}</b>
        <span class="muted">${esc(n.body || '')}</span>
      </div>`).join('');
}

window.markRead = async (id) => { await api(`/notifications/${id}/read`, { method: 'POST' }); refreshInbox(); };
bellBtn.onclick = () => { inboxPanel.hidden = !inboxPanel.hidden; };

// ── Boot ──────────────────────────────────────────────────────────────────────

async function refresh() {
  if (!token()) return;
  if (tab === 'tasks' && isDecider()) await renderTasks();
  else if (tab === 'smart') await renderSmart();
  else await renderClaims();
  await refreshInbox();
}

(async function boot() {
  if (window.location.pathname === '/callback') await handleCallback();
  const authBtn = document.getElementById('authBtn');
  if (token()) {
    const roles = myGroups().filter((g) => g === 'managers' || g === 'accountants');
    document.getElementById('who').innerHTML =
      `<b>${esc(me())}</b> ${roles.map((r) => `<span class="chip role">${esc(r)}</span>`).join(' ')}`;
    bellBtn.hidden = false;
    authBtn.textContent = 'Sign out';
    authBtn.onclick = signOut;
    await refresh();
    // The chat view manages its own polling; a full refresh mid-conversation would
    // discard what the user is typing.
    setInterval(() => { if (tab !== 'smart') refresh(); else refreshInbox(); }, 10000);
  } else {
    authBtn.onclick = signIn;
  }
})();
