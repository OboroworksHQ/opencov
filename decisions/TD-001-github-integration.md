# TD-001: GitHub Integration — Commit Status + PR Coverage Comments

**Status**: Proposed
**Priority**: High
**Effort**: Hours

## Decision

Add GitHub integration to OpenCov, mirroring the existing Gitea integration. After coverage is processed, OpenCov posts a commit status and a coverage summary comment on the corresponding GitHub PR.

## Context

OpenCov (fork OboroworksHQ/opencov) is a self-hosted coverage viewer that receives reports via Coveralls-compatible API. The fork already has a Gitea integration (`lib/opencov/integrations/gitea.ex`) that posts commit status and PR comments after coverage processing. Projects hosted on GitHub don't get this feedback — this TD closes the gap.

The upstream repo (danhper/opencov) has an abandoned `integrations` branch with GitHub OAuth scaffolding but no actual status posting. We don't need OAuth complexity — a static PAT (like Gitea) is sufficient.

## Implementation

### OpenCov repo (OboroworksHQ/opencov)

#### 1. New file: `lib/opencov/integrations/github.ex`

Structural copy of `gitea.ex` with these differences:

- **Config**: reads `:github` app config, env vars `GITHUB_ENABLED`, `GITHUB_TOKEN`. No `url` field (always `https://api.github.com`).
- **Repo parsing**: `parse_repo/1` extracts owner/repo from `project.base_url` matching host `github.com` (single-arg, no gitea_url parameter).
- **Auth header**: `Authorization: Bearer {token}` (vs `token {token}` for Gitea).
- **API endpoints**:
  - Commit status: `POST /repos/{owner}/{repo}/statuses/{sha}`
  - List comments: `GET /repos/{owner}/{repo}/issues/{pr}/comments`
  - Post comment: `POST /repos/{owner}/{repo}/issues/{pr}/comments`
  - Edit comment: `PATCH /repos/{owner}/{repo}/issues/comments/{id}`
- **Comment formatting, marker, helpers**: identical to Gitea.

#### 2. Modify: `web/managers/build_manager.ex`

Add one line in `update_coverage/1` after the Gitea notify:

```elixir
Opencov.Integrations.Gitea.notify(build)
Opencov.Integrations.Github.notify(build)
```

Both run async (Task.start), both are no-ops if disabled or if `base_url` doesn't match their host.

#### 3. Modify: `config/config.exs`

Add config block after Gitea:

```elixir
config :opencov, :github,
  enabled: System.get_env("GITHUB_ENABLED") == "true",
  token: System.get_env("GITHUB_TOKEN"),
  post_commit_status: true,
  post_pr_comment: true
```

### Ansible repo (oboroworks-ansible)

#### 4. Modify: `roles/opencov/templates/docker-compose.yml.j2`

Add `environment` section to `opencov` service:

```yaml
environment:
  - GITHUB_ENABLED={{ opencov_github_enabled | default('false') }}
  - GITHUB_TOKEN={{ opencov_github_token }}
```

#### 5. Modify: `roles/opencov/vars/main.yml`

```yaml
opencov_github_enabled: "true"
opencov_github_token: "{{ opencov_github_token_secret }}"
```

#### 6. Modify: `.github/workflows/deploy.yml`

Add secret passthrough:

```
-e "opencov_github_token_secret=${{ secrets.OPENCOV_GITHUB_TOKEN }}" \
```

#### 7. GitHub Actions secret

Create `OPENCOV_GITHUB_TOKEN` — PAT with `repo:status` scope.

#### 8. Modify: `README.md`

Add `OPENCOV_GITHUB_TOKEN` to the secrets table.

## What's NOT needed

- **No DB migration** — reuses existing fields (`commit_sha`, `service_job_pull_request`, `base_url`)
- **No new dependency** — HTTPoison already present
- **No webhook receiver** — integration is unidirectional (OpenCov → GitHub)
- **No OAuth** — static PAT, same as Gitea

## Verification

1. Create a project in OpenCov with `base_url` pointing to a GitHub repo
2. Send a coverage report via API with `commit_sha` and `service_job_pull_request` set
3. Verify commit status appears on GitHub commit
4. Verify coverage comment appears on the PR
5. Send a second report — comment must be updated, not duplicated
