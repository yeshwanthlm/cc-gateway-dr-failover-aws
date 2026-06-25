terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC for EKS
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    main = {
      min_size     = 2
      max_size     = 2
      desired_size = 2

      instance_types = [var.instance_type]
      capacity_type  = "ON_DEMAND"
    }
  }

  enable_cluster_creator_admin_permissions = true
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# -----------------------------------------------------------------------------
# Route53 Private Hosted Zone for the Gateway
# -----------------------------------------------------------------------------
# A private hosted zone associated with the EKS VPC so that in-cluster pods
# (e.g. kafka-tools) can resolve the gateway domain (kafka.cc.axa.com).
# The actual record pointing at the gateway LoadBalancer is created/updated by
# deploy.sh after the Confluent Gateway provisions its NLB.
resource "aws_route53_zone" "gateway" {
  name = var.dns_zone_name

  vpc {
    vpc_id = module.vpc.vpc_id
  }

  comment = "Private hosted zone for Confluent Gateway (${var.cluster_name})"

  tags = {
    Environment = "demo"
    Project     = "confluent-gateway"
  }
}
