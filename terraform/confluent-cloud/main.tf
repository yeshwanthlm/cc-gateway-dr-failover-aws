terraform {
  required_version = ">= 1.0"
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}

# Environment for the clusters with Stream Governance (Schema Registry)
resource "confluent_environment" "main" {
  display_name = var.environment_name

  # Enable Stream Governance (Schema Registry) - Advanced Package
  stream_governance {
    package = "ADVANCED"
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Primary AWS Cluster (us-east-1) - Standard type
resource "confluent_kafka_cluster" "primary_cluster" {
  display_name = var.primary_cluster_name
  availability = var.availability
  cloud        = "AWS"
  region       = var.primary_cluster_region

  standard {}

  environment {
    id = confluent_environment.main.id
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Service Account for Primary Cluster
resource "confluent_service_account" "primary_cluster_manager" {
  display_name = "${var.primary_cluster_name}-manager"
  description  = "Service account for primary AWS cluster management"
}

# API Key for Primary Cluster
# IMPORTANT: Created AFTER role binding so it inherits CloudClusterAdmin permissions
resource "confluent_api_key" "primary_cluster_api_key" {
  display_name = "${var.primary_cluster_name}-api-key"
  description  = "API Key for primary AWS Kafka cluster with CloudClusterAdmin role"
  owner {
    id          = confluent_service_account.primary_cluster_manager.id
    api_version = confluent_service_account.primary_cluster_manager.api_version
    kind        = confluent_service_account.primary_cluster_manager.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.primary_cluster.id
    api_version = confluent_kafka_cluster.primary_cluster.api_version
    kind        = confluent_kafka_cluster.primary_cluster.kind

    environment {
      id = confluent_environment.main.id
    }
  }

  # Wait for role binding to be created first
  depends_on = [
    confluent_role_binding.primary_cluster_admin
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# DR AWS Cluster (us-west-2) - Dedicated type
resource "confluent_kafka_cluster" "dr_cluster" {
  display_name = var.dr_cluster_name
  availability = var.availability
  cloud        = "AWS"
  region       = var.dr_cluster_region

  dedicated {
    cku = 1
  }

  environment {
    id = confluent_environment.main.id
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Service Account for DR Cluster
resource "confluent_service_account" "dr_cluster_manager" {
  display_name = "${var.dr_cluster_name}-manager"
  description  = "Service account for DR AWS cluster management"
}

# API Key for DR Cluster
# IMPORTANT: Created AFTER role binding so it inherits CloudClusterAdmin permissions
resource "confluent_api_key" "dr_cluster_api_key" {
  display_name = "${var.dr_cluster_name}-api-key"
  description  = "API Key for DR AWS Kafka cluster with CloudClusterAdmin role"
  owner {
    id          = confluent_service_account.dr_cluster_manager.id
    api_version = confluent_service_account.dr_cluster_manager.api_version
    kind        = confluent_service_account.dr_cluster_manager.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.dr_cluster.id
    api_version = confluent_kafka_cluster.dr_cluster.api_version
    kind        = confluent_kafka_cluster.dr_cluster.kind

    environment {
      id = confluent_environment.main.id
    }
  }

  # Wait for role binding to be created first
  depends_on = [
    confluent_role_binding.dr_cluster_admin
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# Poll for Schema Registry availability after environment creation
# Schema Registry provisioning is asynchronous - this polls until it's ready
resource "null_resource" "wait_for_schema_registry" {
  depends_on = [confluent_environment.main]

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -e
      echo "Waiting for Schema Registry to be provisioned in environment ${confluent_environment.main.id}..."

      # Poll for up to 5 minutes (60 attempts, 5 seconds apart)
      for i in {1..60}; do
        echo "Attempt $i/60: Checking if Schema Registry is available..."

        # Use Confluent Cloud API to check if Schema Registry exists
        RESPONSE=$(curl -s -u "${var.confluent_cloud_api_key}:${var.confluent_cloud_api_secret}" \
          "https://api.confluent.cloud/srcm/v3/clusters?environment=${confluent_environment.main.id}" || echo "")

        # Check if response contains a Schema Registry cluster
        if echo "$RESPONSE" | grep -q "lsrc-"; then
          echo "✓ Schema Registry is ready!"
          exit 0
        fi

        if [ $i -lt 60 ]; then
          echo "Schema Registry not yet available, waiting 5 seconds..."
          sleep 5
        fi
      done

      echo "ERROR: Schema Registry did not become available within 5 minutes"
      exit 1
    EOT

    interpreter = ["bash", "-c"]
  }

  triggers = {
    environment_id = confluent_environment.main.id
  }
}

# Schema Registry Cluster - Data Source
# Schema Registry is automatically enabled via the environment's stream_governance block
# This data source retrieves the Schema Registry cluster details
data "confluent_schema_registry_cluster" "main" {
  environment {
    id = confluent_environment.main.id
  }

  # Wait for Schema Registry to be available before reading
  depends_on = [
    confluent_environment.main,
    null_resource.wait_for_schema_registry
  ]
}

# Service Account for Schema Registry
resource "confluent_service_account" "schema_registry_manager" {
  display_name = "schema-registry-manager"
  description  = "Service account for Schema Registry management"
}

# API Key for Schema Registry
resource "confluent_api_key" "schema_registry_api_key" {
  display_name = "schema-registry-api-key"
  description  = "API Key for Schema Registry"
  owner {
    id          = confluent_service_account.schema_registry_manager.id
    api_version = confluent_service_account.schema_registry_manager.api_version
    kind        = confluent_service_account.schema_registry_manager.kind
  }

  managed_resource {
    id          = data.confluent_schema_registry_cluster.main.id
    api_version = data.confluent_schema_registry_cluster.main.api_version
    kind        = data.confluent_schema_registry_cluster.main.kind

    environment {
      id = confluent_environment.main.id
    }
  }

  # Wait for role binding and schema registry to be available
  depends_on = [
    confluent_role_binding.schema_registry_resource_owner,
    data.confluent_schema_registry_cluster.main
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# =============================================================================
# Topic Creation
# =============================================================================

# test_topic on Primary Cluster
resource "confluent_kafka_topic" "test_topic_primary" {
  kafka_cluster {
    id = confluent_kafka_cluster.primary_cluster.id
  }

  topic_name         = "test_topic"
  partitions_count   = 3
  rest_endpoint      = confluent_kafka_cluster.primary_cluster.rest_endpoint
  config = {
    "cleanup.policy"    = "delete"
    "retention.ms"      = "604800000"  # 7 days
    "segment.ms"        = "86400000"   # 1 day
  }

  credentials {
    key    = confluent_api_key.primary_cluster_api_key.id
    secret = confluent_api_key.primary_cluster_api_key.secret
  }

  depends_on = [
    confluent_api_key.primary_cluster_api_key
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# test_topic on DR Cluster (regular topic, NOT a mirror)
# This allows direct writes to DR cluster for testing and failover scenarios
resource "confluent_kafka_topic" "test_topic_dr" {
  kafka_cluster {
    id = confluent_kafka_cluster.dr_cluster.id
  }

  topic_name         = "test_topic"
  partitions_count   = 3
  rest_endpoint      = confluent_kafka_cluster.dr_cluster.rest_endpoint
  config = {
    "cleanup.policy"    = "delete"
    "retention.ms"      = "604800000"  # 7 days
    "segment.ms"        = "86400000"   # 1 day
  }

  credentials {
    key    = confluent_api_key.dr_cluster_api_key.id
    secret = confluent_api_key.dr_cluster_api_key.secret
  }

  depends_on = [
    confluent_api_key.dr_cluster_api_key
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# =============================================================================
# Cluster Linking Configuration
# =============================================================================
# Cluster Link from Primary (Standard) to DR (Dedicated) cluster
# This enables disaster recovery and data replication

# Service Account for Cluster Link on DR side
resource "confluent_service_account" "cluster_link_dr" {
  display_name = "cluster-link-dr-sa"
  description  = "Service account for cluster link on DR cluster"
}

# Grant CloudClusterAdmin role to cluster link service account on DR cluster
resource "confluent_role_binding" "cluster_link_dr_admin" {
  principal   = "User:${confluent_service_account.cluster_link_dr.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.dr_cluster.rbac_crn
}

# API Key for Cluster Link on DR Cluster
resource "confluent_api_key" "cluster_link_dr_api_key" {
  display_name = "cluster-link-dr-api-key"
  description  = "API Key for cluster link on DR cluster"

  owner {
    id          = confluent_service_account.cluster_link_dr.id
    api_version = confluent_service_account.cluster_link_dr.api_version
    kind        = confluent_service_account.cluster_link_dr.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.dr_cluster.id
    api_version = confluent_kafka_cluster.dr_cluster.api_version
    kind        = confluent_kafka_cluster.dr_cluster.kind

    environment {
      id = confluent_environment.main.id
    }
  }

  depends_on = [
    confluent_role_binding.cluster_link_dr_admin
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# Cluster Link: Primary -> DR
resource "confluent_cluster_link" "primary_to_dr" {
  link_name = "primary-to-dr-link"
  link_mode = "DESTINATION"

  connection_mode = "OUTBOUND"

  source_kafka_cluster {
    id                 = confluent_kafka_cluster.primary_cluster.id
    bootstrap_endpoint = confluent_kafka_cluster.primary_cluster.bootstrap_endpoint
    credentials {
      key    = confluent_api_key.primary_cluster_api_key.id
      secret = confluent_api_key.primary_cluster_api_key.secret
    }
  }

  destination_kafka_cluster {
    id            = confluent_kafka_cluster.dr_cluster.id
    rest_endpoint = confluent_kafka_cluster.dr_cluster.rest_endpoint
    credentials {
      key    = confluent_api_key.cluster_link_dr_api_key.id
      secret = confluent_api_key.cluster_link_dr_api_key.secret
    }
  }

  depends_on = [
    confluent_kafka_topic.test_topic_primary,
    confluent_api_key.primary_cluster_api_key,
    confluent_api_key.cluster_link_dr_api_key
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# mirrored_topic on Primary Cluster (source for mirroring)
# This topic will be replicated to DR cluster via cluster linking
resource "confluent_kafka_topic" "mirrored_topic_primary" {
  kafka_cluster {
    id = confluent_kafka_cluster.primary_cluster.id
  }

  topic_name         = "mirrored_topic"
  partitions_count   = 3
  rest_endpoint      = confluent_kafka_cluster.primary_cluster.rest_endpoint
  config = {
    "cleanup.policy"    = "delete"
    "retention.ms"      = "604800000"  # 7 days
    "segment.ms"        = "86400000"   # 1 day
  }

  credentials {
    key    = confluent_api_key.primary_cluster_api_key.id
    secret = confluent_api_key.primary_cluster_api_key.secret
  }

  depends_on = [
    confluent_api_key.primary_cluster_api_key
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# Mirror Topic: mirrored_topic from Primary to DR
# This demonstrates cluster linking with automatic replication
# Note: Mirror topics are read-only on the destination cluster
resource "confluent_kafka_mirror_topic" "mirrored_topic_mirror" {
  source_kafka_topic {
    topic_name = "mirrored_topic"
  }

  cluster_link {
    link_name = confluent_cluster_link.primary_to_dr.link_name
  }

  kafka_cluster {
    id            = confluent_kafka_cluster.dr_cluster.id
    rest_endpoint = confluent_kafka_cluster.dr_cluster.rest_endpoint
    credentials {
      key    = confluent_api_key.cluster_link_dr_api_key.id
      secret = confluent_api_key.cluster_link_dr_api_key.secret
    }
  }

  depends_on = [
    confluent_cluster_link.primary_to_dr,
    confluent_kafka_topic.mirrored_topic_primary
  ]

  lifecycle {
    prevent_destroy = false
  }
}

