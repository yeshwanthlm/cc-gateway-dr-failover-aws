output "environment_id" {
  description = "Confluent Cloud Environment ID"
  value       = confluent_environment.main.id
}

output "primary_cluster_id" {
  description = "Primary AWS Kafka Cluster ID"
  value       = confluent_kafka_cluster.primary_cluster.id
}

output "primary_cluster_bootstrap_endpoint" {
  description = "Primary AWS Kafka Cluster Bootstrap Endpoint"
  value       = confluent_kafka_cluster.primary_cluster.bootstrap_endpoint
}

output "primary_cluster_rest_endpoint" {
  description = "Primary AWS Kafka Cluster REST Endpoint"
  value       = confluent_kafka_cluster.primary_cluster.rest_endpoint
}

output "primary_cluster_api_key" {
  description = "Primary AWS Kafka Cluster API Key"
  value       = confluent_api_key.primary_cluster_api_key.id
  sensitive   = true
}

output "primary_cluster_api_secret" {
  description = "Primary AWS Kafka Cluster API Secret"
  value       = confluent_api_key.primary_cluster_api_key.secret
  sensitive   = true
}

output "dr_cluster_id" {
  description = "DR AWS Kafka Cluster ID"
  value       = confluent_kafka_cluster.dr_cluster.id
}

output "dr_cluster_bootstrap_endpoint" {
  description = "DR AWS Kafka Cluster Bootstrap Endpoint"
  value       = confluent_kafka_cluster.dr_cluster.bootstrap_endpoint
}

output "dr_cluster_rest_endpoint" {
  description = "DR AWS Kafka Cluster REST Endpoint"
  value       = confluent_kafka_cluster.dr_cluster.rest_endpoint
}

output "dr_cluster_api_key" {
  description = "DR AWS Kafka Cluster API Key"
  value       = confluent_api_key.dr_cluster_api_key.id
  sensitive   = true
}

output "dr_cluster_api_secret" {
  description = "DR AWS Kafka Cluster API Secret"
  value       = confluent_api_key.dr_cluster_api_key.secret
  sensitive   = true
}

output "connection_details" {
  description = "Connection details for both clusters"
  value = {
    primary_cluster = {
      cluster_id        = confluent_kafka_cluster.primary_cluster.id
      bootstrap_servers = confluent_kafka_cluster.primary_cluster.bootstrap_endpoint
      rest_endpoint     = confluent_kafka_cluster.primary_cluster.rest_endpoint
      region            = var.primary_cluster_region
      cloud             = "AWS"
    }
    dr_cluster = {
      cluster_id        = confluent_kafka_cluster.dr_cluster.id
      bootstrap_servers = confluent_kafka_cluster.dr_cluster.bootstrap_endpoint
      rest_endpoint     = confluent_kafka_cluster.dr_cluster.rest_endpoint
      region            = var.dr_cluster_region
      cloud             = "AWS"
    }
  }
}

# Service Account IDs (needed for creating ACLs)
output "primary_service_account_id" {
  description = "Primary cluster service account ID (for ACL creation)"
  value       = confluent_service_account.primary_cluster_manager.id
}

output "dr_service_account_id" {
  description = "DR cluster service account ID (for ACL creation)"
  value       = confluent_service_account.dr_cluster_manager.id
}

# Schema Registry Outputs
output "schema_registry_id" {
  description = "Schema Registry Cluster ID"
  value       = data.confluent_schema_registry_cluster.main.id
}

output "schema_registry_endpoint" {
  description = "Schema Registry REST Endpoint (Public)"
  value       = data.confluent_schema_registry_cluster.main.rest_endpoint
}

output "schema_registry_api_key" {
  description = "Schema Registry API Key"
  value       = confluent_api_key.schema_registry_api_key.id
  sensitive   = true
}

output "schema_registry_api_secret" {
  description = "Schema Registry API Secret"
  value       = confluent_api_key.schema_registry_api_key.secret
  sensitive   = true
}

output "schema_registry_service_account_id" {
  description = "Schema Registry service account ID"
  value       = confluent_service_account.schema_registry_manager.id
}

output "bootstrap_instructions" {
  description = "One-time bootstrap instructions for Terraform automation"
  value       = <<-EOT

    ╔════════════════════════════════════════════════════════════════╗
    ║  ONE-TIME BOOTSTRAP REQUIRED                                   ║
    ╠════════════════════════════════════════════════════════════════╣
    ║  To enable full Terraform automation, grant your Cloud API key ║
    ║  OrganizationAdmin permissions (one-time manual step).         ║
    ║                                                                 ║
    ║  1. Go to: https://confluent.cloud/settings/api-keys          ║
    ║  2. Find your Cloud API key                                    ║
    ║  3. Add role: OrganizationAdmin                                ║
    ║  4. Run: terraform apply                                       ║
    ║                                                                 ║
    ║  After this, everything is managed by Terraform!               ║
    ║                                                                 ║
    ║  See: README.md for detailed instructions                      ║
    ╚════════════════════════════════════════════════════════════════╝

  EOT
}

output "terraform_managed_resources" {
  description = "List of resources managed by Terraform after bootstrap"
  value       = <<-EOT

    After bootstrap, Terraform manages:

    Infrastructure:
      ✓ Environment: ${confluent_environment.main.id}
      ✓ Primary Cluster (AWS ${var.primary_cluster_region}, Standard): ${confluent_kafka_cluster.primary_cluster.id}
      ✓ DR Cluster (AWS ${var.dr_cluster_region}, Dedicated): ${confluent_kafka_cluster.dr_cluster.id}
      ✓ Schema Registry (Advanced, Public): ${data.confluent_schema_registry_cluster.main.id}
      ✓ Service Accounts: 4 (Primary, DR, Schema Registry, Cluster Link)
      ✓ API Keys: 4 cluster-specific keys

    Topics:
      ✓ test_topic on Primary Cluster (independent, writable)
      ✓ test_topic on DR Cluster (independent, writable)
      ✓ mirrored_topic on Primary Cluster (source)

    Cluster Linking:
      ✓ Cluster Link: ${confluent_cluster_link.primary_to_dr.link_name}
      ✓ Mirror Topic: mirrored_topic (Primary → DR, read-only on DR)

    Access Control (after bootstrap):
      ✓ Role Bindings: CloudClusterAdmin (Kafka), ResourceOwner (Schema Registry)
      ✓ Fully managed by Terraform

  EOT
}

# Cluster Linking Outputs
output "cluster_link_name" {
  description = "Cluster Link Name (Primary to DR)"
  value       = confluent_cluster_link.primary_to_dr.link_name
}

output "cluster_link_id" {
  description = "Cluster Link ID"
  value       = confluent_cluster_link.primary_to_dr.id
}

output "cluster_link_status" {
  description = "Cluster Link connection mode and direction"
  value = {
    link_name       = confluent_cluster_link.primary_to_dr.link_name
    link_mode       = confluent_cluster_link.primary_to_dr.link_mode
    connection_mode = confluent_cluster_link.primary_to_dr.connection_mode
    source_cluster  = confluent_kafka_cluster.primary_cluster.id
    destination_cluster = confluent_kafka_cluster.dr_cluster.id
  }
}

# Topic Outputs
output "test_topic_primary" {
  description = "test_topic details on Primary cluster"
  value = {
    topic_name       = confluent_kafka_topic.test_topic_primary.topic_name
    partitions_count = confluent_kafka_topic.test_topic_primary.partitions_count
    cluster_id       = confluent_kafka_cluster.primary_cluster.id
  }
}

output "test_topic_dr" {
  description = "test_topic on DR cluster (regular topic, allows direct writes)"
  value = {
    topic_name       = confluent_kafka_topic.test_topic_dr.topic_name
    partitions_count = confluent_kafka_topic.test_topic_dr.partitions_count
    cluster_id       = confluent_kafka_cluster.dr_cluster.id
  }
}

output "mirrored_topic_primary" {
  description = "mirrored_topic on Primary cluster (source for cluster linking)"
  value = {
    topic_name       = confluent_kafka_topic.mirrored_topic_primary.topic_name
    partitions_count = confluent_kafka_topic.mirrored_topic_primary.partitions_count
    cluster_id       = confluent_kafka_cluster.primary_cluster.id
  }
}

output "mirrored_topic_mirror" {
  description = "mirrored_topic mirror on DR cluster (replicated via cluster linking)"
  value = {
    topic_name        = "mirrored_topic"
    mirror_topic_name = confluent_kafka_mirror_topic.mirrored_topic_mirror.mirror_topic_name
    cluster_id        = confluent_kafka_cluster.dr_cluster.id
    status            = confluent_kafka_mirror_topic.mirrored_topic_mirror.status
  }
}
