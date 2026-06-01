#!/usr/bin/env bash
# Create GitHub Actions OIDC provider, IAM role, and inline policy.
# Idempotent: safe to re-run. Re-running will update the trust/permissions.

set -euo pipefail

ROLE_NAME="GitHubActions-iac-aws"
POLICY_NAME="terraform-permissions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "==> Operating on AWS account: ${ACCOUNT_ID}"

PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo "==> Creating GitHub OIDC provider"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "    Provider already exists, skipping create."
else
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
fi

echo "==> Rendering policy files with account ID"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT
sed "s/ACCOUNT_ID_PLACEHOLDER/${ACCOUNT_ID}/g" \
  "${SCRIPT_DIR}/policies/trust-policy.json" > "${TMPDIR}/trust.json"
sed "s/ACCOUNT_ID_PLACEHOLDER/${ACCOUNT_ID}/g" \
  "${SCRIPT_DIR}/policies/tf-permissions.json" > "${TMPDIR}/permissions.json"

echo "==> Creating or updating IAM role: ${ROLE_NAME}"
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "    Role exists, updating assume-role policy."
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "file://${TMPDIR}/trust.json"
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TMPDIR}/trust.json"
fi

echo "==> Putting inline policy: ${POLICY_NAME}"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "file://${TMPDIR}/permissions.json"

ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)"
echo "==> Done. Role ARN: ${ROLE_ARN}"
echo ""
echo "Set this as the AWS_ROLE_ARN secret in the iac-aws GitHub repo:"
echo "  gh secret set AWS_ROLE_ARN --body \"${ROLE_ARN}\" --repo Kagayama0208/iac-aws"
