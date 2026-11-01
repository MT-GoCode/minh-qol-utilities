# /// script
# dependencies = ["numpy"]
# ///
"""Speaker-embedding separation per model and segment length.

pair_eer: equal error rate of raw same-vs-different-speaker cosine over all clip pairs.
centroid: the online-clustering case. Each test segment is scored against per-speaker centroids
built from up to 4 *other* clips (longest crop of each); reports top-1 accuracy over 20 speakers and the EER/threshold
of "own centroid" vs "best other centroid" similarity (the new-speaker decision).
"""
import json
import sys
from collections import defaultdict

import numpy as np

rows = json.load(open(sys.argv[1]))["rows"]

def unit(v):
    v = np.asarray(v, dtype=np.float64)
    return v / np.linalg.norm(v)

def eer(same, diff):
    same, diff = np.asarray(same), np.asarray(diff)
    best = (2.0, 0.0)
    for t in np.unique(np.concatenate([same, diff])):
        frr, far = (same < t).mean(), (diff >= t).mean()
        if abs(frr - far) < best[0]:
            best = (abs(frr - far), t, (frr + far) / 2)
    return best[2], best[1]

for model in ["campplus", "wespeaker"]:
    by_len = defaultdict(list)
    for r in rows:
        by_len[r["seconds"]].append((r["speaker"], r["clip"], unit(r[model])))
    full = {}  # longest available crop per clip
    for L in sorted(by_len):
        full.update({(s, c): e for s, c, e in by_len[L]})
    print(f"\n{model}")
    for L in sorted(by_len):
        items = by_len[L]
        same, diff = [], []
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                cos = float(items[i][2] @ items[j][2])
                (same if items[i][0] == items[j][0] else diff).append(cos)
        pe, pt = eer(same, diff)
        own, other, hits = [], [], 0
        for spk, clip, e in items:
            cents = {}
            for (s, c), fe in full.items():
                if c != clip:
                    cents.setdefault(s, []).append(fe)
            cents = {s: unit(np.mean(v[:4], axis=0)) for s, v in cents.items()}
            sims = {s: float(e @ ce) for s, ce in cents.items()}
            best_other = max(v for s, v in sims.items() if s != spk)
            own.append(sims[spk])
            other.append(best_other)
            hits += sims[spk] > best_other
        ce, ct = eer(own, other)
        print(f"  {L:>4}s  n={len(items):3d}  pair_eer={pe:6.2%} @ {pt:.3f}   "
              f"centroid top1={hits / len(items):6.2%}  new-speaker eer={ce:6.2%} @ {ct:.3f}")
