# --- S3 bucket ---

import {
  to = aws_s3_bucket.blog-images
  id = var.blog_images_bucket_name
}
resource "aws_s3_bucket" "blog-images" {
  bucket           = var.blog_images_bucket_name
  bucket_namespace = "account-regional"

  tags = {
    Project = "personal-blog"
    Purpose = "blog images"
  }
}

resource "aws_s3_bucket_versioning" "blog-images" {
  bucket = aws_s3_bucket.blog-images.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "blog-images" {
  bucket                  = aws_s3_bucket.blog-images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 画像配信用途のため CMK は使わず SSE-S3(AES256)を採用。AWS-0132 を意図的に抑制。
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "blog-images" {
  bucket = aws_s3_bucket.blog-images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "blog-images" {
  bucket = aws_s3_bucket.blog-images.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# --- IAM Policy (managed) ---
data "aws_iam_policy_document" "blog_images" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.blog-images.arn]
  }

  statement {
    sid    = "ObjectRW"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.blog-images.arn}/*"]
  }
}

resource "aws_iam_policy" "blog_images" {
  name        = "personal-blog-images"
  description = "S3 access for personal blog images"
  policy      = data.aws_iam_policy_document.blog_images.json
}

# ブログ用は専用 IAM user を新規作成し、アプリ用クレデンシャルを発行
resource "aws_iam_user" "blog_images" {
  name = "personal-blog-images"
}

resource "aws_iam_access_key" "blog_images" {
  user = aws_iam_user.blog_images.name
}

resource "aws_iam_user_policy_attachment" "blog_images" {
  user       = aws_iam_user.blog_images.name
  policy_arn = aws_iam_policy.blog_images.arn
}
