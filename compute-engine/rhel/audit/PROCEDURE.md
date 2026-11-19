# 手動手順: /etc/passwd・/etc/group の監査ルールから `r` を外す

> 対象: RHEL（auditd + `augenrules` 構成）。root で実施する。
> 変更するのは `/etc/audit/rules.d/` の `/etc/passwd`・`/etc/group` の 2 行だけ。shadow / gshadow / sudoers などほかのルールは変更しない。
> 検証環境での実施結果は [`README.md`](README.md) を参照（RHEL 9.9 / audit-3.1.5 で確認済み）。
>
> **`ausearch` には `--input-logs` を付ける。** 標準入力が端末でない場合（`script` やパイプ、ヒアドキュメント経由での実行）、`ausearch` は標準入力を監査ログとして読むため、正しく検索できない。

## 事前に決めておくこと

- 作業ログの保存先（作業端末のターミナルログ、または `script` コマンド）
- 切り戻しの判断基準（例: `augenrules --load` が失敗した、差分が 2 行以外にある）

```bash
sudo -i
script -a /root/audit-change-$(date +%Y%m%d%H%M).log   # 作業ログ（任意。終了は exit）
export LC_ALL=C
export BK=/root/audit-backup-$(date +%Y%m%d%H%M%S)
PAT='(^[[:space:]]*-w[[:space:]]+/etc/(passwd|group)([[:space:]]|$))|(path=/etc/(passwd|group)([[:space:]]|$))'
```

## 手順 1. 修正が必要か確認

```bash
grep -nE "$PAT" /etc/audit/rules.d/*.rules                 # 設定ファイル上のルール
auditctl -l | grep -E '/etc/(passwd|group)( |$)'           # 読み込み済みのルール
auditctl -l | grep -E '(-w /etc/? )|(dir=/etc/?( |$))'     # /etc ごとの監視がないか
auditctl -s | grep -E '^enabled'                           # 2 なら不変モード
augenrules --check                                         # "No change" であること
```

| 結果 | 判断 |
|---|---|
| `-p` または `perm=` に `r` を含む行がある | **修正必要** → 手順 2 へ |
| `-w /etc/passwd -k xxx` のように `-p` がない | **修正必要**（`rwxa` 扱い）。手順 4 で手動で `-p wxa` を追加する |
| `r` を含まない（例: `-p wa`）／該当行がない | **修正不要**。作業終了 |
| `augenrules --check` が `Rules have changed and should be updated` | **中止**。rules.d に未反映の変更があるため、反映すると今回の 2 行以外も適用される。顧客に確認 |
| `enabled 2` | 不変モード。`augenrules --load` が失敗するため、反映には **再起動が必要**。作業計画を見直す |
| `/etc` ごと監視している | 2 行を変えても `/etc/passwd` の読み取りは記録される。顧客に確認 |

## 手順 2. 変更前: r 操作がログに記録されることを確認

```bash
S_D=$(date +%x); S_T=$(date +%T); sleep 1
cat /etc/passwd > /dev/null; cat /etc/group > /dev/null; sleep 2
ausearch --input-logs -i -f /etc/passwd -c cat -ts "$S_D" "$S_T"
ausearch --input-logs -i -f /etc/group  -c cat -ts "$S_D" "$S_T"
```

期待: どちらも `comm=cat` の `type=SYSCALL` レコードが出る。

## 手順 3. バックアップ

```bash
mkdir -m 0700 "$BK"
cp -a /etc/audit/rules.d "$BK/"        # バックアップを rules.d の中に置かない（*.rules は全て読み込まれる）
cp -a /etc/audit/audit.rules "$BK/"
auditctl -l > "$BK/auditctl-l.before"
auditctl -s > "$BK/auditctl-s.before"
ls -laZ "$BK/rules.d"
```

## 手順 4. 設定の変更と変更確認

```bash
TARGETS=$(grep -lE "$PAT" /etc/audit/rules.d/*.rules); echo "$TARGETS"
for f in $TARGETS; do
  sed -i -E \
    -e '/^[[:space:]]*-w[[:space:]]+\/etc\/(passwd|group)([[:space:]]|$)/ s/(-p[[:space:]]+[wxa]*)r/\1/' \
    -e '/path=\/etc\/(passwd|group)([[:space:]]|$)/ s/(perm=[wxa]*)r/\1/' \
    "$f"
done
diff -r "$BK/rules.d" /etc/audit/rules.d     # 差分が passwd / group の 2 行だけであること
ls -lZ /etc/audit/rules.d/                   # 所有者・パーミッション・SELinux コンテキストが変わっていないこと
```

例: `-w /etc/passwd -p rwa -k identity` → `-w /etc/passwd -p wa -k identity`

> sed を使わず `vi` で直接編集してもよい。その場合も `diff -r` で 2 行だけの変更であることを確認する。

## 手順 5. 反映

```bash
auditctl -s | grep -E '^enabled'    # 1 であること（2 なら中止）
augenrules --check                  # "Rules have changed and should be updated"
augenrules --load; echo $?          # 0 であること
systemctl is-active auditd          # active
```

- `systemctl restart auditd` は使わない（RHEL の auditd.service は `RefuseManualStop=yes` で拒否される）。
- `augenrules --load` は既存ルールを削除（`-D`）してから全ルールを読み直す。読み直しの間のごく短い時間は監査ルールがない状態になる。
- `--load` の出力のうち、`Old style watch rules are slower`（`-w` 形式 1 行ごとの警告）、`No rules`、状態表示（`enabled 1` など）は正常。判定は終了コード 0 で行う。

## 手順 6. 反映後の静的確認

```bash
auditctl -l | grep -E '/etc/(passwd|group)( |$)'                 # -p wa になっていること
auditctl -l | diff -u "$BK/auditctl-l.before" -                  # 2 行だけ変わっていること
diff -u "$BK/audit.rules" /etc/audit/audit.rules                 # 生成ファイルも 2 行だけ
augenrules --check                                               # "No change"
auditctl -s                                                      # enabled 1、lost が増えていないこと
ausearch --input-logs -i -m CONFIG_CHANGE -ts recent | grep '^type=CONFIG_CHANGE' | tail -n 20   # op=add_rule ... res=yes
```

## 手順 7. 変更後: r 操作がログに記録されないことを確認

```bash
S_D=$(date +%x); S_T=$(date +%T); sleep 1
cat /etc/passwd > /dev/null; cat /etc/group > /dev/null; sleep 2
ausearch --input-logs -i -f /etc/passwd -c cat -ts "$S_D" "$S_T"     # <no matches>
ausearch --input-logs -i -f /etc/group  -c cat -ts "$S_D" "$S_T"     # <no matches>
```

## 切り戻し

```bash
for f in "$BK"/rules.d/*.rules; do cp -a "$f" /etc/audit/rules.d/; done
diff -r "$BK/rules.d" /etc/audit/rules.d          # 差分なし
augenrules --load; echo $?
auditctl -l | diff -u "$BK/auditctl-l.before" -   # 差分なし
```
