# rhel/audit: /etc/passwd・/etc/group の監査ルールから `r` を外す変更の検証

> ステータス: **検証完了・環境は削除済み**（2026-11-19 UTC に構築・検証、2026-11-20 に `terraform destroy`）
> - **手動確認の手順（接続〜確認をシリアルに実行）: [`fix-audit-log.md`](fix-audit-log.md)**
> - 顧客環境で実施する手動手順: [`PROCEDURE.md`](PROCEDURE.md)
> - 検証で取得したログ（実体は Git 管理外）: [`logs/README.md`](logs/README.md)
> - 顧客環境を再現するルールのサンプル: [`rules/50-identity.rules`](rules/50-identity.rules)

## 0. 目的と確認すること

顧客から「`/etc/audit/rules.d/` のルールで、`/etc/passwd` と `/etc/group` の監視権限から `r` を外したい」という依頼があった。変更するのは **この 2 行だけ** で、shadow / gshadow / sudoers などほかのルールは変更しない。

| # | 確認すること | 結果（検証後に記入） |
|---|---|---|
| 1 | 修正が必要か（`/etc/passwd`・`/etc/group` の一方または両方を、`r` を含む権限で監視しているか） | |
| 2 | 変更前: 2 つのファイルを読む（r 操作）とログに記録されること | |
| 3 | 設定のバックアップ → 変更 → 差分が 2 行だけであること | |
| 4 | 安全な反映（`augenrules`）と反映後の静的確認（`auditctl -l` 等） | |
| 5 | 変更後: 2 つのファイルを読んでもログに **記録されない** こと | |
| 6 | 変更後: 書き込み（w/a）と、ほかのルール（shadow の r）は引き続き記録されること | |
| 7 | ログを Git 管理外（`logs/`）に保存 | |

## 1. 構成

```
 自宅 PC（WSL）── SSH tcp:22 ──►  [FW: 送信元 = 自宅グローバル IP/32 のみ]
                                   VPC: rha-vpc（専用。default VPC は使わない）
                                   └ rha-subnet 10.20.0.0/24 (asia-northeast1)
                                      └ rha-vm  RHEL 9 / e2-medium / 外部 IP（エフェメラル）
                                         ログイン: rheladmin（metadata の ssh-keys、OS Login 無効）
```

```
compute-engine/rhel/audit/
├── README.md / PROCEDURE.md
├── .gitignore                    # 各ディレクトリに配置（秘密情報の混入防止）
├── versions.tf / variables.tf
├── network.tf                    # 専用 VPC、サブネット、SSH 許可 FW（自宅 IP/32 のみ）
├── compute.tf                    # Compute API 有効化、RHEL VM 1 台
├── outputs.tf                    # 外部 IP、ssh コマンド
├── terraform.tfvars.example      # terraform.tfvars は Git 管理外
├── rules/50-identity.rules       # 顧客環境を再現するルール（VM に手動で配置）
└── logs/                         # 検証ログ（README 以外は Git 管理外）
```

## 2. 前提・想定

| 項目 | 内容 |
|---|---|
| OS | `rhel-cloud/rhel-9`（最新イメージ）。顧客環境のバージョンが違う場合は `image` 変数で `rhel-8` / `rhel-10` に変更する |
| 顧客の既存ルール | 実物は未入手のため、CIS 準拠でよく見る形を想定した [`rules/50-identity.rules`](rules/50-identity.rules) を `/etc/audit/rules.d/` に置いて再現する。`/etc/passwd`・`/etc/group` は `-w <file> -p rwa -k identity` |
| 変更内容 | `-w /etc/passwd -p rwa ...` → `-w /etc/passwd -p wa ...`（`/etc/group` も同様）。ほかの行は変えない |
| 反映方法 | `augenrules --load`（RHEL 推奨。`systemctl restart auditd` は `RefuseManualStop=yes` のため使えない） |
| SSH | 本検証専用の鍵 `~/.ssh/gc-rhel-audit`（リポジトリの外）。FW は `allowed_ssh_cidr`（自宅 IP/32）だけを許可 |
| default VPC | このプロジェクトの default VPC には `default-allow-ssh`（0.0.0.0/0）が残っている。本検証は専用 VPC を使うため影響しない |
| 費用（目安） | e2-medium と RHEL のライセンス料が時間課金でかかる。検証後に `terraform destroy` する |

### ルールの形式による違い（顧客環境で確認すること）

| 顧客の書き方 | 判断 | 変更方法 |
|---|---|---|
| `-w /etc/passwd -p rwa -k xxx`（r を含む） | **修正必要** | `-p` から `r` を削除（`PROCEDURE.md` の sed） |
| `-a always,exit -F path=/etc/passwd -F perm=rwa -k xxx` | **修正必要** | `perm=` から `r` を削除（同じ sed で対応） |
| `-w /etc/passwd -k xxx`（`-p` なし） | **修正必要**（`-p` 省略時は `rwxa` 扱い） | 手動で `-p wxa` を追加する（sed では対応しない） |
| `-p r` だけ | 修正必要 | `r` を外すと権限が空になるため **行の削除** になる。顧客に確認 |
| `-p wa` など r を含まない | 修正不要 | — |
| 該当行なし | 修正不要（監視していない） | — |
| `-F dir=/etc` や `-w /etc/` のようにディレクトリごと監視 | 別途確認 | 2 行を変えても `/etc` 配下の読み取りは記録される。顧客に確認 |

## 3. 環境構築

```bash
cd compute-engine/rhel/audit

# 3-1. 本検証専用の SSH 鍵（リポジトリの外）
ssh-keygen -t ed25519 -f ~/.ssh/gc-rhel-audit -C rhel-audit -N ''

# 3-2. 自宅のグローバル IP を確認して tfvars に記載（terraform.tfvars は Git 管理外）
curl -s -4 https://checkip.amazonaws.com
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars   # project_id と allowed_ssh_cidr = "<上の IP>/32"

# 3-3. 作成（ADC が切れている場合は GOOGLE_OAUTH_ACCESS_TOKEN を使う）
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

### SSH 接続

```bash
export VM_IP=$(terraform output -raw external_ip)
# zsh / bash 共通。known_hosts は検証用に分ける
vm() { ssh -i ~/.ssh/gc-rhel-audit \
         -o StrictHostKeyChecking=accept-new \
         -o UserKnownHostsFile=~/.ssh/gc-rhel-audit_known_hosts \
         rheladmin@"$VM_IP" "$@"; }

vm 'cat /etc/redhat-release; id'   # 接続確認（起動直後は 1〜2 分待つ）
```

> 自宅の IP が変わると接続できなくなる。その場合は `terraform.tfvars` の `allowed_ssh_cidr` を直して `terraform apply` する。

## 4. 検証手順（ログを `logs/<RUN>/` に保存）

すべてローカル（WSL）から `vm` 経由で実行し、出力を `tee` で `logs/` に保存する。VM 上では root で `bash -s` を実行する。

> **注意: `ausearch` には必ず `--input-logs` を付ける。** `ausearch` は標準入力がパイプ／ファイルだとそこを監査ログとして読む。`bash -s` のヒアドキュメント内で付け忘れると、スクリプトの残りを読み込んで `<no matches>` になり、後続のコマンドも実行されない（事前実行で発生）。cron やスクリプトから実行する場合も同じ。

```bash
export RUN=$(date -u +%Y%m%dT%H%MZ)
export BK=/root/audit-backup-$RUN       # VM 上のバックアップ先
mkdir -p logs/$RUN
```

### 4-0. 顧客環境の再現（既存ルールの配置）

```bash
scp -i ~/.ssh/gc-rhel-audit -o UserKnownHostsFile=~/.ssh/gc-rhel-audit_known_hosts \
  rules/50-identity.rules rheladmin@"$VM_IP":/tmp/
vm sudo bash -s <<'EOF' | tee logs/$RUN/00-env.txt
exec 2>&1; set -x
install -m 0600 -o root -g root /tmp/50-identity.rules /etc/audit/rules.d/50-identity.rules
restorecon -v /etc/audit/rules.d/50-identity.rules
augenrules --load
cat /etc/redhat-release; uname -r; rpm -q audit
systemctl is-active auditd
ls -lZ /etc/audit/rules.d/
EOF
```

ここまでが「顧客の既存環境」。以降が顧客環境で実施する手順と同じ内容になる。

### 4-1. 修正が必要か確認

```bash
vm sudo bash -s <<'EOF' | tee logs/$RUN/01-check.txt
exec 2>&1
PAT='(^[[:space:]]*-w[[:space:]]+/etc/(passwd|group)([[:space:]]|$))|(path=/etc/(passwd|group)([[:space:]]|$))'
echo "## rules.d の該当行（ファイル名:行番号:内容）"
grep -nE "$PAT" /etc/audit/rules.d/*.rules || echo "(該当なし)"
echo; echo "## 読み込まれているルール（auditctl -l）"
auditctl -l | grep -E '/etc/(passwd|group)( |$)' || echo "(該当なし)"
echo; echo "## ディレクトリごとの監視がないか（/etc 全体）"
auditctl -l | grep -E '(-w /etc/? )|(dir=/etc/?( |$))' || echo "(なし)"
echo; echo "## 不変モード（enabled 2 なら再起動が必要）"
auditctl -s | grep -E '^enabled'
grep -nE '^-e[[:space:]]+2' /etc/audit/rules.d/*.rules || echo "(-e 2 なし)"
echo; echo "## rules.d と読み込み済みルールが一致しているか（No change であること）"
augenrules --check
EOF
```

判断:
- `-p` / `perm=` に `r` が含まれる行がある → **修正必要**（2-ルールの形式の表も参照）
- `augenrules --check` が `Rules have changed and should be updated` → **中止して確認**（rules.d に未反映の変更があり、反映すると今回の 2 行以外も適用されてしまう）
- `enabled 2` → 不変モード。`augenrules --load` が失敗するため、反映には再起動が必要

### 4-2. 変更前: r 操作がログに記録されること

```bash
vm sudo bash -s <<'EOF' | tee logs/$RUN/02-read-test-before.txt
exec 2>&1; export LC_ALL=C
S_D=$(date +%x); S_T=$(date +%T); echo "start: $S_D $S_T"; sleep 1
cat /etc/passwd > /dev/null
cat /etc/group  > /dev/null
sleep 2
for f in /etc/passwd /etc/group; do
  echo; echo "===== ausearch -f $f -c cat ====="
  ausearch --input-logs -i -f "$f" -c cat -ts "$S_D" "$S_T"; echo "ausearch exit=$?"
done
EOF
```

期待: 2 ファイルとも `type=SYSCALL ... comm=cat ... key=identity` が出る（`exit=0`）。

### 4-3. バックアップ

```bash
vm sudo BK=$BK bash -s <<'EOF' | tee logs/$RUN/03-backup.txt
exec 2>&1; set -x
mkdir -m 0700 "$BK"
cp -a /etc/audit/rules.d "$BK/"           # rules.d の中には置かない（*.rules は全て読み込まれる）
cp -a /etc/audit/audit.rules "$BK/"
auditctl -l > "$BK/auditctl-l.before"
auditctl -s > "$BK/auditctl-s.before"
ls -laZ "$BK" "$BK/rules.d"
EOF
```

### 4-4. 設定の変更と変更確認

```bash
vm sudo BK=$BK bash -s <<'EOF' | tee logs/$RUN/04-edit.txt
exec 2>&1
PAT='(^[[:space:]]*-w[[:space:]]+/etc/(passwd|group)([[:space:]]|$))|(path=/etc/(passwd|group)([[:space:]]|$))'
TARGETS=$(grep -lE "$PAT" /etc/audit/rules.d/*.rules)
echo "targets: $TARGETS"
for f in $TARGETS; do
  # passwd / group の行だけ、-p（または perm=）の中の r を削除
  sed -i -E \
    -e '/^[[:space:]]*-w[[:space:]]+\/etc\/(passwd|group)([[:space:]]|$)/ s/(-p[[:space:]]+[wxa]*)r/\1/' \
    -e '/path=\/etc\/(passwd|group)([[:space:]]|$)/ s/(perm=[wxa]*)r/\1/' \
    "$f"
  echo; echo "===== diff -u backup $f ====="
  diff -u "$BK/rules.d/$(basename "$f")" "$f"
  echo "changed lines (expect 2 removed + 2 added = 4 in total): $(diff "$BK/rules.d/$(basename "$f")" "$f" | grep -c '^[<>]')"
done
echo; echo "===== diff -r rules.d（ほかのファイルが変わっていないこと） ====="
diff -r "$BK/rules.d" /etc/audit/rules.d
echo; ls -lZ /etc/audit/rules.d/
EOF
```

期待: 差分は `/etc/passwd`・`/etc/group` の 2 行だけ（`-p rwa` → `-p wa`）。所有者・パーミッション・SELinux コンテキスト（`auditd_etc_t`）が変わっていないこと。

### 4-5. 安全な反映

```bash
vm sudo bash -s <<'EOF' | tee logs/$RUN/05-load.txt
exec 2>&1; set -x
auditctl -s | grep -E '^enabled'      # 2 なら中止（再起動が必要）
augenrules --check                    # "Rules have changed and should be updated" が出るはず
augenrules --load; echo "augenrules exit=$?"
systemctl is-active auditd
EOF
```

`augenrules --load` の出力について（いずれも正常）:
- `Old style watch rules are slower` … `-w` 形式のルール 1 行ごとに出る警告。エラーではない（`exit=0`）
- `No rules` と `auditctl -s` 相当の状態表示 3 回 … 先頭の `-D`、`-b`、`-f` などの制御行の実行結果

### 4-6. 反映後の静的確認

```bash
vm sudo BK=$BK bash -s <<'EOF' | tee logs/$RUN/06-static-check.txt
exec 2>&1; export LC_ALL=C
echo "## passwd / group のルール（-p wa になっていること）"
auditctl -l | grep -E '/etc/(passwd|group)( |$)'
echo; echo "## 読み込み済みルールの差分（2 行だけ変わっていること）"
auditctl -l > "$BK/auditctl-l.after"
diff -u "$BK/auditctl-l.before" "$BK/auditctl-l.after"
echo; echo "## 生成された audit.rules の差分"
diff -u "$BK/audit.rules" /etc/audit/audit.rules
echo; echo "## rules.d と読み込み済みが一致（No change であること）"
augenrules --check
echo; echo "## auditd の状態（enabled 1 / lost が増えていないこと）"
auditctl -s
diff <(grep -vE '^(lost|backlog) ' "$BK/auditctl-s.before") <(auditctl -s | grep -vE '^(lost|backlog) ') && echo "(status: lost/backlog 以外は変化なし)"
echo; echo "## ルール変更の監査記録（CONFIG_CHANGE）"
ausearch --input-logs -i -m CONFIG_CHANGE -ts recent | grep '^type=CONFIG_CHANGE' | grep -oE 'op=[a-z_]+ .*key=[^ ]*' | sort | uniq -c
EOF
```

### 4-7. 変更後: r 操作がログに記録されないこと

```bash
vm sudo bash -s <<'EOF' | tee logs/$RUN/07-read-test-after.txt
exec 2>&1; export LC_ALL=C
S_D=$(date +%x); S_T=$(date +%T); echo "start: $S_D $S_T"; sleep 1
cat /etc/passwd > /dev/null
cat /etc/group  > /dev/null
sleep 2
for f in /etc/passwd /etc/group; do
  echo; echo "===== ausearch -f $f -c cat ====="
  ausearch --input-logs -i -f "$f" -c cat -ts "$S_D" "$S_T"; echo "ausearch exit=$?"
done
EOF
```

期待: 2 ファイルとも `<no matches>`（`exit=1`）。

### 4-8. 変更後: w/a とほかのルールは引き続き記録されること（検証環境のみ）

顧客環境ではユーザー作成を伴うため実施しない。検証環境で「r だけが外れた」ことを確認する。

```bash
vm sudo bash -s <<'EOF' | tee logs/$RUN/08-other-rules-test.txt
exec 2>&1; export LC_ALL=C
S_D=$(date +%x); S_T=$(date +%T); echo "start: $S_D $S_T"; sleep 1
useradd audit-verify-tmp && userdel -r audit-verify-tmp   # passwd / group への書き込み
cat /etc/shadow > /dev/null                                # shadow は rwa のまま
sleep 2
for f in /etc/passwd /etc/group; do
  echo; echo "===== $f への書き込み（comm=useradd/userdel が出ること） ====="
  ausearch --input-logs -i -f "$f" -ts "$S_D" "$S_T" | grep -E '^type=SYSCALL' ; echo "exit=$?"
done
echo; echo "===== /etc/shadow の読み取り（comm=cat が出ること） ====="
ausearch --input-logs -i -f /etc/shadow -c cat -ts "$S_D" "$S_T" | grep -E '^type=SYSCALL'; echo "exit=$?"
EOF
```

### 4-99. 切り戻し（必要な場合のみ）

```bash
vm sudo BK=$BK bash -s <<'EOF' | tee logs/$RUN/99-rollback.txt
exec 2>&1; set -x
for f in "$BK"/rules.d/*.rules; do cp -a "$f" /etc/audit/rules.d/; done
diff -r "$BK/rules.d" /etc/audit/rules.d
augenrules --load; echo "augenrules exit=$?"
auditctl -l | diff -u "$BK/auditctl-l.before" - && echo "(切り戻し完了: 変更前と一致)"
EOF
```

## 5. 片付け

```bash
terraform destroy
rm -f ~/.ssh/gc-rhel-audit ~/.ssh/gc-rhel-audit.pub ~/.ssh/gc-rhel-audit_known_hosts   # 不要なら
```

## 6. Claude による事前実行の結果（2026-11-19 UTC、RHEL 9.9 / kernel 5.14.0-741 / audit-3.1.5）

README の各コードブロックを、そのまま抜き出して実行した。ログは `logs/<RUN>-claude-dryrun/`（Git 管理外）。

| 手順 | 結果 |
|---|---|
| SSH | 自宅 IP/32 のみ許可の FW 経由で `rheladmin` でログイン、sudo 可 |
| 4-0 | RHEL 9 の初期状態は `rules.d/audit.rules`（`-D` / `-b 8192` / `--backlog_wait_time 60000` / `-f 1`）のみで、監視ルールはなし。サンプル配置後、SELinux コンテキストは `auditd_etc_t` |
| 4-1 | `50-identity.rules` の 4・5 行目が `-p rwa` → **修正必要**。`/etc` ごとの監視なし、`enabled 1`、`augenrules --check` = `No change` |
| 4-2 | ✅ `cat` による読み取りが 2 ファイルとも記録された（`syscall=openat a2=O_RDONLY ... key=identity`）。※最初は `--input-logs` なしで `<no matches>` になった（上記の注意を参照）→ 修正済み |
| 4-3 | ✅ `/root/audit-backup-<RUN>/` に rules.d・audit.rules・`auditctl -l`/`-s` を保存 |
| 4-4 | ✅ 差分は 2 行だけ（`-p rwa` → `-p wa`）。`sed -i` 後もパーミッション 0600 と `auditd_etc_t` が維持された |
| 4-5 | ✅ `--check` = `Rules have changed...` → `--load` は exit 0、auditd は active |
| 4-6 | ✅ `auditctl -l` と `audit.rules` の差分は 2 行だけ、`--check` = `No change`、`lost 0`、CONFIG_CHANGE（`op=add_rule ... res=yes`）を確認 |
| 4-7 | ✅ 2 ファイルとも `<no matches>`（exit 1） |
| 4-8 | ✅ useradd/userdel による passwd・group の `openat(O_RDWR)` と `rename` は引き続き記録された。shadow の `cat` も記録された |
| 4-99 | ✅ 切り戻し後の `auditctl -l` は変更前と一致 |

### 知見

- **読み取りのログ量が大きい:** 変更前は、ルールを読み込んでから約 40 秒の間に `key=identity` の記録が約 280 件あった（`sshd-session` 130、`sudo` 85、`unix_chkpwd` 22、`systemd` 18 など）。SSH ログインや sudo のたびに NSS が `/etc/passwd`・`/etc/group` を読むため。変更後は、これらによる記録はなくなり、書き込み（useradd/userdel）だけが記録された。顧客の変更理由（ログ量の削減）として妥当。
- **ログの見え方:** 書き込みは `openat` と `rename` の 2 種類で記録される。useradd などは一時ファイル `/etc/passwd+` に書いてから rename で置き換えるため、`a2=O_RDWR` の openat と `syscall=rename` が出る。
- **sed の範囲:** `sed` の対象行の正規表現は、パス名の後ろに空白か行末を必須にしている。そのため `/etc/passwd-`（バックアップファイル）の行は対象外になる。
