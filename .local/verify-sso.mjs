// Jane signs into the ICP console through Thunder, and her MANAGER role shows her the tasks.
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
const require_ = createRequire(import.meta.url);
const dirs = execSync('ls -d ~/.npm/_npx/*/node_modules/playwright 2>/dev/null', { shell: '/bin/bash' }).toString().trim().split('\n').filter(Boolean);
const { chromium } = require_(dirs.find((d) => existsSync(d)));
const BASE = 'https://localhost:9664';
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1700, height: 1050 } });
const page = await ctx.newPage();
try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.screenshot({ path: '.local/sso-1-login.png' });
  const ssoBtn = page.getByRole('button', { name: /sso|single sign/i }).first();
  await ssoBtn.waitFor({ timeout: 20000 });
  console.log('1. SSO button present');
  await ssoBtn.click();
  await page.waitForURL((u) => String(u).includes('8090'), { timeout: 30000 });
  console.log('2. redirected to Thunder:', new URL(page.url()).pathname);
  await page.screenshot({ path: '.local/sso-2-thunder.png' });
  // Thunder's hosted login form
  await page.getByLabel(/username|email/i).first().or(page.locator('input[name="username"], input[type="text"]').first()).fill('jane');
  await page.locator('input[type="password"]').first().fill('jane12345');
  await page.locator('button[type="submit"]').first().click();
  await page.waitForURL((u) => String(u).includes('9664'), { timeout: 45000 });
  console.log('3. back on the console:', new URL(page.url()).pathname);
  await page.waitForTimeout(6000);
  await page.screenshot({ path: '.local/sso-3-console.png' });
  // Navigate to the claims Human Tasks page — jane should see pending reviews.
  await page.goto(`${BASE}/organizations/default/projects/claimflow/components/claims/workflow-tasks`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForTimeout(8000);
  await page.screenshot({ path: '.local/sso-4-tasks.png' });
  const rows = await page.getByText(/Review claim|Approve payment/).count();
  console.log('4. task rows visible to jane:', rows);
} catch (e) {
  await page.screenshot({ path: '.local/sso-fail.png' }).catch(() => {});
  console.log('ERR', e.message.split('\n')[0]);
  process.exitCode = 1;
} finally {
  await browser.close();
}
