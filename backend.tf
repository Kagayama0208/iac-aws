terraform {
    backend "s3" {
        bucket          = "kousuke-iac-tfstate"
        key             = "iac-aws/terraform.tfstate"
        aws_region      = "ap-northeast-1"
        dynamodb_table  = "iac-aws-tflock"
        encrypt         = true
    }
}
