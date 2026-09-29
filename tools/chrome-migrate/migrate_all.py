#!/usr/bin/env python3
"""Chrome の全プロファイルを 1 回で Idaten へ引っ越す道具。

- キーチェーンは Chrome Safe Storage と Idaten Storage Key を最初に 1 回ずつだけ読む。
  プロファイルごとには聞かない(鍵は使い回す)。
- 運ぶ: Cookies(鍵を入れ直す。chrome_migrate の関数をそのまま使う)、Bookmarks、History、
  Favicons、Local Storage、IndexedDB、Session Storage などサイトデータ。
- 運ばない: Preferences / Secure Preferences / Extensions / Login Data / キャッシュ類。
  根拠は下の PREFS_NOTE を参照(Chromium 153 のソースで確認)。
- Idaten の user-data-dir に新しいプロファイルディレクトリを作り、Local State の
  profile.info_cache にも登録する(選択画面に出る)。名前の対応表を migrate_map.json に記録。
- 両ブラウザが開いていたら止まる。書く前に Idaten の Local State と対象をバックアップ。
- --dry-run で件数だけ出す。秘密(鍵・Cookie の値)は画面にもログにも出さない。

PREFS_NOTE(Preferences/Secure Preferences を運ばない根拠, chromium 153.0.8010.52):
- chrome/browser/prefs/chrome_pref_service_factory.cc L282-291: 追跡プリファレンスの HMAC の種(seed)は
  `#if BUILDFLAG(GOOGLE_CHROME_BRANDING)` の時だけ IDR_PREF_HASH_SEED_BIN から読み、それ以外は空。
  => Google Chrome(正式ブランド)は 0 でない種、Idaten(Chromium ブランド)は空の種。
- services/preferences/tracked/pref_hash_calculator.cc L225-236: HMAC は seed と device_id と
  path と value から計算される。種が違えば、Chrome が書いた Secure Preferences の MAC は Idaten では
  検証に通らない(L155 INVALID)。壊れた/改竄扱いになり、リセットや警告の対象になる。
  よって Preferences/Secure Preferences は運ばない。拡張は Google 同期で入れ直す前提。
"""
import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chrome_migrate as cm  # noqa: E402  (derive_key/load_password/decrypt/encrypt を借りる)

# 既定のキーチェーン指定(本人の Mac 用)。試験では mock に差し替える
DEFAULT_SRC_KEY = "keychain:Chrome Safe Storage:Chrome"
DEFAULT_DST_KEY = "keychain:Idaten Storage Key:Idaten"

HOME = os.path.expanduser("~")
DEFAULT_CHROME_ROOT = os.path.join(HOME, "Library/Application Support/Google/Chrome")
DEFAULT_IDATEN_ROOT = os.path.join(HOME, "Library/Application Support/dev.idaten.chromium")

# 既定で飛ばす対応(手作業で済ませたぶん)
DEFAULT_SKIP = {"Profile 1": "Default"}

# 運ぶサイトデータ(ファイルと dir)。キャッシュ・プリファレンス・拡張・Login Data は入れない
DATA_FILES = [
    "Bookmarks",
    "History", "History-journal",
    "Favicons", "Favicons-journal",
    "Web Data", "Web Data-journal",          # 自動入力の住所など(暗号化された CC は先の鍵では読めない=既知の穴)
    "Network Action Predictor", "Network Action Predictor-journal",
    "Top Sites", "Top Sites-journal",
    "Shortcuts", "Shortcuts-journal",
]
DATA_DIRS = [
    "Local Storage",
    "IndexedDB",
    "Session Storage",
    "Service Worker",   # 中の CacheStorage は消えても再取得されるが、登録情報は運ぶ
    "WebStorage",
    "blob_storage",
]
# はっきり運ばないもの(誤って DATA_* に入れないための番人)
DENY = {
    "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
    "Preferences", "Secure Preferences",
    "Extensions", "Extension Rules", "Extension Scripts", "Extension State",
    "Local Extension Settings", "Managed Extension Settings", "Sync Extension Settings",
    "Login Data", "Login Data-journal", "Login Data For Account", "Login Data For Account-journal",
    "Cookies", "Cookies-journal",  # Cookies は別処理(鍵の入れ直し)
    "LOCK", "LOG", "SingletonLock",
}


def check_not_running(root, label):
    lock = os.path.join(root, "SingletonLock")
    if os.path.lexists(lock):
        sys.exit(f"{label} が起動中のようです({lock} がある)。閉じてから実行してください")


def list_chrome_profiles(chrome_root):
    ls = os.path.join(chrome_root, "Local State")
    with open(ls, encoding="utf-8") as f:
        obj = json.load(f)
    cache = obj.get("profile", {}).get("info_cache", {})
    out = []
    for d, info in cache.items():
        if not os.path.isdir(os.path.join(chrome_root, d)):
            continue
        out.append({"dir": d, "name": info.get("name", d), "user_name": info.get("user_name", "")})
    out.sort(key=lambda p: (p["dir"] != "Default", p["dir"]))
    return out


def sanitize(s):
    return "".join(c if c.isalnum() or c in " -_" else "_" for c in s).strip() or "profile"


def idaten_dir_for(chrome_dir, mapping, existing):
    """先のディレクトリ名を決める。衝突しないように。"""
    if chrome_dir in mapping:
        return mapping[chrome_dir]
    base = "chrome-" + sanitize(chrome_dir)
    name = base
    i = 2
    while name in existing or name in mapping.values():
        name = f"{base}-{i}"
        i += 1
    return name


def migrate_cookies(src_db, dst_db, src_key, dst_key, include_session, dry):
    """chrome_migrate と同じ処理を、鍵を渡す形で。先が無ければスキップ。"""
    if not os.path.exists(src_db):
        return {"read": 0, "written": 0, "note": "src Cookies なし"}
    if dry:
        # dry-run は先の DB を作らない。元だけ読んで、運ぶ件数を数える
        import hashlib
        c = dict(read=0, ok=0, decrypt_fail=0, hash_fail=0, expired=0, session=0)
        tmp = src_db + ".dry-copy"
        shutil.copy2(src_db, tmp)
        try:
            s = sqlite3.connect(f"file:{tmp}?mode=ro", uri=True)
            sv = cm.meta_version(s)
            now_us = int(time.time() * 1_000_000) + cm.EPOCH_DELTA_US
            for host, ev, pers, hasexp, exp in s.execute(
                    "SELECT host_key, encrypted_value, is_persistent, has_expires, expires_utc FROM cookies"):
                c["read"] += 1
                if not pers and not include_session:
                    c["session"] += 1; continue
                if hasexp and exp and exp < now_us:
                    c["expired"] += 1; continue
                plain = cm.decrypt(src_key, bytes(ev)) if ev else b""
                if plain is None:
                    c["decrypt_fail"] += 1; continue
                if ev and sv >= 24 and not plain.startswith(hashlib.sha256(host.encode()).digest()):
                    c["hash_fail"] += 1; continue
                c["ok"] += 1
            return c
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
    tmp = dst_db + ".migrate-src-copy"
    shutil.copy2(src_db, tmp)
    cnt = dict(read=0, ok=0, decrypt_fail=0, hash_fail=0, expired=0, session=0, written=0, kept=0)
    try:
        src = sqlite3.connect(f"file:{tmp}?mode=ro", uri=True)
        dst = sqlite3.connect(dst_db, timeout=0)
        dst.execute("BEGIN IMMEDIATE")
        sv, dv = cm.meta_version(src), cm.meta_version(dst)
        if dv != cm.SUPPORTED_DST_VERSION:
            dst.rollback()
            return {"error": f"先の Cookies が v{dv}(対応は v{cm.SUPPORTED_DST_VERSION})"}
        dcols = cm.columns(dst, "cookies")
        scols = cm.columns(src, "cookies")
        if [c for c in dcols if c not in scols]:
            dst.rollback()
            return {"error": "列が合わない"}
        now_us = int(time.time() * 1_000_000) + cm.EPOCH_DELTA_US
        rows = []
        sel = ", ".join(dcols)
        for row in src.execute(f"SELECT {sel} FROM cookies"):
            cnt["read"] += 1
            r = dict(zip(dcols, row))
            if not r["is_persistent"] and not include_session:
                cnt["session"] += 1
                continue
            if r["has_expires"] and r["expires_utc"] and r["expires_utc"] < now_us:
                cnt["expired"] += 1
                continue
            host = r["host_key"].encode()
            ev = r["encrypted_value"] or b""
            if ev:
                plain = cm.decrypt(src_key, bytes(ev))
                if plain is None:
                    cnt["decrypt_fail"] += 1
                    continue
                if sv >= 24:
                    import hashlib
                    h = hashlib.sha256(host).digest()
                    if not plain.startswith(h):
                        cnt["hash_fail"] += 1
                        continue
                    plain = plain[32:]
            else:
                plain = (r["value"] or "").encode()
            cnt["ok"] += 1
            import hashlib
            r["encrypted_value"] = cm.encrypt(dst_key, hashlib.sha256(host).digest() + plain)
            r["value"] = ""
            rows.append(r)
        if dry:
            dst.rollback()
            return cnt
        ph = ", ".join("?" for _ in dcols)
        for r in rows:
            c = dst.execute(f"INSERT OR IGNORE INTO cookies ({sel}) VALUES ({ph})", [r[x] for x in dcols])
            cnt["written" if c.rowcount == 1 else "kept"] += 1
        dst.commit()
        return cnt
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def copy_site_data(src_prof, dst_prof, dry):
    copied = []
    for name in DATA_FILES:
        s = os.path.join(src_prof, name)
        if os.path.isfile(s):
            if not dry:
                shutil.copy2(s, os.path.join(dst_prof, name))
            copied.append(name)
    for name in DATA_DIRS:
        s = os.path.join(src_prof, name)
        if os.path.isdir(s):
            d = os.path.join(dst_prof, name)
            if not dry:
                if os.path.exists(d):
                    shutil.rmtree(d)
                shutil.copytree(s, d, ignore=shutil.ignore_patterns("Cache", "Code Cache", "GPUCache"))
            copied.append(name + "/")
    return copied


def register_profile(idaten_ls, idaten_dir, disp_name, user_name, dry):
    with open(idaten_ls, encoding="utf-8") as f:
        obj = json.load(f)
    prof = obj.setdefault("profile", {})
    cache = prof.setdefault("info_cache", {})
    if idaten_dir in cache:
        return "既に登録済み"
    metrics = prof.setdefault("metrics", {})
    idx = metrics.get("next_bucket_index", len(cache) + 1)
    metrics["next_bucket_index"] = idx + 1
    label = disp_name + (f" ({user_name})" if user_name else "")
    cache[idaten_dir] = {
        "name": label,
        "user_name": user_name,
        "gaia_id": "",
        "is_consented_primary_account": False,
        "is_ephemeral": False,
        "is_using_default_avatar": True,
        "is_using_default_name": False,
        "background_apps": False,
        "managed_user_id": "",
        "metrics_bucket_index": idx,
        "avatar_icon": "chrome://theme/IDR_PROFILE_AVATAR_26",
    }
    order = prof.setdefault("profiles_order", list(cache.keys()))
    if idaten_dir not in order:
        order.append(idaten_dir)
    if not dry:
        with open(idaten_ls, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
    return f"登録 name='{label}' bucket={idx}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome-root", default=DEFAULT_CHROME_ROOT)
    ap.add_argument("--idaten-root", default=DEFAULT_IDATEN_ROOT)
    ap.add_argument("--src-key", default=DEFAULT_SRC_KEY)
    ap.add_argument("--dst-key", default=DEFAULT_DST_KEY)
    ap.add_argument("--all", action="store_true", help="全プロファイルを移す")
    ap.add_argument("--profiles", default="", help="移す Chrome の dir をカンマ区切りで(例 'Default,Profile 2')")
    ap.add_argument("--no-default-skip", action="store_true", help="Profile 1→Default の既定スキップをやめる")
    ap.add_argument("--include-session", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    check_not_running(a.chrome_root, "Chrome")
    check_not_running(a.idaten_root, "Idaten")
    idaten_ls = os.path.join(a.idaten_root, "Local State")
    for p in (os.path.join(a.chrome_root, "Local State"), idaten_ls):
        if not os.path.exists(p):
            sys.exit(f"{p} がありません")

    profiles = list_chrome_profiles(a.chrome_root)
    print("Chrome のプロファイル:")
    for i, p in enumerate(profiles):
        skip = DEFAULT_SKIP.get(p["dir"]) and not a.no_default_skip
        print(f"  [{i}] dir={p['dir']!r} name={p['name']!r} user={p['user_name']!r}"
              + (f"  (既定でスキップ→ Idaten {DEFAULT_SKIP[p['dir']]})" if skip else ""))

    # 移す対象を決める
    if a.profiles:
        want = set(x.strip() for x in a.profiles.split(","))
        targets = [p for p in profiles if p["dir"] in want]
    elif a.all:
        targets = list(profiles)
    else:
        sys.exit("--all か --profiles を指定してください(一覧だけ見るならこのままで OK)")
    if not a.no_default_skip:
        targets = [p for p in targets if p["dir"] not in DEFAULT_SKIP]
    if not targets:
        print("移す対象がありません(既定スキップを外すなら --no-default-skip)")
        return

    # 鍵はここで 1 回ずつだけ読む
    print("キーチェーンを読みます(Chrome→ 1回, Idaten→ 1回)...")
    src_key = cm.derive_key(cm.load_password(a.src_key))
    dst_key = cm.derive_key(cm.load_password(a.dst_key))

    # バックアップ(Local State と、既に対象 dir があれば)
    mapfile = os.path.join(a.idaten_root, "migrate_map.json")
    mapping = dict(DEFAULT_SKIP)
    if os.path.exists(mapfile):
        try:
            mapping.update(json.load(open(mapfile)))
        except Exception:
            pass
    if not a.dry_run:
        bak = idaten_ls + time.strftime(".bak-%Y%m%d-%H%M%S")
        shutil.copy2(idaten_ls, bak)
        print(f"Local State backup: {bak}")

    existing = set(list_chrome_profiles(a.idaten_root) and
                   [x["dir"] for x in list_chrome_profiles(a.idaten_root)])
    existing |= set(json.load(open(idaten_ls)).get("profile", {}).get("info_cache", {}).keys())

    for p in targets:
        dst_dir_name = idaten_dir_for(p["dir"], mapping, existing)
        mapping[p["dir"]] = dst_dir_name
        existing.add(dst_dir_name)
        src_prof = os.path.join(a.chrome_root, p["dir"])
        dst_prof = os.path.join(a.idaten_root, dst_dir_name)
        print(f"\n=== {p['dir']!r} ({p['name']}) → Idaten {dst_dir_name!r}")
        if not a.dry_run:
            os.makedirs(dst_prof, exist_ok=True)
        data = copy_site_data(src_prof, dst_prof, a.dry_run)
        print(f"  site data: {data}")
        # Cookies は先の DB が要る。無ければ空の v24 を作れないので、site data コピー後に
        # Chrome の Cookies を一旦コピーして、その場で鍵を入れ直す(スキーマは Chrome の v24 を流用)
        src_ck = os.path.join(src_prof, "Cookies")
        dst_ck = os.path.join(dst_prof, "Cookies")
        if os.path.exists(src_ck) and not a.dry_run:
            shutil.copy2(src_ck, dst_ck)  # まず器ごと持ってくる(v24 スキーマ)
            # 中身を全消しして、鍵を入れ直したものだけ入れる
            con = sqlite3.connect(dst_ck)
            con.execute("DELETE FROM cookies")
            con.commit()
            con.close()
        ck = migrate_cookies(src_ck, dst_ck, src_key, dst_key, a.include_session, a.dry_run)
        print(f"  cookies: {ck}")
        reg = register_profile(idaten_ls, dst_dir_name, p["name"], p["user_name"], a.dry_run)
        print(f"  {reg}")

    if not a.dry_run:
        with open(mapfile, "w", encoding="utf-8") as f:
            json.dump(mapping, f, ensure_ascii=False, indent=1)
        print(f"\n対応表: {mapfile}")
    print("\n対応表(chrome dir → idaten dir):", json.dumps(mapping, ensure_ascii=False))


if __name__ == "__main__":
    main()
