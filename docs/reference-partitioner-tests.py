import random, itertools
from partition import partition, canonicalize, assert_canonical, evaluate_single_list, evaluate_many_lists, Unsatisfiable, NotCanonical

def block(f, dom=None):
    t = {"url-filter": f}
    if dom: t["if-domain"] = dom
    return {"trigger": t, "action": {"type": "block"}}

def hide(f, sel):
    return {"trigger": {"url-filter": f}, "action": {"type": "css-display-none", "selector": sel}}

def allow(f, dom=None):
    t = {"url-filter": f}
    if dom: t["if-domain"] = dom
    return {"trigger": t, "action": {"type": "ignore-previous-rules"}}

def naive_partition(rules, max_rules):
    "The obvious-but-wrong version: straight slicing, no replication."
    return [rules[i:i+max_rules] for i in range(0, len(rules), max_rules)]

# ---------------------------------------------------------------- 1
def test_exception_survives_split():
    rules = [block("/ads/"), block("/track/"), block("/pixel/"), allow("/ads/", ["good.com"])]
    chunks = partition(rules, max_rules=3)   # forces a split
    got  = evaluate_many_lists(chunks, "https://good.com/ads/x.js", "good.com")
    want = evaluate_single_list(rules,  "https://good.com/ads/x.js", "good.com")
    assert got == want == set(), f"whitelist broken: {got}"
    return chunks

# ---------------------------------------------------------------- 2
def test_naive_partition_is_broken():
    rules = [block("/ads/"), block("/track/"), block("/pixel/"), allow("/ads/", ["good.com"])]
    chunks = naive_partition(rules, 3)       # [b,b,b] , [allow]
    got  = evaluate_many_lists(chunks, "https://good.com/ads/x.js", "good.com")
    want = evaluate_single_list(rules,  "https://good.com/ads/x.js", "good.com")
    assert got != want, "expected the naive version to fail"
    return got, want

# ---------------------------------------------------------------- 3
def test_capacity_accounting():
    rules = [block(f"/a{i}/") for i in range(10)] + [allow("/a3/"), allow("/a7/")]
    chunks = partition(rules, max_rules=6)    # capacity = 6-2 = 4
    assert all(len(c) <= 6 for c in chunks), [len(c) for c in chunks]
    assert len(chunks) == 3, len(chunks)      # ceil(10/4)
    return [len(c) for c in chunks]

# ---------------------------------------------------------------- 4
def test_unsatisfiable():
    rules = [block("/x/")] + [allow(f"/e{i}/") for i in range(5)]
    try:
        partition(rules, max_rules=5)
    except Unsatisfiable as e:
        return str(e)
    raise AssertionError("should have raised")

# ---------------------------------------------------------------- 5
def test_rejects_non_canonical():
    rules = [allow("/ads/"), block("/ads/")]
    try:
        partition(rules, 50)
    except NotCanonical as e:
        return str(e)[:70] + "..."
    raise AssertionError("should have rejected")

def test_canonicalize_matches_abp_semantics():
    """After canonicalize, exception wins -- which is what ABP `@@` means."""
    rules = canonicalize([allow("/ads/"), block("/ads/")])
    assert evaluate_single_list(rules, "https://x.com/ads/a.js", "x.com") == set()
    return "exception wins, as ABP requires"

def test_differential_random(trials=3000, seed=7):
    rng = random.Random(seed)
    frags  = ["/ads/", "/track/", "/pixel/", "/beacon/", "/cdn/"]
    domains = ["good.com", "bad.com", "news.org"]
    fails = 0
    for _ in range(trials):
        rules = []
        for _ in range(rng.randint(4, 14)):
            k = rng.random()
            f = rng.choice(frags)
            d = rng.choice([None, [rng.choice(domains)]])
            if k < 0.55:   rules.append(block(f, d))
            elif k < 0.80: rules.append(hide(f, ".ad"))
            else:          rules.append(allow(f, d))
        rules = canonicalize(rules)
        cap = rng.randint(3, 8)
        if cap - sum(1 for r in rules if r["action"]["type"] == "ignore-previous-rules") < 1:
            continue
        chunks = partition(rules, max_rules=cap)
        for url_f, dom in itertools.product(frags, domains):
            url = f"https://{dom}{url_f}z.js"
            if evaluate_many_lists(chunks, url, dom) != evaluate_single_list(rules, url, dom):
                fails += 1
    return fails

if __name__ == "__main__":
    print("1 exception survives split :", test_exception_survives_split())
    g, w = test_naive_partition_is_broken()
    print(f"2 naive partition          : got={g} want={w}  <- the bug")
    print("3 capacity accounting      :", test_capacity_accounting())
    print("4 unsatisfiable            :", test_unsatisfiable())
    print("5 rejects non-canonical    :", test_rejects_non_canonical())
    print("6 canonicalize == ABP      :", test_canonicalize_matches_abp_semantics())
    f = test_differential_random()
    print(f"7 differential (3000 cases x 15 probes): {f} mismatches")
    assert f == 0
    print("\nALL PASS")
