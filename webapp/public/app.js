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

// ── Views ─────────────────────────────────────────────────────────────────────

const app = document.getElementById('app');
let tab = 'claims';
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function shell(content) {
  const decider = isDecider();
  app.innerHTML = `
    <div class="tabs">
      <button class="${tab === 'claims' ? 'active' : ''}" onclick="setTab('claims')">My claims</button>
      ${decider ? `<button class="${tab === 'tasks' ? 'active' : ''}" onclick="setTab('tasks')">Decisions</button>` : ''}
    </div>${content}`;
}

window.setTab = (t) => { tab = t; refresh(); };

async function renderClaims() {
  const res = await api('/claims/my');
  const rows = res.ok ? await res.json() : [];
  const list = rows.length === 0
    ? '<div class="empty">No claims yet — submit your first one above.</div>'
    : rows.map((c) => `
      <div class="card">
        <div class="row">
          <h3 style="margin:0">${esc(c.claimId)}</h3>
          <span class="status ${esc(c.status)}">${esc(c.status.replace(/_/g, ' '))}</span>
          <span class="muted">$${esc(c.amount)}</span>
          <div class="spacer" style="flex:1"></div>
          <span class="muted">${esc((c.updatedAt || '').slice(0, 16).replace('T', ' '))}</span>
        </div>
        ${c.billUrl ? `<div class="muted">bill: <a href="${esc(c.billUrl)}">${esc(c.billUrl.split('/').pop())}</a></div>` : ''}
        ${c.note ? `<div class="muted">${esc(c.note)}</div>` : ''}
        ${c.status === 'BILL_REQUESTED' ? `
          <div class="row" style="margin-top:.5rem">
            <input type="file" id="bill-${esc(c.claimId)}">
            <button class="primary" onclick="uploadBill('${esc(c.claimId)}', '${esc(c.workflowId)}')">Upload &amp; attach bill</button>
          </div>` : ''}
      </div>`).join('');
  shell(`
    <div class="card">
      <h3>Submit a claim</h3>
      <div class="row">
        <input type="number" id="amount" placeholder="Amount" style="width:9rem">
        <input type="text" id="desc" placeholder="What happened?" style="flex:1;min-width:14rem">
        <button class="primary" onclick="submitClaim()">Submit</button>
      </div>
      <div class="muted" style="margin-top:.4rem">A manager reviews every claim; you'll hear back here and in the bell.</div>
    </div>
    ${list}`);
}

window.submitClaim = async () => {
  const amount = parseFloat(document.getElementById('amount').value);
  const description = document.getElementById('desc').value;
  if (!amount || amount <= 0) return alert('An amount is required');
  // Trailing slash matters: nginx 301s '/api/claims' to '/api/claims/', and a
  // redirected POST arrives as a GET.
  const res = await api('/claims/', { method: 'POST', body: JSON.stringify({ amount, description }) });
  if (!res.ok) alert('Submit failed: ' + (await res.text()));
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

async function renderTasks() {
  const res = await api('/claims/tasks');
  const rows = res.ok ? await res.json() : [];
  const list = rows.length === 0
    ? '<div class="empty">Nothing waiting on you.</div>'
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
        <div class="row">${facts}</div>${bill}
        <div class="row" style="margin-top:.6rem">
          ${buttons}
          <input type="text" id="c-${esc(t.taskId)}" placeholder="Comment (optional)" style="flex:1;min-width:10rem">
        </div>
        <div class="muted" style="margin-top:.3rem">The full form, payload and history live in the ICP console — this is the fast lane.</div>
      </div>`;
    }).join('');
  shell(list);
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
    setInterval(refresh, 10000);
  } else {
    authBtn.onclick = signIn;
  }
})();
