// The default language: a config that names no language shows the panel in Brazilian Portuguese, and "auto" follows the
// browser's languages. The demo serves a language-less config as English under test (see TEST in tools/pages/demo.js),
// so the first check answers the panel's config request itself, the way an agent with no language saved would.
const { test, expect } = require('@playwright/test');

const LAYOUT = { id: 'one', title: 'One', enabled: true, widgets: [
  { id: 'n1', type: 'note', x: 0, y: 0, w: 6, h: 3, options: { text: 'hello', color: '#fbbf24' } },
] };

// a stored demo config, read by the demo's own /api/config
async function openPanel(page, display) {
  await page.goto('/panel/style.css');
  await page.evaluate(({ display, layout }) => {
    localStorage.clear();
    localStorage.setItem('pb-demo-config', JSON.stringify({
      night: { enabled: false }, rules: [], shortcuts: [], ...(display ? { display } : {}), pages: [layout],
    }));
  }, { display, layout: LAYOUT });
  await page.goto('/panel/');
  await expect(page.locator('.note-t')).toHaveText('hello');
}

test('a config without a language shows the panel in Brazilian Portuguese', async ({ page }) => {
  await page.addInitScript((layout) => {
    try { localStorage.removeItem('pb-lang'); } catch (_) {}
    // what the agent sends when display.language was never saved; answered before the demo installs its own fetch
    // mock (the setter keeps that one as the fallback for every other request)
    const body = JSON.stringify({ version: 1, config: {
      night: { enabled: false }, display: {}, pages: [layout], shortcuts: [], rules: [], charge: { enabled: false, min: 50, max: 80 },
    } });
    let inner = window.fetch;
    Object.defineProperty(window, 'fetch', {
      configurable: true,
      // the fallback is fixed when the wrapper is handed out: demo.js keeps the first one as its "real" fetch, and a
      // wrapper that looked up the live mock would send the demo's pass-through requests back to the demo forever
      get: () => {
        const fallback = inner;
        return (input, init) => {
          const url = new URL(typeof input === 'string' ? input : input.url, location.href);
          if (url.pathname.endsWith('/api/config')) {
            return Promise.resolve(new Response(body, { status: 200, headers: { 'Content-Type': 'application/json' } }));
          }
          return fallback(input, init);
        };
      },
      set: (v) => { inner = v; },
    });
  }, LAYOUT);
  await page.goto('/panel/');
  await expect(page.locator('.note-t')).toHaveText('hello');
  await expect(page.locator('html')).toHaveAttribute('lang', 'pt-BR');
  expect(await page.evaluate(() => [window.PhoneBoxI18n.getPref(), window.PhoneBoxI18n.getLang()])).toEqual(['pt-BR', 'pt-BR']);
});

test('under test the demo serves a config without a language as English', async ({ page }) => {
  await openPanel(page, null);
  await expect(page.locator('html')).toHaveAttribute('lang', 'en');
});

test.describe('follow system', () => {
  test.use({ locale: 'de-DE' });

  test('"auto" follows the browser\'s languages, not the default', async ({ page }) => {
    await openPanel(page, { language: 'auto' });
    await expect(page.locator('html')).toHaveAttribute('lang', 'de');
    expect(await page.evaluate(() => window.PhoneBoxI18n.getPref())).toBe('auto');
  });
});
