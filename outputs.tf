output "keiba_db_backup_bucket" {
  description = "S3 bucket for keiba-db CNPG backup"
  value = aws_s3_bucket.keiba-db-backup.id
}

output "keiba_db_backup_bucket_arn" {
  description = "ARN of the keiba-db backup bucket"
  value = aws_s3_bucket.keiba-db-backup.arn
}