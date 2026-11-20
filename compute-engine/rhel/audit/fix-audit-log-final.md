```bash
sudo -i

export LC_ALL=C # date +%x / ausearch -ts の日付書式を揃える
export BK=/tmp/audit-backup-$(date +%Y%m%d%H%M%S)
mkdir -p $BK; echo $BK

# ------------------------------------------------------------------------------
# テスト設定する場合
# ------------------------------------------------------------------------------
# cat > /etc/audit/rules.d/50-identity.rules <<'EOF'
# -w /etc/passwd -p rwa -k identity
# -w /etc/group -p rwa -k identity
# -w /etc/shadow -p rwa -k identity
# -w /etc/gshadow -p rwa -k identity
# -w /etc/security/opasswd -p wa -k identity
# -w /etc/sudoers -p rwa -k scope
# -w /etc/sudoers.d/ -p rwa -k scope
# EOF
# chmod 0600 /etc/audit/rules.d/50-identity.rules
# restorecon -v /etc/audit/rules.d/50-identity.rules
# augenrules --load; echo $?     # 0（"Old style watch rules are slower" は警告なので問題なし）
# auditctl -l                    # 上の 7 行が出る


# ------------------------------------------------------------------------------
# 記録されてしまうことの確認（対応要否）
# ------------------------------------------------------------------------------
# /etc/passwd, /etc/group の読み取りがログに記録されることを確認する
S_D=$(date +%x); S_T=$(date +%T); sleep 1
cat /etc/passwd > /dev/null
cat /etc/group > /dev/null
sleep 2
ausearch --input-logs -i -f /etc/passwd -c cat -ts $S_D $S_T   # comm=cat ... が出る
ausearch --input-logs -i -f /etc/group  -c cat -ts $S_D $S_T   # 同上

# ------------------------------------------------------------------------------
# 設定箇所の確認
# ------------------------------------------------------------------------------
# 反映されたルール、設定値（ファイルパス付）を確認
auditctl -l | egrep -i "passwd|group"
grep -Hni -E "passwd|group" /etc/audit/rules.d/*.rules # ★★★

# 出力がない                                    -> 修正対応不要
# 出力がある 且つ -p (-F perm=) に r が含まれない -> 修正対応不要
# 出力がある 且つ -p (-F perm=) に r が含まれる   -> 修正対応必要
# 出力がある 且つ -w で -p の指定がない          -> 修正対応必要（-p なしは rwxa 扱い）
# ※ gshadow / groupadd 等の行もヒットするため、/etc/passwd, /etc/group の行か目視確認する

# example
# -w /etc/passwd -p wa -k identity                -> r なし -> 対応不要
# -w /etc/group -p rwa -k identity                -> r あり -> 対応必要
# -w /etc/passwd -k identity                      -> -p なし（= rwxa）-> 対応必要
# -a always,exit -F path=/etc/group -F perm=r ... -> r あり -> 対応必要

auditctl -s         # enabled 1 なら続行（0: 無効、2: 不変モード → 中止）
augenrules --check  # No change なら rules.d と audit.rules が一致（それ以外なら中止）

# ------------------------------------------------------------------------------
# バックアップ
# ------------------------------------------------------------------------------
cp -a /etc/audit/rules.d $BK/
cp -a /etc/audit/audit.rules $BK/
auditctl -l > $BK/auditctl-l.before
ls -lZ $BK $BK/rules.d

# ------------------------------------------------------------------------------
# 設定変更と反映
# ------------------------------------------------------------------------------
# 設定ファイルを手動修正して保存（対象ルールの -p から r を外す。例: -p rwa -> -p wa）
vi /etc/audit/rules.d/<xxx>.rules # ★★★ で確認したファイル名

# バックアップとの比較
diff -r $BK/rules.d /etc/audit/rules.d

# 設定ファイルを反映
augenrules --check         # Rules have changed and should be updated
augenrules --load; echo $? # 0
systemctl is-active auditd # active
auditctl -s                # enabled 1

# 反映後のルール確認
auditctl -l > $BK/auditctl-l.after
diff $BK/auditctl-l.before $BK/auditctl-l.after

# ------------------------------------------------------------------------------
# 記録されてないことの確認（作業後）
# ------------------------------------------------------------------------------
S_D=$(date +%x); S_T=$(date +%T); sleep 1
cat /etc/passwd > /dev/null
cat /etc/group > /dev/null
sleep 2
ausearch --input-logs -i -f /etc/passwd -c cat -ts $S_D $S_T   # <no matches>
ausearch --input-logs -i -f /etc/group  -c cat -ts $S_D $S_T   # <no matches>

# ------------------------------------------------------------------------------
# 切り戻し（必要であれば）
# ------------------------------------------------------------------------------
# cp -a $BK/rules.d/xxx.rules /etc/audit/rules.d/   # 修正したファイルを戻す
# restorecon -v /etc/audit/rules.d/*.rules
# diff -r $BK/rules.d /etc/audit/rules.d            # 差分なし
# augenrules --load; echo $?                        # 0
# auditctl -l | diff $BK/auditctl-l.before -        # 差分なし
```
