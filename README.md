

# Lessons
AWS ECS Fargate + ALB + Terraform + GitHub Actions CI/CD 構築のつまづきポイントまとめ

### 1. Dockerイメージとコンテナ実行環境のアーキテクチャ不一致

*   **エラーメッセージ例:**
    *   `exec /usr/local/bin/uvicorn: exec format error`
    *   `exec /usr/local/bin/gunicorn: exec format error`
*   **原因:**
    *   ローカルPC (M1/M2 Macなど) が **ARM64** アーキテクチャでDockerイメージをビルドするのに対し、AWS ECS Fargateのデフォルト（または意図された）実行環境が **X86_64 (AMD64)** アーキテクチャであったため。
    *   異なるCPUアーキテクチャ用にビルドされたバイナリを実行しようとすると発生します。
*   **解決策:**
    *   **ローカルでビルドしたイメージのアーキテクチャを確認する:** `docker inspect <image_id_or_tag> | grep Architecture`
    *   **ECS Task Definition で `runtime_platform` を明示的に指定する:**
        ```terraform
        resource "aws_ecs_task_definition" "app_task_def" {
          # ...
          runtime_platform {
            cpu_architecture        = "X86_64" # または ARM64
            operating_system_family = "LINUX"
          }
          # ...
        }
        ```
    *   **`docker buildx` を使って、ECSが期待するアーキテクチャのイメージをビルドし、ECRにプッシュする:**
        ```bash
        docker buildx create --use
        docker buildx build --platform linux/amd64 -t <ECR_REPO_URI>:latest --push . # AMD64用
        # または
        # docker buildx build --platform linux/arm64 -t <ECR_REPO_URI>:latest --push . # ARM64用
        ```*   **教訓:**
    *   「ローカルで動くものがクラウドで動かない」典型例。DockerイメージのCPUアーキテクチャと、コンテナが実行される環境のアーキテクチャは**必ず一致させる**。
    *   `exec format error` はアーキテクチャ不一致の強いシグナル。
    *   **`docker buildx` はマルチアーキテクチャ対応の必須ツール。**

### 2. ECRへのDockerイメージプッシュミス

*   **エラーメッセージ例:**
    *   `ERROR: name unknown: The repository with name 'my-fastapi-app-app-repoatest' does not exist...`
*   **原因:**
    *   `docker push` コマンドのECRリポジトリURIにタイプミスがあった（例: `$ECR_REPO_URI:latest` が `repoatest` に展開された）。
*   **解決策:**
    *   EXPORTで設定せず、直接URIをコマンドに含めて実行する（暫定処置）

### 4. Terraformの変数渡しと命名規則の構文エラー

*   **エラーメッセージ例:**
    *   `Error: Reference to undeclared input variable`
    *   `Error: Invalid value for input variable: list of string required.`
    *   `Error: "name" cannot begin with a hyphen`
    *   `Missing attribute separator; Expected a newline or comma to mark the beginning of the next attribute.` (`jsonencode` 内のHCL構文エラー)
*   **原因:**
    *   Terraformの変数 (`var.xxx`) が定義されていないのに参照した。
    *   `terraform plan -var='key=${{ env.JSON_STRING }}'` のように、JSON文字列を `-var` で渡す際に、Terraformがそれを文字列リテラルと解釈してしまい、リスト型として認識できなかった。
    *   AWSリソースの命名規則に違反した（例: ターゲットグループ名がハイフンで始まった）。
*   **解決策:**
    *   **Terraform変数に `default` 値を設定する（暫定処置）**
    *   リスト型の変数は、GitHub Actionsから直接 `-var` で渡すのではなく、**Terraformコードの `default` 値に設定する**。

### 3. GitHub ActionsのOIDC認証とIAMロールの信頼ポリシー

*   **エラーメッセージ例:**
    *   `Error: Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`
    *   `is not authorized to perform: ecr:GetAuthorizationToken on resource: *`
*   **原因:**
    *   **IAM OIDC Providerの `thumbprint_list` が古い/不要な場合に設定されていた。** (最新のGitHub Actionsでは不要)
    *   **IAMロールの信頼ポリシー (`assume_role_policy`) の `Condition` が、GitHub Actionsが送るOIDCトークンの `sub` クレームのパターンと不一致。**
        *   `StringEquals` と `StringLike` の使い分けミス。
        *   `github.ref` が `refs/pull/*/merge` や `refs/pull/*/head` となるPull Requestイベントのパターンに対応できていない。
        *   `sub` クレームのパターン (`repo:owner/repo:ref:refs/heads/*`, `repo:owner/repo:pull_request` など) が不足していたり、不正確だったりした。
    *   **`ecr:GetAuthorizationToken` アクションが、`Resource: "*"` を要求するアクションであるにもかかわらず、特定のリソースARNで制限しようとしていた（または、ポリシーが正しく適用されていなかった）。**
    *   `terraform apply` を実行し忘れたり、AWS側で変更が完全に反映されていなかったりしたため、IAMロールのポリシーが最新の状態になっていなかった。
*   **解決策:**
    *   **IAMロールの信頼ポリシーの `Condition` を、GitHub Actionsの `push` と `pull_request` 両方のトリガーで発行される `sub` クレームのパターンを網羅するように修正する。**
        ```terraform
        # 例
        StringLike = {
          "token.actions.githubusercontent.com:sub" : [
            "repo:${var.github_repository_owner}/${var.github_repository_name}:ref:refs/heads/*",
            "repo:${var.github_repository_owner}/${var.github_repository_name}:pull_request" # これが特に重要
          ]
        }
        ```
    *   `ecr:GetAuthorizationToken` アクションは、必ず `Resource: "*"` を指定した独立した `Statement` ブロックで許可する。
    *   AWSコンソールのIAMロールの Trust RelationshipsのJSONを見る
    *   IAM Policy Simulatorで確認してみる

