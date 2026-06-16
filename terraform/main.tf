terraform {
  required_version = ">= 1.6"

  # Remote state in GCS; the Devtron job pod authenticates via Workload Identity
  # (devtron-ci/ci-runner -> tofu-bootstrap GSA). State is consistent across the
  # plan-on-PR and apply-on-merge jobs.
  backend "gcs" {
    bucket = "dev-infra-test-497417-tofu-state"
    prefix = "atlantis-poc"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "dev-infra-test-497417"
  region  = "us-central1"
}

# A REAL, visible-in-the-Console demo resource: a GCS bucket.
# - Open a PR that edits this -> plan-on-PR comments the diff.
# - Merge -> apply-on-merge creates/changes it; see it in
#   Cloud Console -> Cloud Storage.
resource "google_storage_bucket" "demo" {
  name                        = "dev-infra-test-497417-atlantis-poc-demo"
  location                    = "US"
  force_destroy               = true # lets a "destroy" PR remove it cleanly
  uniform_bucket_level_access = true

  labels = {
    # ---- change this in a PR to see a "1 to change" diff in the Console ----
    demo_revision = "1"
    managed_by    = "atlantis-poc"
  }
}

output "demo_bucket" {
  description = "The demo bucket's URL (visible in Cloud Console)."
  value       = google_storage_bucket.demo.url
}
