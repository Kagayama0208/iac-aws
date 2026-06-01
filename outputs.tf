output "keiba_db_backup_bucket" {
  description = "S3 bucket for keiba-db CNPG backup"
  value       = aws_s3_bucket.keiba-db-backup.id
}

output "keiba_db_backup_bucket_arn" {
  description = "ARN of the keiba-db backup bucket"
  value       = aws_s3_bucket.keiba-db-backup.arn
}

output "keiba_db_backup_kms_key_arn" {
  description = "ARN of the KMS key for keiba-db backup encryption"
  value       = aws_kms_key.keiba-db-backup.arn
}

output "keiba_db_cnpg_access_key_id" {
  description = "Access key ID for CNPG IAM user"
  value       = aws_iam_access_key.keiba_db_cnpg.id
}

output "keiba_db_cnpg_secret_access_key" {
  description = "Secret access key for CNPG IAM user"
  value       = aws_iam_access_key.keiba_db_cnpg.secret
  sensitive   = true
}