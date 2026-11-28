# 費用の計算（cas-cert-lb 検証）

> 計算日: 2026-11-28。単価は **Cloud Billing Catalog API の SKU**（USD、OnDemand、2026-11-28 に取得）から取った。
> 公式ドキュメント:
> - [Certificate Authority Service pricing](https://cloud.google.com/certificate-authority-service/pricing)
> - [Certificate authority states](https://docs.cloud.google.com/certificate-authority-service/docs/certificate-authority-states)（状態ごとの課金）
> - [Enable, disable, and restore certificate authorities](https://docs.cloud.google.com/certificate-authority-service/docs/managing-ca-state)
> - [Delete certificate authorities](https://docs.cloud.google.com/certificate-authority-service/docs/deleting-certificate-authorities)
> - [Certificate Manager pricing](https://cloud.google.com/certificate-manager/pricing)

## 0. 要点

| 問い | 答え |
|---|---|
| CAS の費用は何で決まるか | **CA の数 × 階層の単価 × 課金される状態でいた時間** ＋ **発行した証明書の枚数 × 階層の単価** |
| 「$200 / 月」は何の値段か | **CA 1 つあたり**の月額（Enterprise 階層）。DevOps 階層は CA 1 つあたり $20 / 月 |
| 日割りか | **日割り**。SKU は CA 1 つあたり $6.66 / 日（Enterprise）で、秒単位で測られる |
| 今回の設計（CA 3 つ）の本番の月額 | **Enterprise で約 $600 / 月**、DevOps なら約 $60 / 月（証明書の発行料は月 $1〜2 程度） |
| 今回の検証の実績 | **約 $3.8**（CA 3 つが約 43.5 分で約 $0.60、証明書 6 枚で $3.00、ほか約 $0.15） |

## 1. 料金の決まり方

### 1.1 計算式

```
CAS の費用 = Σ（CA ごとに）階層の日額 × 課金される状態でいた日数（秒単位で按分）
           + 発行した証明書の枚数 × 階層の 1 枚あたりの単価（枚数に応じて段階的に安くなる）
```

- 「$200 per CA per month」の **per CA が肝心**。CA を 1 つ増やすごとに、月 $200（Enterprise）が加わる。
- 今回の設計は「ルート CA 1 つ＋下位 CA 2 つ」なので、**CA は 3 つ → 3 × $200 = 月 $600**。

### 1.2 費用を左右するもの・しないもの

| 要素 | 費用への影響 | 補足 |
|---|---|---|
| **CA の数** | **する（一番大きい）** | 1 つあたり $6.66 / 日（Enterprise）、$0.66 / 日（DevOps） |
| **階層（Enterprise / DevOps）** | **する（10 倍の差）** | CA プールを作るときに決まり、後から変えられない |
| **CA が課金される状態でいた時間** | する | 秒単位。ENABLED・DISABLED・STAGED の間は課金される（§2） |
| **発行した証明書の枚数** | する | Enterprise $0.50 / 枚、DevOps $0.30 / 枚（最初の 5 万枚）。枚数の段階は、すべての CA の合計で数える（料金ページの「Tiering across CAs」） |
| CA プールの数 | しない | CA プール自体の SKU はない。CA が 0 のプールは無料 |
| ルート CA か下位 CA か | しない | 同じ SKU（Monthly Active CA）、同じ単価 |
| リージョン（東京・大阪） | しない | CAS の SKU はすべて `global`（リージョンによる差がない） |
| 鍵のアルゴリズム・有効期間 | しない | |
| Cloud KMS の顧客管理鍵（CMEK） | する（別料金） | Enterprise だけで使える。今回は使っていない（Google 管理の鍵） |

## 2. CA の状態と課金

[Certificate authority states](https://docs.cloud.google.com/certificate-authority-service/docs/certificate-authority-states) の「Is billed?」列より：

| 状態 | 課金 | どんなときにこの状態になるか |
|---|---|---|
| AWAITING_USER_ACTIVATION | **されない** | 下位 CA を作った直後（有効化の前）。**30 日以内に有効化しないと削除される** |
| STAGED | **される** | ルート CA を作った直後、下位 CA を有効化した後（まだ ENABLED にしていない） |
| ENABLED | **される** | 通常の稼働状態 |
| DISABLED | **される** | 無効にした CA。「A disabled CA continues to be billed at its usual billing tier.」 |
| DELETED | **されない**（猶予期間中） | 削除してから 30 日の猶予期間中。「A deleted CA isn't billed during the grace period.」 |

- **無効にしても料金は止まらない**。止めるには削除する。
- **削除した CA を復元すると、DELETED だった期間の分も請求される**（「you are charged at the CA's billing tier for the time that the CA existed in the DELETED state」）。SKU では `Restored CA`（Enterprise $6.66 / 日）。
- 猶予期間（30 日）の間は課金されないので、費用の点では猶予期間を省く必要はない。今回 Terraform で `skip_grace_period = true` にしたのは、検証用の CA を 30 日間残さないため（費用のためではない）。
- 今回の T12 でルート CA を無効にした約 40 秒（06:14:28〜06:15:09）も、課金の対象になっている。

## 3. 単価（SKU）

### 3.1 Certificate Authority Service（サービス `BAE4-9668-BD24`）

| SKU | 課金単位 | 測定単位 | 単価 |
|---|---|---|---|
| Monthly Active CA (Enterprise) | 日 | 秒 | **$6.66 / CA / 日**（= $0.2775 / CA / 時、30 日で $199.8） |
| Monthly Active CA (DevOps) | 日 | 秒 | $0.66 / CA / 日（30 日で $19.8） |
| Restored CA (Enterprise / DevOps) | 日 | 秒 | $6.66 / $0.66（削除した CA を復元したとき） |
| Issued Certificate Count (Enterprise) | 枚 | 枚 | 1〜50,000 枚目 **$0.50**、50,001〜100,000 枚目 $0.05、100,001 枚目〜 $0.001 |
| Issued Certificate Count (DevOps) | 枚 | 枚 | 1〜50,000 枚目 $0.30、50,001〜100,000 枚目 $0.03、100,001 枚目〜 $0.0009 |

- 料金ページには「$200 per CA per month」としか書かれていないが、SKU は日額で、秒単位で測られる。**$6.66 × 30 日 ≒ $200** なので、月額は 30 日分の目安と考えればよい（31 日の月は約 $206）。
- 階層の違い（[tiers](https://docs.cloud.google.com/certificate-authority-service/docs/tiers)）：DevOps は発行した証明書を記録しない（一覧・失効ができない）、CMEK が使えない。Enterprise は少ない枚数・長い有効期間の証明書のライフサイクル管理向け。

### 3.2 そのほかのサービス

| サービス | SKU | 単価 | 今回の数量 |
|---|---|---|---|
| Compute Engine | E2 Instance Core running in Japan / Osaka | $0.02803 / vCPU / 時 | e2-micro は 0.25 vCPU として課金 × 6 台 |
| Compute Engine | E2 Instance Ram running in Japan / Osaka | $0.003739 / GiB / 時 | 1 GiB × 6 台 |
| Compute Engine | Storage PD Capacity in Japan / Osaka | $0.052 / GiB / 月 | pd-standard 10 GiB × 6 |
| Networking | Regional Internal Application Load Balancer Proxy Instance Charge（Tokyo / Osaka） | $0.025 / プロキシインスタンス / 時 | 台数は自動で決まる |
| Networking | Regional Internal Application Load Balancer Inbound / Outbound Data Processing | $0.008 / GiB | 検証の通信はごくわずか |
| Networking | Networking Cloud Nat Gateway Uptime | $0.0014 / VM / 時 | 6 台 |
| Networking | Networking Cloud NAT IP Usage | $0.005 / IP / 時 | 2 |
| Networking | Networking Cloud Nat Data Processing | $0.045 / GiB | apt の数百 KB のみ |
| Cloud DNS | ManagedZone | $0.20 / ゾーン / 月 | 1 |
| Cloud DNS | Cloud DNS Internal Fast Health Check Target | $0.50 / ターゲット / 月 | 2（フェイルオーバーの東京・大阪 ALB） |
| Cloud DNS | Networking Cloud DNS Routing Policy Query | $0.0000007 / 件 | dig 数十回 |
| Certificate Manager | Regional Certificates usage / Certificates usage | **最初の 100 枚は無料**、以降 $0.20 / 枚 / 月 | 4 枚（無料） |

## 4. 本番運用の見積もり（設計書の構成案ごと）

### 4.1 CA の数と月額

1 か月 = 30 日（CA 1 つあたり Enterprise $199.8、DevOps $19.8）、1 年 = 365 日（Enterprise $2,431、DevOps $241）で計算。

| 構成案（設計書の記号） | CA の数 | Enterprise / 月 | DevOps / 月 | Enterprise / 年 | 備考 |
|---|---|---|---|---|---|
| **A. 全リージョナル（本設計）** | **3**（ルート 1、下位 2） | **$599** | $59 | **$7,293** | 採用案 |
| 工夫 A：東京はルートから直接発行、大阪だけ下位 CA | 2（ルート 1、下位 1） | $400 | $40 | $4,862 | ルート CA の鍵を毎日の発行に使う（ベストプラクティスから外れる） |
| G：ルート CA を東京・大阪で別々に作る | 4（ルート 2、下位 2） | $799 | $79 | $9,724 | 端末に配るルート証明書が 2 つになる |
| A のルートだけ Enterprise、下位 2 つは DevOps | 3 | $240 | — | $2,917 | **未検証**。大阪・東京の証明書は失効できない（DevOps のため） |

- 一番効くのは **CA の数と階層**。設計の構成を変えずに費用を下げるなら、DevOps 階層（1/10）にするかどうかの判断になる。
- ルート CA は、下位 CA を作るとき（数年に 1 回）しか使わない。それでも**無効にしても課金は止まらない**ので、「普段は無効にしておく」ことで費用は下がらない。

### 4.2 証明書の発行料（自動更新の分）

- 今回の発行構成（有効期間 30 日、66% で更新）では、証明書 1 枚が **19.8 日ごとに 1 回発行**される。1 年で 365 / 19.8 ≒ 18.4 回。
- 証明書 2 枚（cert-tokyo、cert-osaka）で、**1 年に約 37 枚**。

| 階層 | 1 年 | 1 か月あたり |
|---|---|---|
| Enterprise（$0.50 / 枚） | **約 $18** | 約 $1.5 |
| DevOps（$0.30 / 枚） | 約 $11 | 約 $0.9 |

- 有効期間を最長の 30 日のままにしておくのが、発行回数が一番少ない（最短の 21 日だと、年に約 26 回 × 2 枚）。

### 4.3 数年に 1 回の費用

| 作業 | 時期の目安 | 追加の費用（Enterprise） |
|---|---|---|
| 下位 CA の入れ替え（新しい下位 CA を作り、古い方を削除） | 下位 CA の有効期間（5 年）が切れる前 | 新旧が並ぶ期間だけ CA が 1 つずつ増える。1 か月並べると、東京・大阪で 2 × $200 = **約 $400**。CA 証明書の発行料 $1 |
| ルート CA の入れ替え | ルート CA の有効期間（10 年）が切れる前 | 新旧のルートと下位 CA が並ぶ期間の分。端末への新しいルート証明書の配布作業が必要 |

### 4.4 CAS 以外の本番の費用（参考）

| 項目 | 月額の目安 | 計算 |
|---|---|---|
| 内部 ALB のプロキシインスタンス（2 リージョン） | $37〜$110 | 2 × 1〜3 台 × $0.025 × 730 時間。台数はトラフィックで自動で決まる |
| Cloud DNS（ゾーン 1、ヘルスチェック対象 2） | $1.2 | $0.20 + 2 × $0.50 |
| Certificate Manager（証明書 2 枚） | $0 | 100 枚まで無料 |
| 業務サーバ・データ転送 | 構成による | 今回の見積もりの対象外 |

### 4.5 本設計（A、Enterprise）の合計

| 項目 | 1 か月 | 1 年 |
|---|---|---|
| CA 3 つ | $599 | $7,293 |
| 証明書の自動更新 | $1.5 | $18 |
| 内部 ALB・Cloud DNS（参考） | $38〜$111 | $460〜$1,350 |
| **合計（業務サーバを除く）** | **約 $640〜$710** | **約 $7,800〜$8,700** |

- **CAS が全体の 8〜9 割**を占める。

## 5. 今回の検証の実績（destroy 後に計算）

| 項目 | 実績 | 計算 |
|---|---|---|
| CA が存在した時間 | **約 43.5 分**（作成 05:38:11 → 削除 06:21:41） | 監査ログ |
| CA の費用 | **約 $0.60** | 3 × $6.66 × 43.5 / 1440 |
| そのほか（ALB・VM・NAT・DNS、約 46 分） | 約 $0.11〜$0.19 | ($0.14〜$0.24 / 時) × 0.76 時 |
| 証明書の発行料 | **$3.00** | 6 枚 × $0.50（§5.2） |
| **合計** | **約 $3.7〜$3.8** | |

- 下位 CA は、AWAITING_USER_ACTIVATION（課金なし）にいたのは数秒だけで、Terraform がすぐに有効化した。ここでは作成から削除まで全部の時間を課金対象として計算している。
- 請求データへの反映には時間がかかるため、数日後に Cloud Billing のレポート（サービス「Certificate Authority Service」）で実際の金額を確認する。
- 短時間の検証では、CA の時間料金より**証明書の発行料（1 枚 $0.50）の方が大きかった**。

### 5.1 1 時間あたりの費用（検証環境）

| 項目 | 計算 | $ / 時 |
|---|---|---|
| **CAS の CA（Enterprise × 3）** | 3 × $6.66 ÷ 24 | **$0.8325** |
| VM（e2-micro × 6） | 6 × (0.25 × $0.02803 + 1 × $0.003739) | $0.0645 |
| ディスク（10 GiB × 6） | 60 × $0.052 ÷ 730 | $0.0043 |
| 内部 ALB のプロキシインスタンス | 2 リージョン × 1〜3 台 × $0.025 | $0.05〜$0.15 |
| Cloud NAT | 6 × $0.0014 + 2 × $0.005 | $0.0184 |
| Cloud DNS（ゾーン＋ヘルスチェック 2） | ($0.20 + 2 × $0.50) ÷ 730 | $0.0016 |
| **合計** | | **約 $0.97〜$1.07** |

### 5.2 発行した証明書（Enterprise は記録が残るので、実際の枚数を数えた）

| 発行元プール | 証明書 | 発行日時（UTC） | 用途 |
|---|---|---|---|
| root-pool | Sample Sub CA Tokyo | 05:38:35 | 下位 CA 東京の CA 証明書 |
| root-pool | Sample Sub CA Osaka | 05:38:34 | 下位 CA 大阪の CA 証明書 |
| sub-pool-tokyo | test.sample.com, tokyo.test.sample.com | 05:43:57 | cert-tokyo |
| sub-pool-osaka | test.sample.com, osaka.test.sample.com | 05:45:53 | cert-osaka |
| sub-pool-tokyo | test.sample.com | 05:50:25 | neg-cert-global-cas（P2） |
| sub-pool-osaka | drtest2.sample.com | 06:14:33 | drtest-cert-osaka2（T12） |

- 下位 CA の CA 証明書も「発行した証明書」として記録されているので、課金対象に含めて計算した。
- 作成直後に `AUTHORIZATION_ISSUE` で発行が待たされた間（05:38〜05:44）の再試行は、証明書として記録されていない（失敗した試行は数えない）。

### 5.3 検証の長さ別の見込み（destroy 前に立てた見積もり）

| destroy までの時間 | 時間に比例する費用 | 証明書 | 合計 |
|---|---|---|---|
| 1 時間（実際はこれ） | $1.0 | $3.00 | **約 $4** |
| 3 時間 | $2.9〜$3.2 | $3.00 | 約 $6〜$7 |
| 24 時間 | $23〜$26 | $3.00 | 約 $26〜$29 |
| 消し忘れて 30 日 | $700〜$770 | $3.00 | **約 $700〜$770** |
| T13 の自動更新を観察（7 日以上） | 約 $140（CA）＋約 $30（そのほか） | 自動更新 2 枚 +$1 | **約 $170** |

## 6. 費用を抑えるための注意

- **CA の数が費用の大半を決める**。検証では必要最小限の CA にし、終わったらすぐに削除する。
- **無効化（DISABLED）では課金は止まらない**。止めるには削除する（削除後の猶予期間中は課金されない）。
- **削除した CA を復元すると、削除していた期間の分も請求される**。復元は本当に必要なときだけにする。
- 下位 CA は AWAITING_USER_ACTIVATION の間は課金されないが、30 日以内に有効化しないと自動で削除される。
- 短時間の検証では、証明書の発行料（Enterprise $0.50 / 枚）の方が大きくなる。不要な証明書を何度も作り直さない。
- 自動更新の観察のように CA を何日も残す検証は、DevOps 階層の小さな環境で行うと 1/10 で済む（ただし、設計書の Enterprise とは条件が少し変わる）。
