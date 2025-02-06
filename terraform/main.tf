provider "aws" {
  region = "eu-north-1"
}

data "aws_s3_bucket" "artifact_bucket" {
  bucket = "my-cicd-artifact-bucket"
}

data "aws_secretsmanager_secret" "github_token" {
  name = "github-token"
}

resource "aws_secretsmanager_secret_version" "github_token" {
  secret_id     = data.aws_secretsmanager_secret.github_token.id
  secret_string = "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"  # Replace with your actual GitHub token
}

resource "aws_iam_role" "codebuild_role" {
  name = "codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
           Service = [
            "codebuild.amazonaws.com",
            "codepipeline.amazonaws.com",
            "ecs.amazonaws.com"
          ]
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  role = aws_iam_role.codebuild_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:*",
          "logs:*",
          "ecs:*",
          "codebuild:*",
          "codepipeline:*"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_codebuild_project" "my_app_build" {
  name          = "my-app-build"
  service_role  = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:4.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/akpanphilip/aws-cicd-pipeline"
    git_clone_depth = 1
  }
}

resource "aws_ecs_cluster" "my_app_cluster" {
  name = "my-app-cluster"
}

resource "aws_ecs_task_definition" "my_app_task" {
  family                   = "my-app-task"
  execution_role_arn       = aws_iam_role.codebuild_role.arn
  task_role_arn            = aws_iam_role.codebuild_role.arn
  network_mode            = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([{
    name      = "my-app-container"
    image     = "my-app-image:latest"  # Use your image here
    essential = true
    memory    = 512
    cpu       = 256
    portMappings = [
      {
        containerPort = 80
        hostPort      = 80
        protocol      = "tcp"
      }
    ]
  }])
}

resource "aws_ecs_service" "my_app_service" {
  name            = "my-app-service"
  cluster         = aws_ecs_cluster.my_app_cluster.id
  task_definition = aws_ecs_task_definition.my_app_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = ["subnet-0e5937621394a0493"]  # Replace with your subnet IDs
    assign_public_ip = true
  }
}

resource "aws_codepipeline" "my_app_pipeline" {
  name     = "my-app-pipeline"
  role_arn = aws_iam_role.codebuild_role.arn

  artifact_store {
    location = data.aws_s3_bucket.artifact_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        Owner  = "akpanphilip"
        Repo   = "aws-cicd-pipeline"
        Branch = "main"
        OAuthToken = aws_secretsmanager_secret_version.github_token.secret_string
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]  # Input artifact from Source stage
      output_artifacts = ["build_output"]  # Define output artifact from Build stage
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.my_app_build.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name             = "Deploy"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "ECS"
      input_artifacts  = ["build_output"]
      version          = "1"

      configuration = {
         ClusterName       = aws_ecs_cluster.my_app_cluster.name
         ServiceName       = aws_ecs_service.my_app_service.name
         FileName          = "imagedefinitions.json"  # Output artifact from Build stage
      }
    }
  }
}
