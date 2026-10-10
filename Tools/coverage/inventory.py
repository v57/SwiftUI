import re, subprocess, glob, sys, os
import os, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.environ.get('INVENTORY_OUT', tempfile.gettempdir())
sdk = subprocess.check_output(['xcrun','--show-sdk-path']).decode().strip()
files = [f'{sdk}/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface',
         f'{sdk}/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface']
mods, views, others = {}, {}, {}
for path in files:
    lines = open(path).read().split('\n')
    depth = 0; ext_stack = []  # (depth_at_open, typename)
    attrs = []
    for line in lines:
        s = line.strip()
        if s.startswith('@'):
            attrs.append(s)
        unavailable = any(('macOS, unavailable' in a) or ('macos, unavailable' in a.lower()) or ('*, unavailable' in a) for a in attrs)
        deprecated = any('deprecated' in a for a in attrs)
        m = re.match(r'(?:@\S+\s+)*extension\s+([\w.:]+)', s)
        if m and '{' in s:
            ext_stack.append((depth, re.split(r'\.|::', m.group(1))[-1], unavailable))
        cur = ext_stack[-1] if ext_stack else None
        fm = re.search(r'public (?:static )?func (\w+)', s)
        if fm and cur and cur[1] == 'View' and not unavailable and not cur[2]:
            name = fm.group(1)
            if not name.startswith('_'):
                mods.setdefault(name, deprecated)
                if not deprecated: mods[name] = False
        sm = re.search(r'public struct (\w+)(<[^>{]*>)?\s*:\s*([^{]*)', s)
        if sm and not unavailable and depth == 0:
            name = sm.group(1); conf = sm.group(3)
            if not name.startswith('_'):
                if re.search(r'\bView\b', conf): views[name] = deprecated
                else: others[name] = deprecated
        # depth tracking
        depth += s.count('{') - s.count('}')
        while ext_stack and depth <= ext_stack[-1][0]:
            ext_stack.pop()
        if s and not s.startswith('@'):
            attrs = []
src = ''
for f in glob.glob('' + ROOT + '/Sources/**/*.swift', recursive=True):
    src += open(f).read()
have_funcs = set(re.findall(r'func (\w+)', src))
# A modifier is a stub when every definition of it inside `extension View` just returns `self`.
def balanced(text, i):
    d = 0
    for j in range(i, len(text)):
        if text[j] == '{': d += 1
        elif text[j] == '}':
            d -= 1
            if d == 0: return j
    return len(text)
defs = {}
for f in glob.glob(ROOT + '/Sources/SwiftUI2*/**/*.swift', recursive=True):
    text = open(f).read()
    spans = []
    for m in re.finditer(r'^\s*(?:@\w+\s+)*(?:public\s+)?extension\s+(?:SwiftUI2Core\.)?View\b[^{]*\{', text, re.M):
        spans.append((m.end(), balanced(text, m.end() - 1)))
    for m in re.finditer(r'func (\w+)\b[^{\n]*\{([^\n]*)', text):
        if any(a <= m.start() < b for a, b in spans):
            defs.setdefault(m.group(1), []).append(m.group(2).strip())
stubs = {n for n, bodies in defs.items() if bodies and all(b in ('self }', 'self}') for b in bodies)}
have_types = set(re.findall(r'(?:struct|class|enum|protocol|typealias) (\w+)', src))
def report(title, d, have):
    active = sorted(k for k, dep in d.items() if not dep)
    missing = [k for k in active if k not in have]
    print(f'== {title}: {len(active)-len(missing)}/{len(active)} implemented ({100*(len(active)-len(missing))//max(1,len(active))}%)')
    if '-v' in sys.argv: print('   missing:', ' '.join(missing))
    return missing
m1 = report('View modifiers (macOS, non-deprecated)', mods, have_funcs)
active = [k for k, dep in mods.items() if not dep and k in have_funcs]
stubbed = sorted(k for k in active if k in stubs)
print(f'   of which pass-through stubs: {len(stubbed)} -> real: {len(active)-len(stubbed)}/{len([k for k,d in mods.items() if not d])}')
if '-v' in sys.argv: print('   stubs:', ' '.join(stubbed))
open('' + OUT + '/stub_mods.txt','w').write('\n'.join(stubbed))
m2 = report('View types', views, have_types)
m3 = report('Other public structs', others, have_types)
open('' + OUT + '/missing_mods.txt','w').write('\n'.join(m1))
open('' + OUT + '/missing_views.txt','w').write('\n'.join(m2))
open('' + OUT + '/missing_others.txt','w').write('\n'.join(m3))
