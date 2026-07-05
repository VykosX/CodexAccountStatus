#!/usr/bin/env bash
set -euo pipefail

python_bin="${PYTHON:-}"
if [ -z "$python_bin" ]; then
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1 && python -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    python_bin="python"
  else
    python_bin="python3"
  fi
fi
if ! command -v "$python_bin" >/dev/null 2>&1 || ! "$python_bin" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
  echo "Python 3 is required. Set PYTHON=/path/to/python3 or install python3." >&2
  exit 1
fi

mkdir -p ./.codex-cache
tmp_py="./.codex-cache/codex-account-status-$$.py"
trap 'rm -f "$tmp_py"' EXIT INT TERM
cat > "$tmp_py" <<'PY'
import argparse
import base64
import datetime as _dt
import gzip
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

TEMPLATE_B64 = """
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
"""

API_BASE = "https://chatgpt.com"
USER_AGENT = "CodexAccountStatus.sh/1.0"


def local_stamp(value=None):
    if value is None:
        dt = _dt.datetime.now().astimezone()
    elif isinstance(value, (int, float)):
        dt = _dt.datetime.fromtimestamp(value, _dt.timezone.utc).astimezone()
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.isdigit():
            dt = _dt.datetime.fromtimestamp(int(text), _dt.timezone.utc).astimezone()
        else:
            text = text.replace("Z", "+00:00")
            dt = _dt.datetime.fromisoformat(text).astimezone()
    else:
        dt = value.astimezone()
    return dt.strftime("%Y-%m-%d • %H:%M:%S")


def json_load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def json_dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, separators=(",", ":"))
    tmp.replace(path)


def b64url_decode(value):
    value = value.replace("-", "+").replace("_", "/")
    value += "=" * ((4 - len(value) % 4) % 4)
    return base64.b64decode(value)


def decode_jwt_payload(token):
    parts = token.split(".")
    if len(parts) < 2:
        raise RuntimeError("Token is not a JWT.")
    return json.loads(b64url_decode(parts[1]).decode("utf-8"))


def first_non_empty(*values):
    for value in values:
        if value is not None and str(value).strip() != "":
            return value
    return None


def safe_stem(value):
    value = re.sub(r"[^a-z0-9._-]+", "-", str(value).lower()).strip(".-")
    return (value or "account")[:96].strip(".-") or "account"


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


def default_auth_path():
    return codex_home() / "auth.json"


def auth_info(auth_path):
    auth = json_load(auth_path)
    tokens = auth.get("tokens") or {}
    access = tokens.get("access_token") or os.environ.get("CODEX_ACCESS_TOKEN")
    if not access:
        raise RuntimeError(f"Missing access_token in {auth_path}. Run `codex login`, or use file credential storage at {default_auth_path()}.")
    id_token = tokens.get("id_token")
    access_payload = decode_jwt_payload(access)
    id_payload = decode_jwt_payload(id_token) if id_token else {}
    access_auth = access_payload.get("https://api.openai.com/auth") or {}
    id_auth = id_payload.get("https://api.openai.com/auth") or {}
    profile = access_payload.get("https://api.openai.com/profile") or {}
    account_id = first_non_empty(tokens.get("account_id"), access_auth.get("chatgpt_account_id"), id_auth.get("chatgpt_account_id"))
    if not account_id:
        raise RuntimeError(f"Could not determine account id in {auth_path}.")
    return {
        "accessToken": access,
        "accountId": account_id,
        "email": first_non_empty(profile.get("email"), id_payload.get("email")),
        "name": id_payload.get("name"),
        "plan": first_non_empty(access_auth.get("chatgpt_plan_type"), id_auth.get("chatgpt_plan_type")),
        "accessTokenExpiresAt": local_stamp(access_payload.get("exp")) if access_payload.get("exp") else None,
    }


def api_get(info, path):
    url = API_BASE + path
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {info['accessToken']}")
    req.add_header("ChatGPT-Account-ID", info["accountId"])
    req.add_header("OpenAI-Beta", "codex-1")
    req.add_header("originator", "Codex Desktop")
    req.add_header("User-Agent", USER_AGENT)
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw) if raw else None


def proxy_get(info, path_and_query):
    value = api_get(info, path_and_query)
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def usage_window(item):
    used = item.get("used_percent") if isinstance(item, dict) else None
    remaining = item.get("remaining_percent") if isinstance(item, dict) else None
    if remaining is None and used is not None:
        remaining = max(0, 100 - float(used))
    if used is None and remaining is not None:
        used = max(0, 100 - float(remaining))
    reset_at = first_non_empty(item.get("reset_at"), item.get("resets_at"), item.get("resetAt"))
    return {
        "kind": item.get("kind"),
        "label": first_non_empty(item.get("label"), item.get("window"), item.get("name")),
        "usedPercent": used,
        "remainingPercent": remaining,
        "limitWindowSeconds": item.get("limit_window_seconds"),
        "resetAfterSeconds": item.get("reset_after_seconds"),
        "resetAt": local_stamp(reset_at) if reset_at else None,
    }


def normalize_usage(raw):
    windows = raw.get("windows") or raw.get("rate_limits") or []
    return {
        "allowed": raw.get("allowed"),
        "limitReached": raw.get("limit_reached"),
        "rateLimitReachedType": raw.get("rate_limit_reached_type"),
        "windows": [usage_window(w) for w in windows if isinstance(w, dict)],
        "credits": raw.get("credits") or {},
        "spendControl": raw.get("spend_control") or {},
        "rateLimitResetCredits": raw.get("rate_limit_reset_credits") or {},
    }


def normalize_profile(raw):
    stats = raw.get("stats") or raw
    daily = stats.get("daily_usage_buckets") or stats.get("dailyUsageBuckets") or []
    return {
        "username": stats.get("username"),
        "displayName": first_non_empty(stats.get("display_name"), stats.get("displayName")),
        "statsAsOf": stats.get("stats_as_of") or stats.get("statsAsOf"),
        "generatedAt": local_stamp(first_non_empty(stats.get("generated_at"), stats.get("generatedAt"))) if first_non_empty(stats.get("generated_at"), stats.get("generatedAt")) else None,
        "lifetimeTokens": stats.get("lifetime_tokens") or stats.get("lifetimeTokens") or 0,
        "peakDailyTokens": stats.get("peak_daily_tokens") or stats.get("peakDailyTokens") or 0,
        "currentStreakDays": stats.get("current_streak_days") or stats.get("currentStreakDays") or 0,
        "longestStreakDays": stats.get("longest_streak_days") or stats.get("longestStreakDays") or 0,
        "totalThreads": stats.get("total_threads") or stats.get("totalThreads") or 0,
        "longestRunningTurnSec": stats.get("longest_running_turn_sec") or stats.get("longestRunningTurnSec") or 0,
        "fastModeUsagePercentage": stats.get("fast_mode_usage_percentage") or stats.get("fastModeUsagePercentage") or 0,
        "mostUsedReasoningEffort": stats.get("most_used_reasoning_effort") or stats.get("mostUsedReasoningEffort"),
        "mostUsedReasoningEffortPercentage": stats.get("most_used_reasoning_effort_percentage") or stats.get("mostUsedReasoningEffortPercentage") or 0,
        "dailyUsageBuckets": [{"date": d.get("date"), "tokens": d.get("tokens") or d.get("text_total_tokens") or 0} for d in daily if isinstance(d, dict)],
    }


def normalize_reset_credits(raw):
    credits = raw.get("credits") if isinstance(raw, dict) else raw
    credits = credits or []
    rows = []
    for c in credits:
        if not isinstance(c, dict):
            continue
        rows.append({
            "id": c.get("id"),
            "resetType": c.get("reset_type") or c.get("resetType"),
            "status": c.get("status"),
            "grantedAt": local_stamp(c.get("granted_at") or c.get("grantedAt")) if (c.get("granted_at") or c.get("grantedAt")) else None,
            "expiresAt": local_stamp(c.get("expires_at") or c.get("expiresAt")) if (c.get("expires_at") or c.get("expiresAt")) else None,
            "title": c.get("title"),
            "description": c.get("description"),
        })
    available = sum(1 for c in rows if str(c.get("status")).lower() == "available")
    return {"availableCount": available, "credits": rows}


def analytics_usage(info):
    end = _dt.date.today() + _dt.timedelta(days=1)
    start = end - _dt.timedelta(days=30)
    path = f"/backend-api/wham/analytics/daily-workspace-usage-counts?start_date={start.isoformat()}&end_date={end.isoformat()}&group_by=day"
    raw = api_get(info, path)
    rows_raw = raw.get("data") if isinstance(raw, dict) else raw
    rows_raw = rows_raw or []
    rows = []
    model_totals = {}
    surface_totals = {}
    totals = {"users":0,"threads":0,"turns":0,"credits":0,"uncachedTextInputTokens":0,"cachedTextInputTokens":0,"textOutputTokens":0,"textTotalTokens":0}
    for row in rows_raw:
        if not isinstance(row, dict):
            continue
        clients = row.get("clients") or []
        models = row.get("models") or []
        def num(*names):
            for n in names:
                if row.get(n) is not None:
                    try: return float(row.get(n) or 0)
                    except Exception: return 0
            return 0
        normalized = {
            "date": row.get("date"),
            "users": num("users"),
            "threads": num("threads"),
            "turns": num("turns"),
            "credits": num("credits"),
            "uncachedTextInputTokens": num("uncached_text_input_tokens", "uncachedTextInputTokens"),
            "cachedTextInputTokens": num("cached_text_input_tokens", "cachedTextInputTokens"),
            "textOutputTokens": num("text_output_tokens", "textOutputTokens"),
            "tokens": num("text_total_tokens", "tokens", "textTotalTokens"),
            "clients": clients,
            "models": models,
        }
        rows.append(normalized)
        totals["users"] += normalized["users"]
        totals["threads"] += normalized["threads"]
        totals["turns"] += normalized["turns"]
        totals["credits"] += normalized["credits"]
        totals["uncachedTextInputTokens"] += normalized["uncachedTextInputTokens"]
        totals["cachedTextInputTokens"] += normalized["cachedTextInputTokens"]
        totals["textOutputTokens"] += normalized["textOutputTokens"]
        totals["textTotalTokens"] += normalized["tokens"]
        for m in models:
            name = m.get("model") or m.get("name") or "Unknown"
            item = model_totals.setdefault(name, {"name":name,"users":0,"threads":0,"turns":0,"credits":0,"tokens":0})
            for k in ("users","threads","turns","credits"):
                item[k] += float(m.get(k) or 0)
        for c in clients:
            name = c.get("client_id") or c.get("name") or "Unknown"
            item = surface_totals.setdefault(name, {"name":name,"users":0,"threads":0,"turns":0,"credits":0,"tokens":0})
            item["users"] += float(c.get("users") or 0)
            item["threads"] += float(c.get("threads") or 0)
            item["turns"] += float(c.get("turns") or 0)
            item["credits"] += float(c.get("credits") or 0)
            item["tokens"] += float(c.get("text_total_tokens") or c.get("tokens") or 0)
    return {
        "fetchedAt": local_stamp(), "path": path, "groupBy":"day", "rows": rows,
        "dailyUsageBuckets": rows,
        "modelBreakdown": sorted(model_totals.values(), key=lambda x: (-x["turns"], x["name"])),
        "surfaceBreakdown": sorted(surface_totals.values(), key=lambda x: (-x["turns"], x["name"])),
        "totals": totals, "error": None,
    }


def history_path(cache_dir, account):
    ident = first_non_empty(account.get("email"), account.get("name"), account.get("accountId")) or "account"
    aid = str(account.get("accountId") or "")
    if not aid:
        return None
    return cache_dir / "history" / f"{safe_stem(ident + '-' + aid[:8])}.history.json"


def sample_from(account):
    profile = account.get("profileStats") or {}
    usage = account.get("usageStatus") or {}
    windows = usage.get("windows") or []
    primary = windows[0] if len(windows) > 0 else {}
    secondary = windows[1] if len(windows) > 1 else {}
    return {
        "at": local_stamp(),
        "availableResetCredits": account.get("availableCount") or 0,
        "lifetimeTokens": profile.get("lifetimeTokens") or 0,
        "totalThreads": profile.get("totalThreads") or 0,
        "primaryUsedPercent": primary.get("usedPercent"),
        "secondaryUsedPercent": secondary.get("usedPercent"),
        "primaryResetAt": primary.get("resetAt"),
        "secondaryResetAt": secondary.get("resetAt"),
        "mostUsedReasoningEffort": profile.get("mostUsedReasoningEffort"),
        "surface": "Local proxy",
        "model": "Unknown",
    }


def update_history(cache_dir, account, analytics=None):
    path = history_path(cache_dir, account)
    if not path:
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        try: hist = json_load(path)
        except Exception: hist = {}
    else:
        hist = {}
    hist.setdefault("accountId", account.get("accountId"))
    hist.setdefault("email", account.get("email"))
    hist.setdefault("createdAt", local_stamp())
    hist["updatedAt"] = local_stamp()
    samples = hist.setdefault("samples", [])
    s = sample_from(account)
    if not samples or samples[-1] != s:
        samples.append(s)
    hist.setdefault("sessions", [])
    if analytics:
        hist["analytics"] = analytics
        hist["dailyUsageBuckets"] = analytics.get("dailyUsageBuckets") or []
        hist["modelBreakdown"] = analytics.get("modelBreakdown") or []
        hist["surfaceBreakdown"] = analytics.get("surfaceBreakdown") or []
    elif account.get("profileStats"):
        hist.setdefault("dailyUsageBuckets", account["profileStats"].get("dailyUsageBuckets") or [])
        hist.setdefault("modelBreakdown", [])
        hist.setdefault("surfaceBreakdown", [])
    json_dump(path, hist)
    return hist


def live_snapshot(args):
    info = auth_info(args.auth_path)
    record = {
        "email": info.get("email"), "name": info.get("name"), "plan": info.get("plan"),
        "accountId": info["accountId"], "tokenSource": str(args.auth_path),
        "dataSource": "live Codex auth", "isLive": True, "lastPolledAt": local_stamp(),
        "accessTokenExpiresAt": info.get("accessTokenExpiresAt"), "availableCount": 0,
        "credits": [], "usageStatus": None, "profileStats": None,
        "resetCreditsError": None, "usageError": None, "profileError": None, "error": None,
    }
    analytics = None
    try:
        credits = normalize_reset_credits(api_get(info, "/backend-api/wham/rate-limit-reset-credits"))
        record["availableCount"] = credits["availableCount"]
        record["credits"] = credits["credits"]
    except Exception as e:
        record["resetCreditsError"] = str(e)
    try:
        record["usageStatus"] = normalize_usage(api_get(info, "/backend-api/wham/usage"))
    except Exception as e:
        record["usageError"] = str(e)
    try:
        record["profileStats"] = normalize_profile(api_get(info, "/backend-api/wham/profiles/me"))
        if not record.get("name"):
            record["name"] = record["profileStats"].get("displayName")
    except Exception as e:
        record["profileError"] = str(e)
    try:
        analytics = analytics_usage(info)
    except Exception as e:
        analytics = {"fetchedAt": local_stamp(), "error": str(e), "rows": [], "dailyUsageBuckets": []}
    hist = update_history(args.cache_dir, record, analytics)
    if hist:
        record["history"] = hist
    ident = first_non_empty(record.get("email"), record.get("name"), record.get("accountId"))
    snap_path = args.cache_dir / f"{safe_stem(ident + '-' + record['accountId'][:8])}.snapshot.json"
    cache_record = dict(record)
    cache_record["isLive"] = False
    cache_record["dataSource"] = "cached snapshot from last successful live poll"
    json_dump(snap_path, cache_record)
    return record


def cached_snapshot(args):
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    accounts = []
    live_account = None
    try:
        live_account = auth_info(args.auth_path).get("accountId")
    except Exception:
        pass
    for path in sorted(args.cache_dir.glob("*.snapshot.json")):
        try:
            acct = json_load(path)
        except Exception:
            continue
        if not acct.get("accountId"):
            continue
        acct["isLive"] = bool(live_account and acct.get("accountId") == live_account)
        acct["dataSource"] = "cached snapshot for active account" if acct["isLive"] else f"cached snapshot from {path.name}"
        hp = history_path(args.cache_dir, acct)
        if hp and hp.exists():
            try: acct["history"] = json_load(hp)
            except Exception: pass
        accounts.append(acct)
    total = sum(int(a.get("availableCount") or 0) for a in accounts)
    return {
        "generatedAt": local_stamp(), "timeZone": time.tzname[0] if time.tzname else "local",
        "source": "Live data for the active Codex auth account plus cached snapshots for other accounts.",
        "accountsDir": str(args.cache_dir), "totalAvailable": total,
        "accounts": sorted(accounts, key=lambda a: (not a.get("isLive"), str(a.get("email") or ""), str(a.get("accountId") or ""))),
    }


def live_auth(args):
    try: aid = auth_info(args.auth_path).get("accountId")
    except Exception: aid = None
    return {"accountId": aid, "apiBase": f"http://127.0.0.1:{args.port}"}


def template_html():
    return gzip.decompress(base64.b64decode(TEMPLATE_B64)).decode("utf-8")


def write_html(args):
    args.root.mkdir(parents=True, exist_ok=True)
    html_text = template_html()
    html_text = html_text.replace("__RESET_DATA_JSON__", json.dumps(cached_snapshot(args), ensure_ascii=False, separators=(",", ":")))
    html_text = html_text.replace("__LIVE_AUTH_JSON__", json.dumps(live_auth(args), ensure_ascii=False, separators=(",", ":")))
    (args.root / "index.html").write_text(html_text, encoding="utf-8")


def ensure_generated(args, force=False):
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    (args.cache_dir / "history").mkdir(parents=True, exist_ok=True)
    if force or not list(args.cache_dir.glob("*.snapshot.json")):
        print("Refreshing live Codex account data...", flush=True)
        try:
            live_snapshot(args)
        except Exception as e:
            print(f"Warning: could not refresh live account data: {e}", file=sys.stderr, flush=True)
    write_html(args)
    print(f"Wrote {args.root / 'index.html'}", flush=True)


def open_browser(url):
    opener = "open" if sys.platform == "darwin" else "xdg-open"
    if not shutil.which(opener):
        return
    try:
        subprocess.Popen([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, ctype, body):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "authorization,content-type")
        self.send_header("Access-Control-Allow-Methods", "GET,OPTIONS")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204, "text/plain; charset=utf-8", "")

    def do_GET(self):
        args = self.server.args
        parsed = urllib.parse.urlsplit(self.path)
        try:
            if parsed.path in ("/", "/index.html"):
                if not (args.root / "index.html").exists():
                    ensure_generated(args)
                html_text = (args.root / "index.html").read_text(encoding="utf-8")
                html_text = re.sub(r'<script id="reset-data" type="application/json">.*?</script>', f'<script id="reset-data" type="application/json">{json.dumps(cached_snapshot(args), ensure_ascii=False, separators=(",", ":"))}</script>', html_text, flags=re.S)
                html_text = re.sub(r'<script id="live-auth" type="application/json">.*?</script>', f'<script id="live-auth" type="application/json">{json.dumps(live_auth(args), ensure_ascii=False, separators=(",", ":"))}</script>', html_text, flags=re.S)
                self._send(200, "text/html; charset=utf-8", html_text)
                return
            if parsed.path == "/codex-resets/live":
                self._send(200, "application/json; charset=utf-8", json.dumps(live_snapshot(args), ensure_ascii=False, separators=(",", ":")))
                return
            if parsed.path.startswith("/backend-api/wham/"):
                info = auth_info(args.auth_path)
                self._send(200, "application/json; charset=utf-8", proxy_get(info, parsed.path + (("?" + parsed.query) if parsed.query else "")))
                return
            self._send(404, "application/json; charset=utf-8", json.dumps({"error": f"Unknown path: {parsed.path}"}))
        except Exception as e:
            self._send(500, "application/json; charset=utf-8", json.dumps({"error": str(e)}))

    def log_message(self, fmt, *args):
        return


def parse_args(argv):
    aliases = {
        "-Port": "--port",
        "-AuthPath": "--auth-path",
        "-Root": "--root",
        "-CacheDir": "--cache-dir",
        "-Update": "-Update",
        "-SkipBrowser": "-SkipBrowser",
    }
    argv = [aliases.get(arg, arg) for arg in argv]
    p = argparse.ArgumentParser(description="Codex reset credits dashboard")
    p.add_argument("-Port", "--port", dest="port", type=int, default=8787)
    p.add_argument("-AuthPath", "--auth-path", dest="auth_path", default=str(default_auth_path()))
    p.add_argument("-Root", "--root", dest="root", default=str(Path.cwd()))
    p.add_argument("-CacheDir", "--cache-dir", dest="cache_dir", default=None)
    p.add_argument("-Update", dest="update", action="store_true")
    p.add_argument("-SkipBrowser", dest="skip_browser", action="store_true")
    args = p.parse_args(argv)
    args.root = Path(args.root).expanduser().resolve()
    args.cache_dir = Path(args.cache_dir).expanduser().resolve() if args.cache_dir else args.root / ".codex-cache"
    args.auth_path = Path(args.auth_path).expanduser().resolve()
    return args


def main(argv):
    args = parse_args(argv)
    ensure_generated(args, force=args.update)
    if args.update:
        return 0
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.args = args
    url = f"http://127.0.0.1:{args.port}/index.html"
    print(f"Codex Resets server running at http://127.0.0.1:{args.port}/", flush=True)
    print(f"Open {url}", flush=True)
    print("Press Ctrl+C to stop.", flush=True)
    if not args.skip_browser:
        open_browser(url)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
PY
"$python_bin" "$tmp_py" "$@"

