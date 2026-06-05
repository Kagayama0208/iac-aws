# --- S3 bucket ---

import {
  to = aws_s3_bucket.keiba-db-backup
  id = var.keiba_db_backup_bucket_name
}
resource "aws_s3_bucket" "keiba-db-backup" {
  bucket           = var.keiba_db_backup_bucket_name
  bucket_namespace = "account-regional"

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

resource "aws_s3_bucket_public_access_block" "keiba-db-backup" {
  bucket                  = aws_s3_bucket.keiba-db-backup.id
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
    filter { prefix = "keiba-db/wals/" }
    expiration { days = 30 }
  }

  rule {
    id     = "expire-old-base"
    status = "Enabled"
    filter { prefix = "keiba-db/base/" }
    expiration { days = 90 }
  }
}

# --- KMS ---
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

# --- IAM Policy (managed) ---
data "aws_iam_policy_document" "keiba_db_backup" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.keiba-db-backup.arn]
  }

  statement {
    sid    = "ObjectRW"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",     # barman の multipart upload で必要
      "s3:ListMultipartUploadParts", # 同上
    ]
    resources = ["${aws_s3_bucket.keiba-db-backup.arn}/*"]
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

resource "aws_iam_policy" "keiba_db_backup" {
  name        = "keiba-db-backup"
  description = "S3 + KMS access for keiba-db CNPG backup"
  policy      = data.aws_iam_policy_document.keiba_db_backup.json
}

# 既存 user は手動管理のまま、attach だけ Terraform で
resource "aws_iam_user_policy_attachment" "keiba_db_backup" {
  user       = "keiba-db-backup" # 既存 user 名を直書き(Terraform 管理外)
  policy_arn = aws_iam_policy.keiba_db_backup.arn
}