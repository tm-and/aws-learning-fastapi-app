# outputs.tf (または main.tf の一番下)

output "debug_github_repo_owner" {
  description = "DEBUG: GitHub Repository Owner variable value"
  value       = var.github_repository_owner
}

output "debug_github_repository_name" {
  description = "DEBUG: GitHub Repository Name variable value"
  value       = var.github_repository_name
}

output "debug_iam_sub_pattern_heads" {
  description = "DEBUG: IAM sub pattern for refs/heads/*"
  value       = "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/heads/*"
}

output "debug_iam_sub_pattern_pull_request" {
  description = "DEBUG: IAM sub pattern for pull_request event"
  value       = "repo:${var.github_repository_owner}/${var.github_repository_name}:pull_request"
}

output "debug_iam_sub_pattern_environment" {
  description = "DEBUG: IAM sub pattern for environment"
  value       = "repo:${var.github_repository_owner}/${var.github_repository_name}:environment:production"
}