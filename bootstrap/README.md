# Bootstrap

Resources required to run Terraform itself. Managed manually (not Terraform)
to avoid chicken-and-egg problems with self-managing IAM roles and state backend.

## What's here

| Resource | Purpose |
|---|---|
| `kosuke-iac-tfstate` (S3 bucket) | Terraform state storage |
| `iac-aws-tflock` (DynamoDB table) | Terraform state locking |
| GitHub Actions OIDC provider | Federated identity for CI |
| `GitHubActions-iac-aws` (IAM role) | Role assumed by GitHub Actions via OIDC |

## Initial setup

Requires AWS credentials with admin-level permissions (typically your SSO admin profile).

```bash
export AWS_PROFILE=personal
cd bootstrap/

./01-tfstate-backend.sh
./02-github-oidc.sh
```

Scripts are idempotent -- safe to re-run if interrupted.

## Why not Terraform?

- **Chicken-and-egg**: the role for Terraform CI is needed *before* Terraform can run
- **State recursion**: the state backend cannot store state about itself
- **Blast radius**: a misconfigured bootstrap breaks all CI; safer to require manual change

For application resources (S3 buckets, IAM users for apps, KMS keys, etc.),
see Terraform code in the repo root.

## Updating

When you need to change the Terraform CI role's permissions, edit
`policies/tf-permissions.json` and re-run `./02-github-oidc.sh`.
