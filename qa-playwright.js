const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

(async () => {
  const screenshotsDir = path.join(__dirname, 'qa-screenshots');
  fs.mkdirSync(screenshotsDir, { recursive: true });

  const browser = await chromium.launch({ headless: true });
  const results = [];

  // Get session tokens via curl (avoids browser rate limiting)
  function getCookies(cookieFile) {
    const content = fs.readFileSync(cookieFile, 'utf8');
    const cookies = [];
    for (const line of content.split('\n')) {
      // Skip blank lines and comment lines that are NOT HttpOnly markers
      if (!line.trim() || (line.startsWith('#') && !line.startsWith('#HttpOnly_'))) continue;
      const parts = line.split('\t');
      if (parts.length < 7) continue;
      const isHttpOnly = line.startsWith('#HttpOnly_');
      cookies.push({
        name: parts[5],
        value: parts[6].trim(),
        // Use url instead of domain so Playwright correctly scopes to localhost
        url: 'http://localhost:3000',
        httpOnly: isHttpOnly,
        secure: parts[3] === 'TRUE',
      });
    }
    return cookies;
  }

  async function checkPage(browser, cookies, pagePath, label, contextOpts = {}) {
    const ctx = await browser.newContext(contextOpts);
    // Set cookies to simulate logged-in session
    if (cookies.length > 0) {
      await ctx.addCookies(cookies);
    }
    const page = await ctx.newPage();
    let result = { path: pagePath };
    try {
      await page.goto('http://localhost:3000' + pagePath, { waitUntil: 'load', timeout: 20000 });
      await page.waitForTimeout(2000);
      const title = await page.title();
      const body = await page.textContent('body');
      const hasError = body.includes('Something went wrong');
      const isBlank = body.trim().length < 50;
      const hasNav = await page.locator('nav, aside, [class*="sidebar"], [role="navigation"]').count() > 0;
      await page.screenshot({ path: path.join(screenshotsDir, label + '.png'), fullPage: true });
      result = { path: pagePath, title, hasError, isBlank, hasNav, bodyLength: body.trim().length, finalUrl: page.url() };
    } catch (err) {
      await page.screenshot({ path: path.join(screenshotsDir, label + '_error.png'), fullPage: true }).catch(() => {});
      result = { path: pagePath, error: err.message };
    }
    await ctx.close();
    return result;
  }

  // --- Login page (no cookies) ---
  results.push(await checkPage(browser, [], '/login', '_login'));

  // --- Tenant pages (qa5 user with admin role) ---
  const qa5Cookies = getCookies(path.join(__dirname, 'qa5-cookies.txt'));
  for (const { pagePath, label } of [
    { pagePath: '/', label: 'home' },
    { pagePath: '/projects', label: 'projects' },
    { pagePath: '/history', label: 'history' },
    { pagePath: '/validation', label: 'validation' },
  ]) {
    results.push(await checkPage(browser, qa5Cookies, pagePath, label));
  }

  // --- Admin page (super-admin) ---
  const saCookies = getCookies(path.join(__dirname, 'qa-sa-cookies.txt'));
  results.push(await checkPage(browser, saCookies, '/admin', '_admin'));

  await browser.close();
  console.log(JSON.stringify(results, null, 2));
})();
