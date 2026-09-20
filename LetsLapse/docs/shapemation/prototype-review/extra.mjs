import * as M from './model.mjs';
import fs from 'node:fs'; import path from 'node:path';
const ROOT = path.join(process.env.HOME, 'Library/Developer/LetsLapseRun/libraries/tram-root/Projects');
const pct = v => (Math.round(v * 1000) / 10).toFixed(1) + ' %';
const sigma = (ph, A) => (ph.facePx / ph.height) * Math.max(1, A / ph.a) / Math.min(A, 1);
const lossOf = r => 1 - 1 / ((1 + r.ev.ex) * (1 + r.ev.ey) * r.ev.z * r.ev.z);
function loadTrams() {
  const out = [];
  for (const dir of fs.readdirSync(ROOT)) {
    const f = path.join(ROOT, dir, 'shapes.json'); if (!fs.existsSync(f)) continue;
    const d = JSON.parse(fs.readFileSync(f, 'utf8')); const rep = d.representative, W = rep.width, H = rep.height;
    const quads = d.shapes.filter(s => s.kind === 'quad' && s.corners?.length === 4); if (!quads.length) continue;
    const q = quads.reduce((a, b) => (b.nativeDiameterPx > a.nativeDiameterPx ? b : a));
    const xs = q.corners.map(c => c[0] * W), ys = q.corners.map(c => c[1] * H);
    let captured = ''; try { captured = JSON.parse(fs.readFileSync(path.join(ROOT, dir, 'metadata.json'), 'utf8')).imported?.captured || ''; } catch {}
    out.push({ id: dir.slice(0, 8), width: W, height: H, bbox: { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) }, captured, file: '' });
  }
  out.sort((a, b) => a.captured.localeCompare(b.captured));
  return out.map((m, i) => { const d = M.derive(m); d.order = i; return d; }).filter(p => p.orient === 'portrait');
}
const DEF = { thFlag: 0.15, thReject: 0.30, onZ: false, zFlag: 1.1, zReject: 1.2, autoReject: true, fixpoint: false, window: 5, ends: 'median', keys: {}, ease: 'linear', rejectedManual: new Set(), keptAnyway: new Set() };
const trams = loadTrams();
const pathJump = rows => { let s = 0, mx = 0; for (let i = 0; i < rows.length - 1; i++) { const d = Math.hypot(rows[i + 1].P.x - rows[i].P.x, rows[i + 1].P.y - rows[i].P.y); s += d; mx = Math.max(mx, d); } return { sum: s, max: mx }; };
const breaks = (rows, dir = 1) => { let b = 0; for (let i = 1; i < rows.length; i++) if ((rows[i].ev.size - rows[i - 1].ev.size) * dir < -0.002) b++; return b; };

console.log('### What the viewer sees: the rendered path\'s jump Σ|P(i+1) − P(i)| (the board shows Σ J on the natural positions instead) — portrait 83 → 4:5, one pass');
console.log('| rule | rejected | Σ J (board) | rendered Σ ΔP | largest single step | size-curve breaks |');
console.log('|---|---|---|---|---|---|');
for (const [name, o] of [['smallest · w3', { sort: 'smallest', window: 3 }], ['smallest · w5', { sort: 'smallest', window: 5 }], ['smallest · w7', { sort: 'smallest', window: 7 }], ['alignment K3 · w5', { sort: 'alignment', window: 5 }], ['capture order · w5', { sort: 'capture', window: 5 }]]) {
  const opts = { ...DEF, ...o }; const b = M.evaluateBoard(M.sortPhotos(trams, opts.sort, { A: 0.8, K: 3 }), 0.8, opts); const j = pathJump(b.rows);
  console.log(`| ${name} | ${b.rejectedRows.length} | ${b.sumJ.toFixed(2)} | ${j.sum.toFixed(2)} | ${j.max.toFixed(3)} | ${breaks(b.rows)} |`);
}

// "Placement only matters while the tram is small" (brief §1): let the path let go as the face grows.
function letGo(list, A, gamma, o = {}) {
  const opts = { ...DEF, ...o }; let kept = M.sortPhotos(list, 'smallest', { A });
  const pass = () => { const path = M.buildPath(kept, A, opts); return kept.map((ph, i) => { const n = M.natural(ph, A); const w = Math.pow(1 - Math.min(1, sigma(ph, A)), gamma); const T = { x: n.px + (path[i].x - n.px) * w, y: n.py + (path[i].y - n.py) * w }; const ev = M.evaluate(ph, A, T, 1); return { ph, i, P: T, ev, v: M.verdict(ev.f, ev.z, opts) }; }); };
  let rows = pass(); const rejected = [];
  for (let it = 0; it < (opts.fixpoint ? 10 : 1); it++) { const red = rows.filter(r => r.v === 'red'); if (!red.length) break; red.forEach(r => rejected.push(r.ph)); kept = kept.filter(ph => !red.some(r => r.ph === ph)); rows = pass(); }
  const meanF = rows.reduce((a, r) => a + r.ev.f, 0) / rows.length, meanL = rows.reduce((a, r) => a + lossOf(r), 0) / rows.length;
  return { rows, rejected, meanF, meanL, amber: rows.filter(r => r.v === 'amber').length, red: rows.filter(r => r.v === 'red').length, jump: pathJump(rows) };
}
console.log('\n### A size-aware path: target = p + (P − p)·(1 − σ)^γ — the face is pulled to the path only while it is small (γ = 0 is the prototype as built)');
console.log('| rect | γ | rejected | of which s ≥ 50 % | amber | red kept | mean f | mean L | rendered Σ ΔP | largest step |');
console.log('|---|---|---|---|---|---|---|---|---|---|');
for (const [k, A] of [['4:5', 0.8], ['3:4', 0.75], ['9:16', 9 / 16]]) for (const g of [0, 0.5, 1, 2]) { const r = letGo(trams, A, g); console.log(`| ${k} | ${g} | ${r.rejected.length} of 83 | ${r.rejected.filter(p => p.s >= 0.5).length} | ${r.amber} | ${r.red} | ${pct(r.meanF)} | ${pct(r.meanL)} | ${r.jump.sum.toFixed(2)} | ${r.jump.max.toFixed(3)} |`); }
const base = letGo(trams, 0.8, 0), lg = letGo(trams, 0.8, 1);
console.log(`\n4:5 · γ = 1 keeps ${base.rejected.filter(p => !lg.rejected.includes(p)).map(p => `${p.id} (s ${pct(p.s)})`).join(', ')} that γ = 0 rejected; newly rejected: ${lg.rejected.filter(p => !base.rejected.includes(p)).map(p => p.id).join(', ') || 'none'}`);
// how far off the path do the rejects sit, at 4:5 defaults
const b = M.evaluateBoard(M.sortPhotos(trams, 'smallest', { A: 0.8 }), 0.8, DEF);
const offs = b.rejectedRows.map(r => Math.hypot(r.ev.px - (b.rows.reduce((a, x) => a + x.P.x, 0) / b.rows.length), 0)).sort((a, b) => a - b);
console.log(`\nAt 4:5 the kept path sits at x ≈ ${(b.rows.reduce((a, x) => a + x.P.x, 0) / b.rows.length).toFixed(2)}; the ${offs.length} rejects' faces are ${offs[0].toFixed(2)}–${offs[offs.length - 1].toFixed(2)} of the frame width off it horizontally (a same-aspect photo pays z = 1.2 → f 30 % at roughly ±0.08).`);
