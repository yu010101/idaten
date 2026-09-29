#!/usr/bin/env python3
"""Chrome -> Idaten Cookie 引っ越し(試作・方式a: SQLite を直接つなぎ替える)。

Chromium 153 の macOS 形式(ソースで確認済み):
  encrypted_value = b"v10" + AES-128-CBC(key, IV=b" "*16, PKCS7(SHA256(host_key) + value))
  key = PBKDF2-HMAC-SHA1(keychain_password, salt=b"saltysalt", iter=1003, len=16)
  Cookies DB の meta.version >= 24 のときだけ先頭 32 バイトのドメインハッシュが付く。

秘密(鍵・Cookie の値)は画面にもログにも出さない。出すのは件数だけ。
両方のブラウザを閉じてから実行する(開いていると止まる)。
"""
import argparse
import hashlib
import os
import shutil
import sqlite3
import subprocess
import sys
import time

try:
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
except ImportError:
    sys.exit("python3 の cryptography が要ります (pip3 install --user cryptography)")

V10 = b"v10"
IV = b" " * 16
SUPPORTED_DST_VERSION = 24
# Chromium の時刻: 1601-01-01 からのマイクロ秒
EPOCH_DELTA_US = 11644473600 * 1_000_000


def derive_key(password: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)


def load_password(spec: str) -> bytes:
    """spec: 'mock' | 'keychain:<service>:<account>' | 'file:<path>' """
    if spec == "mock":
        # crypto/apple/fake_keychain_v2.mm の kPassword。--use-mock-keychain の時の鍵
        return b"mock_password"
    if spec.startswith("keychain:"):
        _, service, account = spec.split(":", 2)
        r = subprocess.run(
            ["security", "find-generic-password", "-w", "-s", service, "-a", account],
            capture_output=True,
        )
        if r.returncode != 0:
            # stderr には秘密は含まれない(見つからない・拒否された等の理由だけ)
            sys.exit(f"キーチェーンから '{service}' を読めませんでした rc={r.returncode}: "
                     f"{r.stderr.decode(errors='replace').strip()}")
        pw = r.stdout.rstrip(b"\n")
        if not pw:
            sys.exit(f"'{service}' が空でした")
        return pw
    if spec.startswith("file:"):
        with open(spec[5:], "rb") as f:
            return f.read().rstrip(b"\n")
    sys.exit(f"鍵の指定が分かりません: {spec}")


def decrypt(key: bytes, blob: bytes):
    if not blob.startswith(V10):
        return None
    ct = blob[len(V10):]
    if len(ct) == 0 or len(ct) % 16:
        return None
    d = Cipher(algorithms.AES(key), modes.CBC(IV)).decryptor()
    padded = d.update(ct) + d.finalize()
    u = padding.PKCS7(128).unpadder()
    try:
        return u.update(padded) + u.finalize()
    except ValueError:
        return None


def encrypt(key: bytes, plain: bytes) -> bytes:
    p = padding.PKCS7(128).padder()
    padded = p.update(plain) + p.finalize()
    e = Cipher(algorithms.AES(key), modes.CBC(IV)).encryptor()
    return V10 + e.update(padded) + e.finalize()


def meta_version(con) -> int:
    row = con.execute("SELECT value FROM meta WHERE key='version'").fetchone()
    return int(row[0]) if row else -1


def columns(con, table):
    return [r[1] for r in con.execute(f"PRAGMA table_info({table})")]


def check_not_running(user_data_dir: str, label: str):
    lock = os.path.join(user_data_dir, "SingletonLock")
    if os.path.lexists(lock):
        sys.exit(f"{label} が起動中のようです({lock} がある)。閉じてから実行してください")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="元プロファイル (例 .../Google/Chrome/Default)")
    ap.add_argument("--dst", required=True, help="先プロファイル (例 .../dev.idaten.chromium/Default)")
    ap.add_argument("--src-key", required=True, help="mock | keychain:Chrome Safe Storage:Chrome | file:PATH")
    ap.add_argument("--dst-key", required=True, help="mock | keychain:Idaten Storage Key:Idaten | file:PATH")
    ap.add_argument("--overwrite", action="store_true", help="先に同じ Cookie があれば上書き(既定は先を残す)")
    ap.add_argument("--include-session", action="store_true", help="セッション Cookie も運ぶ(既定は運ばない)")
    ap.add_argument("--skip-hash", action="store_true", help="[試験用] ドメインハッシュを付けずに書く(負の対照)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    for label, prof in (("元", a.src), ("先", a.dst)):
        check_not_running(os.path.dirname(os.path.abspath(prof)), label)
    src_db = os.path.join(a.src, "Cookies")
    dst_db = os.path.join(a.dst, "Cookies")
    for p in (src_db, dst_db):
        if not os.path.exists(p):
            sys.exit(f"{p} がありません(先は一度起動して閉じると作られる)")

    src_key = derive_key(load_password(a.src_key))
    dst_key = derive_key(load_password(a.dst_key))

    # 元は読むだけ。念のため一時コピーを読む(元の DB に一切書かないため)
    tmp_src = dst_db + ".migrate-src-copy"
    shutil.copy2(src_db, tmp_src)
    try:
        src = sqlite3.connect(f"file:{tmp_src}?mode=ro", uri=True)
        dst = sqlite3.connect(dst_db, timeout=0)
        dst.execute("BEGIN IMMEDIATE")  # 先が開かれていれば locked で止まる

        sv, dv = meta_version(src), meta_version(dst)
        print(f"schema: 元 v{sv} / 先 v{dv}")
        if dv != SUPPORTED_DST_VERSION:
            sys.exit(f"先の Cookies DB が v{dv}。この試作は v{SUPPORTED_DST_VERSION} だけ書ける")
        scols, dcols = columns(src, "cookies"), columns(dst, "cookies")
        if sv == dv and scols != dcols:
            sys.exit("同じ版なのに列が違う。中止")
        missing = [c for c in dcols if c not in scols]
        if missing:
            sys.exit(f"元に無い列があるので書けない: {missing}")

        now_us = int(time.time() * 1_000_000) + EPOCH_DELTA_US
        cnt = dict(read=0, ok=0, plaintext=0, decrypt_fail=0, hash_fail=0,
                   expired=0, session=0, written=0, kept_existing=0)
        rows_out = []
        sel = ", ".join(dcols)
        for row in src.execute(f"SELECT {sel} FROM cookies"):
            cnt["read"] += 1
            r = dict(zip(dcols, row))
            if not r["is_persistent"] and not a.include_session:
                cnt["session"] += 1
                continue
            if r["has_expires"] and r["expires_utc"] and r["expires_utc"] < now_us:
                cnt["expired"] += 1
                continue
            host = r["host_key"].encode()
            ev = r["encrypted_value"] or b""
            if ev:
                plain = decrypt(src_key, bytes(ev))
                if plain is None:
                    cnt["decrypt_fail"] += 1
                    continue
                if sv >= 24:
                    h = hashlib.sha256(host).digest()
                    if not plain.startswith(h):
                        cnt["hash_fail"] += 1
                        continue
                    plain = plain[32:]
            else:
                plain = (r["value"] or "").encode()
                cnt["plaintext"] += 1
            cnt["ok"] += 1
            prefix = b"" if a.skip_hash else hashlib.sha256(host).digest()
            r["encrypted_value"] = encrypt(dst_key, prefix + plain)
            r["value"] = ""
            rows_out.append(r)

        if a.dry_run:
            dst.rollback()
            print("dry-run:", cnt)
            return

        backup = dst_db + time.strftime(".bak-%Y%m%d-%H%M%S")
        shutil.copy2(dst_db, backup)
        verb = "INSERT OR REPLACE" if a.overwrite else "INSERT OR IGNORE"
        ph = ", ".join("?" for _ in dcols)
        for r in rows_out:
            cur = dst.execute(f"{verb} INTO cookies ({sel}) VALUES ({ph})", [r[c] for c in dcols])
            if cur.rowcount == 1:
                cnt["written"] += 1
            else:
                cnt["kept_existing"] += 1
        dst.commit()

        # 書いた先を先の鍵で読み戻して検算(値は出さない)
        back_ok = back_bad = 0
        for host_key, ev in dst.execute("SELECT host_key, encrypted_value FROM cookies"):
            p = decrypt(dst_key, bytes(ev)) if ev else b""
            if p is not None and (a.skip_hash or not ev or p.startswith(hashlib.sha256(host_key.encode()).digest())):
                back_ok += 1
            else:
                back_bad += 1
        print("result:", cnt)
        print(f"readback(先の鍵で復号できた行): ok={back_ok} bad={back_bad}")
        print(f"backup: {backup}")
    finally:
        if os.path.exists(tmp_src):
            os.remove(tmp_src)


if __name__ == "__main__":
    main()
