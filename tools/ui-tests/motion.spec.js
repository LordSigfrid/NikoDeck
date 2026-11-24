const { test, expect } = require('@playwright/test');

// The panel's one-off animations (motion.js): numbers count to their new value, gauge rings and meter bars move there.
// The state polls every second, so they must end exactly where the widget's own formatting says, stop well before the
// next poll, stay still for what nobody sees (another page, a hidden panel) and not run at all when the system asks for
// less motion. Like the status pulses (status-pulses.spec.js), a running animation costs a frame on every refresh.
const RING = (pct) => {
  const c = 2 * Math.PI * 42;
  return `<svg viewBox="0 0 100 100"><circle class="fg" cx="50" cy="50" r="42" stroke-dasharray="${c.toFixed(1)}" stroke-dashoffset="${(c * (1 - pct / 100)).toFixed(1)}"/></svg>`;
};

async function load(page) {
  await page.goto('/panel/');
  await expect(page.locator('#dots i')).not.toHaveCount(0);
  await page.evaluate(() => import('/panel/motion.js'));
}
// a fixture outside the pager: it is not on any page, so it counts as on screen
const mount = (page, html) => page.evaluate((h) => {
  document.getElementById('motion-fixture')?.remove();
  const box = document.createElement('div');
  box.id = 'motion-fixture';
  box.style.cssText = 'position: fixed; left: 0; top: 0; width: 300px; height: 150px;';
  box.innerHTML = h;
  document.body.append(box);
}, html);
// motion.js animates from script (a plain Animation); a CSS transition elsewhere in the panel (a toast, the page title) is not its own
const fixtureAnimations = (page) => page.evaluate(() => [...document.querySelectorAll('#motion-fixture, #motion-fixture *')]
  .flatMap((e) => e.getAnimations()).filter((a) => a.constructor === Animation && a.playState === 'running').length);

test('a number counts to its new value and ends on the exact text', async ({ page }) => {
  await load(page);
  await mount(page, '<b class="n"></b>');
  const mid = await page.evaluate(async () => {
    const { tweenText } = await import('/panel/motion.js');
    const n = document.querySelector('#motion-fixture .n');
    tweenText(n, '12.5', '%');
    tweenText(n, '87.0', '%');
    await new Promise((r) => setTimeout(r, 100));
    return n.textContent;
  });
  expect(mid, 'it counts: the text is between the two values on the way').not.toBe('87.0');
  await page.waitForTimeout(1000);
  await expect(page.locator('#motion-fixture .n')).toHaveText('87.0');
});

test('a bare text node (the gauge\'s number) counts too and keeps updating', async ({ page }) => {
  await load(page);
  await mount(page, '<b class="n"></b>');
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.evaluate(async () => {
    const { tweenText } = await import('/panel/motion.js');
    const num = document.createTextNode('');
    document.querySelector('#motion-fixture .n').append(num);
    tweenText(num, '20');
    tweenText(num, '60');
  });
  await page.waitForTimeout(1000);
  await expect(page.locator('#motion-fixture .n')).toHaveText('60');
  expect(errors).toEqual([]);
});

test('a value that is not a plain number is set at once', async ({ page }) => {
  await load(page);
  await mount(page, '<b class="n"></b>');
  const shown = await page.evaluate(async () => {
    const { tweenText } = await import('/panel/motion.js');
    const n = document.querySelector('#motion-fixture .n');
    tweenText(n, '12');
    tweenText(n, '—');
    const dash = n.textContent;
    tweenText(n, '1,234');
    return [dash, n.textContent];
  });
  expect(shown).toEqual(['—', '1,234']);
});

test('a gauge ring and a bar end on their new value, and nothing runs a second after the update', async ({ page }) => {
  await load(page);
  await mount(page, `<div class="g-dial">${RING(10)}</div><div class="meters"><div class="track"><i style="width: 10%"></i></div></div>`);
  const started = await page.evaluate(async (ring) => {
    const { carryRing, barWidths, carryBars } = await import('/panel/motion.js');
    const dial = document.querySelector('#motion-fixture .g-dial');
    const old = dial.firstElementChild;
    dial.insertAdjacentHTML('afterbegin', ring);
    carryRing(old, dial.firstElementChild);
    old.remove();
    const list = document.querySelector('#motion-fixture .meters');
    const before = barWidths(list);
    list.innerHTML = '<div class="track"><i style="width: 80%"></i></div>';
    carryBars(list, before);
    return document.getAnimations().length;
  }, RING(80));
  expect(started, 'a big change moves').toBeGreaterThan(0);
  await page.waitForTimeout(1000);
  expect(await fixtureAnimations(page), 'EXPECTED: nothing still animating').toBe(0);
  const end = await page.evaluate(() => {
    const fg = document.querySelector('#motion-fixture .fg');
    return { ring: parseFloat(getComputedStyle(fg).strokeDashoffset), want: Number(fg.getAttribute('stroke-dashoffset')),
      bar: getComputedStyle(document.querySelector('#motion-fixture .track i')).transform };
  });
  expect(end.ring).toBeCloseTo(end.want, 1);
  expect(end.bar).toBe('none');
});

test('a small change (a poll\'s jitter) is set at once, with no animation', async ({ page }) => {
  await load(page);
  await mount(page, `<div class="g-dial">${RING(40)}</div><div class="meters"><div class="track"><i style="width: 40%"></i></div></div>`);
  const running = await page.evaluate(async (ring) => {
    const { carryRing, barWidths, carryBars } = await import('/panel/motion.js');
    const dial = document.querySelector('#motion-fixture .g-dial');
    const old = dial.firstElementChild;
    dial.insertAdjacentHTML('afterbegin', ring);
    carryRing(old, dial.firstElementChild);
    old.remove();
    const list = document.querySelector('#motion-fixture .meters');
    const before = barWidths(list);
    list.innerHTML = '<div class="track"><i style="width: 41%"></i></div>';
    carryBars(list, before);
    return [...document.querySelectorAll('#motion-fixture *')].flatMap((e) => e.getAnimations()).length;
  }, RING(41));
  expect(running).toBe(0);
});

test('nothing moves on a page that is not the one shown', async ({ page }) => {
  await load(page);
  await mount(page, `<section class="page"><div class="g-dial">${RING(10)}</div><b class="n"></b></section>`);
  const out = await page.evaluate(async (ring) => {
    const { carryRing, tweenText } = await import('/panel/motion.js');
    const dial = document.querySelector('#motion-fixture .g-dial');
    const old = dial.firstElementChild;
    dial.insertAdjacentHTML('afterbegin', ring);
    carryRing(old, dial.firstElementChild);
    old.remove();
    const n = document.querySelector('#motion-fixture .n');
    tweenText(n, '10');
    tweenText(n, '90');
    return { animations: [...document.querySelectorAll('#motion-fixture *')].flatMap((e) => e.getAnimations()).length, text: n.textContent };
  }, RING(90));
  expect(out).toEqual({ animations: 0, text: '90' });
});

test('with less motion asked for, nothing animates and the text is set at once', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await load(page);
  await mount(page, `<div class="g-dial">${RING(10)}</div><b class="n"></b>`);
  const out = await page.evaluate(async (ring) => {
    const { carryRing, pageIn, tweenText } = await import('/panel/motion.js');
    const dial = document.querySelector('#motion-fixture .g-dial');
    const old = dial.firstElementChild;
    dial.insertAdjacentHTML('afterbegin', ring);
    carryRing(old, dial.firstElementChild);
    old.remove();
    pageIn(document.querySelector('#pager').children[0], 1);
    const n = document.querySelector('#motion-fixture .n');
    tweenText(n, '10');
    tweenText(n, '90');
    return { animations: document.getAnimations().filter((a) => a.constructor === Animation).length, text: n.textContent };
  }, RING(90));
  expect(out).toEqual({ animations: 0, text: '90' });
  // the panel's own updates keep arriving: none of them animates either
  await page.waitForTimeout(2500);
  expect(await page.evaluate(() => document.getAnimations().filter((a) => a.constructor === Animation).length)).toBe(0);
});

test('a swipe to the next page does not replay its entrance', async ({ page }) => {
  await load(page);
  const replayed = await page.evaluate(async () => {
    const m = await import('/panel/main.js');
    const next = document.querySelector('#pager').children[m.curPage + 1];
    if (!next) return 0;
    let seen = 0;
    const watch = setInterval(() => {
      // the entrance is the only 600 ms (bars) and 700 ms (rings from empty) animation
      seen += next.getAnimations({ subtree: true }).filter((a) => [600, 700].includes(a.effect.getTiming().duration)).length;
    }, 30);
    m.goPage(m.curPage + 1);
    await new Promise((r) => setTimeout(r, 1200));
    clearInterval(watch);
    return seen;
  });
  expect(replayed, 'EXPECTED: no entrance on a swipe | ACTUAL: ' + replayed).toBe(0);
});
