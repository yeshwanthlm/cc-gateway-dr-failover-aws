#!/bin/bash

# =============================================================================
# Confluent Cloud Gateway Demo - Destruction Script (AWS)
# =============================================================================
# This script automates the complete destruction of:
# - Kubernetes resources (Gateway, Secrets, Pods)
# - Confluent Operator (Helm)
# - Confluent Cloud Kafka Clusters (Standard Primary + Dedicated DR)
# - Cluster Linking and Mirror Topics
# - Schema Registry
# - Route53 gateway DNS record
# - AWS EKS Cluster, VPC, and Route53 private hosted zone
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

# -----------------------------------------------------------------------------
# Confirmation
# -----------------------------------------------------------------------------

print_header "Confluent Cloud Gateway Demo - Destruction"

print_warning "This will destroy ALL resources including:"
echo "  - Kubernetes Gateway and resources"
echo "  - Confluent Operator (Helm)"
echo "  - Confluent Cloud Kafka Clusters:"
echo "      • Primary (Standard) in us-east-1"
echo "      • DR (Dedicated, 1 CKU) in us-west-2"
echo "  - Cluster Linking (Primary → DR)"
echo "  - Mirror Topics (mirrored_topic)"
echo "  - Schema Registry (Advanced package)"
echo "  - AWS EKS Cluster, VPC, and Route53 private hosted zone"
echo ""
print_error "This action cannot be undone!"
echo ""
read -p "Are you sure you want to continue? (type 'yes' to confirm): " -r
echo

if [[ ! $REPLY =~ ^yes$ ]]; then
    print_info "Destruction cancelled."
    exit 0
fi

# Load environment variables if .env exists
if [ -f .env ]; then
    print_info "Loading configuration from .env file..."
    export $(cat .env | grep -v '^#' | xargs)
fi

# -----------------------------------------------------------------------------
# Step 1: Delete Kubernetes Resources
# -----------------------------------------------------------------------------

print_header "Step 1: Deleting Kubernetes Resources"

# Check if kubectl is configured
if kubectl cluster-info &> /dev/null; then
    print_info "Kubernetes cluster is accessible"

    # Delete gateway
    if kubectl get namespace confluent &> /dev/null; then
        print_info "Deleting gateway resource..."
        kubectl delete -f kubernetes-resources/gateway.yaml -n confluent 2>&1 || print_warning "Gateway already deleted or not found"

        # Delete kafka-tools pod
        print_info "Deleting kafka-tools pod..."
        kubectl delete -f kubernetes-resources/kafka-tools.yaml -n confluent 2>&1 || print_warning "Kafka-tools already deleted or not found"

        # Delete secrets
        print_info "Deleting secrets..."
        kubectl delete secret -n confluent \
            cc-primary-tls \
            cc-dr-tls \
            gateway-tls \
            gateway-truststore \
            client-primary \
            client-dr \
            2>&1 || print_warning "Some secrets already deleted or not found"

        print_success "Kubernetes resources deleted"
    else
        print_warning "Confluent namespace not found, skipping Kubernetes resources cleanup"
    fi
else
    print_warning "Kubernetes cluster not accessible, skipping Kubernetes resources cleanup"
fi

# -----------------------------------------------------------------------------
# Step 2: Uninstall Confluent Operator
# -----------------------------------------------------------------------------

print_header "Step 2: Uninstalling Confluent Operator"

if kubectl get namespace confluent &> /dev/null; then
    # Check if helm release exists
    if helm list -n confluent | grep -q confluent-operator; then
        print_info "Uninstalling Confluent operator..."
        helm uninstall confluent-operator -n confluent
        print_success "Confluent operator uninstalled"
    else
        print_warning "Confluent operator not found"
    fi

    # Delete namespace
    print_info "Deleting confluent namespace..."
    kubectl delete namespace confluent
    print_success "Confluent namespace deleted"
else
    print_warning "Confluent namespace not found, skipping operator cleanup"
fi

# -----------------------------------------------------------------------------
# Step 3: Destroy Confluent Cloud Resources
# -----------------------------------------------------------------------------

print_header "Step 3: Destroying Confluent Cloud Resources"

if [ -d "terraform/confluent-cloud" ]; then
    cd terraform/confluent-cloud

    # Check if terraform state exists
    if [ -f "terraform.tfstate" ]; then
        print_info "Destroying Confluent Cloud clusters..."
        terraform destroy -auto-approve
        print_success "Confluent Cloud resources destroyed"
    else
        print_warning "No Confluent Cloud terraform state found, skipping"
    fi

    cd ../..
else
    print_warning "terraform/confluent-cloud directory not found, skipping"
fi

# -----------------------------------------------------------------------------
# Step 4: Destroy AWS EKS Cluster
# -----------------------------------------------------------------------------

print_header "Step 4: Destroying AWS EKS Cluster"

if [ -d "terraform/eks" ]; then
    cd terraform/eks

    # Check if terraform state exists
    if [ -f "terraform.tfstate" ]; then
        # Remove any gateway DNS record we created so the hosted zone can be deleted
        ROUTE53_ZONE_ID=$(terraform output -raw route53_zone_id 2>/dev/null || echo "")
        if [ -n "$ROUTE53_ZONE_ID" ] && [ -n "${GATEWAY_DOMAIN}" ]; then
            print_info "Removing gateway DNS record from Route53..."
            EXISTING=$(aws route53 list-resource-record-sets \
                --hosted-zone-id "$ROUTE53_ZONE_ID" \
                --query "ResourceRecordSets[?Name=='${GATEWAY_DOMAIN}.']" \
                --output json 2>/dev/null || echo "[]")
            if [ "$EXISTING" != "[]" ] && [ -n "$EXISTING" ]; then
                LB_VALUE=$(echo "$EXISTING" | grep -o '"Value": *"[^"]*"' | head -1 | sed 's/.*"Value": *"\([^"]*\)".*/\1/')
                if [ -n "$LB_VALUE" ]; then
                    cat > /tmp/route53-delete.json <<EOF
{
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${GATEWAY_DOMAIN}",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [ { "Value": "${LB_VALUE}" } ]
      }
    }
  ]
}
EOF
                    aws route53 change-resource-record-sets \
                        --hosted-zone-id "$ROUTE53_ZONE_ID" \
                        --change-batch file:///tmp/route53-delete.json 2>/dev/null || \
                        print_warning "Could not delete DNS record (may already be gone)"
                    rm -f /tmp/route53-delete.json
                fi
            fi
        fi

        print_info "Destroying EKS cluster, VPC, and Route53 zone (this may take 15-20 minutes)..."
        terraform destroy -auto-approve
        print_success "EKS cluster, VPC, and Route53 zone destroyed"
    else
        print_warning "No EKS terraform state found, skipping"
    fi

    cd ../..
else
    print_warning "terraform/eks directory not found, skipping"
fi

# -----------------------------------------------------------------------------
# Step 5: Clean up certificates and temporary files using Makefile
# -----------------------------------------------------------------------------

print_header "Step 5: Cleaning Up Certificates and Temporary Files"

print_info "Using Makefile to clean up certificates..."
make clean-certs 2>/dev/null || {
    print_warning "Makefile cleanup failed, performing manual cleanup..."
    rm -f /tmp/cc-primary-truststore.jks
    rm -f /tmp/cc-dr-truststore.jks
    rm -f /tmp/gateway-truststore.jks
    rm -f /tmp/jksPassword.txt
    rm -f /tmp/gateway-ca.pem
    rm -rf certs/ssl/*
    rm -rf gateway-tls-cert/*.pem gateway-tls-cert/*.csr gateway-tls-cert/*.srl gateway-tls-cert/*.cnf
    rm -f clients/client-primary.properties
    rm -f clients/client-dr.properties
}
print_success "Certificates and temporary files cleaned"

# -----------------------------------------------------------------------------
# Destruction Complete
# -----------------------------------------------------------------------------

print_header "Destruction Complete!"

print_success "All resources have been destroyed successfully!"
echo ""
print_info "Destroyed resources:"
echo "  ✓ Kubernetes Gateway and resources"
echo "  ✓ Confluent Operator (Helm)"
echo "  ✓ Confluent Cloud Kafka Clusters:"
echo "      • Primary (Standard) cluster"
echo "      • DR (Dedicated) cluster"
echo "  ✓ Cluster Linking and Mirror Topics"
echo "  ✓ Schema Registry"
echo "  ✓ Route53 gateway DNS record"
echo "  ✓ AWS EKS Cluster, VPC, and Route53 private hosted zone"
echo "  ✓ Temporary files and certificates"
echo ""
print_info "Your .env file and source code remain intact."
print_info "Run ./deploy.sh to deploy again."
echo ""
