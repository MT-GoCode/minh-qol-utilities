# /// script
# dependencies = ["numpy"]
# ///
"""Simulate the online SpeakerTracker on held-out speakers.

Each session: k random speakers, their clips interleaved in random order, each clip cropped to L s.
Tracker: cosine to running-mean centroids; >= THR joins the best, else new speaker.
Reports, per (k, L): fraction of sessions with exactly k clusters and mean purity (fraction of
segments whose cluster's majority speaker is their speaker).
"""
import json
import random
import sys
from collections import Counter, defaultdict

import numpy as np

rows = json.load(open(sys.argv[1]))["rows"]
THR = float(sys.argv[2]) if len(sys.argv) > 2 else 0.45
emb = defaultdict(dict)  # (speaker, seconds) -> {clip: unit vec}
for r in rows:
    v = np.asarray(r["wespeaker"], dtype=np.float64)
    emb[(r["speaker"], r["seconds"])][r["clip"]] = v / np.linalg.norm(v)
speakers = sorted({s for s, _ in emb})
rng = random.Random(0)

def session(k, L):
    spks = rng.sample([s for s in speakers if len(emb[(s, L)]) >= 4], k)
    seq = [(s, e) for s in spks for e in emb[(s, L)].values()]
    rng.shuffle(seq)
    sums, labels = [], []
    for s, e in seq:
        sims = [float(e @ (c / np.linalg.norm(c))) for c in sums]
        if sims and max(sims) >= THR:
            i = int(np.argmax(sims))
            sums[i] = sums[i] + e
        else:
            i = len(sums)
            sums.append(e.copy())
        labels.append((s, i))
    by_cluster = defaultdict(Counter)
    for s, i in labels:
        by_cluster[i][s] += 1
    purity = sum(c.most_common(1)[0][1] for c in by_cluster.values()) / len(labels)
    return len(sums) == k, purity, len(sums)

print(f"threshold {THR}")
for L in [1.5, 2.0, 3.0]:
    for k in [2, 3, 4, 6]:
        res = [session(k, L) for _ in range(300)]
        exact = np.mean([r[0] for r in res])
        print(f"  L={L}s k={k}: exact-count {exact:6.1%}  purity {np.mean([r[1] for r in res]):6.1%}  "
              f"clusters min/median/max {min(r[2] for r in res)}/{int(np.median([r[2] for r in res]))}/"
              f"{max(r[2] for r in res)}")
