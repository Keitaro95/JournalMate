# /// script
# requires-python = ">=3.10"
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""App Store Connect API で、審査に出すまでを進める。

    uv run .claude/skills/app-store-release/scripts/asc.py status
    uv run .claude/skills/app-store-release/scripts/asc.py prepare 1.0.2 4 --whats-new ja=whats-new-ja.txt
    uv run .claude/skills/app-store-release/scripts/asc.py submit 1.0.2

キーの ID などは ~/.appstoreconnect/journalmate.env から読む（リポジトリには入れない）。
審査メモは submission.md の「#### 英語」のコードブロックをそのまま使う。
"""
import argparse
import os
import re
import sys
import time
from pathlib import Path

import jwt
import requests

ROOT = Path(__file__).resolve().parents[4]
BASE = "https://api.appstoreconnect.apple.com"
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"}


def load_env() -> dict[str, str]:
    env = {}
    path = Path.home() / ".appstoreconnect/journalmate.env"
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return {**env, **{k: v for k, v in os.environ.items() if k.startswith("ASC_")}}


ENV = load_env()
APP = ENV["ASC_APP_ID"]
KEY = (Path.home() / f".appstoreconnect/private_keys/AuthKey_{ENV['ASC_KEY_ID']}.p8").read_text()


def token() -> str:
    now = int(time.time())
    claims = {"iss": ENV["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    return jwt.encode(claims, KEY, algorithm="ES256", headers={"kid": ENV["ASC_KEY_ID"]})


def api(method: str, path: str, body=None, params=None) -> dict:
    r = requests.request(method, BASE + path, json=body, params=params,
                         headers={"Authorization": "Bearer " + token()})
    if r.status_code >= 400:
        sys.exit(f"{method} {path} → {r.status_code}\n{r.text[:2000]}")
    return r.json() if r.text else {}


def find_version(version: str) -> dict | None:
    r = api("GET", f"/v1/apps/{APP}/appStoreVersions",
            params={"filter[versionString]": version, "filter[platform]": "IOS"})
    return r["data"][0] if r["data"] else None


def find_build(version: str, build: str) -> dict:
    r = api("GET", "/v1/builds", params={
        "filter[app]": APP, "filter[version]": build,
        "filter[preReleaseVersion.version]": version, "filter[preReleaseVersion.platform]": "IOS"})
    if not r["data"]:
        sys.exit(f"ビルド {version} ({build}) が見つかりません。アップロード直後なら数分待ってください。")
    b = r["data"][0]
    state = b["attributes"]["processingState"]
    if state != "VALID":
        sys.exit(f"ビルド {version} ({build}) はまだ {state} です。VALID になるまで待ってください。")
    return b


def review_notes() -> str:
    text = (ROOT / "submission.md").read_text(encoding="utf-8")
    m = re.search(r"#### 英語\n\n```\n(.*?)\n```", text, re.S)
    if not m:
        sys.exit("submission.md に「#### 英語」の審査メモが見つかりません。")
    return m.group(1)


def status(_):
    r = api("GET", "/v1/builds", params={"filter[app]": APP, "include": "preReleaseVersion",
                                         "sort": "-uploadedDate", "limit": 5})
    pre = {i["id"]: i["attributes"]["version"] for i in r.get("included", [])}
    print("ビルド（新しい順）")
    for b in r["data"]:
        a = b["attributes"]
        v = pre.get(b["relationships"]["preReleaseVersion"]["data"]["id"])
        print(f"  {v} ({a['version']})  {a['processingState']}{'  期限切れ' if a['expired'] else ''}")
    print("App Store のバージョン")
    for v in api("GET", f"/v1/apps/{APP}/appStoreVersions", params={"limit": 5})["data"]:
        a = v["attributes"]
        print(f"  {a['versionString']}  {a['appStoreState']}  {a['releaseType']}")
    print("審査の提出")
    for s in api("GET", "/v1/reviewSubmissions", params={"filter[app]": APP, "limit": 5})["data"]:
        a = s["attributes"]
        print(f"  {a.get('submittedDate') or '-'}  {a['state']}")


def prepare(args):
    build = find_build(args.version, args.build)
    v = find_version(args.version)
    if v is None:
        v = api("POST", "/v1/appStoreVersions", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": args.version, "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
        print(f"バージョン {args.version} を作りました")
    elif v["attributes"]["appStoreState"] not in EDITABLE:
        sys.exit(f"{args.version} は {v['attributes']['appStoreState']} なので直せません。")
    vid = v["id"]

    api("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build",
        {"data": {"type": "builds", "id": build["id"]}})
    print(f"ビルド {args.build} を紐づけました")

    locs = {l["attributes"]["locale"]: l["id"] for l in
            api("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]}
    given = dict(w.split("=", 1) for w in args.whats_new)
    for locale, lid in locs.items():
        if locale not in given:
            sys.exit(f"ストアに {locale} があるのに、その新機能の文が渡されていません（--whats-new {locale}=ファイル）。")
        text = Path(given[locale]).read_text(encoding="utf-8").strip()
        api("PATCH", f"/v1/appStoreVersionLocalizations/{lid}", {"data": {
            "type": "appStoreVersionLocalizations", "id": lid, "attributes": {"whatsNew": text}}})
        print(f"新機能の文（{locale}）を入れました")

    notes = review_notes()
    detail = api("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail").get("data")
    if detail:
        api("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {
            "type": "appStoreReviewDetails", "id": detail["id"], "attributes": {"notes": notes}}})
    else:
        api("POST", "/v1/appStoreReviewDetails", {"data": {
            "type": "appStoreReviewDetails", "attributes": {"notes": notes},
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    print(f"審査メモを submission.md の英語版にしました（{len(notes)} 字）")


def submit(args):
    v = find_version(args.version)
    if v is None or v["attributes"]["appStoreState"] not in EDITABLE:
        sys.exit(f"{args.version} は提出できる状態ではありません（先に prepare）。")
    sub = api("POST", "/v1/reviewSubmissions", {"data": {
        "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
    api("POST", "/v1/reviewSubmissionItems", {"data": {
        "type": "reviewSubmissionItems",
        "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
                          "appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
    r = api("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {
        "type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}})
    print(f"{args.version} を審査に出しました: {r['data']['attributes']['state']}")


p = argparse.ArgumentParser()
sp = p.add_subparsers(required=True)
sp.add_parser("status").set_defaults(func=status)
pp = sp.add_parser("prepare")
pp.add_argument("version")
pp.add_argument("build")
pp.add_argument("--whats-new", action="append", default=[], metavar="LOCALE=FILE")
pp.set_defaults(func=prepare)
ps = sp.add_parser("submit")
ps.add_argument("version")
ps.set_defaults(func=submit)
args = p.parse_args()
args.func(args)
