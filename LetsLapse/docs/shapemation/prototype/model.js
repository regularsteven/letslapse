// Shape-mation prototype — the one computation (brief §4). Ratios of the photo's own frame and of the output rect.
export const ASPECTS = { '1:1': 1, '4:5': 0.8, '3:2': 1.5, '16:9': 16 / 9, '2:3': 2 / 3, '9:16': 9 / 16, '4:3': 4 / 3 };

export function derive(m) {
  const W = m.width, H = m.height, b = m.bbox;
  return {
    ...m,
    seq: m.id.replace(/\.\d+$/, ''),
    cx: (b.x + b.w / 2) / W, cy: (b.y + b.h / 2) / H,
    s: Math.max(b.w, b.h) / Math.min(W, H),
    facePx: Math.max(b.w, b.h),
    a: W / H,
    orient: W > H ? 'landscape' : W < H ? 'portrait' : 'square',
    centreCell: cellOf((b.x + b.w / 2) / W, (b.y + b.h / 2) / H),
  };
}
export function cellOf(x, y) { const c = Math.min(2, Math.floor(x * 3)), r = Math.min(2, Math.floor(y * 3)); return r * 3 + c; }

// Natural (cover-fit) rendering: overhang e per axis, natural face position p.
export function natural(ph, A) {
  const ex = ph.a > A ? ph.a / A - 1 : 0;
  const ey = ph.a < A ? A / ph.a - 1 : 0;
  return { ex, ey, px: 0.5 + (ph.cx - 0.5) * (1 + ex), py: 0.5 + (ph.cy - 0.5) * (1 + ey) };
}
function zAxis(P, p, e) { return Math.max(1, P / (p + e / 2), (1 - P) / (1 + e / 2 - p)); }

// The crop a photo pays to bring its face from p onto P. zoomKey ≥ 1 is a deliberate zoom beyond cover fit.
export function evaluate(ph, A, P, zoomKey = 1) {
  const n = natural(ph, A);
  const zx = zAxis(P.x, n.px, n.ex), zy = zAxis(P.y, n.py, n.ey);
  const z = Math.max(zx, zy) * zoomKey;
  const f = 1 - 1 / (z * z);
  // output window in the photo's unit coords
  const winW = 1 / (z * (1 + n.ex)), winH = 1 / (z * (1 + n.ey));
  let left = ph.cx - P.x * winW, top = ph.cy - P.y * winH;
  left = Math.min(Math.max(left, 0), 1 - winW); top = Math.min(Math.max(top, 0), 1 - winH);
  return { ...n, zx, zy, z, f, size: ph.s * z, win: { left, top, w: winW, h: winH } };
}

export function verdict(f, z, opts) {
  const { thFlag, thReject, onZ, zFlag, zReject } = opts;
  if (onZ) return z >= zReject ? 'red' : z >= zFlag ? 'amber' : 'green';
  return f >= thReject ? 'red' : f >= thFlag ? 'amber' : 'green';
}

function median(arr) { const s = [...arr].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; }
export function runningMedian(vals, win) {
  const h = Math.floor(win / 2), out = [];
  for (let i = 0; i < vals.length; i++) out.push(median(vals.slice(Math.max(0, i - h), Math.min(vals.length, i + h + 1))));
  return out;
}
function lineFit(xs, ys) {
  const n = xs.length; if (n < 2) return { m: 0, b: ys[0] ?? 0.5 };
  const mx = xs.reduce((a, b) => a + b, 0) / n, my = ys.reduce((a, b) => a + b, 0) / n;
  let num = 0, den = 0; for (let i = 0; i < n; i++) { num += (xs[i] - mx) * (ys[i] - my); den += (xs[i] - mx) ** 2; }
  const m = den ? num / den : 0; return { m, b: my - m * mx };
}
// Ends continue the trend: a local line over the first/last `win` points replaces the shortened median there.
function continueEnds(path, vals, win) {
  const n = vals.length; if (n < 3) return path;
  const h = Math.floor(win / 2), k = Math.min(n, win);
  const idx = Array.from({ length: k }, (_, i) => i);
  const head = lineFit(idx, vals.slice(0, k)); const tail = lineFit(idx.map(i => n - k + i), vals.slice(n - k));
  const out = [...path];
  for (let i = 0; i < Math.min(h, n); i++) out[i] = clamp01(head.m * i + head.b);
  for (let i = Math.max(0, n - h); i < n; i++) out[i] = clamp01(tail.m * i + tail.b);
  return out;
}
const clamp01 = v => Math.min(1, Math.max(0, v));
export const ease = { linear: t => t, inOut: t => t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2 };

// The path P(t) over the sorted kept order. keys: {index: {x,y}} user pins; the offset from the automatic path is eased between neighbouring pins.
export function buildPath(kept, A, opts) {
  const n = kept.length; if (!n) return [];
  const nat = kept.map(ph => natural(ph, A));
  let px = runningMedian(nat.map(v => v.px), opts.window), py = runningMedian(nat.map(v => v.py), opts.window);
  if (opts.ends === 'trend') { px = continueEnds(px, nat.map(v => v.px), opts.window); py = continueEnds(py, nat.map(v => v.py), opts.window); }
  const auto = px.map((x, i) => ({ x, y: py[i] }));
  const pins = Object.entries(opts.keys || {}).map(([i, k]) => ({ i: +i, k })).filter(p => p.i < n).sort((a, b) => a.i - b.i);
  if (!pins.length) return auto;
  const anchors = [{ i: 0, dx: 0, dy: 0 }, ...pins.map(p => ({ i: p.i, dx: p.k.x - auto[p.i].x, dy: p.k.y - auto[p.i].y })), { i: n - 1, dx: 0, dy: 0 }]
    .reduce((acc, a) => { const ex = acc.find(b => b.i === a.i); if (ex) { ex.dx = a.dx; ex.dy = a.dy; } else acc.push(a); return acc; }, []).sort((a, b) => a.i - b.i);
  const E = ease[opts.ease] || ease.linear;
  return auto.map((p, i) => {
    let lo = anchors[0], hi = anchors[anchors.length - 1];
    for (let j = 0; j < anchors.length - 1; j++) if (i >= anchors[j].i && i <= anchors[j + 1].i) { lo = anchors[j]; hi = anchors[j + 1]; break; }
    const t = hi.i === lo.i ? 0 : E((i - lo.i) / (hi.i - lo.i));
    return { x: clamp01(p.x + lo.dx + (hi.dx - lo.dx) * t), y: clamp01(p.y + lo.dy + (hi.dy - lo.dy) * t) };
  });
}

// Sorts
export function sortPhotos(list, sort, opts = {}) {
  const L = [...list];
  if (sort === 'largest') return L.sort((a, b) => b.s - a.s);
  if (sort === 'smallest') return L.sort((a, b) => a.s - b.s);
  if (sort === 'capture') return L.sort((a, b) => a.order - b.order);
  if (sort === 'alignment') return alignmentSort(L, opts.A ?? 1.5, opts.K ?? 3, opts.sameAngle);
  return L;
}
export function alignmentSort(list, A, K, sameAngle) {
  const bySize = [...list].sort((a, b) => a.s - b.s);
  if (bySize.length < 3) return bySize;
  const out = [bySize.shift()];
  while (bySize.length) {
    const cur = out[out.length - 1], nc = natural(cur, A);
    let best = 0, bestCost = Infinity;
    for (let j = 0; j < Math.min(K, bySize.length); j++) {
      const n = natural(bySize[j], A);
      let cost = Math.hypot(n.px - nc.px, n.py - nc.py) * (1 - cur.s);
      if (sameAngle && bySize[j].tram !== cur.tram) cost += 0.05;
      cost += j * 0.002; // prefer the size order on ties
      if (cost < bestCost) { bestCost = cost; best = j; }
    }
    out.push(bySize.splice(best, 1)[0]);
  }
  return out;
}

// One board evaluation: sorted members → rows with p, z, f, verdict; rejects; ΣJ and mean f.
export function evaluateBoard(sorted, A, opts) {
  const manual = opts.rejectedManual || new Set(), keep = opts.keptAnyway || new Set();
  let kept = sorted.filter(ph => !manual.has(ph.id));
  let autoRejected = new Set();
  const pass = () => {
    const idxKeys = {}; kept.forEach((ph, i) => { if (opts.keys?.[ph.id]) idxKeys[i] = opts.keys[ph.id]; });
    const path = buildPath(kept, A, { ...opts, keys: idxKeys });
    const rows = kept.map((ph, i) => {
      const key = idxKeys[i];
      const ev = evaluate(ph, A, path[i], key?.zoom || 1);
      return { ph, i, P: path[i], ev, v: verdict(ev.f, ev.z, opts), key: key || null };
    });
    return { path, rows };
  };
  let { path, rows } = pass();
  if (opts.autoReject) {
    for (let iter = 0; iter < (opts.fixpoint ? 10 : 1); iter++) {
      const newly = rows.filter(r => r.v === 'red' && !keep.has(r.ph.id)).map(r => r.ph.id);
      if (!newly.length) break;
      newly.forEach(id => autoRejected.add(id));
      kept = kept.filter(ph => !autoRejected.has(ph.id));
      ({ path, rows } = pass());
    }
  }
  let sumJ = 0;
  for (let i = 0; i < rows.length - 1; i++) sumJ += Math.hypot(rows[i + 1].ev.px - rows[i].ev.px, rows[i + 1].ev.py - rows[i].ev.py) * (1 - rows[i].ph.s);
  const meanF = rows.length ? rows.reduce((a, r) => a + r.ev.f, 0) / rows.length : 0;
  let angleChanges = 0; for (let i = 0; i < rows.length - 1; i++) if (rows[i].ph.tram !== rows[i + 1].ph.tram) angleChanges++;
  const rejectedRows = sorted.filter(ph => manual.has(ph.id) || autoRejected.has(ph.id)).map(ph => {
    const ev = evaluate(ph, A, nearestPath(path, rows, ph, A), 1);
    return { ph, ev, v: verdict(ev.f, ev.z, opts), rejected: true, manual: manual.has(ph.id) };
  });
  return { rows, path, sumJ, meanF, angleChanges, autoRejected, rejectedRows, flagged: rows.filter(r => r.v === 'amber').length, red: rows.filter(r => r.v === 'red').length };
}
function nearestPath(path, rows, ph, A) {
  if (!rows.length) return { x: 0.5, y: 0.55 };
  // the rejected photo would sit by size between its neighbours: take the path at the nearest kept size
  let best = rows[0]; for (const r of rows) if (Math.abs(r.ph.s - ph.s) < Math.abs(best.ph.s - ph.s)) best = r;
  return best.P;
}

// Fixed face (output-frame.md §2): ×2 rasterisation rule — double the manifest's pixels before the math.
export function fixedFace(ph, outW, outH, face, size, cap = 2) {
  const W = ph.width * 2, H = ph.height * 2, facePx = ph.facePx * 2;
  const targetPx = size * outH, scale = targetPx / facePx;
  const cx = face.x * outW, cy = face.y * outH;
  const left = cx - ph.cx * W * scale, top = cy - ph.cy * H * scale;
  const right = left + W * scale, bottom = top + H * scale;
  const sf = { left: Math.max(0, left), top: Math.max(0, top), right: Math.max(0, outW - right), bottom: Math.max(0, outH - bottom) };
  const short = Object.values(sf).some(v => v > 0.5), up = scale > cap;
  return { scale, shortfall: sf, verdict: short && up ? 'shortAndUpscaled' : short ? 'short' : up ? 'upscaled' : 'fits', placed: { left: left / outW, top: top / outH, w: W * scale / outW, h: H * scale / outH } };
}

export const HOLDS = [{ l: '2 s', s: 2 }, { l: '1 s', s: 1 }, { l: '0.5 s', s: 0.5 }, { l: '0.25 s', s: 0.25 }, { l: '0.1 s', s: 0.1 }, { l: '3 frames', fr: 3 }, { l: '2 frames', fr: 2 }, { l: '1 frame', fr: 1 }];
export function holdFrames(h, fps) { return h.fr ? h.fr : Math.max(1, Math.round(h.s * fps)); }
export const fmtPct = v => Math.round(v * 100) + ' %';
export const fmtPx = v => Math.round(v).toLocaleString('fr-FR').replace(/\u202f/g, ' ');
