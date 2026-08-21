#!/bin/bash
# NetSpeed triage — answers "was it the router, the PowerBeam, or the cable?"
#   ./triage.sh              last 2 hours
#   ./triage.sh 19:00 20:00  a specific window (today)
#   ./triage.sh 2026-08-21   a whole past day
set -uo pipefail
L="$HOME/Library/Application Support/NetSpeed"
python3 - "$@" <<'PY'
import csv, sys, os, statistics as st
from datetime import datetime, timedelta
L = os.path.expanduser("~/Library/Application Support/NetSpeed")
a = sys.argv[1:]
day = datetime.now().strftime("%Y-%m-%d"); lo = hi = None
if len(a) == 1 and "-" in a[0]: day = a[0]
elif len(a) == 2: lo, hi = f"{day} {a[0]}:00", f"{day} {a[1]}:00"
else:
    t = datetime.now() - timedelta(hours=2)
    lo, hi = t.strftime("%Y-%m-%d %H:%M:%S"), "9999"
f = f"{L}/netlog-{day}.csv"
if not os.path.exists(f): sys.exit(f"no log for {day}")
rows = [r for r in csv.DictReader(open(f)) if (lo is None or lo <= r["time"] <= hi)]
if not rows: sys.exit("no samples in that window")
num = lambda v: float(v) if v not in ("", None) else None
def q(vals, p):
    vals = sorted(v for v in vals if v is not None)
    return vals[min(int(len(vals)*p), len(vals)-1)] if vals else None
def line(name, key, unit="ms"):
    v = [num(r[key]) for r in rows]
    ok = [x for x in v if x is not None]
    if not ok: return f"  {name:<26} no data"
    miss = len(v) - len(ok)
    return (f"  {name:<26} p50 {q(ok,.5):7.1f}  p95 {q(ok,.95):7.1f}  "
            f"max {max(ok):7.1f} {unit}  drops {miss}")
print(f"window {rows[0]['time']} -> {rows[-1]['time']}   ({len(rows)} samples)\n")
print("LATENCY BY HOP  (each line adds one more piece of the path)")
print(line("1 cable+switch+router", "gw_ms"))
print(line("2 +router->radio", "pb_ms"))
print(line("3 +radio link+ISP", "inet_ms"))
gw, inet = [num(r["gw_ms"]) for r in rows], [num(r["inet_ms"]) for r in rows]
g95, i95 = q(gw,.95), q(inet,.95)
print("\nVERDICT")
if g95 and g95 > 10: print(f"  ✗ LAN side: gateway p95 {g95:.1f} ms — cable, port or router")
elif g95: print(f"  ✓ LAN side clean: gateway p95 {g95:.1f} ms")
rs = [num(r["rssi"]) for r in rows]; amc = [num(r["amc"]) for r in rows]
if i95 and g95 and i95 - g95 > 40:
    worst = q(amc,.05)
    extra = f" (airMAX capacity dipped to {worst:.0f}%)" if worst is not None else ""
    print(f"  ✗ Upstream: internet p95 {i95:.1f} ms vs {g95:.1f} local{extra}")
elif i95: print(f"  ✓ Upstream ok: internet p95 {i95:.1f} ms")
ie = [num(r["ierrs"]) for r in rows]; oe = [num(r["oerrs"]) for r in rows]
ie = [x for x in ie if x is not None]; oe = [x for x in oe if x is not None]
if ie and (ie[-1]-ie[0] or oe[-1]-oe[0]):
    print(f"  ✗ CABLE: {int(ie[-1]-ie[0])} in / {int(oe[-1]-oe[0])} out errors appeared")
elif ie: print("  ✓ Cable clean: zero interface errors")
sp = {int(x) for x in (num(r["link_mbit"]) for r in rows) if x}
if len(sp) > 1: print(f"  ✗ CABLE: link speed changed {sorted(sp)} Mb — renegotiation")
if rs and any(x is not None for x in rs):
    print(f"\nRADIO   signal p50 {q(rs,.5):.0f} dBm (worst {min(x for x in rs if x is not None):.0f})"
          f"   airMAX capacity p50 {q(amc,.5):.0f}%")
cpu = [num(r["cpu_pct"]) for r in rows]
if cpu and any(x is not None for x in cpu):
    print(f"MAC     cpu p95 {q(cpu,.95):.0f}%   (high cpu with clean gateway ping = not the network)")
ev = f"{L}/events.csv"
if os.path.exists(ev):
    e = [r for r in csv.DictReader(open(ev)) if (lo is None or lo <= r["time"] <= hi) and r["time"][:10] == day]
    if e:
        print("\nEVENTS")
        for r in e[-12:]: print(f"  {r['time'][11:]}  {r['event']:<20} {r['detail']}")
PY
