// The whole portal story: alice submits, jane asks for and approves the bill,
// john releases the payment, alice sees PAID — all in the Claimflow portal.
import { existsSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
const require_ = createRequire(import.meta.url);
const dirs = execSync('ls -d ~/.npm/_npx/*/node_modules/playwright 2>/dev/null', { shell: '/bin/bash' }).toString().trim().split('\n').filter(Boolean);
const { chromium } = require_(dirs.find((d) => existsSync(d)));
const PORTAL = 'http://localhost:9090';
const browser = await chromium.launch({ channel: 'chrome', headless: true });

async function signIn(user, pass) {
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 950 } });
  const page = await ctx.newPage();
  await page.goto(PORTAL, { waitUntil: 'domcontentloaded' });
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => String(u).includes('8090'), { timeout: 30000 });
  await page.getByLabel(/username|email/i).first().or(page.locator('input[name="username"], input[type="text"]').first()).fill(user);
  await page.locator('input[type="password"]').first().fill(pass);
  await page.locator('button[type="submit"]').first().click();
  await page.waitForURL((u) => String(u).startsWith(PORTAL), { timeout: 45000 });
  await page.waitForTimeout(2500);
  return page;
}

try {
  // 1. alice submits
  const alice = await signIn('alice', 'alice12345');
  alice.on('response', async (r) => {
    if (r.url().includes('/api/claims') && r.request().method() === 'POST') {
      console.log('POST /api/claims ->', r.status(), (await r.text().catch(() => '')).slice(0, 300));
    }
  });
  await alice.locator('#amount').fill('1800');
  await alice.locator('#desc').fill('Cracked phone screen on holiday');
  alice.on('dialog', (d) => { console.log('DIALOG:', d.message().slice(0, 200)); d.accept().catch(() => {}); });
  const [submitResp] = await Promise.all([
    alice.waitForResponse((r) => r.url().includes('/api/claims/') && r.request().method() === 'POST', { timeout: 30000 }),
    alice.getByRole('button', { name: 'Submit' }).click(),
  ]);
  console.log('1a. submit ->', submitResp.status());
  // The durable record appears once the workflow's first activity runs; reload until the
  // new claim (top of the list, hex id) is there.
  let claimId = '';
  for (let i = 0; i < 15 && !claimId; i++) {
    await alice.waitForTimeout(3000);
    await alice.reload(); await alice.waitForTimeout(1500);
    const first = alice.locator('.card h3').nth(1); // nth(0) is the submit form's own heading
    const t = (await first.innerText().catch(() => '')).trim();
    if (/^CLM-[A-F0-9]{8}$/.test(t)) claimId = t;
  }
  if (!claimId) throw new Error('the new claim never appeared in My claims');
  console.log('1. alice submitted', claimId);

  // 2. jane requests the bill
  const jane = await signIn('jane', 'jane12345');
  jane.on('response', async (r) => {
    if (r.url().includes('/api/claims/tasks') && r.request().method() === 'GET') {
      console.log('GET tasks ->', r.status(), (await r.text().catch(() => '')).slice(0, 300));
    }
  });
  await jane.getByRole('button', { name: 'Decisions' }).click();
  const card = jane.locator('.card', { hasText: claimId }).first();
  await card.waitFor({ timeout: 30000 });
  await card.locator(`#c-${await card.evaluate((el) => el.querySelector('input[id^="c-"]').id.slice(2))}`).fill('Need the receipt, please');
  await card.getByRole('button', { name: 'Request bill' }).click();
  await jane.waitForTimeout(3000);
  console.log('2. jane requested the bill');

  // 3. alice uploads + attaches
  await alice.reload(); await alice.waitForTimeout(3000);
  const aliceCard = alice.locator('.card', { hasText: claimId }).first();
  await aliceCard.getByText('BILL REQUESTED').waitFor({ timeout: 40000 });
  writeFileSync('.local/receipt.txt', `Receipt for ${claimId}: $1800, phone screen.`);
  await aliceCard.locator('input[type="file"]').setInputFiles('.local/receipt.txt');
  await aliceCard.getByRole('button', { name: /Upload/ }).click();
  await alice.waitForTimeout(4000);
  console.log('3. alice uploaded and attached the bill');
  await alice.screenshot({ path: '.local/portal-alice-billreq.png' });

  // 4. jane approves (the review returns with the bill)
  await jane.reload(); await jane.waitForTimeout(2500);
  await jane.getByRole('button', { name: 'Decisions' }).click();
  const card2 = jane.locator('.card', { hasText: claimId }).first();
  await card2.waitFor({ timeout: 40000 });
  await card2.getByText(/bill:/).waitFor({ timeout: 30000 });
  await card2.getByRole('button', { name: 'Approve', exact: true }).click();
  await jane.waitForTimeout(3000);
  console.log('4. jane approved with the bill in view');
  await jane.screenshot({ path: '.local/portal-jane.png' });

  // 5. john releases the payment
  const john = await signIn('john', 'john12345');
  await john.getByRole('button', { name: 'Decisions' }).click();
  const payCard = john.locator('.card', { hasText: claimId }).first();
  await payCard.waitFor({ timeout: 40000 });
  await payCard.getByRole('button', { name: 'Approve payment' }).click();
  await john.waitForTimeout(3000);
  console.log('5. john approved the payment');

  // 6. alice sees PAID + the notification
  await alice.reload(); await alice.waitForTimeout(4000);
  await alice.locator('.card', { hasText: claimId }).first().getByText('PAID', { exact: true }).waitFor({ timeout: 40000 });
  await alice.locator('#bellBtn').click();
  await alice.getByText(new RegExp(`Claim ${claimId} paid`)).waitFor({ timeout: 15000 });
  console.log('6. alice sees PAID and the inbox says so');
  await alice.screenshot({ path: '.local/portal-alice-paid.png' });
} catch (e) {
  console.log('ERR', e.message.split('\n')[0]);
  process.exitCode = 1;
} finally {
  await browser.close();
}
