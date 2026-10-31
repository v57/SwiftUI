#!/usr/bin/env python3
"""Writes the WinUI host's symbol fonts (Windows/SwiftUIHost/Assets): Material Symbols (Apache 2.0,
google/material-design-icons), which the host uses for Image(systemName:) like the Android backend (SF Symbols
can't be shipped), cut to the ligatures SymbolNames.swift maps to: 12.2 MB of fonts become 0.3 MB.

- MaterialSymbolsOutlined.ttf: the variable font with FILL 0, GRAD 0 and opsz 24 pinned; wght stays, since XAML's
  FontWeight drives it.
- MaterialSymbolsOutlinedFilled.ttf: filled glyphs (`.fill` symbols). XAML can't set the FILL axis, so a static
  FILL=1 instance of the same font (Google Fonts serves one as TrueType).
- symbol-fonts.sha256: SymbolNames.swift's hash (LF line endings), so build-app.ps1 sees when the table changed since.

Rerun after editing the table (Android/tools/symbol_map.py), and commit the fonts. Needs fontTools
(pip install fonttools).
    python3 Windows/scripts/symbol-fonts.py
"""
import hashlib, os, re, tempfile, urllib.request
from fontTools.ttLib import TTFont
from fontTools import subset
from fontTools.varLib import instancer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TABLE = os.path.join(ROOT, "Sources", "SwiftUIWinUI", "SymbolNames.swift")
ASSETS = os.path.join(ROOT, "Windows", "SwiftUIHost", "Assets")
REPO = "https://raw.githubusercontent.com/google/material-design-icons/master"
VARIABLE = REPO + "/variablefont/MaterialSymbolsOutlined%5BFILL%2CGRAD%2Copsz%2Cwght%5D.ttf"
FILLED_CSS = "https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,1,0"


def fetch(url, agent="symbol-fonts"):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": agent})) as response:
        return response.read()


def cut(path, dest, wanted, pin=None):
    """Keeps the ligatures in `wanted` (and the letters that spell them), then pins the axes in `pin`."""
    font = TTFont(path)
    cmap = font.getBestCmap()
    char_of = {glyph: chr(code) for code, glyph in cmap.items()}
    keep, found = set(), set()
    for lookup in font["GSUB"].table.LookupList.Lookup:
        for table in lookup.SubTable:
            table = getattr(table, "ExtSubTable", table)
            if not hasattr(table, "ligatures"):
                continue
            for first, ligatures in list(table.ligatures.items()):
                spell = lambda l: "".join(char_of.get(g, "?") for g in [first] + l.Component)
                kept = [l for l in ligatures if spell(l) in wanted]
                for l in kept:
                    keep.add(l.LigGlyph)
                    found.add(spell(l))
                if kept:
                    table.ligatures[first] = kept
                else:
                    del table.ligatures[first]
    keep.update(cmap[ord(c)] for c in "abcdefghijklmnopqrstuvwxyz0123456789_" if ord(c) in cmap)
    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.notdef_outline = True
    subsetter = subset.Subsetter(options)
    subsetter.populate(glyphs=sorted(keep))
    subsetter.subset(font)
    if pin and "fvar" in font:
        font = instancer.instantiateVariableFont(font, pin)
    font.save(dest)
    missing = sorted(wanted - found)
    print(f"{os.path.basename(dest)}: {len(found)} ligatures, {os.path.getsize(dest) / 1e6:.2f} MB"
          + (f", not in the font: {', '.join(missing)}" if missing else ""))


def main():
    table = open(TABLE, "rb").read()
    wanted = set(re.findall(r'"[^"]+":\s*[gf]\("([^"]+)"\)', table.decode()))
    os.makedirs(ASSETS, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        variable, filled = os.path.join(tmp, "variable.ttf"), os.path.join(tmp, "filled.ttf")
        open(variable, "wb").write(fetch(VARIABLE))
        css = fetch(FILLED_CSS, agent="Mozilla/4.0").decode()
        open(filled, "wb").write(fetch(re.search(r"url\((https://[^)]+\.ttf)\)", css).group(1)))
        cut(variable, os.path.join(ASSETS, "MaterialSymbolsOutlined.ttf"), wanted, {"FILL": 0, "GRAD": 0, "opsz": 24})
        cut(filled, os.path.join(ASSETS, "MaterialSymbolsOutlinedFilled.ttf"), wanted)
    open(os.path.join(ASSETS, "MaterialSymbols-LICENSE.txt"), "wb").write(fetch(REPO + "/LICENSE"))
    open(os.path.join(ASSETS, "symbol-fonts.sha256"), "w").write(hashlib.sha256(table.replace(b"\r\n", b"\n")).hexdigest() + "\n")


main()
