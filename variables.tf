variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "keiba_db_backup_bucket_name" {
  type        = string
  description = "S3 bucket name for keiba-db CNPG backup"
  sensitive   = true
}