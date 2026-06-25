#!/bin/bash

# =============================================================================
# DR Failover Script - Promote Mirror Topic to Writable Regular Topic
# =============================================================================
# This script performs DR failover by converting the mirrored_topic from a
# read-only mirror topic to a writable regular topic on the DR cluster.
#
# Reference: https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/disaster-recovery.html
# =============================================================================

set -e

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
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
# Configuration
# -----------------------------------------------------------------------------

print_header "DR Failover - Promote Mirror Topic to Writable"

# Change to terraform/confluent-cloud directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT/terraform/confluent-cloud"

# Check if we're in the correct directory
if [ ! -f "terraform.tfstate" ]; then
    print_error "terraform.tfstate not found in terraform/confluent-cloud directory"
    exit 1
fi

# Extract configuration from Terraform outputs
print_info "Reading configuration from Terraform..."

DR_CLUSTER_ID=$(terraform output -raw dr_cluster_id 2>/dev/null)
CLUSTER_LINK_NAME=$(terraform output -raw cluster_link_name 2>/dev/null)
ENVIRONMENT_ID=$(terraform output -raw environment_id 2>/dev/null)
MIRROR_TOPIC_NAME="mirrored_topic"

if [ -z "$DR_CLUSTER_ID" ] || [ -z "$CLUSTER_LINK_NAME" ] || [ -z "$ENVIRONMENT_ID" ]; then
    print_error "Failed to extract Terraform outputs"
    exit 1
fi

print_success "Configuration loaded"
echo ""
echo "  Environment ID: $ENVIRONMENT_ID"
echo "  DR Cluster ID: $DR_CLUSTER_ID"
echo "  Cluster Link: $CLUSTER_LINK_NAME"
echo "  Mirror Topic: $MIRROR_TOPIC_NAME"
echo ""

# Set environment context for Confluent CLI
print_info "Setting Confluent environment context..."
confluent environment use "$ENVIRONMENT_ID" > /dev/null 2>&1
print_success "Environment context set"
echo ""

# -----------------------------------------------------------------------------
# Pre-Failover Checks
# -----------------------------------------------------------------------------

print_header "Step 1: Pre-Failover Verification"

print_info "Checking if Confluent CLI is installed..."
if ! command -v confluent &> /dev/null; then
    print_error "Confluent CLI not found. Please install it:"
    print_info "  brew install confluentinc/tap/cli  # macOS"
    print_info "  Or visit: https://docs.confluent.io/confluent-cli/current/install.html"
    exit 1
fi
print_success "Confluent CLI is installed"

print_info "Checking mirror topic status..."
MIRROR_STATUS=$(confluent kafka mirror list \
    --link "$CLUSTER_LINK_NAME" \
    --cluster "$DR_CLUSTER_ID" 2>/dev/null | grep "$MIRROR_TOPIC_NAME" || echo "")

if [ -z "$MIRROR_STATUS" ]; then
    print_warning "Mirror topic '$MIRROR_TOPIC_NAME' not found on link '$CLUSTER_LINK_NAME'"
    print_info "Available mirror topics:"
    confluent kafka mirror list --link "$CLUSTER_LINK_NAME" --cluster "$DR_CLUSTER_ID" || true
    exit 1
fi

print_success "Mirror topic found: $MIRROR_TOPIC_NAME"
echo "$MIRROR_STATUS"

# -----------------------------------------------------------------------------
# Dry-Run Failover Preview
# -----------------------------------------------------------------------------

print_header "Step 2: Preview Failover (Dry-Run)"

print_info "Running failover dry-run to preview changes..."
echo ""

confluent kafka mirror failover "$MIRROR_TOPIC_NAME" \
    --link "$CLUSTER_LINK_NAME" \
    --cluster "$DR_CLUSTER_ID" \
    --dry-run

echo ""
print_success "Dry-run completed"

# -----------------------------------------------------------------------------
# Confirmation
# -----------------------------------------------------------------------------

print_warning "This will PROMOTE the mirror topic to a regular writable topic on DR cluster"
print_warning "After promotion:"
echo "  • The topic will be WRITABLE on DR cluster"
echo "  • The cluster link for this topic will be STOPPED"
echo "  • This operation is IRREVERSIBLE"
echo ""
read -p "Do you want to proceed with failover? (type 'yes' to confirm): " -r
echo

if [[ ! $REPLY =~ ^yes$ ]]; then
    print_info "Failover cancelled"
    exit 0
fi

# -----------------------------------------------------------------------------
# Execute Failover
# -----------------------------------------------------------------------------

print_header "Step 3: Execute Failover"

print_info "Promoting mirror topic to writable regular topic..."
echo ""

confluent kafka mirror failover "$MIRROR_TOPIC_NAME" \
    --link "$CLUSTER_LINK_NAME" \
    --cluster "$DR_CLUSTER_ID"

echo ""
print_success "Failover completed successfully!"
print_success "Topic '$MIRROR_TOPIC_NAME' is now a WRITABLE regular topic on DR cluster"

# -----------------------------------------------------------------------------
# Post-Failover Verification
# -----------------------------------------------------------------------------

print_header "Step 4: Post-Failover Verification"

print_info "Verifying topic on DR cluster..."
confluent kafka topic describe "$MIRROR_TOPIC_NAME" --cluster "$DR_CLUSTER_ID"
print_success "Topic is now a regular writable topic on DR cluster"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

print_header "Failover Summary"

echo ""
echo "✅ Failover Complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Topic Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Topic: $MIRROR_TOPIC_NAME"
echo "  Cluster: $DR_CLUSTER_ID (DR - Dedicated)"
echo "  Status: ✅ WRITABLE (promoted from mirror)"
echo "  Cluster Link: ⚠️  STOPPED for this topic"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Next Steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Update application configurations to point to DR cluster"
echo "2. Switch gateway routing to DR cluster (if using gateway)"
echo "3. Monitor DR cluster performance and replication lag"
echo "4. Consider creating reverse cluster link (DR → Primary) for eventual failback"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Important Notes:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  ⚠️  The mirror topic has been PROMOTED to a regular topic"
echo "  ⚠️  Replication from Primary cluster has STOPPED"
echo "  ⚠️  To re-establish replication, create a NEW mirror topic"
echo "  ⚠️  Or create a reverse link (DR → Primary) for failback"
echo ""
echo "To verify topic status:"
echo "  confluent kafka topic describe $MIRROR_TOPIC_NAME --cluster $DR_CLUSTER_ID"
echo ""
echo "To check cluster link status:"
echo "  confluent kafka link describe $CLUSTER_LINK_NAME --cluster $DR_CLUSTER_ID"
echo ""
