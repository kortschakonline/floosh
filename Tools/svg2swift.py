#!/usr/bin/env python3
"""Konvertiert SVG-Pfaddaten in SwiftUI-Path-Code (Design-Koordinaten)."""
import re, sys, json, math

NUM = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
CMD = re.compile(r'[MmLlHhVvCcSsQqTtZzAa]')

def tokenize(d):
    out, i = [], 0
    while i < len(d):
        ch = d[i]
        if CMD.match(ch):
            out.append(ch); i += 1
        elif ch in ', \t\n\r':
            i += 1
        else:
            m = NUM.match(d, i)
            if not m: raise ValueError(f"tok @{i}: {d[i:i+20]!r}")
            out.append(float(m.group())); i = m.end()
    return out

def parse(d):
    """Liefert Liste von Segmenten: ('M',x,y) ('L',x,y) ('C',x1,y1,x2,y2,x,y) ('Z',)."""
    toks = tokenize(d)
    segs = []
    i = 0
    cx = cy = sx = sy = 0.0
    pcx = pcy = None  # letzter Kontrollpunkt (für S/s)
    last = None
    while i < len(toks):
        t = toks[i]
        if isinstance(t, str):
            cmd = t; i += 1
        else:
            # implizite Wiederholung; M wird zu L
            cmd = {'M': 'L', 'm': 'l'}.get(last, last)
        def take(n):
            nonlocal i
            vals = toks[i:i+n]
            assert all(isinstance(v, float) for v in vals), f"{cmd} args @{i}"
            i += n
            return vals
        if cmd in 'Mm':
            x, y = take(2)
            if cmd == 'm': x += cx; y += cy
            cx, cy, sx, sy = x, y, x, y
            segs.append(('M', x, y)); pcx = pcy = None
        elif cmd in 'Ll':
            x, y = take(2)
            if cmd == 'l': x += cx; y += cy
            cx, cy = x, y
            segs.append(('L', x, y)); pcx = pcy = None
        elif cmd in 'Hh':
            (x,) = take(1)
            if cmd == 'h': x += cx
            cx = x
            segs.append(('L', x, cy)); pcx = pcy = None
        elif cmd in 'Vv':
            (y,) = take(1)
            if cmd == 'v': y += cy
            cy = y
            segs.append(('L', cx, y)); pcx = pcy = None
        elif cmd in 'Cc':
            x1, y1, x2, y2, x, y = take(6)
            if cmd == 'c':
                x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy
            segs.append(('C', x1, y1, x2, y2, x, y))
            pcx, pcy = x2, y2
            cx, cy = x, y
        elif cmd in 'Ss':
            x2, y2, x, y = take(4)
            if cmd == 's':
                x2 += cx; y2 += cy; x += cx; y += cy
            x1 = 2*cx - pcx if pcx is not None else cx
            y1 = 2*cy - pcy if pcy is not None else cy
            segs.append(('C', x1, y1, x2, y2, x, y))
            pcx, pcy = x2, y2
            cx, cy = x, y
        elif cmd in 'Aa':
            rx, ry, rot, large, sweep, x, y = take(7)
            if cmd == 'a': x += cx; y += cy
            segs.extend(arc_to_curves(cx, cy, rx, ry, rot, int(large), int(sweep), x, y))
            pcx = pcy = None
            cx, cy = x, y
        elif cmd in 'Zz':
            segs.append(('Z',))
            cx, cy = sx, sy
            pcx = pcy = None
        else:
            raise ValueError(f"cmd {cmd!r} nicht unterstützt")
        last = cmd
    return segs

def arc_to_curves(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2):
    """Elliptischer Bogen (SVG-Endpunktform) → kubische Bézier-Segmente.
    Umrechnung in die Mittelpunktform nach SVG 1.1, Anhang F.6."""
    if (x1, y1) == (x2, y2):
        return []
    if rx == 0 or ry == 0:
        return [('L', x2, y2)]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi_deg)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p = cp * dx + sp * dy
    y1p = -sp * dx + cp * dy
    lam = (x1p ** 2) / (rx ** 2) + (y1p ** 2) / (ry ** 2)
    if lam > 1:
        rx *= math.sqrt(lam); ry *= math.sqrt(lam)
    num = rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
    den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
    co = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        co = -co
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    ccx = cp * cxp - sp * cyp + (x1 + x2) / 2
    ccy = sp * cxp + cp * cyp + (y1 + y2) / 2
    def ang(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    n = max(1, math.ceil(abs(dt) / (math.pi / 2)))
    step = dt / n
    k = 4 / 3 * math.tan(step / 4)
    out = []
    def point(t):
        x = rx * math.cos(t); y = ry * math.sin(t)
        return (cp * x - sp * y + ccx, sp * x + cp * y + ccy)
    def deriv(t):
        x = -rx * math.sin(t); y = ry * math.cos(t)
        return (cp * x - sp * y, sp * x + cp * y)
    t = t1
    for _ in range(n):
        p0 = point(t); d0 = deriv(t)
        p3 = point(t + step); d3 = deriv(t + step)
        c1 = (p0[0] + k * d0[0], p0[1] + k * d0[1])
        c2 = (p3[0] - k * d3[0], p3[1] - k * d3[1])
        out.append(('C', c1[0], c1[1], c2[0], c2[1], p3[0], p3[1]))
        t += step
    # Endpunkt exakt setzen (Rundungsfehler)
    last = out[-1]
    out[-1] = ('C', last[1], last[2], last[3], last[4], x2, y2)
    return out

def bbox(seglists):
    xs, ys = [], []
    for segs in seglists:
        cx = cy = 0.0
        for s in segs:
            if s[0] == 'M' or s[0] == 'L':
                xs.append(s[1]); ys.append(s[2]); cx, cy = s[1], s[2]
            elif s[0] == 'C':
                x0, y0 = cx, cy
                x1, y1, x2, y2, x3, y3 = s[1:]
                for k in range(11):
                    t = k / 10
                    mt = 1 - t
                    xs.append(mt**3*x0 + 3*mt*mt*t*x1 + 3*mt*t*t*x2 + t**3*x3)
                    ys.append(mt**3*y0 + 3*mt*mt*t*y1 + 3*mt*t*t*y2 + t**3*y3)
                cx, cy = x3, y3
    return min(xs), min(ys), max(xs), max(ys)

def emit(segs, indent="        "):
    L = []
    f = lambda v: f"{v:.3f}".rstrip('0').rstrip('.')
    for s in segs:
        if s[0] == 'M':
            L.append(f"{indent}p.move(to: t(CGPoint(x: {f(s[1])}, y: {f(s[2])})))")
        elif s[0] == 'L':
            L.append(f"{indent}p.addLine(to: t(CGPoint(x: {f(s[1])}, y: {f(s[2])})))")
        elif s[0] == 'C':
            L.append(f"{indent}p.addCurve(to: t(CGPoint(x: {f(s[5])}, y: {f(s[6])})), control1: t(CGPoint(x: {f(s[1])}, y: {f(s[2])})), control2: t(CGPoint(x: {f(s[3])}, y: {f(s[4])})))")
        elif s[0] == 'Z':
            L.append(f"{indent}p.closeSubpath()")
    return "\n".join(L)

if __name__ == '__main__':
    spec = json.load(open(sys.argv[1]))
    # spec: { assets: [ {name, parts: [{name, paths: [dstr...], rects: [[x,y,w,h]...]}] } ] }
    for asset in spec['assets']:
        all_segs = []
        parts_parsed = []
        for part in asset['parts']:
            segs_list = [parse(d) for d in part.get('paths', [])]
            for (x, y, w, h) in part.get('rects', []):
                segs_list.append([('M', x, y), ('L', x+w, y), ('L', x+w, y+h), ('L', x, y+h), ('Z',)])
            parts_parsed.append((part['name'], segs_list))
            all_segs += segs_list
        x0, y0, x1, y1 = bbox(all_segs)
        print(f"    // MARK: {asset['name']} — Designbox x:{x0:.2f} y:{y0:.2f} w:{x1-x0:.2f} h:{y1-y0:.2f}")
        print(f"    static let {asset['name']}Design = CGRect(x: {x0:.3f}, y: {y0:.3f}, width: {x1-x0:.3f}, height: {y1-y0:.3f})")
        print()
        for pname, segs_list in parts_parsed:
            print(f"    static func {asset['name']}{pname}(t: (CGPoint) -> CGPoint) -> Path {{")
            print(f"        var p = Path()")
            for segs in segs_list:
                print(emit(segs))
            print(f"        return p")
            print(f"    }}")
            print()

# Aufruf zum Regenerieren von BrandLogos.swift (LogoPaths-Rumpf):
#   python3 Tools/regenerate-logo-paths.py
# (extrahiert die Pfade aus den SVGs, konvertiert sie und ersetzt den
#  generierten Abschnitt zwischen `enum LogoPaths {` und `// MARK: - Shapes`)
