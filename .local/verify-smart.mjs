// Bob chats his claim in; the agent files and estimates; "pay" parks on the accountant's
// gate; the gate is approved in the ICP; bob's chat says paid.
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
const require_ = createRequire(import.meta.url);
const dirs = execSync('ls -d ~/.npm/_npx/*/node_modules/playwright 2>/dev/null', { shell: '/bin/bash' }).toString().trim().split('\n').filter(Boolean);
const { chromium } = require_(dirs.find((d) => existsSync(d)));
const PORTAL = 'http://localhost:9090';
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 950 } });
const bob = await ctx.newPage();
bob.on('dialog', (d) => { console.log('DIALOG:', d.message().slice(0, 250)); d.accept().catch(() => {}); });
bob.on('response', async (r) => {
  if (r.url().includes('/api/agent/') && r.status() >= 400) {
    console.log('AGENT API', r.request().method(), r.url().split('/api')[1], '->', r.status(), (await r.text().catch(() => '')).slice(0, 200));
  }
});

const lastBubble = async () => (await bob.locator('#chatlog .card').last().innerText()).trim();

try {
  await bob.goto(PORTAL, { waitUntil: 'domcontentloaded' });
  await bob.getByRole('button', { name: 'Sign in' }).click();
  await bob.waitForURL((u) => String(u).includes('8090'), { timeout: 30000 });
  await bob.locator('input[type="text"]').first().fill('bob');
  await bob.locator('input[type="password"]').first().fill('bob12345');
  await bob.locator('button[type="submit"]').first().click();
  await bob.waitForURL((u) => String(u).startsWith(PORTAL), { timeout: 45000 });
  await bob.waitForTimeout(2500);
  await bob.getByRole('button', { name: 'Smart claim' }).click();
  console.log('1. bob is in the Smart claim chat');

  await bob.locator('#chatmsg').fill('Broke my laptop on a work trip, about $1200');
  await bob.getByRole('button', { name: 'Send' }).click();
  for (let i = 0; i < 40; i++) {
    await bob.waitForTimeout(3000);
    const t = await lastBubble();
    if (t && !t.includes('working')) break;
  }
  console.log('2. agent:', (await lastBubble()).slice(0, 140));

  await bob.locator('#chatmsg').fill('pay');
  await bob.getByRole('button', { name: 'Send' }).click();
  await bob.waitForTimeout(6000);
  console.log('3. after "pay":', (await lastBubble()).slice(0, 100));
  await bob.screenshot({ path: '.local/smart-pending.png' });
} catch (e) {
  await bob.screenshot({ path: '.local/smart-fail.png' }).catch(() => {});
  console.log('ERR', e.message.split('\n')[0]);
  process.exit(1);
}

// The accountant's gate, decided through the ICP tunnel.
try {
  const approve = execSync(`bash -c '
    CONSOLE="https://localhost:9664"
    token=$(curl -sk -X POST "$CONSOLE/auth/login" -H "Content-Type: application/json" -d "{\\"username\\":\\"admin\\",\\"password\\":\\"admin\\"}" | python3 -c "import json,sys; print(json.load(sys.stdin)[\\"token\\"])")
    cid=$(docker compose exec -T postgres psql -qtAX -U postgres -d icp_db -c "SELECT component_id FROM components WHERE name = chr(99)||chr(108)||chr(97)||chr(105)||chr(109)||chr(115)||chr(45)||chr(97)||chr(103)||chr(101)||chr(110)||chr(116)")
    ENV=750e8400-e29b-41d4-a716-446655440001
    for i in $(seq 1 30); do
      code=$(curl -sk -o /tmp/rv.json -w "%{http_code}" "$CONSOLE/icp/workflow/$cid/$ENV/review-activities?status=PENDING" -H "Authorization: Bearer $token")
      rid=$(python3 -c "import json;d=json.load(open(\\"/tmp/rv.json\\"));items=d.get(\\"items\\") or [];print(items[0][\\"taskId\\"] if items else \\"\\")" 2>/dev/null)
      [ -n "$rid" ] && break; sleep 3
    done
    [ -n "$rid" ] || { echo "NO_REVIEW"; exit 0; }
    code=$(curl -sk -o /tmp/rv2.json -w "%{http_code}" -X POST "$CONSOLE/icp/workflow/$cid/$ENV/review-activities/$rid/proceed" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "{}")
    op=$(python3 -c "import json;print(json.load(open(\\"/tmp/rv2.json\\")).get(\\"operationId\\",\\"\\"))" 2>/dev/null)
    for i in $(seq 1 30); do
      code=$(curl -sk -o /tmp/rv3.json -w "%{http_code}" "$CONSOLE/icp/workflow/$cid/$ENV/operations/$op" -H "Authorization: Bearer $token")
      [ "$code" != "202" ] && break; sleep 2
    done
    echo "APPROVED $code"
  '`).toString().trim();
  console.log('4. gate:', approve);
} catch (e) {
  console.log('4. gate ERR', String(e.message).slice(0, 200));
}

// Bob's pending bubble resolves.
try {
  for (let i = 0; i < 60; i++) {
    await bob.waitForTimeout(3000);
    const t = await lastBubble();
    if (t && !t.includes('working')) { console.log('5. agent:', t.slice(0, 140)); break; }
    if (i === 59) console.log('5. still pending');
  }
  await bob.screenshot({ path: '.local/smart-paid.png' });
} finally {
  await browser.close();
}
