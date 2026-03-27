terraform {
  backend "s3" {
    bucket         = "rizwan66-terraform-state"
    key            = "aws-ecommerce/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "rizwan66-terraform-locks"
  }
}
