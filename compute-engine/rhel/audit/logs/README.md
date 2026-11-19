# logs/

検証で取得したログの置き場所です。**このディレクトリの中身は Git 管理外**です（`.gitignore` で `README.md` と `.gitignore` 以外を除外）。外部 IP・ホスト名・auid などが含まれるためです。

```
logs/
└── <RUN>/                       # 例: 20261119T1430Z（実行ごとに作成）
    ├── 00-env.txt               # OS / auditd のバージョン、auditd の状態
    ├── 01-check.txt             # 修正要否の確認
    ├── 02-read-test-before.txt  # 変更前の r 操作テスト
    ├── 03-backup.txt            # バックアップ
    ├── 04-edit.txt              # 設定の変更と差分
    ├── 05-load.txt              # 反映
    ├── 06-static-check.txt      # 反映後の静的確認
    ├── 07-read-test-after.txt   # 変更後の r 操作テスト（記録されないこと）
    ├── 08-other-rules-test.txt  # w/a と shadow の r が引き続き記録されること
    └── 99-rollback.txt          # （実施した場合のみ）切り戻し
```

取得方法は [`../README.md`](../README.md) の「4. 検証手順」を参照してください。
