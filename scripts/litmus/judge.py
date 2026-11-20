#!/usr/bin/env python3
"""Litmus judge: turn paired old/new outcomes into a verdict. Runs no sessions.

One case is run as pairs: the old wording and the new wording answer the same
question with the same option order, back to back. Each pair is one of
  worse   old passed, new failed
  better  old failed, new passed
  same    both passed or both failed
A case is looked at only at fixed decision points (first, first+step, ..., cap
pairs) and stops at the first decision:
  worse      the worse pairs outnumber the better ones beyond chance
  better     the reverse
  holds      new is shown not to be worse than old by more than the margin
  undecided  the cap was reached with none of the above
The comparison's verdict: `regress` if any case is worse, `pass` if every case
is better or holds, else `inconclusive`.

False alarms. If the two wordings are the same, a pair is as likely to be
worse as better, whatever the pass rate. So the chance that a case is flagged
worse or better on identical files can be computed exactly for this stopping
rule (false_alarm below), and the threshold is set from that calculation so
the whole comparison, across all its cases and decision points, stays within
Rules.alpha. That holds if repeats are independent of each other, which no
arithmetic can show: only same-file comparisons on real runs can.
"""
from collections import defaultdict
from dataclasses import dataclass
from functools import lru_cache
from math import comb, sqrt
from statistics import NormalDist


@dataclass(frozen=True)
class Rules:
    alpha: float = 0.05      # chance, per comparison, of flagging any case on identical files
    margin: float = 0.15     # holds: new is not worse than old by more than this
    hold_conf: float = 0.99  # strictness of the margin bound. Set so that, with these decision points,
                             # a true drop equal to the margin is called `holds` under 5% of the time
                             # (0.95 would miss 13% at the extremes; the tests pin this)
    first: int = 8           # pairs before the first decision point
    step: int = 4            # pairs between decision points
    cap: int = 30            # most pairs per case

    def __post_init__(self):
        if not (0 < self.alpha < 1 and 0 < self.margin < 1 and 0.5 < self.hold_conf < 1
                and 1 <= self.first <= self.cap and self.step >= 1):
            raise ValueError(f"unusable rules: {self}")

    def looks(self):
        out = list(range(self.first, self.cap, self.step))
        return tuple(out + [self.cap])


def sign_p(k, d):
    """Chance of k or more out of d when each is a fair coin."""
    return sum(comb(d, i) for i in range(k, d + 1)) / 2 ** d if d else 1.0


def false_alarm(nominal, looks, discord):
    """Exact chance that one case is flagged worse (the same for better) when
    the wordings do not differ and a pair disagrees with probability discord."""
    state, crossed, n = {(0, 0): 1.0}, 0.0, 0
    for look in looks:
        for _ in range(look - n):
            nxt = defaultdict(float)
            for (b, c), p in state.items():
                nxt[(b, c)] += p * (1 - discord)
                nxt[(b + 1, c)] += p * discord / 2
                nxt[(b, c + 1)] += p * discord / 2
            state = nxt
        n = look
        keep = {}
        for (b, c), p in state.items():
            if sign_p(b, b + c) <= nominal:
                crossed += p                      # flagged worse: the case stops
            elif sign_p(c, b + c) > nominal:
                keep[(b, c)] = p                  # not flagged better either: it goes on
        state = keep
    return crossed


DISCORD_GRID = tuple(i / 40 for i in range(1, 41))


def worst_false_alarm(nominal, looks):
    return max(false_alarm(nominal, looks, d) for d in DISCORD_GRID)


@lru_cache(maxsize=None)
def threshold(n_cases, rules):
    """The largest per-look threshold that keeps the whole comparison within
    rules.alpha: alpha is shared across the cases and the two directions."""
    side = rules.alpha / (2 * max(n_cases, 1))
    looks = rules.looks()
    cands = sorted({sign_p(k, d) for d in range(1, rules.cap + 1) for k in range(d + 1)})
    lo, hi, best = 0, len(cands) - 1, 0.0
    while lo <= hi:
        mid = (lo + hi) // 2
        if worst_false_alarm(cands[mid], looks) <= side:
            best, lo = cands[mid], mid + 1
        else:
            hi = mid - 1
    return best


def drop_bound(b, c, n, conf):
    """Upper confidence bound on how far the new pass rate sits below the old
    one, from b worse and c better pairs of n (Bonett-Price adjusted interval
    for a paired difference; its miss rate is pinned by the tests)."""
    z = NormalDist().inv_cdf(conf)
    pb, pc = (b + 1) / (n + 2), (c + 1) / (n + 2)
    d = pb - pc
    return d + z * sqrt(max(pb + pc - d * d, 0.0) / (n + 2))


def judge_case(pairs, n_cases, rules=Rules(), final=False):
    """pairs: (old_passed, new_passed) in run order. Looks only at the decision
    points reached, in order, and reports the first decision, as a live run does.
    final=True means no more pairs are coming (the run was cut short)."""
    nominal, out = threshold(n_cases, rules), None
    for look in rules.looks():
        if look > len(pairs):
            break
        seen = pairs[:look]
        b = sum(1 for o, n in seen if o and not n)
        c = sum(1 for o, n in seen if n and not o)
        out = {"pairs": look, "worse": b, "better": c,
               "old": sum(o for o, _ in seen) / look, "new": sum(n for _, n in seen) / look}
        not_worse = drop_bound(b, c, look, rules.hold_conf) < rules.margin
        if sign_p(b, b + c) <= nominal:
            return out | {"state": "worse"}
        if sign_p(c, b + c) <= nominal:
            return out | {"state": "better"}
        if not_worse and drop_bound(c, b, look, rules.hold_conf) < rules.margin:
            return out | {"state": "holds"}       # no movement either way: stop early
        if look == rules.cap:
            return out | {"state": "holds" if not_worse else "undecided"}
    if out is None:
        n = len(pairs)
        out = {"pairs": n, "worse": sum(1 for o, x in pairs if o and not x),
               "better": sum(1 for o, x in pairs if x and not o),
               "old": sum(o for o, _ in pairs) / n if n else 0.0,
               "new": sum(x for _, x in pairs) / n if n else 0.0}
    if final:
        return out | {"state": "undecided"}
    nxt = next(l for l in rules.looks() if l > len(pairs))
    return out | {"state": "open", "need": nxt - len(pairs)}


def verdict(states):
    """states: the state of every case in the comparison."""
    states = list(states)
    if any(s == "worse" for s in states):
        return "regress"
    if states and all(s in ("better", "holds") for s in states):
        return "pass"
    return "inconclusive"
