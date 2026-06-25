output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC ID for the EKS cluster"
  value       = module.vpc.vpc_id
}

output "configure_kubectl" {
  description = "Configure kubectl: run the following command to update your kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

# -----------------------------------------------------------------------------
# Route53 / Gateway DNS Outputs
# -----------------------------------------------------------------------------
output "route53_zone_id" {
  description = "Route53 private hosted zone ID for the gateway"
  value       = aws_route53_zone.gateway.zone_id
}

output "dns_zone_name" {
  description = "Route53 private hosted zone name"
  value       = aws_route53_zone.gateway.name
}

output "gateway_fqdn" {
  description = "Fully qualified domain name for the gateway"
  value       = "${var.gateway_dns_record_name}.${var.dns_zone_name}"
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = <<-EOT

    ╔════════════════════════════════════════════════════════════════╗
    ║  Update your kubeconfig with the following command:             ║
    ╠════════════════════════════════════════════════════════════════╣
    ║  aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}
    ╚════════════════════════════════════════════════════════════════╝

  EOT
}

output "dns_update_command" {
  description = "Command to create the gateway DNS record after the LoadBalancer is created"
  value       = <<-EOT

    ╔════════════════════════════════════════════════════════════════╗
    ║  After the gateway LoadBalancer is created, point the record:   ║
    ╠════════════════════════════════════════════════════════════════╣
    ║  1. Get the LoadBalancer hostname:                             ║
    ║     kubectl get svc confluent-gateway-bootstrap-lb -n confluent \
    ║       -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' ║
    ║                                                                 ║
    ║  2. Upsert a CNAME record in zone ${aws_route53_zone.gateway.zone_id}:
    ║     ${var.gateway_dns_record_name}.${var.dns_zone_name} -> <LB_HOSTNAME>
    ╚════════════════════════════════════════════════════════════════╝

  EOT
}
