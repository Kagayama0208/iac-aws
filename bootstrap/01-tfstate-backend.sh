#!/usr/bin/env bash
# Create Terraform state backend resources.
# Idempotent: safe to re-run.

set -euo pipefail

REGION="ap-northeast-1"
BUCKET="kosuke-iac-tfstate"
TABLE="iac-aws-tflock"

echo "==> Creating S3 bucket for Terraform state: ${BUCKET}"
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "    Bucket already exists, skipping create."
else
  aws s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
fi

echo "==> Enabling versioning"
aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

echo "==> Blocking public access"
aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "==> Enabling default encryption (AES256 is acceptable for state bucket)"
aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "==> Creating DynamoDB table for state locking: ${TABLE}"
if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "    Table already exists, skipping create."
else
  aws dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  echo "    Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
fi

echo "==> Done. Backend ready:"
echo "    S3 bucket    : ${BUCKET}"
echo "    Lock table   : ${TABLE}"
