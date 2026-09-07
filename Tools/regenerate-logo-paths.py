#!/usr/bin/env python3
"""Regeneriert den LogoPaths-Rumpf in BrandLogos.swift aus den SVG-Quellen."""
import io, json, re, subprocess, sys
from contextlib import redirect_stdout
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "Tools"))
import svg2swift

floosh = (root / "Logo & Icon Source/floosh-logo-varianten.svg").read_text()
jrn = (root / "jrn Logo Source/JRN.digital-mini-01.svg").read_text()

paths = re.findall(r'<path class="(cls-\d)" d="([^"]+)"', floosh)
frame = next(d for c, d in paths if c == 'cls-5' and d.startswith('M63.88'))
accent = next(d for c, d in paths if c == 'cls-8' and d.startswith('M63.13'))
jpaths = re.findall(r'<path class="(cls-\d)" d="([^"]+)"', jrn)
jprimary = [d for c, d in jpaths if c == 'cls-1']
jrects = [[float(v) for v in m] for m in re.findall(
    r'<rect class="cls-2" x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"', jrn)]

# Wortmarke (mittlere, dunkle Variante im Varianten-SVG): Blitz + Buchstaben
# sind die klassenlosen Pfade, die Stoppuhr-Ringe des „oo" sind cls-3
# (Konturpfade + zwei Verbindungslinien).
plain = re.findall(r'<path d="([^"]+)"', floosh)
mark_bolt_frame = next(d for d in plain if d.startswith('M223.06'))
mark_letters = [d for d in plain if not d.startswith('M223.06')]
mark_bolt_accent = next(d for c, d in paths if c == 'cls-8' and d.startswith('M209,'))
rings = [d for c, d in paths if c == 'cls-3']
rings += [f"M{x1},{y1}L{x2},{y2}" for x1, y1, x2, y2 in re.findall(
    r'<line class="cls-3" x1="([\d.]+)" y1="([\d.]+)" x2="([\d.]+)" y2="([\d.]+)"', floosh)]

# Solide Wortmarke (obere Zeile im Varianten-SVG): großer Blitz + gefüllte
# FLOOSH-Lettern (cls-5; Blitz M63.88 und Kachel-Blitz M101.18 ausgenommen).
solid_letters = [d for c, d in paths if c == 'cls-5'
                 and not d.startswith('M63.88') and not d.startswith('M101.18')]

spec = {"assets": [
    {"name": "bolt", "parts": [{"name": "Frame", "paths": [frame]},
                               {"name": "Accent", "paths": [accent]}]},
    {"name": "logo", "parts": [{"name": "Frame", "paths": [frame]},
                               {"name": "Accent", "paths": [accent]},
                               {"name": "Letters", "paths": solid_letters}]},
    {"name": "mark", "parts": [{"name": "Frame", "paths": [mark_bolt_frame]},
                               {"name": "Accent", "paths": [mark_bolt_accent]},
                               {"name": "Letters", "paths": mark_letters},
                               {"name": "Rings", "paths": rings}]},
    {"name": "jrn", "parts": [{"name": "Primary", "paths": jprimary},
                              {"name": "Accent", "rects": jrects}]},
]}
specfile = root / "build" / "logo-spec.json"
specfile.parent.mkdir(exist_ok=True)
specfile.write_text(json.dumps(spec))

body = subprocess.run([sys.executable, str(root / "Tools/svg2swift.py"), str(specfile)],
                      capture_output=True, text=True, check=True).stdout

target = root / "Sources/Floosh/BrandLogos.swift"
src = target.read_text()
head, rest = src.split("enum LogoPaths {\n", 1)
_, tail = rest.split("}\n\n// MARK: - Shapes", 1)
target.write_text(head + "enum LogoPaths {\n" + body + "}\n\n// MARK: - Shapes" + tail)
print(f"✓ {target} aktualisiert")
