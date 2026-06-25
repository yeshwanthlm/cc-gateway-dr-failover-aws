variable "aws_region" {
  description = "AWS region for the EKS cluster"
  type        = string
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "cc-gateway-eks"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.large"
}

variable "dns_zone_name" {
  description = "Route53 private hosted zone name for the gateway"
  type        = string
  default     = "axa.com"
}

variable "gateway_dns_record_name" {
  description = "DNS record name for the gateway (e.g., kafka.cc for kafka.cc.axa.com)"
  type        = string
  default     = "kafka.cc"
}
