#!/usr/bin/env python3
"""Query Slack for the current user's activity in a time window and emit the
daily-summary adapter JSON shape on stdout.

Reads token JSON (from slack-tokens.py) on stdin. Args: --since ISO [--until ISO].
Uses search.messages with the web-session token (has search:read scope).
"""
import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone


def iso_to_epoch(s):
    s = s.replace("Z", "+00:00")
    return datetime.fromisoformat(s).timestamp()


def slack_post(method, token, cookie_d, params):
    params = dict(params, token=token)
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(
        f"https://slack.com/api/{method}", data=data,
        headers={"Cookie": f"d={cookie_d}",
                 "Content-Type": "application/x-www-form-urlencoded"})
    return json.load(urllib.request.urlopen(req, timeout=30))


def search_all(query, token, cookie_d, max_pages=10):
    matches, page, total = [], 1, None
    while page <= max_pages:
        r = slack_post("search.messages", token, cookie_d,
                       {"query": query, "count": 100, "page": page, "sort": "timestamp"})
        if not r.get("ok"):
            print(f"slack-query: search error: {r.get('error')}", file=sys.stderr)
            break
        msgs = r.get("messages", {})
        total = msgs.get("total", total)
        batch = msgs.get("matches") or []
        matches.extend(batch)
        paging = msgs.get("paging") or {}
        if page >= (paging.get("pages") or 1) or not batch:
            break
        page += 1
        time.sleep(0.3)
    return matches, total


def resolve_name(cid, token, cookie_d, cache):
    """Resolve a channel/user id to a human label (cached)."""
    if not cid or cid in cache:
        return cache.get(cid, cid)
    label = cid
    if cid[0] in ("U", "W"):  # DM shows the other person's user id
        r = slack_post("users.info", token, cookie_d, {"user": cid})
        if r.get("ok"):
            u = r["user"]
            label = "@" + (u.get("profile", {}).get("display_name")
                            or u.get("name") or u.get("real_name") or cid)
    elif cid[0] in ("C", "G", "D"):
        r = slack_post("conversations.info", token, cookie_d, {"channel": cid})
        if r.get("ok"):
            c = r["channel"]
            label = "#" + c["name"] if c.get("name") else cid
    cache[cid] = label
    return label


def slim(m, token, cookie_d, cache):
    ch = m.get("channel") or {}
    cid = ch.get("id")
    is_dm = bool(ch.get("is_im") or ch.get("is_mpim"))
    if ch.get("is_im"):
        name = resolve_name(ch.get("user"), token, cookie_d, cache)
    elif ch.get("is_mpim"):
        name = ch.get("name") or cid
    elif ch.get("name"):
        name = "#" + ch["name"]
    else:
        name = resolve_name(cid, token, cookie_d, cache)
    return {
        "ts": m.get("ts"),
        "iso": datetime.fromtimestamp(float(m["ts"]), timezone.utc).isoformat().replace("+00:00", "Z")
        if m.get("ts") else None,
        "channel": name,
        "channel_id": cid,
        "is_dm": is_dm,
        "permalink": m.get("permalink"),
        "text": m.get("text"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", default=None)
    args = ap.parse_args()

    tok = json.load(sys.stdin)
    token, cookie_d = tok["token"], tok["cookie_d"]
    username = tok.get("user")

    since_e = iso_to_epoch(args.since)
    until_e = iso_to_epoch(args.until) if args.until else time.time()

    # Slack search dates are day-granular; pad by a day and filter on ts.
    after = (datetime.fromtimestamp(since_e, timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
    before = (datetime.fromtimestamp(until_e, timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d")

    sent_q = f"from:@{username} after:{after} before:{before}"
    mention_q = f"to:@{username} after:{after} before:{before}"

    sent_raw, sent_total = search_all(sent_q, token, cookie_d)
    mention_raw, mention_total = search_all(mention_q, token, cookie_d)

    def in_window(m):
        try:
            t = float(m["ts"])
        except (KeyError, TypeError, ValueError):
            return False
        return since_e <= t < until_e

    cache = {}
    sent = sorted((slim(m, token, cookie_d, cache) for m in sent_raw if in_window(m)),
                  key=lambda x: x["ts"] or "")
    mentions = sorted((slim(m, token, cookie_d, cache) for m in mention_raw if in_window(m)),
                      key=lambda x: x["ts"] or "")

    print(json.dumps({
        "source": "slack",
        "since": args.since,
        "until": args.until or datetime.fromtimestamp(until_e, timezone.utc).isoformat().replace("+00:00", "Z"),
        "user": username,
        "team": tok.get("team"),
        "messages_sent": sent,
        "messages_sent_count": len(sent),
        "mentions": mentions,
        "mentions_count": len(mentions),
    }))


if __name__ == "__main__":
    main()
