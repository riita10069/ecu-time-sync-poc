# 車両 PKI の代役。本番では既存の車両証明書の CA を truststore に入れる。
# PoC のため秘密鍵が Terraform state に入る点に注意
resource "tls_private_key" "vehicle_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "vehicle_ca" {
  private_key_pem       = tls_private_key.vehicle_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 30
  allowed_uses          = ["cert_signing", "crl_signing"]
  subject { common_name = "${var.name} Vehicle CA" }
}

# VIN001 は台帳にある車両、VIN999 は証明書は正規だが台帳にない車両
resource "tls_private_key" "vehicle" {
  for_each    = toset(["VIN001", "VIN999"])
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "vehicle" {
  for_each        = tls_private_key.vehicle
  private_key_pem = each.value.private_key_pem
  subject { common_name = each.key }
}

resource "tls_locally_signed_cert" "vehicle" {
  for_each              = tls_cert_request.vehicle
  cert_request_pem      = each.value.cert_request_pem
  ca_private_key_pem    = tls_private_key.vehicle_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.vehicle_ca.cert_pem
  validity_period_hours = 24 * 7
  allowed_uses          = ["digital_signature", "client_auth"]
}

resource "local_sensitive_file" "vehicle_cert" {
  for_each        = tls_locally_signed_cert.vehicle
  filename        = "${path.module}/../out/aws/${each.key}.pem"
  content         = each.value.cert_pem
  file_permission = "0600"
}

resource "local_sensitive_file" "vehicle_key" {
  for_each        = tls_private_key.vehicle
  filename        = "${path.module}/../out/aws/${each.key}.key"
  content         = each.value.private_key_pem
  file_permission = "0600"
}

# API Gateway mTLS の truststore。非公開バケット
resource "aws_s3_bucket" "truststore" {
  bucket_prefix = "${var.name}-truststore-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "truststore" {
  bucket                  = aws_s3_bucket.truststore.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "truststore" {
  bucket = aws_s3_bucket.truststore.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_object" "truststore" {
  bucket     = aws_s3_bucket.truststore.id
  key        = "truststore.pem"
  content    = tls_self_signed_cert.vehicle_ca.cert_pem
  depends_on = [aws_s3_bucket_versioning.truststore]
}
