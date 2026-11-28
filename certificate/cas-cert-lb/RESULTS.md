# 検証結果（実施日：2026-11-28）

> 対象：設計書「東京・大阪 DR構成設計」、検証指示書 [`verify-dr-prompt.md`](verify-dr-prompt.md)・[`verify-global-negative-prompt.md`](verify-global-negative-prompt.md)
> 環境：プロジェクト `miumosh-sb-test01`、Terraform（このディレクトリ）で構築。CA 階層は Enterprise。
> 時系列：[`HISTORY.md`](HISTORY.md)　費用：[`COST.md`](COST.md)　知見：[`knowledge.md`](knowledge.md)
> 時刻はすべて UTC。

---

# 第 1 部　DR構成 検証結果

## サマリ

- **OK: 13 件 / NG: 0 件 / 要確認: 2 件**（T13、T15）
- 重要な発見：
  1. **T11：バックエンドが 0 台になっても、DNS は自動で大阪に切り替わらない**（6 分間ずっと東京を返し、HTTP は 503）。設計書の注意点のとおりで、**手動切替の手順（T09）は必須**。
  2. T11：MIG を 0 にしても、接続ドレイン（300 秒）の間は `get-health` が `HEALTHY` のまま。**障害の監視には使えない**。
  3. T09/T10：設計書の切替コマンドは、そのまま使えた。GCE の VM からは、コマンドの完了から約 1 秒で応答が変わった。gcloud が `--routing-policy-backup-data` は非推奨だと警告する。
  4. T12：ルート CA を無効にしても、大阪の下位 CA は約 2 秒で証明書を発行できた。既存の TLS にも影響しなかった。
  5. T02：証明書の発行に 5〜7 分かかり、その間は一時的に `AUTHORIZATION_ISSUE` が表示された（IAM の反映待ち）。
  6. T03：指示書の `--format="yaml(certificateManagerCertificates)"` では null になる。API では `sslCertificates` に入っている。

## 結果一覧

| ID | テスト | 判定 | 根拠（出力の要点） |
|---|---|---|---|
| T01 | CAS の階層構造 | OK | root-ca / sub-ca-tokyo / sub-ca-osaka すべて `ENABLED`。両方の下位 CA の `pemIssuerChain` は同じ Sample Root CA |
| T02 | 証明書の発行状態 | OK | 両方 `ACTIVE`。SAN に test.sample.com。expireTime：東京 2026-12-28T05:43:56Z、大阪 2026-12-28T05:45:52Z |
| T03 | LB への証明書の設定とグローバルアクセス | OK | proxy-tokyo → cert-tokyo、proxy-osaka → cert-osaka（`sslCertificates` フィールド）。両方の転送ルールで `allowGlobalAccess: true` |
| T04 | 通常時の名前解決 | OK | 両方の VM で `10.10.0.10` |
| T05 | TLS の検証（東京） | OK | `Verify return code: 0 (ok)`、issuer=Sample Sub CA Tokyo、HTTP 200 |
| T06 | TLS の検証（大阪を直接） | OK | `Verify return code: 0 (ok)`、issuer=Sample Sub CA Osaka、HTTP 200。**1 つのルート CA で両方を検証できた** |
| T07 | リージョン専用の名前 | OK | tokyo → 10.10.0.10、osaka → 10.20.0.10。両方 HTTP 200（TLS 検証 OK） |
| T08 | リージョンをまたいだ接続 | OK | 大阪の VM → 東京 ALB、東京の VM → 大阪 ALB とも TLS 検証 OK、HTTP 200 |
| T09 | 手動切替 | OK | コマンド完了（06:01:27）から約 1 秒で両方の VM が `10.20.0.10` に。端末側の変更なしで issuer=Sub CA Osaka、検証 OK、HTTP 200 |
| T10 | 切戻し | OK | 06:05:11 完了 → 06:05:12 に `10.10.0.10`。検証 OK。`terraform plan` は No changes |
| T11 | バックエンド障害で自動切替されるか | OK（想定どおり、切り替わらない） | 6 分間ずっと `10.10.0.10`、HTTP 503。自動切替なし |
| T12 | ルート CA が無効の間の大阪での発行 | OK | root-ca `DISABLED` の間に drtest-cert-osaka2 を作成 → 約 20 秒以内に `ACTIVE`（発行自体は約 2 秒） |
| T13 | 自動更新の設定 | 要確認 | lifetime 30 日、rotationWindowPercentage 66。次の更新開始は 2026-12-18 00:56 UTC 頃。実際の更新は未観察 |
| T14 | ファイアウォール | OK | HC 範囲＋両方のプロキシ専用サブネット → tcp:80 を許可。バックエンドは 4 台とも `HEALTHY` |
| T15 | オンプレからの名前解決 | 要確認 | 受信 IP：東京 10.10.0.2、大阪 10.20.0.2。オンプレとの接続はないため、オンプレ DNS への登録は確認できない |

## 詳細

### T01 CAS の階層構造
```
$ gcloud privateca roots list --location=asia-northeast1 --pool=root-pool --format="table(name,state)"
NAME     STATE
root-ca  ENABLED
$ gcloud privateca subordinates describe sub-ca-tokyo ...  → state: ENABLED, subordinateConfig.pemIssuerChain = Sample Root CA
$ gcloud privateca subordinates describe sub-ca-osaka ...  → state: ENABLED, subordinateConfig.pemIssuerChain = Sample Root CA（東京と同じ証明書）
```
- 判定：OK
- 補足：`subordinateConfig` には発行元の URL（`.../caPools/root-pool`）ではなく、**発行元の証明書チェーン（`pemIssuerChain`）** が入る。発行元が東京の root-pool であることは、チェーンの証明書が root-ca のものと同じことと、`gcloud privateca certificates list --issuer-pool=root-pool --location=asia-northeast1` に `Sample Sub CA Osaka` の CA 証明書が載っていること（05:38:34 発行）で確認した。
- Terraform で `subordinate_config.certificate_authority = <東京の root-ca のフルネーム>` を指定するだけで、リージョンをまたいだ下位 CA が作れた。

### T02 証明書の発行状態
```
cert-tokyo: state ACTIVE, sanDnsnames [test.sample.com, tokyo.test.sample.com], expireTime 2026-12-28T05:43:56Z
cert-osaka: state ACTIVE, sanDnsnames [test.sample.com, osaka.test.sample.com], expireTime 2026-12-28T05:45:52Z
```
- 判定：OK
- 補足：作成（05:38:48）直後は `state: PROVISIONING` で、`provisioningIssue: AUTHORIZATION_ISSUE`「Permission denied for issuing certificates from the configured CA Pool.」と表示された。IAM（`roles/privateca.certificateRequester`）は付与済みで、何もしなくても東京は 5 分 9 秒後、大阪は 7 分 5 秒後に `ACTIVE` になった。

### T03 LB への証明書の設定とグローバルアクセス
```
$ gcloud compute target-https-proxies describe proxy-tokyo --region=asia-northeast1 --format="yaml(certificateManagerCertificates)"
  null
$ gcloud compute target-https-proxies describe proxy-tokyo --region=asia-northeast1 --format=json
  "sslCertificates": ["//certificatemanager.googleapis.com/projects/miumosh-sb-test01/locations/asia-northeast1/certificates/cert-tokyo"]
（proxy-osaka も同様に cert-osaka のみ）
$ gcloud compute forwarding-rules describe fr-tokyo ... → IPAddress: 10.10.0.10, allowGlobalAccess: true
$ gcloud compute forwarding-rules describe fr-osaka ... → IPAddress: 10.20.0.10, allowGlobalAccess: true
```
- 判定：OK
- 補足：指示書のコマンドは `--format="yaml(sslCertificates)"` に直す必要がある。

### T04〜T08（両方の VM で同じ結果）
```
$ dig +short test.sample.com            → 10.10.0.10
$ openssl s_client -connect 10.10.0.10:443 -servername test.sample.com -CAfile /tmp/root.pem
 0 s:CN = test.sample.com
 1 s:O = Sample, CN = Sample Sub CA Tokyo
 2 s:O = Sample, CN = Sample Root CA
issuer=O = Sample, CN = Sample Sub CA Tokyo
Verify return code: 0 (ok)
$ curl --cacert /tmp/root.pem https://test.sample.com/          → region=tokyo ... [200]
$ openssl s_client -connect 10.20.0.10:443 ...                   → issuer=Sample Sub CA Osaka, Verify return code: 0 (ok)
$ curl --resolve test.sample.com:443:10.20.0.10 ...              → region=osaka ... [200]
$ dig +short tokyo.test.sample.com / osaka.test.sample.com       → 10.10.0.10 / 10.20.0.10
$ curl https://tokyo.test.sample.com/ / https://osaka.test.sample.com/  → 200 / 200
```
- 判定：すべて OK
- 補足：ALB は、サーバ証明書・下位 CA・ルート CA の 3 枚をチェーンとして提示する。
- T08：`drtest-client-os`（大阪）→ 東京 ALB、`drtest-client-tk`（東京）→ 大阪 ALB のどちらも、T05・T06 と同じ結果になった。

### T09 手動切替
```
06:01:24 $ gcloud dns record-sets update test.sample.com. --zone=zone-sample --type=A --ttl=30 \
  --routing-policy-type=FAILOVER --routing-policy-primary-data=fr-osaka@asia-northeast2 \
  --routing-policy-backup-data-type=GEO --routing-policy-backup-data="asia-northeast1=fr-tokyo@asia-northeast1" \
  --backup-data-trickle-ratio=0 --enable-health-checking
WARNING: The `--routing-policy-backup-data` flag is deprecated. Use --routing-policy-backup-item instead.
06:01:27 完了
dig（2 秒おき）：tk 06:01:18 10.10.0.10 → 06:01:28 10.20.0.10 / os も同じ
06:04:50 dig → 10.20.0.10、issuer=Sample Sub CA Osaka、Verify return code: 0 (ok)、HTTP 200（両方の VM）
```
- 判定：OK
- 切り替わるまでの時間：**コマンドの完了から約 1 秒**（VM はメタデータサーバの DNS を使っていて、TTL によるキャッシュの影響を受けなかった）。オンプレの DNS などキャッシュするリゾルバを経由する場合は、最大で TTL（30 秒）が加わる。

### T10 切戻し
```
06:05:09 $ gcloud dns record-sets update ...（primary=fr-tokyo@asia-northeast1, backup asia-northeast2=fr-osaka@asia-northeast2）
06:05:11 完了 → 06:05:12 に両方の VM で 10.10.0.10
issuer=Sample Sub CA Tokyo、Verify return code: 0 (ok)、HTTP 200
$ terraform plan → No changes. Your infrastructure matches the configuration.
```
- 判定：OK
- 補足：gcloud（`--enable-health-checking` 付き）で作ったレコードと、Terraform（`internal_load_balancers` を指定）で作ったレコードは同じ内容で、差分は出なかった。

### T11 バックエンド障害で自動切替されるか
```
06:06:29 $ gcloud compute instance-groups managed resize drtest-mig-tokyo --size=0 --region=asia-northeast1
06:06:25 dns=10.10.0.10 http=200
06:06:55 dns=10.10.0.10 http=503
...（30 秒おき、両方の VM とも同じ）
06:12:26 dns=10.10.0.10 http=503
get-health（35 秒おき）：06:06:31〜06:11:56 ずっと HEALTHY;HEALTHY
監査ログ：VM の削除（instances.delete）は 06:12:32 に開始
06:13:24 resize --size=2 → 06:14:01 UNHEALTHY → 06:14:17 HEALTHY、HTTP 200
```
- 判定：OK（想定どおり。**自動では大阪に切り替わらない**）
- 観測：
  - DNS は 6 分間ずっと東京を返した。Cloud DNS のヘルスチェックは、ALB のプロキシしか見ていない。
  - HTTP はサイズ変更から 30 秒以内に 503 になった。
  - MIG は、接続ドレイン（`drainingTimeoutSec=300`）が終わるまで VM を削除せず、その間 `get-health` は HEALTHY を返し続けた。
  - 復旧は、サイズを 2 に戻してから約 53 秒（新しい VM の作成 → ヘルスチェック成功）。
- **判断：手動切替の手順（T09）は必要**。バックエンドの異常は、ALB のリクエスト数や 5xx の割合など、Cloud Monitoring の指標で検知して、手動で切り替える。

### T12 ルート CA が使えない状態での大阪の発行
```
06:14:27 $ gcloud privateca roots disable root-ca --pool=root-pool --location=asia-northeast1 → DISABLED
06:14:31 $ gcloud certificate-manager certificates create drtest-cert-osaka2 --location=asia-northeast2 --domains=drtest2.sample.com --issuance-config=ic-osaka
06:14:34 state=PROVISIONING → 06:14:55 state=ACTIVE（expireTime 2026-12-28T06:14:33Z = 06:14:33 に発行）
06:14:55 root-ca の状態 = DISABLED（発行の間ずっと無効）
ルート CA が無効の間の TLS：東京・大阪とも Verify return code: 0 (ok)
06:15:07 $ gcloud privateca roots enable ...  → ENABLED
06:15:10 $ gcloud certificate-manager certificates delete drtest-cert-osaka2 ... → 削除済み
$ terraform plan → No changes
```
- 判定：OK
- 補足：CA の「無効化」は失効ではないので、ルート CA で署名済みの下位 CA 証明書や、配布済みのルート証明書による検証には影響しない。

### T13 自動更新の設定
```
ic-tokyo / ic-osaka：lifetime 2592000s（30 日）、rotationWindowPercentage 66、keyAlgorithm RSA_2048
```
- 次の更新開始の目安（発行から 30 日 × 66% = 19.8 日後）：
  - cert-tokyo：発行 2026-11-28 05:43:56 → **2026-12-18 00:56 UTC 頃**
  - cert-osaka：発行 2026-11-28 05:45:52 → **2026-12-18 00:58 UTC 頃**
- 設定できる範囲（[公式ドキュメント](https://docs.cloud.google.com/certificate-manager/docs/issuance-configs)）：
  - lifetime：**21〜30 日**（`1814400s`〜`2592000s`）
  - rotationWindowPercentage：発行後 7 日以上、期限の 7 日以上前になる値。30 日なら 24〜76、21 日なら 34〜66
- **実際の更新を確認するには**：最短でも、lifetime 21 日・rotationWindowPercentage 34 の発行構成で、発行から約 7.1 日待つ必要がある。CA を 7 日以上残すことになるので、Enterprise の CA 3 つで約 $140、DevOps の CA 1 つ（ルート兼用、別の検証環境）なら約 $5。**作成するかどうかは未決定（人の判断待ち）**。
- 判定：要確認（設定は確認したが、更新そのものは未観察）

### T14 ファイアウォール
```
drtest-allow-hc-proxy  10.20.100.0/23,130.211.0.0/22,35.191.0.0/16,10.10.100.0/23  tcp:80  drtest-web
drtest-bs-tokyo：HEALTHY, HEALTHY　drtest-bs-osaka：HEALTHY, HEALTHY
```
- 判定：OK

### T15 オンプレからの名前解決
```
$ gcloud compute addresses list --filter="purpose=DNS_RESOLVER"
dns-forwarding-f316493614d0d88e  10.10.0.2  asia-northeast1  snet-tokyo
dns-forwarding-2848aedf688e990d  10.20.0.2  asia-northeast2  snet-osaka
```
- 判定：要確認。受信 IP が東京・大阪の両方にできることは確認した。オンプレの DNS に両方が転送先として登録されているかは、オンプレとの接続がないため確認できない（人による確認が必要）。

## 未実施・保留の項目と理由

| 項目 | 理由 |
|---|---|
| T13 実際の自動更新 | 有効期間は最短 21 日で、更新が始まるのは早くても発行の 7 日後。CA を 7 日以上残すかは人の判断待ち |
| T15 オンプレ DNS の登録 | 検証環境にオンプレとの接続がない |

## 後片付けの状況

| リソース | 状態 |
|---|---|
| drtest-cert-osaka2（T12） | **削除済み**（06:15:10） |
| ルート CA | **ENABLED に戻した**（06:15:09） |
| DNS のプライマリ | **東京に戻した**（06:05:11）。`terraform plan` は No changes |
| 東京の MIG | **サイズ 2 に戻した**（06:13:24、HEALTHY） |
| Terraform のリソース 47 件（クライアント VM、CA 3 つを含む） | **削除済み**（`terraform destroy`、06:20:37〜06:23:36。CA は 06:21:41 に即時削除） |
| プロジェクトのメタデータ `ssh-keys`（gcloud が自動で追加した鍵） | **削除済み**（06:24:11） |
| 一時的な SSH 鍵（drtest-key） | **削除済み**（scratchpad） |

---

# 第 2 部　検証結果：グローバルな CA・証明書はリージョナル ALB に使えないことの確認

## 結論

- 設計書の結論（全リージョナルしか選べない）を裏付けたか：**はい**
  - グローバル証明書（セルフマネージド・CAS 発行のどちらも）はリージョナルのプロキシに設定できない（API：`must be in same scope as resource referencing it`）。
  - 証明書マップは、グローバルのプロキシでしか使えない。
  - CA プールはグローバルに作れない。
  - 発行構成は、同じリージョンの CA プールしか参照できない（ただし、**グローバルの発行構成からは、リージョンの CA プールを参照できる**。P2）。
- ただし、**指示書の gcloud コマンド（N01・N02・N06）には問題がある**。regional のプロキシで `--certificate-manager-certificates` にフルパスを渡すと、gcloud が URL を壊す。このため、N01・N02 は API 直接と Terraform で確認し直した。

## 結果一覧

| ID | 内容 | 期待結果 | 実際の結果 | 判定 |
|---|---|---|---|---|
| P1 | グローバルのセルフマネージド証明書を作る | 成功 | 成功（`locations/global/certificates/neg-cert-global-sm`） | — |
| P2 | グローバルの発行構成（→ 東京の CA プール）から証明書を作る | 記録 | 成功。証明書は作成から 23 秒で `ACTIVE` | — |
| N01 | グローバルのセルフマネージド証明書 → リージョナルのプロキシ | エラー | gcloud：エラー（URL が壊れていたため、根拠にならない）／**API・Terraform：エラー（同じスコープでない）** | OK |
| N02 | グローバルの CAS 証明書 → リージョナルのプロキシ | エラー | gcloud：エラー（同上）／**API：エラー（同じスコープでない）** | OK |
| N03 | 証明書マップ → リージョナルのプロキシ | エラー | API がエラーを返した（gcloud はフラグを受け付けた） | OK |
| N04 | グローバルの CA プール | エラー | エラー（`Location global is not found`） | OK |
| N05 | 大阪の発行構成 → 東京の CA プール | エラー | エラー（場所が一致しない） | OK |
| N06 | 対照実験：リージョナル証明書 → リージョナルのプロキシ | 成功 | **指示書のコマンド（フルパス）：エラー**／短い名前：成功／API 直接：成功 | 要修正（コマンドの問題。設計は正しい） |
| N07 | コンソール画面での確認 | 表示されない | 未実施 | 人による確認が必要 |

## エラーメッセージ全文

### N01（gcloud、指示書どおり）
```
$ gcloud compute target-https-proxies create neg-proxy-01 --region=asia-northeast1 --url-map=um-tokyo --certificate-manager-certificates=projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-sm
ERROR: (gcloud.compute.target-https-proxies.create) Could not fetch resource:
 - Invalid value for field 'resource.sslCertificates[0]': 'https://certificatemanager.googleapis.com/v1/projects/miumosh-sb-test01/locations/asia-northeast1/certificates/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-sm'. Must be a valid SslCertificate URL or a valid Certificate Manager certificate URL within the same scope and project.
```

### N01（Compute API 直接、正しい URL）
```
POST https://compute.googleapis.com/compute/v1/projects/miumosh-sb-test01/regions/asia-northeast1/targetHttpsProxies
{"name":"neg-proxy-01","urlMap":"projects/miumosh-sb-test01/regions/asia-northeast1/urlMaps/um-tokyo","sslCertificates":["//certificatemanager.googleapis.com/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-sm"]}
→ 400 Invalid value for field 'resource.sslCertificates[0]': '//certificatemanager.googleapis.com/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-sm'. Resource '//certificatemanager.googleapis.com/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-sm' must be in same scope as resource referencing it.
```

### N01（Terraform、`neg-tf/`）
```
Plan: 1 to add, 0 to change, 0 to destroy.
google_compute_region_target_https_proxy.neg_global_cert: Creating...
Error: Error creating RegionTargetHttpsProxy: googleapi: Error 400: Invalid value for field 'resource.sslCertificates[0]': 'https://certificatemanager.googleapis.com/v1/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-sm'. Resource 'https://certificatemanager.googleapis.com/v1/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-sm' must be in same scope as resource referencing it., invalid
```

### N02（gcloud、指示書どおり）
```
ERROR: (gcloud.compute.target-https-proxies.create) Could not fetch resource:
 - Invalid value for field 'resource.sslCertificates[0]': 'https://certificatemanager.googleapis.com/v1/projects/miumosh-sb-test01/locations/asia-northeast1/certificates/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-cas'. Must be a valid SslCertificate URL or a valid Certificate Manager certificate URL within the same scope and project.
```

### N02（Compute API 直接、正しい URL）
```
→ 400 Invalid value for field 'resource.sslCertificates[0]': '//certificatemanager.googleapis.com/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-cas'. Resource '//certificatemanager.googleapis.com/projects/miumosh-sb-test01/locations/global/certificates/neg-cert-global-cas' must be in same scope as resource referencing it.
```

### N03
```
$ gcloud certificate-manager maps create neg-map                → 成功
$ gcloud certificate-manager maps entries create neg-entry ...  → 成功
$ gcloud compute target-https-proxies create neg-proxy-03 --region=asia-northeast1 --url-map=um-tokyo --certificate-map=neg-map
ERROR: (gcloud.compute.target-https-proxies.create) Could not fetch resource:
 - Invalid value for field 'resource.certificateMap': 'https://certificatemanager.googleapis.com/v1/projects/miumosh-sb-test01/locations/global/certificateMaps/neg-map'. Certificate Map is supported only with global TargetHttpsProxy. Please use SSL certificates instead.
```
- 拒否した段階：**API**（gcloud は `--region` と `--certificate-map` の組み合わせを受け付けて、リクエストを送った）。

### N04
```
$ gcloud privateca pools create neg-pool-global --location=global --tier=devops
ERROR: (gcloud.privateca.pools.create) PERMISSION_DENIED: Location global is not found or access is unauthorized. This command is authenticated as （利用者のアカウント） which is the active account specified by the [core/account] property.
```
- 補足：ステータスは `PERMISSION_DENIED` だが、内容は「global という場所がない」。CA プールは作られていない（料金なし）。

### N05
```
$ gcloud certificate-manager issuance-configs create neg-ic-os-to-tk --location=asia-northeast2 --ca-pool=projects/miumosh-sb-test01/locations/asia-northeast1/caPools/sub-pool-tokyo
ERROR: (gcloud.certificate-manager.issuance-configs.create) INVALID_ARGUMENT: Config validation failed
- '@type': type.googleapis.com/google.rpc.BadRequest
  fieldViolations:
  - description: the CaPool location does not match the CertificateIssuanceConfig
      location
    field: certificate_authority_config.certificate_authority_service_config.ca_pool
```

### N06（指示書どおり：フルパス）
```
$ gcloud compute target-https-proxies create neg-proxy-ok --region=asia-northeast1 --url-map=um-tokyo --certificate-manager-certificates=projects/miumosh-sb-test01/locations/asia-northeast1/certificates/cert-tokyo
ERROR: (gcloud.compute.target-https-proxies.create) Could not fetch resource:
 - Invalid value for field 'resource.sslCertificates[0]': 'https://certificatemanager.googleapis.com/v1/projects/miumosh-sb-test01/locations/asia-northeast1/certificates/projects/miumosh-sb-test01/locations/asia-northeast1/certificates/cert-tokyo'. Must be a valid SslCertificate URL or a valid Certificate Manager certificate URL within the same scope and project.
```

### N06b（短い名前）／N06（API 直接）
```
$ gcloud compute target-https-proxies create neg-proxy-ok2 --region=asia-northeast1 --url-map=um-tokyo --certificate-manager-certificates=cert-tokyo
Created [.../regions/asia-northeast1/targetHttpsProxies/neg-proxy-ok2].
POST .../regions/asia-northeast1/targetHttpsProxies {"sslCertificates":["//certificatemanager.googleapis.com/projects/miumosh-sb-test01/locations/asia-northeast1/certificates/cert-tokyo"]}
→ operation RUNNING → neg-proxy-ok-api 作成
```

## 想定と違った点

1. **gcloud のフルパス指定が壊れている（N01・N02・N06）**：regional のプロキシでは、`--certificate-manager-certificates` の値の前に、gcloud が `--region` の URL を付け足す。フルパス（`projects/...`）も `//certificatemanager.googleapis.com/...` も壊れる。ヘルプの「fully specified name」とは食い違う（gcloud 593.0.0）。→ 指示書は、短い名前にするか、API・Terraform で確認するように直す。
2. **P2：グローバルの発行構成から、東京の CA プールを参照できた**。グローバルの証明書としては発行できるが、リージョナル ALB には使えない（N02）ので、設計の結論は変わらない。
3. **N03：gcloud はフラグを受け付けた**（拒否したのは API）。
4. **N04：エラーの種類は `PERMISSION_DENIED`** で、`INVALID_ARGUMENT` ではない。

## 後片付けの状況

| リソース | 状態 |
|---|---|
| neg-proxy-ok-api、neg-proxy-ok2 | **削除済み**（06:19:55） |
| neg-entry → neg-map | **削除済み**（06:19:59、06:20:02） |
| neg-cert-global-sm、neg-cert-global-cas | **削除済み**（06:20:07、06:20:10） |
| neg-ic-global | **削除済み**（06:20:13） |
| neg-pool-global | 作られていない |
| neg-proxy-01 / 02 / 03 / 01c / ok / tf | 作られていない（すべてエラー）。`neg-tf/` の state も空 |
| ローカルの neg.key / neg.crt | **削除済み**（scratchpad） |

destroy 後に確認した結果：CA プール・CA・証明書・発行構成・VM・転送ルール・プロキシ・DNS ゾーン・DNS ポリシーは、どれも 0 件。VPC は `default` だけ（検証前からあったもの）。
