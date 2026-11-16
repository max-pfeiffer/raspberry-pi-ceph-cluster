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

.PHONY: help deps hooks lint test check-pins check clean cloud-init cloud-init-copy specs ping site firmware base network ceph-prereqs ceph upgrade reboot

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

lint: $(DEPS) ## Run yamllint, ansible-lint, shellcheck, actionlint and the vault encryption check
	$(RUN) yamllint .
	$(RUN) ansible-lint
	$(RUN) shellcheck scripts/*.sh tests/integration/*.sh
	$(RUN) actionlint
	scripts/check-vault-encrypted.sh $$(git ls-files '*vault.yml')

# Runs against a copy of the inventory without vault.yml, with dummy secrets and
# a dummy SSH key: no vault password is needed (CI, Dependabot and fork PRs have
# none) and the result doesn't depend on the workstation. The output goes to its
# own directory, so it's never mistaken for the real cloud-init files.
TEST_DIR      := build/test
TEST_ARGS     := -e '{"render_dir": "$(CURDIR)/$(TEST_DIR)", "vault_ceph_dashboard_password": "test-password-not-used", "vault_ceph_grafana_password": "test-password-not-used", "admin_ssh_public_keys": ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGVzdGtleXRlc3RrZXl0ZXN0a2V5dGVzdGtleXRlc3Rr test"]}'
TEST_PLAYBOOK := $(RUN) ansible-playbook -i $(TEST_DIR)/inventory/hosts.yml $(TEST_ARGS)

# The validators only exist on Linux. Locally they're skipped when missing; CI must have them.
SKIP_OR_FAIL = if [ -n "$${CI:-}" ]; then echo "$(1) is required in CI" >&2; exit 1; else echo "$(1) not installed, skipping its checks"; fi

test: $(DEPS) ## Syntax-check all playbooks, render and validate cloud-init files, netplan and service specs (needs no vault password)
	rm -rf $(TEST_DIR)
	mkdir -p $(TEST_DIR)
	cp -R inventory $(TEST_DIR)/inventory
	rm -f $(TEST_DIR)/$(VAULT_FILE)
	for playbook in playbooks/*.yml tests/*.yml tests/integration/health.yml; do $(TEST_PLAYBOOK) --syntax-check "$$playbook"; done
	$(TEST_PLAYBOOK) playbooks/render-cloud-init.yml playbooks/render-specs.yml tests/render-netplan.yml
	$(RUN) python -c 'import sys, yaml; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]' $(TEST_DIR)/cloud-init/*/* $(TEST_DIR)/specs/*
	@if command -v cloud-init >/dev/null; then \
	  for d in $(TEST_DIR)/cloud-init/*; do \
	    cloud-init schema --config-file "$$d/user-data"; \
	    cloud-init schema --config-file "$$d/network-config" --schema-type network-config; \
	  done; \
	else $(call SKIP_OR_FAIL,cloud-init); fi
	@# An absolute path: netplan's generator resolves a relative --root-dir against /.
	@if command -v netplan >/dev/null; then \
	  for d in $(CURDIR)/$(TEST_DIR)/netplan/*; do echo "netplan generate: $$d"; netplan generate --root-dir "$$d"; done; \
	else $(call SKIP_OR_FAIL,netplan); fi

check-pins: ## Check that the cephadm checksum and image digest in the inventory belong to ceph_version (needs network)
	@pins=$$(scripts/ceph-release-pins.sh "$$(sed -n 's/^ceph_version: "\(.*\)"$$/\1/p' inventory/group_vars/ceph/main.yml)"); \
	echo "$$pins"; \
	echo "$$pins" | while read -r line; do \
	  grep -qxF "$$line" inventory/group_vars/ceph/main.yml || { echo "Not in the inventory: $$line" >&2; exit 1; }; \
	done

clean: ## Remove the environment, collections and rendered files
	rm -rf .venv collections .ansible build

# --- Cluster --------------------------------------------------------------------

check: $(DEPS) ## Dry run of the complete setup on an installed cluster, showing diffs (changes nothing)
	$(PLAYBOOK) --check --diff playbooks/site.yml

cloud-init: $(DEPS) ## Render cloud-init files into build/cloud-init/<host>/
	$(PLAYBOOK) playbooks/render-cloud-init.yml

# The boot partition of a disk flashed on macOS, e.g. make cloud-init-copy HOST=ceph1
BOOT_VOLUME ?= /Volumes/system-boot

cloud-init-copy: $(DEPS) ## Render the cloud-init files, copy those of HOST=<node> onto a freshly flashed disk and eject it (macOS)
	@[ -n "$(HOST)" ] || { echo "Usage: make cloud-init-copy HOST=ceph1" >&2; exit 1; }
	$(PLAYBOOK) playbooks/render-cloud-init.yml
	scripts/copy-cloud-init.sh build/cloud-init/$(HOST) $(BOOT_VOLUME)

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
