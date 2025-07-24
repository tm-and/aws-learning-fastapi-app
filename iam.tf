# ======================================================================
# IAM Resources (for GitHub Actions OIDC)
# ======================================================================

# variables.tf (または main.tf の variable ブロック内)

variable "github_repository_owner" {
  description = "GitHubリポジトリのオーナー名"
  type        = string
  default     = "tm-and"
}

variable "github_repository_name" {
  description = "GitHubリポジトリ名"
  type        = string
  default     = "aws-learning-fastapi-app"
}

variable "aws_account_id" {
  description = "AWSアカウントID"
  type        = string
  default     = "447655429754"
}


# --- OIDC Identity Provider for GitHub ---
# GitHubが発行するIDトークンを信頼するためのプロバイダー
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  # クライアントID（Audience）は GitHub Actions の固定値
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "${var.project_name}-github-oidc-provider"
  }
}

# --- IAM Role for GitHub Actions (Terraform Apply) ---
# Terraformのデプロイを実行するためのロール
resource "aws_iam_role" "github_actions_tf_deploy_role" {
  name = "${var.project_name}-github-actions-tf-deploy-role"

  # GitHub ActionsからのAssumeRoleを許可するポリシー
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          "ForAnyValue:StringLike" = {
            "token.actions.githubusercontent.com:sub" : [
              "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/heads/main", # mainブランチへのプッシュ用
              "repo:${var.github_repository_owner}/${var.github_repository_name}:pull_request"       # ★ pull_request イベント用（これが重要！）★
            ]
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-github-actions-tf-deploy-role"
  }
}

# --- IAM Policy for GitHub Actions (Terraform Apply) ---
# Terraformが作成する全てのリソースへの権限を付与 (本番では最小権限に絞るべき)
resource "aws_iam_role_policy" "github_actions_tf_deploy_policy" {
  name = "${var.project_name}-github-actions-tf-deploy-policy"
  role = aws_iam_role.github_actions_tf_deploy_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "*" # <-- 本番環境では必要なAWSリソース操作に絞り込む
        Resource = "*" # <-- 本番環境ではARNでリソースを絞り込む
      }
    ]
  })
}

# --- IAM Role for GitHub Actions (ECR Push) ---
# ECRへのプッシュ権限を持つロール (CIビルド用)
resource "aws_iam_role" "github_actions_ecr_push_role" {
  name = "${var.project_name}-github-actions-ecr-push-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
          }

          # sub 条件をリストにして、複数のパターンを許可する
          # push イベント (refs/heads/*) と pull_request イベント (refs/pull/*) の両方を許可
          "ForAnyValue:StringLike" = { # 複数のパターンを許可する際に ForAnyValue:StringLike が推奨されるケースあり
            "token.actions.githubusercontent.com:sub" : [
              "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/heads/*",    # pushイベント（ブランチ）用
              "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/tags/*",     # tagイベント用（必要であれば）
              "repo:${var.github_repository_owner}/${var.github_repository_name}:pull_request",        # ★ pull_request イベント用（これが重要！）★
              # "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/pull/*/merge", # こちらも残してもよいが、pull_requestでカバーされることも多い
              # "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/pull/*/head" # 同上
            ]
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-github-actions-ecr-push-role"
  }
}

# --- IAM Policy for GitHub Actions (ECR Push) ---
resource "aws_iam_role_policy" "github_actions_ecr_push_policy" {
  name = "${var.project_name}-github-actions-ecr-push-policy"
  role = aws_iam_role.github_actions_ecr_push_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ecr:GetAuthorizationToken というIAMアクションが、AWSの設計上、リソースレベルのアクセス許可（特定のECRリポジトリARNを指定すること）をサポートしていない
        # そのため、 "*"である必要がある
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = aws_ecr_repository.app_repo.arn # 他のプッシュアクションはARNで限定
      }
    ]
  })
}

# --- Outputs (後でGitHub Actionsで参照するため) ---
output "github_actions_tf_deploy_role_arn" {
  description = "GitHub Actions Terraform Deploy Role ARN"
  value       = aws_iam_role.github_actions_tf_deploy_role.arn
}

output "github_actions_ecr_push_role_arn" {
  description = "GitHub Actions ECR Push Role ARN"
  value       = aws_iam_role.github_actions_ecr_push_role.arn
}