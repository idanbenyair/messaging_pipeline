# Creating ECR repo
resource "aws_ecr_repository" "msg-pipe-ecr-repo" {
  name                 = "msg-pipe-ecr-repo"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository_policy" "msg-pipe-ecr-policy" {
  repository = aws_ecr_repository.msg-pipe-ecr-repo.name

  policy = <<EOF
{
    "Version": "2008-10-17",
    "Statement": [
        {
            "Sid": "new policy",
            "Effect": "Allow",
            "Principal": "*",
            "Action": [
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:BatchCheckLayerAvailability",
                "ecr:PutImage",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload",
                "ecr:DescribeRepositories",
                "ecr:GetRepositoryPolicy",
                "ecr:ListImages",
                "ecr:DeleteRepository",
                "ecr:BatchDeleteImage",
                "ecr:SetRepositoryPolicy",
                "ecr:DeleteRepositoryPolicy"
            ]
        }
    ]
}
EOF
}

#data "aws_ecr_image" "nginx-image" {
#  repository_name = aws_ecr_repository.msg-pipe-ecr-repo.name
#  image_tag       = "latest"
#}

# Creating ECS task, cluster and service. As well as fargate
resource "aws_ecs_task_definition" "msg-pipe-ecs-task" {
  family                = "nginx"
  container_definitions = file("task-definitions/web-service.json")
#  requires_compatibilities = ["FARGATE"]
  cpu = 256
  memory = 512
#  volume {
#    name      = "service-storage"
#    host_path = "/ecs/service-storage"
#  }
#  container_definitions = jsonencode([
#    {
#      name : "sample-fargate-app",
#      image : "httpd:2.4",
#      cpu : 256,
#      memory : 512,
#      essential: true,
#      mountPoints: [
#        {
#          sourceVolume: "service-storage",
#          containerPath: "/var/scratch"
#        }
#      ],
#      networkMode : "awsvpc",
#      portMappings : [
#        {
#          containerPort : 80,
#          protocol : "tcp",
#          hostPort : 80
#        }
#      ]
#    }
#  ])

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.availability-zone in [us-west-2a, us-west-2b]"
  }
}

resource "aws_ecs_cluster" "msg-pipe-ecs-cluster" {
    name = var.cluster_name
    
}

resource "aws_ecs_service" "msg-pipe-ecs-service" {
  name            = "web-service"
  cluster         = aws_ecs_cluster.msg-pipe-ecs-cluster.id
  task_definition = aws_ecs_task_definition.msg-pipe-ecs-task.arn
  desired_count   = 1
#  launch_type     = "FARGATE"
#  iam_role        = aws_iam_role.msg-pipe-ecs-role.arn
  depends_on      = [aws_ecs_cluster.msg-pipe-ecs-cluster]

  ordered_placement_strategy {
    type  = "binpack"
    field = "cpu"
  }

#  load_balancer {
#    target_group_arn = aws_lb_target_group.foo.arn
#    container_name   = "mongo"
#    container_port   = 8080
#  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.availability-zone in [us-west-2a, us-west-2b]"
  }
}

# Creating codepipeline steps
resource "aws_codepipeline" "codepipeline" {
  name     = "messaging-pipeline-cicd"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline_bucket.bucket
    type     = "S3"

    encryption_key {
      id   = data.aws_kms_alias.s3kmskey.arn
      type = "KMS"
    }
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
        Owner      = "skatz1990"
        Repo       = "messaging_pipeline"
        Branch     = "messaging_pipeline_tf"
        OAuthToken = var.github_token
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
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = "test"
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ClusterName = aws_ecs_cluster.msg-pipe-ecs-cluster.name
        ServiceName = var.app_service_name
        FileName    = "imagedefinitions.json"
      }
    }
  }
}

# Artifacts bucket
resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket = "messaging-pipeline-bucket"
  acl    = "private"
}

# IAM roles and policies
resource "aws_iam_role" "codepipeline_role" {
  name = "msg-pipeline-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline_policy"
  role = aws_iam_role.codepipeline_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObject"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline_bucket.arn}",
        "${aws_s3_bucket.codepipeline_bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

data "aws_kms_alias" "s3kmskey" {
  name = "alias/s3_kms_key"
}
