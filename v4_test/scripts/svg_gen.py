#!/usr/bin/env python3
"""Real Perfetto meminfo series (run1 tmpfs vs run2 ext4 control) -> 3-panel SVG."""
import json
D = {r['name']: r for r in json.load(open('analysis.json'))}
W, H = 1000, 768
PADL, PADR, PADT = 70, 24, 88
PH, GAP = 152, 62
METRICS = [('MemAvailable', 'MemAvailable (MiB): headroom the kernel reports to userspace',
            [('run1 tmpfs /data', '#1a73e8', '-24.0 MiB'), ('run2 ext4 /userdata (control)', '#1a73e8', '-0.5 MiB')]),
           ('Shmem', 'Shmem (MiB): RAM-backed tmpfs pages',
            [('run1 tmpfs /data', '#d93025', '+24.0 MiB'), ('run2 ext4 /userdata (control)', '#d93025', 'flat')]),
           ('Cached', 'Cached (MiB): page cache (also counts tmpfs pages)',
            [('run1 tmpfs /data', '#188038', '+24.0 MiB'), ('run2 ext4 /userdata (control)', '#188038', '+24.0 MiB')])]
def series(name):
    r = D[name]; a = r['anchor_s']
    return [s for s in r['series'] if a - 12 <= s['t'] <= a + 50], a
def fmt(v): return f'{v:.0f}' if abs(v) >= 100 else f'{v:.1f}'
out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif">',
       f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
       f'<text x="{PADL}" y="26" font-size="16" font-weight="700">RDK X5 — 24 MiB test file: tmpfs (/data) vs ext4 (/userdata)</text>',
       f'<text x="{PADL}" y="45" font-size="11" fill="#555">Perfetto linux.sys_stats meminfo @250 ms; x = seconds relative to workload_start; shaded band = tmpfs file alive (dd .. rm)</text>',
       f'<line x1="{W-300}" y1="20" x2="{W-278}" y2="20" stroke="#555" stroke-width="2.4"/><text x="{W-272}" y="24" font-size="11">run1: /data = tmpfs</text>',
       f'<line x1="{W-300}" y1="38" x2="{W-278}" y2="38" stroke="#555" stroke-width="2.4" stroke-dasharray="5 3"/><text x="{W-272}" y="42" font-size="11">run2: /userdata = ext4 (control)</text>']
for i, (key, title, annot) in enumerate(METRICS):
    s1, a1 = series('run1'); s2, a2 = series('run2')
    top = PADT + i * (PH + GAP)
    vals = [s[key] for s in s1] + [s[key] for s in s2]
    lo, hi = max(0.0, min(vals)), max(vals)
    if lo < 2: lo = 0.0
    if hi - lo < 6: hi = lo + 6
    lo -= 2; hi += 4
    xmap = lambda t, a=a1: PADL + (t - a + 12) / 62 * (W - PADL - PADR)
    ymap = lambda v, top=top: top + PH - (v - lo) / (hi - lo) * PH
    out.append(f'<text x="{PADL}" y="{top-10}" font-size="12.5" font-weight="600">{title}</text>')
    for k in range(5):
        gv = lo + (hi - lo) * k / 4
        out.append(f'<line x1="{PADL}" y1="{ymap(gv):.1f}" x2="{W-PADR}" y2="{ymap(gv):.1f}" stroke="#edf0f2"/>'
                   f'<text x="{PADL-7}" y="{ymap(gv)+4:.1f}" font-size="10" fill="#666" text-anchor="end">{fmt(gv)}</text>')
    for tv in range(-10, 51, 10):
        out.append(f'<line x1="{xmap(tv):.1f}" y1="{top}" x2="{xmap(tv):.1f}" y2="{top+PH}" stroke="#f6f7f8"/>'
                   f'<text x="{xmap(tv):.1f}" y="{top+PH+14}" font-size="10" fill="#666" text-anchor="middle">{tv:+d}</text>')
    out.append(f'<rect x="{xmap(10):.1f}" y="{top}" width="{xmap(35)-xmap(10):.1f}" height="{PH}" fill="#fef7e0"/>')
    for tv in (10, 35):
        out.append(f'<line x1="{xmap(tv):.1f}" y1="{top}" x2="{xmap(tv):.1f}" y2="{top+PH}" stroke="#9aa0a6" stroke-dasharray="4 3"/>')
    out.append(f'<text x="{xmap(10)+5:.1f}" y="{top+14}" font-size="10" font-weight="600" fill="#b06000">dd</text>')
    out.append(f'<text x="{xmap(35)+5:.1f}" y="{top+14}" font-size="10" font-weight="600" fill="#b06000">rm</text>')
    def pl(ser, a, col, dash=''):
        d = f' stroke-dasharray="{dash}"' if dash else ''
        return f'<polyline fill="none" stroke="{col}" stroke-width="1.9"{d} points="' + \
               ''.join(f"{xmap(s['t'], a):.1f},{ymap(s[key]):.1f} " for s in ser) + '"/>'
    out.append(pl(s1, a1, annot[0][1])); out.append(pl(s2, a2, annot[1][1], '5 3'))
    ax = xmap(37.5)
    out.append(f'<text x="{ax:.1f}" y="{top+PH*0.40:.1f}" font-size="10.8" font-weight="600" fill="{annot[0][1]}">{annot[0][0]}: {annot[0][2]}</text>')
    out.append(f'<text x="{ax:.1f}" y="{top+PH*0.40+15:.1f}" font-size="10.8" fill="#555">{annot[1][0]}: {annot[1][2]}</text>')
out.append(f'<text x="{PADL}" y="{H-12}" font-size="10" fill="#666">Source: run1.pftrace / run2.pftrace (Perfetto v57.1-c59f57dd4), values converted bytes->MiB. Cached and Shmem overlap for tmpfs pages: do not add them.</text>')
out.append('</svg>')
open('mem_timeline.svg', 'w').write('\n'.join(out))
print('ok')
