# atlantis-poc

A minimal **plan-on-PR** demo — the one behaviour that matters most in
[Atlantis](https://www.runatlantis.io/): when you open a pull request that
touches Terraform, the `terraform/tofu plan` diff is posted back as a **comment
on the PR**, so a reviewer sees *what would change* before anything is merged.

But there is **no Atlantis here**. The plan runs inside a **Devtron Job**,
auto-triggered by a **GitHub Pull Request webhook**.

```
open / push to PR
   │  (GitHub pull_request webhook)
   ▼
Devtron webhook receiver  ──▶  CI Job (source type: Pull Request, state=open)
   │
   ▼  alpine container, auto-triggered
   tofu plan  ──▶  POST plan as a PR comment (GitHub API)
```

**Apply is out of scope** — this only ever runs `plan`. Nothing is applied.

## What's here

| Path | What |
|---|---|
| `terraform/main.tf` | A trivial `local_file` resource (zero cost, no cloud creds). Edit it in a PR to produce a plan diff. |
| `ci/plan-and-comment.sh` | The script the Devtron Job runs: `tofu plan` → resolve the PR → post the comment. |

## Try it

1. Create a branch, edit `revision = 1` in `terraform/main.tf`, open a PR.
2. Within a moment the Devtron Job runs and a comment with the `tofu plan`
   output appears on the PR.

> The Terraform here is **not real infrastructure** — it exists only to generate
> a plan diff for the demo.
