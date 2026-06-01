resource "aws_s3_bucket" "keiba-db-backup" {
  bucket           = var.keiba_db_backup_bucket_name
  bucket_namespace = "global"

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

resource "aws_kms_key" "keiba-db-backup" {
  description             = "KMS key for keiba-db S3 backup encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Project = "keiba-db"
  }
}

resource "aws_kms_alias" "keiba-db-backup" {
  name          = "alias/keiba-db-backup"
  target_key_id = aws_kms_key.keiba-db-backup.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "keiba-db-backup" {
  bucket = aws_s3_bucket.keiba-db-backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.keiba-db-backup.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "keiba-db-backup" {
  bucket = aws_s3_bucket.keiba-db-backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_user" "keiba_db_cnpg" {
  name = "keiba-db-cnpg"
  tags = {
    Project = "keiba-db"
    Purpose = "CNPG S3 backup access"
  }
}

resource "aws_iam_access_key" "keiba_db_cnpg" {
  user = aws_iam_user.keiba_db_cnpg.name
}

data "aws_iam_policy_document" "keiba_db_cnpg" {
  statement {
    sid    = "S3BucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.keiba-db-backup.arn,
      "${aws_s3_bucket.keiba-db-backup.arn}/*",
    ]
  }

  statement {
    sid    = "KMSEncryptDecrypt"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.keiba-db-backup.arn]
  }
}

resource "aws_iam_user_policy" "keiba_db_cnpg" {
  name   = "keiba-db-cnpg-s3-kms"
  user   = aws_iam_user.keiba_db_cnpg.name
  policy = data.aws_iam_policy_document.keiba_db_cnpg.json
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