#!/bin/bash

# =============================================================================
# Confluent Cloud Gateway Demo - Deployment Script (AWS)
# =============================================================================
# This script automates the complete deployment of:
# - AWS EKS Cluster (with Route53 private hosted zone)
# - Confluent Cloud Kafka Clusters (AWS Primary Standard & DR Dedicated)
#   * Primary: Standard cluster (elastic, pay-per-use) in us-east-1
#   * DR: Dedicated cluster (1 CKU, fixed capacity) in us-west-2
#   * Cluster Linking: Primary → DR with automatic replication
#   * test_topic: Created on both clusters
#   * mirrored_topic: Created on Primary, mirrored to DR
# - Schema Registry with Advanced Governance Package
# - Confluent Gateway on Kubernetes
# - All necessary certificates and secrets
# =============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        print_error "$1 is not installed. Please install it first."
        exit 1
    fi
    print_success "$1 is installed"
}

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------

print_header "Pre-flight Checks"

# Check required commands
check_command terraform
check_command aws
check_command kubectl
check_command helm
check_command openssl
check_command keytool

# Check for .env file
if [ ! -f .env ]; then
    print_error ".env file not found!"
    print_info "Please copy .env.example to .env and fill in your configuration"
    print_info "  cp .env.example .env"
    print_info "  # Edit .env with your values"
    exit 1
fi

# Load environment variables
print_info "Loading configuration from .env file..."
export $(cat .env | grep -v '^#' | xargs)
print_success "Configuration loaded"

# Validate required variables
REQUIRED_VARS=(
    "AWS_REGION"
    "EKS_CLUSTER_NAME"
    "CONFLUENT_CLOUD_API_KEY"
    "CONFLUENT_CLOUD_API_SECRET"
    "GATEWAY_DOMAIN"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Required variable $var is not set in .env file"
        exit 1
    fi
done
print_success "All required variables are set"

# Check AWS credentials
print_info "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured. Please run: aws configure (or set AWS env vars)"
    exit 1
fi
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_success "AWS credentials are valid (account: ${AWS_ACCOUNT_ID})"

# -----------------------------------------------------------------------------
# Step 1: Deploy EKS Cluster
# -----------------------------------------------------------------------------

print_header "Step 1: Deploying EKS Cluster"

cd terraform/eks

# Create terraform.tfvars
cat > terraform.tfvars <<EOF
aws_region              = "${AWS_REGION}"
cluster_name            = "${EKS_CLUSTER_NAME}"
kubernetes_version      = "${KUBERNETES_VERSION:-1.31}"
instance_type           = "${INSTANCE_TYPE:-t3.large}"
dns_zone_name           = "${DNS_ZONE_NAME:-axa.com}"
gateway_dns_record_name = "${GATEWAY_DNS_RECORD_NAME:-kafka.cc}"
EOF

print_info "Initializing Terraform..."
terraform init

print_info "Deploying EKS cluster (this may take 15-20 minutes)..."
terraform apply -auto-approve

print_success "EKS cluster deployed successfully"

# Capture Route53 zone ID for later DNS update
ROUTE53_ZONE_ID=$(terraform output -raw route53_zone_id)
print_info "Route53 private hosted zone ID: ${ROUTE53_ZONE_ID}"

# Configure kubectl
print_info "Configuring kubectl..."
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"
print_success "kubectl configured"

# Verify cluster access
print_info "Verifying cluster access..."
kubectl get nodes
print_success "Cluster is accessible"

cd ../..

# -----------------------------------------------------------------------------
# Step 2: Install Confluent Operator
# -----------------------------------------------------------------------------

print_header "Step 2: Installing Confluent Operator"

print_info "Adding Confluent Helm repository..."
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

print_info "Creating confluent namespace..."
kubectl create namespace confluent 2>/dev/null || print_warning "Namespace confluent already exists, continuing..."

print_info "Installing Confluent for Kubernetes operator..."
helm upgrade --install confluent-operator \
    confluentinc/confluent-for-kubernetes \
    --namespace confluent \
    --wait

print_success "Confluent operator installed successfully"

# Wait for operator to be ready
print_info "Waiting for operator pod to be ready..."
kubectl wait --for=condition=Ready pod -l app=confluent-operator -n confluent --timeout=300s
print_success "Confluent operator is ready"

# -----------------------------------------------------------------------------
# Step 3: Deploy Confluent Cloud Clusters with ACLs
# -----------------------------------------------------------------------------

print_header "Step 3: Deploying Confluent Cloud Clusters"

cd terraform/confluent-cloud

# Create terraform.tfvars
cat > terraform.tfvars <<EOF
confluent_cloud_api_key    = "${CONFLUENT_CLOUD_API_KEY}"
confluent_cloud_api_secret = "${CONFLUENT_CLOUD_API_SECRET}"
environment_name           = "${CONFLUENT_ENVIRONMENT_NAME:-cc-gateway-demo-aws}"
primary_cluster_name       = "${PRIMARY_CLUSTER_NAME:-aws-useast1-primary}"
primary_cluster_region     = "${PRIMARY_CLUSTER_REGION:-us-east-1}"
dr_cluster_name            = "${DR_CLUSTER_NAME:-aws-uswest2-dr}"
dr_cluster_region          = "${DR_CLUSTER_REGION:-us-west-2}"
availability               = "${KAFKA_AVAILABILITY:-SINGLE_ZONE}"
EOF

print_info "Initializing Terraform..."
terraform init

print_info "Deploying Confluent Cloud resources (this may take 30-45 minutes)..."
print_info "  - Primary Cluster: Standard (elastic, auto-scaling)"
print_info "  - DR Cluster: Dedicated (1 CKU, fixed capacity)"
print_info "  - Cluster Linking: Primary → DR with automatic replication"
print_info "  - test_topic & mirrored_topic: Created on clusters"
print_warning "Note: ACL creation requires your Cloud API key to have OrganizationAdmin role"
print_info "If ACL creation fails, see README.md"

# Try to apply with ACLs
if terraform apply -auto-approve; then
    print_success "Confluent Cloud clusters and ACLs deployed successfully"
else
    print_error "Terraform apply failed"
    print_warning "This is likely due to insufficient Cloud API key permissions"
    print_info "To fix:"
    print_info "  1. Go to: https://confluent.cloud/settings/api-keys"
    print_info "  2. Find your Cloud API key: ${CONFLUENT_CLOUD_API_KEY}"
    print_info "  3. Add role binding: OrganizationAdmin"
    print_info "  4. Run: cd terraform/confluent-cloud && terraform apply"
    print_info "  5. Then resume: ./deploy.sh --skip-terraform"
    exit 1
fi

# Get cluster endpoints and API keys
print_info "Retrieving cluster information..."
PRIMARY_CLUSTER_ENDPOINT=$(terraform output -raw primary_cluster_bootstrap_endpoint | sed 's/SASL_SSL:\/\///')
DR_CLUSTER_ENDPOINT=$(terraform output -raw dr_cluster_bootstrap_endpoint | sed 's/SASL_SSL:\/\///')
PRIMARY_CLUSTER_API_KEY=$(terraform output -raw primary_cluster_api_key)
PRIMARY_CLUSTER_API_SECRET=$(terraform output -raw primary_cluster_api_secret)
DR_CLUSTER_API_KEY=$(terraform output -raw dr_cluster_api_key)
DR_CLUSTER_API_SECRET=$(terraform output -raw dr_cluster_api_secret)
PRIMARY_SERVICE_ACCOUNT_ID=$(terraform output -raw primary_service_account_id)
DR_SERVICE_ACCOUNT_ID=$(terraform output -raw dr_service_account_id)
CC_SCHEMA_REGISTRY_ENDPOINT=$(terraform output -raw schema_registry_endpoint)
CC_SCHEMA_REGISTRY_API_KEY=$(terraform output -raw schema_registry_api_key)
CC_SCHEMA_REGISTRY_API_SECRET=$(terraform output -raw schema_registry_api_secret)

print_success "Cluster and Schema Registry information retrieved"

cd ../..

# -----------------------------------------------------------------------------
# Step 4-6: Create All Certificates and Secrets using Makefile
# -----------------------------------------------------------------------------

print_header "Steps 4-6: Creating Certificates and Secrets"

# Update .env with cluster information from Terraform
print_info "Updating .env file with cluster information..."

# Remove old entries if they exist
grep -v "^PRIMARY_CLUSTER_ENDPOINT=" .env > .env.tmp 2>/dev/null || cp .env .env.tmp
grep -v "^DR_CLUSTER_ENDPOINT=" .env.tmp > .env.tmp2 2>/dev/null || cp .env.tmp .env.tmp2
grep -v "^PRIMARY_CLUSTER_API_KEY=" .env.tmp2 > .env.tmp3 2>/dev/null || cp .env.tmp2 .env.tmp3
grep -v "^PRIMARY_CLUSTER_API_SECRET=" .env.tmp3 > .env.tmp4 2>/dev/null || cp .env.tmp3 .env.tmp4
grep -v "^DR_CLUSTER_API_KEY=" .env.tmp4 > .env.tmp5 2>/dev/null || cp .env.tmp4 .env.tmp5
grep -v "^DR_CLUSTER_API_SECRET=" .env.tmp5 > .env.tmp6 2>/dev/null || cp .env.tmp5 .env.tmp6
grep -v "^PRIMARY_SERVICE_ACCOUNT_ID=" .env.tmp6 > .env.tmp7 2>/dev/null || cp .env.tmp6 .env.tmp7
grep -v "^DR_SERVICE_ACCOUNT_ID=" .env.tmp7 > .env.tmp8 2>/dev/null || cp .env.tmp7 .env.tmp8
grep -v "^SCHEMA_REGISTRY_ENDPOINT=" .env.tmp8 > .env.tmp9 2>/dev/null || cp .env.tmp8 .env.tmp9
grep -v "^SCHEMA_REGISTRY_API_KEY=" .env.tmp9 > .env.tmp10 2>/dev/null || cp .env.tmp9 .env.tmp10
grep -v "^SCHEMA_REGISTRY_API_SECRET=" .env.tmp10 > .env.tmp11 2>/dev/null || cp .env.tmp10 .env.tmp11
grep -v "^CC_SCHEMA_REGISTRY_ENDPOINT=" .env.tmp11 > .env.tmp12 2>/dev/null || cp .env.tmp11 .env.tmp12
grep -v "^CC_SCHEMA_REGISTRY_API_KEY=" .env.tmp12 > .env.tmp13 2>/dev/null || cp .env.tmp12 .env.tmp13
grep -v "^CC_SCHEMA_REGISTRY_API_SECRET=" .env.tmp13 > .env 2>/dev/null || cp .env.tmp13 .env
rm -f .env.tmp .env.tmp2 .env.tmp3 .env.tmp4 .env.tmp5 .env.tmp6 .env.tmp7 .env.tmp8 .env.tmp9 .env.tmp10 .env.tmp11 .env.tmp12 .env.tmp13

# Append new values
cat >> .env <<EOF

# Auto-populated from Terraform (terraform/confluent-cloud/)
PRIMARY_CLUSTER_ENDPOINT=${PRIMARY_CLUSTER_ENDPOINT}
DR_CLUSTER_ENDPOINT=${DR_CLUSTER_ENDPOINT}
PRIMARY_CLUSTER_API_KEY=${PRIMARY_CLUSTER_API_KEY}
PRIMARY_CLUSTER_API_SECRET=${PRIMARY_CLUSTER_API_SECRET}
DR_CLUSTER_API_KEY=${DR_CLUSTER_API_KEY}
DR_CLUSTER_API_SECRET=${DR_CLUSTER_API_SECRET}
PRIMARY_SERVICE_ACCOUNT_ID=${PRIMARY_SERVICE_ACCOUNT_ID}
DR_SERVICE_ACCOUNT_ID=${DR_SERVICE_ACCOUNT_ID}
CC_SCHEMA_REGISTRY_ENDPOINT=${CC_SCHEMA_REGISTRY_ENDPOINT}
CC_SCHEMA_REGISTRY_API_KEY=${CC_SCHEMA_REGISTRY_API_KEY}
CC_SCHEMA_REGISTRY_API_SECRET=${CC_SCHEMA_REGISTRY_API_SECRET}
EOF

print_success ".env file updated with cluster credentials"

print_info "Using Makefile to automate certificate creation..."
print_info "This will:"
echo "  - Download and convert Confluent Cloud certificates"
echo "  - Generate gateway TLS certificates"
echo "  - Create client configuration files"
echo "  - Create all Kubernetes secrets"
echo ""

# Run make to create all certificates and secrets
make certs
make k8s-secrets

print_info "Verifying Kubernetes secrets are created..."
REQUIRED_SECRETS=("cc-primary-tls" "cc-dr-tls" "gateway-tls" "gateway-truststore" "client-primary" "client-dr")
MISSING_SECRETS=()

for secret in "${REQUIRED_SECRETS[@]}"; do
    if ! kubectl get secret "$secret" -n confluent &>/dev/null; then
        MISSING_SECRETS+=("$secret")
    fi
done

if [ ${#MISSING_SECRETS[@]} -eq 0 ]; then
    print_success "All Kubernetes secrets created successfully"
else
    print_error "Missing secrets: ${MISSING_SECRETS[*]}"
    print_error "Re-running make k8s-secrets..."
    make k8s-secrets
fi

# Verify certificates
print_info "Verifying certificates..."
make verify-certs

# -----------------------------------------------------------------------------
# Step 7: Update and Deploy Gateway Configuration
# -----------------------------------------------------------------------------

print_header "Step 7: Deploying Confluent Gateway"

# Update gateway.yaml with actual cluster endpoints
print_info "Updating gateway configuration with cluster endpoints..."

# Backup the original file
cp kubernetes-resources/gateway.yaml kubernetes-resources/gateway.yaml.bak

# Use awk to update endpoints reliably (works on both GNU and BSD)
awk -v primary="${PRIMARY_CLUSTER_ENDPOINT}" -v dr="${DR_CLUSTER_ENDPOINT}" '
  /id: CC_PRIMARY/ { in_primary=1 }
  /id: CC_DR/ { in_primary=0; in_dr=1 }
  /id:/ && !/id: CC_PRIMARY/ && !/id: CC_DR/ { in_primary=0; in_dr=0 }

  /endpoint:/ && in_primary {
    gsub(/endpoint: .*/, "endpoint: " primary)
    in_primary=0
  }
  /endpoint:/ && in_dr {
    gsub(/endpoint: .*/, "endpoint: " dr)
    in_dr=0
  }
  { print }
' kubernetes-resources/gateway.yaml > kubernetes-resources/gateway.yaml.tmp

# Replace original with updated file
mv kubernetes-resources/gateway.yaml.tmp kubernetes-resources/gateway.yaml

print_success "Gateway configuration updated with cluster endpoints:"
print_info "  - Primary Cluster: ${PRIMARY_CLUSTER_ENDPOINT}"
print_info "  - DR Cluster: ${DR_CLUSTER_ENDPOINT}"

print_info "Deploying gateway..."
kubectl apply -f kubernetes-resources/gateway.yaml -n confluent

print_info "Waiting for gateway pods to be ready (this may take 2-3 minutes)..."
kubectl wait --for=condition=Ready pod -l app=confluent-gateway --timeout=600s -n confluent

print_info "Verifying gateway is healthy..."
GATEWAY_POD=$(kubectl get pods -n confluent -l app=confluent-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$GATEWAY_POD" ]; then
    # Wait a bit for the gateway to fully initialize
    sleep 10
    print_success "Gateway pod ${GATEWAY_POD} is running and ready"
else
    print_warning "Could not verify gateway pod name, but deployment succeeded"
fi

print_success "Gateway deployed successfully"

# -----------------------------------------------------------------------------
# Step 7.5: Update Route53 DNS Record
# -----------------------------------------------------------------------------

print_header "Step 7.5: Updating Route53 DNS"

# AWS LoadBalancers (NLB/ELB) expose a hostname, not an IP. We resolve the
# gateway LoadBalancer's hostname and create a CNAME in the private hosted zone.
print_info "Waiting for LoadBalancer to be provisioned..."

MAX_ATTEMPTS=60  # Wait up to 5 minutes (60 * 5 seconds)
ATTEMPT=0
LB_HOSTNAME=""

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    LB_HOSTNAME=$(kubectl get svc confluent-gateway-bootstrap-lb -n confluent \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [ -n "$LB_HOSTNAME" ]; then
        print_success "LoadBalancer hostname assigned: ${LB_HOSTNAME}"
        break
    fi

    ATTEMPT=$((ATTEMPT + 1))
    if [ $((ATTEMPT % 6)) -eq 0 ]; then
        print_info "Still waiting for LoadBalancer hostname... (${ATTEMPT}/60 attempts)"
    fi
    sleep 5
done

if [ -z "$LB_HOSTNAME" ]; then
    print_error "LoadBalancer hostname not available after 5 minutes."
    print_warning "This may indicate an issue with AWS LoadBalancer provisioning."
    print_info "You can:"
    print_info "  1. Check LoadBalancer status: kubectl get svc confluent-gateway-bootstrap-lb -n confluent"
    print_info "  2. Check events: kubectl describe svc confluent-gateway-bootstrap-lb -n confluent"
    print_info "  3. Create the DNS record manually later with:"
    print_info "     aws route53 change-resource-record-sets --hosted-zone-id ${ROUTE53_ZONE_ID:-<ZONE_ID>} \\"
    print_info "       --change-batch '{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${GATEWAY_DOMAIN}\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"<LB_HOSTNAME>\"}]}}]}'"
    print_warning "Continuing without updating DNS..."
else
    print_success "LoadBalancer ready with hostname: ${LB_HOSTNAME}"

    print_info "Upserting Route53 CNAME record ${GATEWAY_DOMAIN} -> ${LB_HOSTNAME}..."

    cat > /tmp/route53-change.json <<EOF
{
  "Comment": "Confluent Gateway record",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${GATEWAY_DOMAIN}",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          { "Value": "${LB_HOSTNAME}" }
        ]
      }
    }
  ]
}
EOF

    aws route53 change-resource-record-sets \
        --hosted-zone-id "${ROUTE53_ZONE_ID}" \
        --change-batch file:///tmp/route53-change.json || {
        print_warning "Failed to update Route53 record automatically"
        print_info "You may need to create it manually"
    }
    rm -f /tmp/route53-change.json

    print_success "DNS record updated: ${GATEWAY_DOMAIN} -> ${LB_HOSTNAME}"

    # Verify DNS record
    print_info "Verifying DNS record..."
    aws route53 list-resource-record-sets \
        --hosted-zone-id "${ROUTE53_ZONE_ID}" \
        --query "ResourceRecordSets[?Name=='${GATEWAY_DOMAIN}.']" \
        --output table || true
fi

# -----------------------------------------------------------------------------
# Step 8: Deploy Kafka Tools Pod
# -----------------------------------------------------------------------------

print_header "Step 8: Deploying Kafka Tools Pod"

# The kafka-tools pod resolves ${GATEWAY_DOMAIN} via the Route53 private hosted
# zone associated with the EKS VPC (cluster DNS forwards to the VPC resolver).
print_info "Deploying kafka-tools pod..."
kubectl apply -f kubernetes-resources/kafka-tools.yaml -n confluent

kubectl wait --for=condition=Ready pod/kafka-tools --timeout=120s -n confluent

print_success "Kafka tools pod deployed successfully"

# -----------------------------------------------------------------------------
# Deployment Complete
# -----------------------------------------------------------------------------

print_header "Deployment Complete!"

print_success "All resources have been deployed successfully!"
echo ""
print_info "Summary:"
echo "  - EKS Cluster: ${EKS_CLUSTER_NAME} (${AWS_REGION})"
echo "  - Primary Kafka Cluster (AWS ${PRIMARY_CLUSTER_REGION}): ${PRIMARY_CLUSTER_ENDPOINT}"
echo "    • Service Account: ${PRIMARY_SERVICE_ACCOUNT_ID}"
echo "    • API Key: ${PRIMARY_CLUSTER_API_KEY}"
echo "  - DR Kafka Cluster (AWS ${DR_CLUSTER_REGION}): ${DR_CLUSTER_ENDPOINT}"
echo "    • Service Account: ${DR_SERVICE_ACCOUNT_ID}"
echo "    • API Key: ${DR_CLUSTER_API_KEY}"
echo "  - Schema Registry (Advanced, Public): ${CC_SCHEMA_REGISTRY_ENDPOINT}"
echo "    • API Key: ${CC_SCHEMA_REGISTRY_API_KEY}"
echo "  - Gateway Domain: ${GATEWAY_DOMAIN}"
echo "  - LoadBalancer Hostname: ${LB_HOSTNAME}"
echo ""
print_success "ACLs and Permissions:"
echo "  ✓ Role bindings created (CloudClusterAdmin)"
echo "  ✓ ACLs created (CREATE, WRITE, READ, DESCRIBE for topics)"
echo "  ✓ Consumer group permissions granted"
echo ""
print_info "Next Steps:"
echo ""
echo "  1. Verify Route53 record: ${GATEWAY_DOMAIN} -> ${LB_HOSTNAME}"
echo ""
echo "  2. Test topic listing:"
echo "     kubectl exec kafka-tools -n confluent -- kafka-topics \\"
echo "       --bootstrap-server ${GATEWAY_DOMAIN}:9092 \\"
echo "       --command-config /etc/kafka/client-primary/client-primary.properties \\"
echo "       --list"
echo ""
echo "  3. Test message production:"
echo "     kubectl exec kafka-tools -n confluent -- bash -c 'echo -e \"test 1\\ntest 2\\ntest 3\" | kafka-console-producer \\"
echo "       --bootstrap-server ${GATEWAY_DOMAIN}:9092 \\"
echo "       --producer.config /etc/kafka/client-primary/client-primary.properties \\"
echo "       --topic test_topic'"
echo ""
echo "  4. To switch between clusters, update kubernetes-resources/gateway.yaml"
echo "     and run: kubectl apply -f kubernetes-resources/gateway.yaml -n confluent"
echo ""
print_info "Credentials saved to: .env"
print_info "For more details, see README.md"
echo ""
