#!/bin/bash

# Confluent Cloud Terraform Setup Script
# This script helps you quickly set up your Confluent Cloud clusters

set -e

echo "========================================="
echo "Confluent Cloud Terraform Setup"
echo "========================================="
echo ""

# Check if terraform is installed
if ! command -v terraform &> /dev/null; then
    echo "Error: Terraform is not installed."
    echo "Please install Terraform from: https://www.terraform.io/downloads"
    exit 1
fi

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    echo "Creating terraform.tfvars from example..."
    cp terraform.tfvars.example terraform.tfvars
    echo ""
    echo "IMPORTANT: Please edit terraform.tfvars and add your Confluent Cloud credentials:"
    echo "  - confluent_cloud_api_key"
    echo "  - confluent_cloud_api_secret"
    echo ""
    echo "Get your API credentials from: https://confluent.cloud/settings/api-keys"
    echo ""
    read -p "Press Enter after you've updated terraform.tfvars..."
fi

# Verify credentials are set
if grep -q "YOUR_CONFLUENT_CLOUD_API_KEY" terraform.tfvars; then
    echo "Error: Please update the Confluent Cloud API credentials in terraform.tfvars"
    exit 1
fi

echo "Step 1: Initializing Terraform..."
terraform init

echo ""
echo "Step 2: Validating configuration..."
terraform validate

echo ""
echo "Step 3: Planning deployment..."
terraform plan -out=tfplan

echo ""
echo "========================================="
echo "Ready to deploy!"
echo "========================================="
echo ""
echo "This will create:"
echo "  - 1 Confluent Cloud Environment"
echo "  - 1 Kafka Cluster in AWS us-east-1"
echo "  - 1 Kafka Cluster in GCP us-west1"
echo "  - 2 Service Accounts (one per cluster)"
echo "  - 2 API Keys (one per cluster)"
echo ""
read -p "Do you want to proceed with deployment? (yes/no): " confirm

if [ "$confirm" = "yes" ]; then
    echo ""
    echo "Deploying clusters... (This may take 5-10 minutes)"
    terraform apply tfplan

    echo ""
    echo "========================================="
    echo "Deployment Complete!"
    echo "========================================="
    echo ""
    echo "To view cluster details:"
    echo "  terraform output connection_details"
    echo ""
    echo "To get API keys (for connecting to clusters):"
    echo "  terraform output -json aws_cluster_api_key"
    echo "  terraform output -json aws_cluster_api_secret"
    echo "  terraform output -json gcp_cluster_api_key"
    echo "  terraform output -json gcp_cluster_api_secret"
    echo ""
else
    echo "Deployment cancelled."
    rm -f tfplan
    exit 0
fi
