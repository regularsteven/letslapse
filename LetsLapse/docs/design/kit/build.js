// Scene kit builder. Inputs: kit/recipes.json. Outputs: kit/objects, kit/skies, kit/scenes, kit/compositions (+ manifest.json).
// Run in Node: node kit/build.js   (or via the project's script runner: build(readFile, saveFile)).
//
// World model (metres). The camera stands on or beside a two-lane road and looks straight down it, so every
// parallel line meets at one vanishing point on the horizon at the frame's horizontal centre. The camera's
// lateral position (pavement left / centre / right) and height move the road's near footprint and the horizon.
//   screen_x = cx + f·(X − camX)/Z      screen_y = horizon + f·camH/Z
// Scenes provide backdrop + ground colour; the composer draws the road, kerbs, centre line and rails, then
// puts each object on its track at the depth its on-screen size implies. Objects declare data-width-m so the
// same maths will place a car or a person.
const C = { red:'#C8332B', cream:'#EFE3C3', creamDk:'#D9CBA3', dark:'#2A2A2E', glass:'#8FB7CF', light:'#F6EFD2', amber:'#E8A33C', shadow:'#1B1B1E', rail:'#B9BCC2' };
const svg = (w, h, inner, attrs = '') => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}"${attrs}>\n${inner}\n</svg>\n`;
const f1 = v => +v.toFixed(1);

// ---------- Objects: Prague T3-style tram ----------
// Front face in a 600×900 local box; body spans x 70–530, wheels touch the ground at y 842. 460 units ≈ 2.5 m.
const FACE_SHAPE = [[70,790],[70,320],[130,175],[300,130],[470,175],[530,320],[530,790]];
const TRAM_WIDTH_M = 600 / 460 * 2.5; // full object box width in metres
function face({ pantograph = true } = {}) {
  return `${pantograph ? `<path d="M300 40 L210 130 M300 40 L390 130 M255 40 H345" stroke="${C.dark}" stroke-width="7" fill="none" stroke-linecap="round"/>
<rect x="240" y="118" width="120" height="14" rx="4" fill="${C.dark}"/>` : ''}
<path d="M70 320 Q70 130 300 130 Q530 130 530 320 V790 H70 Z" fill="${C.cream}"/>
<path d="M70 470 H530 V790 H70 Z" fill="${C.red}"/>
<rect x="70" y="560" width="460" height="26" fill="${C.cream}"/>
<path d="M105 225 Q300 190 495 225 V415 Q300 440 105 415 Z" fill="${C.glass}"/>
<path d="M120 235 Q300 205 480 235 V300 Q300 325 120 300 Z" fill="#FFFFFF" opacity="0.18"/>
<rect x="200" y="168" width="200" height="36" rx="6" fill="${C.dark}"/>
<rect x="215" y="180" width="90" height="12" rx="2" fill="#F2B84B"/>
<circle cx="300" cy="650" r="42" fill="${C.light}" stroke="${C.dark}" stroke-width="6"/>
<circle cx="125" cy="710" r="17" fill="${C.amber}"/><circle cx="475" cy="710" r="17" fill="${C.amber}"/>
<rect x="60" y="760" width="480" height="40" rx="6" fill="${C.dark}"/>
<rect x="95" y="800" width="410" height="42" fill="${C.shadow}"/>
<rect x="270" y="796" width="60" height="50" rx="4" fill="${C.dark}"/>`;
}
// Left flank, receding from the face's body edge (face placed at x=230, so its body edge is x=300) back to x=140.
// It is drawn first and runs under the face to x=380, so the face's rounded corner has cream behind it — no gap.
function flankLeft() {
  const pt = (x, y) => { const t = Math.max(0, (300 - x) / 160); const yy = y + t * ((250 + (y - 155) * 0.78) - y); return `${f1(x)} ${f1(yy)}`; };
  const quad = (x1, x2, y1, y2, fill) => `<path d="M${pt(x1, y1)} L${pt(x2, y1)} L${pt(x2, y2)} L${pt(x1, y2)} Z" fill="${fill}"/>`;
  return quad(140, 380, 155, 790, C.creamDk) + quad(140, 380, 470, 790, '#A9281F') + quad(140, 380, 560, 586, C.creamDk)
    + quad(255, 292, 225, 415, C.glass) + quad(205, 245, 225, 415, C.glass) + quad(155, 195, 225, 415, C.glass)
    + quad(140, 380, 760, 790, C.dark) + quad(160, 380, 800, 842, C.shadow);
}
const T = (pts, fn) => pts.map(fn);
function objects() {
  const attrs = (pts, angle, groundY, widthM) => ` data-shape="${pts.map(p => p.map(f1).join(',')).join(' ')}" data-shape-name="tram-face" data-angle="${angle}" data-ground-y="${groundY}" data-width-m="${widthM.toFixed(2)}"`;
  const marker = pts => `<polygon data-role="shape" points="${pts.map(p => p.map(f1).join(',')).join(' ')}" fill="none" stroke="none"/>`;
  const out = {};
  out['tram.front'] = svg(600, 900, face() + marker(FACE_SHAPE), attrs(FACE_SHAPE, 'front', 842, TRAM_WIDTH_M));
  const leftShape = T(FACE_SHAPE, ([x, y]) => [x + 230, y]);
  const leftW = 800 / 600 * TRAM_WIDTH_M;
  out['tram.left'] = svg(800, 900, flankLeft() + `<g transform="translate(230 0)">${face()}</g>` + marker(leftShape), attrs(leftShape, 'left', 842, leftW));
  const rightShape = T(leftShape, ([x, y]) => [800 - x, y]);
  out['tram.right'] = svg(800, 900, `<g transform="translate(800 0) scale(-1 1)">${flankLeft()}<g transform="translate(230 0)">${face()}</g></g>` + marker(rightShape), attrs(rightShape, 'right', 842, leftW));
  const highShape = T(FACE_SHAPE, ([x, y]) => [x, y * 0.88 + 110]);
  const roof = `<path d="M70 392 L110 90 Q300 50 490 90 L530 392 Q530 224 300 224 Q70 224 70 392 Z" fill="${C.creamDk}"/>
<path d="M240 120 L300 180 L360 120" stroke="${C.dark}" stroke-width="7" fill="none" stroke-linecap="round"/><rect x="255" y="112" width="90" height="12" rx="4" fill="${C.dark}"/>
<rect x="250" y="200" width="100" height="16" rx="4" fill="#B9AA85"/>`;
  out['tram.high'] = svg(600, 960, roof + `<g transform="translate(0 110) scale(1 0.88)">${face({ pantograph: false })}</g>` + marker(highShape), attrs(highShape, 'high', 842 * 0.88 + 110, TRAM_WIDTH_M));
  const lowInner = face() + `<rect x="95" y="842" width="410" height="30" fill="${C.shadow}"/>
<circle cx="160" cy="880" r="42" fill="${C.dark}"/><circle cx="440" cy="880" r="42" fill="${C.dark}"/>
<circle cx="160" cy="880" r="18" fill="#55565C"/><circle cx="440" cy="880" r="18" fill="#55565C"/>`;
  out['tram.low'] = svg(600, 960, lowInner + marker(FACE_SHAPE), attrs(FACE_SHAPE, 'low', 922, TRAM_WIDTH_M));
  return out;
}

// ---------- Skies (1800×1200, full frame) ----------
const W = 1800, H = 1200, HORIZON = 760;
const grad = (id, stops) => `<linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1">${stops.map(([o, c]) => `<stop offset="${o}" stop-color="${c}"/>`).join('')}</linearGradient>`;
const cloud = (x, y, s) => `<g transform="translate(${x} ${y}) scale(${s})" fill="#FFFFFF" opacity="0.92"><ellipse cx="0" cy="0" rx="120" ry="42"/><ellipse cx="-50" cy="-22" rx="60" ry="46"/><ellipse cx="30" cy="-34" rx="72" ry="56"/><ellipse cx="90" cy="-10" rx="52" ry="38"/></g>`;
function skies() {
  const sky = (stops, extra = '', light) => svg(W, H, `<defs>${grad('g', stops)}</defs><rect width="${W}" height="${H}" fill="url(#g)"/>${extra}`, light ? ` data-light="${light}"` : '');
  return {
    'sky.clear': sky([[0, '#4F8FD6'], [1, '#CFE6F7']]),
    'sky.clouds': sky([[0, '#6BA1DC'], [1, '#D8E9F5']], cloud(420, 260, 1.3) + cloud(1120, 180, 1) + cloud(1500, 400, 0.8) + cloud(150, 520, 0.6)),
    'sky.sun': sky([[0, '#3F86D3'], [1, '#BFE0F5']], `<circle cx="1380" cy="260" r="210" fill="#FFF3B0" opacity="0.35"/><circle cx="1380" cy="260" r="110" fill="#FFE98A"/>`),
    'sky.golden': sky([[0, '#C9663F'], [0.55, '#F2A65A'], [1, '#FBE1A6']], `<circle cx="760" cy="640" r="260" fill="#FFD27A" opacity="0.35"/><circle cx="760" cy="640" r="120" fill="#FFE4A0"/>` + cloud(1300, 300, 1.1).replace('#FFFFFF', '#F7C08A'), 'golden'),
    'sky.dusk': sky([[0, '#2D2A5C'], [0.6, '#7A4D8C'], [1, '#E58A8A']], `<circle cx="1180" cy="700" r="90" fill="#FFB27A" opacity="0.9"/>`, 'dusk'),
    'sky.night': sky([[0, '#060B1E'], [1, '#1B2A55']], `<circle cx="1360" cy="240" r="90" fill="#F3EFDD"/>` +
      [[200, 150], [520, 90], [860, 210], [1040, 120], [1620, 160], [300, 420], [1700, 480], [700, 380], [1220, 430], [980, 520]].map(([x, y]) => `<circle cx="${x}" cy="${y}" r="4" fill="#FFFFFF" opacity="0.85"/>`).join(''), 'night'),
  };
}

// ---------- Scenes (1800×1200, transparent sky, horizon y=760). Backdrop + ground only; the road is composed. ----------
// data-road: half = road half-width (m), tracks = rail-pair centres (m, negative = left), kerb/centre = draw or not.
const ground = fill => `<rect x="0" y="${HORIZON}" width="${W}" height="${H - HORIZON}" fill="${fill}"/>`;
const roadAttr = (groundFill, road) => ` data-horizon="${HORIZON}" data-ground="${groundFill}" data-road='${JSON.stringify(road)}'`;
function scenes() {
  const out = {};
  const twoLane = (surface, kerb) => ({ half: 3.5, tracks: [-1.75, 1.75], surface, kerb, centre: true });
  // city skyline
  let far = '', near = '';
  const farW = [140, 90, 200, 120, 160, 100, 220, 130, 180, 110, 150, 200]; let x = -20;
  farW.forEach((w, i) => { const h = 180 + ((i * 97) % 240); far += `<rect x="${x}" y="${HORIZON - h}" width="${w}" height="${h}" fill="#8A97AD"/>`; x += w + 8; });
  [[0, 260, 300], [300, 180, 420], [520, 320, 260], [880, 200, 380], [1120, 260, 320], [1420, 160, 460], [1620, 200, 300]].forEach(([bx, bw, bh]) => {
    near += `<rect x="${bx}" y="${HORIZON - bh}" width="${bw}" height="${bh}" fill="#55627C"/>`;
    for (let wy = HORIZON - bh + 30; wy < HORIZON - 40; wy += 46) for (let wx = bx + 22; wx < bx + bw - 30; wx += 44) near += `<rect x="${wx}" y="${wy}" width="20" height="26" fill="#C9D3E3" opacity="0.7"/>`;
  });
  out['scene.city'] = svg(W, H, far + near + ground('#6E727A'), roadAttr('#6E727A', twoLane('#4A4D55', '#9A9DA3')));
  // old town street
  let houses = ''; const pal = ['#D9A66B', '#E2B8A6', '#B9C9A4', '#E7D6A5', '#C98E7A', '#A9B7C9'];
  [[0, 280, 420], [280, 240, 500], [520, 300, 380], [820, 200, 640], [1020, 280, 440], [1300, 240, 520], [1540, 280, 400]].forEach(([hx, hw, hh], i) => {
    houses += `<rect x="${hx}" y="${HORIZON - hh}" width="${hw}" height="${hh}" fill="${pal[i % pal.length]}"/><polygon points="${hx - 10},${HORIZON - hh} ${hx + hw + 10},${HORIZON - hh} ${hx + hw / 2},${HORIZON - hh - 90}" fill="#7A3B33"/>`;
    for (let wy = HORIZON - hh + 60; wy < HORIZON - 70; wy += 90) for (let wx = hx + 30; wx < hx + hw - 40; wx += 70) houses += `<rect x="${wx}" y="${wy}" width="34" height="52" rx="3" fill="#5B4A3E"/>`;
    houses += `<rect x="${hx + hw / 2 - 30}" y="${HORIZON - 110}" width="60" height="110" rx="30" fill="#4A3A30"/>`;
  });
  houses += `<rect x="1120" y="${HORIZON - 620}" width="150" height="620" fill="#D9C8A0"/><polygon points="1110,${HORIZON - 620} 1280,${HORIZON - 620} 1195,${HORIZON - 800}" fill="#4F6B58"/>`;
  out['scene.oldtown'] = svg(W, H, houses + ground('#A69C8E'), roadAttr('#A69C8E', { half: 3.5, tracks: [-1.75, 1.75], surface: '#8E8579', kerb: '#BFB5A6', centre: false }));
  // hills
  const hill = (fill, d) => `<path d="${d}" fill="${fill}"/>`;
  const tree = (tx, ty, s) => `<g transform="translate(${tx} ${ty}) scale(${s})"><rect x="-6" y="0" width="12" height="40" fill="#5B4632"/><circle cx="0" cy="-20" r="46" fill="#3F7A3A"/></g>`;
  out['scene.hills'] = svg(W, H, hill('#A9C98A', `M0 ${HORIZON} Q450 480 900 620 Q1350 400 1800 600 V${HORIZON} Z`) + hill('#7FAF62', `M0 ${HORIZON} Q300 560 700 700 Q1200 560 1800 720 V${HORIZON} Z`) + tree(320, 690, 1) + tree(1450, 700, 0.8) + tree(1550, 720, 1.1) + ground('#5E9548'), roadAttr('#5E9548', twoLane('#7C7468', '#9B937F')));
  // mountains
  const peaks = `<polygon points="-100,${HORIZON} 250,330 420,520 650,260 880,560 1050,380 1300,220 1560,520 1900,400 1900,${HORIZON}" fill="#7F8CA3"/>
<polygon points="250,330 300,410 200,410" fill="#FFFFFF"/><polygon points="650,260 720,360 580,360" fill="#FFFFFF"/><polygon points="1300,220 1380,340 1220,340" fill="#FFFFFF"/>
<polygon points="-100,${HORIZON} 200,600 500,700 800,560 1100,690 1400,580 1700,680 1900,620 1900,${HORIZON}" fill="#5E6B82"/>` +
    Array.from({ length: 30 }, (_, i) => { const px = i * 62 - 20; return `<polygon points="${px},${HORIZON} ${px + 30},${HORIZON - 70 - (i % 3) * 20} ${px + 60},${HORIZON}" fill="#2F4A3A"/>`; }).join('');
  out['scene.mountains'] = svg(W, H, peaks + ground('#7FAF62'), roadAttr('#7FAF62', twoLane('#8A8273', '#A89F8C')));
  // depot: a wide apron with four tracks, no kerb or centre line
  const poles = [200, 1600, 380, 1420, 560, 1240].map((px, i) => `<rect x="${px}" y="${HORIZON - 300 + i * 40}" width="12" height="${300 - i * 40}" fill="#55565C"/>`).join('');
  const wires = `<path d="M900 ${HORIZON} L1800 ${HORIZON - 420} M900 ${HORIZON} L0 ${HORIZON - 420}" stroke="#55565C" stroke-width="3" fill="none"/>`;
  const shed = `<rect x="1150" y="${HORIZON - 260}" width="650" height="260" fill="#8FA1A9"/><polygon points="1140,${HORIZON - 260} 1800,${HORIZON - 260} 1800,${HORIZON - 330} 1140,${HORIZON - 300}" fill="#5F7078"/><rect x="1220" y="${HORIZON - 190}" width="180" height="190" fill="#3B454B"/><rect x="1470" y="${HORIZON - 190}" width="180" height="190" fill="#3B454B"/>`;
  out['scene.depot'] = svg(W, H, shed + poles + wires + ground('#8E8F93'), roadAttr('#8E8F93', { half: 9, tracks: [-5.25, -1.75, 1.75, 5.25], surface: '#84858A', kerb: null, centre: false }));
  return out;
}

// ---------- Composer ----------
const LIGHT = { golden: ['#E08A2E', 0.22], dusk: ['#5A4A8A', 0.32], night: ['#0E1838', 0.55] };
const ASPECT = { '3:2': [1800, 1200], '2:3': [1200, 1800], '1:1': [1200, 1200], '4:3': [1600, 1200], '16:9': [1920, 1080] };
const CAMERA_X = { left: -4.5, centre: 0, center: 0, right: 4.5 };   // pavement positions, metres from the road's centre line
const CAMERA_H = { front: 1.5, left: 1.5, right: 1.5, high: 4.5, low: 0.45 };
function nested(src, prefix, x, y, w, h, par = 'xMidYMid slice') {
  const vb = /viewBox="([^"]+)"/.exec(src)[1];
  let inner = src.replace(/^[\s\S]*?<svg[^>]*>\n?/, '').replace(/\n?<\/svg>\s*$/, '');
  inner = inner.replace(/id="([^"]+)"/g, `id="${prefix}-$1"`).replace(/url\(#([^)]+)\)/g, `url(#${prefix}-$1)`);
  return `<svg x="${x}" y="${y}" width="${w}" height="${h}" viewBox="${vb}" preserveAspectRatio="${par}" data-part="${prefix}">${inner}</svg>`;
}
const attr = (src, name) => new RegExp(`data-${name}=(?:"([^"]*)"|'([^']*)')`).exec(src)?.slice(1).find(v => v != null);

function compose(r, assets) {
  const [FW, FH] = ASPECT[r.aspect || '3:2'];
  const s = Math.max(FW / W, FH / H), offY = (FH - H * s) / 2;
  const sceneSrc = assets['scene.' + r.scene], skySrc = assets['sky.' + r.sky];
  const road = JSON.parse(attr(sceneSrc, 'road'));
  // camera
  const camX = typeof r.camera === 'number' ? r.camera : CAMERA_X[r.camera || 'centre'];
  const trackX = typeof r.track === 'number' ? r.track : r.track === 'right' ? road.tracks[road.tracks.length - 1] : road.tracks[0];
  let camH = r.camH ?? CAMERA_H[r.tram] ?? 1.5;
  const f = 1620 * s;                                   // ≈ 40 mm-equivalent lens, scaled with the backdrop crop
  const horizonShift = Math.max(-170, Math.min(170, -(camH - 1.5) * 42)) * s;
  const horizon = offY + HORIZON * s + horizonShift;
  // The photographer pans to put the tram at `cx` (default frame centre): the vanishing point slides sideways by the same amount.
  let cx = FW / 2;
  const px = (X, Z) => cx + f * (X - camX) / Z, py = Z => horizon + f * camH / Z;
  // object at the depth its on-screen size implies
  const angleFor = Z => { const a = Math.atan2(camX - trackX, Z) * 180 / Math.PI; return camH > 3 ? 'high' : camH < 0.8 ? 'low' : a < -6 ? 'left' : a > 6 ? 'right' : 'front'; }; // camera left of the tram → its near flank is on the viewer's left
  const probe = assets['tram.front'];
  const size = r.size ?? 0.4;
  const [, pw, ph] = /viewBox="0 0 (\d+) (\d+)"/.exec(probe).map(Number);
  const heightM = +attr(probe, 'width-m') * ph / pw;
  const Z = f * heightM / (size * FH);
  cx = FW * (r.cx ?? 0.5) - f * (trackX - camX) / Z;
  const tram = r.tram || angleFor(Z);
  const obj = assets['tram.' + tram];
  const [, ow, oh] = /viewBox="0 0 (\d+) (\d+)"/.exec(obj).map(Number);
  const wpx = f * +attr(obj, 'width-m') / Z, hpx = wpx * oh / ow, k = wpx / ow;
  const groundY = +attr(obj, 'ground-y');
  const xc = px(trackX, Z), yb = py(Z);
  const ox = xc - wpx / 2, oy = yb - groundY * k;
  // road layer
  const Z0 = f * camH / (FH + 60 - horizon), Zfar = 400, slack = (W * s - FW) / 2;
  const strip = (x1, x2, z1, z2, fill, op = 1) => `<polygon points="${f1(px(x1, z1))},${f1(py(z1))} ${f1(px(x2, z1))},${f1(py(z1))} ${f1(px(x2, z2))},${f1(py(z2))} ${f1(px(x1, z2))},${f1(py(z2))}" fill="${fill}"${op < 1 ? ` opacity="${op}"` : ''}/>`;
  let roadSvg = `<g data-part="road">`;
  if (road.kerb) roadSvg += strip(-road.half - 0.45, road.half + 0.45, Z0, Zfar, road.kerb);
  roadSvg += strip(-road.half, road.half, Z0, Zfar, road.surface);
  if (road.centre) for (let z = Z0; z < 160; z += 6) roadSvg += strip(-0.07, 0.07, z, z + 3, '#E8E4D8', 0.6);
  for (const t of road.tracks) roadSvg += strip(t - 0.75, t + 0.75, Z0, Zfar, '#000000', 0.06) + strip(t - 0.75, t - 0.68, Z0, Zfar, C.rail) + strip(t + 0.68, t + 0.75, Z0, Zfar, C.rail);
  roadSvg += `</g>`;
  const shadow = `<ellipse cx="${f1(xc)}" cy="${f1(yb)}" rx="${f1(wpx * 0.48)}" ry="${f1(wpx * 0.05)}" fill="#000000" opacity="0.25"/>`;
  // metadata
  const shape = attr(obj, 'shape').split(' ').map(p => p.split(',').map(Number)).map(([x, y]) => [ox + x * k, oy + y * k]);
  const xs = shape.map(p => p[0]), ys = shape.map(p => p[1]);
  const bb = { x: Math.min(...xs), y: Math.min(...ys), x2: Math.max(...xs), y2: Math.max(...ys) };
  bb.w = bb.x2 - bb.x; bb.h = bb.y2 - bb.y;
  const marginsF = { left: +(bb.x / FW).toFixed(3), top: +(bb.y / FH).toFixed(3), right: +((FW - bb.x2) / FW).toFixed(3), bottom: +((FH - bb.y2) / FH).toFixed(3) };
  const cells = [];
  for (let row = 0; row < 3; row++) for (let col = 0; col < 3; col++) {
    const cx0 = col * FW / 3, cy0 = row * FH / 3, ix = Math.max(0, Math.min(bb.x2, cx0 + FW / 3) - Math.max(bb.x, cx0)), iy = Math.max(0, Math.min(bb.y2, cy0 + FH / 3) - Math.max(bb.y, cy0));
    cells.push(+((ix * iy) / (bb.w * bb.h)).toFixed(3));
  }
  const cellNames = ['top-left', 'top-centre', 'top-right', 'mid-left', 'centre', 'mid-right', 'bottom-left', 'bottom-centre', 'bottom-right'];
  const cellIdx = cells.findIndex(v => v >= 0.95), cell = cellIdx >= 0 ? cellNames[cellIdx] : 'mixed';
  const light = LIGHT[attr(skySrc, 'light')];
  const inner = [
    nested(skySrc, 'sky', 0, 0, FW, FH),
    `<rect x="0" y="${f1(horizon)}" width="${FW}" height="${f1(FH - horizon)}" fill="${attr(sceneSrc, 'ground')}" data-part="ground"/>`,
    nested(sceneSrc, 'scene', f1(-slack + Math.max(-slack, Math.min(slack, cx - FW / 2))), f1(offY + horizonShift), f1(W * s), f1(H * s), 'xMinYMin meet'),
    roadSvg, shadow,
    nested(obj, 'tram', f1(ox), f1(oy), f1(wpx), f1(hpx), 'xMidYMid meet'),
    light ? `<rect width="${FW}" height="${FH}" fill="${light[0]}" opacity="${light[1]}" data-part="light"/>` : '',
    `<polygon data-role="shape" points="${shape.map(p => p.map(f1).join(',')).join(' ')}" fill="none" stroke="none"/>`,
  ].join('\n');
  const meta = { id: r.id, aspect: r.aspect || '3:2', width: FW, height: FH, scene: r.scene, sky: r.sky, tram, track: trackX, camera: camX, camH, vp: +(cx / FW).toFixed(3), distance: +Z.toFixed(1), size, cx: +(xc / FW).toFixed(3),
    bbox: { x: f1(bb.x), y: f1(bb.y), w: f1(bb.w), h: f1(bb.h) }, margins: marginsF, cells, cell };
  const attrs = ` data-id="${r.id}" data-scene="${r.scene}" data-sky="${r.sky}" data-tram="${tram}" data-track="${trackX}" data-camera="${camX}" data-cam-h="${camH}" data-distance-m="${meta.distance}" data-shape-bbox="${meta.bbox.x} ${meta.bbox.y} ${meta.bbox.w} ${meta.bbox.h}" data-margins="${marginsF.left} ${marginsF.top} ${marginsF.right} ${marginsF.bottom}" data-cells="${cells.join(' ')}" data-cell="${cell}"`;
  return { svg: svg(FW, FH, inner, attrs), meta };
}

async function build(readFile, saveFile, log = () => {}) {
  const recipes = JSON.parse(await readFile('kit/recipes.json'));
  const assets = { ...objects(), ...skies(), ...scenes() };
  for (const [name, src] of Object.entries(assets)) {
    const dir = name.startsWith('tram') ? 'objects' : name.startsWith('sky') ? 'skies' : 'scenes';
    await saveFile(`kit/${dir}/${name}.svg`, src);
  }
  const manifest = [];
  for (const r of recipes) {
    const { svg: out, meta } = compose(r, assets);
    const file = `kit/compositions/${r.id}.svg`;
    await saveFile(file, out);
    manifest.push({ file, ...meta });
  }
  await saveFile('kit/compositions/manifest.json', JSON.stringify(manifest, null, 1));
  log(`built ${Object.keys(assets).length} assets, ${manifest.length} compositions`);
  return manifest;
}

if (typeof module !== 'undefined') {
  module.exports = { build, compose, objects, skies, scenes };
  if (typeof require !== 'undefined' && require.main === module) {
    const fs = require('fs'), path = require('path'), root = path.join(__dirname, '..');
    build(p => fs.promises.readFile(path.join(root, p), 'utf8'), async (p, d) => { await fs.promises.mkdir(path.dirname(path.join(root, p)), { recursive: true }); await fs.promises.writeFile(path.join(root, p), d); }, console.log);
  }
}
