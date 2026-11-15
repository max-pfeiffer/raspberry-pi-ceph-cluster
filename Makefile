# Compatible with GNU Make 3.81 (macOS default).
SHELL         := bash
.SHELLFLAGS   := -eu -o pipefail -c
.DELETE_ON_ERROR:
.DEFAULT_GOAL := help
MAKEFLAGS     += --no-builtin-rules

# Extra arguments for ansible-playbook, e.g. make site ANSIBLE_ARGS="--limit ceph2"
ANSIBLE_ARGS ?=

# No vault arguments while no vault.yml exists (e.g. in CI), so nothing prompts.
VAULT_FILE := inventory/group_vars/all/vault.yml
VAULT_ARGS := $(if $(wildcard $(VAULT_FILE)),$(if $(wildcard .vault-pass),--vault-password-file .vault-pass,--ask-vault-pass))
# The environment is synced by the marker targets below, so commands skip the sync.
RUN        := uv run --no-sync
PLAYBOOK   := $(RUN) ansible-playbook $(VAULT_ARGS) $(ANSIBLE_ARGS)

VENV_MARKER        := .venv/.synced
COLLECTIONS_MARKER := collections/.installed
DEPS               := $(VENV_MARKER) $(COLLECTIONS_MARKER)

.PHONY: help deps hooks lint test check clean cloud-init specs ping site firmware base network ceph-prereqs ceph upgrade reboot

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-14s %s\n", $$1, $$2}'

# --- Environment ----------------------------------------------------------------

$(VENV_MARKER): pyproject.toml uv.lock .python-version
	@command -v uv >/dev/null || { echo "uv not found, see https://docs.astral.sh/uv/getting-started/installation/" >&2; exit 1; }
	uv sync --locked
	@touch $@

$(COLLECTIONS_MARKER): requirements.yml $(VENV_MARKER)
	rm -rf collections
	$(RUN) ansible-galaxy collection install -r requirements.yml -p collections
	@touch $@

deps: $(DEPS) ## Install Python, Ansible, linters and collections (only when lock files changed)

hooks: $(DEPS) ## Install the pre-commit git hooks
	$(RUN) pre-commit install

lint: $(DEPS) ## Run yamllint, ansible-lint, shellcheck and the vault encryption check
	$(RUN) yamllint .
	$(RUN) ansible-lint
	$(RUN) shellcheck scripts/*.sh
	scripts/check-vault-encrypted.sh $$(git ls-files '*vault.yml')

# A dummy SSH key keeps the rendering independent of the workstation. The output
# goes to its own directory, so it's never mistaken for the real cloud-init files.
TEST_DIR  := build/test
TEST_ARGS := -e '{"render_dir": "$(CURDIR)/$(TEST_DIR)", "admin_ssh_public_keys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVzdGtleXRlc3RrZXl0ZXN0a2V5dGVzdGtleXRlc3Rr test"]}'

test: $(DEPS) ## Syntax-check all playbooks, render cloud-init files and service specs, validate the results
	for playbook in playbooks/*.yml; do $(PLAYBOOK) --syntax-check "$$playbook"; done
	$(PLAYBOOK) $(TEST_ARGS) playbooks/render-cloud-init.yml playbooks/render-specs.yml
	$(RUN) python -c 'import sys, yaml; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]' $(TEST_DIR)/cloud-init/*/* $(TEST_DIR)/specs/*
	@if command -v cloud-init >/dev/null; then \
	  for f in $(TEST_DIR)/cloud-init/*/user-data; do cloud-init schema --config-file "$$f"; done; \
	else echo "cloud-init not installed, skipping the user-data schema check"; fi

clean: ## Remove the environment, collections and rendered files
	rm -rf .venv collections .ansible build

# --- Cluster --------------------------------------------------------------------

check: $(DEPS) ## Dry run of the complete setup on an installed cluster, showing diffs (changes nothing)
	$(PLAYBOOK) --check --diff playbooks/site.yml

cloud-init: $(DEPS) ## Render cloud-init files into build/cloud-init/<host>/
	$(PLAYBOOK) playbooks/render-cloud-init.yml

specs: $(DEPS) ## Render the cephadm service specs into build/specs/ for review
	$(PLAYBOOK) playbooks/render-specs.yml

ping: $(DEPS) ## Check SSH connectivity to all nodes
	$(RUN) ansible ceph $(VAULT_ARGS) $(ANSIBLE_ARGS) -m ansible.builtin.ping

site: $(DEPS) ## Run the complete setup (idempotent)
	$(PLAYBOOK) playbooks/site.yml

firmware: $(DEPS) ## Raspberry Pi EEPROM and config.txt
	$(PLAYBOOK) playbooks/00-firmware.yml

base: $(DEPS) ## OS baseline
	$(PLAYBOOK) playbooks/10-base.yml

network: $(DEPS) ## Network on the 2.5 GbE adapter
	$(PLAYBOOK) playbooks/20-network.yml

ceph-prereqs: $(DEPS) ## Podman, cephadm, optional OSD disk wipe (ANSIBLE_ARGS="-e wipe_osd_disks=true")
	$(PLAYBOOK) playbooks/30-ceph-prereqs.yml

ceph: $(DEPS) ## Bootstrap and converge the Ceph cluster
	$(PLAYBOOK) playbooks/40-ceph-cluster.yml

upgrade: $(DEPS) ## Upgrade Ceph to ceph_version from inventory
	$(PLAYBOOK) playbooks/upgrade-ceph.yml

reboot: $(DEPS) ## Rolling reboot, one node at a time, waiting for health
	$(PLAYBOOK) playbooks/rolling-reboot.yml
