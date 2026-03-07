provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Use shared GitHub Connection (created in bootstrap-pipeline)
data "aws_codestarconnections_connection" "github" {
  arn = var.github_connection_arn
}

# S3 Bucket for Artifacts
resource "aws_s3_bucket" "pipeline_artifact" {
  bucket        = "pipeline-provisioner-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # Allow deletion even if bucket contains objects
}

resource "aws_s3_bucket_versioning" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifact" {
  bucket = aws_s3_bucket.pipeline_artifact.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# CodeBuild Project - Pipeline Provisioner
resource "aws_codebuild_project" "provisioner" {
  name          = "pipeline-provisioner"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 60

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "GITHUB_REPOSITORY"
      value = var.github_repository
    }
    environment_variable {
      name  = "GITHUB_BRANCH"
      value = var.github_branch
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
    environment_variable {
      name  = "GITHUB_CONNECTION_ARN"
      value = data.aws_codestarconnections_connection.github.arn
    }
    environment_variable {
      name  = "PLATFORM_IMAGE"
      value = var.codebuild_image
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-provisioner/buildspec.yml"
  }
}

# CodeBuild Project - Build Platform Image
resource "aws_codebuild_project" "build_platform_image" {
  name          = "pipeline-provisioner-build-image"
  service_role  = aws_iam_role.build_platform_image_role.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "terraform/config/pipeline-provisioner/buildspec-build-image.yml"
  }
}

# CodePipeline - Pipeline Provisioner
resource "aws_codepipeline" "provisioner" {
  name           = "pipeline-provisioner"
  role_arn       = aws_iam_role.codepipeline_role.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED" # Prevent parallel executions that could cause lock conflicts

  artifact_store {
    location = aws_s3_bucket.pipeline_artifact.bucket
    type     = "S3"
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.github_branch]
        }
        file_paths {
          includes = [
            "deploy/${var.environment}/*/terraform/regional.json",
            "deploy/${var.environment}/*/terraform/management/*.json",
            "terraform/config/pipeline-regional-cluster/**",
            "terraform/config/pipeline-management-cluster/**",
            "terraform/modules/platform-image/**",
            "scripts/build-platform-image.sh"
          ]
        }
      }
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = data.aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repository
        BranchName       = var.github_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Build-Platform-Image"

    action {
      name            = "BuildPlatformImage"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.build_platform_image.name
      }
    }
  }

  stage {
    name = "Provision"

    action {
      name            = "ProvisionPipelines"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.provisioner.name
      }
    }
  }
}
