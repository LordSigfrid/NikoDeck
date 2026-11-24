const { test, expect } = require('@playwright/test');

// The Visor widget (widgets/visor.js): one PC metric at a time in big numbers inside a ring, cycling through the chosen
// metrics, over a background effect that only moves while the widget is on screen and the system allows motion.
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');

async function show(page, options = {}, config = {}) {
  await page.goto('/panel/style.css');
  await page.evaluate(({ options, config }) => {
    localStorage.clear();
    localStorage.setItem('pb-demo-config', JSON.stringify({ night: { enabled: false }, shortcuts: [],
      pages: [
        { id: 'visor', title: 'Visor', widgets: [{ id: 'visor', type: 'visor', x: 0, y: 0, w: 12, h: 6, options }] },
        { id: 'other', title: 'Other', widgets: [{ id: 'note', type: 'note', x: 0, y: 0, w: 6, h: 6, options: { text: 'Another page' } }] },
      ],
      ...config, display: { idleReturnSec: 0, ...(config.display || {}) } }));
  }, { options, config });
  await page.goto('/panel/');
  await expect(page.locator('.w-visor')).toBeVisible();
}
const visor = (page) => page.locator('.w-visor');
// animations inside the widget that are producing frames right now (CSS loops, transitions, motion.js carries)
const running = (page) => page.locator('.w-visor').evaluate((box) =>
  [box, ...box.querySelectorAll('*')].flatMap((e) => e.getAnimations()).filter((a) => a.playState === 'running').length);

test('shows the chosen metric in big numbers with its label, its ring and a secondary line', async ({ page }) => {
  await show(page, { metrics: ['cpu'], cycle: 0, background: 'none' });
  await expect(visor(page).locator('.vz-label')).toHaveText('CPU');
  await expect(visor(page).locator('.vz-num')).toHaveText(/^\d+$/);
  await expect(visor(page).locator('.vz-unit')).toHaveText('%');
  await expect(visor(page).locator('.vz-dial svg .fg')).toHaveCount(1);
  // the demo's CPU reports a temperature and a power draw
  await expect(visor(page).locator('.vz-sub')).toHaveText(/\d+°C · \d+ W/);
  await expect(visor(page)).toHaveAttribute('data-level', 'cool');
});

test('the ring turns orange, then red, at the thresholds', async ({ page }) => {
  // every demo load is over 1%: hot at once
  await show(page, { metrics: ['cpu'], cycle: 0, background: 'none', loadWarm: 0, loadHot: 1 });
  await expect(visor(page)).toHaveAttribute('data-level', 'hot');
  await expect.poll(() => visor(page).locator('.vz-dial svg .fg').evaluate((el) => getComputedStyle(el).stroke)).toBe('rgb(255, 54, 93)');
  // the demo's CPU stays between 52 and 68 °C: warm from 0, hot only from 150
  await show(page, { metrics: ['cputemp'], cycle: 0, background: 'none', tempWarm: 0, tempHot: 150 });
  await expect(visor(page)).toHaveAttribute('data-level', 'warm');
  await expect(visor(page).locator('.vz-unit')).toHaveText('°C');
});

test('cycles through the metrics on its own', async ({ page }) => {
  await show(page, { metrics: ['cpu', 'gpu'], cycle: 1, background: 'none' });
  await expect(visor(page)).toHaveAttribute('data-metric', 'cpu');
  await expect(visor(page)).toHaveAttribute('data-metric', 'gpu', { timeout: 5000 });
  await expect(visor(page).locator('.vz-label')).toHaveText('GPU');
  await expect(visor(page)).toHaveAttribute('data-metric', 'cpu', { timeout: 5000 });
});

test('a tap goes to the next metric, and with cycling off nothing else moves it', async ({ page }) => {
  await show(page, { metrics: ['cpu', 'ram'], cycle: 0, background: 'none' });
  await expect(visor(page)).toHaveAttribute('data-metric', 'cpu');
  await visor(page).click();
  await expect(visor(page)).toHaveAttribute('data-metric', 'ram');
  await expect(visor(page).locator('.vz-label')).toHaveText('RAM');
  await page.waitForTimeout(2500);
  await expect(visor(page)).toHaveAttribute('data-metric', 'ram');
  await visor(page).click();
  await expect(visor(page)).toHaveAttribute('data-metric', 'cpu');
});

test('bad options fall back to the defaults', async ({ page }) => {
  await show(page, { metrics: ['nosuchmetric'], cycle: 'soon', background: 'lava', dim: 900 });
  await expect(visor(page)).toHaveAttribute('data-bg', 'particles');
  await expect(visor(page)).toHaveAttribute('data-metric', 'cpu');
  expect(await page.locator('.w > .empty').count()).toBe(0);
});

for (const background of ['particles', 'waves', 'grid', 'pulse']) {
  test(`the ${background} effect runs only while its page is shown`, async ({ page }) => {
    await show(page, { metrics: ['cpu'], cycle: 0, background });
    await expect(visor(page)).toHaveAttribute('data-fx', 'running');
    await expect.poll(() => running(page)).toBeGreaterThan(0);
    await page.keyboard.press('ArrowRight'); // the Visor's page is now a neighbour: mounted, not shown
    await expect(page.locator('.w-note')).toBeInViewport();
    await expect(visor(page)).toHaveAttribute('data-fx', 'paused');
    await expect.poll(() => running(page)).toBe(0);
    await page.keyboard.press('ArrowLeft');
    await expect(visor(page)).toHaveAttribute('data-fx', 'running');
    await expect.poll(() => running(page)).toBeGreaterThan(0);
  });
}

test('the effect stops while the panel is hidden', async ({ page }) => {
  await show(page, { metrics: ['cpu'], cycle: 0, background: 'particles' });
  await expect(visor(page)).toHaveAttribute('data-fx', 'running');
  // the Android shell reports a paused app (screen off, another app in front) through window.onAppPause
  await page.evaluate(() => window.onAppPause(true));
  await expect(visor(page)).toHaveAttribute('data-fx', 'paused');
  await expect.poll(() => running(page)).toBe(0);
  await page.evaluate(() => window.onAppPause(false));
  await expect(visor(page)).toHaveAttribute('data-fx', 'running');
});

test('with reduced motion the background stands still and the metric changes without a crossfade', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await show(page, { metrics: ['cpu', 'gpu'], cycle: 0, background: 'particles' });
  await expect(visor(page)).toHaveAttribute('data-fx', 'paused');
  await page.waitForTimeout(1500); // a few state polls
  expect(await running(page)).toBe(0);
  // still a frame of dots, not an empty backdrop
  await expect(visor(page).locator('.vz-particles i')).not.toHaveCount(0);
  await visor(page).click();
  await expect(visor(page)).toHaveAttribute('data-metric', 'gpu');
  await expect(visor(page).locator('.vz-face')).not.toHaveClass(/out/);
  expect(await running(page)).toBe(0);
});

test('the uploaded media is drawn behind the numbers, darkened', async ({ page }) => {
  const asked = [];
  await page.route('**/agent/api/visor-media*', (route) => { asked.push(route.request().url()); route.fulfill({ body: PNG, contentType: 'image/png' }); });
  // a revision past 2^53, sent as text like the wallpaper's
  await show(page, { metrics: ['cpu'], cycle: 0, background: 'media', dim: 60 }, { visorMediaRev: '9019088123725100163' });
  await expect(visor(page).locator('img.vz-media')).toHaveAttribute('src', /^blob:/);
  expect(asked.some((u) => u.includes('/agent/api/visor-media?v=9019088123725100163'))).toBe(true);
  await expect(visor(page)).toHaveClass(/vz-has-media/);
  await expect(visor(page).locator('.vz-dim')).toBeVisible();
  expect(await visor(page).evaluate((el) => el.style.getPropertyValue('--vz-dim'))).toBe('0.6');
});

test('without an upload the media background is a plain backdrop and asks for nothing', async ({ page }) => {
  const asked = [];
  await page.route('**/agent/api/visor-media*', (route) => { asked.push(route.request().url()); route.fulfill({ status: 404, body: '' }); });
  await show(page, { metrics: ['cpu'], cycle: 0, background: 'media' });
  await expect(visor(page).locator('.vz-none')).toHaveCount(1);
  await expect(visor(page).locator('.vz-media')).toHaveCount(0);
  await page.waitForTimeout(1500);
  expect(asked).toEqual([]);
});

test('the settings editor offers the media upload only for the media background and keeps the metrics in ticked order', async ({ page }) => {
  await page.goto('/settings/');
  await expect(page.locator('#save')).toBeVisible();
  const out = await page.evaluate(() => {
    const d = widgetDef('visor');
    const media = d.options.find((o) => o.key === 'media');
    const shown = (background) => optionShown({ type: 'visor', options: { background } }, d, media);
    const w = { type: 'visor', options: { metrics: ['cpu'] } };
    const field = optionField(w, d.options.find((o) => o.key === 'metrics'), () => {});
    document.body.append(field);
    const tick = (id) => [...field.querySelectorAll('label.check')].find((l) => l.querySelector('input') && l.textContent.includes(id))?.querySelector('input').click();
    tick('RAM');
    tick('GPU load');
    const order = [...w.options.metrics];
    field.remove();
    return { particles: shown('particles'), media: shown('media'), order };
  });
  expect(out.particles).toBe(false);
  expect(out.media).toBe(true);
  expect(out.order).toEqual(['cpu', 'ram', 'gpu']);
});
