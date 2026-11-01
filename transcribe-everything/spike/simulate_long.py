# /// script
# dependencies = ["numpy"]
# ///
"""Long-session drift of the online SpeakerTracker on held-out speakers (every utterance, full length).

Session: k speakers; each turn picks a random speaker (never the same twice in a row) and plays that
speaker's next utterance, until every chosen speaker's utterances run out. Reports clusters created,
spurious clusters (beyond k), purity, and when spurious clusters appear (segment index).
Variants: plain running-mean centroids; and with merge = after each assignment, merge any two
centroids whose cosine >= threshold.
"""
import json
import random
import sys
from collections import Counter, defaultdict

import numpy as np

rows = json.load(open(sys.argv[1]))["rows"]
THR = float(sys.argv[2])
emb = defaultdict(list)
for r in rows:
    v = np.asarray(r["wespeaker"], dtype=np.float64)
    emb[r["speaker"]].append((r["seconds"], v / np.linalg.norm(v)))
speakers = sorted(emb)
unit = lambda v: v / np.linalg.norm(v)

def run(k, merge, rng):
    spks = rng.sample(speakers, k)
    pools = {s: rng.sample(emb[s], len(emb[s])) for s in spks}
    seq, last = [], None
    while any(pools.values()):
        choices = [s for s in spks if pools[s] and s != last] or [s for s in spks if pools[s]]
        last = rng.choice(choices)
        seq.append((last, pools[last].pop()))
    sums, owner, labels, spurious_at = [], [], [], []
    for idx, (s, (secs, e)) in enumerate(seq):
        if secs < 2.0:
            labels.append((s, labels[-1][1] if labels else 0))
            continue
        sims = [float(e @ unit(c)) for c in sums]
        if sims and max(sims) >= THR:
            i = int(np.argmax(sims))
            sums[i] = sums[i] + e
        else:
            i = len(sums)
            sums.append(e.copy())
            if len(sums) > k:
                spurious_at.append(idx)
        labels.append((s, i))
        if merge:
            merged = True
            while merged:
                merged = False
                for a in range(len(sums)):
                    for b in range(a + 1, len(sums)):
                        if float(unit(sums[a]) @ unit(sums[b])) >= THR:
                            sums[a] = sums[a] + sums.pop(b)
                            labels = [(x, a if y == b else y - (y > b)) for x, y in labels]
                            merged = True
                            break
                    if merged:
                        break
    live = sums
    by = defaultdict(Counter)
    for x, y in labels:
        by[y][x] += 1
    purity = sum(c.most_common(1)[0][1] for c in by.values()) / len(labels)
    return len(seq), len(live), purity, spurious_at

rng = random.Random(0)
print(f"threshold {THR}")
for merge in [False, True]:
    for k in [2, 3, 4]:
        res = [run(k, merge, rng) for _ in range(40)]
        segs = int(np.median([r[0] for r in res]))
        extra = [r[1] - k for r in res]
        print(f"  merge={merge!s:5} k={k} segments~{segs}: final clusters-k mean {np.mean(extra):+.2f} "
              f"(max {max(extra):+d}, min {min(extra):+d}); exact {np.mean([e == 0 for e in extra]):.0%}; "
              f"purity {np.mean([r[2] for r in res]):.1%}; first spurious at seg "
              f"{int(np.median([r[3][0] for r in res if r[3]])) if any(r[3] for r in res) else '-'}")
