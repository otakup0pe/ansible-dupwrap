terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "dupwrap-e2e-test-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "test" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = {
    Name    = local.bucket_name
    Purpose = "dupwrap e2e test"
    Repo    = "otakup0pe/ansible-dupwrap"
  }
}

resource "aws_s3_bucket_public_access_block" "test" {
  bucket = aws_s3_bucket.test.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_user" "test" {
  name = "dupwrap-e2e-test-${random_id.suffix.hex}"
  path = "/testing/"

  tags = {
    Purpose = "dupwrap e2e test"
    Repo    = "otakup0pe/ansible-dupwrap"
  }
}

resource "aws_iam_user_policy" "test" {
  name = "dupwrap-e2e-test-bucket-access"
  user = aws_iam_user.test.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.test.arn,
          "${aws_s3_bucket.test.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_access_key" "test" {
  user = aws_iam_user.test.name
}

output "bucket_name" {
  value = local.bucket_name
}

output "bucket_uri" {
  value = "boto3+s3://${local.bucket_name}"
}

output "aws_access_key_id" {
  value = aws_iam_access_key.test.id
}

output "aws_secret_access_key" {
  value     = aws_iam_access_key.test.secret
  sensitive = true
}
