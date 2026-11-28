# 検証指示書：東京・大阪 DR構成（CAS / Certificate Manager / 内部ALB / Cloud DNS）の動作確認

あなたは Google Cloud の検証担当エンジニアです。以下の構成が設計どおりに動作するかを、gcloud CLI と検証用VMで確認し、結果を報告してください。

---

## 0. 守ること（最優先）

- 操作するのは、**`PROJECT_ID` で指定した検証用プロジェクトだけ**です。他のプロジェクトには触れないでください。
- 作成するリソースには、名前の先頭に `drtest-` を付けるか、ラベル `purpose=drtest` を付けてください。
- **削除・無効化・DNSの変更は、実行する前にコマンドを提示し、人間の承認を得てから実行してください。**（検証の手順として明記されているものも同じです）
- CASのCAは、作成すると月額料金がかかります。作成前に、作成するCAの数と料金がかかることを報告してください。
- 期待どおりの結果にならなかったときは、無理に合わせようとせず、**事実（コマンド、出力、エラー文）をそのまま記録して**、次のテストに進んでください。
- コマンドの書式に自信がないときは、`gcloud ... --help` か公式ドキュメントで確認してから実行してください。

## 1. 前提と変数

```bash
export PROJECT_ID="（検証用プロジェクトID）"
export PROJECT_NUMBER="$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')"
export R_TK="asia-northeast1"   # 東京
export R_OS="asia-northeast2"   # 大阪
export FQDN="test.sample.com"
export ZONE="zone-sample"        # 限定公開ゾーン sample.com.
export VPC="vpc-main"
export VIP_TK="10.10.0.10"
export VIP_OS="10.20.0.10"
gcloud config set project $PROJECT_ID
```

検証対象の構成（構築済みであることが前提です。未構築なら、設計書「東京・大阪 DR構成設計」の構築手順に従って先に構築してください）：

| 種類 | 東京 | 大阪 |
|---|---|---|
| CAプール（ルート） | root-pool / root-ca | なし |
| CAプール（下位） | sub-pool-tokyo / sub-ca-tokyo | sub-pool-osaka / sub-ca-osaka |
| 発行構成 | ic-tokyo | ic-osaka |
| 証明書 | cert-tokyo（test.sample.com, tokyo.test.sample.com） | cert-osaka（test.sample.com, osaka.test.sample.com） |
| ターゲットHTTPSプロキシ | proxy-tokyo | proxy-osaka |
| 転送ルール | fr-tokyo 10.10.0.10:443 | fr-osaka 10.20.0.10:443 |
| 業務サーバ | #1, #2 | #3, #4 |
| DNS | test.sample.com：フェイルオーバー（プライマリ東京、バックアップ大阪）、TTL 30秒 | |

検証用のクライアントVMを作成してください（なければ作成し、名前は `drtest-client-tk` と `drtest-client-os` にします）：
- `drtest-client-tk`：東京のサブネット、外部IPなし
- `drtest-client-os`：大阪のサブネット、外部IPなし
- どちらにも `dnsutils`（dig）、`openssl`、`curl` を入れてください。
- ルートCA証明書をVMの中に `/tmp/root.pem` として置いてください。

```bash
gcloud privateca roots describe root-ca --pool=root-pool --location=$R_TK \
  --format="value(pemCaCertificates)" > root.pem
```

## 2. テストケース

各テストについて、**実行したコマンド・出力の要点・判定（OK / NG / 要確認）**を記録してください。

### T01 CASの階層構造
- **確認内容**：ルートCAと2つの下位CAがすべて有効（ENABLED）であること。下位CAの発行元が、どちらも東京のroot-poolであること。
```bash
gcloud privateca roots list --location=$R_TK --pool=root-pool --format="table(name,state)"
gcloud privateca subordinates describe sub-ca-tokyo --pool=sub-pool-tokyo --location=$R_TK --format="yaml(state,subordinateConfig)"
gcloud privateca subordinates describe sub-ca-osaka --pool=sub-pool-osaka --location=$R_OS --format="yaml(state,subordinateConfig)"
```
- **期待結果**：すべて `ENABLED`。`subordinateConfig` の発行元が `.../locations/asia-northeast1/caPools/root-pool` を指していること。

### T02 証明書の発行状態
- **確認内容**：cert-tokyoとcert-osakaがどちらも発行済みで、両方に同じFQDNが入っていること。
```bash
gcloud certificate-manager certificates describe cert-tokyo --location=$R_TK --format="yaml(managed,sanDnsnames,expireTime)"
gcloud certificate-manager certificates describe cert-osaka --location=$R_OS --format="yaml(managed,sanDnsnames,expireTime)"
```
- **期待結果**：`managed.state: ACTIVE`。`sanDnsnames` に `test.sample.com` が含まれていること。`expireTime` は記録しておいてください。

### T03 LBへの証明書の設定とグローバルアクセス
```bash
gcloud compute target-https-proxies describe proxy-tokyo --region=$R_TK --format="yaml(certificateManagerCertificates)"
gcloud compute target-https-proxies describe proxy-osaka --region=$R_OS --format="yaml(certificateManagerCertificates)"
gcloud compute forwarding-rules describe fr-tokyo --region=$R_TK --format="yaml(IPAddress,allowGlobalAccess)"
gcloud compute forwarding-rules describe fr-osaka --region=$R_OS --format="yaml(IPAddress,allowGlobalAccess)"
```
- **期待結果**：各プロキシに、そのリージョンの証明書だけが設定されていること。両方の転送ルールで `allowGlobalAccess: true`。

### T04 通常時の名前解決
- 両方のクライアントVMで次を実行します。
```bash
dig +short test.sample.com
```
- **期待結果**：どちらのVMでも `10.10.0.10`（東京）が返ること。

### T05 TLSの検証（東京）
```bash
openssl s_client -connect 10.10.0.10:443 -servername test.sample.com -CAfile /tmp/root.pem </dev/null 2>/dev/null \
  | grep -E "subject=|issuer=|Verify return code"
curl -sS -o /dev/null -w "%{http_code}\n" --cacert /tmp/root.pem https://test.sample.com/
```
- **期待結果**：`Verify return code: 0 (ok)`。発行者（issuer）が Sub CA Tokyo であること。HTTPのステータスコードが200など、正常な値であること。

### T06 TLSの検証（大阪を直接）
```bash
openssl s_client -connect 10.20.0.10:443 -servername test.sample.com -CAfile /tmp/root.pem </dev/null 2>/dev/null \
  | grep -E "subject=|issuer=|Verify return code"
curl -sS -o /dev/null -w "%{http_code}\n" --cacert /tmp/root.pem --resolve test.sample.com:443:10.20.0.10 https://test.sample.com/
```
- **期待結果**：`Verify return code: 0 (ok)`。発行者が Sub CA Osaka であること。**同じルートCA1つで、両方の証明書を検証できる**ことが確認できればOKです。

### T07 リージョン専用の名前
```bash
dig +short tokyo.test.sample.com ; dig +short osaka.test.sample.com
curl -sS -o /dev/null -w "%{http_code}\n" --cacert /tmp/root.pem https://osaka.test.sample.com/
```
- **期待結果**：それぞれ `10.10.0.10` / `10.20.0.10` が返ること。TLSの検証がOKであること。

### T08 リージョンをまたいだ接続（グローバルアクセス）
- `drtest-client-os`（大阪）から東京のALBに、`drtest-client-tk`（東京）から大阪のALBに、それぞれT05・T06と同じ確認を行います。
- **期待結果**：どちらの方向でも接続でき、TLSの検証がOKであること。

### T09 手動切替（災対時の切替手順の確認）※承認を得てから実行
```bash
gcloud dns record-sets update test.sample.com. --zone=$ZONE --type=A --ttl=30 \
  --routing-policy-type=FAILOVER \
  --routing-policy-primary-data=fr-osaka@$R_OS \
  --routing-policy-backup-data-type=GEO \
  --routing-policy-backup-data="$R_TK=fr-tokyo@$R_TK" \
  --backup-data-trickle-ratio=0 --enable-health-checking
```
- 実行後、60秒待ってから、両方のVMでT04とT05を実行します。
- **期待結果**：`10.20.0.10` が返ること。**端末側を何も変えずに**、TLSの検証がOKで、発行者が Sub CA Osaka になること。
- コマンドを実行してから応答が切り替わるまでのおおよその時間を記録してください。

### T10 切戻し ※承認を得てから実行
- T09のコマンドで、プライマリとバックアップを元に戻します（プライマリ `fr-tokyo@$R_TK`、バックアップ `$R_OS=fr-osaka@$R_OS`）。
- **期待結果**：`10.10.0.10` に戻ること。TLSの検証がOKであること。

### T11 バックエンド障害で自動切替されるかの確認（設計上の注意点の実証）※承認を得てから実行
- 東京の業務サーバ #1・#2 を停止するか、インスタンスグループのサイズを0にします。
- 5分間、30秒おきに `dig +short test.sample.com` を実行して記録します。同時に、`curl` で返ってくるHTTPのステータスコードも記録します。
- **想定される結果**：Cloud DNSのヘルスチェックは内部ALBのプロキシの状態しか見ていないため、**自動では大阪に切り替わらない可能性があります**（応答は `10.10.0.10` のまま、HTTPは502や503などのエラー）。実際に観測した結果をそのまま記録してください。
- 確認が終わったら、サーバを元に戻してください。
- **この結果を見て、手動切替の手順（T09）が必要かどうかを判断します。**

### T12 東京のルートCAが使えない状態でも、大阪で発行できるか ※承認を得てから実行
- ルートCAを一時的に無効にします。
```bash
gcloud privateca roots disable root-ca --pool=root-pool --location=$R_TK
```
- 大阪で、テスト用の証明書を新しく発行します。
```bash
gcloud certificate-manager certificates create drtest-cert-osaka2 --location=$R_OS \
  --domains="drtest2.sample.com" --issuance-config=ic-osaka
```
- 数分待ってから、`managed.state` が `ACTIVE` になることを確認します。
- 確認が終わったら、ルートCAを再度有効にし（`roots enable`）、テスト用の証明書を削除します。
- **期待結果**：ルートCAが無効の間も、大阪の下位CAから証明書が発行されること。

### T13 自動更新の設定
```bash
gcloud certificate-manager issuance-configs describe ic-tokyo --location=$R_TK
gcloud certificate-manager issuance-configs describe ic-osaka --location=$R_OS
```
- 証明書の有効期間（`lifetime`）と、更新を始めるタイミング（`rotationWindowPercentage`）を記録してください。
- T02の `expireTime` から、次に更新されるおおよその日時を計算して記載してください。
- 実際に更新されるところまで確認したい場合は、有効期間を短くしたテスト用の発行構成を作るなどの方法を提案してください。ただし、設定できる最短値は公式ドキュメントで確認してください。**実際に作成するかどうかは、人間に確認してから決めてください。**

### T14 ファイアウォール
- 業務サーバに、プロキシ専用サブネットとヘルスチェック用のIP範囲（`35.191.0.0/16`, `130.211.0.0/22`）からの通信を許可するルールがあることを確認します。
- バックエンドサービスのヘルス状態が、すべて `HEALTHY` であることを確認します。
```bash
gcloud compute backend-services get-health （東京・大阪それぞれのバックエンドサービス） --region=（リージョン）
```

### T15 オンプレからの名前解決（オンプレとの接続がある場合のみ）
- 受信サーバーポリシーで作られた、東京と大阪の受信IPを確認します。
```bash
gcloud compute addresses list --filter="purpose=DNS_RESOLVER"
```
- オンプレのDNSに、その両方が転送先として登録されていることを、人間に確認してもらってください。

## 3. 報告の形式

次の形式で、マークダウンで報告してください。

```markdown
# DR構成 検証結果（実施日：YYYY-MM-DD）
## サマリ
- OK: n件 / NG: n件 / 要確認: n件
- 重要な発見：（T11の結果、想定と違った点など）

## 結果一覧
| ID | テスト | 判定 | 根拠（出力の要点） |
|---|---|---|---|

## 詳細
### T01 ...
実行コマンド / 出力の抜粋 / 判定 / 補足

## 未実施・保留の項目と理由
## 後片付けの状況（作成したテスト用リソースと、削除したかどうか）
```

## 4. 後片付け ※承認を得てから実行

- `drtest-` が付いたリソース（クライアントVM、テスト用の証明書など）を一覧にして提示し、承認を得てから削除してください。
- DNSのプライマリが東京に戻っていること、ルートCAが `ENABLED` に戻っていることを、最後にもう一度確認してください。
