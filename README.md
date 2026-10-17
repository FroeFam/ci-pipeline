# ci-pipeline

Shared GitHub Actions pipeline for FroeFam repositories. Consumers keep seven
thin caller workflows that call the reusable workflows here; a fix lands once
and reaches every consumer by moving the floating `v1` tag.

## Versioning

Releases are tagged `v1.0.0`, `v1.0.1`, ... and the floating `v1` tag is
force-moved to every v1.x release. Callers and internal action references pin
`@v1`. A breaking change is `v2`.

## Reusable workflows (`.github/workflows/`)

| Workflow | Purpose |
|---|---|
| `build-test.yml` | Build and test. `language: dotnet` (job `build-test`) or `language: python` (jobs `lint`, `unit`, `integration`, `summary`). |
| `claude-review.yml` | Advisory Claude PR review (job `claude-review`), with a GITHUB_TOKEN fallback when the OIDC exchange skips. |
| `classify.yml` | Claude semver classification and label, Dependabot major-bump notices, skip-release for github-actions PRs. |
| `label-gate.yml` | Requires exactly one semver label (job `evaluate`). |
| `automerge.yml` | Enables auto-merge for Dependabot patch/minor PRs as the froefam-automerge App. |
| `release.yml` | Version, multi-arch images by digest, manifest merge, promotion, tag, GitHub release. Output `version`. |
| `comments.yml` | `@claude` responses on PR comments. |
| `failure-alert.yml` | Discord alert when a watched workflow fails. |

## Composite actions (`actions/<name>/`)

classify-pr, compute-version, apply-semver-label, apply-skip-release-label,
fetch-pr-diff, post-fork-notice, publish-test-summary (trx and junit),
notify-discord, trusted-actor-guard. Each is `shell: pwsh` with its script
beside `action.yml`, referenced as `FroeFam/ci-pipeline/actions/<name>@v1`.

## Caller files (names are fixed; workflow_run matches on them)

| File | `name:` | Trigger |
|---|---|---|
| `pr.yml` | PR Validation | pull_request to main; jobs `build`, `review` plus wrappers `check-build` (Build and test) and `check-review` (Review with Claude) |
| `classify-pr.yml` | Classify PR | pull_request_target opened, synchronize |
| `label-gate.yml` | Label Gate | pull_request labeled, unlabeled, reopened and workflow_run of Classify PR; jobs `gate` plus wrapper `check-gate` (label-gate) |
| `automerge.yml` | Dependabot Auto Merge | pull_request opened, synchronize, reopened, ready_for_review |
| `main.yml` | Main Pipeline | push to main and workflow_dispatch; jobs `build`, `release` |
| `claude-comments.yml` | Claude Code Review (Comments) | pull_request_review_comment, issue_comment |
| `ci-failure-alert.yml` | CI failure alert | workflow_run of PR Validation, Main Pipeline, Dependabot Auto Merge |

Every caller job uses `secrets: inherit`. Concurrency lives only in callers.

## Inputs

Common: `anthropic-model` (pass `${{ vars.ANTHROPIC_MODEL }}`),
`automerge-client-id` (pass `${{ vars.AUTOMERGE_APP_CLIENT_ID }}`),
`semver-rules-path` (default `.github/semver-rules.md`), `review-prompt-path`
(default `.github/review-prompt.md`), `review-model` (default
`claude-sonnet-5`), `review-effort` (default `high`), `initial-version`
(default `1.0.0`, the first release's version when no `v*` tag exists).

build-test: `language` (required: dotnet or python). dotnet: `dotnet-version`
(default `10.0.x`, used only without global.json), `solution`,
`unit-test-project`, `integration-test-project` (empty skips integration),
`unit-test-filter`, `integration-test-filter`. python (poetry, `poetry.lock`
required): `python-version` and `python-matrix` (both required),
`unit-test-path`, `integration-test-path`, `integration-test-platforms`
(default `["linux/amd64"]`), `lint-command` (default `poetry run ruff check .`).

release: `images` (JSON array of `{name,dockerfile,context,platforms,title}`),
`registry` (`ghcr` or `dockerhub`), `image-namespace` (ghcr defaults to the
lowercase owner; dockerhub requires it).

## Project files read from the base SHA

- `.github/semver-rules.md`: only the project MAJOR/MINOR/PATCH rules.
- `.github/review-prompt.md`: only the project paragraph and focus list.

A missing file falls back to a built-in default and emits a warning.

## Required secrets and variables (org level)

Actions secrets: ANTHROPIC_API_KEY, DISCORD_WEBHOOK_URL, DOCKER_USERNAME,
DOCKER_PASSWORD (Docker Hub consumers). Dependabot secret:
AUTOMERGE_APP_PRIVATE_KEY. Variables: ANTHROPIC_MODEL, AUTOMERGE_APP_CLIENT_ID.

## Ruleset

`ruleset-main.json` is the consumer ruleset body (POST
`/repos/FroeFam/<repo>/rulesets`). It requires the `label-gate`,
`Build and test` and `Review with Claude` checks.
