# Homelab Infrastructure - Ansible Playbooks

# Variables
ANSIBLE_IMAGE := homelab-ansible
DOCKER := docker
ANSIBLE_DIR := ansible
SSH_DIR := $(HOME)/.ssh
VAULT_PASS_FILE := .vault-password

# SSH agent socket - OrbStack forwards the host agent to this path
SSH_AUTH_SOCKET := /run/host-services/ssh-auth.sock

# Docker run base command - mounts ansible dir, SSH known_hosts, and forwards SSH agent
DOCKER_RUN := $(DOCKER) run --rm -it \
	-v $(shell pwd)/$(ANSIBLE_DIR):/ansible \
	-v $(shell pwd)/kubeconfig:/kubeconfig \
	-v $(SSH_DIR)/known_hosts:/root/.ssh/known_hosts:ro \
	-v $(SSH_AUTH_SOCKET):/tmp/ssh-agent.sock:ro \
	-e SSH_AUTH_SOCK=/tmp/ssh-agent.sock \
	-e ANSIBLE_FORCE_COLOR=1

# 1Password secret reference for vault password
OP_VAULT_REF := op://Private/jetson-ansible-playbook/password

# Vault password resolution: VAULT_PASSWORD env var > 1Password CLI > .vault-password file > interactive prompt
ifndef VAULT_PASSWORD
  ifneq ($(shell command -v op 2>/dev/null),)
    VAULT_PASSWORD := $(shell op read '$(OP_VAULT_REF)' 2>/dev/null)
  endif
endif

ifdef VAULT_PASSWORD
VAULT_ARGS := -e VAULT_PASSWORD='$(VAULT_PASSWORD)'
VAULT_FLAG := --vault-password-file /tmp/vault-pass-env.sh
else ifneq ($(wildcard $(VAULT_PASS_FILE)),)
VAULT_ARGS := -v $(shell pwd)/$(VAULT_PASS_FILE):/tmp/.vault-password:ro
VAULT_FLAG := --vault-password-file /tmp/.vault-password
else
VAULT_ARGS :=
VAULT_FLAG := --ask-vault-pass
endif

.PHONY: help build lint setup deploy deploy-tailscale deploy-k3s deploy-k3s-clean ping shell k vault-encrypt vault-edit clean

help: ## Show this help message
	@echo "Homelab Ansible - Available Commands"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "First time setup:"
	@echo "  make build                          # Build the Ansible Docker image"
	@echo "  make setup                          # Setup vault secrets"
	@echo "  make ping                           # Verify SSH connectivity"
	@echo "  make deploy                         # Run full playbook"

build: ## Build the Ansible Docker image
	@echo "Building Ansible Docker image..."
	@$(DOCKER) build -t $(ANSIBLE_IMAGE) .
	@echo "Image '$(ANSIBLE_IMAGE)' built successfully"

deploy: build ## Run full site playbook (common + tailscale + k3s)
	@echo "Running full site playbook..."
	@$(DOCKER_RUN) $(VAULT_ARGS) $(ANSIBLE_IMAGE) site.yml $(VAULT_FLAG)

deploy-tailscale: build ## Run Tailscale-only playbook
	@echo "Running Tailscale playbook..."
	@$(DOCKER_RUN) $(VAULT_ARGS) $(ANSIBLE_IMAGE) tailscale.yml $(VAULT_FLAG)

deploy-k3s: build ## Run k3s-only playbook
	@echo "Running k3s playbook..."
	@$(DOCKER_RUN) $(VAULT_ARGS) $(ANSIBLE_IMAGE) k3s.yml $(VAULT_FLAG)

deploy-k3s-clean: build ## Run k3s playbook with clean reinstall
	@echo "Running k3s playbook (clean reinstall)..."
	@$(DOCKER_RUN) $(VAULT_ARGS) $(ANSIBLE_IMAGE) k3s.yml $(VAULT_FLAG) -e k3s_clean_install=true

ping: build ## Ping all hosts to verify SSH connectivity
	@$(DOCKER_RUN) \
		--entrypoint ansible \
		$(ANSIBLE_IMAGE) all -m ping

lint: build ## Lint all playbooks and roles
	@echo "Linting Ansible playbooks..."
	@$(DOCKER) run --rm \
		-v $(shell pwd)/$(ANSIBLE_DIR):/ansible \
		--entrypoint ansible-lint \
		$(ANSIBLE_IMAGE) .

shell: build ## Open a shell in the Ansible container
	@$(DOCKER_RUN) \
		--entrypoint /bin/bash \
		$(ANSIBLE_IMAGE)

setup: build ## Setup vault secrets (copy template and encrypt)
	@if [ ! -f $(ANSIBLE_DIR)/vault.yml ]; then \
		cp $(ANSIBLE_DIR)/vault.yml.example $(ANSIBLE_DIR)/vault.yml; \
		echo "Created ansible/vault.yml from template."; \
		echo ""; \
		echo "Next steps:"; \
		echo "  1. Edit secrets:  $${EDITOR:-vim} $(ANSIBLE_DIR)/vault.yml"; \
		echo "  2. Encrypt it:    make vault-encrypt"; \
		echo ""; \
		echo "Optionally, set vault password (auto-detected from 1Password if 'op' CLI is available):"; \
		echo "  VAULT_PASSWORD=<password> make ...   # explicit env var"; \
		echo "  echo 'your-vault-password' > .vault-password  # file-based"; \
	else \
		echo "vault.yml already exists. Use 'make vault-edit' to modify."; \
	fi

vault-encrypt: build ## Encrypt the vault file
	@echo "Encrypting vault..."
	@$(DOCKER) run --rm -it \
		-v $(shell pwd)/$(ANSIBLE_DIR):/ansible \
		$(VAULT_ARGS) \
		--entrypoint sh \
		$(ANSIBLE_IMAGE) -c '\
		if [ -n "$$VAULT_PASSWORD" ]; then \
			printf "#!/bin/sh\nprintf \"%%s\" \"$$VAULT_PASSWORD\"\n" > /tmp/vault-pass-env.sh && chmod +x /tmp/vault-pass-env.sh; \
			ansible-vault encrypt vault.yml --vault-password-file /tmp/vault-pass-env.sh; \
		elif [ -f /tmp/.vault-password ]; then \
			ansible-vault encrypt vault.yml --vault-password-file /tmp/.vault-password; \
		else \
			ansible-vault encrypt vault.yml; \
		fi'

vault-edit: build ## Edit the encrypted vault file
	@$(DOCKER) run --rm -it \
		-v $(shell pwd)/$(ANSIBLE_DIR):/ansible \
		$(VAULT_ARGS) \
		-e EDITOR=vi \
		--entrypoint sh \
		$(ANSIBLE_IMAGE) -c '\
		if [ -n "$$VAULT_PASSWORD" ]; then \
			printf "#!/bin/sh\nprintf \"%%s\" \"$$VAULT_PASSWORD\"\n" > /tmp/vault-pass-env.sh && chmod +x /tmp/vault-pass-env.sh; \
			ansible-vault edit vault.yml --vault-password-file /tmp/vault-pass-env.sh; \
		elif [ -f /tmp/.vault-password ]; then \
			ansible-vault edit vault.yml --vault-password-file /tmp/.vault-password; \
		else \
			ansible-vault edit vault.yml; \
		fi'

clean: ## Remove the Docker image
	@echo "Removing Ansible Docker image..."
	@$(DOCKER) rmi $(ANSIBLE_IMAGE) 2>/dev/null || true
	@echo "Cleanup complete"

k: ## Run kubectl against the k3s cluster (usage: make k c="get nodes")
	@if [ ! -f kubeconfig/jetson.yaml ]; then \
		echo "Error: kubeconfig/jetson.yaml not found. Run 'make deploy-k3s' first."; \
		exit 1; \
	fi
	@KUBECONFIG=$(shell pwd)/kubeconfig/jetson.yaml kubectl $(c)
