terraform {
    backend "s3" {
        bucket          = "kosuke-iac-tfstate"
        key             = "iac-aws/terraform.tfstate"
        region          = "ap-northeast-1"
        dynamodb_table  = "iac-aws-tflock"
        encrypt         = true
    }
}
