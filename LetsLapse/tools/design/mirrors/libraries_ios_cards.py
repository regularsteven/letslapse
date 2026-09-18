import sys; sys.path.insert(0, sys.argv[1])
from svgkit import IOS, tabbar, ACCENT, SEC, RED, wrap
import pathlib
out = pathlib.Path("docs/design/iOS")

def library_row(k, r, name, sub, current, unnamed=False):
    """A Libraries row: title, a subtitle that wraps under the Switch pill (as the app's HStack does), Current or Switch."""
    k.text(32, r + 27, name, 16, SEC if unnamed else "#000")
    lines = wrap(sub, 34 if not current else 52)
    for i, line in enumerate(lines): k.text(32, r + 44 + i * 15, line, 11.5, SEC)
    if current: k.text(361, r + 27, "Current", 15, SEC, anchor="end")
    else: k.pill(287, r + 12, "Switch", w=74, fill="#F3E2CC", text=ACCENT, size=15, h=30)
    h = 44 + 15 * len(lines) + 4
    k.hair(r + h)
    return r + h

def picplace_tail(k, y, user="regularsteven", host="picplace.test", name_lines=("Library “Prague", "LetsLapse Shots”"), count="401 projects · 300,9 MB"):
    k.header(y + 30, "PICPLACE")
    k.card(y + 38, 218, "picplace-card")
    r = y + 38
    r = k.row(r, "Account", trailing="@" + user)
    r = k.row(r, "This device", trailing="iPhone")
    k.text(32, r + 27, "On PicPlace", 16); k.text(361, r + 27, count, 15, SEC, anchor="end")
    k.text(32, r + 44, "originals for 98", 11.5, SEC); k.hair(r + 62); r += 62
    k.text(32, r + 27, name_lines[0], 16); k.text(32, r + 46, name_lines[1], 16)
    k.text(361, r + 36, "@%s on pic…" % user, 15, SEC, anchor="end")
    k.text(32, r + 64, "Connected on 17. 9. 2026 at 14:23", 11.5, SEC)

k = IOS("iOS · Settings · Libraries card · three libraries, the doors · portrait",
 "Mirrors App/SettingsView.swift (librariesCardPhone, the iOS extension at the foot of the file) over App/StorageLocation.swift (StorageRoot's iOS block: libraryFolders, makeLibraryFolder, createFromPicPlace, removeLibraryFolder) and App/LetsLapseApp.swift (ModelHost.switchLibrary) — libraries plan L21/L25, C2c (2026-09-17, code first, mirrored from the running Simulator). Settings scrolled so the LIBRARIES header sits under the status bar, the card in full and the PICPLACE card following. THE CARD: one LLRow per folder of <App Support>/LetsLapse/Libraries/ — title = the identity file's name (grey while it is only the healed placeholder, namedByPerson false), subtitle = 'N projects' (a listing of Projects/) · '@user on host' from the folder's binding, or 'not on PicPlace' (it wraps under the button, as the row's HStack gives the title side the width that is left) — trailing 'Current' (15pt secondary) on the open one and a bordered SWITCH button on the others (disabled while a render runs). Rows sort: the open one first, then by name. A long press opens the row's menu: Rename… (Name this library… while unnamed) and — never on the open one — Remove from this iPhone… (settings.libraries.remove.portrait.svg). THE DOORS, accent LLRows: Add Library from PicPlace… (only while librariesNotOnThisDevice is non-empty; the subtitle names them) and New Library on PicPlace… (signed in on a server with libraries). Signed out with one library the two doors give way to one quiet row, 'One library on this iPhone — Sign in with PicPlace to add your other libraries here or start a new one.' A SWITCH is a new model over the other folder, in place (L22): the tree re-roots and lands back on Settings. The Libraries header carries SettingsAnchor.libraries, so LL_SCROLL=libraries lands here; LL_LIBRARY=switch:|add:|new:|remove:|rename: works the doors without a finger. Verified 2026-09-17 on the Simulator 'C2c Bench' with the throwaway account (the drawn names are Steven's world: Prague LetsLapse Shots open, Holidays and the phone's own library beside it). The tab bar is drawn simplified (labels only).")
y = 76
k.header(y, "LIBRARIES")
k.card(y + 8, 392, "libraries-card")
r = y + 8
r = library_row(k, r, "Prague LetsLapse Shots", "401 projects · @regularsteven on picplace.test", True)
r = library_row(k, r, "Holidays", "877 projects · @regularsteven on picplace.test", False)
r = library_row(k, r, "iPhone", "0 projects · not on PicPlace", False, unnamed=True)
r = k.row(r, "Add Library from PicPlace…", "1 of your libraries is on picplace.test and not on this iPhone: “Client X”.", color=ACCENT)
r = k.row(r, "New Library on PicPlace…", "An empty library on picplace.test as @regularsteven; this iPhone opens it. Nothing is copied.", color=ACCENT, divider=False)
picplace_tail(k, r + 26)
tabbar(k, "Settings")
(out / "settings.libraries.portrait.svg").write_text(k.render())

k = IOS("iOS · Settings · PicPlace card · signed in, the phone's only library unbound — Which library should this iPhone show? · portrait",
 "Mirrors App/PicPlace/PicPlaceViews.swift (PicPlaceSettingsCard, libraryRow's .unbound state; unboundTitle) — libraries plan §17.4, C2c (2026-09-17, mirrored from the running Simulator). Signed in, on a server that keeps libraries apart, with the phone's ONLY library unbound, the accent row asks 'Which library should this iPhone show? — Choose…' (subtitle 'Keeps this library's projects on picplace.test as @regularsteven. The library stays in its folder.'); with other libraries on the phone it reads 'Not on PicPlace — Connect…' as on the Mac. The On PicPlace usage row is hidden while unbound (step 0, plan §17.7) — the card is Account · This device · the question · Server · Sign Out…. The row opens the connect sheet (picplace.connect.portrait.svg). Above it the Libraries card in its one-library, signed-in state: the row and both doors. The tab bar is drawn simplified (labels only).")
y = 76
k.header(y, "LIBRARIES")
k.card(y + 8, 214, "libraries-card")
r = y + 8
r = library_row(k, r, "iPhone", "0 projects · not on PicPlace", True, unnamed=True)
r = k.row(r, "Add Library from PicPlace…", "2 of your libraries are on picplace.test and not on this iPhone: “Prague LetsLapse Shots”, “Holidays”.", color=ACCENT)
r = k.row(r, "New Library on PicPlace…", "An empty library on picplace.test as @regularsteven; this iPhone opens it. Nothing is copied.", color=ACCENT, divider=False)
y2 = r + 26
k.header(y2 + 30, "PICPLACE")
k.card(y2 + 38, 250, "picplace-card")
r = y2 + 38
r = k.row(r, "Account", trailing="@regularsteven")
r = k.row(r, "This device", trailing="iPhone")
k.text(32, r + 27, "Which library should this iPhone show?", 16, ACCENT); k.text(32, r + 46, "— Choose…", 16, ACCENT)
for i, line in enumerate(wrap("Keeps this library's projects on picplace.test as @regularsteven. The library stays in its folder.", 52)): k.text(32, r + 64 + i * 15, line, 11.5, SEC)
k.hair(r + 98); r += 98
r = k.row(r, "Server", trailing="picplace.test")
r = k.row(r, "Sign Out…", color=RED, divider=False)
tabbar(k, "Settings")
(out / "settings.picplace.choose-library.portrait.svg").write_text(k.render())
print("cards regenerated")
