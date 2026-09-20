// The prototype's least-crop model (model.js, unchanged) over Steven's real tram registers.
import * as M from './model.mjs';
import fs from 'node:fs';
import path from 'node:path';

const HOME = process.env.HOME;
const ROOT = path.join(HOME, 'Library/Developer/LetsLapseRun/libraries/tram-root/Projects');
const KIT = '/Users/stevenwright/Documents/dev/letslapse/LetsLapse/docs/design/kit/compositions/manifest.json';
const OUT = process.argv[2] || '.';

const pct = v => (Math.round(v * 1000) / 10).toFixed(1) + ' %';
const sigma = (ph, A) => (ph.facePx / ph.height) * Math.max(1, A / ph.a) / Math.min(A, 1);
const lossOf = r => 1 - 1 / ((1 + r.ev.ex) * (1 + r.ev.ey) * r.ev.z * r.ev.z);
const aspectLossOf = r => 1 - 1 / ((1 + r.ev.ex) * (1 + r.ev.ey));
const med = a => { const s = [...a].sort((x, y) => x - y); return s[s.length >> 1]; };

function loadTrams() {
  const out = [];
  for (const dir of fs.readdirSync(ROOT)) {
    const f = path.join(ROOT, dir, 'shapes.json'); if (!fs.existsSync(f)) continue;
    const d = JSON.parse(fs.readFileSync(f, 'utf8'));
    const rep = d.representative; const W = rep.width, H = rep.height;
    const quads = d.shapes.filter(s => s.kind === 'quad' && s.corners && s.corners.length === 4);
    if (!quads.length) continue;
    const q = quads.reduce((a, b) => (b.nativeDiameterPx > a.nativeDiameterPx ? b : a));
    const xs = q.corners.map(c => c[0] * W), ys = q.corners.map(c => c[1] * H);
    const bbox = { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
    let captured = null; try { captured = JSON.parse(fs.readFileSync(path.join(ROOT, dir, 'metadata.json'), 'utf8')).imported?.captured || null; } catch {}
    out.push({ id: dir.slice(0, 8), dir, width: W, height: H, bbox, captured, file: path.join(ROOT, dir, 'poster.jpg'), nshapes: d.shapes.length });
  }
  out.sort((a, b) => (a.captured || '').localeCompare(b.captured || ''));
  return out.map((m, i) => { const d = M.derive(m); d.order = i; return d; });
}

function run(list, A, o = {}) {
  const opts = { thFlag: 0.15, thReject: 0.30, onZ: false, zFlag: 1.1, zReject: 1.2, autoReject: true, fixpoint: false, window: 5, ends: 'median', keys: {}, ease: 'linear', rejectedManual: new Set(), keptAnyway: new Set(), sort: 'smallest', ...o };
  const sorted = opts.sort === 'sigma' ? [...list].sort((a, b) => sigma(a, A) - sigma(b, A)) : M.sortPhotos(list, opts.sort, { A, K: 3 });
  const b = M.evaluateBoard(sorted, A, opts);
  const n = b.rows.length;
  const meanL = n ? b.rows.reduce((a, r) => a + lossOf(r), 0) / n : 0;
  const meanAspect = n ? b.rows.reduce((a, r) => a + aspectLossOf(r), 0) / n : 0;
  return { b, n, meanL, meanAspect, ends: n ? [b.rows[0].ev.f, b.rows[n - 1].ev.f] : [0, 0], total: list.length };
}
const line = (name, R) => `| ${name} | ${R.b.rejectedRows.length} of ${R.total} | ${R.b.flagged} | ${R.b.red} | ${pct(R.b.meanF)} | ${pct(R.meanAspect)} | ${pct(R.meanL)} | ${R.b.sumJ.toFixed(2)} | ${pct(R.ends[0])} / ${pct(R.ends[1])} |`;
const header = title => `\n### ${title}\n| set / rule | rejected | amber | red kept | mean f | aspect loss | mean L | Σ J | f first / last |\n|---|---|---|---|---|---|---|---|---|`;
function inversions(list, A) { const bys = [...list].sort((a, b) => a.s - b.s); let inv = 0; for (let i = 0; i < bys.length - 1; i++) if (sigma(bys[i], A) > sigma(bys[i + 1], A) + 1e-9) inv++; return inv; }
function dump(R, A, name) {
  const row = (r, rejected) => ({ id: r.ph.id, file: r.ph.file, width: r.ph.width, height: r.ph.height, bbox: r.ph.bbox, win: r.ev.win, f: r.ev.f, v: r.v, L: lossOf(r), s: r.ph.s, P: r.P || null, p: { x: r.ev.px, y: r.ev.py }, rejected });
  fs.writeFileSync(path.join(OUT, name), JSON.stringify({ A, rows: R.b.rows.map(r => row(r, false)), rejected: R.b.rejectedRows.map(r => row(r, true)), sumJ: R.b.sumJ, meanF: R.b.meanF, meanL: R.meanL }, null, 1));
}

const ASP = { '3:4': 0.75, '4:5': 0.8, '2:3': 2 / 3, '9:16': 9 / 16, '1:1': 1, '3:2': 1.5, '16:9': 16 / 9 };
const trams = loadTrams();
const portrait = trams.filter(p => p.orient === 'portrait');
const S = trams.map(p => p.s), CX = trams.map(p => p.cx), CY = trams.map(p => p.cy);
console.log(`## The tram registers through model.js\n`);
console.log(`${trams.length} registers with a quad (${portrait.length} portrait 3024×4032, ${trams.length - portrait.length} landscape); captured ${trams[0].captured} → ${trams[trams.length - 1].captured} (capture order = that walk).`);
console.log(`face share s: min ${pct(Math.min(...S))} · median ${pct(med(S))} · max ${pct(Math.max(...S))}; centre x: ${Math.min(...CX).toFixed(2)} / ${med(CX).toFixed(2)} / ${Math.max(...CX).toFixed(2)}; centre y: ${Math.min(...CY).toFixed(2)} / ${med(CY).toFixed(2)} / ${Math.max(...CY).toFixed(2)}`);
const cells = [0, 0, 0, 0, 0, 0, 0, 0, 0]; trams.forEach(p => cells[p.centreCell]++);
console.log(`3×3 cells (row-major): ${cells.join(' · ')}; columns L/C/R: ${cells[0] + cells[3] + cells[6]} / ${cells[1] + cells[4] + cells[7]} / ${cells[2] + cells[5] + cells[8]}`);

console.log(header('Q10 — the portrait 83, defaults (window 5 · median ends · f 15/30 % · one pass · smallest first)'));
for (const [k, A] of Object.entries(ASP)) console.log(line(`portrait 83 → ${k}`, run(portrait, A)));
console.log(header('All 84 with the one landscape kept in'));
for (const k of ['3:4', '4:5']) { const R = run(trams, ASP[k]); const land = [...R.b.rows, ...R.b.rejectedRows].find(r => r.ph.orient === 'landscape'); console.log(line(`all 84 → ${k}`, R) + ` landscape photo: f ${pct(land.ev.f)} · L ${pct(lossOf(land))} · ${land.rejected ? 'rejected' : land.v}`); }

for (const k of ['3:4', '4:5', '9:16']) {
  const A = ASP[k];
  console.log(header(`Q1 — portrait 83 → ${k}: window × ends × passes`));
  for (const ends of ['median', 'trend']) for (const window of [3, 5, 7]) console.log(line(`w${window} · ${ends} · one pass`, run(portrait, A, { window, ends })));
  for (const ends of ['median', 'trend']) console.log(line(`w5 · ${ends} · fixpoint`, run(portrait, A, { ends, fixpoint: true })));
  console.log(line(`w5 · median · on z 1.10/1.20`, run(portrait, A, { onZ: true })));
  console.log(line(`w5 · median · auto-reject OFF`, run(portrait, A, { autoReject: false })));
  console.log(line(`w5 · trend · auto-reject OFF`, run(portrait, A, { autoReject: false, ends: 'trend' })));
}
console.log(header('Sorts at 4:5 (w5 · median · one pass)'));
for (const sort of ['smallest', 'largest', 'capture', 'alignment']) console.log(line(sort, run(portrait, 0.8, { sort })));

const REC = run(portrait, 0.8); dump(REC, 0.8, 'trams-4x5.json');
const REC34 = run(portrait, 0.75); dump(REC34, 0.75, 'trams-3x4.json');
const RECT = run(portrait, 0.8, { ends: 'trend' }); dump(RECT, 0.8, 'trams-4x5-trend.json');
console.log(`\n### Per photo — portrait 83 → 4:5, defaults (smallest first)\n| # | project | s | natural p | path P | z | f | L | verdict |\n|---|---|---|---|---|---|---|---|---|`);
REC.b.rows.forEach((r, i) => console.log(`| ${i + 1} | ${r.ph.id} | ${pct(r.ph.s)} | ${r.ev.px.toFixed(2)} · ${r.ev.py.toFixed(2)} | ${r.P.x.toFixed(2)} · ${r.P.y.toFixed(2)} | ${r.ev.z.toFixed(2)} | ${pct(r.ev.f)} | ${pct(lossOf(r))} | ${r.v} |`));
REC.b.rejectedRows.forEach(r => console.log(`| — | ${r.ph.id} | ${pct(r.ph.s)} | ${r.ev.px.toFixed(2)} · ${r.ev.py.toFixed(2)} | (nearest) | ${r.ev.z.toFixed(2)} | ${pct(r.ev.f)} | ${pct(lossOf(r))} | REJECTED |`));

// ---- the kit: does model.js reproduce the brief's §4 table?
const kit = JSON.parse(fs.readFileSync(KIT, 'utf8')).map((m, i) => { const d = M.derive(m); d.order = i; return d; });
const BAD = ['mixed.random.01', 'mixed.random.02', 'mixed.random.05', 'mixed.random.07', 'mixed.random.10', 'mixed.random.11', 'mixed.random.13', 'mixed.random.21', 'mixed.random.26', 'mixed.random.27'];
const bad = kit.filter(p => BAD.includes(p.id));
console.log(`\n## The kit through model.js (checks against the brief §4)\n`);
console.log(`### Bad-apple 10 → 3:2, w5 · median · auto-reject OFF — f per photo, model.js order (native s) vs the brief's order (σ)\n| photo | s | σ | f (s-sorted, model.js) | f (σ-sorted, brief) | brief's table |`);
console.log(`|---|---|---|---|---|---|`);
const briefF = { 'mixed.random.05': '95 %', 'mixed.random.07': '20 %', 'mixed.random.01': '13 %', 'mixed.random.02': '4 %', 'mixed.random.13': '11 %', 'mixed.random.10': '46 %', 'mixed.random.11': '0 %', 'mixed.random.21': '21 %', 'mixed.random.26': '37 %', 'mixed.random.27': '44 %' };
const Rs = run(bad, 1.5, { autoReject: false }), Rsig = run(bad, 1.5, { autoReject: false, sort: 'sigma' });
const fOf = (R, id) => R.b.rows.find(r => r.ph.id === id).ev.f;
Rsig.b.rows.forEach(r => console.log(`| ${r.ph.id} | ${pct(r.ph.s)} | ${pct(sigma(r.ph, 1.5))} | ${pct(fOf(Rs, r.ph.id))} | ${pct(fOf(Rsig, r.ph.id))} | ${briefF[r.ph.id]} |`));
console.log(`| Σ J · mean f | | | ${Rs.b.sumJ.toFixed(2)} · ${pct(Rs.b.meanF)} | ${Rsig.b.sumJ.toFixed(2)} · ${pct(Rsig.b.meanF)} | 1.06 · 29 % |`);
const Ron = run(bad, 1.5), Ronfix = run(bad, 1.5, { fixpoint: true });
console.log(`\nauto-reject ON, one pass: rejected ${Ron.b.rejectedRows.map(r => r.ph.id.replace('mixed.random.', '#')).join(', ')} → ${Ron.n} kept, Σ J ${Ron.b.sumJ.toFixed(2)} · mean f ${pct(Ron.b.meanF)}; to a fixpoint: rejected ${Ronfix.b.rejectedRows.map(r => r.ph.id.replace('mixed.random.', '#')).join(', ')} → ${Ronfix.n} kept, Σ J ${Ronfix.b.sumJ.toFixed(2)} · mean f ${pct(Ronfix.b.meanF)}`);
const mixed = kit.filter(p => p.seq === 'mixed.random'), p30 = kit.filter(p => p.orient === 'portrait'), clean = kit.filter(p => p.seq === 'city.clear.approach');
console.log(`\nsort inversions, native s vs rendered σ: mixed 40 → 3:2: ${inversions(mixed, 1.5)} neighbour pairs; portrait 30 → 2:3: ${inversions(p30, 2 / 3)}; trams 83 → 4:5: ${inversions(portrait, 0.8)}`);
console.log(header('Kit sets, defaults'));
console.log(line('mixed 40 → 3:2 · auto-reject OFF', run(mixed, 1.5, { autoReject: false })));
console.log(line('mixed 40 → 3:2', run(mixed, 1.5)));
console.log(line('mixed 40 left column → 3:2', run(mixed.filter(p => p.cx < 1 / 3), 1.5)));
console.log(line('mixed 40 left column → 3:2 · fixpoint', run(mixed.filter(p => p.cx < 1 / 3), 1.5, { fixpoint: true })));
console.log(line('clean 12 → 3:2 · median · OFF', run(clean, 1.5, { autoReject: false })));
console.log(line('clean 12 → 3:2 · trend · OFF', run(clean, 1.5, { autoReject: false, ends: 'trend' })));
for (const k of ['2:3', '4:5', '9:16', '16:9']) console.log(line(`portrait 30 → ${k}`, run(p30, ASP[k])));
