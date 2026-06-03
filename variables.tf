variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "keiba_db_backup_bucket_name" {
  type        = string
  description = "S3 bucket name for keiba-db CNPG backup"
  sensitive   = true
}

variable "blog_images_bucket_name" {
  type        = string
  description = "S3 bucket name for personal blog images"
  sensitive   = true
}