// Settings › General › Weather › "Use the phone's location": while it is on, the place is what the phone app last
// reported, so the city and coordinates are shown read-only and the city search is hidden; off, they are editable
// again. Settings saved before the option existed (no "auto") follow the phone, as the agent reads them (Config.cs).
const { test, expect } = require('@playwright/test');

const config = (weather) => ({
  display: { language: 'en', theme: 'default' },
  pages: [],
  weather: { city: 'São Paulo', lat: -23.55, lon: -46.63, unit: 'celsius', model: '', ...weather },
});

async function seed(page, cfg) {
  await page.goto('/panel/style.css');
  await page.evaluate((c) => localStorage.setItem('pb-demo-config', JSON.stringify(c)), cfg);
  await page.goto('/settings/#general');
}

const fields = (page) => ['weather.city', 'weather.lat', 'weather.lon'].map((p) => page.locator(`[data-bind="${p}"]`));

test('with the phone location on, the place shows what the phone sent and cannot be typed over', async ({ page }) => {
  await seed(page, config({ auto: true }));
  const toggle = page.locator('[data-bind="weather.auto"]');
  await expect(toggle).toBeChecked();
  for (const f of fields(page)) await expect(f).toHaveJSProperty('readOnly', true);
  await expect(page.locator('[data-bind="weather.city"]')).toHaveValue('São Paulo');
  await expect(page.locator('[data-bind="weather.lat"]')).toHaveValue('-23.55');
  await expect(page.locator('#citySearch')).toBeHidden();
  await expect(page.locator('#weatherAutoHint')).toContainText('approximate location');

  await page.locator('label.switch', { has: toggle }).click(); // the input itself is hidden behind the switch
  await expect(toggle).not.toBeChecked();
  for (const f of fields(page)) await expect(f).toHaveJSProperty('readOnly', false);
  await expect(page.locator('#citySearch')).toBeVisible();
  await expect(page.locator('#cityBtn')).toBeEnabled();

  await page.locator('[data-bind="weather.city"]').fill('Campinas');
  await page.locator('#save').click();
  await expect(page.locator('#toast')).toHaveText(/^Saved/);
  await page.reload();
  await expect(page.locator('[data-bind="weather.auto"]')).not.toBeChecked();
  await expect(page.locator('[data-bind="weather.city"]')).toHaveValue('Campinas');
  await expect(page.locator('[data-bind="weather.city"]')).toHaveJSProperty('readOnly', false);
});

test('settings without the option follow the phone, and the switch reads in Brazilian Portuguese', async ({ page }) => {
  await seed(page, { ...config({}), display: { language: 'pt-BR', theme: 'default' } });
  const toggle = page.locator('[data-bind="weather.auto"]');
  await expect(toggle).toBeChecked();
  await expect(page.locator('#weatherAutoLabel')).toHaveText('Usar a localização do celular (automático)');
  for (const f of fields(page)) await expect(f).toHaveJSProperty('readOnly', true);
});
