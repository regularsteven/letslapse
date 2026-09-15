"""Reference classifier for Create ▸ Import photos — a shoot, a pile of photos,
or a question. The rule the Kit port (`ImportedStills+Classification`) must
match; docs/import-classification.md is the spec, cases.py the fixtures.

    swiftc -O -o probe probe.swift            # ImageIO header probe, as the app reads
    ./probe /Volumes/letslapse/Source_SONY/Charles_ARW > charles.csv
    python classify.py charles.csv [more.csv…]

A SHOOT is a clean set: one name sequence, every frame on one beat, the only
irregularity a pause whose beat continues on the far side. Anything less is a
question, never a silent shoot. PHOTOS (one project per file) is silent only
when no beat of MIN_RUN frames exists anywhere in the set.
"""
import csv, re, sys, statistics as st
from collections import Counter

TOL = 0.35              # a gap is on the beat within ±35 % of the run's reference…
FLOOR = 0.5             # …or ±0.5 s, whichever is larger (sub-second stamps)
FLOOR_WHOLE_SECONDS = 1.0   # stamps without SubSecTimeOriginal are ±1 s quantised
CAP = 60.0              # a beat slower than this is a question, not a shoot
MIN_RUN = 24            # the shortest beat that counts as "a shoot is in here"
MIN_FILES = 5           # fewer files than this cannot be a shoot with any confidence
WINDOW = 8              # the run's reference is the median of its last WINDOW gaps


def stem_and_tail(name):
    """`_WEX3518-Rendered.dng` → ('_WEX#-Rendered', 3518); the tail is the LAST run of digits."""
    stem = name.rsplit('.', 1)[0]
    m = re.search(r'(\d+)(?!.*\d)', stem)
    if not m:
        return stem, None
    return stem[:m.start()] + '#' + stem[m.end():], int(m.group(1))


def name_sequence(names):
    """(is_sequence, strangers_by_name, pairs).

    A sequence: one stem pattern holds ≥ 95 % of the files, its numbers ascend,
    and ≥ 90 % of the steps equal the most common step (not "+1": timestamp-named
    frames step by the interval, a card with deletions steps 2 here and there).
    Strangers: every file outside the dominant stem, or with no number.
    Pairs: every number appears the same k > 1 times — RAW+JPEG, one exposure
    per k files — reported as its own answer rather than as strangers."""
    parsed = [stem_and_tail(n) for n in names]
    stems = Counter(s for s, _ in parsed)
    dominant, share = stems.most_common(1)[0]
    strangers = [n for n, (s, t) in zip(names, parsed) if s != dominant or t is None]
    tails = [t for (s, t) in parsed if s == dominant and t is not None]
    counts = Counter(tails)
    dup = {t for t, c in counts.items() if c > 1}
    pairs = bool(dup) and len(set(counts.values())) == 1
    if dup and not pairs:   # one number twice among singles: the duplicate is a stranger
        strangers += [n for n, (s, t) in zip(names, parsed) if s == dominant and t in dup]
    uniq = list(dict.fromkeys(tails))
    steps = [b - a for a, b in zip(uniq, uniq[1:])]
    modal = Counter(steps).most_common(1)[0][1] / len(steps) if steps else 0
    is_seq = share / len(names) >= 0.95 and all(s > 0 for s in steps) and modal >= 0.9
    return is_seq, sorted(set(strangers), key=names.index), pairs


def on_beat(g, ref, floor=FLOOR):
    return abs(g - ref) <= max(floor, TOL * ref)


def find_runs(gaps, floor=FLOOR):
    """Maximal stretches of consecutive gaps where each gap is on the beat of the
    previous ≤ WINDOW gaps of the same stretch (a slowly ramping interval stays on
    the beat; a test shot, a pause or a stray does not). [(first_gap, last_gap)]."""
    runs, start = [], 0
    for i in range(1, len(gaps)):
        ref = st.median(gaps[max(start, i - WINDOW):i])
        if not on_beat(gaps[i], ref, floor):
            runs.append((start, i - 1))
            start = i
    if gaps:
        runs.append((start, len(gaps) - 1))
    return runs


def classify(names, times, subsecond=True):
    """→ (verdict, info). Verdicts: 'photo' (one file), 'photos', 'SHOOT', or
    'ask·<case>' with case ∈ strangers · pairs · beat-change · slow · short · no-clock."""
    n = len(names)
    floor = FLOOR if subsecond else FLOOR_WHOLE_SECONDS
    if n == 1:
        return 'photo', {}
    if n < MIN_FILES:
        return 'photos', {'why': f'{n} files'}
    is_seq, name_strangers, pairs = name_sequence(names)
    if is_seq and pairs and not name_strangers:
        return 'ask·pairs', {'names': True, 'why': 'every number appears more than once'}
    if all(t is None for t in times):
        return ('ask·no-clock' if is_seq else 'photos'), {'names': is_seq}

    # The clock is read on the files that pass the name test — the folder as it
    # would be once tidied — so the question can say what it becomes.
    clock_strangers = [nm for nm, t in zip(names, times) if t is None and nm not in name_strangers]
    idx = [i for i, t in enumerate(times) if t is not None and names[i] not in name_strangers]
    gaps = [times[b] - times[a] for a, b in zip(idx, idx[1:])]
    runs = [(a, b) for a, b in find_runs(gaps, floor) if (b - a + 2) >= MIN_RUN]   # frames = gaps + 1
    covered = set()
    for a, b in runs:
        covered.update(range(a, b + 2))
    beat_strangers = [names[idx[i]] for i in range(len(idx)) if i not in covered]

    # Adjacent runs whose beat continues across the join are one run with a
    # pause in it (a battery swap, a deleted frame). A beat that changes is not.
    merged, beats = [], []
    for a, b in runs:
        beat_in = st.median(gaps[a:min(b + 1, a + WINDOW)])
        beat_out = st.median(gaps[max(a, b - WINDOW + 1):b + 1])
        if merged and merged[-1][1] + 2 >= a and on_beat(beat_in, beats[-1][1], floor):
            merged[-1] = (merged[-1][0], b)
            beats[-1] = (beats[-1][0], beat_out)
        else:
            merged.append((a, b))
            beats.append((beat_in, beat_out))
    pauses = sum(1 for k in range(len(runs) - 1) if runs[k][1] + 1 < runs[k + 1][0])

    strangers = list(dict.fromkeys(name_strangers + clock_strangers + beat_strangers))
    beat = st.median(gaps[merged[0][0]:merged[0][1] + 1]) if merged else None
    tidy = is_seq and not clock_strangers and not beat_strangers and len(merged) == 1
    info = dict(names=is_seq, runs=len(merged), strangers=strangers[:8], n_strangers=len(strangers),
                beat=beat and round(beat, 2), pauses=pauses,
                after_cleanup=('shoot' if tidy and beat <= CAP else 'slow' if tidy else None) if name_strangers else None)
    clean = tidy and not name_strangers
    if clean and beat <= CAP:
        return 'SHOOT', info
    if clean:
        return 'ask·slow', info
    if not runs:
        # a clean short sequence has no run of MIN_RUN but may still be one beat
        if is_seq and not name_strangers and not clock_strangers and len(gaps) >= 2 \
                and len(find_runs(gaps, floor)) == 1:
            info.update(strangers=[], n_strangers=0)
            return 'ask·short', info
        return 'photos', info
    if is_seq and not strangers and len(merged) > 1:
        return 'ask·beat-change', info
    if not strangers:
        return 'ask·names', info      # not a name sequence, yet the clock found a run
    return 'ask·strangers', info


def load(path):
    rows = list(csv.DictReader(open(path)))
    names = [r['name'] for r in rows]
    times = [float(r['epoch']) if r['epoch'] else None for r in rows]
    subsecond = any(r['dateSource'].endswith('+sub') for r in rows)
    return names, times, subsecond


if __name__ == '__main__':
    for f in sys.argv[1:]:
        names, times, subsecond = load(f)
        v, info = classify(names, times, subsecond)
        print(f"{f:24s} {v:16s} {info}")
