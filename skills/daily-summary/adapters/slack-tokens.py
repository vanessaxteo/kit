#!/usr/bin/env python3
"""Extract live Slack web-session tokens (xoxc + xoxd) from the local
Slack desktop app on macOS. Prints JSON {"token","cookie_d","team_domain"}.

No bot, no admin approval: this reuses the already-authenticated desktop
session. Tokens rotate, so this is run fresh on every adapter invocation.

Exits non-zero with a message on stderr if the session can't be read.
"""
import glob
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile

try:
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
except ImportError:
    print("slack-tokens: cryptography module missing", file=sys.stderr)
    sys.exit(3)

SLACK_DIR = os.path.expanduser("~/Library/Application Support/Slack")


def die(msg, code=1):
    print(f"slack-tokens: {msg}", file=sys.stderr)
    sys.exit(code)


def get_xoxd():
    cookies = os.path.join(SLACK_DIR, "Cookies")
    if not os.path.exists(cookies):
        die("Slack Cookies db not found (is the desktop app installed/logged in?)")
    safe_key = subprocess.check_output(
        ["security", "find-generic-password", "-s", "Slack Safe Storage", "-w"]
    ).strip()
    aes_key = hashlib.pbkdf2_hmac("sha1", safe_key, b"saltysalt", 1003, 16)
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as tf:
        tmp = tf.name
    try:
        with open(cookies, "rb") as src, open(tmp, "wb") as dst:
            dst.write(src.read())
        row = sqlite3.connect(tmp).execute(
            "SELECT encrypted_value FROM cookies WHERE name='d'"
        ).fetchone()
    finally:
        os.unlink(tmp)
    if not row:
        die("no 'd' cookie in Slack session")
    enc = row[0]
    dec = Cipher(algorithms.AES(aes_key), modes.CBC(b" " * 16),
                 backend=default_backend()).decryptor()
    pt = dec.update(enc[3:]) + dec.finalize()
    pt = pt[:-pt[-1]]  # strip PKCS7 padding
    for cand in (pt, pt[32:]):  # newer Chromium prepends 32-byte domain hash
        if cand[:5] == b"xoxd-":
            return cand.decode()
    die("could not decode xoxd cookie")


def find_xoxc_tokens():
    base = os.path.join(SLACK_DIR, "Local Storage", "leveldb")
    raw = b""
    for f in glob.glob(os.path.join(base, "*.ldb")) + glob.glob(os.path.join(base, "*.log")):
        try:
            with open(f, "rb") as fh:
                raw += fh.read()
        except OSError:
            pass
    toks = set(re.findall(rb"xoxc-[A-Za-z0-9-]{40,}", raw))
    return sorted((t.decode() for t in toks), key=len, reverse=True)


def auth_test(token, cookie_d):
    import urllib.parse
    import urllib.request
    data = urllib.parse.urlencode({"token": token}).encode()
    req = urllib.request.Request(
        "https://slack.com/api/auth.test", data=data,
        headers={"Cookie": f"d={cookie_d}",
                 "Content-Type": "application/x-www-form-urlencoded"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=15))
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}


def main():
    cookie_d = get_xoxd()
    tokens = find_xoxc_tokens()
    if not tokens:
        die("no xoxc token found in Slack local storage")
    for tok in tokens:
        res = auth_test(tok, cookie_d)
        if res.get("ok"):
            print(json.dumps({
                "token": tok,
                "cookie_d": cookie_d,
                "user": res.get("user"),
                "user_id": res.get("user_id"),
                "team": res.get("team"),
                "team_domain": (res.get("url", "").split("//")[-1].split(".")[0]),
            }))
            return
    die("no working xoxc token (session may have expired; open Slack to refresh)")


if __name__ == "__main__":
    main()
