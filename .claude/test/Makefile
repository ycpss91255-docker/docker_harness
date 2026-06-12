# docker_harness test infra — local + CI entry point.
#
# All targets run inside the .claude/test/Dockerfile image so behaviour matches
# CI exactly (CLAUDE.md "驗證一律走 Docker"). Direct host bats / shellcheck /
# hadolint is not supported.
#
# Run from this directory (.claude/test/), or via `make -C .claude/test <target>`
# from the repo root.

IMAGE := docker_harness-test:local
HADOLINT_IMAGE := hadolint/hadolint:latest-alpine

# Build context = repo root (two levels up); COPY paths inside the Dockerfile
# stay relative to that context (`.claude/hooks/`, `.claude/scripts/`).
REPO_ROOT := $(CURDIR)/../..

.PHONY: help build test lint hadolint tree-check ceiling-check log-helper-check check clean

help:  ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk -F ':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build:  ## Build the test docker image
	docker build -f $(CURDIR)/Dockerfile -t $(IMAGE) $(REPO_ROOT)

test: build  ## Run bats specs (smoke + integration) inside docker
	docker run --rm $(IMAGE)
	@# On green, write the local-CI marker for HEAD so
	@# enforce_local_full_ci_before_pr.sh (refs #176) lets the PR open.
	@# Runs only if the docker run above exited 0 (make stops on error).
	@mkdir -p $(REPO_ROOT)/.claude/state/local-ci-pass && \
	  touch $(REPO_ROOT)/.claude/state/local-ci-pass/$$(git -C $(REPO_ROOT) rev-parse HEAD).ok

lint: build  ## Run shellcheck against all hook + helper scripts inside docker
	docker run --rm --entrypoint sh $(IMAGE) -c \
	  'shellcheck /work/.claude/hooks/*.sh /work/.claude/scripts/*.sh /work/.claude/scripts/lib/*.sh'

hadolint:  ## Lint .claude/test/Dockerfile with Hadolint
	docker run --rm -i \
	  -v "$(REPO_ROOT)/.hadolint.yaml:/.hadolint.yaml:ro" \
	  $(HADOLINT_IMAGE) \
	  hadolint --config /.hadolint.yaml - < $(CURDIR)/Dockerfile

tree-check:  ## Audit CONTEXT.md `.claude/` tree listing vs filesystem (host bash+python3, no docker; pre-#127 audited CLAUDE.md)
	$(REPO_ROOT)/.claude/scripts/check-claude-md-tree.sh $(REPO_ROOT)/CONTEXT.md

ceiling-check:  ## Audit CLAUDE.md line / `^##` ceilings (refs #127; defaults 240 / 20, env-overridable via MAX_LINES / MAX_SECTIONS)
	$(REPO_ROOT)/.claude/scripts/check-claude-md-ceiling.sh $(REPO_ROOT)/CLAUDE.md

log-helper-check:  ## Enforce lib/log.sh adoption in .claude/scripts/*.sh (refs #148 M5; bare printf/echo outside usage()/allowlist fails)
	$(REPO_ROOT)/.claude/scripts/check-log-helper-usage.sh --scripts-dir $(REPO_ROOT)/.claude/scripts

check: lint hadolint test tree-check ceiling-check log-helper-check  ## Full CI gate: shellcheck + Hadolint + bats + tree audit + ceiling audit + log-helper audit

clean:  ## Remove the test image
	docker image rm $(IMAGE) 2>/dev/null || true
