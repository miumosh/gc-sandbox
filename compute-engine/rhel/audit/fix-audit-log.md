# /etc/passwd・/etc/group の監査ルールから `r` を外す（手動手順）

上から順番にコピーして実行する。`#` のあとが期待する結果。

## 1. 接続（ローカル）

```bash
cd ~/ghq/github.com/miumosh/gc-sandbox/compute-engine/rhel/audit
ssh -i ~/.ssh/gc-rhel-audit -o UserKnownHostsFile=~/.ssh/gc-rhel-audit_known_hosts \
  rheladmin@$(terraform output -raw external_ip)
```

## 2. root になる（VM）

```bash
sudo -i
export LC_ALL=C
export BK=/root/audit-backup-$(date +%Y%m%d%H%M%S)
echo $BK
```

> セッションが切れたら `export LC_ALL=C` と `export BK=<上で表示したパス>` を再設定する。

## 3. 顧客環境の再現（検証環境のみ）

```bash
cat > /etc/audit/rules.d/50-identity.rules <<'EOF'
-w /etc/passwd -p rwa -k identity
-w /etc/group -p rwa -k identity
-w /etc/shadow -p rwa -k identity
-w /etc/gshadow -p rwa -k identity
-w /etc/security/opasswd -p wa -k identity
-w /etc/sudoers -p rwa -k scope
-w /etc/sudoers.d/ -p rwa -k scope
EOF
chmod 0600 /etc/audit/rules.d/50-identity.rules
restorecon -v /etc/audit/rules.d/50-identity.rules
augenrules --load; echo $?     # 0（"Old style watch rules are slower" は警告なので問題なし）
auditctl -l                    # 上の 7 行が出る
```

## 4. 修正が必要か確認

```bash
grep -nE '(-w[[:space:]]+/etc/(passwd|group)([[:space:]]|$))|(path=/etc/(passwd|group)([[:space:]]|$))' /etc/audit/rules.d/*.rules
# 50-identity.rules:1:-w /etc/passwd -p rwa -k identity
# 50-identity.rules:2:-w /etc/group -p rwa -k identity
#   → -p に r がある = 修正必要。r がない／該当なしなら修正不要（ここで終了）

auditctl -l | grep -E '/etc/(passwd|group)( |$)'        # 読み込み済みも同じ内容
auditctl -l | grep -E '(-w /etc/? )|(dir=/etc/?( |$))'  # 何も出ない（/etc ごとの監視なし）
auditctl -s | grep enabled                              # enabled 1（2 なら不変モード → 中止）
augenrules --check                                      # No change（それ以外なら中止）
```

## 5. 変更前: 読み取りがログに記録されることを確認

```bash
S_D=$(date +%x); S_T=$(date +%T); sleep 1
cat /etc/passwd > /dev/null
cat /etc/group > /dev/null
sleep 2
ausearch --input-logs -i -f /etc/passwd -c cat -ts $S_D $S_T   # comm=cat ... key=identity が出る
ausearch --input-logs -i -f /etc/group  -c cat -ts $S_D $S_T   # 同上
```

## 6. バックアップ

```bash
mkdir -m 0700 $BK
cp -a /etc/audit/rules.d $BK/
cp -a /etc/audit/audit.rules $BK/
auditctl -l > $BK/auditctl-l.before
ls -lZ $BK $BK/rules.d
```

## 7. 設定の変更

```bash
sed -i -E \
  -e '/^[[:space:]]*-w[[:space:]]+\/etc\/(passwd|group)([[:space:]]|$)/ s/(-p[[:space:]]+[wxa]*)r/\1/' \
  -e '/path=\/etc\/(passwd|group)([[:space:]]|$)/ s/(perm=[wxa]*)r/\1/' \
  /etc/audit/rules.d/50-identity.rules

diff -r $BK/rules.d /etc/audit/rules.d
# < -w /etc/passwd -p rwa -k identity
# < -w /etc/group -p rwa -k identity
# > -w /etc/passwd -p wa -k identity
# > -w /etc/group -p wa -k identity
#   → この 2 行だけであること

ls -lZ /etc/audit/rules.d/   # -rw------- root root ... auditd_etc_t のまま
```

> 顧客環境では、手順 4 の grep で出たファイル名を指定する。

## 8. 反映

```bash
augenrules --check        # Rules have changed and should be updated
augenrules --load; echo $?  # 0
systemctl is-active auditd  # active
```

> `systemctl restart auditd` は使わない（RHEL では拒否される）。

## 9. 反映後の静的確認

```bash
auditctl -l | grep -E '/etc/(passwd|group)( |$)'
# -w /etc/passwd -p wa -k identity
# -w /etc/group -p wa -k identity

auditctl -l | diff $BK/auditctl-l.before -      # 2 行だけ変わっている
diff $BK/audit.rules /etc/audit/audit.rules     # 2 行だけ変わっている
augenrules --check                              # No change
auditctl -s | grep -E 'enabled|lost'            # enabled 1 / lost 0
```

## 10. 変更後: 読み取りがログに記録されないことを確認

```bash
S_D=$(date +%x); S_T=$(date +%T); sleep 1
cat /etc/passwd > /dev/null
cat /etc/group > /dev/null
sleep 2
ausearch --input-logs -i -f /etc/passwd -c cat -ts $S_D $S_T   # <no matches>
ausearch --input-logs -i -f /etc/group  -c cat -ts $S_D $S_T   # <no matches>
```

## 11. 書き込みと他ルールは記録されることを確認（検証環境のみ）

```bash
S_D=$(date +%x); S_T=$(date +%T); sleep 1
useradd audit-verify-tmp && userdel -r audit-verify-tmp
cat /etc/shadow > /dev/null
sleep 2
ausearch --input-logs -i -f /etc/passwd -ts $S_D $S_T | grep ^type=SYSCALL   # comm=useradd / userdel が出る
ausearch --input-logs -i -f /etc/group  -ts $S_D $S_T | grep ^type=SYSCALL   # 同上
ausearch --input-logs -i -f /etc/shadow -c cat -ts $S_D $S_T | grep ^type=SYSCALL   # comm=cat が出る（shadow は変更していない）
```

## 12. 切り戻し（必要な場合のみ）

```bash
cp -a $BK/rules.d/50-identity.rules /etc/audit/rules.d/
diff -r $BK/rules.d /etc/audit/rules.d          # 差分なし
augenrules --load; echo $?                      # 0
auditctl -l | diff $BK/auditctl-l.before -      # 差分なし
```

## 13. 終了

```bash
exit   # root から抜ける
exit   # VM から抜ける
```

検証が終わったら、ローカルで `terraform destroy` を実行する。
