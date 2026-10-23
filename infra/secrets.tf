# Lambda と ntpd-rs だけが知る NTS pool 拡張のトークン
resource "random_password" "pool_token" {
  length  = 43
  special = false
}

resource "aws_secretsmanager_secret" "pool_token" {
  name                    = "${var.name}/pool-token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "pool_token" {
  secret_id     = aws_secretsmanager_secret.pool_token.id
  secret_string = random_password.pool_token.result
}

# 全タスクで共有する cookie のマスター鍵 (ntpd-rs の keyset ファイルを base64 にしたもの)。
# ローテーションは scripts/aws-rotate-keyset.sh で新しい version を入れてローリングデプロイする
data "external" "initial_keyset" {
  program = ["${path.module}/gen-keyset.sh"]
}

resource "aws_secretsmanager_secret" "keyset" {
  name                    = "${var.name}/ntpd-keyset"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "keyset" {
  secret_id     = aws_secretsmanager_secret.keyset.id
  secret_string = data.external.initial_keyset.result.b64
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# NTS-KE (内部) のサーバー証明書。Lambda だけがこの CA を信頼する
resource "tls_private_key" "ke_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ke_ca" {
  private_key_pem       = tls_private_key.ke_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 30
  allowed_uses          = ["cert_signing", "crl_signing"]
  subject { common_name = "${var.name} NTS-KE CA" }
}

resource "tls_private_key" "ke" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "ke" {
  private_key_pem = tls_private_key.ke.private_key_pem
  dns_names       = [local.ke_sni]
  subject { common_name = local.ke_sni }
}

resource "tls_locally_signed_cert" "ke" {
  cert_request_pem      = tls_cert_request.ke.cert_request_pem
  ca_private_key_pem    = tls_private_key.ke_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ke_ca.cert_pem
  validity_period_hours = 24 * 7
  allowed_uses          = ["digital_signature", "server_auth"]
}

resource "aws_secretsmanager_secret" "ke_cert" {
  name                    = "${var.name}/nts-ke-cert"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ke_cert" {
  secret_id     = aws_secretsmanager_secret.ke_cert.id
  secret_string = tls_locally_signed_cert.ke.cert_pem
}

resource "aws_secretsmanager_secret" "ke_key" {
  name                    = "${var.name}/nts-ke-key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ke_key" {
  secret_id     = aws_secretsmanager_secret.ke_key.id
  secret_string = tls_private_key.ke.private_key_pem_pkcs8
}
