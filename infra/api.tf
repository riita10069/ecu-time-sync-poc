data "aws_route53_zone" "main" {
  name         = var.zone_name
  private_zone = false
}

# --- Lambda: 認可と NTS-KE (Fixed Key Request) ---
data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/../out/aws/lambda.zip"
  source {
    filename = "handler.py"
    content  = file("${path.module}/../lambda/handler.py")
  }
  source {
    filename = "nts.py"
    content  = file("${path.module}/../app/nts.py")
  }
  source {
    filename = "nts-ke-ca.pem"
    content  = tls_self_signed_cert.ke_ca.cert_pem
  }
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_secret" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [aws_secretsmanager_secret.pool_token.arn] }]
  })
}

resource "aws_lambda_function" "creds" {
  function_name    = "${var.name}-nts-credentials"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10
  vpc_config {
    subnet_ids         = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.lambda.id]
  }
  environment {
    variables = {
      KE_HOST          = aws_lb.internal.dns_name
      KE_SNI           = local.ke_sni
      NTP_HOST         = local.fqdn_ntp
      TOKEN_SECRET_ARN = aws_secretsmanager_secret.pool_token.arn
      ALLOWED_VEHICLES = join(",", var.allowed_vehicles)
    }
  }
}

# --- API Gateway (HTTP API) + カスタムドメイン mTLS ---
resource "aws_acm_certificate" "api" {
  domain_name       = local.fqdn_api
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "api_validation" {
  for_each = { for o in aws_acm_certificate.api.domain_validation_options : o.domain_name => o }
  zone_id  = data.aws_route53_zone.main.zone_id
  name     = each.value.resource_record_name
  type     = each.value.resource_record_type
  records  = [each.value.resource_record_value]
  ttl      = 60
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for r in aws_route53_record.api_validation : r.fqdn]
}

resource "aws_apigatewayv2_api" "main" {
  name          = var.name
  protocol_type = "HTTP"
  # mTLS を迂回できないよう、既定の execute-api エンドポイントを無効にする
  disable_execute_api_endpoint = true
}

resource "aws_apigatewayv2_integration" "creds" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.creds.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "creds" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /nts-credentials"
  target    = "integrations/${aws_apigatewayv2_integration.creds.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "apigw"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.creds.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_apigatewayv2_domain_name" "api" {
  domain_name = local.fqdn_api
  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
  mutual_tls_authentication {
    truststore_uri     = "s3://${aws_s3_bucket.truststore.id}/${aws_s3_object.truststore.key}"
    truststore_version = aws_s3_object.truststore.version_id
  }
}

resource "aws_apigatewayv2_api_mapping" "api" {
  api_id      = aws_apigatewayv2_api.main.id
  domain_name = aws_apigatewayv2_domain_name.api.id
  stage       = aws_apigatewayv2_stage.default.id
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.fqdn_api
  type    = "A"
  alias {
    name                   = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "ntp" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.fqdn_ntp
  type    = "A"
  alias {
    name                   = aws_lb.public.dns_name
    zone_id                = aws_lb.public.zone_id
    evaluate_target_health = true
  }
}
