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
const chatPanel = document.getElementById('chatPanel');
const aiFab = document.getElementById('aiFab');
// Two top-level workspaces, not sibling tabs: 'claims' is everyone's space,
// 'approvals' is the decider space (managers/accountants) and looks different.
let mode = 'claims';
let chatOpen = false;
let activeConversation = null;
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function shell(content) {
  const decider = isDecider();
  document.body.classList.toggle('admin', mode === 'approvals');
  const switcher = decider ? `
    <div class="mode-switch">
      <button class="${mode === 'claims' ? 'active' : ''}" onclick="setMode('claims')">🗂️ My claims</button>
      <button class="${mode === 'approvals' ? 'active' : ''}" onclick="setMode('approvals')">✅ Approvals</button>
    </div>` : '';
  const banner = mode === 'approvals' ? `
    <div class="admin-banner"><b>Approvals workspace</b> — every card here is a live process, parked on your decision.</div>` : '';
  app.innerHTML = `${switcher}${banner}${content}`;
}

window.setMode = (m) => { mode = m; refresh(); };

// A confirmation the user actually sees — decisions and submits confirm here, and the
// view refreshes right after so the completed card is visibly gone.
const toasts = document.getElementById('toasts');
function showToast(msg, kind = 'good') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  toasts.appendChild(el);
  setTimeout(() => el.classList.add('gone'), 3400);
  setTimeout(() => el.remove(), 3900);
}

// ── My claims ─────────────────────────────────────────────────────────────────

let claimsById = {};
async function renderClaims() {
  const res = await api('/claims/my');
  const rows = res.ok ? await res.json() : [];
  claimsById = Object.fromEntries(rows.map((c) => [c.claimId, c]));
  const list = rows.length === 0
    ? `<div class="empty"><span class="big">🗂️</span>No claims yet.<br>
       <span class="muted">Start with <b>New claim</b> — or open the 🤖 assistant and just tell it what happened.</span></div>`
    : rows.map((c) => `
      <div class="card" style="cursor:pointer" onclick="openClaimDetail('${esc(c.claimId)}')">
        <div class="row">
          <h3>${esc(c.claimId)}</h3>
          <span class="status ${esc(c.status)}">${esc(c.status.replace(/_/g, ' '))}</span>
          ${c.filedVia === 'agent' ? '<span class="ai-badge">🤖 AI filed</span>' : ''}
          <span class="muted">$${esc(c.amount)}</span>
          <div class="spacer" style="flex:1"></div>
          <span class="muted">${esc((c.updatedAt || '').slice(0, 16).replace('T', ' '))}</span>
        </div>
        ${c.note ? `<div class="muted" style="margin-top:.25rem">${esc(c.note)}</div>` : ''}
        ${c.billUrl ? `<div class="muted">bill: <a href="${esc(c.billUrl)}">${esc(c.billUrl.split('/').pop())}</a></div>` : ''}
        ${c.status === 'BILL_REQUESTED' ? `
          <div class="row" style="margin-top:.6rem" onclick="event.stopPropagation()">
            <input type="file" id="bill-${esc(c.claimId)}" style="width:auto">
            <button class="primary" onclick="uploadBill('${esc(c.claimId)}', '${esc(c.workflowId)}')">Upload &amp; attach bill</button>
          </div>` : ''}
      </div>`).join('');
  shell(`
    <div class="toolbar">
      <h2>My claims</h2>
      <div class="spacer" style="flex:1"></div>
      <button class="primary" onclick="openClaimModal()">＋ New claim</button>
      <button class="ai" onclick="openChat()">🤖 Claims assistant</button>
    </div>
    ${list}`);
}

const OPEN_STATUSES = ['SUBMITTED', 'BILL_REQUESTED', 'BILL_ATTACHED'];

window.openClaimDetail = (claimId) => {
  const c = claimsById[claimId];
  if (!c) return;
  const open = OPEN_STATUSES.includes(c.status);
  modal.hidden = false;
  modal.innerHTML = `
    <div class="box">
      <div class="row">
        <h3>${esc(c.claimId)}</h3>
        <span class="status ${esc(c.status)}">${esc(c.status.replace(/_/g, ' '))}</span>
        ${c.filedVia === 'agent' ? '<span class="ai-badge">🤖 AI filed</span>' : ''}
      </div>
      <label>Amount</label><div>$${esc(c.amount)}</div>
      ${c.note ? `<label>${c.status === 'PAID' ? 'Payment reference' : 'Note'}</label><div>${esc(c.note)}</div>` : ''}
      <label>Bill</label>
      <div>${c.billUrl ? `<a href="${esc(c.billUrl)}">${esc(c.billUrl.split('/').pop())}</a>` : '<span class="muted">none attached yet</span>'}</div>
      ${open ? `
        <label>${c.billUrl ? 'Replace the bill' : 'Add a bill'} <span style="font-weight:400">(goes to the reviewer with the claim)</span></label>
        <div class="row">
          <input type="file" id="d-bill" style="width:auto;flex:1">
          <button class="primary" onclick="detailAttachBill('${esc(c.claimId)}', '${esc(c.workflowId)}')">Attach</button>
        </div>` : ''}
      <label>Last update</label><div class="muted">${esc((c.updatedAt || '').slice(0, 19).replace('T', ' '))}</div>
      <div class="row" style="margin-top:1rem; justify-content:flex-end">
        <button class="quiet" onclick="closeModal()">Close</button>
      </div>
    </div>`;
};

window.detailAttachBill = async (claimId, workflowId) => {
  const file = document.getElementById('d-bill').files[0];
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
  window.closeModal();
  showToast('Bill attached — the reviewer gets it with the claim.');
  refresh();
};

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
  showToast('Claim submitted — a manager reviews it; watch the bell.');
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
  showToast('Bill attached — the process resumes on its own.');
  refresh();
};

// ── The claims assistant: an overlay chat with the durable agent ──────────────
// The chat is deliberately NOT another claims form. The classic flow creates a claim
// the moment you submit; the assistant is an intelligent orchestrator — a chat session
// starts first, and the claim is created only once the agent has gathered what it
// needs. Conversations and every turn's correlation token live in the application
// database, so sessions survive new browsers and restarts. A pending reply usually
// means the payment is waiting on the accountant — the demo's point.

window.toggleChat = () => (chatOpen ? window.closeChat() : window.openChat());
window.openChat = async () => {
  chatOpen = true;
  chatPanel.hidden = false;
  aiFab.classList.add('open');
  // Always a fresh fetch on open: outcomes that landed while the panel was closed
  // (approved, paid, refused) must be in the history the moment it appears.
  await renderChat();
};
window.closeChat = () => {
  chatOpen = false;
  chatPanel.hidden = true;
  aiFab.classList.remove('open');
};

window.startAiClaim = async () => {
  const created = await api('/agent/conversations', { method: 'POST' });
  if (!created.ok) return alert('Could not start the agent: ' + (await created.text()));
  activeConversation = (await created.json()).conversationId;
  await renderChat();
};

async function renderChat() {
  if (activeConversation) return renderConversation(activeConversation);
  const res = await api('/agent/conversations');
  const rows = res.ok ? await res.json() : [];
  const list = rows.length === 0
    ? '<div class="empty" style="padding:1.6rem .5rem">No sessions yet.</div>'
    : rows.map((c) => `
      <div class="session-card" onclick="openConversation('${esc(c.conversationId)}')">
        <div class="row" style="gap:.5rem">
          <span class="ai-badge">🤖 session</span>
          <span class="muted" style="font-family:monospace">${esc(c.conversationId.slice(0, 13))}…</span>
          <div class="spacer" style="flex:1"></div>
          <span class="muted">${esc((c.createdAt || '').slice(0, 16).replace('T', ' '))}</span>
        </div>
      </div>`).join('');
  chatPanel.innerHTML = `
    <div class="chat-head">
      <span class="chat-title">🤖 Claims assistant</span>
      <div class="spacer"></div>
      <button class="x" onclick="closeChat()" title="Close">✕</button>
    </div>
    <div class="chat-body">
      <div class="chat-pitch">Just tell it what happened. The assistant asks for what's missing and opens
        the claim only when it has enough — no form to fill.</div>
      <button class="ai wide" onclick="startAiClaim()">＋ Start a new chat</button>
      <div class="session-label">Previous sessions</div>
      ${list}
    </div>`;
}

window.openConversation = (id) => { activeConversation = id; renderChat(); };
window.backToAiList = () => { activeConversation = null; renderChat(); };

let casesById = {};

async function renderConversation(id) {
  const [res, cRes] = await Promise.all([
    api(`/agent/conversations/${id}`),
    api(`/agent/conversations/${id}/cases`),
  ]);
  const turns = res.ok ? await res.json() : [];
  const cases = cRes.ok ? await cRes.json() : [];
  casesById = Object.fromEntries(cases.map((c) => [c.caseId, c]));
  const log = turns.length === 0
    ? '<div class="empty">The agent is opening your case — it says hello in a moment.</div>'
    : turns.map((t) => `
      <div class="bubble-row">
        <div class="bubble ${t.who === 'me' ? 'me' : 'agent'} ${t.pending ? 'pending' : ''}">
          ${t.pending ? '… working (a document, a manager, or the accountant may be holding it)' : esc(t.text || '')}
        </div>
      </div>`).join('');
  // Attachment cases live in the thread: an OPEN one is the agent asking for a
  // document; submitting it fires the caseSubmitted event that resumes the run.
  const caseCards = cases.map((c) => c.status === 'OPEN' ? `
      <div class="case-card">
        <div><b>📎 ${esc(c.requested)}</b> <span class="muted">case ${esc(c.caseId)} · claim ${esc(c.claimId)}</span></div>
        <div class="row" style="margin-top:.45rem">
          <input type="file" id="case-file-${esc(c.caseId)}" style="width:auto;flex:1">
          <button class="primary" onclick="submitCase('${esc(c.caseId)}')">Attach &amp; resume</button>
        </div>
      </div>` : `
      <div class="case-card done">📎 case ${esc(c.caseId)} — document submitted ✓</div>`).join('');
  const draft = document.getElementById('chatmsg')?.value ?? '';
  // The composer stays locked until the agent's greeting has landed: a message sent into
  // the empty session races the greeting, gets a generic scripted answer, and the greeting
  // then arrives AFTER the exchange — a transcript that reads broken. The watcher re-renders
  // the moment the greeting turn exists, which unlocks the input.
  const opening = turns.length === 0;
  chatPanel.innerHTML = `
    <div class="chat-head">
      <button class="x" onclick="backToAiList()" title="All sessions">←</button>
      <span class="chat-title">🤖 Claims assistant</span>
      <span class="chat-id">${esc(id.slice(0, 13))}…</span>
      <div class="spacer"></div>
      <button class="x" onclick="closeChat()" title="Close">✕</button>
    </div>
    <div class="chat-log" id="chatlog">${log}${caseCards}</div>
    <div class="chat-compose">
      <input type="text" id="chatmsg" ${opening ? 'disabled' : ''}
        placeholder="${opening ? 'The assistant is opening your case…' : 'e.g. Broke my laptop on a work trip, about $1200'}"
        onkeydown="if(event.key==='Enter')sendChat()">
      <button class="ai" onclick="sendChat()" ${opening ? 'disabled' : ''}>Send</button>
    </div>`;
  const draftBox = document.getElementById('chatmsg');
  if (draftBox && draft) draftBox.value = draft;
  watchConversation(id, JSON.stringify([turns.map((t) => [t.id, t.pending]), cases.map((c) => [c.caseId, c.status])]));
  // The agent's concluding words never belong to a turn — read the run state and show
  // them as the closing bubble.
  const st = await api(`/agent/conversations/${id}/state`);
  if (st.ok) {
    const state = await st.json();
    if (state.final && !turns.some((t) => t.text === state.final)) {
      document.getElementById('chatlog').insertAdjacentHTML('beforeend',
        `<div class="bubble-row"><div class="bubble agent">${esc(state.final)}</div></div>`);
    } else if (state.failed) {
      document.getElementById('chatlog').insertAdjacentHTML('beforeend',
        `<div class="bubble-row"><div class="bubble agent pending">This conversation has ended — start a new AI claim.</div></div>`);
    }
  }
  const el = document.getElementById('chatlog');
  if (el) el.scrollTop = el.scrollHeight;
  turns.filter((t) => t.pending && t.token).forEach((t) => pollReply(id, t.token));
}

// The agent speaks between turns (greetings, progress, new cases) through its push
// activity — the thread has to notice without the user sending anything. A light
// signature poll re-renders only when something actually changed.
let chatWatch = null;
let chatSig = '';
function watchConversation(id, sig) {
  chatSig = sig;
  if (chatWatch) return;
  chatWatch = setInterval(async () => {
    if (!chatOpen || activeConversation !== id) {
      clearInterval(chatWatch); chatWatch = null; return;
    }
    try {
      const [r1, r2] = await Promise.all([
        api(`/agent/conversations/${id}`),
        api(`/agent/conversations/${id}/cases`),
      ]);
      if (!r1.ok) return;
      const turns = await r1.json();
      const cases = r2.ok ? await r2.json() : [];
      const sig2 = JSON.stringify([turns.map((t) => [t.id, t.pending]), cases.map((c) => [c.caseId, c.status])]);
      if (sig2 !== chatSig) await renderConversation(id);
    } catch { /* transient — next tick retries */ }
  }, 4000);
}

window.submitCase = async (caseId) => {
  const c = casesById[caseId];
  const file = document.getElementById(`case-file-${caseId}`)?.files[0];
  if (!file) return alert('Pick a file first');
  const up = await fetch(`/api/bills/?filename=${encodeURIComponent(file.name)}&owner=${encodeURIComponent(me())}&claimId=${encodeURIComponent(c?.claimId || '')}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/octet-stream' },
    body: file,
  });
  if (!up.ok) return alert('Upload failed: ' + (await up.text()));
  const { billId, url } = await up.json();
  const sub = await api(`/agent/cases/${caseId}/submit`, { method: 'POST', body: JSON.stringify({ url, billId }) });
  if (!sub.ok) return alert('Case submit failed: ' + (await sub.text()));
  showToast('Document attached — the agent picks it up from here.');
  if (chatOpen && activeConversation) await renderConversation(activeConversation);
};

window.sendChat = async () => {
  const input = document.getElementById('chatmsg');
  if (!input || input.disabled) return;
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
      if (res.status === 200 || res.status === 410) {
        if (chatOpen && activeConversation === id) await renderConversation(id);
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
  const [res, aRes, rRes] = await Promise.all([api('/claims/tasks'), api('/agent/tasks'), api('/agent/reviews')]);
  // Completion is task-queue-scoped: each integration decides its own tasks, so the
  // portal remembers which service every card came from.
  const rows = [
    ...(res.ok ? await res.json() : []).map((t) => ({ ...t, src: 'claims' })),
    ...(aRes.ok ? await aRes.json() : []).map((t) => ({ ...t, src: 'agent' })),
  ];
  const reviews = rRes.ok ? await rRes.json() : [];
  // The Smart Claim agent's gated payments: PRE_RUN reviews the module raised on
  // executePayment. Deciding one here releases (or refuses) the money in-app.
  const reviewList = reviews.map((r) => {
    const a = r.args || {};
    const facts = ['claimId', 'payout']
      .filter((k) => a[k] !== undefined && a[k] !== null)
      .map((k) => `<span class="muted">${esc(k)}: <b>${esc(a[k])}</b></span>`).join(' · ');
    return `
      <div class="card">
        <h3>💸 ${esc(r.title || 'Payment release')}</h3>
        <div class="row" style="margin-top:.3rem">${facts} <span class="ai-badge">🤖 Smart Claim</span></div>
        <div class="row" style="margin-top:.7rem">
          <button class="good" onclick="decideReview('${esc(r.taskId)}', 'proceed')">Release payment</button>
          <button class="bad" onclick="decideReview('${esc(r.taskId)}', 'reject')">Refuse</button>
          <input type="text" id="c-${esc(r.taskId)}" placeholder="Comment (optional)" style="flex:1;min-width:10rem">
        </div>
        <div class="muted" style="margin-top:.35rem">The agent's payment call is parked on this decision.</div>
      </div>`;
  }).join('');
  const list = (rows.length === 0 && reviews.length === 0)
    ? '<div class="empty"><span class="big">✅</span>Nothing waiting on you.</div>'
    : reviewList + rows.map((t) => {
      const payment = t.userRoles.includes('ACCOUNTANT');
      const p = t.payload || {};
      const facts = ['claimId', 'amount', 'submittedBy', 'payee', 'validation']
        .filter((k) => p[k] !== undefined && p[k] !== null)
        .map((k) => `<span class="muted">${esc(k)}: <b>${esc(p[k])}</b></span>`).join(' · ');
      const bill = p.bill && p.bill.url ? `<div class="muted">bill: <a href="${esc(p.bill.url)}" target="_blank">${esc(p.bill.url.split('/').pop())}</a></div>` : '';
      const buttons = payment
        ? `<button class="good" onclick="decide('${esc(t.taskId)}', {approved: true, account: 'ACC-77'}, '${t.src}')">Approve payment</button>
           <button class="bad" onclick="decide('${esc(t.taskId)}', {approved: false, comment: comment('${esc(t.taskId)}')}, '${t.src}')">Refuse</button>`
        : `<button class="good" onclick="decide('${esc(t.taskId)}', {outcome: 'APPROVE'}, '${t.src}')">Approve</button>
           <button class="warn" onclick="decide('${esc(t.taskId)}', {outcome: 'REQUEST_BILL', comment: comment('${esc(t.taskId)}')}, '${t.src}')">Request bill</button>
           <button class="bad" onclick="decide('${esc(t.taskId)}', {outcome: 'REJECT', comment: comment('${esc(t.taskId)}')}, '${t.src}')">Reject</button>`;
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

window.decideReview = async (taskId, action) => {
  const feedback = window.comment(taskId);
  const res = await api(`/agent/reviews/${taskId}/decide`, {
    method: 'POST', body: JSON.stringify(feedback ? { action, feedback } : { action }),
  });
  if (!res.ok) return alert('Could not decide the payment: ' + (await res.text()));
  showToast(action === 'proceed'
    ? 'Payment released — the agent completes the run.'
    : 'Payment refused — the agent is told why.', action === 'proceed' ? 'good' : 'bad');
  await refresh();
};

window.decide = async (taskId, result, src = 'claims') => {
  const c = window.comment(taskId);
  if (c && result.comment === undefined) result.comment = c;
  const base = src === 'agent' ? '/agent/tasks' : '/claims/tasks';
  const res = await api(`${base}/${taskId}/complete`, { method: 'POST', body: JSON.stringify({ result }) });
  if (!res.ok) return alert('Could not complete the task: ' + (await res.text()));
  const said = result.outcome || (result.approved === true ? 'PAYMENT APPROVED' : result.approved === false ? 'PAYMENT REFUSED' : 'DONE');
  showToast(`Decision recorded — ${said.replace(/_/g, ' ').toLowerCase()}. The process moves on.`,
    /REJECT|REFUSED/.test(said) ? 'bad' : 'good');
  await refresh();
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
  if (mode === 'approvals' && isDecider()) await renderTasks();
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
    aiFab.hidden = false;
    aiFab.onclick = window.toggleChat;
    authBtn.textContent = 'Sign out';
    authBtn.onclick = signOut;
    await refresh();
    // The chat overlay owns its own polling and draft-preserving redraws; the main
    // view can refresh freely underneath it without touching what the user is typing.
    setInterval(() => refresh(), 10000);
  } else {
    authBtn.onclick = signIn;
  }
})();
