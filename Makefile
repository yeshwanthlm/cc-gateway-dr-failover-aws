# =============================================================================
# Confluent Cloud Gateway Demo - Certificate Management Makefile
# =============================================================================
# This Makefile automates all certificate-related operations
#
# Usage:
#   make certs              - Create all certificates and secrets
#   make confluent-certs    - Download and convert Confluent Cloud certificates
#   make gateway-certs      - Generate gateway TLS certificates
#   make client-configs     - Create client configuration files
#   make k8s-secrets        - Create all Kubernetes secrets
#   make clean-certs        - Remove all generated certificates
#   make verify-certs       - Verify all certificates are created
#   make help               - Show this help message
# =============================================================================

# Load environment variables from .env file
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

# Default values if not set in .env
JKS_PASSWORD ?= confluent
CLIENT_TRUSTSTORE_PASSWORD ?= clienttrustpass
GATEWAY_DOMAIN ?= kafka.cc.axa.com
CERT_COUNTRY ?= US
CERT_STATE ?= CA
CERT_CITY ?= Mountain View
CERT_ORG ?= Confluent
CERT_OU ?= Engineering

# Directories
CERTS_DIR := certs
GATEWAY_CERT_DIR := gateway-tls-cert
CLIENTS_DIR := clients
TMP_DIR := /tmp

# Color output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m

# Default target
.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help message
	@echo "$(BLUE)Confluent Cloud Gateway - Certificate Management$(NC)"
	@echo ""
	@echo "$(GREEN)Available targets:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(GREEN)Configuration (from .env):$(NC)"
	@echo "  GATEWAY_DOMAIN: $(GATEWAY_DOMAIN)"
	@echo "  JKS_PASSWORD: ***"
	@echo "  CLIENT_TRUSTSTORE_PASSWORD: ***"

.PHONY: check-env
check-env: ## Check if required environment variables are set
	@echo "$(BLUE)Checking environment configuration...$(NC)"
	@if [ -z "$(PRIMARY_CLUSTER_ENDPOINT)" ]; then \
		echo "$(RED)✗ PRIMARY_CLUSTER_ENDPOINT not set$(NC)"; \
		echo "$(YELLOW)Run terraform in terraform/confluent-cloud/ first or set manually$(NC)"; \
		exit 1; \
	fi
	@if [ -z "$(DR_CLUSTER_ENDPOINT)" ]; then \
		echo "$(RED)✗ DR_CLUSTER_ENDPOINT not set$(NC)"; \
		echo "$(YELLOW)Run terraform in terraform/confluent-cloud/ first or set manually$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Environment configuration OK$(NC)"

.PHONY: certs
certs: confluent-certs gateway-certs client-configs ## Create all certificates and configurations
	@echo "$(GREEN)✓ All certificates created successfully$(NC)"

.PHONY: confluent-certs
confluent-certs: ## Download and convert Confluent Cloud certificates
	@echo "$(BLUE)Downloading Confluent Cloud certificates...$(NC)"
	@if [ -z "$(PRIMARY_CLUSTER_ENDPOINT)" ] || [ -z "$(DR_CLUSTER_ENDPOINT)" ]; then \
		echo "$(YELLOW)⚠ Cluster endpoints not set. Getting from Terraform...$(NC)"; \
		cd terraform/confluent-cloud && \
		export PRIMARY_CLUSTER_ENDPOINT=$$(terraform output -raw primary_cluster_bootstrap_endpoint 2>/dev/null | sed 's/SASL_SSL:\/\///') && \
		export DR_CLUSTER_ENDPOINT=$$(terraform output -raw dr_cluster_bootstrap_endpoint 2>/dev/null | sed 's/SASL_SSL:\/\///') && \
		echo "PRIMARY_CLUSTER_ENDPOINT=$$PRIMARY_CLUSTER_ENDPOINT" >> ../../.env && \
		echo "DR_CLUSTER_ENDPOINT=$$DR_CLUSTER_ENDPOINT" >> ../../.env && \
		cd ../.. ; \
	fi
	@# Reload env after update
	$(eval PRIMARY_CLUSTER_ENDPOINT := $(shell grep PRIMARY_CLUSTER_ENDPOINT .env 2>/dev/null | cut -d= -f2))
	$(eval DR_CLUSTER_ENDPOINT := $(shell grep DR_CLUSTER_ENDPOINT .env 2>/dev/null | cut -d= -f2))
	@echo "$(BLUE)  Primary Cluster: $(PRIMARY_CLUSTER_ENDPOINT)$(NC)"
	@echo "$(BLUE)  DR Cluster: $(DR_CLUSTER_ENDPOINT)$(NC)"
	@# Download Primary cluster certificates
	@echo "$(BLUE)Downloading Primary cluster certificates...$(NC)"
	@cd $(CERTS_DIR) && ./download-cc-certs.sh $(PRIMARY_CLUSTER_ENDPOINT)
	@# Download DR cluster certificates
	@echo "$(BLUE)Downloading DR cluster certificates...$(NC)"
	@cd $(CERTS_DIR) && ./download-cc-certs.sh $(DR_CLUSTER_ENDPOINT)
	@# Convert to JKS format
	@$(MAKE) convert-to-jks
	@echo "$(GREEN)✓ Confluent Cloud certificates ready$(NC)"

.PHONY: convert-to-jks
convert-to-jks: ## Convert PKCS12 truststores to JKS format
	@echo "$(BLUE)Converting truststores to JKS format...$(NC)"
	@# Get cluster hostnames
	$(eval PRIMARY_HOST := $(shell echo $(PRIMARY_CLUSTER_ENDPOINT) | cut -d: -f1))
	$(eval DR_HOST := $(shell echo $(DR_CLUSTER_ENDPOINT) | cut -d: -f1))
	@# Convert Primary cluster truststore
	@echo "$(BLUE)  Converting Primary cluster truststore...$(NC)"
	@keytool -importkeystore \
		-srckeystore $(CERTS_DIR)/ssl/$(PRIMARY_HOST)/truststore.p12 \
		-srcstoretype PKCS12 \
		-srcstorepass confluent \
		-destkeystore $(TMP_DIR)/cc-primary-truststore.jks \
		-deststoretype JKS \
		-deststorepass $(JKS_PASSWORD) \
		-noprompt > /dev/null 2>&1
	@# Convert DR cluster truststore
	@echo "$(BLUE)  Converting DR cluster truststore...$(NC)"
	@keytool -importkeystore \
		-srckeystore $(CERTS_DIR)/ssl/$(DR_HOST)/truststore.p12 \
		-srcstoretype PKCS12 \
		-srcstorepass confluent \
		-destkeystore $(TMP_DIR)/cc-dr-truststore.jks \
		-deststoretype JKS \
		-deststorepass $(JKS_PASSWORD) \
		-noprompt > /dev/null 2>&1
	@# Create password file in properties format
	@echo "jksPassword=$(JKS_PASSWORD)" > $(TMP_DIR)/jksPassword.txt
	@echo "$(GREEN)✓ Truststores converted to JKS$(NC)"

.PHONY: gateway-certs
gateway-certs: ## Generate gateway TLS certificates
	@echo "$(BLUE)Generating gateway TLS certificates...$(NC)"
	@mkdir -p $(GATEWAY_CERT_DIR)
	@# Generate CA
	@echo "$(BLUE)  Generating Certificate Authority...$(NC)"
	@openssl genrsa -out $(GATEWAY_CERT_DIR)/ca-key.pem 2048 2>/dev/null
	@openssl req -new -x509 -key $(GATEWAY_CERT_DIR)/ca-key.pem \
		-out $(GATEWAY_CERT_DIR)/cacerts.pem -days 365 \
		-subj "/C=$(CERT_COUNTRY)/ST=$(CERT_STATE)/L=$(CERT_CITY)/O=$(CERT_ORG)/OU=$(CERT_OU)/CN=Gateway Test CA" \
		2>/dev/null
	@# Create SAN configuration
	@echo "$(BLUE)  Creating SAN configuration...$(NC)"
	@printf '[req]\n\
distinguished_name = req_distinguished_name\n\
req_extensions = v3_req\n\
prompt = no\n\
\n\
[req_distinguished_name]\n\
C = $(CERT_COUNTRY)\n\
ST = $(CERT_STATE)\n\
L = $(CERT_CITY)\n\
O = $(CERT_ORG)\n\
OU = $(CERT_OU)\n\
CN = $(GATEWAY_DOMAIN)\n\
\n\
[v3_req]\n\
keyUsage = critical, digitalSignature, keyEncipherment\n\
extendedKeyUsage = serverAuth\n\
subjectAltName = @alt_names\n\
\n\
[alt_names]\n\
DNS.1 = $(GATEWAY_DOMAIN)\n\
DNS.2 = *.$(GATEWAY_DOMAIN)\n' > $(GATEWAY_CERT_DIR)/gateway-san.cnf
	@# Generate gateway certificate
	@echo "$(BLUE)  Generating gateway certificate...$(NC)"
	@openssl genrsa -out $(GATEWAY_CERT_DIR)/gateway-key.pem 2048 2>/dev/null
	@openssl req -new -key $(GATEWAY_CERT_DIR)/gateway-key.pem \
		-out $(GATEWAY_CERT_DIR)/gateway.csr \
		-config $(GATEWAY_CERT_DIR)/gateway-san.cnf 2>/dev/null
	@openssl x509 -req -in $(GATEWAY_CERT_DIR)/gateway.csr \
		-CA $(GATEWAY_CERT_DIR)/cacerts.pem \
		-CAkey $(GATEWAY_CERT_DIR)/ca-key.pem \
		-CAcreateserial -out $(GATEWAY_CERT_DIR)/gateway-cert.pem \
		-days 365 -extensions v3_req \
		-extfile $(GATEWAY_CERT_DIR)/gateway-san.cnf 2>/dev/null
	@# Create fullchain
	@cat $(GATEWAY_CERT_DIR)/gateway-cert.pem $(GATEWAY_CERT_DIR)/cacerts.pem > $(GATEWAY_CERT_DIR)/fullchain.pem
	@# Create gateway truststore for clients
	@echo "$(BLUE)  Creating gateway truststore for clients...$(NC)"
	@rm -f $(TMP_DIR)/gateway-truststore.jks
	@keytool -import -trustcacerts -alias gateway-ca \
		-file $(GATEWAY_CERT_DIR)/cacerts.pem \
		-keystore $(TMP_DIR)/gateway-truststore.jks \
		-storepass $(CLIENT_TRUSTSTORE_PASSWORD) \
		-noprompt > /dev/null 2>&1 || { \
		echo "$(RED)✗ Failed to create gateway truststore$(NC)"; \
		exit 1; \
	}
	@echo "$(GREEN)✓ Gateway certificates generated$(NC)"

.PHONY: client-configs
client-configs: ## Create client configuration files
	@echo "$(BLUE)Creating client configuration files...$(NC)"
	@mkdir -p $(CLIENTS_DIR)
	@# Get API keys from .env (already populated by deploy.sh from Terraform)
	$(eval PRIMARY_CLUSTER_API_KEY := $(shell grep "^PRIMARY_CLUSTER_API_KEY=" .env 2>/dev/null | tail -1 | cut -d= -f2))
	$(eval PRIMARY_CLUSTER_API_SECRET := $(shell grep "^PRIMARY_CLUSTER_API_SECRET=" .env 2>/dev/null | tail -1 | cut -d= -f2))
	$(eval DR_CLUSTER_API_KEY := $(shell grep "^DR_CLUSTER_API_KEY=" .env 2>/dev/null | tail -1 | cut -d= -f2))
	$(eval DR_CLUSTER_API_SECRET := $(shell grep "^DR_CLUSTER_API_SECRET=" .env 2>/dev/null | tail -1 | cut -d= -f2))
	@# Verify API keys are set
	@if [ -z "$(PRIMARY_CLUSTER_API_KEY)" ] || [ -z "$(DR_CLUSTER_API_KEY)" ]; then \
		echo "$(RED)✗ Cluster API keys not found in .env file$(NC)"; \
		echo "$(YELLOW)Run terraform in terraform/confluent-cloud/ first$(NC)"; \
		exit 1; \
	fi
	@# Create primary cluster config
	@echo "$(BLUE)  Creating primary cluster config...$(NC)"
	@printf 'security.protocol=SASL_SSL\n\
sasl.mechanism=PLAIN\n\
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$(PRIMARY_CLUSTER_API_KEY)" password="$(PRIMARY_CLUSTER_API_SECRET)";\n\
ssl.truststore.location=/etc/kafka/tls/truststore.jks\n\
ssl.truststore.password=$(CLIENT_TRUSTSTORE_PASSWORD)\n\
ssl.endpoint.identification.algorithm=\n' > $(CLIENTS_DIR)/client-primary.properties
	@# Create DR cluster config
	@echo "$(BLUE)  Creating DR cluster config...$(NC)"
	@printf 'security.protocol=SASL_SSL\n\
sasl.mechanism=PLAIN\n\
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$(DR_CLUSTER_API_KEY)" password="$(DR_CLUSTER_API_SECRET)";\n\
ssl.truststore.location=/etc/kafka/tls/truststore.jks\n\
ssl.truststore.password=$(CLIENT_TRUSTSTORE_PASSWORD)\n\
ssl.endpoint.identification.algorithm=\n' > $(CLIENTS_DIR)/client-dr.properties
	@echo "$(GREEN)✓ Client configuration files created$(NC)"

.PHONY: k8s-secrets
k8s-secrets: ## Create all Kubernetes secrets
	@echo "$(BLUE)Creating Kubernetes secrets...$(NC)"
	@# Check kubectl connection
	@if ! kubectl cluster-info > /dev/null 2>&1; then \
		echo "$(RED)✗ Cannot connect to Kubernetes cluster$(NC)"; \
		exit 1; \
	fi
	@# Check namespace
	@if ! kubectl get namespace confluent > /dev/null 2>&1; then \
		echo "$(YELLOW)⚠ Creating confluent namespace...$(NC)"; \
		kubectl create namespace confluent; \
	fi
	@# Create Confluent Cloud TLS secrets
	@echo "$(BLUE)  Creating Confluent Cloud TLS secrets...$(NC)"
	@kubectl -n confluent create secret generic cc-primary-tls \
		--from-file=truststore.jks=$(TMP_DIR)/cc-primary-truststore.jks \
		--from-file=jksPassword.txt=$(TMP_DIR)/jksPassword.txt \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl -n confluent create secret generic cc-dr-tls \
		--from-file=truststore.jks=$(TMP_DIR)/cc-dr-truststore.jks \
		--from-file=jksPassword.txt=$(TMP_DIR)/jksPassword.txt \
		--dry-run=client -o yaml | kubectl apply -f -
	@# Create gateway TLS secret
	@echo "$(BLUE)  Creating gateway TLS secret...$(NC)"
	@kubectl create secret generic gateway-tls -n confluent \
		--from-file=fullchain.pem=$(GATEWAY_CERT_DIR)/fullchain.pem \
		--from-file=privkey.pem=$(GATEWAY_CERT_DIR)/gateway-key.pem \
		--from-file=cacerts.pem=$(GATEWAY_CERT_DIR)/cacerts.pem \
		--dry-run=client -o yaml | kubectl apply -f -
	@# Create gateway truststore secret
	@echo "$(BLUE)  Creating gateway truststore secret...$(NC)"
	@kubectl create secret generic gateway-truststore -n confluent \
		--from-file=truststore.jks=$(TMP_DIR)/gateway-truststore.jks \
		--from-literal=password=$(CLIENT_TRUSTSTORE_PASSWORD) \
		--dry-run=client -o yaml | kubectl apply -f -
	@# Create client config secrets
	@echo "$(BLUE)  Creating client configuration secrets...$(NC)"
	@kubectl -n confluent create secret generic client-primary \
		--from-file=client-primary.properties=$(CLIENTS_DIR)/client-primary.properties \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl -n confluent create secret generic client-dr \
		--from-file=client-dr.properties=$(CLIENTS_DIR)/client-dr.properties \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "$(GREEN)✓ All Kubernetes secrets created$(NC)"

.PHONY: verify-certs
verify-certs: ## Verify all certificates are created
	@echo "$(BLUE)Verifying certificates...$(NC)"
	@# Check Confluent Cloud certs
	@echo "$(BLUE)  Checking Confluent Cloud truststores...$(NC)"
	@if [ -f "$(TMP_DIR)/cc-primary-truststore.jks" ]; then \
		echo "$(GREEN)    ✓ Primary cluster truststore (JKS)$(NC)"; \
	else \
		echo "$(RED)    ✗ Primary cluster truststore missing$(NC)"; \
	fi
	@if [ -f "$(TMP_DIR)/cc-dr-truststore.jks" ]; then \
		echo "$(GREEN)    ✓ DR cluster truststore (JKS)$(NC)"; \
	else \
		echo "$(RED)    ✗ DR cluster truststore missing$(NC)"; \
	fi
	@# Check gateway certs
	@echo "$(BLUE)  Checking gateway certificates...$(NC)"
	@if [ -f "$(GATEWAY_CERT_DIR)/cacerts.pem" ]; then \
		echo "$(GREEN)    ✓ Gateway CA certificate$(NC)"; \
	else \
		echo "$(RED)    ✗ Gateway CA certificate missing$(NC)"; \
	fi
	@if [ -f "$(GATEWAY_CERT_DIR)/gateway-cert.pem" ]; then \
		echo "$(GREEN)    ✓ Gateway certificate$(NC)"; \
	else \
		echo "$(RED)    ✗ Gateway certificate missing$(NC)"; \
	fi
	@if [ -f "$(GATEWAY_CERT_DIR)/fullchain.pem" ]; then \
		echo "$(GREEN)    ✓ Gateway fullchain$(NC)"; \
	else \
		echo "$(RED)    ✗ Gateway fullchain missing$(NC)"; \
	fi
	@if [ -f "$(TMP_DIR)/gateway-truststore.jks" ]; then \
		echo "$(GREEN)    ✓ Gateway truststore (JKS)$(NC)"; \
	else \
		echo "$(RED)    ✗ Gateway truststore missing$(NC)"; \
	fi
	@# Check client configs
	@echo "$(BLUE)  Checking client configurations...$(NC)"
	@if [ -f "$(CLIENTS_DIR)/client-primary.properties" ]; then \
		echo "$(GREEN)    ✓ Primary cluster client config$(NC)"; \
	else \
		echo "$(RED)    ✗ Primary cluster client config missing$(NC)"; \
	fi
	@if [ -f "$(CLIENTS_DIR)/client-dr.properties" ]; then \
		echo "$(GREEN)    ✓ DR cluster client config$(NC)"; \
	else \
		echo "$(RED)    ✗ DR cluster client config missing$(NC)"; \
	fi
	@# Verify certificate contents
	@echo "$(BLUE)  Verifying certificate validity...$(NC)"
	@openssl x509 -in $(GATEWAY_CERT_DIR)/gateway-cert.pem -noout -subject -dates 2>/dev/null || true
	@echo "$(GREEN)✓ Certificate verification complete$(NC)"

.PHONY: list-k8s-secrets
list-k8s-secrets: ## List all Kubernetes secrets in confluent namespace
	@echo "$(BLUE)Kubernetes secrets in confluent namespace:$(NC)"
	@kubectl get secrets -n confluent 2>/dev/null || echo "$(YELLOW)⚠ Cannot access confluent namespace$(NC)"

.PHONY: clean-certs
clean-certs: ## Remove all generated certificates and temporary files
	@echo "$(YELLOW)Cleaning up certificates...$(NC)"
	@rm -rf $(CERTS_DIR)/ssl/*
	@rm -f $(GATEWAY_CERT_DIR)/*.pem $(GATEWAY_CERT_DIR)/*.csr $(GATEWAY_CERT_DIR)/*.srl $(GATEWAY_CERT_DIR)/*.cnf
	@rm -f $(TMP_DIR)/cc-primary-truststore.jks
	@rm -f $(TMP_DIR)/cc-dr-truststore.jks
	@rm -f $(TMP_DIR)/gateway-truststore.jks
	@rm -f $(TMP_DIR)/jksPassword.txt
	@rm -f $(TMP_DIR)/gateway-ca.pem
	@rm -f $(CLIENTS_DIR)/client-primary.properties
	@rm -f $(CLIENTS_DIR)/client-dr.properties
	@echo "$(GREEN)✓ Certificates cleaned$(NC)"

.PHONY: clean-k8s-secrets
clean-k8s-secrets: ## Delete all Kubernetes secrets
	@echo "$(YELLOW)Deleting Kubernetes secrets...$(NC)"
	@kubectl delete secret -n confluent \
		cc-primary-tls \
		cc-dr-tls \
		gateway-tls \
		gateway-truststore \
		client-primary \
		client-dr \
		2>/dev/null || echo "$(YELLOW)⚠ Some secrets not found$(NC)"
	@echo "$(GREEN)✓ Kubernetes secrets deleted$(NC)"

.PHONY: clean
clean: clean-certs clean-k8s-secrets ## Remove all certificates and Kubernetes secrets
	@echo "$(GREEN)✓ Complete cleanup done$(NC)"
