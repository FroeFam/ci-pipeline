# ci-pipeline

Shared GitHub Actions pipeline for FroeFam repositories. Each consumer keeps
seven thin caller workflows that call the reusable workflows and composite
actions in this repository. A fix lands here once and reaches every consumer
when the floating `v1` tag moves.

What the pipeline does for a consumer:

- Builds and tests every PR (.NET or Python/poetry).
- Runs an advisory Claude code review on same-repo PRs.
- Has Claude choose a `semver: major|minor|patch` label, and gates the merge
  on exactly one semver label.
- Auto-merges Dependabot patch and minor PRs as the froefam-automerge App.
- On every push to main: builds multi-arch images by digest, tags them `main`
  and `sha-<7>`, and (when a PR was merged since the last tag) computes the next
  version, promotes the image to `<ver>`, `<maj.min>` and `latest`, tags
  `v<ver>` and creates a GitHub release.
- Answers `@claude` in PR comments for users with write access.
- Alerts Discord when a watched workflow fails.

## Contents

| Path | Purpose |
|---|---|
| `.github/workflows/build-test.yml` | Build and test. `language: dotnet` (job `build-test`) or `language: python` (jobs `lint`, `unit`, `integration`, `summary`). |
| `.github/workflows/claude-review.yml` | Advisory Claude PR review (job `claude-review`) with a GITHUB_TOKEN fallback. |
| `.github/workflows/classify.yml` | Claude semver classification and label, Dependabot major-bump Discord notice, `skip-release` for github-actions PRs, fork notice. |
| `.github/workflows/label-gate.yml` | Requires exactly one semver label (job `evaluate`). |
| `.github/workflows/automerge.yml` | Enables auto-merge for Dependabot patch and minor PRs as the froefam-automerge App. |
| `.github/workflows/release.yml` | Version, images by digest, manifest merge, promotion, tag, GitHub release, Discord notice. Output `version`. |
| `.github/workflows/comments.yml` | `@claude` responses on PR comments. |
| `.github/workflows/failure-alert.yml` | Discord alert when a watched workflow fails. |
| `.github/workflows/actionlint.yml` | actionlint check for PRs to this repository. |
| `actions/<name>/` | Composite actions (`shell: pwsh`, script beside `action.yml`): classify-pr, compute-version, apply-semver-label, apply-skip-release-label, fetch-pr-diff, post-fork-notice, publish-test-summary (trx and junit), notify-discord, trusted-actor-guard. Referenced as `FroeFam/ci-pipeline/actions/<name>@v1`. |
| `ruleset-main.json` | Consumer ruleset body (ruleset `Main`). |
| `scripts/New-ConsumerRepo.ps1` | Onboards a repository (callers, seeds, labels, settings, security features, ruleset, org secret and variable scopes). |
| `templates/` | Caller and seed templates used by the onboarding script. |

## Caller files

Names are fixed: `workflow_run` triggers match on the `name:` values.

| File | `name:` | Trigger | Jobs |
|---|---|---|---|
| `pr.yml` | PR Validation | pull_request to main | `build` (build-test), `review` (claude-review), wrappers `check-build` (Build and test) and `check-review` (Review with Claude) |
| `classify-pr.yml` | Classify PR | pull_request_target opened, synchronize | `classify` |
| `label-gate.yml` | Label Gate | pull_request labeled, unlabeled, reopened; workflow_run of Classify PR | `gate`, wrapper `check-gate` (label-gate) |
| `automerge.yml` | Dependabot Auto Merge | pull_request opened, synchronize, reopened, ready_for_review | `automerge` |
| `main.yml` | Main Pipeline | push to main, workflow_dispatch | `build`, `release` |
| `claude-comments.yml` | Claude Code Review (Comments) | pull_request_review_comment, issue_comment | `comments` |
| `ci-failure-alert.yml` | CI failure alert | workflow_run of PR Validation, Main Pipeline, Dependabot Auto Merge | `alert` |

Every caller job uses `secrets: inherit`. Concurrency lives only in callers
(Label Gate per PR head, Main Pipeline in group `main-pipeline` without
cancellation). Caller permissions are the maximum each called job needs; the
reusable jobs never request more.

### Required checks

The ruleset requires the contexts `label-gate`, `Build and test` and
`Review with Claude`. These are wrapper jobs in the callers: each `needs` the
reusable job, runs `if: ${{ !cancelled() }}` and fails unless the reusable job
result is `success` or `skipped`. All fork, Dependabot and label skips live
inside the reusable workflows, so a skipped review still yields a green
required check.

## Inputs reference

JSON values (arrays and objects) are passed as strings.

### build-test.yml

| Input | Default | Notes |
|---|---|---|
| `language` | (required) | `dotnet` or `python` |
| `dotnet-version` | `10.0.x` | Used only when no `global.json` exists |
| `solution` | `''` | `.sln` or `.slnx` |
| `unit-test-project` | `''` | Unit test project path |
| `integration-test-project` | `''` | Empty skips the integration step |
| `unit-test-filter` | `Category!=Integration` | |
| `integration-test-filter` | `Category=Integration` | |
| `python-version` | `''` | Required for python (lint and integration jobs) |
| `python-matrix` | `''` | Required for python, JSON array of versions for unit tests |
| `unit-test-path` | `tests/unit` | |
| `integration-test-path` | `tests/integration` | |
| `integration-test-platforms` | `["linux/amd64"]` | JSON array; `linux/arm64` runs on `ubuntu-24.04-arm` |
| `lint-command` | `poetry run ruff check .` | |

Python consumers use poetry only and must commit `poetry.lock`.

### claude-review.yml

| Input | Default |
|---|---|
| `review-prompt-path` | `.github/review-prompt.md` |
| `review-model` | `claude-sonnet-5` |
| `review-effort` | `high` |

### classify.yml

| Input | Default | Notes |
|---|---|---|
| `anthropic-model` | `''` | Caller passes `${{ vars.ANTHROPIC_MODEL }}` |
| `semver-rules-path` | `.github/semver-rules.md` | |

### label-gate.yml, failure-alert.yml

No inputs.

### automerge.yml

| Input | Default | Notes |
|---|---|---|
| `automerge-client-id` | `''` | Caller passes `${{ vars.AUTOMERGE_APP_CLIENT_ID }}` |

### comments.yml

| Input | Default |
|---|---|
| `review-prompt-path` | `.github/review-prompt.md` |

### release.yml

| Input | Default | Notes |
|---|---|---|
| `images` | (required) | JSON array of `{name,dockerfile,context,platforms,title}`; `name` is the repository under the namespace |
| `registry` | (required) | `ghcr` or `dockerhub` |
| `image-namespace` | `''` | ghcr defaults to the lowercase repository owner; required for dockerhub |
| `initial-version` | `1.0.0` | Version of the first release when no `v*` tag exists |

Output: `version`.

### Project files read from the base SHA

- `.github/semver-rules.md`: only the project MAJOR, MINOR and PATCH rules.
- `.github/review-prompt.md`: only the project paragraph and focus list.

They are read from the PR base SHA, so a PR cannot change the rules that
judge it. A missing file (or any read error) falls back to a built-in default
and emits a warning.

### Org secrets and variables

All are org level with selected-repository visibility.

| Kind | Names |
|---|---|
| Actions secrets | ANTHROPIC_API_KEY, DISCORD_WEBHOOK_URL, DOCKER_USERNAME and DOCKER_PASSWORD (Docker Hub consumers only) |
| Dependabot secret | AUTOMERGE_APP_PRIVATE_KEY |
| Variables | ANTHROPIC_MODEL (classification model), AUTOMERGE_APP_CLIENT_ID |

Repository-level secrets with the same name override the org ones.

## Versioning policy

- Releases are tagged `v1.0.0`, `v1.0.1`, ... and the floating `v1` tag is
  force-moved to every v1.x release (`git tag -f v1 <sha>`, then
  `git push -f origin v1`).
- Callers and every internal action reference pin `@v1`, so a fix reaches all
  consumers when `v1` moves. No consumer change is needed.
- A breaking change to inputs, caller names or required check names is `v2`.
- Dependabot only proposes major bumps for `@v1` pins, which is why fixes ship
  by moving `v1`.

## Onboarding a repository

Prerequisites: the repository exists in FroeFam (create or transfer it
first), it is cloned locally, `gh` is authenticated with an org owner account,
and the default branch is `main`.

1. Run `scripts/New-ConsumerRepo.ps1` with `-WhatIf` and read the summary.
2. Run it again without `-WhatIf`. It writes the seven callers, seeds
   `.github/semver-rules.md`, `.github/review-prompt.md`, `.github/CODEOWNERS`
   and `.github/dependabot.yml` only when they are absent, and applies labels,
   repository settings, workflow permissions, the fork approval policy (public
   repositories), security features (Dependabot alerts and security updates
   everywhere; secret scanning, push protection, private vulnerability
   reporting and CodeQL default setup on public repositories, since private
   ones need paid GitHub Advanced Security), the `Main` ruleset (no bypass actors on private repositories)
   and the org secret and variable scopes. It never commits, pushes or deletes.
3. Edit the two seed files for the project, then commit on a branch, push and
   open the cutover PR.
4. Classify PR cannot run on the first PR (its caller is not on main yet), so
   add the label by hand:
   `gh api -X POST repos/FroeFam/<repo>/issues/<n>/labels -f 'labels[]=semver: <level>'`.
5. Wait for the three required checks, handle review threads, then
   `gh pr merge <n> --merge`.

Re-running the script is safe: every item is read first and reported as
`no change` when it already matches.

Parameters: `-Repo`, `-Language` (dotnet or python), `-Registry` (ghcr or
dockerhub), `-Images` (JSON), `-Solution`, `-UnitTestProject`,
`-IntegrationTestProject` (dotnet), `-PythonVersion`, `-PythonMatrix`,
`-IntegrationPlatforms` (python), `-ImageNamespace` (required for dockerhub),
`-ReviewModel` (optional; consumers omit it and get the pipeline default),
`-Path` (local clone, default `D:\Code\<Repo>`), `-WhatIf`.

.NET example (ghcr, two images):

```powershell
./scripts/New-ConsumerRepo.ps1 -Repo TalkingPointsSummary -Language dotnet -Registry ghcr `
    -Solution TalkingPointsSummary.sln `
    -UnitTestProject tests/TalkingPointsSummary.Tests/TalkingPointsSummary.Tests.csproj `
    -IntegrationTestProject tests/TalkingPointsSummary.IntegrationTests/TalkingPointsSummary.IntegrationTests.csproj `
    -Images '[{"name":"talkingpointssummary-worker","dockerfile":"infra/Dockerfile","context":".","platforms":["linux/amd64"],"title":"TalkingPointsSummary Worker"},{"name":"talkingpointssummary-admin","dockerfile":"infra/Dockerfile.admin","context":".","platforms":["linux/amd64"],"title":"TalkingPointsSummary Admin"}]' `
    -WhatIf
```

Python example (Docker Hub, multi-arch):

```powershell
./scripts/New-ConsumerRepo.ps1 -Repo WakeOnLanService -Language python -Registry dockerhub `
    -ImageNamespace drache42 -PythonVersion 3.14 `
    -PythonMatrix '["3.10","3.11","3.12","3.13","3.14"]' `
    -IntegrationPlatforms '["linux/amd64","linux/arm64"]' `
    -Images '[{"name":"wakeonlanservice","dockerfile":"docker/Dockerfile","context":".","platforms":["linux/amd64","linux/arm64"],"title":"WakeOnLanService"}]' `
    -WhatIf
```

## Security model

- Fork PRs: `pull_request` runs get no secrets, so build and test run but the
  Claude review is skipped (the guard reports `fork`). Classify posts a fork
  notice instead of calling Claude, so a maintainer applies the semver label.
  Public repositories require approval for workflow runs from all external
  contributors (`all_external_contributors`).
- trusted-actor-guard: the first step of the review and comment workflows.
  Bots, fork PRs and anyone without admin, maintain or write permission (or
  any API error) get `trusted=false`, and every later step is skipped while
  the job stays green. Dependency PRs (label `dependencies`) skip the review.
- Automerge only acts when both the actor and the PR author are
  `dependabot[bot]` and the update is patch or minor; the merge is done with a
  froefam-automerge App token so it triggers the Main Pipeline.
- Ruleset `Main`: PR required (no approving review needed), branch deletion
  and force push blocked, all review threads resolved, strict status checks
  for the three required contexts. Public repositories let Dependabot bypass
  the PR rule (actor 29110); private repositories have no bypass actors.
- Accepted risks:
  - There is no deterministic semver floor: the label is Claude's choice.
  - Classify can label a major dependency bump `semver: patch`.
  - The Claude review is advisory; it never blocks a merge by itself (only
    unresolved threads do).
  - The claude and froefam-automerge Apps are installed on all org
    repositories.

## Known behaviors and procedures

- Check suites: every pull_request Label Gate run is its own check suite on
  the PR head, and the newest suite decides the required `label-gate`
  context. The workflow_run evaluation posts its `label-gate` through the
  Checks API into an older suite, so it only counts while no pull_request run
  exists. Two rules follow:
  - pull_request and workflow_run runs use separate concurrency groups
    (`github.event_name` in the group). A workflow_run run cancelling a
    pull_request run leaves a cancelled `label-gate` in the newest suite.
  - A `labeled`/`unlabeled` event for a label other than `semver:*` or
    `skip-release` (for example the labels Dependabot adds at PR creation)
    waits up to 3 minutes for a `semver:` label before evaluating, so it does
    not fail in the race with Classify PR.
- Stale label-gate: if a PR stays blocked by a failing `label-gate` after its
  labels are corrected, re-run the newest failed Label Gate run
  (`gh run rerun <id> --failed`) and wait for
  `gh pr view <n> --json mergeStateStatus` to report `CLEAN`.
- `gh run rerun` reuses the workflow SHA of the original run. After changing a
  workflow file, push a new commit instead of re-running.
- Labels: `gh pr edit` fails with the current token scope. Use REST:
  `gh api -X POST repos/<o>/<r>/issues/<n>/labels -f 'labels[]=semver: patch'`
  and `gh api -X DELETE "repos/<o>/<r>/issues/<n>/labels/<url-encoded name>"`.
- OIDC workflow-validation fallback: claude-code-action rejects a run whose
  workflow file differs from the default branch and exits green without
  output. The review then re-runs with `github_token: ${{ github.token }}`,
  emits the warning `Claude review used GITHUB_TOKEN fallback`, and comments
  are posted by github-actions[bot] instead of claude[bot]. This is expected on
  PRs that edit workflow files.
- Review threads: resolve a Claude review thread only after reading it and
  either fixing the issue in the PR or replying with why no change is needed.
  Never resolve a thread that identifies a real defect without fixing it.
- Dependabot flow: Classify labels the PR (github-actions updates also get
  `skip-release`, major updates send a Discord `WARNING:` notice), Label Gate
  passes, and Dependabot Auto Merge enables auto-merge for patch and minor
  updates. Major updates are left for a human. Under strict status checks a
  batch of Dependabot PRs can stall behind each other: comment
  `@dependabot rebase` on the next one.
- First PR of a new repository: Classify cannot run yet, so add the semver
  label manually (see Onboarding).
- Releases are skipped when no PR was merged since the last tag, or when the
  merged PR carries `skip-release`. Images are still pushed as `main` and
  `sha-<7>`. Re-run a half-failed release with `gh run rerun <id> --failed`
  (tag and release steps are idempotent).
- On dotnet repositories the skipped python-only jobs show an unresolved
  `${{ matrix.platform }}` in their names (cosmetic).
