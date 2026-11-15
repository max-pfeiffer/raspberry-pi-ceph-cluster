VENV        ?= .venv
BIN         := $(VENV)/bin
VAULT_ARGS  := $(if $(wildcard .vault-pass),--vault-password-file .vault-pass,--ask-vault-pass)
PLAYBOOK    := $(BIN)/ansible-playbook $(VAULT_ARGS) $(ARGS)

.PHONY: help deps lint cloud-init ping site firmware base network ceph-prereqs ceph upgrade reboot

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

deps: ## Create virtualenv and install Ansible + collections
	python3 -m venv $(VENV)
	$(BIN)/pip install -r requirements.txt
	$(BIN)/ansible-galaxy collection install -r requirements.yml

lint: ## Run yamllint and ansible-lint
	$(BIN)/yamllint .
	$(BIN)/ansible-lint

cloud-init: ## Render cloud-init files into build/cloud-init/<host>/
	$(PLAYBOOK) playbooks/render-cloud-init.yml

ping: ## Check SSH connectivity to all nodes
	$(BIN)/ansible ceph $(VAULT_ARGS) -m ansible.builtin.ping

site: ## Run the complete setup (idempotent)
	$(PLAYBOOK) playbooks/site.yml

firmware: ## Raspberry Pi EEPROM and config.txt
	$(PLAYBOOK) playbooks/00-firmware.yml

base: ## OS baseline
	$(PLAYBOOK) playbooks/10-base.yml

network: ## Public and cluster network
	$(PLAYBOOK) playbooks/20-network.yml

ceph-prereqs: ## Podman, cephadm, optional OSD disk wipe (ARGS="-e wipe_osd_disks=true")
	$(PLAYBOOK) playbooks/30-ceph-prereqs.yml

ceph: ## Bootstrap and converge the Ceph cluster
	$(PLAYBOOK) playbooks/40-ceph-cluster.yml

upgrade: ## Upgrade Ceph to ceph_version from inventory
	$(PLAYBOOK) playbooks/upgrade-ceph.yml

reboot: ## Rolling reboot, one node at a time, waiting for health
	$(PLAYBOOK) playbooks/rolling-reboot.yml
