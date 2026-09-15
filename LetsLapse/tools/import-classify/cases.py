"""The shapes a card takes, and the verdict each must get. Run it after any
change to classify.py; the Kit port's tests are these same fixtures.

    python cases.py [charles.csv tram_bouncing.csv]

Timings are synthesised from a clean 306-frame 3.62 s run (Charles_ARW without
its rendered derivative) when a probe CSV is given, else from a generated one.
"""
import math, random, sys
from classify import classify, load

random.seed(7)


def seq(prefix, start, gaps, t_start, ext='.ARW'):
    ns, ts, t = [], [], t_start
    for i, g in enumerate([0] + list(gaps)):
        t += g
        ns.append(f"{prefix}{start + i:04d}{ext}")
        ts.append(t)
    return ns, ts


if len(sys.argv) > 1:
    names, times, _ = load(sys.argv[1])
    names, times = zip(*[(n, t) for n, t in zip(names, times) if 'Rendered' not in n])
    names, times = list(names), list(times)
else:
    names, times = seq('_WEX', 3517, [3.62] * 305, 1_788_200_967.2)
t0 = times[0]
tram = load(sys.argv[2])[:2] if len(sys.argv) > 2 else seq('frame-', 1, [1.0] * 5029, t0)

CASES = []   # (label, names, times, subsecond, expected)

CASES.append(("clean 306-frame run at 3.62 s", names, times, True, 'SHOOT'))
CASES.append(("tram: 5030 frames at 1.00 s", tram[0], tram[1], True, 'SHOOT'))
tn, tt = seq('_WEX', 3511, [40, 55, 32, 61, 45], t0 - 263)
CASES.append(("6 test shots (40–61 s) then the run", tn + names, tt + times, True, 'ask·strangers'))
tn, tt = seq('_WEX', 3512, [40, 42, 41, 43], t0 - 200)
CASES.append(("5 regular-ish test shots (40–43 s) then the run", tn + names, tt + times, True, 'ask·strangers'))
CASES.append(("the rendered derivative beside its frame",
              names[:1] + ['_WEX3518-Rendered.dng'] + names[1:], times[:1] + [times[1]] + times[1:], True, 'ask·strangers'))
CASES.append(("run with a 600 s pause after frame 150", names, times[:150] + [t + 600 for t in times[150:]], True, 'SHOOT'))
CASES.append(("run with a 3-day pause after frame 150", names, times[:150] + [t + 3 * 86400 for t in times[150:]], True, 'SHOOT'))
ns = [f"_WEX{3517 + i:04d}.ARW" for i in range(len(names) + 1)]
CASES.append(("stray snap between frame 150 and 151", ns, times[:150] + [times[149] + 100] + [t + 300 for t in times[150:]], True, 'ask·strangers'))
n2, t2 = seq('_WEX', 3823, [10] * 199, times[-1] + 7200)
CASES.append(("two shoots: 306 @3.62 s, 2 h hole, 200 @10 s", names + n2, times + t2, True, 'ask·beat-change'))
n2, t2 = seq('_WEX', 3717, [10] * 105, times[199])
CASES.append(("beat change 3.62 → 10 s at frame 200, no pause", names[:200] + n2[1:], times[:200] + t2[1:], True, 'ask·beat-change'))
gaps = [1.0 * 1.0003 ** i * random.uniform(0.98, 1.02) for i in range(4999)]
n7, t7 = seq('frame-', 1, gaps, t0, ext='.jpg')
CASES.append(("Holy Grail ramp 1.0 → 4.5 s over 5000 frames", n7, t7, True, 'SHOOT'))
gaps = [random.uniform(20, 900) for _ in range(20)] + [0.1] * 9 + [random.uniform(20, 900) for _ in range(30)]
n8, t8 = seq('DSC0', 100, gaps, t0)
CASES.append(("10-frame 0.1 s burst inside 50 snaps", n8, t8, True, 'photos'))
n9 = [x for nm in names for x in (nm, nm.replace('.ARW', '.JPG'))]
CASES.append(("RAW+JPEG pairs for the whole run", n9, [x for t in times for x in (t, t)], True, 'ask·pairs'))
CASES.append(("tram + cover.jpg", tram[0] + ['cover.jpg'], tram[1] + [tram[1][-1] + 3600], True, 'ask·strangers'))
n11, t11 = seq('_WEX', 1, [120] * 299, t0)
CASES.append(("slow shoot 120 s × 300", n11, t11, True, 'ask·slow'))
n11, t11 = seq('_WEX', 1, [900] * 99, t0)
CASES.append(("very slow 15 min × 100", n11, t11, True, 'ask·slow'))
CASES.append(("12 clean frames at 3.62 s", names[:12], times[:12], True, 'ask·short'))
CASES.append(("3 files", names[:3], times[:3], True, 'photos'))
CASES.append(("1 file", names[:1], times[:1], True, 'photo'))
gaps = [random.uniform(30, 1800) for _ in range(39)]
n14, t14 = seq('_WEX', 3477, gaps, t0 - 40000)
CASES.append(("40 irregular snaps then the run (mixed card)", n14 + names, t14 + times, True, 'ask·strangers'))
CASES.append(("frame-# sequence with no capture times", tram[0][:500], [None] * 500, True, 'ask·no-clock'))
ts = list(times); ts[100] = ts[101] = ts[102] = None
CASES.append(("run with 3 frames missing capture times", names, ts, True, 'ask·strangers'))
gaps = [random.uniform(5, 3600) for _ in range(399)]
n17, t17 = seq('IMG_', 1, gaps, t0, ext='.JPG')
CASES.append(("400 consecutive IMG_ snaps, irregular", n17, t17, True, 'photos'))
keep = [i for i in range(len(names)) if i not in (50, 51, 120, 200)]
CASES.append(("run with 4 frames deleted on the card", [names[i] for i in keep], [times[i] for i in keep], True, 'SHOOT'))
t = t0; ts = []
for i in range(300):
    ts.append(float(math.floor(t))); t += 1.2
n19 = [f"_DSC{i + 1:04d}.ARW" for i in range(300)]
CASES.append(("whole-second stamps at a 1.2 s beat (no SubSec)", n19, ts, False, 'SHOOT'))
tn, tt = seq('_DSC', -5, [40, 55, 32, 61, 45], ts[0] - 263)
CASES.append(("whole-second stamps, 6 test shots then the run", tn + n19, tt + ts, False, 'ask·strangers'))
n21, t21 = seq('IMG_2026083117', 2450, [3] * 199, t0, ext='.jpg')   # timestamp-named: steps by the interval
CASES.append(("timestamp-named frames stepping by 3", n21, t21, True, 'SHOOT'))

failed = 0
for label, ns, ts, sub, expected in CASES:
    v, info = classify(ns, ts, sub)
    ok = v == expected
    failed += not ok
    extra = {k: info[k] for k in ('beat', 'pauses', 'n_strangers', 'after_cleanup') if info.get(k) not in (None, 0, [])}
    print(f"{'ok ' if ok else 'FAIL'} {label:50s} → {v:16s} {extra} {info.get('strangers', [])[:4]}")
print(f"\n{len(CASES) - failed}/{len(CASES)} as expected")
sys.exit(1 if failed else 0)
