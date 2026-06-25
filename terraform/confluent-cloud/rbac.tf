# =============================================================================
# Role-Based Access Control (RBAC) Configuration
# =============================================================================
# This file manages role bindings for service accounts to enable ACL creation
#
# IMPORTANT: Your Cloud API key (in terraform.tfvars) must have OrganizationAdmin
# or EnvironmentAdmin permissions to create these role bindings.
#
# To grant this permission (one-time manual step):
# 1. Go to: https://confluent.cloud/settings/api-keys
# 2. Find your Cloud API key
# 3. Add role binding: OrganizationAdmin
#
# After that, all ACL and permission management is handled by Terraform.
# =============================================================================

# Grant CloudClusterAdmin role to Primary cluster service account
# This allows the service account to manage ACLs within the cluster
resource "confluent_role_binding" "primary_cluster_admin" {
  principal   = "User:${confluent_service_account.primary_cluster_manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.primary_cluster.rbac_crn
}

# Grant CloudClusterAdmin role to DR cluster service account
# This allows the service account to manage ACLs within the cluster
resource "confluent_role_binding" "dr_cluster_admin" {
  principal   = "User:${confluent_service_account.dr_cluster_manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.dr_cluster.rbac_crn
}

# Grant ResourceOwner role to Schema Registry service account
# This allows the service account to manage schemas in Schema Registry
resource "confluent_role_binding" "schema_registry_resource_owner" {
  principal   = "User:${confluent_service_account.schema_registry_manager.id}"
  role_name   = "ResourceOwner"
  crn_pattern = "${data.confluent_schema_registry_cluster.main.resource_name}/subject=*"

  depends_on = [
    data.confluent_schema_registry_cluster.main
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# Note: These role bindings grant the service accounts admin permissions on their
# respective resources:
# 1. CloudClusterAdmin - Cluster admin capabilities for Kafka clusters
# 2. ResourceOwner - Full access to Schema Registry subjects
#
# For production, you may want to use more restrictive roles:
# - DeveloperRead (read-only access)
# - DeveloperWrite (write access)
# - DeveloperManage (manage topics, ACLs, etc.)
