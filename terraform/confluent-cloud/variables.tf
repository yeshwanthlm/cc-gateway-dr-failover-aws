variable "confluent_cloud_api_key" {
  description = "Confluent Cloud API Key (also referred as Cloud API ID)"
  type        = string
  sensitive   = true
}

variable "confluent_cloud_api_secret" {
  description = "Confluent Cloud API Secret"
  type        = string
  sensitive   = true
}

variable "environment_name" {
  description = "Confluent Cloud Environment Name"
  type        = string
  default     = "cc-gateway-demo-aws"
}

variable "primary_cluster_name" {
  description = "Name for the Primary AWS Kafka cluster"
  type        = string
  default     = "aws-useast1-primary"
}

variable "primary_cluster_region" {
  description = "AWS region for the Primary Kafka cluster"
  type        = string
  default     = "us-east-1"
}

variable "dr_cluster_name" {
  description = "Name for the DR AWS Kafka cluster"
  type        = string
  default     = "aws-uswest2-dr"
}

variable "dr_cluster_region" {
  description = "AWS region for the DR Kafka cluster"
  type        = string
  default     = "us-west-2"
}

variable "availability" {
  description = "Availability zone configuration (SINGLE_ZONE or MULTI_ZONE)"
  type        = string
  default     = "SINGLE_ZONE"
}
