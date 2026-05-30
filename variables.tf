variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID. Set via TF_VAR_aws_account_id env var or tfvars."
  sensitive   = true
}

variable "keiba_db_backup_bucket_name" {
  type        = string
  description = "S3 bucket name for keiba-db CNPG backup"
  sensitive   = true
}