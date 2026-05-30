provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
    ManagedBy = "Terraform"
    Repo      = "Kagayama0208/iac-aws"
    }
  }
}