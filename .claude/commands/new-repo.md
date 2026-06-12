Create a new Docker container repo under the ycpss91255-docker GitHub organization, bootstrapped from the `ycpss91255-docker/template` GitHub Template repo.

**Scope: workspace cwd only.** This command creates a new repo under `${CLAUDE_PROJECT_DIR}/<repo>/` (sibling to the existing sub-repos) and updates `${CLAUDE_PROJECT_DIR}/org-profile/profile/README.md`. If running from a per-repo session, refuse and instruct the user to re-open Claude from the docker workspace root.

All downstream repos share one architecture: a `.base/` subtree pulled from `ycpss91255-docker/base`, driven by `just` recipes (`just build` / `run` / `exec` / `stop` / `setup` / `upgrade`). There is **no** env/agent/app type distinction — every repo is the same shape; per-repo differences live in `config/setup.conf`, the repo `Dockerfile`, and `test/smoke/`.

The heavy lifting is done by the template repo's self-deleting `bootstrap.sh` (re-establishes the `.base/` subtree history, which a GitHub Template clone does not carry, then runs `init.sh` and removes itself). See `ycpss91255-docker/template` + ADR-00000010 for the rationale.

## Workflow

1. **Create the repo from the template + clone into the workspace**:
   ```
   gh repo create ycpss91255-docker/<repo> \
     --template ycpss91255-docker/template \
     --private --description "<desc>" --clone
   ```
   Clone lands at `${CLAUDE_PROJECT_DIR}/<repo>/`. Set git identity if not inherited:
   ```
   git -C <repo> config user.name "<name>" && git -C <repo> config user.email "<email>"
   ```

2. **Bootstrap** (re-establish `.base/` subtree, run init, self-delete):
   ```
   cd <repo> && ./bootstrap.sh [<base-tag>]
   ```
   - No argument -> bootstrap resolves the latest `base` `vX.Y.Z` tag automatically.
   - Pass an explicit tag to pin (e.g. `./bootstrap.sh v0.41.0`).
   - bootstrap removes the template-only files (`README.md` / `doc/` / `.github/` / `test/` placeholders), removes the snapshot `.base/`, re-adds it as a real subtree at the chosen tag, runs `./.base/init.sh` (regenerates Dockerfile / symlinks / config scaffolding), then `git rm bootstrap.sh` and commits. The repo is left on `main` with a clean subtree history; `just upgrade` works from here on.

3. **Post-setup** (the steps the template cannot do for you):
   - **Repo-specific content**: edit `config/setup.conf` (image name + build args), the repo `Dockerfile` (workload layers), and add `test/smoke/<name>_env.bats`. Use an existing downstream repo as reference.
   - **Topic taxonomy**: open a PR in `ycpss91255-docker/.github` adding the repo to `topics.yaml` under `repos:` (tags from `allowed.*` only — the lint job rejects unknown tags). Do NOT `gh repo edit --add-topic` directly; `topics.yaml` is the single source of truth. After merge, run `script/sync-topics.sh --apply` from a `.github` checkout. The weekly drift cron fails if skipped.
   - **Branch protection**: enable required status checks + PR-before-merge via `gh api` (match the settings of an existing org repo).
   - **Org profile README**: add the new repo to `${CLAUDE_PROJECT_DIR}/org-profile/profile/README.md`.

4. **Verify locally**:
   ```
   just build test
   ```
   must pass (ShellCheck + Hadolint + Bats), same gate CI runs.

NOTE: After bootstrap, all further code changes go through the PR workflow (`/pr`). Container ops use `just` recipes first; the `script/*.sh` wrappers are the fallback when `just` is unavailable.

Context from user: $ARGUMENTS

Now create the repo following this workflow.
