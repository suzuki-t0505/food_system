terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # bucket / prefix は backend.hcl で与える(terraform init -backend-config=backend.hcl)
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
