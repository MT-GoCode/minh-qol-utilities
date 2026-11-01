# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy", "scipy"]
# ///
"""Online tracker variants scored per word, ONE-TO-ONE (Hungarian): a spurious extra speaker costs its words.
A new speaker needs K consecutive 2 s windows (0.5 s hop) below the threshold; until then they keep the previous label.
analyze_sustain.py <rttm> <words.json> <windows.json>"""
import json, sys
from collections import Counter
import numpy as np
from scipy.optimize import linear_sum_assignment
ref = [(float(f[3]), float(f[3]) + float(f[4]), f[7]) for f in (l.split() for l in open(sys.argv[1]))]
words = json.load(open(sys.argv[2]))["words"]; rows = json.load(open(sys.argv[3]))["rows"]
E = [np.asarray(r["emb"], dtype=float) / np.linalg.norm(r["emb"]) for r in rows]
mids = np.array([(r["start"] + r["end"]) / 2 for r in rows])
wm = []
for w in words:
    m = (w["start"] + w["end"]) / 2
    who = {s for a, b, s in ref if a <= m < b}
    if len(who) == 1:
        wm.append((m, next(iter(who))))
spk = sorted({s for _, s in wm})
nref = len({s for _, _, s in ref})
for thr in (0.30, 0.35):
    for K in (1, 2, 3, 4, 6):
        sums, labs, pend, prev = [], [], [], 0
        for e in E:
            sims = [float(e @ (c / np.linalg.norm(c))) for c in sums]
            if sims and max(sims) >= thr:
                k = int(np.argmax(sims)); sums[k] = sums[k] + e; pend = []; prev = k
            else:
                pend.append(e)
                if len(pend) >= K:
                    sums.append(np.sum(pend, axis=0)); pend = []; prev = len(sums) - 1
            labs.append(prev)
        c = np.zeros((max(len(sums), 1), len(spk)))
        for m, s in wm:
            c[labs[int(np.argmin(abs(mids - m)))], spk.index(s)] += 1
        r, q = linear_sum_assignment(-c)
        print(f"  thr {thr:.2f} K={K}: clusters {len(sums):2d}/{nref}  one-to-one word accuracy {c[r, q].sum() / len(wm):.1%}")
