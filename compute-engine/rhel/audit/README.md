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
- **手動実行（[`fix-audit-log-final.md`](fix-audit-log-final.md)）での注意点:** `vi` で編集したときに 7 行すべてが消え、`auditctl -l` が `No rules` になった（`fix-audit-log-finel.log`）。この状態でも手順 7 の確認は `<no matches>` になるので、**「記録されないこと」の確認だけでは消しすぎに気付けない**。変更が 2 行だけであることを `diff -r` と `auditctl -l` の before/after の差分で必ず確認し、2 行以外が変わっていたら反映前に止める（または切り戻す）。

## 7. `r` を記録しないように変更するときの影響

### 7-1. 記録される内容への影響

| 観点 | 変更前（`-p rwa`） | 変更後（`-p wa`） | 補足 |
|---|---|---|---|
| `/etc/passwd`・`/etc/group` の読み取り | 記録される | **記録されない** | 誰がいつ参照したかを後から追えなくなる |
| 同ファイルへの書き込み・属性変更（useradd / usermod / groupadd / vipw など） | 記録される | 記録される（変化なし） | 4-8 で確認済み（`openat O_RDWR` と `rename`） |
| shadow / gshadow / opasswd / sudoers のルール | 記録される | 記録される（変化なし） | 変更対象外。4-6 の差分で 2 行以外に変化がないことを確認 |
| `/etc` ごとの監視・`-a ... -S open` などの別ルール | — | **別ルールで記録され続ける** | 2 行を変えても読み取りが記録される。4-1 で事前に確認する |
| ログ量 | SSH ログイン・sudo のたびに NSS が読むため多い（検証では約 40 秒で約 280 件） | 書き込み時のみ | 変更の主目的（ログ量の削減） |

- **セキュリティ・コンプライアンス:** 読み取りはどのユーザーでもできる（パーミッション 644）通常の操作であり、CIS Benchmark の該当項目（ユーザー・グループ情報の変更を記録する）も `-p wa` になっている。そのため一般的な基準では問題にならないことが多い。ただし、**顧客独自のセキュリティポリシーや監査要件（社内規程、ISMS、PCI DSS、SOC 2 などの統制記述）で「読み取りも記録する」と定めている場合は、ポリシーの改訂または例外承認が必要**になる。
- **後続のシステム:** `key=identity` の読み取りイベントを前提にしている仕組みがあると、影響を受ける。
  - SIEM・ログ監視のアラートやダッシュボード（「件数が 0 になったら異常」というアラートがあると誤検知する）
  - ログの転送・保管（Cloud Logging、Splunk など）。件数が減るので費用は下がる方向だが、容量ベースの契約やしきい値の見直しが必要な場合がある
  - 定期レポート（参照履歴のレポートを出していれば、変更日を境に件数が変わる）
- **コンプライアンススキャン:** OpenSCAP などで独自のプロファイルを使っている場合は、`-p rwa` を期待していないか確認する（標準の CIS / STIG プロファイルは `wa` で合格する想定）。

### 7-2. 作業時（反映時）の影響

| 観点 | 影響 | 根拠・確認方法 |
|---|---|---|
| OS 再起動 | **不要**（`enabled 1` の場合） | `augenrules --load` で即時に反映される。`enabled 2`（不変モード）の場合のみ再起動が必要 |
| auditd の再起動 | **不要** | 4-5 で `pid 615` が反映前後で変わっていない |
| 業務サービス・SSH | 影響なし | ルールを読み直すだけで、プロセスの停止はない |
| 監査ルールがない時間 | **ごく短時間ある** | `--load` は先頭の `-D` で全ルールを消してから読み直す。検証では `audit.rules` の生成から最後のルール追加まで数十ミリ秒程度。この間の操作は記録されない |
| 取りこぼし（lost） | 検証では 0 | 反映中に backlog が一時的に増えた（最大 12 / 上限 8192）が `lost 0`。負荷の高いサーバーでは `auditctl -s` の `lost` を前後で比較する |
| `failure` モード | 通常 `1`（syslog に出すだけ） | `-f 2`（panic）を設定しているサーバーでは、取りこぼし発生時にカーネルパニックになる。値を事前に確認し、2 の場合は負荷の低い時間帯に実施する |
| 他の未反映変更 | 一緒に反映されてしまう | `augenrules --check` が事前に `No change` であることを確認する（4-1） |
| ルール変更の記録 | `CONFIG_CHANGE`（`op=add_rule` など）が監査ログに残る | 作業の証跡になる。監査担当者に「この時刻にルールを変更した」と説明できるようにしておく |
| 永続性 | 再起動後も有効 | `rules.d` を変更しているため、起動時の `augenrules` で同じ内容が読み込まれる |
| 切り戻し | 数分で可能・再起動不要 | 4-99。バックアップから戻して `--load` するだけ |

### 7-2-1. 取りこぼし（lost）と `failure` に関係する要素（重要度順）

**前提:** 今回の変更は **イベント数を減らす方向**（`r` による大量の記録がなくなる）なので、変更後は取りこぼしのリスクが **下がる**。リスクが高いのは「現状（`-p rwa`）のまま運用している状態」と「反映の瞬間」。以下は、事前確認で値を把握しておくべき要素。

| 重要度 | 要素 | 起きること | 確認方法 | 検証環境の値 | 値の取得元（検証環境） | 対応・判断 |
|---|---|---|---|---|---|---|
| **高** | `failure`（`-f`）が `2`（panic） | 取りこぼしが 1 件でも発生すると **カーネルパニック（サーバー停止）** | `auditctl -s \| grep failure`、`grep -n '^-f' /etc/audit/rules.d/*.rules` | `1` | `auditctl -s` の `failure 1` 行（4-5 の `augenrules --load` が出力する状態表示、4-6 の `auditctl -s`。ログ: `05-load.txt`・`06-static-check.txt`、手動実行の `fix-audit-log-finel.log`）。設定元は `rules.d/audit.rules` の `-f 1`（`00-env.txt`）。※ `failure 1` は設定値で、エラーが起きたという意味ではない（表の下の補足を参照） | `2` の場合は顧客に報告し、低負荷の時間帯に実施。切り戻し・再起動の体制を用意する |
| **高** | auditd.conf の `disk_full_action` / `disk_error_action` / `admin_space_left_action` が `HALT` / `SINGLE` | ログ領域が一杯・書き込みエラーで **OS 停止またはシングルユーザーモード** | `grep -E '_action' /etc/audit/auditd.conf`、`df -h /var/log/audit` | 未確認 | — （auditd.conf は取得していない） | 今回の変更とは直接関係しないが、現状のログ量が多いほど起きやすい。空き容量を事前に確認する |
| **高** | 同上が `SUSPEND`（RHEL の既定値） | ディスク一杯で auditd が書き込みを止め、**以降のイベントが記録されない**（`lost` には数えられないので気付きにくい） | 同上、`systemctl status auditd`、`/var/log/messages` の auditd のメッセージ | 未確認 | — （取得していない） | 空き容量と `space_left` の警告を事前に確認する |
| **中** | `backlog_limit`（`-b`）が一杯になる | 待ち行列が一杯になると、イベントを出したプロセスが最大 `backlog_wait_time` **待たされる（処理遅延）**。それでも空かなければ取りこぼし（`lost` が増える）→ `failure` の動作 | `auditctl -s` の `backlog` / `backlog_limit` / `backlog_wait_time_actual` | `8192` / 反映時の最大 `12` | `auditctl -s` の `backlog_limit` / `backlog`（`05-load.txt` の状態表示 3 回で `backlog` 4→8→12、`06-static-check.txt` で 0）。設定元は `rules.d/audit.rules` の `-b 8192` | 反映中の `backlog` が上限よりずっと小さいことを確認済み。負荷の高いサーバーでは反映前後で `auditctl -s` を比較する |
| **中** | `backlog_wait_time` | 上記の待ち時間の上限（既定 60000 = 約 60 秒）。長いほど取りこぼしにくいが、遅延は大きくなる | `auditctl -s` | `60000` / `backlog_wait_time_actual 0` | `auditctl -s` の `backlog_wait_time` / `backlog_wait_time_actual`（`05-load.txt`・`06-static-check.txt`）。設定元は `rules.d/audit.rules` の `--backlog_wait_time 60000` | `backlog_wait_time_actual` が 0 でなければ、実際に待ちが発生している |
| **中** | `rate_limit`（`-r`）が 0 以外 | 1 秒あたりの上限を超えた分は **取りこぼし** | `auditctl -s \| grep rate_limit` | `0`（無制限） | `auditctl -s` の `rate_limit`（`05-load.txt`・`06-static-check.txt`、`fix-audit-log-finel.log`）。rules.d に `-r` の指定なし | 0 以外なら現状のログ量で超えていないか `lost` を確認する |
| **中** | プラグイン（SIEM 転送など）の待ち行列（auditd.conf の `q_depth`、`overflow_action`） | 転送先へのイベントだけが欠落する（ローカルのログには残る） | `grep -E 'q_depth\|overflow_action' /etc/audit/auditd.conf`、`ls /etc/audit/plugins.d/` | 未確認 | — （取得していない） | SIEM 側の欠落は監視チームに確認する。変更後は件数が減るので改善する方向 |
| **低** | 反映時の `-D`（全ルール削除）から読み直しまでの間 | 数十ミリ秒程度、ルールがない状態。**この間の操作は記録されない**（`lost` には数えられない） | 4-6 の `CONFIG_CHANGE` の時刻 | 数十ミリ秒程度 | 4-6 の `ausearch -m CONFIG_CHANGE`（`06-static-check.txt`、`audit.rules` の更新時刻 14:29:57.172 と最後の `add_rule` 14:29:57.188 から推定） | 避けられない。作業時刻を記録し、監査担当者に説明できるようにしておく |
| **低** | `lost` カウンタの見方 | 起動からの累計値。0 でなくても今回の作業が原因とは限らない | `auditctl -s \| grep lost` を反映の前後で比較 | 前後とも `0` | `auditctl -s` の `lost`（`05-load.txt`・`06-static-check.txt`、`fix-audit-log-finel.log`） | **作業前の値を記録しておき**、作業後に増えていないことを確認する（手順 3 の `auditctl-s.before`） |

#### 補足: `failure` が表すもの（エラーの有無ではない）

`auditctl -s` の `failure` は、**カーネルの監査機能で深刻なエラーが起きたときに、カーネルがどう動くか** を決める設定値（failure mode）。エラーが起きたかどうかは `failure` ではなく `lost` を見る（検証では反映の前後とも `lost 0` で、エラーは起きていない）。

| 値 | 名前 | エラー発生時の動作 |
|---|---|---|
| 0 | silent | 何もしない（`lost` を数えるだけ） |
| **1** | **printk** | **カーネルログ（`dmesg`、`/var/log/messages`）にメッセージを出し、処理は続ける。RHEL の既定値** |
| 2 | panic | カーネルパニック（サーバー停止） |

- **「深刻なエラー」とは:** 主にイベントの取りこぼし。backlog が一杯で `backlog_wait_time` まで待っても空かない、`rate_limit` を超えた、メモリが足りない、など。
- **検証環境が `1` だった理由:** RHEL の `audit` パッケージが最初から置く `/etc/audit/rules.d/audit.rules` に `-f 1`（コメント `## Set failure mode to syslog`）があり、起動時と `augenrules --load` のたびに読み込まれるため（`00-env.txt` で確認）。カーネル側の既定値も `1`。今回の検証ではこの行を変えていない。
- **顧客環境が `2` の場合:** 誰かが意図して `-f 2` を設定している（CIS・STIG などの強化設定で設定されることがある）。上の表の「高」の行のとおり注意する。どのファイルで設定しているかは `grep -n '^-f' /etc/audit/rules.d/*.rules` で確認する。

事前確認でまとめて取得するコマンド:

```bash
auditctl -s                                              # enabled / failure / rate_limit / backlog_limit / lost / backlog_wait_time(_actual)
grep -nE '^-(f|b|r|e)[[:space:]]|backlog_wait_time' /etc/audit/rules.d/*.rules
grep -E '^(space_left|admin_space_left|disk_full|disk_error|max_log_file)(_action)?|^(q_depth|overflow_action)' /etc/audit/auditd.conf
df -h /var/log/audit
```

### 7-3. 変更が戻されるリスク

- **構成管理ツール:** Ansible / Puppet / Chef / Red Hat Satellite / OpenSCAP の自動修正（remediation）などで `rules.d` を管理している場合、次回の実行で `-p rwa` に戻される。**手作業で変える前に、構成管理側の定義を変更する**（またはそちらで変更する）。
- **ゴールデンイメージ・テンプレート:** 新しく作るサーバーに古いルールが入るため、イメージ側も直す。
- **パッケージ更新:** `audit` パッケージの更新で `rules.d/audit.rules` が置き換わることはあるが、顧客が作成したファイル（例: `50-identity.rules`）は変更されない。

## 8. 実施可能日の洗い出しで確認すること

技術的には「再起動なし・数分・いつでも切り戻せる」作業なので、日程を決める条件は主に **運用・監査側の都合** になる。次の項目を顧客に確認し、すべてを満たす日を候補にする。

### 8-1. 事前に顧客に確認すること（ヒアリング項目）

| # | 確認すること | 実施日への影響 |
|---|---|---|
| 1 | 対象サーバーの一覧と台数、環境（開発 → 検証 → 本番の順で実施するか） | 台数が多い場合は複数日に分ける。本番は下位環境で問題がないことを確認してから |
| 2 | 各サーバーの `auditctl -s` の `enabled` / `failure` | `enabled 2` → 再起動が必要なのでメンテナンスウィンドウが必要。`failure 2` → 低負荷の時間帯を選ぶ |
| 3 | 読み取りの記録を求めるポリシー・監査要件の有無 | ある場合は、ポリシーの改訂・例外承認が終わってから |
| 4 | 監査（内部監査・ISMS・PCI DSS・SOC 2 など）の対象期間・審査日 | 証跡の取得期間の途中で記録内容を変えると説明が必要になる。期間の区切り（月初・四半期初めなど）に合わせると説明しやすい |
| 5 | SIEM・ログ監視・ログ転送の担当チームと、`key=identity` を使っているアラート・レポート | アラートの修正・抑止を同じ日に入れる。監視チームが対応できる日にする |
| 6 | 構成管理ツール（Ansible など）・ゴールデンイメージでの管理の有無 | 構成管理側の変更をリリースする日に合わせる（手作業との二重管理を避ける） |
| 7 | 変更管理の手続き（CAB・変更申請のリードタイム、承認者） | 申請から承認までの日数以降が候補になる |
| 8 | 変更凍結期間（年末年始、決算・繁忙期、大型リリースの前後など） | 凍結期間を除外する |
| 9 | 作業時間帯の制約（業務時間内の作業可否、夜間作業の要否） | 技術的には業務時間内でも影響はないが、運用ルールに従う |
| 10 | 同じ時期に予定している他の作業（OS パッチ・再起動・auditd の設定変更） | まとめて実施すると、問題が出たときに原因を切り分けにくい。別の日にするか、順番を決める |
| 11 | 作業者・確認者・切り戻しの判断者が揃う日 | root 権限での作業と、判断者への連絡手段を確保できる日 |
| 12 | 変更前の監査ログの保全（ローテーション・保管期間） | 変更前のログ（読み取りの記録を含む）を残す必要があれば、保全を終えてから |

### 8-2. 作業時間の目安（1 台あたり）

| 作業 | 目安 | 根拠 |
|---|---|---|
| 事前確認（手順 1〜2） | 5 分 | |
| バックアップ〜反映後の静的確認（手順 3〜6） | 5〜10 分 | 検証ではバックアップから反映後の確認まで約 1 分（コマンド実行のみ） |
| 変更後の確認（手順 7） | 5 分 | |
| 切り戻し（必要な場合） | 5 分 | 再起動不要 |

確認・記録を含めて **1 台あたり 15〜30 分** を目安にする（台数が多い場合は、構成管理ツールでの一括実施を検討する）。`enabled 2` のサーバーは再起動と起動後の確認の時間を追加する。

### 8-3. 当日の実施条件（Go / No-Go）

- 手順 1 で `augenrules --check` が `No change`、`enabled` が `1`
- 修正対象の行が事前の想定と一致している（想定外のファイル・`/etc` ごとの監視がない）
- 監視チームに作業開始を連絡済み（アラートの抑止が必要なら設定済み）
- バックアップの保存先は `/root` 配下にする（`/tmp` は `systemd-tmpfiles` で定期的に削除されるため、切り戻しに備えて残す場所としては適さない）
