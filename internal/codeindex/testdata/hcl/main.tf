terraform {
  required_version = ">= 1.5"
}

# The region every resource lives in.
variable "region" {
  type    = string
  default = "eu-west-1"
}

locals {
  name_prefix = "acme"
  tags        = { team = "platform" }
}

/* The bucket that holds build artifacts. */
resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.name_prefix}-artifacts"

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_caller_identity" "current" {}

// The network module.
module "network" {
  source = "./modules/network"
  cidr   = "10.0.0.0/16"
}

output "bucket_arn" {
  value = aws_s3_bucket.artifacts.arn
}

provider "aws" {
  region = var.region
}
