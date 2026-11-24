// Visor: a whole page as a water-cooler LCD. One PC metric at a time in big glowing numbers inside a ring gauge whose
// colour follows the thresholds (cool, warm, hot), cycling through the chosen metrics, over an animated background:
// a built-in effect or the user's own picture, GIF or short video (uploaded in the settings page, like the wallpaper).
// The effects are CSS transform / opacity loops, so they stay on the compositor; they run only while the widget is
// really on screen (its page shown, the panel visible, no night screen, not a hidden Smart Stack card) and never with
// reduced motion, which leaves a still frame. A video is paused then, and a GIF is swapped for a still copy of its frame.
import { API, D, PANEL_HEADERS, cfg, curPage, gpuOf, gpuPower, h, haptic, idle, pages, r1, ringSvg, tp } from '../main.js';
import { W } from '../registry.js';
import { carryRing, reducedMotion, tweenText } from '../motion.js';

const join = (...parts) => parts.filter(Boolean).join(' · ');
const deg = (v) => (v == null ? null : `${Math.round(v)}°C`);
const watts = (v) => (v == null ? null : `${Math.round(v)} W`);
const pct = (v) => (v == null ? null : `${Math.round(v)}%`);
const ramPct = (s) => (s.pc?.ramTotalGb ? (s.pc.ramUsedGb / s.pc.ramTotalGb) * 100 : null);

// the metrics a Visor can show; `temp` ones use the temperature thresholds, the others the load ones
const KINDS = {
  cpu: { label: 'CPU', unit: '%', val: (s) => s.pc?.cpu, sub: (s) => join(deg(s.pc?.cpuTemp), watts(s.pc?.cpuPower)) },
  gpu: { label: 'GPU', unit: '%', val: (s) => gpuOf(s)?.util, sub: (s) => { const g = gpuOf(s); return join(deg(g?.temp), gpuPower(g)); } },
  cputemp: { label: 'CPU TEMP', unit: '°C', temp: true, val: (s) => s.pc?.cpuTemp, sub: (s) => join(pct(s.pc?.cpu), watts(s.pc?.cpuPower)) },
  gputemp: { label: 'GPU TEMP', unit: '°C', temp: true, val: (s) => gpuOf(s)?.temp, sub: (s) => { const g = gpuOf(s); return join(pct(g?.util), gpuPower(g)); } },
  ram: { label: 'RAM', unit: '%', val: ramPct, sub: (s) => (s.pc?.ramTotalGb ? `${r1(s.pc.ramUsedGb)} / ${Math.round(s.pc.ramTotalGb)} GB` : '') },
};
const EFFECTS = ['particles', 'waves', 'grid', 'pulse', 'none', 'media'];
const PARTICLES = 14; // few and small: each one is a compositor layer on an old phone

const num = (v, def, lo, hi) => (v !== null && v !== '' && Number.isFinite(+v) ? Math.min(hi, Math.max(lo, +v)) : def);

/** The widget's options, with bad values put right (the settings file can be edited by hand). */
export function visorOptions(o = {}) {
  const metrics = [...new Set((Array.isArray(o.metrics) ? o.metrics : []).filter((m) => Object.prototype.hasOwnProperty.call(KINDS, m)))];
  const pair = (warm, hot, dw, dh) => { const a = num(warm, dw, 0, 150), b = num(hot, dh, 0, 150); return a <= b ? [a, b] : [b, a]; };
  return {
    metrics: metrics.length ? metrics : ['cpu', 'cputemp', 'gpu', 'gputemp', 'ram'],
    cycleMs: Math.round(num(o.cycle, 8, 0, 600)) * 1000,
    background: EFFECTS.includes(o.background) ? o.background : 'particles',
    dim: num(o.dim, 45, 0, 90) / 100,
    accent: /^#[0-9a-f]{6}$/i.test(o.accent || '') ? o.accent : '',
    temp: pair(o.tempWarm, o.tempHot, 60, 80),
    load: pair(o.loadWarm, o.loadHot, 70, 90),
  };
}

// ---------------------------------------------------------------- the uploaded media, shared by every Visor
// Fetched as a blob, so the request carries the panel's headers and a video plays from memory (an intercepted request
// cannot answer the range requests a <video> makes). One copy per revision, counted by the Visors that hold it (the one
// shown, or the one being loaded): the last one to let go frees the memory, so a video is not kept once no Visor is
// mounted, or once the media was removed or replaced. A failed load is tried again later and later (2 s up to a minute).
const media = new Map(); // rev -> { rev, users, url, promise }
let failed = { rev: null, delay: 0, until: 0 };
const retryLater = (rev) => rev === failed.rev && Date.now() < failed.until;
function acquireMedia(rev) {
  let m = media.get(rev);
  if (!m) {
    m = { rev, users: 0, url: null };
    const entry = m;
    m.promise = fetch(`${API}/visor-media?v=${encodeURIComponent(String(rev))}`, { headers: PANEL_HEADERS })
      .then((r) => { if (!r.ok) throw new Error('HTTP ' + r.status); return r.blob(); })
      .then((blob) => {
        const out = { url: URL.createObjectURL(blob), video: /^video\//.test(blob.type), gif: blob.type === 'image/gif' };
        if (entry.users > 0) entry.url = out.url; else URL.revokeObjectURL(out.url); // let go of while it loaded
        if (failed.rev === rev) failed = { rev: null, delay: 0, until: 0 };
        return out;
      });
    m.promise.catch(() => {
      if (media.get(rev) === entry) media.delete(rev); // the next try fetches again
      const delay = failed.rev === rev ? Math.min(60_000, failed.delay * 2) : 2000;
      failed = { rev, delay, until: Date.now() + delay };
    });
    media.set(rev, m);
  }
  m.users++;
  return m;
}
function releaseMedia(m) {
  if (!m || --m.users > 0) return;
  if (media.get(m.rev) === m) media.delete(m.rev);
  if (m.url) { URL.revokeObjectURL(m.url); m.url = null; }
}

function effectEl(kind) {
  const fx = h('div', `vz-fx vz-${kind}`);
  if (kind === 'particles') {
    for (let i = 0; i < PARTICLES; i++) {
      // spread over the width, each with its own pace; a negative delay starts it part way, so the paused (still)
      // frame is already a sky of dots rather than an empty bottom row
      const dur = 9 + ((i * 7) % 9);
      const p = h('i', i % 2 ? 'alt' : null, h('b'));
      p.style.left = `${((i * 37) % 100) + 1.5}%`;
      p.style.animationDuration = `${dur}s`;
      p.style.animationDelay = `-${((i * 5.3) % dur).toFixed(1)}s`;
      p.style.setProperty('--s', `${3 + (i % 4)}px`);
      fx.append(p);
    }
  } else if (kind === 'waves') {
    fx.append(h('i', 'w1'), h('i', 'w2'));
  } else if (kind === 'grid') {
    fx.append(h('div', 'plane'), h('i', 'horizon'));
  } else if (kind === 'pulse') {
    fx.append(h('i'));
  }
  return fx;
}

W.visor = {
  needs: ['state', 'tick'],
  bare: true,
  create(box, { o, page }) {
    const opt = visorOptions(o);
    if (opt.accent) box.style.setProperty('--vz-cool', opt.accent);
    box.style.setProperty('--vz-dim', String(opt.dim));
    box.dataset.bg = opt.background;

    const back = h('div', 'vz-back');
    const dim = h('div', 'vz-dim');
    const dial = h('div', 'vz-dial', h('div', 'vz-ticks'));
    const label = h('div', 'vz-label');
    const value = h('b', 'vz-num');
    const unit = h('small', 'vz-unit');
    const sub = h('div', 'vz-sub');
    const face = h('div', 'vz-face', label, h('div', 'vz-val', value, unit), sub);
    box.append(back, dim, dial, face);

    let idx = 0, svg = null, numNode = document.createTextNode('—'), nextAt = 0, alive = true, running = null;
    let swapTimer = 0, queued = false, mediaRev, mediaEl = null, still = null, held = null, loading = null, tapRetry = null;
    value.append(numNode);
    const kind = () => KINDS[opt.metrics[idx % opt.metrics.length]];

    // ---- what is on screen
    const shows = () => alive && box.isConnected && !idle() && !document.body.classList.contains('night')
      && pages[curPage] === page && !box.closest('.stack-item:not(.active)');
    const sync = () => {
      const on = shows(), run = on && !reducedMotion();
      if (on && !nextAt) nextAt = Date.now() + opt.cycleMs; // the cycle starts over when the page comes back
      if (!on) nextAt = 0;
      if (run === running) return;
      running = run;
      box.classList.toggle('vz-run', run);
      box.dataset.fx = run ? 'running' : 'paused';
      playMedia(run);
    };

    // ---- background
    const playMedia = (run) => {
      if (!mediaEl) return;
      if (mediaEl.tagName === 'VIDEO') {
        if (run) playVideo();
        else mediaEl.pause();
      } else if (still) {
        // an animated GIF keeps animating in an <img>: while still it is replaced by a copy of the frame it was on
        if (!run && mediaEl.naturalWidth) {
          still.width = mediaEl.naturalWidth; still.height = mediaEl.naturalHeight;
          try { still.getContext('2d').drawImage(mediaEl, 0, 0); } catch (_) {}
        }
        still.hidden = run || !mediaEl.naturalWidth;
        mediaEl.hidden = !run && !!mediaEl.naturalWidth;
      }
    };
    // a WebView that still wants a gesture before a video plays: tried once more on the next tap anywhere
    const playVideo = () => {
      mediaEl.play()?.catch?.(() => {
        if (tapRetry || !alive) return;
        tapRetry = () => {
          tapRetry = null;
          if (alive && running && mediaEl?.tagName === 'VIDEO') mediaEl.play()?.catch?.(() => {});
        };
        document.addEventListener('pointerdown', tapRetry, { once: true, capture: true });
      });
    };
    const setBack = (el) => {
      if (mediaEl?.tagName === 'VIDEO') { mediaEl.pause(); mediaEl.removeAttribute('src'); mediaEl.load(); }
      mediaEl = null; still = null;
      back.replaceChildren(el);
    };
    const showMedia = (m) => {
      if (!alive) return;
      let el;
      if (m.video) {
        el = h('video', 'vz-media');
        el.muted = true; el.defaultMuted = true; el.loop = true; el.playsInline = true; el.preload = 'auto';
        el.setAttribute('muted', ''); el.setAttribute('playsinline', ''); el.setAttribute('aria-hidden', 'true');
        el.disablePictureInPicture = true;
        el.src = m.url;
      } else {
        el = h('img', 'vz-media');
        el.alt = ''; el.decoding = 'async';
        el.src = m.url;
      }
      setBack(el);
      mediaEl = el;
      if (m.gif) {
        still = h('canvas', 'vz-media');
        still.hidden = true;
        back.append(still);
        el.addEventListener('load', () => playMedia(running), { once: true });
      }
      playMedia(running);
    };
    const checkMedia = () => {
      if (opt.background !== 'media') return;
      const rev = cfg.visorMediaRev ?? null;
      if (rev === mediaRev || (rev != null && retryLater(rev))) return;
      mediaRev = rev;
      releaseMedia(loading); loading = null; // a load this one replaces
      if (rev == null) { // nothing uploaded: the plain backdrop
        box.classList.remove('vz-has-media');
        setBack(effectEl('none'));
        releaseMedia(held); held = null;
        return;
      }
      const m = loading = acquireMedia(rev);
      m.promise.then((got) => {
        if (loading !== m) return; // replaced or destroyed meanwhile (and released then)
        loading = null;
        showMedia(got);
        box.classList.add('vz-has-media');
        releaseMedia(held); held = m; // the old file is let go only once the new one is on screen
      }, () => {
        if (loading !== m) return;
        loading = null;
        releaseMedia(m);
        mediaRev = undefined; // asked again once the back-off allows
        box.classList.remove('vz-has-media');
        setBack(effectEl('none'));
        releaseMedia(held); held = null;
      });
    };
    if (opt.background === 'media') checkMedia();
    else back.append(effectEl(opt.background));

    // ---- the number and its ring
    const level = (k, v) => {
      if (v == null) return 'cool';
      const [warm, hot] = k.temp ? opt.temp : opt.load;
      return v >= hot ? 'hot' : v >= warm ? 'warm' : 'cool';
    };
    const draw = () => {
      const k = kind(), s = D.state;
      const v = s ? k.val(s) : null;
      label.textContent = tp(k.label);
      unit.textContent = k.unit;
      tweenText(numNode, v == null ? '—' : String(Math.round(v)), k.unit);
      sub.textContent = (s && k.sub(s)) || ' ';
      box.dataset.level = level(k, v);
      box.dataset.metric = opt.metrics[idx % opt.metrics.length];
      const full = k.temp ? Math.max(100, opt.temp[1] + 10) : 100;
      const old = svg;
      dial.insertAdjacentHTML('beforeend', ringSvg(v == null ? 0 : (v / full) * 100)); // numbers only
      svg = dial.lastElementChild;
      carryRing(old, svg); // while the old ring is still in place, so a carry running on it can be read
      old?.remove();
    };

    // ---- cycling: a crossfade of the face; the ring carries itself to the next metric's value
    const advance = () => {
      if (opt.metrics.length < 2) return;
      // a tap during the crossfade is not lost and does not cut it short: one more step follows it
      if (swapTimer) { queued = true; return; }
      nextAt = opt.cycleMs ? Date.now() + opt.cycleMs : 0;
      const swap = () => {
        idx = (idx + 1) % opt.metrics.length;
        // a fresh text node: the next metric's number is set at once, not counted to from the last one's
        const fresh = document.createTextNode('');
        numNode.replaceWith(fresh);
        numNode = fresh;
        draw();
        face.classList.remove('out');
        swapTimer = 0;
        if (queued) { queued = false; advance(); }
      };
      if (reducedMotion() || !shows()) { swap(); return; }
      face.classList.add('out');
      swapTimer = setTimeout(swap, 280);
    };
    box.addEventListener('click', () => { if (opt.metrics.length > 1) { haptic(); advance(); } });

    const onShown = () => sync();
    window.addEventListener('phonebox-shown', onShown);
    document.addEventListener('visibilitychange', onShown);
    const motionQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
    motionQuery?.addEventListener?.('change', onShown);
    draw(); // the empty ring and a dash until the first state
    sync();

    return {
      update(what) {
        sync();
        if (what === 'tick') {
          checkMedia();
          if (opt.cycleMs && nextAt && Date.now() >= nextAt && shows()) advance();
          return;
        }
        draw();
      },
      destroy() {
        alive = false;
        clearTimeout(swapTimer);
        if (tapRetry) document.removeEventListener('pointerdown', tapRetry, { capture: true });
        window.removeEventListener('phonebox-shown', onShown);
        document.removeEventListener('visibilitychange', onShown);
        motionQuery?.removeEventListener?.('change', onShown);
        setBack(h('div'));
        releaseMedia(loading); loading = null;
        releaseMedia(held); held = null;
      },
    };
  },
};
