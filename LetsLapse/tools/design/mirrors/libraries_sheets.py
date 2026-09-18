"""The libraries programme's sheet mirrors (libraries plan §17.11): the phone's connect sheet, the Mac's Libraries card and connect sheet.
Run from LetsLapse/: python3 tools/design/mirrors/libraries_sheets.py tools/design"""
import sys; sys.path.insert(0, sys.argv[1])
from svgkit import IOS, MAC, tabbar, ACCENT, SEC, RED, wrap
import pathlib
ios, mac = pathlib.Path("docs/design/iOS"), pathlib.Path("docs/design/macOS")

def truncate(s, n): return s if len(s) <= n else s[:n - 1].rstrip() + "…"

# --- the phone's connect sheet ---
k = IOS("iOS · PicPlace · Connect “Holidays” to PicPlace (sheet) — a folder that was a server library before · portrait",
 "Mirrors PicPlaceConnectSheet (App/PicPlace/PicPlaceViews.swift) over PicPlaceController.ConnectOffer (offerConnectNow, numbers(for:), summary(for:)) — libraries plan §3.7 with step 0's L23/L24 (2026-09-17; mirrored from the running Simulator). Raised by the PicPlace card's Connect / Which library… row. Title 'Connect “Holidays” to PicPlace' (19pt semibold), 'as @regularsteven on picplace.test', and — for a folder whose identity carries a server library's uuid, a link or a create before — 'This library was “Holidays” on PicPlace.' A 'Name on PicPlace' field (disabled while linking: the link takes the server library's name). Then the radio list in a 4 %-tinted 12pt card, one row per target with THE NUMBERS from the two sides' origin ids: New library on PicPlace — what goes up (originals here and on PicPlace nowhere), what is filed elsewhere and stays, and the previews this target cannot account for and would remove ('877 previews of “Holidays” are removed from this iPhone; they stay on PicPlace.'); Take over the N unfiled projects (only while the default library holds any); Link to “X” · N projects — 'N arrive here as previews; originals download per project', 'M already here stay in step', 'K here go up', 'Nothing arrives.' / 'Nothing goes up.' as each applies; a long title wraps. The link to the former library is preselected. Not now · Connect. A connect elsewhere evicts the previews it cannot account for — folder and index row, never a tombstone — and the first pass says so ('N preview(s) removed'). The Mac's sheet is the same view at 460pt (macOS/picplace.connect.svg); LL_PICPLACE_OFFER=1|new|adopt|link:<uuid> opens the real sheet with a target selected.")
k.body.append('<rect x="0" y="0" width="393" height="852" fill="#000" fill-opacity="0.35"/>')
k.body.append('<rect x="0" y="96" width="393" height="756" rx="40" fill="#F2F2F7"/>')
k.body.append('<rect x="178" y="104" width="36" height="5" rx="2.5" fill="#000" fill-opacity="0.18"/>')
k.text(24, 156, "Connect “Holidays” to PicPlace", 19, "#000", 600)
k.text(24, 178, "as @regularsteven on picplace.test", 13, SEC)
k.text(24, 197, "This library was “Holidays” on PicPlace.", 13, SEC)
k.text(24, 234, "Name on PicPlace", 13, SEC)
k.body.append('<rect x="150" y="216" width="219" height="30" rx="6" fill="#FFF" stroke="#000" stroke-opacity="0.12"/>')
k.text(158, 236, "Holidays", 14, SEC)
options = [
    ("New library on PicPlace", "877 previews of “Holidays” are removed from this iPhone; they stay on PicPlace. Nothing arrives. Nothing goes up.", False),
    ("Link to “Holidays” · 877 projects", "877 already here stay in step. Nothing arrives. Nothing goes up.", True),
    ("Link to “Prague LetsLapse Shots” · 401 projects", "All 401 arrive here as previews; originals download per project. 877 previews of “Holidays” are removed from this iPhone; they stay on PicPlace. Nothing goes up.", False),
]
total = sum(20 * len(wrap(t, 36)) + 38 + 14 * len(wrap(d, 54)) for t, d, _ in options)
k.body.append(f'<rect x="24" y="264" width="345" height="{total}" rx="12" fill="#000" fill-opacity="0.04"/>')
y = 264
for i, (title, detail, chosen) in enumerate(options):
    tl, dl = wrap(title, 36), wrap(detail, 54)
    k.body.append(f'<circle cx="46" cy="{y+27}" r="8" fill="none" stroke="{ACCENT if chosen else "#8E8E93"}" stroke-width="1.6"/>')
    if chosen: k.body.append(f'<circle cx="46" cy="{y+27}" r="4.5" fill="{ACCENT}"/>')
    for j, line in enumerate(tl): k.text(68, y + 31 + j * 20, line, 14.5, "#000", 600 if chosen else None)
    dy = y + 31 + 20 * (len(tl) - 1) + 19
    for j, line in enumerate(dl): k.text(68, dy + j * 14, line, 11.5, SEC)
    h = 20 * len(tl) + 38 + 14 * len(dl)
    if i < len(options) - 1: k.hair(y + h, 68, 369)
    y += h
k.pill(24, 760, "Not now", w=164, fill="#FFF", text=ACCENT, size=17, h=56)
k.pill(205, 760, "Connect", w=164, fill=ACCENT, text="#FFF", size=17, h=56)
(ios / "picplace.connect.portrait.svg").write_text(k.render())

# --- the Mac's Libraries card (also the backdrop of the disconnect confirm) ---
def libraries_card(k, y=76):
    k.header(y, "LIBRARIES")
    k.card(y + 10, 386, "libraries-card")
    r = y + 10
    k.text(52, r + 24, "Prague LetsLapse Shots", 16); k.text(52, r + 40, truncate("/Volumes/letslapse/picplace.test/regularsteven · 401 projects · @regularsteven on picplace.test", 96), 11.5, SEC)
    k.text(586, r + 24, "✎", 13, SEC, anchor="middle"); k.text(686, r + 24, "Disconnect…", 13, RED, anchor="end"); k.text(748, r + 24, "Current", 13, SEC, anchor="end")
    k.hair(r + 50); r += 50
    k.text(52, r + 24, "Holidays", 16); k.text(52, r + 40, truncate("~/Library/Application Support/LetsLapse/picplace.test/regularsteven · 877 projects · @regularsteven on picplace.test", 88), 11.5, SEC)
    k.text(676, r + 24, "✎", 13, SEC, anchor="middle"); k.button(692, r + 12, "Switch…", w=56)
    k.hair(r + 50); r += 50
    k.text(52, r + 24, "LetsLapse", 16, SEC); k.text(52, r + 40, "~/Library/Application Support/LetsLapse · 0 projects", 11.5, SEC)
    k.text(676, r + 24, "✎", 13, ACCENT, anchor="middle"); k.button(692, r + 12, "Switch…", w=56)
    k.hair(r + 50); r += 50
    r = k.row(r, "Create New Library…", "An empty library in a folder of your choosing. Nothing is copied.", color=ACCENT)
    r = k.row(r, "Open Other Library…", "A LetsLapse library on any drive — switches to it on relaunch.", color=ACCENT)
    r = k.row(r, "Add Library from PicPlace…", "1 of your libraries is on picplace.test and not on this Mac: “Client X”.", color=ACCENT)
    r = k.row(r, "Move This Library…", "Copies “Prague LetsLapse Shots” — about 12,4 GB — to another folder. Nothing is deleted.", color=ACCENT, divider=False)
    return r

desc_card = "Mirrors App/SettingsView.swift (librariesCard, libraryRowView, refreshLibraryRows, the doors) over App/StorageLocation.swift (StorageRoot, LibraryRegistry) — libraries plan §2.3, §3.1–3.4, L13–L20 (stages A/A′, 2026-09-16; mirrored 2026-09-18 from the running Mac bench). Settings scrolled to the LIBRARIES section. One row per known library (LibraryRegistry: storage.libraries, seeded by discover() from the default location and its <host>/<username>/ folders): title = the identity file's name (grey placeholder with an accent pencil while unnamed — L16), subtitle = the ~-abbreviated path · N projects · @user on host when bound (or 'path — not mounted'), truncated at the width the buttons leave; a pencil to rename on every reachable row (an alert with a text field; the open library's rename also renames it on PicPlace); on the open row 'Current' and — visible, not only in the menu (L14) — a red Disconnect… while it is bound; on the others a bordered Switch… (disabled when unreachable or while a render runs). The row's context menu: Rename…, Show in Finder, Disconnect from PicPlace… (open row, bound), Remove from List (the folder is never touched). THE DOORS: Create New Library… (an NSSavePanel — a name and a place in one go; settings-libraries.create.svg), Open Other Library… (an NSOpenPanel; StorageRoot.check decides — a library switches, an empty folder is refused as such, a folder inside the current one or holding a same-named non-library item is refused), Add Library from PicPlace… (only while the account has libraries no known library here is a copy of; settings-libraries.add-from-picplace.svg), Move This Library… (the copy-never-delete mover; its subtitle says the library's walked size; settings-libraries.move.svg). Every switch or create ends on the Relaunch button — a location applies on relaunch (StorageRoot.current is resolved once per process). LL_SCROLL=libraries lands here; LL_STORAGE=list stages the rows with no disk touched; LL_CREATE_LIBRARY / LL_OPEN_LIBRARY run the real create / open on a scratch path."
k = MAC("macOS · Settings · Libraries card — three libraries, the four doors · 760×680", desc_card)
libraries_card(k)
(mac / "settings-libraries.svg").write_text(k.render())

k = MAC("macOS · Settings · Libraries · Disconnect this library from PicPlace? (confirm with the numbers) · 760×680",
 "Mirrors the Libraries row's Disconnect… confirmationDialog (App/SettingsView.swift, confirmingDisconnect) over PicPlaceController.disconnectMessage — libraries plan L14 and step 0's L23 (2026-09-17; verified against the Mac bench, plan §17.7 T1). Over the card: 'Disconnect this library from PicPlace?' and the numbers — 'The library stops syncing and forgets its account and what it has synced. 2 previews pulled from PicPlace stay on this Mac but cannot download until you connect it again. 1 project with originals here stays as it is. Nothing changes on PicPlace. Switching libraries never needs this.' — Cancel · Disconnect (red). The binding and the sync records go, nothing else: the previews stay, and a later link to the same library finds them in step.")
libraries_card(k)
k.body.append('<rect x="20" y="60" width="760" height="640" fill="#000" fill-opacity="0.18"/>')
k.body.append('<rect x="290" y="240" width="220" height="250" rx="14" fill="#F2F2F7" filter="url(#sheetshadow)"/>')
k.body.append(f'<rect x="384" y="256" width="32" height="32" rx="7" fill="{ACCENT}"/>')
k.text(400, 314, "Disconnect this library", 13, "#000", 700, anchor="middle"); k.text(400, 330, "from PicPlace?", 13, "#000", 700, anchor="middle")
for i, line in enumerate(wrap("The library stops syncing and forgets its account and what it has synced. 2 previews pulled from PicPlace stay on this Mac but cannot download until you connect it again. 1 project with originals here stays as it is. Nothing changes on PicPlace. Switching libraries never needs this.", 40)):
    k.text(400, 350 + i * 12.5, line, 10, "#000", anchor="middle")
k.button(302, 456, "Cancel", w=94); k.button(404, 456, "Disconnect", w=94, red=True)
(mac / "settings-libraries.disconnect.svg").write_text(k.render())

# --- the Mac's connect sheet ---
k = MAC("macOS · Settings · PicPlace · Connect “Holidays” to PicPlace (sheet, 460pt) · 760×680",
 "Mirrors PicPlaceConnectSheet (App/PicPlace/PicPlaceViews.swift, 460pt on the Mac) over PicPlaceController.ConnectOffer — libraries plan §3.7 / stage C1 with step 0's L23/L24 (2026-09-17; captured on the Mac bench with LL_PICPLACE_OFFER=1 — the real sheet, the numbers off the server). Title 'Connect “Holidays” to PicPlace' / 'as @regularsteven on picplace.test' / 'This library was “Holidays” on PicPlace.' (a folder whose identity carries a server library's uuid); the Name on PicPlace field (disabled while linking); the radio list in a 4 %-tinted 12pt card — New library on PicPlace, Take over the N unfiled projects (only while the default library holds any), Link to “X” · N projects — each with the numbers: what arrives as previews, what is already here and stays in step, what goes up (originals here and on PicPlace nowhere), what is filed elsewhere and stays, and the previews the target cannot account for and would remove ('877 previews of “Holidays” are removed from this Mac; they stay on PicPlace.'). The former library's link is preselected. A refusal line in LL.levelOff above Not now (secondary) · Connect (primary). The phone's sheet is the same view (../iOS/picplace.connect.portrait.svg).")
k.body.append('<rect x="20" y="60" width="760" height="640" fill="#000" fill-opacity="0.18"/>')
x, y, w = 170, 118, 460
k.body.append(f'<rect x="{x}" y="{y}" width="{w}" height="500" rx="14" fill="#F2F2F7" filter="url(#sheetshadow)"/>')
k.text(x + 24, y + 40, "Connect “Holidays” to PicPlace", 19, "#000", 600)
k.text(x + 24, y + 60, "as @regularsteven on picplace.test", 13, SEC)
k.text(x + 24, y + 78, "This library was “Holidays” on PicPlace.", 13, SEC)
k.text(x + 24, y + 110, "Name on PicPlace", 13, SEC)
k.body.append(f'<rect x="{x+150}" y="{y+94}" width="{w-174}" height="24" rx="5" fill="#FFF" stroke="#000" stroke-opacity="0.12"/>'); k.text(x + 158, y + 110, "Holidays", 13, SEC)
k.body.append(f'<rect x="{x+24}" y="{y+134}" width="{w-48}" height="262" rx="12" fill="#000" fill-opacity="0.04"/>')
oy = y + 134
options = [("New library on PicPlace", "1 here is filed in other libraries on PicPlace and stays as it is. 877 previews of “Holidays” are removed from this Mac; they stay on PicPlace. Nothing arrives. Nothing goes up.", False),
           ("Link to “Holidays” · 877 projects", "877 already here stay in step. Nothing arrives. Nothing goes up.", True),
           ("Link to “Prague LetsLapse Shots” · 401 projects", "All 401 arrive here as previews; originals download per project. 1 here is filed in other libraries on PicPlace and stays as it is. 877 previews of “Holidays” are removed from this Mac; they stay on PicPlace. Nothing goes up.", False)]
for i, (title, detail, chosen) in enumerate(options):
    lines = wrap(detail, 66)
    k.body.append(f'<circle cx="{x+44}" cy="{oy+22}" r="7.5" fill="none" stroke="{ACCENT if chosen else "#8E8E93"}" stroke-width="1.5"/>')
    if chosen: k.body.append(f'<circle cx="{x+44}" cy="{oy+22}" r="4" fill="{ACCENT}"/>')
    k.text(x + 62, oy + 26, title, 14.5, "#000", 600 if chosen else None)
    for j, line in enumerate(lines): k.text(x + 62, oy + 43 + j * 13, line, 11.5, SEC)
    h = 50 + 13 * len(lines)
    if i < 2: k.hair(oy + h, x + 62, x + w - 34)
    oy += h
k.body.append(f'<rect x="{x+24}" y="{y+420}" width="200" height="44" rx="10" fill="#FFF"/>'); k.text(x + 124, y + 448, "Not now", 15, ACCENT, 700, anchor="middle")
k.body.append(f'<rect x="{x+236}" y="{y+420}" width="200" height="44" rx="10" fill="{ACCENT}"/>'); k.text(x + 336, y + 448, "Connect", 15, "#FFF", 700, anchor="middle")
(mac / "picplace.connect.svg").write_text(k.render())
print("sheets regenerated")
