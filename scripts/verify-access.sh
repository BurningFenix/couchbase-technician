#!/usr/bin/env bash
# Shows exactly what each technician's App Services account can pull.
# Reads credentials from .env — nothing is printed to the terminal.
#
#   ./scripts/verify-access.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "error: no .env (run: cp .env.example .env)"; exit 1; }

python3 - <<'PY'
import json, pathlib, subprocess, urllib.parse

env = {}
for line in pathlib.Path(".env").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1); env[k.strip()] = v.strip()

url  = env.get("SYNC_ENDPOINT_URL", "")
host = urllib.parse.urlparse(url).hostname
name = url.rstrip("/").split("/")[-1]
if not host:
    raise SystemExit("error: SYNC_ENDPOINT_URL missing/invalid in .env")

def changes(user, pwd, collection):
    api = f"https://{host}:4984/{name}.field.{collection}/_changes?limit=200"
    out = subprocess.run(["curl", "-sk", "-m", "15", "-u", f"{user}:{pwd}", api],
                         capture_output=True, text=True).stdout
    try:
        data = json.loads(out)
    except Exception:
        return None, out.strip()[:120]
    if "results" not in data:
        return None, data.get("reason") or data.get("error") or str(data)[:120]
    return sorted(r["id"].replace("job::", "") for r in data["results"]
                  if not r["id"].startswith("_user/")), None

techs = [("Kyle", env.get("SYNC_USERNAME_KYLE", ""), env.get("SYNC_PASSWORD_KYLE", "")),
         ("BJ",   env.get("SYNC_USERNAME_BJ", ""),   env.get("SYNC_PASSWORD_BJ", ""))]

print(f"endpoint: {host}/{name}\n")
for coll, expect in (("workOrders", "should DIFFER per tech"), ("fieldNotes", "should MATCH — shared")):
    print(f"── {coll}  ({expect})")
    seen = {}
    for label, u, p in techs:
        if not u:
            print(f"   {label:4} : no credentials in .env"); continue
        ids, err = changes(u, p, coll)
        if err or ids is None:
            print(f"   {label:4} ({u}): ERROR — {err or 'no results'}")
        else:
            seen[label] = ids
            print(f"   {label:4} ({u}): {len(ids)} doc(s)  {ids if ids else ''}")
    if coll == "workOrders" and len(seen) == 2:
        a, b = seen.values()
        if a == b and a:
            print("   ⚠️  IDENTICAL — isolation is NOT in effect. Resync the endpoint (step 4).")
        elif a and b:
            print("   ✅ isolated — each tech pulls only their own work orders.")
    print()
PY
