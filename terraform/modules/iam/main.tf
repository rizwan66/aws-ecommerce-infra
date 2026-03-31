# ─── EC2 Instance Role ────────────────────────────────────────────────────────
resource "aws_iam_role" "ec2_instance" {
  name = "${var.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.name_prefix}-ec2-role" }
}

# Least-privilege: only access own secret + CloudWatch + SSM
resource "aws_iam_role_policy" "ec2_custom" {
  name = "${var.name_prefix}-ec2-policy"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SecretsManagerAccess"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.db_secret_arn]
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid      = "EC2Metadata"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeTags"]
        Resource = "*"
      },
      {
        Sid    = "S3ArtifactsBucket"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::*-artifacts-*",
          "arn:aws:s3:::*-artifacts-*/*"
        ]
      }
    ]
  })
}

# AWS managed policies for SSM Session Manager and CloudWatch Agent
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_instance.name
  tags = { Name = "${var.name_prefix}-ec2-profile" }
}

# ─── GitHub Actions OIDC Role ─────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = "${var.name_prefix}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:rizwan66/*:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  #checkov:skip=CKV_AWS_355:GitHub Actions requires broad permissions to manage all AWS infrastructure via Terraform
  #checkov:skip=CKV_AWS_288:GitHub Actions role needs S3/Secrets access to manage Terraform state and app secrets
  #checkov:skip=CKV_AWS_286:GitHub Actions role needs iam:* to manage IAM resources via Terraform
  #checkov:skip=CKV_AWS_287:GitHub Actions role needs secretsmanager access to read app secrets via Terraform
  #checkov:skip=CKV_AWS_289:GitHub Actions role needs resource management permissions for infrastructure deployment
  #checkov:skip=CKV_AWS_290:GitHub Actions role needs write access to manage all AWS resources via Terraform
  name = "${var.name_prefix}-github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:*",
          "elasticloadbalancing:*",
          "autoscaling:*",
          "rds:*",
          "elasticache:*",
          "cloudwatch:*",
          "logs:*",
          "iam:*",
          "secretsmanager:*",
          "s3:*",
          "config:*",
          "sns:*",
          "dynamodb:*"
        ]
        Resource = "*"
      }
    ]
  })
}
