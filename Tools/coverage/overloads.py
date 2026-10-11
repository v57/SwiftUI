# Signature-level coverage of View modifiers: argument labels (+ coarse type of unlabeled params).
import re, subprocess, glob, sys
import os, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.environ.get('INVENTORY_OUT', tempfile.gettempdir())
sdk = subprocess.check_output(['xcrun','--show-sdk-path']).decode().strip()
files = [f'{sdk}/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface',
         f'{sdk}/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface']

def balanced(s, i, open_, close):
    d = 0
    for j in range(i, len(s)):
        if s[j] == open_: d += 1
        elif s[j] == close:
            d -= 1
            if d == 0: return j
    return -1

def split_top(s):
    out, d, cur = [], 0, ''
    for ch in s:
        if ch in '(<[': d += 1
        elif ch in ')>]': d -= 1
        if ch == ',' and d == 0: out.append(cur); cur = ''
        else: cur += ch
    if cur.strip(): out.append(cur)
    return out

def parse(text, i):
    """text[i:] starts after 'func name'. Returns (params[(label, type, hasDefault)], generics set)."""
    j = i
    generics = set()
    while text[j] == ' ': j += 1
    if text[j] == '<':
        e = balanced(text, j, '<', '>')
        for g in split_top(text[j+1:e]):
            generics.add(re.split(r'[:\s]', g.strip())[0])
        j = e + 1
    while text[j] == ' ': j += 1
    if text[j] != '(': return None
    e = balanced(text, j, '(', ')')
    params = []
    for p in split_top(text[j+1:e]):
        p = p.strip()
        if not p: continue
        m = re.match(r'(?:(\w+)\s+)?(\w+)\s*:\s*(.*)$', p, re.S)
        if not m: continue
        label = m.group(1) or m.group(2)
        rest = m.group(3)
        has_default = False
        dm = split_eq(rest)
        if dm is not None: rest, has_default = dm, True
        params.append((label, norm(rest, generics), has_default))
    return params

def split_eq(t):
    d = 0
    for k, ch in enumerate(t):
        if ch in '(<[': d += 1
        elif ch in ')>]': d -= 1
        elif ch == '=' and d == 0 and (k + 1 >= len(t) or t[k+1] != '=') and (k == 0 or t[k-1] not in '-<>!='):
            return t[:k].strip()
    return None

def norm(t, generics):
    t = re.sub(r'@\w+(\([^)]*\))?\s*', '', t).strip()
    t = t.replace('inout ', '').replace('::', '.').strip()
    if '->' in t: return 'fn'
    opt = t.endswith('?')
    t = t.rstrip('?!').strip()
    if t.startswith('some ') or t.startswith('any '): return 'G'
    if t.startswith('['): return 'array' + ('?' if opt else '')
    base = re.sub(r'<.*', '', t)
    base = base.split('.')[-1] if not base.startswith('(') else 'tuple'
    if base in generics or base == 'Self': base = 'G'
    if base in ('Double', 'CGFloat', 'Float', 'Int'): base = 'num'
    return base + ('?' if opt else '')

def key_ok(apple, ours):
    """Apple's full call (all params given) is accepted by `ours`."""
    k = 0
    for (label, typ, dflt) in ours:
        if k < len(apple) and apple[k][0] == label and (label != '_' or compat(apple[k][1], typ)):
            k += 1
        elif not dflt:
            return False
    return k == len(apple)

def compat(a, b):
    return a == b or 'G' in (a.rstrip('?'), b.rstrip('?')) or a.rstrip('?') == b.rstrip('?')

apple = {}
for path in files:
    text = open(path).read()
    lines = text.split('\n')
    depth = 0; ext = []; attrs = []
    for line in lines:
        s = line.strip()
        if s.startswith('@'): attrs.append(s)
        unavailable = any(('macOS, unavailable' in a) or ('*, unavailable' in a) for a in attrs)
        deprecated = any('deprecated' in a for a in attrs)
        m = re.match(r'(?:@\S+\s+)*extension\s+([\w.:]+)', s)
        if m and '{' in s: ext.append((depth, re.split(r'\.|::', m.group(1))[-1], unavailable))
        cur = ext[-1] if ext else None
        fm = re.search(r'public (?:static )?func (\w+)', s)
        if fm and cur and cur[1] == 'View' and not unavailable and not cur[2] and not deprecated and not fm.group(1).startswith('_'):
            p = parse(s, fm.end())
            if p is not None: apple.setdefault(fm.group(1), []).append((p, s))
        depth += s.count('{') - s.count('}')
        while ext and depth <= ext[-1][0]: ext.pop()
        if s and not s.startswith('@'): attrs = []

ours = {}
for f in glob.glob('' + ROOT + '/Sources/SwiftUI*/**/*.swift', recursive=True):
    text = open(f).read()
    # offsets of `extension View` bodies (brace matched)
    spans = []
    for m in re.finditer(r'^\s*(?:@\w+\s+)*(?:public\s+)?extension\s+(?:_SwiftUICore\.)?View\b[^{]*\{', text, re.M):
        e = balanced(text, m.end() - 1, '{', '}')
        spans.append((m.end(), e))
    for m in re.finditer(r'func (\w+)', text):
        if not any(a <= m.start() < b for a, b in spans): continue
        try: p = parse(text, m.end())
        except Exception: p = None
        if p is not None: ours.setdefault(m.group(1), []).append(p)

missing = []
total = 0
for name, sigs in sorted(apple.items()):
    seen = set()
    for p, s in sigs:
        k = (tuple((l, t) for l, t, _ in p))
        if k in seen: continue
        seen.add(k)
        total += 1
        if not any(key_ok(p, o) for o in ours.get(name, [])):
            missing.append((name, p, s))
print(f'== View modifier overloads: {total-len(missing)}/{total} callable')
if '-v' in sys.argv:
    for name, p, s in missing:
        print(f"  {name}(" + ''.join(f"{l}:" if l != '_' else f"_{t}:" for l, t, _ in p) + ")")
