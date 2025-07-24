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
          StringEquals = {
            # GitHub Actionsの Issuer と Audience を指定
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com",
            # リポジトリとブランチを指定して、特定のワークフローからの実行を制限
            # Pull Request の場合は pull_request イベントのソースブランチを、
            # Push やマージの場合は main ブランチを指定することが多い
            "token.actions.githubusercontent.com:sub" : "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/heads/main"
            # 特定のワークフローや環境に絞ることも可能
            # "token.actions.githubusercontent.com:sub": "repo:octo-org/octo-repo:environment:production"
            # "token.actions.githubusercontent.com:sub": "repo:octo-org/octo-repo:ref:refs/heads/main"
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
          StringLike = {
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com",
            # 全てのブランチからのビルドを許可する場合
            "token.actions.githubusercontent.com:sub" : "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/heads/*"
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
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
          # ... 他のECRアクション ...
        ]
        Resource = "*" # ★一時的にワイルドカードに変更して試す★
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