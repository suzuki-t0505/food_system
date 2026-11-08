# 要求: GCP 月額コストの削減

- HTTP:80 の HTTPS リダイレクト(URL マップ・HTTP プロキシ・転送ルール)を削除する(約 -18 ドル/月)
- Cloud SQL を共有コアの最小 tier `db-f1-micro` にする(約 -30〜40 ドル/月)
- 影響: `http://` では接続できない。`db-f1-micro` は SLA 対象外・約 0.6GB RAM・接続数が少ない
