# Confluent Cloud Gateway Setup for Cluster Switchover (AWS)

Complete Confluent Cloud Gateway deployment on AWS with Standard (Primary) and Dedicated (DR) clusters, cluster linking, and automated failover capabilities.

## Architecture Diagram
<img width="1540" height="870" alt="image (2)" src="https://github.com/user-attachments/assets/f0721e47-cf64-4e8d-aced-060d30f414f2" />

---

## 📖 Table of Contents

- [Quick Start (Automated)](#-quick-start-automated) - **Start here for fastest deployment**
- [Manual Deployment Guide](#-manual-deployment-guide) - **Step-by-step instructions**
- [Architecture Overview](#-architecture-overview)
- [Testing & Verification](#-testing--verification)
- [DR Failover](#-dr-failover)
- [Cleanup](#-cleanup)

---

## 🚀 Quick Start (Automated)

**Choose this if**: You want a one-command deployment with minimal manual intervention.

### Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (configured)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) >= 3.0
- OpenSSL and Java KeyTool
- [Confluent Cloud Account](https://confluent.cloud) with API keys

### Step 1: AWS Login

```bash
aws configure
aws sts get-caller-identity
```

### Step 2: Configure Environment

```bash
cp .env.example .env
nano .env
```

**Required configuration:**
```bash
AWS_REGION=us-east-2
EKS_CLUSTER_NAME=cc-gateway-eks
CONFLUENT_CLOUD_API_KEY=your-api-key
CONFLUENT_CLOUD_API_SECRET=your-api-secret
GATEWAY_DOMAIN=kafka.cc.axa.com
```

### Step 3: Deploy Everything

```bash
./deploy.sh
```

**Deployment time**: ~45-50 minutes
- EKS Cluster: 15-20 min
- Primary Cluster (Standard): 3-5 min
- DR Cluster (Dedicated): 35-45 min
- Cluster Linking: 2-3 min
- Gateway & Certificates: 5-10 min

### Step 4: Verify Deployment

```bash
# Verify cluster linking
./scripts/verify-cluster-linking.sh

# Check all resources
kubectl get all -n confluent
```

### What Gets Deployed

| Component | Details |
|-----------|---------|
| **EKS Cluster** | 2 nodes, Kubernetes 1.31, us-east-2 |
| **Primary Cluster** | Standard type (elastic), us-east-1, `test_topic` + `mirrored_topic` |
| **DR Cluster** | Dedicated type (1 CKU), us-west-2, `test_topic` + `mirrored_topic` (mirror) |
| **Cluster Link** | `primary-to-dr-link` - Active replication |
| **Gateway** | Confluent Gateway on EKS with LoadBalancer (NLB) |
| **DNS** | Route53 private hosted zone `axa.com` with CNAME record `kafka.cc.axa.com` |
| **Schema Registry** | Advanced package with public endpoint |

### Gateway Switchover Testing

Complete end-to-end cluster switchover from Primary to DR.

#### Step 1: Deploy

Ensure deployment is complete:

```bash
# Verify all resources are running
kubectl get all -n confluent

# Check gateway is routing to Primary
kubectl get gateway confluent-gateway -n confluent -o yaml | grep "bootstrapServerId:"
# Expected: bootstrapServerId: CC_PRIMARY
```

#### Step 2: Produce/Consume to Primary & DR Cluster

```bash

# Produce to mirrored_topic on Primary cluster
kubectl exec kafka-tools -n confluent -- bash -c \
  'echo -e "primary-msg-1\nprimary-msg-2\nprimary-msg-3" | kafka-console-producer \
    --bootstrap-server kafka.cc.axa.com:9092 \
    --producer.config /etc/kafka/client-primary/client-primary.properties \
    --topic mirrored_topic'

# Produce to mirrored_topic on DR cluster
kubectl exec kafka-tools -n confluent -- bash -c \
  'echo -e "msg-1\nmsg-2\nmsg-3" | kafka-console-producer \
    --bootstrap-server kafka.cc.axa.com:9092 \
    --producer.config /etc/kafka/client-dr/client-dr.properties \
    --topic mirrored_topic'
```

✅ Expected: Messages replicated from Primary to DR via cluster linking

#### Step 3: Promote Mirror Topic and Switch Gateway to DR

**A. Promote mirrored_topic on DR cluster:**

```bash
./scripts/failover-mirrored-topic.sh
# Type 'yes' when prompted to confirm
```

Or manually:
```bash
cd terraform/confluent-cloud
DR_CLUSTER_ID=$(terraform output -raw dr_cluster_id)
LINK_NAME=$(terraform output -raw cluster_link_name)

confluent kafka mirror failover mirrored_topic \
  --link $LINK_NAME \
  --cluster $DR_CLUSTER_ID

cd ../..
```

✅ Result: `mirrored_topic` on DR is now **writable** (no longer read-only mirror)

**B. Change gateway route to DR cluster:**

```bash
# Edit gateway configuration
nano kubernetes-resources/gateway.yaml
```

Change lines 50-56:
```yaml
# BEFORE (routing to Primary):
routes:
  - name: primary-route
    endpoint: "kafka.cc.axa.com:9092"
    streamingDomain:
      name: cc-primary
      bootstrapServerId: CC_PRIMARY

# AFTER (routing to DR):
routes:
  - name: dr-route
    endpoint: "kafka.cc.axa.com:9092"
    streamingDomain:
      name: cc-dr
      bootstrapServerId: CC_DR
```

**C. Apply changes and restart gateway:**

```bash
kubectl delete pod -n confluent -l app=confluent-gateway
kubectl apply -f kubernetes-resources/gateway.yaml -n confluent
kubectl wait --for=condition=Ready pod -l app=confluent-gateway -n confluent --timeout=120s
```

**D. Verify gateway switched:**

```bash
kubectl get gateway confluent-gateway -n confluent -o yaml | grep "bootstrapServerId:"
# Expected: bootstrapServerId: CC_DR
```

✅ Gateway now routing to DR cluster

#### Step 4: Produce to DR Cluster

```bash
# Produce to mirrored_topic on DR cluster (now writable!)
kubectl exec kafka-tools -n confluent -- bash -c \
  'echo -e "dr-msg-1\ndr-msg-2\ndr-msg-3" | kafka-console-producer \
    --bootstrap-server kafka.cc.axa.com:9092 \
    --producer.config /etc/kafka/client-dr/client-dr.properties \
    --topic mirrored_topic'

# Consume to verify
kubectl exec kafka-tools -n confluent -- kafka-console-consumer \
  --bootstrap-server kafka.cc.axa.com:9092 \
  --consumer.config /etc/kafka/client-dr/client-dr.properties \
  --topic mirrored_topic \
  --from-beginning \
  --max-messages 6 \
  --timeout-ms 10000
```

✅ Expected: All 6 messages (3 from Primary + 3 from DR)

**🎉 Cluster Switchover Complete!**

You've successfully:
1. ✅ Produced messages to Primary cluster
2. ✅ Verified replication to DR via cluster linking
3. ✅ Promoted mirror topic to writable on DR
4. ✅ Switched gateway routing from Primary to DR
5. ✅ Produced messages to DR cluster

**For detailed DR failover documentation**, see the [DR Failover](#-dr-failover) section.

### Cleanup

```bash
./destroy.sh
```

---

## 📖 Manual Deployment Guide

**Choose this if**: You want full control over each deployment step.

### Phase 1: AWS Infrastructure

#### 1.1 Configure AWS

```bash
# Configure credentials
aws configure

# Verify identity
aws sts get-caller-identity
```

#### 1.2 Configure Environment

```bash
cp .env.example .env
```

Edit `.env` with your values:
```bash
AWS_REGION=us-east-2
EKS_CLUSTER_NAME=cc-gateway-eks
KUBERNETES_VERSION=1.31
INSTANCE_TYPE=t3.large
CONFLUENT_CLOUD_API_KEY=<your-cloud-api-key>
CONFLUENT_CLOUD_API_SECRET=<your-cloud-api-secret>
DNS_ZONE_NAME=axa.com
GATEWAY_DNS_RECORD_NAME=kafka.cc
GATEWAY_DOMAIN=kafka.cc.axa.com
```

#### 1.3 Deploy EKS Cluster

```bash
cd terraform/eks

# Create terraform.tfvars
cat > terraform.tfvars <<EOF
aws_region              = "us-east-2"
cluster_name            = "cc-gateway-eks"
kubernetes_version      = "1.31"
instance_type           = "t3.large"
dns_zone_name           = "axa.com"
gateway_dns_record_name = "kafka.cc"
EOF

terraform init
terraform plan
terraform apply
```

**Time**: 15-20 minutes

This also creates a Route53 private hosted zone for `axa.com` associated with the EKS VPC, so in-cluster pods can resolve `kafka.cc.axa.com`.

#### 1.4 Configure kubectl

```bash
aws eks update-kubeconfig \
  --region us-east-2 \
  --name cc-gateway-eks

kubectl get nodes
```

### Phase 2: Confluent Cloud Resources

#### 2.1 Deploy Kafka Clusters

```bash
cd ../confluent-cloud

# Create terraform.tfvars
cat > terraform.tfvars <<EOF
confluent_cloud_api_key    = "$CONFLUENT_CLOUD_API_KEY"
confluent_cloud_api_secret = "$CONFLUENT_CLOUD_API_SECRET"
environment_name           = "cc-gateway-demo-aws"
primary_cluster_name       = "aws-useast1-primary"
primary_cluster_region     = "us-east-1"
dr_cluster_name            = "aws-uswest2-dr"
dr_cluster_region          = "us-west-2"
availability               = "SINGLE_ZONE"
EOF

terraform init
terraform plan
terraform apply
```

**Time**: 45-50 minutes (DR Dedicated cluster takes longest)

**What gets created:**
- Environment with Schema Registry (Advanced)
- Primary cluster (Standard) - us-east-1
- DR cluster (Dedicated, 1 CKU) - us-west-2
- Cluster link: `primary-to-dr-link`
- Topics: `test_topic` (both clusters), `mirrored_topic` (Primary + DR mirror)
- Service accounts and API keys

#### 2.2 Save Cluster Details

```bash
# Save to environment file
terraform output -raw primary_cluster_bootstrap_endpoint
terraform output -raw dr_cluster_bootstrap_endpoint
terraform output -raw schema_registry_endpoint

# View all outputs
terraform output
```

### Phase 3: Confluent Operator

#### 3.1 Install Operator

```bash
cd ../..

# Add Helm repo
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

# Create namespace
kubectl create namespace confluent

# Install operator
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace confluent \
  --wait
```

#### 3.2 Verify Operator

```bash
kubectl wait --for=condition=Ready pod \
  -l app=confluent-operator \
  -n confluent \
  --timeout=300s

kubectl get pods -n confluent
```

### Phase 4: Certificates and Secrets

#### 4.1 Generate Certificates

```bash
# Create all certificates
make certs

# Verify
make verify-certs
```

#### 4.2 Create Kubernetes Secrets

```bash
make k8s-secrets

# Verify all secrets exist
kubectl get secrets -n confluent | grep -E "tls|client"
```

**Expected secrets:**
- `cc-primary-tls`
- `cc-dr-tls`
- `gateway-tls`
- `gateway-truststore`
- `client-primary`
- `client-dr`

### Phase 5: Deploy Gateway

#### 5.1 Get LoadBalancer Hostname

Wait for the LoadBalancer service to get an external hostname (AWS NLB exposes a DNS name, not an IP):

```bash
# Deploy gateway
kubectl apply -f kubernetes-resources/gateway.yaml -n confluent

# Wait for LoadBalancer
kubectl wait --for=condition=Ready pod \
  -l app=confluent-gateway \
  -n confluent \
  --timeout=600s

# Get hostname (wait up to 5 minutes)
LB_HOSTNAME=""
for i in {1..60}; do
  LB_HOSTNAME=$(kubectl get svc confluent-gateway-bootstrap-lb -n confluent \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  if [ -n "$LB_HOSTNAME" ]; then
    echo "LoadBalancer hostname: $LB_HOSTNAME"
    break
  fi
  echo "Waiting for LoadBalancer hostname... ($i/60)"
  sleep 5
done
```

#### 5.2 Update DNS Record

Create a CNAME record in the Route53 private hosted zone pointing `kafka.cc.axa.com` at the NLB hostname:

```bash
# Get the Route53 zone ID from terraform
ROUTE53_ZONE_ID=$(cd terraform/eks && terraform output -raw route53_zone_id)

# Upsert the CNAME record
cat > /tmp/route53-change.json <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "kafka.cc.axa.com",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [ { "Value": "${LB_HOSTNAME}" } ]
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id "$ROUTE53_ZONE_ID" \
  --change-batch file:///tmp/route53-change.json

# Verify
aws route53 list-resource-record-sets \
  --hosted-zone-id "$ROUTE53_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='kafka.cc.axa.com.']"
```

### Phase 6: Deploy Kafka Tools

```bash
kubectl apply -f kubernetes-resources/kafka-tools.yaml -n confluent

kubectl wait --for=condition=Ready pod/kafka-tools \
  -n confluent \
  --timeout=120s
```

### Phase 7: Verify Deployment

```bash
# Check all pods
kubectl get pods -n confluent

# Check gateway
kubectl get gateway confluent-gateway -n confluent

# Test connectivity
kubectl exec kafka-tools -n confluent -- kafka-topics \
  --bootstrap-server kafka.cc.axa.com:9092 \
  --command-config /etc/kafka/client-primary/client-primary.properties \
  --list
```

---

## 🏗️ Architecture Overview

### Infrastructure Components

**3 AWS Regions:**
- **us-east-2**: EKS cluster, Gateway
- **us-east-1**: Primary Kafka cluster (Standard)
- **us-west-2**: DR Kafka cluster (Dedicated, 1 CKU)

### Cluster Configuration

| Feature | Primary (Standard) | DR (Dedicated) |
|---------|-------------------|----------------|
| **Type** | Standard | Dedicated |
| **Region** | us-east-1 | us-west-2 |
| **Capacity** | Elastic, auto-scaling | Fixed (1 CKU) |
| **Throughput** | Up to 100 MB/s | 100 MB/s per CKU |
| **SLA** | 99.9% | 99.95% |
| **Network** | Shared | Isolated VPC |
| **Monthly Cost** | ~$50-100 (variable) | ~$500 (fixed) |

### Topics Configuration

| Topic | Primary Cluster | DR Cluster | Purpose |
|-------|----------------|------------|---------|
| **test_topic** | ✅ Writable | ✅ Writable | Independent testing on both clusters |
| **mirrored_topic** | ✅ Writable (source) | 📖 Read-only (mirror) | Demonstrates cluster linking & DR |

### Cluster Linking

- **Link Name**: `primary-to-dr-link`
- **Direction**: Primary → DR
- **Mode**: DESTINATION
- **Connection**: OUTBOUND
- **Status**: ACTIVE
- **Replication**: Near real-time (< 1 second lag)

---

## ✅ Testing & Verification

### Verify Cluster Linking

```bash
./scripts/verify-cluster-linking.sh
```

**This script:**
1. Tests connectivity to both clusters
2. Produces messages to Primary cluster
3. Verifies replication to DR cluster
4. Reports cluster linking status

### Manual Testing

#### Test 1: Write to test_topic (Both Clusters)

```bash
# Primary cluster
kubectl exec kafka-tools -n confluent -- bash -c \
  'echo -e "primary-1\nprimary-2" | kafka-console-producer \
    --bootstrap-server kafka.cc.axa.com:9092 \
    --producer.config /etc/kafka/client-primary/client-primary.properties \
    --topic test_topic'

# DR cluster
kubectl exec kafka-tools -n confluent -- bash -c \
  'echo -e "dr-1\ndr-2" | kafka-console-producer \
    --bootstrap-server kafka.cc.axa.com:9092 \
    --producer.config /etc/kafka/client-dr/client-dr.properties \
    --topic test_topic'
```

#### Test 2: Cluster Linking Replication

```bash
# Produce to mirrored_topic on Primary
kubectl exec kafka-tools -n confluent -- bash -c \
  'echo -e "replicated-1\nreplicated-2\nreplicated-3" | kafka-console-producer \
    --bootstrap-server kafka.cc.axa.com:9092 \
    --producer.config /etc/kafka/client-primary/client-primary.properties \
    --topic mirrored_topic'

# Wait for replication (typically < 1 second)
sleep 2

# Consume from DR cluster (should see replicated messages)
kubectl exec kafka-tools -n confluent -- kafka-console-consumer \
  --bootstrap-server kafka.cc.axa.com:9092 \
  --consumer.config /etc/kafka/client-dr/client-dr.properties \
  --topic mirrored_topic \
  --from-beginning \
  --max-messages 3 \
  --timeout-ms 10000
```

#### Test 3: Mirror Topic is Read-Only on DR

```bash
# This should FAIL (mirror topics are read-only)
kubectl exec kafka-tools -n confluent -- bash -c \
  'echo "test" | kafka-console-producer \
    --bootstrap-server kafka.cc.axa.com:9092 \
    --producer.config /etc/kafka/client-dr/client-dr.properties \
    --topic mirrored_topic'

# Expected error: "Cannot append records to read-only mirror topic"
```

### Check Resources

```bash
# All Kubernetes resources
kubectl get all -n confluent

# Gateway status
kubectl get gateway confluent-gateway -n confluent -o yaml

# Gateway logs
kubectl logs -n confluent -l app=confluent-gateway --tail=50

# Active cluster routing
kubectl get gateway confluent-gateway -n confluent -o yaml | grep "bootstrapServerId:"
```

---

## 🔄 DR Failover

Disaster recovery failover involves promoting the read-only mirror topic to a writable regular topic on the DR cluster and switching applications to use the DR cluster.

### Understanding Failover

**Before Failover:**
```
Primary (Standard)          DR (Dedicated)
  mirrored_topic     ─────>  mirrored_topic
  (writable source)   CL     (read-only mirror)
                             ❌ Cannot write
```

**After Failover:**
```
Primary (Standard)          DR (Dedicated)
  mirrored_topic             mirrored_topic
  (writable)                 (writable - promoted)
                             ✅ Can write
                             ⚠️  Replication stopped
```

### When to Failover

Failover to DR cluster when:
- ❌ Primary cluster is unavailable (disaster)
- ❌ Primary region has outage
- 🔧 Planned maintenance on Primary cluster
- 🧪 DR testing exercises

---

### Option 1: Automated Failover (Recommended)

#### Script: `scripts/failover-mirrored-topic.sh`

**Prerequisites:**
- [Confluent CLI](https://docs.confluent.io/confluent-cli/current/install.html) installed
- Terraform applied successfully
- Mirror topic `mirrored_topic` exists and is active

**Installation (Confluent CLI):**
```bash
# macOS
brew install confluentinc/tap/cli

# Linux
curl -sL --http1.1 https://cnfl.io/cli | sh -s -- latest

# Windows
# Download from: https://docs.confluent.io/confluent-cli/current/install.html
```

#### Run the Failover Script

```bash
./scripts/failover-mirrored-topic.sh
```

#### What the Script Does

**Step 1: Pre-Failover Verification**
- ✅ Checks Confluent CLI is installed
- ✅ Extracts cluster IDs and API keys from Terraform
- ✅ Verifies mirror topic exists and is active
- ✅ Shows current cluster link status

**Step 2: Dry-Run Preview**
```bash
# Script runs this automatically:
confluent kafka mirror failover mirrored_topic \
  --link primary-to-dr-link \
  --cluster <DR-cluster-id> \
  --dry-run
```
- Shows what will happen without making changes
- Lists topics that will be promoted
- Displays cluster link impact

**Step 3: Confirmation Prompt**
```
⚠ This will PROMOTE the mirror topic to a regular writable topic on DR cluster
After promotion:
  • The topic will be WRITABLE on DR cluster
  • The cluster link for this topic will be STOPPED
  • This operation is IRREVERSIBLE

Do you want to proceed with failover? (type 'yes' to confirm):
```
- Type **`yes`** to proceed
- Any other input cancels the operation

**Step 4: Execute Failover**
```bash
# Script executes:
confluent kafka mirror failover mirrored_topic \
  --link primary-to-dr-link \
  --cluster <DR-cluster-id>
```
- Promotes mirror topic to regular topic
- Stops replication from Primary cluster
- Topic becomes writable on DR cluster

**Step 5: Post-Failover Testing**
```bash
# Script automatically:
# 1. Configures CLI for DR cluster
confluent api-key use <DR-api-key> --resource <DR-cluster-id>

# 2. Produces test messages
echo "failover-msg-1" | confluent kafka topic produce mirrored_topic

# 3. Consumes messages to verify
confluent kafka topic consume mirrored_topic --from-beginning
```

**Step 6: Kubernetes Testing**
- Tests write via kafka-tools pod
- Verifies gateway can access the promoted topic
- Confirms end-to-end functionality

#### Expected Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 1: Pre-Failover Verification
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ Confluent CLI is installed
✓ Configuration loaded

  DR Cluster ID: lkc-6kkg2xj
  Cluster Link: primary-to-dr-link
  Mirror Topic: mirrored_topic

✓ Mirror topic found: mirrored_topic
  Link Name: primary-to-dr-link
  State: ACTIVE
  Lag: 0

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 2: Preview Failover (Dry-Run)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Mirror Topics that will be promoted:
  - mirrored_topic (from link: primary-to-dr-link)

✓ Dry-run completed

⚠ This will PROMOTE the mirror topic to a regular writable topic
...
Do you want to proceed? (type 'yes' to confirm): yes

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 3: Execute Failover
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ Failover completed successfully!
✓ Topic 'mirrored_topic' is now a WRITABLE regular topic on DR cluster

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 4: Post-Failover Verification
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ API key configured for DR cluster
✓ Successfully produced 5 test messages to promoted topic!
✓ Messages successfully consumed from promoted topic on DR cluster

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Failover Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ Failover Complete!

Topic Status:
  Topic: mirrored_topic
  Cluster: lkc-6kkg2xj (DR - Dedicated)
  Status: ✅ WRITABLE (promoted from mirror)
  Cluster Link: ⚠️  STOPPED for this topic
```

---

### Option 2: Manual Failover (Step-by-Step)

For full control over each step:

#### Step 1: Get Cluster Information

```bash
cd terraform/confluent-cloud

# Extract values
DR_CLUSTER_ID=$(terraform output -raw dr_cluster_id)
DR_API_KEY=$(terraform output -raw dr_cluster_api_key)
DR_API_SECRET=$(terraform output -raw dr_cluster_api_secret)
LINK_NAME=$(terraform output -raw cluster_link_name)

# Display values
echo "DR Cluster: $DR_CLUSTER_ID"
echo "Link Name: $LINK_NAME"
```

#### Step 2: Verify Current State

```bash
# Check mirror topic status
confluent kafka mirror list \
  --link $LINK_NAME \
  --cluster $DR_CLUSTER_ID

# Check cluster link health
confluent kafka link describe $LINK_NAME \
  --cluster $DR_CLUSTER_ID
```

Expected output:
```
Mirror Topic Name    State    Source Topic       Lag
mirrored_topic       ACTIVE   mirrored_topic     0
```

#### Step 3: Preview Failover (Dry-Run)

```bash
confluent kafka mirror failover mirrored_topic \
  --link $LINK_NAME \
  --cluster $DR_CLUSTER_ID \
  --dry-run
```

This shows what will happen **without making changes**.

#### Step 4: Execute Failover

```bash
confluent kafka mirror failover mirrored_topic \
  --link $LINK_NAME \
  --cluster $DR_CLUSTER_ID
```

**⚠️ WARNING**: This operation is **irreversible**. The mirror topic will be promoted to a regular topic and replication will stop.

Confirmation prompt:
```
Are you sure you want to failover mirror topic 'mirrored_topic'? (y/n):
```
Type **`y`** to proceed.

#### Step 5: Configure CLI for DR Cluster

```bash
confluent api-key use $DR_API_KEY --resource $DR_CLUSTER_ID
```

#### Step 6: Test Write to Promoted Topic

```bash
# Produce test messages
echo -e "failover-test-1\nfailover-test-2\nfailover-test-3" | \
  confluent kafka topic produce mirrored_topic \
  --cluster $DR_CLUSTER_ID
```

Expected output:
```
Produced message to partition 0 at offset 0.
Produced message to partition 1 at offset 0.
Produced message to partition 2 at offset 0.
```

✅ **Success!** Topic is now writable.

#### Step 7: Verify Messages

```bash
confluent kafka topic consume mirrored_topic \
  --cluster $DR_CLUSTER_ID \
  --from-beginning \
  --max-messages 3
```

You should see the messages you just produced.

---

### Post-Failover: Switch Gateway to DR Cluster

After promoting the mirror topic, update the gateway to route traffic to the DR cluster.

#### Edit Gateway Configuration

```bash
nano kubernetes-resources/gateway.yaml
```

**Change lines 50-52:**

```yaml
# BEFORE (routing to Primary):
routes:
  - name: primary-route
    endpoint: "kafka.cc.axa.com:9092"
    streamingDomain:
      name: cc-primary
      bootstrapServerId: CC_PRIMARY

# AFTER (routing to DR):
routes:
  - name: dr-route
    endpoint: "kafka.cc.axa.com:9092"
    streamingDomain:
      name: cc-dr
      bootstrapServerId: CC_DR
```

#### Apply Gateway Changes

```bash
# Apply updated configuration
kubectl apply -f kubernetes-resources/gateway.yaml -n confluent

# Restart gateway pods to pick up changes
kubectl delete pod -n confluent -l app=confluent-gateway

# Wait for gateway to be ready
kubectl wait --for=condition=Ready pod \
  -l app=confluent-gateway \
  -n confluent \
  --timeout=120s
```

#### Verify Gateway Switchover

```bash
# Check which cluster the gateway is routing to
kubectl get gateway confluent-gateway -n confluent -o yaml | grep "bootstrapServerId:"

# Expected output:
# bootstrapServerId: CC_DR

# Test via gateway
kubectl exec kafka-tools -n confluent -- kafka-topics \
  --bootstrap-server kafka.cc.axa.com:9092 \
  --command-config /etc/kafka/client-dr/client-dr.properties \
  --list
```

---

### Complete DR Failover Checklist

Use this checklist for a complete DR failover:

- [ ] **Verify DR cluster is healthy**
  ```bash
  ./scripts/verify-cluster-linking.sh
  ```

- [ ] **Stop writes to Primary cluster** (application-level)

- [ ] **Wait for replication to catch up**
  ```bash
  confluent kafka mirror list --link primary-to-dr-link --cluster <DR-cluster-id>
  # Ensure lag is 0
  ```

- [ ] **Promote mirror topic**
  ```bash
  ./scripts/failover-mirrored-topic.sh
  # Type 'yes' when prompted
  ```

- [ ] **Switch gateway to DR cluster**
  ```bash
  # Edit kubernetes-resources/gateway.yaml
  # Change cc-primary to cc-dr
  kubectl apply -f kubernetes-resources/gateway.yaml -n confluent
  kubectl delete pod -n confluent -l app=confluent-gateway
  ```

- [ ] **Update application configurations**
  - Point applications to DR cluster bootstrap endpoint
  - Update connection strings, configs, etc.

- [ ] **Verify writes to DR cluster work**
  ```bash
  kubectl exec kafka-tools -n confluent -- bash -c \
    'echo "dr-test" | kafka-console-producer \
      --bootstrap-server kafka.cc.axa.com:9092 \
      --producer.config /etc/kafka/client-dr/client-dr.properties \
      --topic mirrored_topic'
  ```

- [ ] **Monitor DR cluster**
  - Check Confluent Cloud UI for cluster health
  - Monitor consumer lag
  - Verify all topics are accessible

- [ ] **Document failover**
  - Record time of failover
  - Note any issues encountered
  - Update runbooks

---

### Failback to Primary (Restore Original Setup)

After the Primary cluster issue is resolved, you may want to failback.

#### Option 1: Recreate Cluster Link (Clean Start)

```bash
cd terraform/confluent-cloud

# Re-apply Terraform to recreate cluster link and mirror topic
# Note: This will create a NEW mirror topic, starting replication fresh
terraform apply

# Wait for replication to catch up
# Monitor via Confluent Cloud UI or CLI
```

#### Option 2: Create Reverse Link (DR → Primary)

Requires creating a new cluster link configuration in Terraform from DR to Primary, then using that to fail back.

---

### Troubleshooting Failover

#### Issue: "Confluent CLI not found"

```bash
# Install Confluent CLI
brew install confluentinc/tap/cli  # macOS

# Or download from
curl -sL --http1.1 https://cnfl.io/cli | sh -s -- latest
```

#### Issue: "Mirror topic not found"

```bash
# Check if mirror topic exists
confluent kafka mirror list \
  --link primary-to-dr-link \
  --cluster <DR-cluster-id>

# If missing, verify cluster linking is active
terraform output cluster_link_status
```

#### Issue: "Failover failed - topic has lag"

```bash
# Wait for replication to catch up
confluent kafka mirror list --link primary-to-dr-link --cluster <DR-cluster-id>

# Once lag is 0, retry failover
```

#### Issue: Cannot write after failover

```bash
# Verify topic was promoted
confluent kafka topic describe mirrored_topic --cluster <DR-cluster-id>

# Check API key permissions
confluent api-key list

# Ensure using correct API key for DR cluster
confluent api-key use <DR-api-key> --resource <DR-cluster-id>
```

---

## 🧹 Cleanup

### Automated Cleanup

```bash
./destroy.sh
```

**This removes:**
- Kubernetes resources (Gateway, Operator, Pods, Secrets)
- Confluent Cloud clusters (Primary + DR)
- Cluster linking and mirror topics
- Schema Registry
- EKS cluster, VPC, and networking
- Route53 private hosted zone and gateway DNS record
- All certificates and temporary files

### Manual Cleanup

```bash
# Step 1: Delete Kubernetes resources
kubectl delete -f kubernetes-resources/gateway.yaml -n confluent
kubectl delete -f kubernetes-resources/kafka-tools.yaml -n confluent
kubectl delete secrets -n confluent --all
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent

# Step 2: Destroy Confluent Cloud resources
cd terraform/confluent-cloud
terraform destroy

# Step 3: Destroy EKS cluster
cd ../eks
terraform destroy

# Step 4: Clean up certificates
cd ../..
make clean-certs
```

---

## 📊 Cost Estimate

| Component | Monthly Cost |
|-----------|--------------|
| Primary Cluster (Standard) | ~$50-100 |
| DR Cluster (Dedicated, 1 CKU) | ~$500 |
| Schema Registry (Advanced) | Included |
| Cluster Linking | No additional cost |
| **Total Confluent Cloud** | **~$550-600** |
| EKS control plane | ~$73 |
| EC2 (2 nodes, t3.large) | ~$120 |
| NLB | ~$20 |
| VPC & Route53 | ~$5 |
| **Total AWS** | **~$218** |
| **GRAND TOTAL** | **~$768-818/month** |

---

## 📁 Repository Structure

```
.
├── README.md                        # This file
├── .env.example                     # Configuration template
├── deploy.sh                        # Automated deployment
├── destroy.sh                       # Automated cleanup
├── Makefile                         # Certificate automation
├── scripts/
│   ├── verify-cluster-linking.sh    # Verify cluster linking
│   └── failover-mirrored-topic.sh   # DR failover automation
├── terraform/
│   ├── eks/                         # AWS EKS + VPC + Route53 infrastructure
│   └── confluent-cloud/             # Confluent Cloud resources
├── kubernetes-resources/
│   ├── gateway.yaml                 # Gateway configuration
│   └── kafka-tools.yaml             # Testing pod
├── certs/                           # Generated certificates
├── gateway-tls-cert/                # Gateway TLS certificates
└── clients/                         # Client configuration files
```

---

## 🔗 Useful Links

- [Confluent Cloud Console](https://confluent.cloud)
- [Confluent CLI Installation](https://docs.confluent.io/confluent-cli/current/install.html)
- [Cluster Linking Documentation](https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/index.html)
- [DR Failover Guide](https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/disaster-recovery.html)
- [Standard vs Dedicated Clusters](https://docs.confluent.io/cloud/current/clusters/cluster-types.html)

---

## 🆘 Troubleshooting

### Issue: LoadBalancer hostname not assigned

```bash
# Check service
kubectl get svc confluent-gateway-bootstrap-lb -n confluent

# Check events
kubectl describe svc confluent-gateway-bootstrap-lb -n confluent

# Wait longer (NLB provisioning can take up to 5 minutes)
```

### Issue: Gateway pod not ready

```bash
# Check pod status
kubectl get pods -n confluent -l app=confluent-gateway

# View logs
kubectl logs -n confluent -l app=confluent-gateway --tail=100

# Check for secret issues
kubectl get secrets -n confluent
```

### Issue: Cluster linking not working

```bash
# Run verification script
./scripts/verify-cluster-linking.sh

# Check link status via Terraform
cd terraform/confluent-cloud
terraform output cluster_link_status

# Check via Confluent Cloud UI
# Go to: https://confluent.cloud/environments
# Select environment → DR cluster → Cluster Linking
```

### Issue: Cannot write to mirrored_topic on DR

**This is expected!** Mirror topics are read-only. Use the failover script to promote:

```bash
./scripts/failover-mirrored-topic.sh
```

---

**🎉 You're ready to deploy Confluent Cloud Gateway with cluster linking on AWS!**

Choose your path:
- **Quick Start**: Run `./deploy.sh` and go
- **Manual**: Follow the step-by-step guide above
