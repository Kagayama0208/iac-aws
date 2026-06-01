resource "aws_s3_bucket" "keiba-db-backup" {
  bucket = var.keiba_db_backup_bucket_name

  tags = {
    Project = "keiba-db"
    Purpose = "CNPG backup"
  }
}

resource "aws_s3_bucket_versioning" "keiba-db-backup" {
  bucket = aws_s3_bucket.keiba-db-backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "keiba-db-backup" {
  bucket = aws_s3_bucket.keiba-db-backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "keiba-db-backup" {
  bucket = aws_s3_bucket.keiba-db-backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "keiba-db-backup" {
  bucket = aws_s3_bucket.keiba-db-backup.id

  rule {
    id     = "expire-old-wal"
    status = "Enabled"

    filter {
      prefix = "keiba-db/wals/"
    }

    expiration {
      days = 90
    }
  }
}