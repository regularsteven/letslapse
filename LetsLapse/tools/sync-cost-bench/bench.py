#!/usr/bin/env python3
"""
bench.py — the PicPlace sync-cost bench: import photos and .lapse projects on
the Mac, edit a few, let the Simulator pull them, edit a few there, and write
a data-pack report of every request each step cost.

The run is a sequence of app launches, one per step, each with the launch
hooks that do the step's work (`LL_IMPORT_STILLS`, `LL_IMPORT_ARCHIVE`,
`LL_APPLY_PRESET`, `LL_PICPLACE_DOWNLOAD`). Every launch carries
`LL_PICPLACE_TRACE=1`, so the app's own console log names every API request
and storage transfer; the report is built from those lines, the app's other
`picplace:` lines, the server's usage ledger and the libraries on disk.

    python3 bench.py run --photos <dir|file…> --lapse <dir|file…> \
        [--mac-root ~/Pictures/LetsLapse/synth] [--sim <udid>] \
        [--token <access>] [--out <dir>] [--edits 3] [--sim-edit download|preview]
    python3 bench.py report <out dir>        # rebuild the report from the raw files
    python3 bench.py token [--user synth]    # mint a personal-access token for the Mac
    python3 bench.py plan …                  # print the steps and stop

Read README.md first: which builds it needs, why Steven's own copy of the
app must not hold the Mac library, and how the numbers are read.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
UNIT = HERE.parent.parent                       # LetsLapse/
RUN_ROOT = Path.home() / "Library/Developer/LetsLapseRun"
MAC_APP = RUN_ROOT / "dd-mac/Build/Products/Debug/LetsLapse.app"
SIM_APP = RUN_ROOT / "dd-sim/Build/Products/Debug-iphonesimulator/LetsLapse.app"
BUNDLE = "com.regularsteven.letslapse"
DEFAULT_MAC_ROOT = Path.home() / "Pictures/LetsLapse/synth"
DEFAULT_SIM = "C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996"          # "LetsLapse Fresh", iOS 27
DEFAULT_PICPLACE = Path.home() / "Sites/picplace"
PRESETS = ["Cinema", "Matte", "Vivid", "Natural"]
UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
LOG_LINE = re.compile(r"^(\d\d:\d\d:\d\d\.\d+)\s+\S+\s+[\d.]+\s+(.*)$")
TRACE_API = re.compile(r"^picplace trace: (GET|POST|PUT|PATCH|DELETE) (\S+) → (\d+) (\d+) ms up=(\d+) down=(\d+)")
TRACE_STORE = re.compile(r"^picplace trace: STORAGE (PUT|GET) (.+?) → (\d+) (\d+) ms bytes=(\d+)")   # names may hold spaces


def log(msg):
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", file=sys.stderr, flush=True)


def run(cmd, check=True, capture=False, env=None, cwd=None, timeout=None):
    proc = subprocess.run([str(c) for c in cmd], check=False, text=True, env=env, cwd=cwd, timeout=timeout,
                          stdout=subprocess.PIPE if capture else None, stderr=subprocess.PIPE if capture else None)
    if check and proc.returncode != 0:
        raise SystemExit(f"bench: `{' '.join(str(c) for c in cmd)}` failed ({proc.returncode})\n{proc.stderr if capture else ''}")
    return proc


def human(n):
    n = float(n)
    for unit in ["B", "KB", "MB", "GB"]:
        if n < 1024 or unit == "GB":
            return f"{n:,.0f} {unit}" if unit == "B" else f"{n:,.1f} {unit}"
        n /= 1024
    return f"{n:,.1f} GB"


# ----------------------------------------------------------------------------- inputs

def expand_inputs(items, suffixes):
    files = []
    for item in items or []:
        path = Path(item).expanduser()
        if path.is_dir():
            files += sorted(p for p in path.rglob("*") if p.is_file() and p.suffix.lower() in suffixes)
        elif path.is_file():
            files.append(path)
        else:
            raise SystemExit(f"bench: no such input {path}")
    return files


# ----------------------------------------------------------------------------- libraries on disk

def project_records(projects_dir: Path):
    """id → {origin, title, mode, kind, folder, bytes} for every project folder."""
    out = {}
    if not projects_dir.exists():
        return out
    for folder in projects_dir.iterdir():
        doc = folder / "project.json"
        if not doc.is_file():
            continue
        try:
            j = json.loads(doc.read_text())
        except Exception:
            continue
        j = j.get("capture", j)                   # the document is {formatVersion, capture, blends}
        pid = j.get("id") or folder.name
        out[pid.lower()] = {
            "id": pid.lower(),
            "origin": (j.get("originID") or j.get("importedFromID") or pid).lower(),
            "title": j.get("name") or j.get("originalName") or j.get("mode") or folder.name,
            "preset": j.get("selectedPreset") or (j.get("presetState") or {}).get("kind"),
            "modifiedAt": j.get("modifiedAt"),
            "mode": j.get("mode"),
            "kind": j.get("kind"),
            "folder": str(folder),
            "bytes": folder_bytes(folder),
        }
    return out


def folder_bytes(folder: Path):
    total = 0
    for root, _, files in os.walk(folder):
        for f in files:
            try:
                total += (Path(root) / f).stat().st_size
            except OSError:
                pass
    return total


def sim_container(udid):
    return Path(run(["xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"], capture=True).stdout.strip())


def sim_library(udid, library_id=None):
    support = sim_container(udid) / "Library/Application Support/LetsLapse"
    libraries = sorted(p for p in (support / "Libraries").glob("*") if p.is_dir())
    if library_id:
        match = [p for p in libraries if p.name.lower() == library_id.lower()]
        if not match:
            raise SystemExit(f"bench: no library {library_id} in the Simulator ({[p.name for p in libraries]})")
        return match[0], support / "Logs"
    if len(libraries) != 1:
        raise SystemExit(f"bench: {len(libraries)} libraries in the Simulator under {support / 'Libraries'} — say which (--sim-library)")
    return libraries[0], support / "Logs"


def sim_library_ids(udid):
    support = sim_container(udid) / "Library/Application Support/LetsLapse"
    return sorted(p.name for p in (support / "Libraries").glob("*") if p.is_dir())


# ----------------------------------------------------------------------------- log reading

def newest_log(logs_dir: Path, after: float):
    candidates = [p for p in logs_dir.glob("console-*.log") if p.stat().st_mtime >= after - 2]
    return max(candidates, key=lambda p: p.stat().st_mtime) if candidates else None


def read_lines(path: Path):
    try:
        return path.read_text(errors="replace").splitlines()
    except FileNotFoundError:
        return []


def picplace_lines(lines):
    """(time, message) for every line that is the sync's — traces included."""
    out = []
    for line in lines:
        m = LOG_LINE.match(line)
        if not m:
            continue
        msg = m.group(2)
        if msg.startswith("picplace") or msg.startswith("LL_") or msg.startswith("assets:") or "import" in msg.lower() or "archive" in msg.lower():
            out.append((m.group(1), msg))
    return out


def endpoint_pattern(path):
    path = UUID_RE.sub("{u}", path)
    return path


def storage_group(name):
    """Names are paths within the project; the heavy folders are grouped."""
    if "/" in name:
        return name.split("/", 1)[0] + "/*"
    return name


def parse_traces(lines):
    api, store = [], []
    for t, msg in picplace_lines(lines):
        m = TRACE_API.match(msg)
        if m:
            api.append({"t": t, "method": m.group(1), "path": m.group(2), "pattern": f"{m.group(1)} {endpoint_pattern(m.group(2))}",
                        "status": int(m.group(3)), "ms": int(m.group(4)), "up": int(m.group(5)), "down": int(m.group(6))})
            continue
        m = TRACE_STORE.match(msg)
        if m:
            store.append({"t": t, "verb": m.group(1), "name": m.group(2), "group": storage_group(m.group(2)),
                          "status": int(m.group(3)), "ms": int(m.group(4)), "bytes": int(m.group(5))})
    return api, store


HIGHLIGHT = re.compile(r"picplace: (library |.*filed|.*elsewhere|.*evict|.*removed|initial sync|check \(|push queue|originals queue|blends queue|pulled |.* — uploading |pacing|rate limited|sync of .* failed|conflict|.*backed up|.*PicPlace finished checking|library .*not here)|^LL_|^assets: .* recorded|archive|import")


def highlights(lines, limit=60):
    out = [f"{t} {msg}" for t, msg in picplace_lines(lines) if HIGHLIGHT.search(msg) and not msg.startswith("picplace trace")]
    if len(out) > limit:
        out = out[: limit // 2] + [f"… {len(out) - limit} line(s) left out …"] + out[-limit // 2:]
    return out


# ----------------------------------------------------------------------------- server

def ledger(picplace: Path, user: str, since: int):
    env = dict(os.environ, BENCH_USER=user, BENCH_SINCE=str(since))
    proc = subprocess.run(["php", "artisan", "tinker", f"--execute=require '{HERE / 'ledger.php'}';"], cwd=picplace, env=env,
                          text=True, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    for line in proc.stdout.splitlines():
        if line.startswith("BENCH_JSON "):
            return json.loads(line[len("BENCH_JSON "):])
    raise SystemExit(f"bench: the ledger probe printed no JSON:\n{proc.stdout[-2000:]}")


def mint_token(picplace: Path, user: str):
    code = (f"$u = App\\Models\\User::where('username', '{user}')->firstOrFail();"
            "$t = $u->createToken('sync-cost-bench', ['projects:read','projects:write','assets:read','assets:write']);"
            "echo 'BENCH_TOKEN '.$t->accessToken.PHP_EOL;")
    proc = subprocess.run(["php", "artisan", "tinker", f"--execute={code}"], cwd=picplace, text=True, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    for line in proc.stdout.splitlines():
        if line.startswith("BENCH_TOKEN "):
            return line.split(" ", 1)[1].strip()
    raise SystemExit(f"bench: could not mint a token:\n{proc.stdout[-2000:]}")


def server_ok(server: str, token: str | None):
    cmd = ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "8", "-H", "Accept: application/json"]
    if token:
        cmd += ["-H", f"Authorization: Bearer {token}"]
    cmd.append(f"{server}/api/letslapse/v1/status")
    return run(cmd, check=False, capture=True).stdout.strip()


# ----------------------------------------------------------------------------- devices

class Mac:
    def __init__(self, root: Path, token: str, server: str, device_id: str | None = None):
        self.root, self.token, self.server, self.device_id = root, token, server, device_id
        self.proc = None

    @property
    def logs(self):
        return self.root / "Logs"

    @property
    def projects(self):
        return self.root / "Projects"

    def others_holding(self):
        out = run(["pgrep", "-fl", "LetsLapse.app/Contents/MacOS/LetsLapse"], check=False, capture=True).stdout
        return [l for l in out.splitlines() if l.strip()]

    def launch(self, hooks: dict):
        binary = MAC_APP / "Contents/MacOS/LetsLapse"
        if self.device_id:
            # A copied library carries its source's `Projects/.lock`; the copy
            # is nobody's yet.
            (self.projects / ".lock").unlink(missing_ok=True)
        env = dict(os.environ)
        env.update({k: str(v) for k, v in hooks.items()})
        env["LL_PICPLACE_TRACE"] = "1"
        env["LL_PICPLACE_TOKENS"] = f"{self.token}:none"
        env["LL_PICPLACE_SERVER"] = self.server
        # The originals queue on for the run without writing the setting
        # (it is per device and library, so a scratch device would start off).
        arguments = [str(binary), "-ApplePersistenceIgnoreState", "YES", "-storage.libraryRootPath", str(self.root),
                     "-letslapse.picplace.autoOriginals", "YES"]
        if self.device_id:
            # A scratch copy of a library as its own device (the two-device bench's trick).
            arguments += ["-letslapse.deviceID", self.device_id]
        self.proc = subprocess.Popen(arguments, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"mac: launched pid {self.proc.pid} with {sorted(k for k in hooks)}")
        return self.proc.pid

    def quit(self):
        if not self.proc:
            return
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(20)
        except subprocess.TimeoutExpired:
            log("mac: did not quit in 20 s — killing")
            self.proc.kill()
            self.proc.wait(10)
        log(f"mac: pid {self.proc.pid} quit")
        self.proc = None


class Sim:
    """Paths are resolved on every use: an install moves the data container."""

    def __init__(self, udid: str, active: str | None = None):
        self.udid = udid
        self.active = active          # the library folder id the next launch opens; None = the only one

    @property
    def library(self):
        return sim_library(self.udid, self.active)[0]

    @property
    def logs(self):
        return sim_container(self.udid) / "Library/Application Support/LetsLapse/Logs"

    @property
    def projects(self):
        return self.library / "Projects"

    def launch(self, hooks: dict, arguments=()):
        env = dict(os.environ)
        for k, v in dict(hooks, LL_PICPLACE_TRACE="1").items():
            env[f"SIMCTL_CHILD_{k}"] = str(v)
        arguments = list(arguments)
        if self.active:
            # Opens that library for the run without writing the setting.
            arguments += ["-storage.activeLibrary", self.active]
        out = run(["xcrun", "simctl", "launch", "--terminate-running-process", self.udid, BUNDLE, *arguments], capture=True, env=env).stdout
        log(f"sim: launched — {out.strip()} with {sorted(k for k in hooks)}")

    def quit(self):
        run(["xcrun", "simctl", "terminate", self.udid, BUNDLE], check=False, capture=True)
        log("sim: terminated")


# ----------------------------------------------------------------------------- the run

class Bench:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out).expanduser() if args.out else UNIT / "docs/fieldtests" / f"{dt.date.today():%Y-%m-%d}-sync-cost-bench"
        self.raw = self.out / "raw"
        self.picplace = Path(args.picplace).expanduser()
        self.state_path = self.out / "run.json"
        self.state = {"steps": [], "started": dt.datetime.now().isoformat(timespec="seconds"), "args": {k: str(v) for k, v in vars(args).items() if k != "func"}}

    # -- steps -----------------------------------------------------------------

    def plan(self):
        photos = expand_inputs(self.args.photos, {".jpg", ".jpeg", ".heic", ".dng", ".png", ".tif", ".tiff"})
        lapses = expand_inputs(self.args.lapse, {".lapse"})
        n = self.args.edits
        steps = [
            ("mac-baseline", "Mac", "launch, one check, quit", {}),
            ("mac-import-photos", "Mac", f"import {len(photos)} photo(s) as separate projects; push, originals up", {"import": photos}),
            ("mac-edit-photos", "Mac", f"preset on {n} of the new photos", {}),
            ("mac-import-lapse", "Mac", f"import {len(lapses)} .lapse project(s); push, originals up", {"archives": lapses}),
            ("mac-edit-lapse", "Mac", f"preset on {n} of the imported .lapse projects", {}),
            ("sim-pull", "Simulator", "launch, pull every new project's preview", {}),
        ]
        if self.args.sim_edit == "download":
            steps.append(("sim-download", "Simulator", f"download the originals of {n} photos not edited on the Mac (the just-in-time prompt's answer)", {}))
        steps += [
            ("sim-edit", "Simulator", f"preset on those {n} photos", {}),
            ("mac-after", "Mac", "launch, one check: what the Simulator's edits cost the Mac", {}),
        ]
        wanted = set(self.args.steps.split(",")) if self.args.steps else None
        if wanted is not None:
            return [s for s in steps if s[0] in wanted], photos, lapses
        if not lapses:
            steps = [s for s in steps if "lapse" not in s[0]]
        if not photos:
            steps = [s for s in steps if "photos" not in s[0] and not s[0].startswith("sim-")]
        return steps, photos, lapses

    def preflight(self, photos, lapses):
        problems = []
        if not MAC_APP.exists():
            problems.append(f"no Mac Debug build at {MAC_APP} — `driver.py build mac`")
        if not photos and not self.args.steps:
            problems.append("no photos (--photos)")
        if not Path(self.args.mac_root).expanduser().exists():
            problems.append(f"no Mac library at {self.args.mac_root}")
        if not (self.picplace / "artisan").exists():
            problems.append(f"no picplace repo at {self.picplace}")
        status = server_ok(self.args.server, None)
        if status != "401":
            problems.append(f"{self.args.server} answered {status or 'nothing'} to an unauthenticated /status (expected 401)")
        garage = run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", self.args.storage], check=False, capture=True).stdout.strip()
        if garage not in {"403", "400", "200"}:
            problems.append(f"storage at {self.args.storage} answered {garage or 'nothing'} (a TCP probe is not enough — Docker's forwarder accepts and breaks the pipe)")
        return problems

    def settle(self, logs_dir: Path, launched_at: float, step: str, require=None, min_seconds=30, quiet=None, timeout=None):
        """Wait until the app's log has been quiet for `quiet` seconds (no
        sync line, no import line) and `require(lines)` is true; return the
        log path and its lines."""
        quiet = quiet or self.args.quiet
        timeout = timeout or self.args.step_timeout
        started = time.time()
        path = None
        last_change = time.time()
        seen = 0
        while True:
            time.sleep(2)
            if path is None:
                path = newest_log(logs_dir, launched_at)
                if path is None:
                    if time.time() - started > 60:
                        raise SystemExit(f"bench: {step}: no console log appeared in {logs_dir} within 60 s")
                    continue
                log(f"{step}: log {path.name}")
            lines = read_lines(path)
            if any("read-only" in l or "libraryReadOnly" in l for l in lines[-200:]):
                raise SystemExit(f"bench: {step}: the library opened READ-ONLY — another LetsLapse holds it. Quit it and run again.")
            count = len(picplace_lines(lines))
            if count != seen:
                seen = count
                last_change = time.time()
            elapsed = time.time() - started
            satisfied = require(lines) if require else True
            if elapsed >= min_seconds and time.time() - last_change >= quiet and satisfied:
                return path, lines
            if elapsed > timeout:
                log(f"{step}: timed out after {timeout} s (requirement {'met' if satisfied else 'NOT met'}) — moving on")
                return path, lines

    def snapshot(self, mac: Mac, sim: Sim | None):
        return {
            "mac_projects": project_records(mac.projects),
            "sim_projects": project_records(sim.projects) if sim else {},
            "mac_sync_state_bytes": (mac.root / "PicPlace/sync-state.json").stat().st_size if (mac.root / "PicPlace/sync-state.json").exists() else 0,
            "sim_sync_state_bytes": (sim.library / "PicPlace/sync-state.json").stat().st_size if sim and (sim.library / "PicPlace/sync-state.json").exists() else 0,
        }

    def record(self, name, device, description, launched_at, ended_at, log_path, lines, before, after, ledger_before, ledger_after, hooks, extra=None):
        api, store = parse_traces(lines)
        raw_log = self.raw / f"{len(self.state['steps']) + 1:02d}-{name}.log"
        raw_log.write_text("\n".join(lines) + "\n")
        step = {
            "name": name, "device": device, "description": description,
            "started": dt.datetime.fromtimestamp(launched_at).isoformat(timespec="seconds"),
            "ended": dt.datetime.fromtimestamp(ended_at).isoformat(timespec="seconds"),
            "seconds": round(ended_at - launched_at, 1),
            "hooks": {k: (v if len(str(v)) < 200 else f"{str(v)[:200]}…") for k, v in hooks.items()},
            "log": str(raw_log.relative_to(self.out)),
            "api": api, "storage": store,
            "highlights": highlights(lines),
            "ledger_before": ledger_before, "ledger_after": ledger_after,
            "mac_projects_before": len(before["mac_projects"]), "mac_projects_after": len(after["mac_projects"]),
            "sim_projects_before": len(before["sim_projects"]), "sim_projects_after": len(after["sim_projects"]),
            "mac_sync_state_bytes": after["mac_sync_state_bytes"], "sim_sync_state_bytes": after["sim_sync_state_bytes"],
            "new_mac_projects": [after["mac_projects"][k] for k in after["mac_projects"] if k not in before["mac_projects"]],
            "new_sim_projects": [after["sim_projects"][k] for k in after["sim_projects"] if k not in before["sim_projects"]],
        }
        if extra:
            step.update(extra)
        self.state["steps"].append(step)
        self.state_path.write_text(json.dumps(self.state, indent=1, default=str))
        log(f"{name}: {len(api)} API request(s), {len(store)} storage transfer(s), {step['seconds']} s")

    def run(self):
        steps, photos, lapses = self.plan()
        problems = self.preflight(photos, lapses)
        if problems:
            raise SystemExit("bench: not starting —\n  " + "\n  ".join(problems))
        self.out.mkdir(parents=True, exist_ok=True)
        self.raw.mkdir(exist_ok=True)

        token = self.args.token or mint_token(self.picplace, self.args.user)
        if server_ok(self.args.server, token) != "200":
            raise SystemExit("bench: the token does not open /status on " + self.args.server)
        mac = Mac(Path(self.args.mac_root).expanduser(), token, self.args.server, self.args.device_id)
        holders = mac.others_holding()
        if holders and not self.args.force:
            raise SystemExit("bench: another LetsLapse is running on this Mac — if it holds the library the bench's copy opens read-only. "
                             "Quit it (or pass --force if it is on another library):\n  " + "\n  ".join(holders))
        sim = Sim(self.args.sim)
        if any(s[1] == "Simulator" for s in steps):
            if self.args.install_sim:
                if not SIM_APP.exists():
                    raise SystemExit(f"no Simulator Debug build at {SIM_APP} — `driver.py build sim --device {self.args.sim}`")
                run(["xcrun", "simctl", "install", self.args.sim, SIM_APP])
                log("sim: installed the Debug build")
            sim.quit()

        self.state["photos"] = [str(p) for p in photos]
        self.state["lapses"] = [str(p) for p in lapses]
        self.state["out"] = str(self.out)
        edited_photos, edited_lapse, sim_targets = [], [], []
        ledger_now = ledger(self.picplace, self.args.user, 0)
        self.state["ledger_start"] = ledger_now
        since = ledger_now["ledger_max_id"]
        n = self.args.edits
        presets = (self.args.presets.split(",") if self.args.presets else PRESETS)

        def preset_hook(targets):
            return ";".join(f"{t['origin']}:{presets[i % len(presets)]}@{2 + 2 * i}" for i, t in enumerate(targets))

        for name, device, description, payload in steps:
            hooks = {}
            require = None
            expected_new = 0
            if name == "mac-baseline" or name == "mac-after":
                hooks = {"LL_TAB": "projects"}
                require = lambda lines: any("picplace: check (" in l and "—" in l for l in lines)
            elif name == "mac-import-photos":
                hooks = {"LL_TAB": "projects", "LL_IMPORT_STILLS": ":".join(str(p) for p in payload["import"]), "LL_IMPORT_ANSWER": "photos"}
                expected_new = len(payload["import"])
                require = lambda lines: any("push queue —" in l for l in lines)
            elif name == "mac-import-lapse":
                hooks = {"LL_TAB": "projects", "LL_IMPORT_ARCHIVE": ":".join(str(p) for p in payload["archives"])}
                expected_new = len(payload["archives"])
                require = lambda lines: any("push queue —" in l for l in lines)
            elif name == "mac-edit-photos":
                hooks = {"LL_TAB": "projects", "LL_APPLY_PRESET": preset_hook(edited_photos)}
                require = lambda lines: any("push queue —" in l for l in lines)
            elif name == "mac-edit-lapse":
                hooks = {"LL_TAB": "projects", "LL_APPLY_PRESET": preset_hook(edited_lapse)}
                require = lambda lines: any("push queue —" in l for l in lines)
            elif name == "sim-pull":
                hooks = {"LL_TAB": "gallery"}
                want = len(project_records(mac.projects)) - len(project_records(sim.projects))
                log(f"{name}: expecting {want} pull(s)")
                require = lambda lines, want=want: sum(1 for l in lines if "picplace: pulled " in l) >= want
            elif name == "sim-download":
                hooks = {"LL_TAB": "gallery", "LL_PICPLACE_DOWNLOAD": ",".join(t["origin"] for t in sim_targets)}
                require = lambda lines: sum(1 for l in lines if "downloaded the originals" in l) >= len(sim_targets)
            elif name == "sim-edit":
                hooks = {"LL_TAB": "gallery", "LL_APPLY_PRESET": preset_hook(sim_targets)}
                require = lambda lines: sum(1 for l in lines if "LL_APPLY_PRESET applied" in l) >= len(sim_targets) and any("push queue —" in l for l in lines)

            needs = {"mac-edit-photos": edited_photos, "mac-edit-lapse": edited_lapse, "sim-download": sim_targets, "sim-edit": sim_targets}
            if name in needs and not needs[name]:
                log(f"{name}: nothing to edit — skipped")
                continue

            log(f"== {name}: {description}")
            before = self.snapshot(mac, sim)
            ledger_before = ledger(self.picplace, self.args.user, since)
            launched_at = time.time()
            try:
                if device == "Mac":
                    mac.launch(hooks)
                    path, lines = self.settle(mac.logs, launched_at, name, require=require, min_seconds=45 if expected_new else 30)
                else:
                    sim.launch(hooks)
                    path, lines = self.settle(sim.logs, launched_at, name, require=require, min_seconds=30)
            finally:
                (mac if device == "Mac" else sim).quit()
            ended_at = time.time()
            time.sleep(2)
            after = self.snapshot(mac, sim)
            ledger_after = ledger(self.picplace, self.args.user, since)
            extra = {}
            if name == "mac-import-photos":
                new = sorted((after["mac_projects"][k] for k in after["mac_projects"] if k not in before["mac_projects"]), key=lambda r: r["title"])
                edited_photos = new[:n]
                sim_targets = new[n:2 * n] if len(new) >= 2 * n else new[n:]
                extra["edited"] = [t["origin"] for t in edited_photos]
                extra["sim_targets"] = [t["origin"] for t in sim_targets]
                if len(new) != expected_new:
                    log(f"{name}: expected {expected_new} new project(s), found {len(new)}")
            if name == "mac-import-lapse":
                new = sorted((after["mac_projects"][k] for k in after["mac_projects"] if k not in before["mac_projects"]), key=lambda r: r["title"])
                edited_lapse = new[:n]
                extra["edited"] = [t["origin"] for t in edited_lapse]
                if len(new) != expected_new:
                    log(f"{name}: expected {expected_new} new project(s), found {len(new)}")
            self.record(name, device, description, launched_at, ended_at, path, lines, before, after, ledger_before, ledger_after, hooks, extra)

        self.state["ledger_end"] = ledger(self.picplace, self.args.user, 0)
        self.state["finished"] = dt.datetime.now().isoformat(timespec="seconds")
        self.state_path.write_text(json.dumps(self.state, indent=1, default=str))
        report = write_report(self.state, self.out)
        log(f"report → {report}")


    # -- the two-library scenario ------------------------------------------------

    def step(self, mac, sim, name, device, description, hooks, require=None, arguments=(), min_seconds=30, since=0, extra=None):
        """One launch: snapshot, ledger, launch with hooks, settle, quit, record."""
        log(f"== {name}: {description}")
        before = self.snapshot(mac, sim)
        ledger_before = ledger(self.picplace, self.args.user, since)
        launched_at = time.time()
        try:
            if device == "Mac":
                mac.launch(hooks)
                path, lines = self.settle(mac.logs, launched_at, name, require=require, min_seconds=min_seconds)
            else:
                sim.launch(hooks, arguments)
                path, lines = self.settle(sim.logs, launched_at, name, require=require, min_seconds=min_seconds)
        finally:
            (mac if device == "Mac" else sim).quit()
        ended_at = time.time()
        time.sleep(2)
        after = self.snapshot(mac, sim)
        ledger_after = ledger(self.picplace, self.args.user, since)
        self.record(name, device, description, launched_at, ended_at, path, lines, before, after, ledger_before, ledger_after, hooks, extra)
        return lines, before, after

    def api(self, token, method, path, body=None):
        cmd = ["curl", "-sk", "--max-time", "20", "-X", method, "-H", "Accept: application/json", "-H", f"Authorization: Bearer {token}"]
        if body is not None:
            cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
        cmd.append(f"{self.args.server}/api/letslapse/v1/{path}")
        out = run(cmd, capture=True).stdout
        try:
            return json.loads(out)
        except Exception:
            return {"raw": out[:400]}

    def run_libraries(self):
        """Mac on library A, Simulator on a NEW library B of the same account:
        what each device pays for the other's library, what leaks across,
        what a twin of the same project does, and what a move costs."""
        a = self.args
        photos = expand_inputs(a.photos, {".jpg", ".jpeg", ".heic", ".dng", ".png"})
        lapses = expand_inputs(a.lapse, {".lapse"})
        problems = [p for p in self.preflight(photos or [Path("x")], lapses) if "photos" not in p]
        if problems:
            raise SystemExit("bench: not starting —\n  " + "\n  ".join(problems))
        self.out.mkdir(parents=True, exist_ok=True)
        self.raw.mkdir(exist_ok=True)
        token = a.token or mint_token(self.picplace, a.user)
        if server_ok(a.server, token) != "200":
            raise SystemExit("bench: the token does not open /status on " + a.server)
        mac = Mac(Path(a.mac_root).expanduser(), token, a.server, a.device_id)
        holders = mac.others_holding()
        if holders and not a.force:
            raise SystemExit("bench: another LetsLapse is running on this Mac — quit it (or --force):\n  " + "\n  ".join(holders))
        ids_before = sim_library_ids(a.sim)
        library_a = a.sim_library or (ids_before[0] if len(ids_before) == 1 else None)
        if not library_a:
            raise SystemExit(f"bench: the Simulator holds {ids_before}; say which is library A with --sim-library")
        sim = Sim(a.sim, active=library_a)
        if a.install_sim:
            run(["xcrun", "simctl", "install", a.sim, SIM_APP])
            log("sim: installed the Debug build")
        sim.quit()
        self.state.update({"scenario": "libraries", "photos": [str(p) for p in photos], "lapses": [str(p) for p in lapses], "out": str(self.out)})
        self.state["ledger_start"] = ledger(self.picplace, a.user, 0)
        since = self.state["ledger_start"]["ledger_max_id"]
        checked = lambda lines: any("picplace: check (" in l and " — " in l for l in lines)
        status = self.api(token, "GET", "status")
        self.state["libraries_before"] = status.get("libraries")
        name_b = a.library_name

        if a.resume_b:
            # Carry on a run that stopped after library B was made: keep its steps.
            previous = json.loads(self.state_path.read_text())
            for key in ("steps", "started", "ledger_start", "libraries_before"):
                self.state[key] = previous.get(key)
            since = self.state["ledger_start"]["ledger_max_id"]
            library_b = a.resume_b
            self.state["library_a"], self.state["library_b"] = library_a, library_b
            sim.active = library_b
            self._libraries_tail(mac, sim, token, library_a, library_b, since, checked)
            return
        self.step(mac, sim, "sim-a-baseline", "Simulator", "Simulator on library A: one launch, its checks", {"LL_TAB": "gallery"}, checked, since=since)

        lines, _, _ = self.step(mac, sim, "sim-new-library", "Simulator",
                                f"create library “{name_b}” on PicPlace from the phone's Libraries section (the real door), which switches to it",
                                {"LL_TAB": "settings", "LL_SCROLL": "libraries", "LL_LIBRARY": f"new:{name_b}"},
                                lambda lines: any("created on" in l and "placed in Libraries/" in l for l in lines), since=since)
        made = [i for i in sim_library_ids(a.sim) if i not in ids_before]
        if len(made) != 1:
            raise SystemExit(f"bench: expected one new library folder in the Simulator, found {made}")
        library_b = made[0]
        self.state["library_a"], self.state["library_b"] = library_a, library_b
        log(f"library B = {library_b}")

        sim.active = library_b
        hooks = {"LL_TAB": "gallery"}
        if photos:
            hooks.update({"LL_IMPORT_STILLS": ":".join(str(p) for p in photos), "LL_IMPORT_ANSWER": "photos"})
        if lapses:
            hooks["LL_IMPORT_ARCHIVE"] = ":".join(str(p) for p in lapses)
        self.step(mac, sim, "sim-b-import", "Simulator",
                  f"library B: import {len(photos)} photo(s) whose bytes library A already holds, and {len(lapses)} .lapse project(s) library A already holds (twins by origin); originals on",
                  hooks, lambda lines: any("push queue —" in l for l in lines),
                  arguments=["-letslapse.picplace.autoOriginals", "YES"], min_seconds=60, since=since)

        self.step(mac, sim, "mac-a-check", "Mac", "Mac on library A after library B gained projects: does anything of B arrive?", {"LL_TAB": "projects"}, checked, since=since)
        self.step(mac, sim, "sim-b-check", "Simulator", "library B idle check: what a small library pays for the account's big one", {"LL_TAB": "gallery"}, checked, since=since)

        self._libraries_tail(mac, sim, token, library_a, library_b, since, checked)

    def _libraries_tail(self, mac, sim, token, library_a, library_b, since, checked):
        a = self.args
        # Move one of A's projects (originals on the Mac, a preview on the
        # Simulator's copy of A) into B, as another client or the web would.
        # B's SERVER uuid is its binding's, not its folder's name.
        binding = json.loads((sim.library / "PicPlace/account.json").read_text())
        server_b = binding["library"]["uuid"].lower()
        in_b = {p["uuid"].lower() for p in self.api(token, "GET", f"projects?library={server_b}").get("projects", [])}
        candidates = sorted((r for r in project_records(mac.projects).values() if r["origin"] not in in_b), key=lambda r: (r["title"], r["origin"]))
        if not candidates:
            raise SystemExit("bench: no project on the Mac to move")
        moved = candidates[0]
        # The API refuses a token no device is registered to: the bench moves
        # the project as a client of its own (a stand-in for the web or a
        # third device).
        self.api(token, "POST", "device", {"device_key": "5c0de5c0-0000-4000-8000-0000000be9c4", "name": "sync-cost-bench", "platform": "macos",
                                           "model": "bench", "os_version": "bench", "app_version": "bench"})
        result = self.api(token, "POST", f"libraries/{server_b}/projects", {"projects": [moved["origin"]]})
        self.state["moved"] = {"origin": moved["origin"], "title": moved["title"], "result": result}
        log(f"moved {moved['title']} ({moved['origin'][:8]}) from A to B on the server: {result}")

        self.step(mac, sim, "mac-a-after-move", "Mac", f"Mac on A after “{moved['title']}” ({moved['origin'][:8]}) was filed under B on the server", {"LL_TAB": "projects"}, checked, since=since)
        self.step(mac, sim, "sim-b-after-move", "Simulator", "library B after the move: the project arrives", {"LL_TAB": "gallery"}, checked, since=since)
        sim.active = library_a
        self.step(mac, sim, "sim-a-after-move", "Simulator", "the Simulator back on library A: its preview of the moved project", {"LL_TAB": "gallery"}, checked, since=since)
        sim.active = library_b
        self.step(mac, sim, "sim-b-idle", "Simulator", "library B once more with nothing changed: do the same conflicts or notices repeat?", {"LL_TAB": "gallery"}, checked, since=since)

        # Leave the Simulator the way it was found: library A is the one it opens.
        run(["xcrun", "simctl", "spawn", a.sim, "defaults", "write", BUNDLE, "storage.activeLibrary", library_a], check=False, capture=True)
        self.state["libraries_after"] = self.api(token, "GET", "status").get("libraries")
        self.state["ledger_end"] = ledger(self.picplace, a.user, 0)
        self.state["finished"] = dt.datetime.now().isoformat(timespec="seconds")
        self.state_path.write_text(json.dumps(self.state, indent=1, default=str))
        log(f"report → {write_report(self.state, self.out)}")


# ----------------------------------------------------------------------------- report

def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def api_table(api):
    by = defaultdict(lambda: {"n": 0, "ms": 0, "up": 0, "down": 0, "fail": 0})
    for r in api:
        b = by[r["pattern"]]
        b["n"] += 1
        b["ms"] += r["ms"]
        b["up"] += r["up"]
        b["down"] += r["down"]
        if r["status"] >= 400 and not (r["status"] == 404 and "claim" in r["pattern"]):
            b["fail"] += 1
    rows = [(k, v["n"], round(v["ms"] / v["n"]), human(v["up"]), human(v["down"]), v["fail"] or "")
            for k, v in sorted(by.items(), key=lambda kv: -kv[1]["n"])]
    rows.append(("**total**", len(api), round(sum(r["ms"] for r in api) / max(1, len(api))), human(sum(r["up"] for r in api)), human(sum(r["down"] for r in api)), sum(v["fail"] for v in by.values()) or ""))
    return table(["Endpoint", "Requests", "avg ms", "Body up", "Body down", "Failed"], rows)


def storage_table(store):
    by = defaultdict(lambda: {"n": 0, "bytes": 0, "ms": 0})
    for r in store:
        b = by[(r["verb"], r["group"])]
        b["n"] += 1
        b["bytes"] += r["bytes"]
        b["ms"] += r["ms"]
    rows = [(f"{k[0]} {k[1]}", v["n"], human(v["bytes"]), round(v["ms"] / v["n"])) for k, v in sorted(by.items())]
    rows.append(("**total**", len(store), human(sum(r["bytes"] for r in store)), round(sum(r["ms"] for r in store) / max(1, len(store)))))
    return table(["Storage transfer", "Objects", "Bytes", "avg ms"], rows)


def ledger_delta(before, after):
    rows = []
    # PHP encodes an empty map as `[]`: no events yet is a list, not a dict.
    be = before.get("events") or {}
    ae = after.get("events") or {}
    events = set(be) | set(ae)
    for e in sorted(events):
        b = be.get(e, {"n": 0, "bytes_in": 0, "bytes_out": 0})
        a = ae.get(e, {"n": 0, "bytes_in": 0, "bytes_out": 0})
        if a["n"] - b["n"]:
            rows.append((e, a["n"] - b["n"], human(a["bytes_in"] - b["bytes_in"]), human(a["bytes_out"] - b["bytes_out"])))
    return table(["Ledger event", "Rows", "bytes_in", "bytes_out"], rows) if rows else "_no ledger rows_"


def write_report(state, out: Path):
    steps = state["steps"]
    for s in steps:
        raw = out / s["log"]
        if raw.exists():
            lines = read_lines(raw)
            s["api"], s["storage"] = parse_traces(lines)
            s["highlights"] = highlights(lines)
    lines = [f"# PicPlace sync-cost bench: {state['started'][:10]}", "",
             f"**Started** {state['started']} · **finished** {state.get('finished', '—')} · raw logs and `run.json` in [`raw/`](raw/).",
             "",
             "A data pack, not an analysis. Every request comes from the app's own `picplace trace:` lines (`LL_PICPLACE_TRACE=1`): "
             "API bodies are JSON bytes without headers; storage bytes are the object's bytes. Ledger rows are the server's `letslapse_usage_events` for the account. "
             "Each step is one launch of the app with the hooks shown, settled until its log was quiet, then quit; a launch's own check (2 to 5 requests) is inside each step's figures.",
             "",
             "## Inputs", "",
             f"- Photos: {len(state.get('photos', []))} file(s) — `{state.get('photos', ['—'])[0]}` …" if state.get("photos") else "- Photos: none",
             f"- `.lapse` projects: {len(state.get('lapses', []))} file(s)" + (f" — `{state['lapses'][0]}` …" if state.get("lapses") else ""),
             f"- Mac library `{state['args'].get('mac_root')}`, Simulator `{state['args'].get('sim')}`, server `{state['args'].get('server')}`, account `{state['args'].get('user')}`.",
             f"- Simulator edit mode: **{state['args'].get('sim_edit')}** (download = the originals come down first, as the editor's just-in-time prompt would; preview = the preset is written over the preview alone).",
             "", "## Summary", ""]
    rows = []
    for s in steps:
        api, store = s["api"], s["storage"]
        new = len(s["new_mac_projects"]) if s["device"] == "Mac" else len(s["new_sim_projects"])
        per = f"{len(api) / new:.1f}" if new else ""
        rows.append((s["name"], s["device"], s["seconds"], len(api), human(sum(r["up"] for r in api)), human(sum(r["down"] for r in api)),
                     sum(1 for r in store if r["verb"] == "PUT"), human(sum(r["bytes"] for r in store if r["verb"] == "PUT")),
                     sum(1 for r in store if r["verb"] == "GET"), human(sum(r["bytes"] for r in store if r["verb"] == "GET")),
                     new or "", per))
    lines.append(table(["Step", "Device", "s", "API req", "API up", "API down", "PUTs", "PUT bytes", "GETs", "GET bytes", "New projects", "API req / new project"], rows))
    if state.get("scenario") == "libraries":
        lines += ["", f"Library A on the Simulator: `{state.get('library_a')}`. Library B (created by the run): `{state.get('library_b')}`.",
                  f"Moved on the server from A to B: {json.dumps(state.get('moved'))}",
                  "", "Libraries on the account before:", "", "```", json.dumps(state.get("libraries_before"), indent=1), "```",
                  "after:", "", "```", json.dumps(state.get("libraries_after"), indent=1), "```"]
    lines += ["", "Sync-state files at the end: Mac " + human(steps[-1]["mac_sync_state_bytes"]) + ", Simulator " + human(steps[-1]["sim_sync_state_bytes"]) + "." if steps else "", ""]
    if "ledger_start" in state and "ledger_end" in state:
        lines += ["## Server, start → end", "", ledger_delta(state["ledger_start"], state["ledger_end"]), "",
                  "Account tables at the end:", "",
                  table(["Table", "Value"], [
                      ("projects live / trashed", f"{state['ledger_end']['projects']['live']} / {state['ledger_end']['projects']['trashed']}"),
                      ("projects by type", json.dumps(state["ledger_end"]["projects"]["by_type"])),
                      ("manifest bytes", human(state["ledger_end"]["projects"]["manifest_bytes"])),
                      ("assets", "; ".join(f"{a['kind']} {a['status']}: {a['n']} ({human(a['bytes'])})" for a in state["ledger_end"]["assets"])),
                      ("presences by tier", json.dumps(state["ledger_end"]["presences"])),
                      ("index rows / name NULL / records indexed", f"{state['ledger_end']['index']['rows']} / {state['ledger_end']['index']['name_null']} / {state['ledger_end']['index']['records_indexed']}"),
                      ("pending uploads", state["ledger_end"]["uploads_pending"]),
                  ]), ""]
    for i, s in enumerate(steps, 1):
        lines += [f"## {i}. {s['name']} — {s['device']}", "", f"_{s['description']}._ {s['started'][11:]} → {s['ended'][11:]} ({s['seconds']} s). Hooks: " +
                  (", ".join(f"`{k}={v}`" for k, v in s["hooks"].items() if k != "LL_TAB") or "none beyond the trace"), ""]
        if s.get("edited"):
            lines += ["Edited (origin ids): " + ", ".join(f"`{e[:8]}`" for e in s["edited"]), ""]
        if s.get("sim_targets"):
            lines += ["Chosen for the Simulator's edits: " + ", ".join(f"`{e[:8]}`" for e in s["sim_targets"]), ""]
        if s["new_mac_projects"] or s["new_sim_projects"]:
            new = s["new_mac_projects"] or s["new_sim_projects"]
            lines += [f"New projects on the {s['device']}: {len(new)}, {human(sum(p['bytes'] for p in new))} on disk.", ""]
        lines += ["**API requests**", "", api_table(s["api"]) if s["api"] else "_none_", "",
                  "**Storage transfers**", "", storage_table(s["storage"]) if s["storage"] else "_none_", "",
                  "**Ledger rows written during the step**", "", ledger_delta(s["ledger_before"], s["ledger_after"]), "",
                  "**Log highlights**", "", "```", *s["highlights"], "```", "",
                  f"Full log: [`{s['log']}`]({s['log']}) · projects on the Mac {s['mac_projects_before']} → {s['mac_projects_after']}, on the Simulator {s['sim_projects_before']} → {s['sim_projects_after']}.", ""]
    path = out / "README.md"
    path.write_text("\n".join(lines))
    return path


# ----------------------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--photos", nargs="*", help="photo files or folders (imported as separate projects)")
        p.add_argument("--lapse", nargs="*", help=".lapse files or folders")
        p.add_argument("--mac-root", default=str(DEFAULT_MAC_ROOT))
        p.add_argument("--sim", default=DEFAULT_SIM, help="Simulator udid")
        p.add_argument("--server", default="https://picplace.test")
        p.add_argument("--storage", default="http://127.0.0.1:3900", help="object storage endpoint, for the health probe")
        p.add_argument("--picplace", default=str(DEFAULT_PICPLACE), help="the PicPlace repo (for the ledger probe and the token)")
        p.add_argument("--user", default="synth")
        p.add_argument("--token", help="a personal-access token for --user; minted with `bench.py token` when absent")
        p.add_argument("--out", help="report folder (default docs/fieldtests/<date>-sync-cost-bench)")
        p.add_argument("--edits", type=int, default=3)
        p.add_argument("--presets", help="comma list, default Cinema,Matte,Vivid,Natural")
        p.add_argument("--sim-edit", choices=["download", "preview"], default="download")
        p.add_argument("--steps", help="comma list of step names to run (default all)")
        p.add_argument("--quiet", type=int, default=45, help="seconds of log silence that end a step")
        p.add_argument("--step-timeout", type=int, default=1800)
        p.add_argument("--install-sim", action="store_true", help="install the Debug Simulator build first")
        p.add_argument("--force", action="store_true", help="run even if another LetsLapse is running on this Mac")
        p.add_argument("--device-id", help="launch the Mac copy as this device id (a scratch copy of a library as a second device)")

    p = sub.add_parser("run"); common(p); p.set_defaults(func=lambda a: Bench(a).run())
    p = sub.add_parser("libraries", help="the two-library scenario: Mac on A, Simulator on a new library B")
    common(p)
    p.add_argument("--library-name", default="synth two")
    p.add_argument("--sim-library", help="the Simulator's library A folder id, when it holds several")
    p.add_argument("--resume-b", help="carry on a stopped run from the move: library B's folder id in the Simulator")
    p.set_defaults(func=lambda a: Bench(a).run_libraries())
    p = sub.add_parser("plan"); common(p)

    def do_plan(a):
        b = Bench(a)
        steps, photos, lapses = b.plan()
        print(f"{len(photos)} photo(s), {len(lapses)} .lapse file(s) → {b.out}")
        for name, device, description, _ in steps:
            print(f"  {name:20} {device:10} {description}")
        problems = b.preflight(photos, lapses)
        print("preflight: " + ("ok" if not problems else "\n  - " + "\n  - ".join(problems)))
    p.set_defaults(func=do_plan)
    p = sub.add_parser("report"); p.add_argument("out")
    p.set_defaults(func=lambda a: print(write_report(json.loads((Path(a.out) / "run.json").read_text()), Path(a.out))))
    p = sub.add_parser("token"); p.add_argument("--user", default="synth"); p.add_argument("--picplace", default=str(DEFAULT_PICPLACE))
    p.set_defaults(func=lambda a: print(mint_token(Path(a.picplace).expanduser(), a.user)))
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
