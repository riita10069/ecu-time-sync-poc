terraform {
  required_version = ">= 1.6"
  required_providers {
    aws      = { source = "hashicorp/aws", version = "~> 6.70" }
    tls      = { source = "hashicorp/tls", version = "~> 4.0" }
    random   = { source = "hashicorp/random", version = "~> 3.6" }
    archive  = { source = "hashicorp/archive", version = "~> 2.4" }
    external = { source = "hashicorp/external", version = "~> 2.3" }
    local    = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.name, Purpose = "poc" }
  }
}
