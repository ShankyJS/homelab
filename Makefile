# Homelab Infrastructure - Ansible Playbooks

# Variables
ANSIBLE_IMAGE := homelab-ansible
DOCKER := docker
ANSIBLE_DIR := ansible
SSH_DIR := $(HOME)/.ssh

# SSH agent socket - OrbStack forwards the host agent to this path
SSH_AUTH_SOCKET := /run/host-services/ssh-auth.sock

# 1Password secret references (all secrets live in 1Password, zero vault files)
OP_BECOME_PASS_REF   := op://homelab/jetson_root_password/password
OP_GITHUB_TOKEN_REF  := op://homelab/flux_cd_token_github/credential
OP_TAILSCALE_REF     := op://homelab/jetson_tailscale_auth_key/password
OP_SA_TOKEN_REF      := op://homelab/1password_sa_jetson_k3s/credential

# Secret resolution: env vars > 1Password CLI
# In CI, set these env vars directly (from OP_SERVICE_ACCOUNT_TOKEN + op CLI or GitHub secrets)
ifndef BECOME_PASS
  ifneq ($(shell command -v op 2>/dev/null),)
    BECOME_PASS := $(shell op read '$(OP_BECOME_PASS_REF)' 2>/dev/null)
  endif
endif
ifndef GITHUB_TOKEN
  ifneq ($(shell command -v op 2>/dev/null),)
    GITHUB_TOKEN := $(shell op read '$(OP_GITHUB_TOKEN_REF)' 2>/dev/null)
  endif
endif
ifndef TAILSCALE_AUTHKEY
  ifneq ($(shell command -v op 2>/dev/null),)
    TAILSCALE_AUTHKEY := $(shell op read '$(OP_TAILSCALE_REF)' 2>/dev/null)
  endif
endif
ifndef OP_SA_TOKEN
  ifneq ($(shell command -v op 2>/dev/null),)
    OP_SA_TOKEN := $(shell op read '$(OP_SA_TOKEN_REF)' 2>/dev/null)
  endif
endif

# Docker TTY detection: use -it for interactive terminals, -i only for CI/pipes
DOCKER_TTY := $(shell [ -t 0 ] && echo "-it" || echo "-i")

# SSH mounts: only mount known_hosts and SSH agent socket when available (local dev)
# In CI (DinD runner), these don't exist — password auth is used instead
SSH_MOUNTS :=
ifneq ($(wildcard $(SSH_DIR)/known_hosts),)
  SSH_MOUNTS += -v $(SSH_DIR)/known_hosts:/root/.ssh/known_hosts:ro
endif
ifneq ($(wildcard $(SSH_AUTH_SOCKET)),)
  SSH_MOUNTS += -v $(SSH_AUTH_SOCKET):/tmp/ssh-agent.sock:ro -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
endif

# Docker run base command - mounts ansible dir and kubeconfig, SSH mounts conditional
# Secrets are passed as env vars (never mounted as files)
DOCKER_RUN := $(DOCKER) run --rm $(DOCKER_TTY) \
	-v $(shell pwd)/$(ANSIBLE_DIR):/ansible \
	-v $(shell pwd)/kubeconfig:/kubeconfig \
	$(SSH_MOUNTS) \
	-e ANSIBLE_FORCE_COLOR=1 \
	-e BECOME_PASS='$(BECOME_PASS)' \
	-e GITHUB_TOKEN='$(GITHUB_TOKEN)' \
	-e TAILSCALE_AUTHKEY='$(TAILSCALE_AUTHKEY)' \
	-e OP_SA_TOKEN='$(OP_SA_TOKEN)'

# Extra ansible-playbook args (used by CI to pass -e ansible_ssh_pass=... etc.)
ANSIBLE_EXTRA ?=

.PHONY: help build lint deploy deploy-tailscale deploy-k3s deploy-k3s-clean deploy-flux diagnose ping shell k clean

help: ## Show this help message
	@echo "Homelab Ansible - Available Commands"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Secrets are fetched automatically from 1Password CLI."
	@echo "In CI, set env vars: BECOME_PASS, GITHUB_TOKEN, TAILSCALE_AUTHKEY, OP_SA_TOKEN"

build: ## Build the Ansible Docker image
	@echo "Building Ansible Docker image..."
	@$(DOCKER) build -t $(ANSIBLE_IMAGE) .
	@echo "Image '$(ANSIBLE_IMAGE)' built successfully"

deploy: build ## Run full site playbook (common + tailscale + k3s + flux)
	@echo "Running full site playbook..."
	@$(DOCKER_RUN) $(ANSIBLE_IMAGE) site.yml $(ANSIBLE_EXTRA)

deploy-tailscale: build ## Run Tailscale-only playbook
	@echo "Running Tailscale playbook..."
	@$(DOCKER_RUN) $(ANSIBLE_IMAGE) tailscale.yml $(ANSIBLE_EXTRA)

deploy-k3s: build ## Run k3s-only playbook
	@echo "Running k3s playbook..."
	@$(DOCKER_RUN) $(ANSIBLE_IMAGE) k3s.yml $(ANSIBLE_EXTRA)

deploy-k3s-clean: build ## Run k3s playbook with clean reinstall
	@echo "Running k3s playbook (clean reinstall)..."
	@$(DOCKER_RUN) $(ANSIBLE_IMAGE) k3s.yml -e k3s_clean_install=true $(ANSIBLE_EXTRA)

deploy-flux: build ## Bootstrap FluxCD on the k3s cluster
	@echo "Running FluxCD bootstrap playbook..."
	@$(DOCKER_RUN) $(ANSIBLE_IMAGE) flux.yml $(ANSIBLE_EXTRA)

diagnose: build ## Run networking diagnostics on the Jetson
	@echo "Running diagnostics..."
	@$(DOCKER_RUN) $(ANSIBLE_IMAGE) diagnose.yml $(ANSIBLE_EXTRA)

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
