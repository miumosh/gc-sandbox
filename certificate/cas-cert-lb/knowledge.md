# 知見：CAS × Certificate Manager × リージョン内部 ALB × Cloud DNS フェイルオーバー

> 2026-11-28 の検証で分かったこと（§8〜§10 は検証後の考察と、証明書の中身の確認による追記）（環境：`miumosh-sb-test01`、Terraform 1.15.5、google / google-beta provider 7.46.2、gcloud 593.0.0）。
> 根拠となる出力は [`RESULTS.md`](RESULTS.md)、時系列は [`HISTORY.md`](HISTORY.md)、費用は [`COST.md`](COST.md)。

## 1. 構成の制約（実測で確定したもの）

| 組み合わせ | 可否 | API の返答 |
|---|---|---|
| 大阪の下位 CA の発行元に、東京のルート CA を指定する | **できる** | — |
| 東京の CA プール → 大阪の発行構成 | できない | `the CaPool location does not match the CertificateIssuanceConfig location` |
| 東京の CA プール → **グローバル**の発行構成 | **できる**（証明書も発行される） | — |
| グローバル証明書（セルフマネージド・CAS 発行とも）→ リージョンのプロキシ | できない | `Resource '...locations/global/certificates/...' must be in same scope as resource referencing it.` |
| 証明書マップ → リージョンのプロキシ | できない | `Certificate Map is supported only with global TargetHttpsProxy. Please use SSL certificates instead.` |
| CA プールを global に作る | できない | `PERMISSION_DENIED: Location global is not found or access is unauthorized.` |
| 同じ FQDN の証明書を、東京・大阪で別々に発行する | できる | — |

- 決め手は**証明書の場所（スコープ）だけ**。証明書の種類（セルフマネージドか、Google マネージド＋CAS か）は関係ない。
- グローバルの発行構成はリージョンの CA プールを参照できるが、そこから発行したグローバル証明書は、リージョン内部 ALB では使えない。**「リージョン ALB なら全部リージョナル」という結論は変わらない**。

## 2. CAS

### 2.1 リージョンをまたぐ下位 CA（Terraform）

```hcl
resource "google_privateca_certificate_authority" "sub" {
  location = "asia-northeast2"          # 大阪
  type     = "SUBORDINATE"
  subordinate_config {
    certificate_authority = google_privateca_certificate_authority.root.name   # 東京の root-ca のフルネーム
  }
  ...
}
```

- 作成 → ルート CA による署名 → Activate → Enable まで、Terraform が自動で行う。ルート CA は約 11 秒、下位 CA は約 12 秒で `ENABLED` になった。
- `gcloud privateca subordinates describe` の `subordinateConfig` には、発行元の URL ではなく**発行元の証明書チェーン（`pemIssuerChain`）** が入る。発行元のプールを確かめるには、`gcloud privateca certificates list --issuer-pool=root-pool` に下位 CA の CA 証明書が載っているかを見る（Enterprise 階層のみ。DevOps 階層は記録しない）。

### 2.2 ルート CA を無効にしたとき

- ルート CA が `DISABLED` の間も、**下位 CA は証明書を発行できる**（約 2 秒で発行）。
- 無効化は失効ではないので、既存の TLS（ルート → 下位 → サーバ証明書）の検証にも影響しない。
- → 東京が被災してルート CA が使えなくなっても、大阪の発行・自動更新は止まらない（設計書の主張どおり）。ルート CA が必要になるのは、新しい下位 CA を作るときだけ。

### 2.3 削除

- Terraform では `skip_grace_period = true`、`deletion_protection = false`、`ignore_active_certificates_on_deletion = true` で、destroy のときに CA を即時削除する（既定では 30 日の猶予期間がある）。

## 3. Certificate Manager

### 3.1 作成直後の `AUTHORIZATION_ISSUE` は待てば消える

- 証明書を作った直後は `state: PROVISIONING` で、`provisioningIssue.reason: AUTHORIZATION_ISSUE`「Permission denied for issuing certificates from the configured CA Pool.」と表示される。
- サービスエージェント（`service-<番号>@gcp-sa-certificatemanager.iam.gserviceaccount.com`）に `roles/privateca.certificateRequester` を付与した直後だと、**IAM の反映待ちで 5〜7 分かかった**。何もしなくても自動で `ACTIVE` になる。
- IAM が反映された後に作った証明書は、**2〜23 秒**で発行された。
- Terraform は証明書の発行完了を待たない。プロキシには、**証明書が PROVISIONING の状態でも設定できる**（発行されるまで TLS はつながらない）。
- サービスエージェントを Terraform で作るには、`google_project_service_identity`（**google-beta provider のみ**）を使う。

### 3.2 発行構成（issuance config）の値

| 項目 | gcloud の既定値 | Terraform | 設定できる範囲（[公式ドキュメント](https://docs.cloud.google.com/certificate-manager/docs/issuance-configs)） |
|---|---|---|---|
| lifetime | `P30D` | **必須**（`"2592000s"`） | **21〜30 日**（`1814400s`〜`2592000s`） |
| rotation_window_percentage | 66 | **必須** | 1〜99。ただし、発行の 7 日後以降、期限の 7 日以上前になる値（30 日なら 24〜76、21 日なら 34〜66） |
| key_algorithm | `rsa-2048` | **必須**（`RSA_2048` / `ECDSA_P256`） | RSA_2048、ECDSA_P256 |

- 自動更新が始まるのは、発行から「lifetime × rotation_window_percentage」が経ったとき（既定値なら 19.8 日後）。
- **自動更新を実際に観察するには、最短でも約 7 日かかる**（21 日 × 34%）。検証で確かめるなら、CA を 7 日以上残す費用（Enterprise 3 CA で約 $140）を見込む。

### 3.3 ALB が提示する証明書チェーン

- `pemCertificate` には、サーバ証明書・下位 CA・ルート CA の 3 枚が入っていて、ALB はこの 3 枚を提示する。クライアントの信頼ストアにはルート CA 1 枚だけを入れればよい。

## 4. リージョン内部 ALB と gcloud の落とし穴

### 4.1 フルパスで証明書を指定すると、gcloud が URL を壊す

regional のプロキシで `--certificate-manager-certificates` に値を渡すと、gcloud はそれを「名前」とみなし、`--region` のリージョンの URL を前に付け足す。

| 指定した値 | gcloud が送った値 | 結果 |
|---|---|---|
| `cert-tokyo` | `.../locations/asia-northeast1/certificates/cert-tokyo` | 成功 |
| `projects/P/locations/asia-northeast1/certificates/cert-tokyo` | `.../locations/asia-northeast1/certificates/projects/P/locations/asia-northeast1/certificates/cert-tokyo` | **失敗（同じリージョンの正しい証明書でも）** |
| `//certificatemanager.googleapis.com/projects/P/locations/global/certificates/X` | `.../locations/asia-northeast1/certificates///certificatemanager.googleapis.com/...` | 失敗 |

- ヘルプには「fully specified name でも指定できる」と書かれているが、regional のプロキシでは動かない。
- **gcloud では短い名前を使う**。別のスコープの証明書を試したいときは、Compute API に直接渡すか Terraform を使う。そうしないと、エラーの原因が「スコープ違い」なのか「URL が壊れた」なのかを区別できない。
- このとき出るエラー文 `Must be a valid SslCertificate URL or a valid Certificate Manager certificate URL within the same scope and project.` は、URL が壊れたときに出る一般的なものなので、根拠には使わない。本来の制約のエラー文は `must be in same scope as resource referencing it`。

### 4.2 プロキシに設定した証明書は `sslCertificates` に入る

- Certificate Manager の証明書を設定しても、API のレスポンスでは `certificateManagerCertificates` ではなく `sslCertificates` に、`//certificatemanager.googleapis.com/...` の形で入っている。
- `gcloud ... --format="yaml(certificateManagerCertificates)"` だと null になる。`--format="yaml(sslCertificates)"` を使う。

### 4.3 Terraform では、plan はすり抜けて apply で失敗する

- `google_compute_region_target_https_proxy.certificate_manager_certificates` にグローバル証明書を指定しても、**plan は通る**。apply の時点で API が `must be in same scope` で拒否する。

## 5. Cloud DNS のフェイルオーバー（内部 ALB）

### 5.1 Terraform の書き方と、gcloud との対応

```hcl
routing_policy {
  primary_backup {
    trickle_ratio = 0
    primary {
      internal_load_balancers {
        load_balancer_type = "regionalL7ilb"
        ip_address = "10.10.0.10"
        port = "443"
        ip_protocol = "tcp"
        network_url = google_compute_network.main.id
        project = var.project_id
        region = "asia-northeast1"
      }
    }
    backup_geo {
      location = "asia-northeast2"
      health_checked_targets { internal_load_balancers { ... 10.20.0.10 ... } }
    }
  }
}
```

- `health_check` 属性（外部エンドポイント用）は指定しなくてよい。`internal_load_balancers` を指定すれば、ヘルスチェックの対象になる。
- gcloud の `--routing-policy-primary-data=fr-osaka@asia-northeast2 ... --enable-health-checking` で更新したレコードと、上の Terraform の定義は同じ内容になる（切戻し後の `terraform plan` は No changes）。→ **切替は gcloud、通常時の定義は Terraform** という運用でもずれない。
- gcloud は `--routing-policy-backup-data` が非推奨だと警告する（`Use --routing-policy-backup-item instead.`）。設計書の手順は今は動くが、いずれ書き換えが必要。

### 5.2 切り替わるまでの時間

- 手動切替（`record-sets update`）は 3 秒で完了し、**GCE の VM からは約 1 秒後に新しい応答が返った**。VM はメタデータサーバ（169.254.169.254）に問い合わせていて、TTL のキャッシュの影響を受けなかった。
- オンプレの DNS など、キャッシュするリゾルバを経由する場合は、最大で TTL（30 秒）が加わる。

### 5.3 バックエンドが全滅しても、自動では切り替わらない

- 東京の MIG を 0 台にしても、**DNS は 6 分間ずっと東京を返し続けた**。クライアントには HTTP 503 が返った。
- Cloud DNS のヘルスチェックは ALB のプロキシ（Envoy）の状態を見ていて、バックエンドの状態は見ていない（設計書の注意点のとおり）。
- → **バックエンドの障害は、Cloud Monitoring（ALB の 5xx の割合や、バックエンドへのリクエスト数）で検知して、手動で切り替える**。手動切替の手順は必須。

### 5.4 `get-health` は、ドレインの間 HEALTHY を返す

- MIG を 0 台にすると、VM はすぐに振り分け先から外れる（30 秒以内に 503）。一方で、VM の削除は**接続ドレイン（既定 300 秒）が終わるまで行われず**、その間 `gcloud compute backend-services get-health` は `HEALTHY` を返し続けた。
- → `get-health` やバックエンドのヘルス状態だけでは、「振り分け先がない」状態を検知できない。
- サイズを 2 に戻すと、約 50 秒で HEALTHY になり、200 が返った。

## 6. 費用

- CAS の費用は **CA の数 × 階層の単価 × 課金される状態でいた時間 ＋ 発行枚数 × 単価** で決まる。「$200 / 月」は **CA 1 つあたり**（Enterprise）。今回の設計は CA 3 つなので約 $600 / 月。
- SKU 上は日額（$6.66 / CA / 日、Enterprise）で、秒単位で測定される（日割り）。料金ページの「per CA per month」は 30 日分の目安。
- ENABLED・STAGED・**DISABLED** は課金される。AWAITING_USER_ACTIVATION と、削除後の猶予期間中（DELETED）は課金されない。削除した CA を復元すると、削除していた期間の分も請求される。
- CA プールの数、ルートか下位か、リージョンは費用に関係しない。
- 今回の構成（CA 3 つ＋ALB 2 セット＋VM 6 台）は約 $1 / 時で、その 8 割以上が CA。
- 下位 CA の CA 証明書も、Enterprise では「発行した証明書」として記録される（課金対象として計算）。
- Certificate Manager の証明書は、100 枚まで無料。
- 詳細は [`COST.md`](COST.md)。

## 7. 検証作業の注意（再検証するとき）

- **`gcloud compute ssh` は、プロジェクト全体のメタデータ `ssh-keys` に公開鍵を追加する**。プロジェクトを変えたくないなら、鍵を VM のインスタンスメタデータに登録しておく（このディレクトリの `client_ssh_public_key` 変数）。
- 秘密鍵にパスフレーズがあり、ssh-agent がないと、対話できないシェル（自動実行）からは SSH できない。`ssh_askpass: exec(/usr/bin/ssh-askpass): No such file or directory` が出たら、これが原因。
- 外部 IP のない Debian 12 の VM に dig を入れるには、Cloud NAT が必要。業務サーバの代わりは、標準で入っている `python3 -m http.server` で足りる。
- gcloud で作った `neg-` のプロキシは `um-tokyo` を参照するので、**`terraform destroy` の前に削除しないと URL マップを削除できない**。
- 指示書の直すべき点：
  - T03：`--format` は `sslCertificates` にする。
  - N01・N02：API 直接か Terraform で確認する。
  - N06：証明書は短い名前で指定する。
  - T09・T10：`--routing-policy-backup-data` は非推奨。

## 8. HTTPS 接続のときの、ルート CA と下位 CA の役割

### 8.1 接続のときに起きること

1. ALB が TLS ハンドシェイクで、証明書のチェーンを送る。今回の ALB は、**サーバ証明書・下位 CA・ルート CA の 3 枚**を送っていた（Certificate Manager の `pemCertificate` に 3 枚入っていて、それがそのまま提示される）。
2. 端末は、**手元の情報だけで**検証する。
   - サーバ証明書の署名を、下位 CA の証明書に入っている公開鍵で確かめる。
   - 下位 CA の証明書の署名を、**端末の信頼ストアにあるルート CA の証明書**の公開鍵で確かめる。ALB が送ってきたルート証明書は信頼の根拠には使わない（端末が持っているものと照合されるだけ）。
   - 有効期限、SAN（test.sample.com が入っているか）、Basic Constraints（CA:TRUE / FALSE）などを確かめる。
3. **CAS には、端末も ALB もアクセスしない**。ALB は、Certificate Manager に保存済みの証明書を提示するだけ。

→ CAS が止まっても、既存の証明書による接続には影響しない（T12 でルート CA を無効にしても、TLS の検証は OK のままだった）。CAS が必要になるのは、証明書を発行・更新するときだけ。

| | ルート CA | 下位 CA |
|---|---|---|
| 接続のときの役割 | 信頼の起点（端末の信頼ストアに入れておく） | サーバ証明書の署名者 |
| 端末に入れておく必要 | **ある** | **ない**（ALB が送ってくる） |
| 接続のときに CA にアクセスするか | しない | しない |

### 8.2 端末がネットワークにアクセスしうる 2 つの場合

T12 で発行した証明書を `openssl x509 -text` で確認した結果：

| 拡張 | 今回の証明書 | 端末がアクセスするとき |
|---|---|---|
| 失効確認（CRL の配布場所、OCSP） | **入っていない** | なし |
| AIA（上位 CA の証明書の取得先） | **入っている**（`http://privateca-content-....storage.googleapis.com/.../ca.crt`） | サーバがチェーンを送らなかったときだけ |

- **失効確認**：CA プールで CRL の公開を無効にしている（`publish_crl = false`）ので、証明書に CRL の URL が入らない。CAS には OCSP もない。そのため端末は失効を確認しない。そのかわり、証明書を失効させても端末には伝わらないので、有効期間 30 日の短さで補う。
  - CRL を公開すると、証明書に**インターネット上の GCS の URL** が入る。インターネットに出られない端末では、失効確認の待ち時間や失敗が起きるおそれがある。
- **AIA**：CA 証明書の公開を有効にしている（`publish_ca_cert = true`）ので、インターネット上の GCS の URL が入る。ALB がチェーンを全部送るので、通常は使われない。一部の OS（Windows など）は、チェーンが足りないときにこの URL から取りに行く。不要なら `publish_ca_cert = false` にすれば、URL は入らない。

### 8.3 サーバ証明書に Key Usage / Extended Key Usage が入っていない（要確認）

Certificate Manager が発行したサーバ証明書の拡張は、次の 5 つだけだった。

```
X509v3 Basic Constraints: critical  CA:FALSE
X509v3 Subject Key Identifier
X509v3 Authority Key Identifier
Authority Information Access: CA Issuers - URI:http://privateca-content-....storage.googleapis.com/.../ca.crt
X509v3 Subject Alternative Name: DNS:drtest2.sample.com
```

- **Key Usage と Extended Key Usage（serverAuth）がない**。CA プールに発行ポリシー（`issuance_policy`）を設定しなかったため。
- openssl と curl では、問題なく検証できた。
- **未確認**：記憶では、Apple のプラットフォーム（macOS / iOS）は TLS サーバ証明書に EKU の serverAuth を必須にしている。そうであれば、Apple の端末では接続エラーになる可能性がある。Windows や各ブラウザでの動作も、今回は確かめていない。
- 対策の候補：下位 CA プールの `issuance_policy.baseline_values` で、`extended_key_usage.server_auth = true` と `key_usage.base_key_usage.digital_signature = true`（RSA 鍵なら `key_encipherment` も）を付ける。**設計書にはない設定**なので、実際の端末で確かめてから設計に入れる。

## 9. 端末に配るのは「ルート CA の証明書」だけ（鍵は配らない）

### 9.1 配るもの

| 配るもの | 中身 | 秘密か |
|---|---|---|
| **ルート CA の証明書**（`root.pem`） | ルート CA の名前・公開鍵・有効期間と、それ自身による署名 | 秘密ではない（公開してよい） |

- 取り出し方：`gcloud privateca roots describe root-ca --pool=root-pool --location=asia-northeast1 --format="value(pemCaCertificates)" > root.pem`。今回の検証でクライアント VM に置いた `/tmp/root.pem`（741 バイト）が、これ。
- 配り方：GPO や MDM で、端末の「信頼されたルート証明機関」に入れる。
- **秘密鍵は配らない（そもそも取り出せない）**。CA の秘密鍵は CAS の中（Google が管理する鍵）にあり、取り出す API はない。端末が検証に使うのは、証明書に入っている**公開鍵**だけ。秘密鍵は署名する側（CAS）だけが使う。

### 9.2 下位 CA（中間 CA）の証明書を配らなくてよい理由

1. **サーバが毎回送ってくる**：ALB は、TLS ハンドシェイクでサーバ証明書と一緒に下位 CA の証明書を送る（今回は 3 枚のチェーン）。端末は受け取ったものを使って、チェーンを組み立てる。
2. **下位 CA の正しさは、ルート CA の署名で証明される**：下位 CA の証明書には、ルート CA の秘密鍵による署名が付いている。端末は、信頼ストアにあるルート CA の公開鍵でこの署名を確かめれば、「この下位 CA はルート CA が認めたもの」と分かる。下位 CA をあらかじめ信頼しておく必要はない。
3. **信頼の起点を 1 つにしておけば、下位 CA を変えても端末は変えなくてよい**：

| 起きること | 端末側の作業 |
|---|---|
| 東京から大阪に切り替える（提示される下位 CA が東京 → 大阪に変わる） | なし（T09 で確認） |
| 下位 CA を入れ替える（5 年ごと） | なし |
| 別のリージョンに下位 CA を追加する | なし |
| ルート CA を入れ替える（10 年ごと） | **新しいルート証明書を配る必要がある** |

- 逆に、下位 CA の証明書を信頼の起点として端末に配ってしまうと、下位 CA を入れ替えるたびに配り直しが必要になり、「1 つのルートで両方のリージョンを検証できる」利点も失われる。
- **注意**：サーバがチェーンを送らない設定だと、端末は下位 CA の証明書を持っていないので検証に失敗する（AIA で取りに行ける OS もあるが、今回の AIA はインターネット上の URL）。ALB に Certificate Manager の証明書を設定すると、チェーンは自動で付くので、今回の構成では問題にならない。

## 10. 東京が被災したとき、いつまでに復旧すれば大阪に影響が出ないか

### 10.1 証明書の面：期限は「大阪の下位 CA の有効期限」だけ

| 要素 | 東京が使えないときの影響 | 期限 |
|---|---|---|
| 大阪のサーバ証明書（30 日） | 大阪の下位 CA が自動更新を続ける（T12 で、ルート CA が無効でも発行できることを確認） | なし |
| **大阪の下位 CA**（5 年。今回作ったものは 2026-11-28 〜 **2031-11-27**） | 作り直しにはルート CA（東京）が必要 | **この有効期限より前に、東京が復旧している必要がある** |
| ルート CA（10 年。今回は 2026-11-28 〜 2036-11-25） | 期限まで信頼の起点として有効 | 被災とは関係ない |
| 端末の信頼ストア | 変更不要 | なし |

```
実際の期限 ＝ 大阪の下位 CA の有効期限
            −（新しい下位 CA を作って入れ替える作業の期間）
            − サーバ証明書の有効期間（30 日）
```

- 下位 CA を作った直後の被災なら、期限は約 5 年先で、事実上問題にならない。
- 危ないのは、**下位 CA の期限が近い時期の被災**。たとえば残り 3 か月で被災すると、その間に東京が戻らないと、大阪の証明書を更新できなくなる。
- 未確認：下位 CA の期限が近いとき、新しく発行される証明書の有効期限がどう扱われるか（下位 CA の期限で切り詰められるのか、エラーになるのか）。
- 対策：下位 CA を**余裕をもって入れ替える**（例：残り 2〜3 年で入れ替える）。そうすれば、どの時期に被災しても数年の猶予が残る。

### 10.2 条件付きで期限が生まれるもの

- **CRL を公開する設定にした場合**：ルート CA が出す CRL には有効期限がある。東京が止まると CRL を更新できなくなり、期限が切れた後は、失効確認をする端末で、大阪の下位 CA の検証に失敗するおそれがある。今回の構成は CRL を公開していない（`publish_crl = false`）ので該当しない。
- **AIA**：大阪の下位 CA の証明書に入っている AIA の URL は、ルート CA 側の公開バケットを指している（そのバケットのリージョンは未確認）。ALB がチェーンを全部送っているので、通常は使われない。

### 10.3 切替の作業が東京に依存している点（未検証）

- **設計書の切替コマンド**は、`--routing-policy-backup-data="asia-northeast1=fr-tokyo@asia-northeast1"` のように**東京の転送ルールを名前で指定**している。gcloud はこの名前から IP やネットワークを調べるために、東京の Compute API を呼んでいると考えられる。東京の API が応答しないと、**手動切替のコマンド自体が失敗する**おそれがある。
  - 対策の候補：東京を含めない（大阪だけをプライマリにする）切替手順を用意しておく。IP などの値を直接書いた Cloud DNS API や Terraform で切り替える方法もある。
- **Terraform の state**：今回の state は東京と大阪で 1 つ。plan で全リソースの状態を読み直すので、東京の API が応答しないと、大阪だけを変えたいときも plan や apply が失敗する。
  - 対策の候補：リージョンごとに state を分ける、または災害時の操作は gcloud で行う手順にする。
- リージョン障害は再現できないので、確かめるなら「東京の転送ルールを指定しないコマンドで切り替えられるか」を試す形になる。
