# ======================================================================
# Terraform Core & Provider Configuration
# ======================================================================
terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "my-fastapi-app-terraform-state-unique-name" # ★手順1で作成したS3バケット名に置き換える★
    key            = "terraform.tfstate"                          # Stateファイルの名前
    region         = "ap-southeast-2"                             # あなたのAWSリージョンに合わせる
    dynamodb_table = "my-fastapi-app-terraform-lock"
    encrypt        = true # Stateファイルを暗号化
  }
}

provider "aws" {
  region = var.aws_region
}

# ======================================================================
# Variables
# ======================================================================
variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-southeast-2"
}


variable "project_name" {
  description = "プロジェクト名（リソース名のプレフィックスとして使用）"
  type        = string
  default     = "my-fastapi-app"
}

variable "public_subnet_ids_cidr" {
  description = "パブリックサブネットのCIDRブロックのリスト"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"] # 例: AZごとに1つずつ
}

variable "private_subnet_ids_cidr" {
  description = "プライベートサブネットのCIDRブロックのリスト"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"] # 例: AZごとに1つずつ
}

variable "app_image_tag" {
  description = "ECRにプッシュするDockerイメージのタグ"
  type        = string
  default     = "latest"
}

# ======================================================================
# Data Sources
# ======================================================================
# Available AZs を取得し、サブネット作成時にAZをローテートするために使用
data "aws_availability_zones" "available" {
  state = "available"
}

# ======================================================================
# Networking Resources (VPC, Subnets, NAT Gateway, Security Groups)
# ======================================================================

# --- VPC ---
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# --- Internet Gateway (IGW) ---
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# --- NAT Gateway用 Elastic IP ---
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

# --- NAT Gateway ---
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet[0].id

  tags = {
    Name = "${var.project_name}-nat-gw"
  }
  # IGW作成後にNAT GWを作成する依存関係を明示（Terraformが自動検出する場合もある）
  depends_on = [aws_internet_gateway.gw]
}

# --- Public Subnets ---
resource "aws_subnet" "public_subnet" {
  count      = length(var.public_subnet_ids_cidr)
  vpc_id     = aws_vpc.main.id
  cidr_block = element(var.public_subnet_ids_cidr, count.index)
  # Availability Zone をローテートさせる (例: ap-northeast-1a, ap-northeast-1b)
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  map_public_ip_on_launch = true # Fargateタスクには不要だが、EC2インスタンスを起動する場合などに影響

  tags = {
    Name = "${var.project_name}-public-subnet-${count.index}"
  }
}

# --- Private Subnets ---
resource "aws_subnet" "private_subnet" {
  count      = length(var.private_subnet_ids_cidr)
  vpc_id     = aws_vpc.main.id
  cidr_block = element(var.private_subnet_ids_cidr, count.index)
  # Public subnet とは異なる AZ を割り当てる (例: public は a, b なら private は b, c)
  availability_zone = element(data.aws_availability_zones.available.names, count.index + length(var.public_subnet_ids_cidr))


  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-private-subnet-${count.index}"
  }
}

# --- Route Tables ---
# Public Subnets Route Table (IGWへルーティング)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Public Subnets と Route Table の関連付け
resource "aws_route_table_association" "public_subnet_assoc" {
  count          = length(aws_subnet.public_subnet)
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

# Private Subnets Route Table (NAT Gatewayへルーティング)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

# Private Subnets と Route Table の関連付け
resource "aws_route_table_association" "private_subnet_assoc" {
  count          = length(aws_subnet.private_subnet)
  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private_rt.id
}

# --- Security Groups ---
# ALB Security Group (HTTP/HTTPS ingress)
resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP/HTTPS inbound traffic"
  vpc_id      = aws_vpc.main.id # Terraformで作成したVPCを参照

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Internetから許可
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Internetから許可 (証明書設定は別途必要)
  }

  # デフォルトのアウトバウンドルール (通常は全て許可)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

# ECS Task Security Group (ALBからのTCP:8000 ingress)
resource "aws_security_group" "ecs_task_sg" {
  name        = "${var.project_name}-ecs-task-sg"
  description = "Allow traffic from ALB"
  vpc_id      = aws_vpc.main.id # Terraformで作成したVPCを参照

  ingress {
    from_port = 8000 # FastAPIがリッスンするポート
    to_port   = 8000
    protocol  = "tcp"
    # ALBのセキュリティグループからのトラフィックのみを許可
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Fargateタスクはインターネットへのアウトバウンド通信が必要
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ecs-task-sg"
  }
}

# ======================================================================
# IAM Resources (Roles and Policies)
# ======================================================================

# --- ECS Task Execution Role ---
data "aws_iam_policy_document" "ecs_task_execution_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${var.project_name}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role_policy.json
}

# ECRからのイメージプル権限
resource "aws_iam_role_policy" "ecs_task_execution_ecr_pull" {
  name = "${var.project_name}-ecs-task-execution-ecr-pull-policy"
  role = aws_iam_role.ecs_task_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Effect   = "Allow"
        Resource = "*" # 制限する場合はリポジトリARNを指定
      }
    ]
  })
}

# CloudWatch Logsへのログ送信権限
resource "aws_iam_role_policy" "ecs_task_execution_cloudwatch_logs" {
  name = "${var.project_name}-ecs-task-execution-cloudwatch-logs-policy"
  role = aws_iam_role.ecs_task_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --- ECSタスク実行ロールにSecrets Managerからの読み取り権限を追加 ---
resource "aws_iam_role_policy" "ecs_task_execution_secrets_manager_read" {
  name = "${var.project_name}-ecs-task-execution-secrets-manager-read-policy"
  role = aws_iam_role.ecs_task_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.rds_credentials.arn # 特定のシークレットに限定
      }
    ]
  })
}


# ======================================================================
# Container Registry (ECR)
# ======================================================================
resource "aws_ecr_repository" "app_repo" {
  name = "${var.project_name}-app-repo"

  image_tag_mutability = "MUTABLE"


  image_scanning_configuration {
    scan_on_push = true
  }
}

# ECRリポジトリのURIを取得 (ECS Task Definitionで参照するため)
data "aws_ecr_repository" "app_repo_data" {
  name = aws_ecr_repository.app_repo.name
  # depends_on = [aws_ecr_repository.app_repo] # Explicitly depends on the ECR repo creation
}

# ======================================================================
# ECS Resources (Cluster, Task Definition, Service)
# ======================================================================

# --- ECS Cluster ---
resource "aws_ecs_cluster" "app_cluster" {
  name = "${var.project_name}-cluster"
  tags = {
    Name = "${var.project_name}-cluster"
  }
}

# --- ECS Task Definition ---
resource "aws_ecs_task_definition" "app_task_def" {
  family = "${var.project_name}-task-def"
  # task_role_arn = aws_iam_role.ecs_task_execution_role.arn # Task Role (もし必要なら)
  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn # Task Execution Role (Fargateで必須)
  network_mode       = "awsvpc"

  cpu    = "256" # 0.25 vCPU
  memory = "512" # 512 MB

  runtime_platform {
    cpu_architecture        = "X86_64" # <-- ここでX86_64を指定
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-container"
      image     = "${data.aws_ecr_repository.app_repo_data.repository_url}:${var.app_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000 # Fargateではコンテナポートと同じ
          protocol      = "tcp"
        }
      ]

      secrets = [
        {
          name      = "DATABASE_USER"
          valueFrom = "${aws_secretsmanager_secret.rds_credentials.arn}:username::" # JSONキー `username` を参照
        },
        {
          name      = "DATABASE_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.rds_credentials.arn}:password::" # JSONキー `password` を参照
        }
      ]

      environment = [
        {
          name  = "PORT"
          value = "8000"
        },
        {
          name  = "DATABASE_HOST"
          value = aws_db_instance.rds_instance.address
        },
        {
          name  = "DATABASE_PORT"
          value = tostring(aws_db_instance.rds_instance.port)
        },
        {
          name  = "DATABASE_NAME"
          value = aws_db_instance.rds_instance.db_name
        }
      ]

      logConfiguration = {
        logDriver = "awslogs",
        options = {
          "awslogs-group"         = "/ecs/${var.project_name}-app-container",
          "awslogs-create-group"  = "true",
          "awslogs-region"        = var.aws_region,
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# --- ECS Service ---
resource "aws_ecs_service" "app_service" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.app_cluster.id
  task_definition = aws_ecs_task_definition.app_task_def.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    assign_public_ip = false # プライベートサブネットに配置するため
    # Terraformで作成したプライベートサブネットを参照
    subnets         = [for subnet in aws_subnet.private_subnet : subnet.id]
    security_groups = [aws_security_group.ecs_task_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_target_group.arn
    container_name   = "${var.project_name}-container"
    container_port   = 8000
  }

  # Circuit Breaker設定
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 依存関係: Task Definition, IAM Roles, ALB Listener の作成後に実行
  depends_on = [
    aws_ecs_task_definition.app_task_def,
    aws_iam_role_policy.ecs_task_execution_ecr_pull,
    aws_iam_role_policy.ecs_task_execution_cloudwatch_logs,
    aws_lb_listener.app_listener
  ]

  tags = {
    Name = "${var.project_name}-service"
  }
}

# ======================================================================
# Load Balancer Resources (ALB, Target Group, Listener)
# ======================================================================

# --- ALB Target Group ---
resource "aws_lb_target_group" "app_target_group" {
  name     = "${var.project_name}-alb-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id # Terraformで作成したVPCを参照

  target_type = "ip" # Fargateの場合

  health_check {
    path                = "/"
    protocol            = "HTTP"
    port                = "8000"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

# --- ALB Listener (HTTP:80) ---
resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_target_group.arn
  }
}

# --- ALB ---
resource "aws_lb" "app_alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]                       # ALBのSGを参照
  subnets            = [for subnet in aws_subnet.public_subnet : subnet.id] # Public Subnetsを参照

  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-alb"
  }
}


# --- RDS用のDBサブネットグループ ---
# RDSインスタンスを配置するプライベートサブネットのグループ
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "${var.project_name}-rds-subnet-group"
  subnet_ids = [for subnet in aws_subnet.private_subnet : subnet.id] # プライベートサブネットを指定

  tags = {
    Name = "${var.project_name}-rds-subnet-group"
  }
}

# --- RDS用のセキュリティグループ ---
# ECSタスクからのDB接続 (5432ポート) を許可する
resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "Allow PostgreSQL inbound traffic"
  vpc_id      = aws_vpc.main.id

  # ECSタスクのセキュリティグループからのインバウンド接続を許可
  ingress {
    from_port       = 5432 # PostgreSQLのポート
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_task_sg.id]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# --- Secrets Manager for RDS Credentials ---
# DBのマスターユーザー名とパスワードを安全に保存
resource "aws_secretsmanager_secret" "rds_credentials" {
  name = "${var.project_name}/rds/credentials"
}

# --- ランダムなパスワードを生成 ---
resource "random_password" "rds_master_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# --- Secrets Managerに初期値を設定 ---
# 生成したランダムパスワードと固定のユーザー名をシークレットに保存
resource "aws_secretsmanager_secret_version" "rds_credentials_version" {
  secret_id     = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.rds_master_password.result
  })
}

# --- RDS PostgreSQL Instance ---
resource "aws_db_instance" "rds_instance" {
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "15.8"
  instance_class       = "db.t4g.micro"
  db_name              = "${var.project_name}_db"

  username             = jsondecode(aws_secretsmanager_secret_version.rds_credentials_version.secret_string)["username"]
  password             = jsondecode(aws_secretsmanager_secret_version.rds_credentials_version.secret_string)["password"]

  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot  = true
  # backup_retention_period = 7 # 本番環境ではバックアップを設定
  # multi_az             = true # 本番環境ではMulti-AZを有効化

  tags = {
    Name = "${var.project_name}-rds"
  }
}

# ======================================================================
# Outputs
# ======================================================================
output "alb_dns_name" {
  description = "Application Load BalancerのDNS名"
  value       = aws_lb.app_alb.dns_name
}

output "ecr_repository_uri" {
  description = "ECRリポジトリのURI"
  value       = aws_ecr_repository.app_repo.repository_url
}

output "ecs_cluster_name" {
  description = "ECSクラスター名"
  value       = aws_ecs_cluster.app_cluster.name
}

output "ecs_service_name" {
  description = "ECSサービス名"
  value       = aws_ecs_service.app_service.name
}