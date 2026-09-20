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
    out.push({ id: dir.slice(0, 8), width: W, height: H, bbox: { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) }, captured, file: path.join(ROOT, dir, 'poster.jpg') });
  }
  out.sort((a, b) => a.captured.localeCompare(b.captured));
  return out.map((m, i) => { const d = M.derive(m); d.order = i; return d; }).filter(p => p.orient === 'portrait');
}
const DEF = { thFlag: 0.15, thReject: 0.30, onZ: false, zFlag: 1.1, zReject: 1.2, autoReject: true, fixpoint: false, window: 5, ends: 'median', keys: {}, ease: 'linear', rejectedManual: new Set(), keptAnyway: new Set() };
const trams = loadTrams();
const pathJump = rows => { let s = 0, mx = 0; for (let i = 0; i < rows.length - 1; i++) { const d = Math.hypot(rows[i + 1].P.x - rows[i].P.x, rows[i + 1].P.y - rows[i].P.y); s += d; mx = Math.max(mx, d); } return { sum: s, max: mx }; };
const breaks = rows => { let b = 0; for (let i = 1; i < rows.length; i++) if (rows[i].ev.size - rows[i - 1].ev.size < -0.002) b++; return b; };
const maxDip = rows => { let m = 0; for (let i = 1; i < rows.length; i++) m = Math.max(m, rows[i - 1].ev.size - rows[i].ev.size); return m; };

console.log('### The size stutter: sorting on the native share s leaves the rendered size s·z non-monotonic; re-sorting once or twice on the rendered size (rejects kept out) — portrait 83, defaults');
console.log('| rect | pass | rows | rejected | size-curve breaks | largest dip (of the short edge) | mean f | rendered Σ ΔP |');
console.log('|---|---|---|---|---|---|---|---|');
for (const [k, A] of [['4:5', 0.8], ['3:4', 0.75], ['9:16', 9 / 16]]) {
  let b = M.evaluateBoard(M.sortPhotos(trams, 'smallest', { A }), A, DEF);
  console.log(`| ${k} | sorted on s | ${b.rows.length} | ${b.rejectedRows.length} | ${breaks(b.rows)} | ${pct(maxDip(b.rows))} | ${pct(b.meanF)} | ${pathJump(b.rows).sum.toFixed(2)} |`);
  const rej = new Set(b.rejectedRows.map(r => r.ph.id));
  for (let pass = 1; pass <= 2; pass++) {
    const order = [...b.rows].sort((x, y) => x.ev.size - y.ev.size).map(r => r.ph);
    b = M.evaluateBoard(order, A, { ...DEF, rejectedManual: rej, autoReject: false });
    console.log(`| ${k} | re-sorted on s·z ×${pass} | ${b.rows.length} | ${rej.size} | ${breaks(b.rows)} | ${pct(maxDip(b.rows))} | ${pct(b.meanF)} | ${pathJump(b.rows).sum.toFixed(2)} |`);
  }
}
// dump the size-aware γ=1 board at 4:5 for a contact sheet
function letGo(list, A, gamma) {
  const opts = { ...DEF }; let kept = M.sortPhotos(list, 'smallest', { A });
  const pass = () => { const path = M.buildPath(kept, A, opts); return kept.map((ph, i) => { const n = M.natural(ph, A); const w = Math.pow(1 - Math.min(1, sigma(ph, A)), gamma); const T = { x: n.px + (path[i].x - n.px) * w, y: n.py + (path[i].y - n.py) * w }; const ev = M.evaluate(ph, A, T, 1); return { ph, i, P: T, ev, v: M.verdict(ev.f, ev.z, opts) }; }); };
  let rows = pass(); const rejected = [];
  const red = rows.filter(r => r.v === 'red'); red.forEach(r => rejected.push(r)); kept = kept.filter(ph => !red.some(r => r.ph === ph)); rows = pass();
  return { rows, rejected };
}
const g = letGo(trams, 0.8, 1);
const row = (r, rejected) => ({ id: r.ph.id, file: r.ph.file, width: r.ph.width, height: r.ph.height, bbox: r.ph.bbox, win: r.ev.win, f: r.ev.f, v: r.v, L: lossOf(r), s: r.ph.s, P: r.P, p: { x: r.ev.px, y: r.ev.py }, rejected });
fs.writeFileSync(path.join(process.argv[2], 'trams-4x5-sizeaware.json'), JSON.stringify({ A: 0.8, rows: g.rows.map(r => row(r, false)), rejected: g.rejected.map(r => row(r, true)) }, null, 1));
console.log(`\nsize-aware γ = 1 at 4:5: ${g.rows.length} kept, ${g.rejected.length} rejected → trams-4x5-sizeaware.json`);
