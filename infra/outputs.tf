output "api_url" { value = "https://${local.fqdn_api}/nts-credentials" }
output "ntp_host" { value = local.fqdn_ntp }
output "ecr_repository" { value = aws_ecr_repository.app.repository_url }
output "cluster" { value = aws_ecs_cluster.main.name }
output "service" { value = aws_ecs_service.time.name }
output "keyset_secret_arn" { value = aws_secretsmanager_secret.keyset.arn }
output "ntp_target_group_arn" { value = aws_lb_target_group.ntp.arn }
output "ke_target_group_arn" { value = aws_lb_target_group.ke.arn }
output "private_route_table_ids" { value = { for k, v in aws_route_table.private : k => v.id } }
output "nat_gateway_ids" { value = { for k, v in aws_nat_gateway.main : k => v.id } }
output "public_nlb_dns" { value = aws_lb.public.dns_name }
output "internal_nlb_dns" { value = aws_lb.internal.dns_name }
