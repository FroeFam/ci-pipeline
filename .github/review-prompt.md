Repository ci-pipeline: the shared GitHub Actions pipeline (reusable workflows and composite actions) that every FroeFam repository calls through the floating v1 tag.

Focus on:
- Security: pull_request_target misuse, untrusted text (PR titles, bodies, branch names, release notes) interpolated into scripts or prompts, secrets reaching fork PRs, over-broad permissions, unpinned third-party actions
- Breaking changes to the public contract: workflow inputs, secrets and outputs, composite action inputs, caller file and check names
- Correctness of the pwsh scripts (exit codes, $LASTEXITCODE, quoting)
- Behavior across every consumer shape: dotnet and python, ghcr and Docker Hub, public and private repos
- ASCII-only content in workflows and scripts
