# cas-cert-lb: 東京・大阪 DR構成（CAS / Certificate Manager / 内部ALB / Cloud DNS）の検証

> ステータス: **検証完了・環境は削除済み**（2026-11-28 05:38〜06:24 UTC に実施）
> - 検証結果: [`RESULTS.md`](RESULTS.md)
> - 知見: [`knowledge.md`](knowledge.md)
> - 費用の計算: [`COST.md`](COST.md)
> - 作業の時系列: [`HISTORY.md`](HISTORY.md)
> - 設計書: [`東京・大阪 DR構成設計.html`](東京・大阪%20DR構成設計.html)
> - 検証指示書（DR 構成の動作確認 T01〜T15）: [`verify-dr-prompt.md`](verify-dr-prompt.md)
> - 検証指示書（グローバル構成ができないことの確認 N01〜N07）: [`verify-global-negative-prompt.md`](verify-global-negative-prompt.md)

## 0. 方針

- 設計書の構成（全リージョナル）は **Terraform で構築** する。設計書の「工夫 B. コード化」と同じく、1 リージョン分のセットを `for_each`（キー `tokyo` / `osaka`）で 2 回作る。
- 指示書のテスト操作（切替・ルート CA の無効化・エラーになることの確認）は、**指示書に書かれた gcloud コマンドをそのまま実行** する。コマンド自体が検証の対象のため。
  - T09/T10 の DNS 切替を gcloud で行ったあと、`terraform plan` で差分が出ないこと（切戻し後に Terraform の定義と一致すること）も確認する。
  - N01〜N05 は「失敗すること」を確かめる試験なので Terraform 管理外。作成したもの（`neg-` で始まるリソース）は gcloud で削除する。
- 指示書の「承認を得てから実行」の操作（DNS 変更、サーバ停止、ルート CA の無効化、削除）は、実行前にコマンドを提示して承認を得る。
- 検証が終わったら結果を `RESULTS.md` にまとめ、`terraform destroy` する。

## 1. 前提

| 項目 | 値 |
|---|---|
| プロジェクト | `miumosh-sb-test01`（`terraform.tfvars`。Git 管理外） |
| リージョン | 東京 `asia-northeast1` / 大阪 `asia-northeast2` |
| 認証 | ADC は期限切れのため `GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)` を使う |
| API | privateca / certificatemanager / compute / dns はすでに有効 |
| 既存リソース | `default` VPC がある（今回は使わない。`vpc-main` を新しく作る） |
| ラベル | すべてのリソースに `purpose=drtest`（provider の `default_labels`） |

## 2. 作るリソース（設計書のリソース一覧に対応）

| サービス | リソース | 東京 | 大阪 | 設計書との違い・補足 |
|---|---|---|---|---|
| CAS | CA プール（ルート） | `root-pool` / `root-ca`（EC P-384、10 年） | なし | |
| CAS | CA プール（下位） | `sub-pool-tokyo` / `sub-ca-tokyo`（EC P-256、5 年） | `sub-pool-osaka` / `sub-ca-osaka` | 大阪の下位 CA の発行元は東京の `root-ca`（リージョンをまたぐ指定） |
| CAS | 階層 | `ENTERPRISE`（変数 `ca_tier`） | 同左 | 費用を抑えるなら `DEVOPS` にできる（後述） |
| Certificate Manager | サービスエージェント・IAM | `roles/privateca.certificateRequester` を各下位プールに付与 | 同左 | |
| Certificate Manager | 発行構成 | `ic-tokyo` → `sub-pool-tokyo` | `ic-osaka` → `sub-pool-osaka` | 有効期間 30 日・更新開始 66%・RSA 2048（**gcloud の既定値に合わせた**。Terraform では指定が必須） |
| Certificate Manager | 証明書 | `cert-tokyo`（test.sample.com, tokyo.test.sample.com） | `cert-osaka`（test.sample.com, osaka.test.sample.com） | |
| VPC | `vpc-main` / サブネット | `snet-tokyo` 10.10.0.0/24 | `snet-osaka` 10.20.0.0/24 | |
| VPC | プロキシ専用サブネット | 10.10.100.0/23 | 10.20.100.0/23 | |
| VPC | Cloud NAT | `drtest-nat-tokyo` | `drtest-nat-osaka` | 外部 IP なしのクライアント VM に dig を入れるため（設計書にはない） |
| VPC | ファイアウォール | `drtest-allow-hc-proxy`（HC 範囲＋プロキシ専用サブネット → tcp:80）、`drtest-allow-iap-ssh`（IAP → tcp:22） | | |
| Compute | 業務サーバ | MIG `drtest-mig-tokyo`（2 台 = #1, #2） | `drtest-mig-osaka`（2 台 = #3, #4） | e2-micro、python3 http.server :80（応答にリージョン名）。T11 で MIG のサイズを 0 にする |
| Compute | クライアント VM | `drtest-client-tk` | `drtest-client-os` | 外部 IP なし。`/tmp/root.pem` は metadata から配置 |
| LB | URL マップ / プロキシ | `um-tokyo` / `proxy-tokyo`（`cert-tokyo` を直接設定） | `um-osaka` / `proxy-osaka` | 証明書マップは使わない |
| LB | 転送ルール | `fr-tokyo` 10.10.0.10:443、グローバルアクセス ON | `fr-osaka` 10.20.0.10:443 | VIP は静的内部 IP `drtest-vip-*` として予約 |
| Cloud DNS | 限定公開ゾーン | `zone-sample`（sample.com.） | | |
| Cloud DNS | レコード | `test.sample.com.` A：フェイルオーバー（プライマリ東京、バックアップ大阪）、TTL 30、トリクル 0 | | |
| Cloud DNS | レコード | `tokyo.test.sample.com.` → 10.10.0.10 | `osaka.test.sample.com.` → 10.20.0.10 | TTL 300 |
| Cloud DNS | 受信サーバーポリシー | `drtest-inbound` | | T15 用。オンプレ接続はないので受信 IP ができることだけ確認 |

## 3. 費用（要確認・承認事項）

### 3.1 単価（2026-11-28 に確認）

[料金ページ](https://cloud.google.com/certificate-authority-service/pricing)には「$200 per CA per month」としか書かれておらず、日割りかどうかは分からない。そこで、課金の単位を **Cloud Billing Catalog API の SKU 定義**（サービス `BAE4-9668-BD24` Certificate Authority Service）で確認した。

| SKU | 課金の単位 | 測定の単位 | 単価（USD） |
|---|---|---|---|
| Monthly Active CA (Enterprise) | 日 | **秒**（86,400 秒 = 1 日） | **$6.66 / CA / 日**（≒ $200 / 30 日） |
| Monthly Active CA (DevOps) | 日 | 秒 | $0.66 / CA / 日（≒ $20 / 30 日） |
| Restored CA (Enterprise / DevOps) | 日 | 秒 | $6.66 / $0.66（削除した CA を復元したときの料金） |
| Issued Certificate Count (Enterprise) | 枚 | 枚 | 1〜50,000 枚目 $0.50 |
| Issued Certificate Count (DevOps) | 枚 | 枚 | 1〜50,000 枚目 $0.30 |

- **結論：CA の月額料金は日割り（実際には秒単位で測定）**。月の途中で作って数時間で消せば、その時間分だけかかる。1 か月分まるごとかかるわけではない。
- 課金される状態：ENABLED・STAGED・**DISABLED（無効にしても課金される）**。AWAITING_USER_ACTIVATION と DELETED（猶予期間中）は課金されない（[CA の状態](https://docs.cloud.google.com/certificate-authority-service/docs/certificate-authority-states)）。詳細は [`COST.md`](COST.md)。
- Certificate Manager の証明書（SKU `Regional Certificates usage`）は、**100 枚までは無料**なので今回はかからない。

### 3.2 今回の見積もり（3 CA = ルート 1・下位 2）

| 期間 | Enterprise | DevOps |
|---|---|---|
| 8 時間（1 日で終わる場合） | 3 × $6.66 × 8/24 ≒ **$6.7** | ≒ $0.7 |
| 24 時間 | 3 × $6.66 ≒ **$20** | ≒ $2 |
| 消し忘れて 1 か月 | ≒ $600 | ≒ $60 |

- 証明書の発行料（Enterprise $0.50/枚）：cert-tokyo、cert-osaka、T12 のテスト用、P2 のグローバル証明書のほか、下位 CA の証明書 2 枚と、自動更新の分も数える可能性がある。多くても 10 枚程度、**$5 以下**。
- その他（内部 ALB ×2、VM ×6、Cloud NAT ×2、Cloud DNS）：数時間なら数ドル程度。
- **合計の目安：Enterprise で 1 日 $30 程度まで、DevOps で $10 程度まで。** 一番大きいのは消し忘れなので、検証が終わったらすぐ destroy する。
- DevOps 階層は、発行した証明書を記録しない（一覧・失効ができない）。今回の検証項目には影響しないと考えるが、設計書は Enterprise を前提にしている。費用の差が 1 日 $20 程度なので、**設計書どおり Enterprise で検証するのがよい**。
- 削除：Terraform の destroy で CA を **猶予期間なしで即時削除** する（`skip_grace_period = true`）。CA の ID・プール名は削除後しばらく再利用できない場合がある。

## 4. 実施手順

```bash
cd certificate/cas-cert-lb
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)
terraform init
terraform plan -out=tfplan     # 47 to add（2026-11-28 時点で確認済み）
terraform apply tfplan         # ← 承認後に実行
```

1. apply 後、証明書が `ACTIVE` になるまで待つ。
2. `verify-dr-prompt.md` の T01〜T15 を実施（クライアント VM には `gcloud compute ssh --tunnel-through-iap` で入る）。
3. `verify-global-negative-prompt.md` の P1〜P2、N01〜N06 を実施（N07 のコンソール確認は人手で依頼）。
4. 結果を `RESULTS.md` にまとめる。
5. `neg-` リソースを gcloud で削除し、`terraform destroy`。

## 5. 検証で確かめたい点（設計書の主張）

| # | 設計書の主張 | 確認するテスト |
|---|---|---|
| 1 | 大阪の下位 CA の発行元に、東京のルート CA を指定できる | T01（Terraform の apply が成功するか自体も確認になる） |
| 2 | 同じ FQDN の証明書を、両リージョンで別々に発行できる | T02 |
| 3 | 1 つのルート CA で、両方のリージョンの証明書を検証できる | T05, T06, T08 |
| 4 | 切替で変えるのは DNS だけ | T09, T10 |
| 5 | バックエンドが全滅しても DNS は自動で切り替わらないことがある | T11 |
| 6 | 東京のルート CA が使えなくても、大阪で発行を続けられる | T12 |
| 7 | グローバルの CA・証明書はリージョナル内部 ALB に使えない | N01〜N06 |
