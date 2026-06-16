terraform {
  required_version = ">= 1.6"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# A deliberately trivial, zero-cost, no-cloud resource.
# Its only job is to produce a meaningful `tofu plan` diff when edited,
# so we can demo the "plan-on-PR -> comment" flow without touching real infra.
resource "local_file" "demo" {
  filename = "${path.module}/demo-output.txt"

  # ---- Edit anything below in a PR to change the plan ----
  content = <<-EOT
    Atlantis-PoC demo file.

    Change this content (or add a resource) in a pull request, and the
    Devtron job will post the `tofu plan` diff as a comment on that PR.

    revision = 3
  EOT
}
