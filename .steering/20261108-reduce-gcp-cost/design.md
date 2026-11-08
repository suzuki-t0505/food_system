# 設計

- `infra/terraform/lb.tf`: `http_redirect` の url_map / `target_http_proxy` / HTTP 用 `global_forwarding_rule` を削除。静的 IP は 443 で使うため残す
- `infra/terraform/variables.tf`・`terraform.tfvars.example`: `db_tier` を `db-f1-micro` にする。`sql.tf`(ENTERPRISE)は変更なし
- 不足時は `db_tier` を `db-g1-small` / `db-custom-1-3840` へ戻す(変数のみ)。apply 済み環境では tier 変更で再起動が入る
- ドキュメント: `docs/architecture.md`、`.steering/20261105-gcp-terraform/`、`infra/terraform/README.md`
