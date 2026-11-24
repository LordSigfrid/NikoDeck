// PhoneBox desk panel: the short, one-off animations (page turns, values, gauges, bars). A leaf module with no imports,
// so main.js and the widgets can both use it without an import cycle.
// Only transform, opacity and a gauge's stroke-dashoffset move, through the Web Animations API: nothing here runs a
// frame once its animation is over (a running animation costs a frame on every display refresh, see the status pulses).
// The Web Animations API in Chromium 83 needs both keyframes, so every animation names its start and its end.

const reduceQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
/** Whether the user asked the system for less motion; read on every call, so a change applies without a reload. */
export const reducedMotion = () => !!reduceQuery?.matches;

// The state polls every second and its values change on almost every poll, so only what the user can see moves: the
// page main.js shows (the neighbours it keeps updated are off screen), and nothing while the panel is hidden.
let shownPage = null;
/** main.js names the page on screen at every page turn. */
export const setShownPage = (section) => { shownPage = section || null; };
const onScreen = (el) => {
  if (!el?.isConnected || document.hidden) return false;
  // tweenText also gets bare Text nodes (the gauge's number), which have no closest()
  const page = (el.nodeType === 1 ? el : el.parentElement)?.closest('.page');
  return !page || page === shownPage;
};
const canAnimate = (el) => !!el && typeof el.animate === 'function' && !reducedMotion() && onScreen(el);
const EASE_OUT = 'cubic-bezier(.2, .8, .2, 1)';
// element -> its running carry, so a new value that lands mid-animation starts from what is shown, not the old target
const running = new WeakMap();
const play = (el, keyframes, opts) => {
  const a = el.animate(keyframes, opts);
  running.set(el, a);
  return a;
};
const isRunning = (el) => running.get(el)?.playState === 'running';

// ---------------------------------------------------------------- numbers
const NUMBER = /^-?\d+(?:\.(\d+))?$/;
const TWEEN_MS = 400;
const tweens = new WeakMap(); // node -> { cur, to, dec, unit, raf }

/**
 * Sets node's text to text, counting there from the number it shows when both are plain numbers with the same
 * decimals and unit. Anything else (a dash, a thousands separator, another unit, the first value) is set at once, so
 * the text always ends exactly as the caller formatted it.
 */
export function tweenText(node, text, unit = '') {
  text = String(text);
  const m = NUMBER.exec(text);
  const to = m ? Number(text) : NaN, dec = m ? (m[1] || '').length : -1;
  const prev = tweens.get(node);
  if (prev?.raf && prev.to === to && prev.dec === dec && prev.unit === unit) return; // already on its way there
  if (prev?.raf) cancelAnimationFrame(prev.raf);
  const state = { cur: to, to, dec, unit, raf: 0 };
  tweens.set(node, state);
  if (!m || !prev || Number.isNaN(prev.cur) || prev.dec !== dec || prev.unit !== unit || prev.cur === to || reducedMotion()
    || typeof requestAnimationFrame !== 'function' || !onScreen(node)) {
    node.textContent = text;
    return;
  }
  const from = prev.cur;
  let start = 0;
  const step = (now) => {
    if (!start) start = now;
    const k = Math.min(1, (now - start) / TWEEN_MS);
    if (k >= 1) { state.raf = 0; state.cur = to; node.textContent = text; return; }
    state.cur = from + (to - from) * (1 - Math.pow(1 - k, 3));
    const shown = state.cur.toFixed(dec);
    node.textContent = /^-0(\.0*)?$/.test(shown) ? shown.slice(1) : shown;
    state.raf = requestAnimationFrame(step);
  };
  state.raf = requestAnimationFrame(step);
}

// ---------------------------------------------------------------- gauges and bars
const offsetOf = (fg) => Number(fg?.getAttribute('stroke-dashoffset'));
const lengthOf = (fg) => Number(fg?.getAttribute('stroke-dasharray'));
// what an arc shows now: mid-carry that is the animated value (a style read, no layout), otherwise its attribute
const shownOffset = (fg) => (fg && isRunning(fg) ? parseFloat(getComputedStyle(fg).strokeDashoffset) : offsetOf(fg));

/**
 * The gauges draw a new ring SVG on every update; this moves the new ring's arc from where the old one stands (or from
 * empty, the first time) instead of jumping there. Call it before the old ring is removed, so a carry still running
 * on it can be read. A move under `min` of the ring (a few seconds of a timer, a poll's jitter) is set at once.
 */
export function carryRing(oldSvg, newSvg, min = 0.02) {
  const fg = newSvg?.querySelector?.('.fg');
  if (!canAnimate(fg)) return;
  const len = lengthOf(fg), to = offsetOf(fg), from = oldSvg ? shownOffset(oldSvg.querySelector('.fg')) : len;
  if (!Number.isFinite(to) || !Number.isFinite(from) || !(Math.abs(from - to) >= Math.max(0.5, len * min))) return;
  play(fg, [{ strokeDashoffset: String(from) }, { strokeDashoffset: String(to) }], { duration: oldSvg ? 450 : 700, easing: EASE_OUT });
}

/**
 * The widths (in %) the bars under parent show: their inline width, scaled by a carry still running on them. Read from
 * their style, which costs no layout.
 */
export const barWidths = (parent, sel = '.track > i') => [...parent.querySelectorAll(sel)].map((i) => {
  const w = parseFloat(i.style.width);
  if (!isRunning(i)) return w;
  const m = /^matrix\(([^,]+),/.exec(getComputedStyle(i).transform);
  return m ? w * Number(m[1]) : w;
});

/**
 * The meter widgets rebuild their rows on every update; this grows each new bar from the width the bar at the same
 * place had (`before`, from barWidths) with a scaleX, so the move stays on the compositor. When the rows changed
 * (a disk or a GPU row came or went) the places no longer match, and the bars are set at once.
 */
export function carryBars(parent, before, sel = '.track > i') {
  if (reducedMotion()) return;
  const bars = parent.querySelectorAll(sel);
  if (bars.length !== before.length) return;
  bars.forEach((bar, n) => {
    const to = parseFloat(bar.style.width), from = before[n];
    if (!(to > 0) || !(from >= 0) || Math.abs(from - to) < 2 || !canAnimate(bar)) return;
    play(bar, [{ transform: `scaleX(${from / to})` }, { transform: 'none' }], { duration: 450, easing: EASE_OUT });
  });
}

// ---------------------------------------------------------------- pages
/**
 * Plays a page's entrance: its gauges fill from empty, its bars grow and its charts rise. With `dir` (+1 forward,
 * -1 back) the page's grid also slides in from that side; that is for jumps, a swipe already moves the page itself.
 */
export function pageIn(section, dir = 0) {
  if (!section || reducedMotion()) return;
  const grid = section.firstElementChild;
  if (dir && canAnimate(grid)) {
    grid.animate([{ opacity: 0.35, transform: `translateX(${dir > 0 ? 32 : -32}px)` }, { opacity: 1, transform: 'none' }],
      { duration: 300, easing: EASE_OUT });
  }
  section.querySelectorAll('.g-dial svg .fg').forEach((fg) => carryRing(null, fg.ownerSVGElement));
  section.querySelectorAll('.track > i').forEach((bar) => {
    if (parseFloat(bar.style.width) > 0 && canAnimate(bar)) play(bar, [{ transform: 'scaleX(0)' }, { transform: 'none' }], { duration: 600, easing: EASE_OUT });
  });
  // transform only: a stat tile draws its chart at half opacity, which an opacity keyframe would override
  section.querySelectorAll('.w-stat canvas, .w-chart canvas').forEach((c) => {
    if (canAnimate(c)) c.animate([{ transform: 'scaleY(0)' }, { transform: 'none' }], { duration: 500, easing: EASE_OUT });
  });
}
