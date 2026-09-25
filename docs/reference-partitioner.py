MAX_RULES = 150_000

class Unsatisfiable(Exception): pass
class NotCanonical(Exception): pass

def is_exception(r): return r["action"]["type"] == "ignore-previous-rules"

def canonicalize(rules):
    """ABP -> WebKit canonical form.

    Valid ONLY as part of ABP semantics, where `@@` exceptions are
    position-independent and always defeat a matching block. Hoisting them to
    the tail preserves that meaning. Applying this to hand-authored WebKit JSON
    (where order IS significant) would change behaviour.
    """
    return [r for r in rules if not is_exception(r)] + [r for r in rules if is_exception(r)]

def assert_canonical(rules):
    seen_exception = False
    for i, r in enumerate(rules):
        if is_exception(r):
            seen_exception = True
        elif seen_exception:
            raise NotCanonical(
                f"action rule at index {i} follows an ignore-previous-rules rule. "
                "Partitioning would change its meaning. Run canonicalize() first "
                "if and only if these came from ABP-syntax filters."
            )

def partition(rules, max_rules=MAX_RULES):
    assert_canonical(rules)
    actions    = [r for r in rules if not is_exception(r)]
    exceptions = [r for r in rules if is_exception(r)]

    if not actions:
        return [exceptions] if exceptions else []

    capacity = max_rules - len(exceptions)
    if capacity < 1:
        raise Unsatisfiable(
            f"{len(exceptions)} exceptions leave no room for action rules "
            f"(cap {max_rules}). Narrow the list selection.")

    return [actions[i:i+capacity] + exceptions
            for i in range(0, len(actions), capacity)]

# ---- oracle -----------------------------------------------------------
def matches(rule, url, domain):
    t = rule["trigger"]
    if t["url-filter"] not in url: return False
    if "if-domain" in t and domain not in t["if-domain"]: return False
    return True

def evaluate_single_list(rules, url, domain):
    acc = set()
    for r in rules:
        if not matches(r, url, domain): continue
        if is_exception(r): acc.clear()
        else: acc.add(r["action"]["type"])
    return acc

def evaluate_many_lists(chunks, url, domain):
    out = set()
    for c in chunks: out |= evaluate_single_list(c, url, domain)
    return out
