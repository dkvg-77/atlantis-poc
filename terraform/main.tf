terraform {
  required_version = ">= 1.6"

  # Remote state so plan/apply are consistent across runs (and across the
  # plan-on-PR and apply-on-merge jobs). The Devtron job pod authenticates to
  # GCS via Workload Identity (devtron-ci/ci-runner -> tofu-bootstrap GSA).
  backend "gcs" {
    bucket = "dev-infra-test-497417-tofu-state"
    prefix = "atlantis-poc"
  }

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# A deliberately trivial, zero-cost, no-cloud resource that lives entirely in
# Terraform state (no external system), so the plan reflects real state:
#   - unchanged PR     -> "No changes"
#   - bump `revision`  -> plan shows replace (-/+); apply-on-merge applies it
resource "random_pet" "demo" {
  length    = 2
  separator = "-"

  keepers = {
    # ---- Bump this in a PR to force a new pet ----
    revision = "5"
  }
}

output "demo_pet" {
  description = "The generated pet name (changes only when revision changes)."
  value       = random_pet.demo.id
}
