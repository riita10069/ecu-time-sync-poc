#!/usr/bin/env bash
# 2 台の ntpd-rs が同じマスター鍵で互いの cookie を検証できること、
# 3 段階のローテーションをローリングで行っても NTSN が出ないことを確かめる
set -uo pipefail
cd "$(dirname "$0")/.."
c() { finch compose exec -T client python3 /poc/app/creds_cli.py "$@" 2>&1 | grep -v -e Ignoring -e "exec failed"; }
ks() { python3 scripts/ntpd-keyset.py "$@" out/keys/ntpd-keyset; chmod 644 out/keys/ntpd-keyset; }
restart() { finch compose --profile pool restart "$1" >/dev/null 2>&1; sleep 2; echo "  (restarted $1)"; }

echo "== 共有鍵: ntpdrs で発行した cookie を両方で使う (NLB が交互に振り分ける想定)"
ks show
c fetch v1
for h in ntpdrs2 ntpdrs ntpdrs2; do c query v1 "${h}"; done

echo "== 段階 1: 新しい鍵を足す (primary は旧鍵のまま)"
ks add; restart ntpdrs; c query v1 ntpdrs; c query v1 ntpdrs2; restart ntpdrs2; c query v1 ntpdrs2

echo "== 段階 2: 新しい鍵を primary に"
ks promote; restart ntpdrs
c fetch v2
c query v2 ntpdrs2; c query v1 ntpdrs; c query v1 ntpdrs2
restart ntpdrs2; c query v1 ntpdrs2; c query v2 ntpdrs

echo "== 段階 2 と 3 の間: 車両が通常どおり問い合わせ、手持ちの旧鍵 cookie が新鍵 cookie に入れ替わる"
c query v1 ntpdrs 8; c query v2 ntpdrs2 8

echo "== 段階 3: 旧鍵を捨てる"
ks prune; restart ntpdrs; restart ntpdrs2
c query v1 ntpdrs; c query v2 ntpdrs2

echo "== 対照: 旧鍵の cookie しか持たない車両 (段階 1 の前に取得し、以後問い合わせていない)"
