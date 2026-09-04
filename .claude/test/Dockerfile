# syntax=docker/dockerfile:1
#
# Test image for claude-workspace hooks. Runs bats specs and shellcheck
# inside Docker so behaviour matches CI exactly (CLAUDE.md "驗證一律走 Docker").
#
# Build context = repo root (so COPY paths reach .claude/...). Use the
# `just -f .claude/test/justfile <target>` wrapper (CI runs the same
# `.claude/test/ci.sh <target>` driver); direct invocation:
#   docker build -f .claude/test/Dockerfile -t claude-workspace-test:local .
#   docker run --rm claude-workspace-test:local
#   docker run --rm --entrypoint sh claude-workspace-test:local \
#     -c 'shellcheck /work/.claude/hooks/*.sh /work/.claude/scripts/*.sh'

FROM bats/bats:1.11.0

USER root

# Hook runtime + bats helper deps:
#   - bash       hooks use [[ ]] / arrays / bash regex
#   - file       check_no_emoji uses `file --mime`
#   - git        check_changelog_drift / repo discovery
#   - jq         every hook parses input JSON
#   - python3    check_no_emoji's regex matcher
#   - shellcheck lint target
#   - grep / coreutils — GNU userland for consistent flags
#
# APK_MIRROR points apk at a different host. The default keeps the upstream
# CDN, so a network that can reach it sees no change. Networks that cannot
# reach dl-cdn.alpinelinux.org exist -- on one of ours, apk spends 480s and
# then reports every package as "no such package", because an unreachable
# index reads as an empty one. That is the whole failure: not a timeout the
# reader can recognise, but a package list that appears not to contain bash.
# Base solves the same problem for Debian and Ubuntu with APT_MIRROR_DEBIAN /
# APT_MIRROR_UBUNTU; this is the Alpine spelling of it.
ARG APK_MIRROR="dl-cdn.alpinelinux.org"
RUN if [ "${APK_MIRROR}" != "dl-cdn.alpinelinux.org" ]; then \
      sed -i "s@dl-cdn\.alpinelinux\.org@${APK_MIRROR}@g" /etc/apk/repositories; \
    fi && \
    apk add --no-cache \
      bash \
      coreutils \
      file \
      git \
      grep \
      jq \
      python3 \
      shellcheck

ARG BATS_SUPPORT_VERSION=v0.3.0
ARG BATS_ASSERT_VERSION=v2.1.0

RUN git clone --depth 1 --branch "${BATS_SUPPORT_VERSION}" \
      https://github.com/bats-core/bats-support.git /usr/lib/bats-support && \
    git clone --depth 1 --branch "${BATS_ASSERT_VERSION}" \
      https://github.com/bats-core/bats-assert.git   /usr/lib/bats-assert && \
    rm -rf /usr/lib/bats-support/.git /usr/lib/bats-assert/.git

WORKDIR /work
COPY .claude/hooks/ /work/.claude/hooks/
COPY .claude/scripts/ /work/.claude/scripts/
COPY .claude/test/ /work/.claude/test/

# bats/bats image already has ENTRYPOINT ["bats"]; CMD becomes its args.
# Specs live under .claude/test/bats/<level>/ (ISTQB layout, ADR-00000013).
CMD ["--recursive", "/work/.claude/test/bats/"]
