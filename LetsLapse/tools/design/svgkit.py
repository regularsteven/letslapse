"""Tiny SVG kit in the repo's mirror conventions (docs/design/README.md):
iOS: 441x940 viewBox, 393x852 screen at (24,24), rounded frame, status bar; cards x=16 w=361 rx=16, LLRow title 16px, subtitle 11.5px.
macOS: 800x750 viewBox, 760x680 window at (20,20), titlebar; cards x=36 w=728 rx=12, rows title 16px, subtitle 11.5px."""
from xml.sax.saxutils import escape as esc
ACCENT = "#C36A00"; SEC = "#6D6D72"; HAIR = 'stroke="#000" stroke-opacity="0.08"'; RED = "#FF3B30"
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"

def wrap(text, width_chars):
    words, lines, cur = text.split(), [], ""
    for w in words:
        if len(cur) + len(w) + 1 > width_chars and cur: lines.append(cur); cur = w
        else: cur = (cur + " " + w).strip()
    if cur: lines.append(cur)
    return lines

class IOS:
    def __init__(self, title, desc, scroll=0):
        self.title, self.desc, self.scroll = title, desc, scroll; self.body = []
    def text(self, x, y, s, size=16, fill="#000", weight=None, anchor=None, cls=None):
        a = [f'x="{x}" y="{y}" font-size="{size}" fill="{fill}"']
        if weight: a.append(f'font-weight="{weight}"')
        if anchor: a.append(f'text-anchor="{anchor}"')
        if cls: a.append(f'class="{cls}"')
        self.body.append(f'<text {" ".join(a)}>{esc(s)}</text>')
    def header(self, y, s): self.text(20, y, s, 13, SEC, 600, cls="hdr")
    def card(self, y, h, gid): self.body.append(f'<rect id="{gid}" x="16" y="{y}" width="361" height="{h}" rx="16" fill="#FFF" filter="url(#soft)"/>')
    def hair(self, y, x1=32, x2=361): self.body.append(f'<line x1="{x1}" y1="{y}" x2="{x2}" y2="{y}" {HAIR}/>')
    def row(self, y, title, subtitle=None, color="#000", trailing=None, trailing_color=SEC, divider=True, sub_width=52):
        """One LLRow starting at y (its top). Returns the next y."""
        self.text(32, y + 27, title, 16, color)
        cy = y + 27
        if trailing: self.text(361, cy, trailing, 15, trailing_color, anchor="end")
        h = 44
        if subtitle:
            for i, line in enumerate(wrap(subtitle, sub_width)):
                self.text(32, y + 44 + i * 15, line, 11.5, SEC)
            h = 44 + 15 * len(wrap(subtitle, sub_width)) + 4
        if divider: self.hair(y + h)
        return y + h
    def pill(self, x, y, label, w=None, fill=ACCENT, text="#FFF", size=15, h=32):
        w = w or int(len(label) * 8.6 + 28)
        self.body.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{h/2}" fill="{fill}"/>')
        self.text(x + w / 2, y + h / 2 + 5.5, label, size, text, 600, anchor="middle")
        return w
    def render(self):
        return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 441 940" font-family="{FONT}">
  <title>{esc(self.title)}</title>
  <desc>{esc(self.desc)}</desc>
  <defs>
    <clipPath id="screen"><rect x="24" y="24" width="393" height="852" rx="54"/></clipPath>
    <clipPath id="scroll"><rect x="0" y="58" width="393" height="794"/></clipPath>
    <filter id="soft" x="-40%" y="-40%" width="180%" height="180%"><feDropShadow dx="0" dy="8" stdDeviation="7" flood-color="#000" flood-opacity="0.14"/></filter>
  </defs>
  <style>text{{font-family:inherit}}.sb{{font-weight:600}}.b{{font-weight:700}}.sec{{fill:#6D6D72}}.hdr{{font-size:13px;font-weight:600;fill:#6D6D72;letter-spacing:0.5px}}.ttl{{font-size:16px;fill:#000}}.sub{{font-size:11.5px;fill:#6D6D72}}</style>
  <rect x="18" y="18" width="405" height="864" rx="60" fill="none" stroke="#3A3A3F" stroke-width="3"/>
  <g clip-path="url(#screen)">
    <rect x="24" y="24" width="393" height="852" fill="#F2F2F7"/>
    <g transform="translate(24,24)">
      <g id="status-bar" fill="#000">
        <text x="80" y="43" font-size="15" class="sb" text-anchor="middle">9:41</text>
        <g><rect x="306" y="35" width="3" height="4" rx="1"/><rect x="311" y="33" width="3" height="6" rx="1"/><rect x="316" y="31" width="3" height="8" rx="1"/><rect x="321" y="29" width="3" height="10" rx="1"/></g>
        <path d="M334 34 a8 8 0 0 1 12 0 M337 37 a4.5 4.5 0 0 1 6 0 M339.5 39.5 l0.5 0.5 0.5 -0.5" stroke="#000" stroke-width="1.8" fill="none" stroke-linecap="round"/>
        <g><rect x="352" y="30" width="23" height="11" rx="3.5" fill="none" stroke="#000" stroke-opacity="0.4"/><rect x="376" y="33.5" width="2" height="4" rx="1" fill="#000" fill-opacity="0.4"/><rect x="354" y="32" width="15" height="7" rx="2"/></g>
      </g>
      <g clip-path="url(#scroll)"><g transform="translate(0,{-self.scroll})">
{chr(10).join("        " + b for b in self.body)}
      </g></g>
    </g>
  </g>
</svg>
'''

def tabbar(k, active):
    """The floating six-seat pill (Create · Gallery · Projects · Collections · Settings) at the foot of every iOS tab mirror."""
    k.body.append('<g id="tab-bar" transform="translate(0,0)">')
    k.body.append(f'<rect x="20" y="{k.scroll + 776}" width="353" height="62" rx="31" fill="#FFF" fill-opacity="0.92" filter="url(#soft)"/>')
    names = ["Create", "Gallery", "Projects", "Collections", "Settings"]
    for i, n in enumerate(names):
        cx = 55 + i * 70.5
        if n == active:
            k.body.append(f'<rect x="{cx-31}" y="{k.scroll + 781}" width="62" height="52" rx="26" fill="{ACCENT}" fill-opacity="0.12"/>')
        k.text(cx, k.scroll + 826, n, 10.5, ACCENT if n == active else SEC, 600 if n == active else None, anchor="middle")
    k.body.append('</g>')

class MAC:
    def __init__(self, title, desc):
        self.title, self.desc = title, desc; self.body = []
    def text(self, x, y, s, size=16, fill="#000", weight=None, anchor=None):
        a = [f'x="{x}" y="{y}" font-size="{size}" fill="{fill}"']
        if weight: a.append(f'font-weight="{weight}"')
        if anchor: a.append(f'text-anchor="{anchor}"')
        self.body.append(f'<text {" ".join(a)}>{esc(s)}</text>')
    def header(self, y, s): self.text(36, y, s, 12, SEC, 600)
    def card(self, y, h, gid): self.body.append(f'<rect id="{gid}" x="36" y="{y}" width="728" height="{h}" rx="12" fill="#FFF"/>')
    def hair(self, y, x1=52, x2=748): self.body.append(f'<line x1="{x1}" y1="{y}" x2="{x2}" y2="{y}" {HAIR}/>')
    def row(self, y, title, subtitle=None, color="#000", divider=True, sub_width=118):
        self.text(52, y + 24, title, 16, color)
        h = 40
        if subtitle:
            lines = wrap(subtitle, sub_width)
            for i, line in enumerate(lines): self.text(52, y + 40 + i * 14, line, 11.5, SEC)
            h = 40 + 14 * len(lines) + 4
        if divider: self.hair(y + h)
        return y + h
    def button(self, x, y, label, w=None, primary=False, red=False, h=24):
        w = w or int(len(label) * 7.2 + 24)
        fill = ACCENT if primary else "#000"; op = "1" if primary else "0.06"
        self.body.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" fill-opacity="{op}"/>')
        self.text(x + w / 2, y + h / 2 + 4.5, label, 13, "#FFF" if primary else (RED if red else "#000"), 600 if primary else None, anchor="middle")
        return w
    def render(self):
        return f'''<svg viewBox="0 0 800 750" xmlns="http://www.w3.org/2000/svg" font-family="{FONT}">
  <title>{esc(self.title)}</title>
  <desc>{esc(self.desc)}</desc>
  <defs>
    <clipPath id="win"><rect x="20" y="20" width="760" height="680" rx="11"/></clipPath>
    <filter id="sheetshadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000000" flood-opacity="0.20"/></filter>
  </defs>
  <style>text{{font-family:inherit}}.sb{{font-weight:600}}.b{{font-weight:700}}.mono{{font-variant-numeric:tabular-nums}}</style>
  <g clip-path="url(#win)">
    <rect x="20" y="20" width="760" height="680" fill="#F2F2F7"/>
    <g id="titlebar">
      <rect x="20" y="20" width="760" height="40" fill="#F6F6F8"/>
      <line x1="20" y1="60" x2="780" y2="60" stroke="#000" stroke-opacity="0.08"/>
      <circle cx="40" cy="40" r="6" fill="#FF736A"/><circle cx="60" cy="40" r="6" fill="#FEBC2E"/><circle cx="80" cy="40" r="6" fill="#19C332"/>
      <text x="400" y="45" font-size="13" class="sb" text-anchor="middle" fill="#000" fill-opacity="0.85">Settings</text>
    </g>
{chr(10).join("    " + b for b in self.body)}
  </g>
</svg>
'''
