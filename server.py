#!/usr/bin/env python3
"""Public trial portal for aaa-main. Runs on 127.0.0.1:8090 (put nginx in front). Run as root.
Writes accounts in the SAME format as usernew.sh / add-ws.sh / add-vless.sh / add-tr.sh,
so they show up in (and can be deleted from) your menu."""
import hashlib, hmac, json, os, re, secrets, subprocess, threading, time, pwd, uuid as uuidlib
from datetime import datetime
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

BIND, PORT = os.environ.get("BIND", "127.0.0.1"), int(os.environ.get("PORT", 8090))
DB_FILE = os.environ.get("DB_FILE", "/var/lib/trial-portal/db.json")
XRAY_CONF = os.environ.get("XRAY_CONF", "/etc/xray/config.json")
SSH_DB = os.environ.get("SSH_DB", "/etc/ssh-accounts")
DOMAIN_FILE = os.environ.get("DOMAIN_FILE", "/etc/xray/domain")
TRIAL_HOURS = int(os.environ.get("TRIAL_HOURS", 72))  # 3 days
MAX_ACTIVE = int(os.environ.get("MAX_ACTIVE", 0))            # 0 = unlimited
PER_IP_LIMIT = int(os.environ.get("PER_IP_LIMIT", 0))          # 0 = unlimited; else trials per IP ...
IP_WINDOW_H = int(os.environ.get("IP_WINDOW_H", 72))             # ... per this many hours
DRY = os.environ.get("DRY_RUN") == "1"  # test mode: no useradd / systemctl
HERE = os.path.dirname(os.path.abspath(__file__))
lock = threading.Lock()
RATE_PER_MIN = int(os.environ.get("RATE_PER_MIN", 20))  # global anti-flood (bots); 0 = off
recent = []
L = "━" * 35

def domain():
    try: return open(DOMAIN_FILE).read().strip()
    except Exception: return ""

def load():
    try: return json.load(open(DB_FILE))
    except Exception: return {"active": {}, "ips": {}}

def save(db):
    os.makedirs(os.path.dirname(DB_FILE), mode=0o700, exist_ok=True)
    json.dump(db, open(DB_FILE, "w")); os.chmod(DB_FILE, 0o600)

def run(*a, **k):
    if DRY: return subprocess.CompletedProcess(a, 0)
    return subprocess.run(a, capture_output=True, **k)

# ---------- Xray config helpers (same layout as the add-*/del-* scripts) ----------
def read_conf(): return open(XRAY_CONF).read().split("\n")

def write_conf(lines):
    tmp = XRAY_CONF + ".tmp"
    open(tmp, "w").write("\n".join(lines))
    try: os.chmod(tmp, os.stat(XRAY_CONF).st_mode)
    except Exception: pass
    os.replace(tmp, XRAY_CONF)

def restart_xray(): run("systemctl", "restart", "xray")

def xray_exists(user):
    return re.search(r"\b" + re.escape(user) + r"\b", open(XRAY_CONF).read()) is not None

def insert_after(lines, marker, comment, entry):
    out = []
    for ln in lines:
        out.append(ln)
        if ln.rstrip().endswith(marker):
            out += [comment, entry]
    return out

def remove_account(lines, prefix):
    out, skip = [], False
    for ln in lines:
        if skip:
            if ln.startswith("},{"): skip = False
            continue
        if ln.startswith(prefix):
            skip = True; continue
        out.append(ln)
    return out

# ---------- creators: return (ok, info_text, meta) ----------
def create_ssh(user, password, exp_ts, dom, restart=True, check=True):
    day = datetime.fromtimestamp(exp_ts).strftime("%Y-%m-%d")
    r = run("useradd", "-e", day, "-s", "/bin/false", "-M", user)
    if r.returncode: return False, "", {}
    run("chpasswd", input=f"{user}:{password}", text=True)
    if not DRY:
        open(SSH_DB, "a").write(f"{user}:{password}\n"); os.chmod(SSH_DB, 0o600)
    txt = (f"{L}\nSSH Account\n{L}\nHost       : {dom}\nUsername   : {user}\nPassword   : {password}\n"
           f"Expired On : {datetime.fromtimestamp(exp_ts):%Y-%m-%d %H:%M}\n{L}\n"
           f"OpenSSH    : 22,200,500,53,666,40000,51443,58080\nSSH WS     : 80\nSSH SSL WS : 443\nSSL/TLS    : 443\nUDPGW      : 7100-7900\n{L}\n"
           f"Payload WS\nGET / HTTP/1.1[crlf]Host: {dom}[crlf]Upgrade: websocket[crlf][crlf]\n{L}\n"
           f"Payload WSS\nGET wss://isi_bug_disini HTTP/1.1[crlf]Host: {dom}[crlf]Upgrade: websocket[crlf][crlf]")
    return True, txt, {"day": day}

def create_vmess(user, _pw, exp_ts, dom, restart=True, check=True):
    day = datetime.fromtimestamp(exp_ts).strftime("%Y-%m-%d"); u = str(uuidlib.uuid4())
    if check and xray_exists(user): return False, "", {}
    lines = insert_after(read_conf(), "#vmess", f"### {user} {day}",
                         f'}},{{"id": "{u}","alterId": 0,"email": "{user}"')
    write_conf(lines)
    if restart: restart_xray()
    import base64
    def link(port, tls):
        j = json.dumps({"v": "2", "ps": user, "add": dom, "port": port, "id": u, "aid": "0", "net": "ws",
                        "path": "/vmess", "type": "none", "host": "", "tls": tls, **({"allowInsecure": "1"} if tls == "tls" else {})}, indent=2)
        return "vmess://" + base64.b64encode(j.encode()).decode()
    txt = (f"{L}\nVmess Account\n{L}\nRemarks : {user}\nDomain  : {dom}\nPort TLS: 443\nPort none TLS: 80\n"
           f"id      : {u}\nalterId : 0\nNetwork : ws\nPath    : /vmess\n{L}\nLink TLS:\n{link('443','tls')}\n{L}\n"
           f"Link none TLS:\n{link('80','none')}\n{L}\nExpired On: {day}")
    return True, txt, {"day": day, "prefix": f"### {user} {day}"}

def create_vless(user, _pw, exp_ts, dom, restart=True, check=True):
    day = datetime.fromtimestamp(exp_ts).strftime("%Y-%m-%d"); u = str(uuidlib.uuid4())
    if check and xray_exists(user): return False, "", {}
    entry = f'}},{{"id": "{u}","email": "{user}"'
    lines = insert_after(read_conf(), "#vless", f"#& {user} {day}", entry)
    lines = insert_after(lines, "#slipvless", f"#& {user} {day}", entry)  # no-op if marker absent
    write_conf(lines)
    if restart: restart_xray()
    txt = (f"{L}\nVless Account\n{L}\nRemarks : {user}\nDomain  : {dom}\nPort TLS: 443\nPort none TLS: 80\n"
           f"id      : {u}\nPath    : /vless\n{L}\nLink TLS:\nvless://{u}@{dom}:443?path=/vless&security=tls&allowInsecure=1&encryption=none&type=ws#{user}\n{L}\n"
           f"Link none TLS:\nvless://{u}@{dom}:80?path=/vless&encryption=none&type=ws#{user}\n{L}\nExpired On: {day}")
    return True, txt, {"day": day, "prefix": f"#& {user} {day}"}

def create_trojan(user, _pw, exp_ts, dom, restart=True, check=True):
    day = datetime.fromtimestamp(exp_ts).strftime("%Y-%m-%d"); u = str(uuidlib.uuid4())
    if check and xray_exists(user): return False, "", {}
    entry = f'}},{{"password": "{u}","email": "{user}"'
    lines = insert_after(read_conf(), "#trojanws", f"#! {user} {day}", entry)
    lines = insert_after(lines, "#trojangrpc", f"#! {user} {day}", entry)
    write_conf(lines)
    if restart: restart_xray()
    txt = (f"{L}\nTrojan Account\n{L}\nRemarks : {user}\nDomain  : {dom}\nPort TLS: 443\nPort none TLS: 80\n"
           f"Password: {u}\nPath    : /trojan-ws\n{L}\nLink TLS:\ntrojan://{u}@{dom}:443?path=%2Ftrojan-ws&security=tls&allowInsecure=1&host={dom}&type=ws#{user}\n{L}\n"
           f"Link none TLS:\ntrojan://{u}@{dom}:80?path=%2Ftrojan-ws&security=none&host={dom}&type=ws#{user}\n{L}\nExpired On: {day}")
    return True, txt, {"day": day, "prefix": f"#! {user} {day}"}

OVPN_PROFILE = os.environ.get("OVPN_PROFILE", "/etc/openvpn/client-tcp.ovpn")

def ovpn_text(user, password, dom):
    try: prof = open(OVPN_PROFILE).read().strip()
    except Exception: prof = "(OpenVPN is not installed on this server)"
    return (f"{L}\nOPENVPN (TCP) - same login as SSH\n{L}\nHost: {dom}\nUsername: {user}\nPassword: {password}\n"
            f"Ports: 80 (WS/Direct)  443 (WSS/SSL)\n{L}\nPayload (recommended)\n"
            f"GET / HTTP/1.1[crlf]Host: {dom}[crlf]Upgrade: websocket[crlf]X-Real-Host: 127.0.0.1:1194[crlf][crlf]\n{L}\n"
            f"Profile (paste in app):\n{prof}")

def create_ovpn(user, password, exp_ts, dom, restart=True):
    """OpenVPN logs in through PAM = the same account as SSH, so make the SSH account and show the OVPN profile."""
    ok, _t, meta = create_ssh(user, password, exp_ts, dom)
    return (True, ovpn_text(user, password, dom), meta) if ok else (False, "", {})

def create_all(user, password, exp_ts, dom):
    """SSH + OpenVPN + VMess + VLESS + Trojan in one go (single xray restart). Returns list of (proto, text, meta)."""
    out = []
    ok, txt, meta = create_ssh(user, password, exp_ts, dom)   # this same account also covers OVPN
    if not ok: return None
    out.append(("ssh", txt + "\n\n" + ovpn_text(user, password, dom), meta))
    for p, fn in (("vmess", create_vmess), ("vless", create_vless), ("trojan", create_trojan)):
        ok, txt, meta = fn(user, password, exp_ts, dom, restart=False, check=False)
        if ok: out.append((p, txt, meta))
    restart_xray()
    return out

HANDLERS = {"ssh": create_ssh, "ovpn": create_ovpn, "vmess": create_vmess, "vless": create_vless, "trojan": create_trojan}

# ---------- deletion + cleanup ----------
def delete_ssh(u):
    run("pkill", "-KILL", "-u", u); run("userdel", "-f", u)
    try:
        rows = [r for r in open(SSH_DB).read().split("\n") if r and not r.startswith(u + ":")]
        open(SSH_DB, "w").write("\n".join(rows) + ("\n" if rows else ""))
    except Exception: pass

def drop(db, key):
    """Delete one account. Returns True if the xray config changed (caller restarts xray once)."""
    meta = db["active"].pop(key)
    if meta["proto"] in ("ssh", "ovpn"):
        delete_ssh(meta["user"]); return False
    write_conf(remove_account(read_conf(), meta["prefix"])); return True

def expire(db, now):
    changed = False
    for key, meta in list(db["active"].items()):
        if meta["exp"] <= now: changed |= drop(db, key)
    return changed

def cleanup_loop():
    while True:
        time.sleep(60)
        with lock:
            db = load(); now = time.time()
            if expire(db, now): restart_xray()
            for ip, ts in list(db["ips"].items()):
                db["ips"][ip] = [t for t in ts if t > now - IP_WINDOW_H * 3600]
                if not db["ips"][ip]: del db["ips"][ip]
            save(db)

# ---------- HTTP ----------
def sha(t): return hashlib.sha256(t.encode()).hexdigest()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def ip(self):
        c = self.client_address[0]
        return self.headers.get("X-Forwarded-For", c).split(",")[0].strip() if c == "127.0.0.1" else c
    def token(self):
        m = re.search(r"(?:^|;\s*)tp_owner=([A-Za-z0-9_-]{20,64})", self.headers.get("Cookie", ""))
        return m.group(1) if m else None
    def send(self, code, body, ctype="application/json", headers=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store"); self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def err(self, code, msg): self.send(code, json.dumps({"error": msg}))
    def body(self):
        if not self.headers.get("Content-Type", "").startswith("application/json"): return None
        try: return json.loads(self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 2048)))
        except Exception: return None

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/mine":       # only the browser that created the account (cookie) can see it
            tok = self.token(); items = {}
            if tok:
                with lock:
                    for m in load()["active"].values():
                        if hmac.compare_digest(m.get("owner", ""), sha(tok)):
                            it = items.setdefault(m["user"], {"user": m["user"], "texts": [],
                                 "expires": datetime.fromtimestamp(m["exp"]).strftime("%Y-%m-%d %H:%M")})
                            it["texts"].append(m["text"])
            return self.send(200, json.dumps([{"user": i["user"], "expires": i["expires"], "text": "\n\n".join(i["texts"])} for i in items.values()]))
        if path == "/": return self.send(200, open(os.path.join(HERE, "panel.html"), "rb").read(), "text/html; charset=utf-8")
        self.err(404, "Not found")

    def do_POST(self):
        req = self.body()
        if req is None: return self.err(400, "Bad request")
        if self.path == "/api/delete": return self.delete(req)
        if self.path != "/api/trial": return self.err(404, "Not found")
        if req.get("website"): return self.err(400, "Rejected")  # honeypot
        proto = req.get("protocol", "all"); name = str(req.get("username", "")).lower()
        if proto not in HANDLERS and proto != "all": return self.err(400, "Protocol not available")
        if not re.fullmatch(r"[a-z][a-z0-9]{2,11}", name):
            return self.err(400, "Username: 3-12 letters/numbers, start with a letter")
        user = "trial_" + name; ip = self.ip()
        tok = self.token() or secrets.token_urlsafe(24); oh = sha(tok)
        with lock:
            db = load(); now = time.time()
            recent[:] = [t for t in recent if t > now - 60]
            if RATE_PER_MIN and len(recent) >= RATE_PER_MIN: return self.err(429, "Too many requests right now. Try again in a minute.")
            if PER_IP_LIMIT and len([t for t in db["ips"].get(ip, []) if t > now - IP_WINDOW_H * 3600]) >= PER_IP_LIMIT:
                return self.err(429, f"Limit reached: {PER_IP_LIMIT} trial per {IP_WINDOW_H // 24} days.")
            if MAX_ACTIVE and len(db["active"]) >= MAX_ACTIVE: return self.err(503, "Trial slots are full. Try again later.")
            if any(m["user"] == user for m in db["active"].values()): return self.err(409, "Username taken")
            try: pwd.getpwnam(user); return self.err(409, "Username taken")
            except KeyError: pass
            exp = now + TRIAL_HOURS * 3600
            dom = domain() or self.headers.get("Host", "").split(":")[0]; pw = secrets.token_urlsafe(6)
            if proto == "all":
                if xray_exists(user): return self.err(409, "Username taken")
                res = create_all(user, pw, exp, dom)
                if not res: return self.err(500, "Could not create account")
                entries = res
            else:
                ok, txt, meta = HANDLERS[proto](user, pw, exp, dom)
                if not ok: return self.err(409, "Could not create account (name taken?)")
                entries = [(proto, txt, meta)]
            for p, t, meta in entries:
                db["active"][f"{user}|{p}"] = {"exp": exp, "proto": p, "user": user, "owner": oh, "text": t, **meta}
            db["ips"].setdefault(ip, []).append(now); recent.append(now); save(db)
        secure = "; Secure" if self.headers.get("X-Forwarded-Proto") == "https" else ""
        ck = f"tp_owner={tok}; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict{secure}"
        self.send(200, json.dumps({"ok": True}), headers=[("Set-Cookie", ck)])

    def delete(self, req):
        tok = self.token(); user = str(req.get("user", ""))
        if not tok: return self.err(403, "Not your account")
        with lock:
            db = load()
            keys = [k for k, m in db["active"].items() if m["user"] == user and hmac.compare_digest(m.get("owner", ""), sha(tok))]
            if not keys: return self.err(404, "Account not found")
            changed = False
            for k in keys: changed |= drop(db, k)
            save(db)
            if changed: restart_xray()
        self.send(200, json.dumps({"ok": True}))

if __name__ == "__main__":
    threading.Thread(target=cleanup_loop, daemon=True).start()
    ThreadingHTTPServer((BIND, PORT), H).serve_forever()
