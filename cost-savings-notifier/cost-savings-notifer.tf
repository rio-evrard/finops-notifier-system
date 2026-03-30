# Cost Savings Notifier

# ==============================================================================
# 0. LOCALS & DATA SOURCES
# ==============================================================================
locals {
  athena_database_name = "cost_optimization_reports"
  athena_table_name    = "data"
  export_prefix        = "recommendations"
}

data "aws_caller_identity" "current" {}

# ==============================================================================
# 1. STORAGE: S3 Bucket & Policies
# ==============================================================================
resource "aws_s3_bucket" "automation_cost_savings_data" {
  bucket = var.cost_savings_s3_bucket
}

resource "aws_s3_bucket_server_side_encryption_configuration" "automation_cost_savings_data_sse" {
  bucket = aws_s3_bucket.automation_cost_savings_data.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "bcm_data_export_policy" {
  statement {
    sid    = "EnableAWSDataExportsToWriteToS3"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetBucketPolicy",
      "s3:GetBucketAcl"
    ]
    resources = [
      aws_s3_bucket.automation_cost_savings_data.arn,
      "${aws_s3_bucket.automation_cost_savings_data.arn}/*"
    ]
    principals {
      type = "Service"
      identifiers = [
        "bcm-data-exports.amazonaws.com",
        "billingreports.amazonaws.com"
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "automation_cost_savings_data_policy" {
  bucket = aws_s3_bucket.automation_cost_savings_data.id
  policy = data.aws_iam_policy_document.bcm_data_export_policy.json
}

# ==============================================================================
# 2. DATA INGESTION: Cost Optimization Hub Export
# ==============================================================================

# Leaving this code bellow commented out in case AWS decides to allow delegated administrators to make exports of Cost Optimization Hub Recommendations

# Create the Service-Linked Role required for Data Exports to read Cost Optimization Hub
# resource "aws_iam_service_linked_role" "bcm_data_exports" {
#   aws_service_name = "bcm-data-exports.amazonaws.com"
# }

# resource "aws_bcmdataexports_export" "cost_optimization_export" {
#   export {
#     name = "CostOptimizationRecommendations"

#     data_query {
#       query_statement = "SELECT account_id, account_name, action_type, currency_code, current_resource_details, current_resource_summary, current_resource_type, estimated_monthly_cost_after_discount, estimated_monthly_cost_before_discount, estimated_monthly_savings_after_discount, estimated_monthly_savings_before_discount, estimated_savings_percentage_after_discount, estimated_savings_percentage_before_discount, implementation_effort, last_refresh_timestamp, recommendation_id, recommendation_lookback_period_in_days, recommendation_source, recommended_resource_details, recommended_resource_summary, recommended_resource_type, region, resource_arn, restart_needed, rollback_possible, tags FROM COST_OPTIMIZATION_RECOMMENDATIONS"

#       table_configurations = {
#         "COST_OPTIMIZATION_RECOMMENDATIONS" = {
#           "INCLUDE_ALL_RECOMMENDATIONS" = "TRUE"
#           "FILTER"                      = "{}"
#         }
#       }
#     }

#     destination_configurations {
#       s3_destination {
#         s3_bucket = aws_s3_bucket.automation_cost_savings_data.bucket
#         s3_prefix = local.export_prefix
#         s3_region = var.aws_region

#         s3_output_configurations {
#           compression = "PARQUET"
#           format      = "PARQUET"
#           output_type = "CUSTOM"
#           overwrite   = "OVERWRITE_REPORT"
#         }
#       }
#     }

#     refresh_cadence {
#       frequency = "SYNCHRONOUS"
#     }
#   }

#   depends_on = [
#     aws_s3_bucket_policy.automation_cost_savings_data_policy
#   ]
# }

# ==============================================================================
# 3. DATA CATALOGING: AWS Glue Database & Crawler
# ==============================================================================
resource "aws_glue_catalog_database" "cost_optimization_db" {
  name = local.athena_database_name
}

resource "aws_iam_role" "glue_crawler_role" {
  name = "CostOptimizationCrawlerRole"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "glue.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service_role_attach" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_policy" "glue_s3_access" {
  name        = "CostOptimizationCrawlerS3Access"
  description = "Allows Glue Crawler to read the exported recommendations"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.management_cost_export_bucket}",
          "arn:aws:s3:::${var.management_cost_export_bucket}/recommendations/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_s3_access_attach" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = aws_iam_policy.glue_s3_access.arn
}

resource "aws_glue_crawler" "cost_data_crawler" {
  database_name = aws_glue_catalog_database.cost_optimization_db.name
  name          = "cost_optimization_reports_crawler"
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${var.management_cost_export_bucket}/recommendations/CostOptimizationRecommendations/data/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  schedule = "cron(0 6 1 1/2 ? *)"
}

resource "aws_athena_workgroup" "cost_optimization_wg" {
  name = "cost_optimization_wg"
  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    result_configuration {
      output_location = "s3://${aws_s3_bucket.automation_cost_savings_data.bucket}/athena-query-results/"
    }
  }
}

# ==============================================================================
# 4. COMPUTE: Lambda Function & IAM
# ==============================================================================
data "archive_file" "cost_savings_notifier_zip" {
  type        = "zip"
  output_path = "${path.module}/cost_savings_notifier.zip"
  source_file = "${path.module}/lambda_src/cost-saving-notification.py"
}

resource "aws_iam_role" "cost_savings_notifier_lambda_role" {
  name = "CostSavingsNotifierRole"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.cost_savings_notifier_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "cost_savings_notifier_policy" {
  name        = "CostSavingsNotifierPolicy"
  description = "Permissions for Cost Savings Notifier to fetch Athena results and read S3 config"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LocalBucketAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.automation_cost_savings_data.arn,
          "${aws_s3_bucket.automation_cost_savings_data.arn}/*"
        ]
      },
      {
        Sid      = "AthenaExecution"
        Effect   = "Allow"
        Action   = ["athena:GetQueryExecution", "athena:GetQueryResults"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_app_policy" {
  role       = aws_iam_role.cost_savings_notifier_lambda_role.name
  policy_arn = aws_iam_policy.cost_savings_notifier_policy.arn
}

resource "aws_lambda_function" "cost_savings_notifier" {
  function_name    = "CostSavingsNotifier"
  description      = "Processes finished Athena CostSavings queries and notifies via Teams"
  role             = aws_iam_role.cost_savings_notifier_lambda_role.arn
  handler          = "cost-saving-notification.lambda_handler"
  runtime          = "python3.13"
  timeout          = 60 # Dropped from 300 to 60 because polling is gone!
  memory_size      = 256
  filename         = data.archive_file.cost_savings_notifier_zip.output_path
  source_code_hash = data.archive_file.cost_savings_notifier_zip.output_base64sha256

  environment {
    variables = {
      WEBHOOK_MAP_BUCKET = aws_s3_bucket.automation_cost_savings_data.bucket
      WEBHOOK_MAP_KEY    = "config/table_account_name.json"
    }
  }
}

# ==============================================================================
# 5. ORCHESTRATION: Step Functions & EventBridge Scheduler
# ==============================================================================

# Step Function IAM Role
resource "aws_iam_role" "step_function_role" {
  name = "CostSavingsSFNRole"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "states.amazonaws.com" } }]
  })
}

resource "aws_iam_policy" "step_function_policy" {
  name        = "CostSavingsSFNPolicy"
  description = "Allows Step Function to trigger Athena and Lambda"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:StopQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:PutObject"]
        Resource = [
          aws_s3_bucket.automation_cost_savings_data.arn,
          "${aws_s3_bucket.automation_cost_savings_data.arn}/*",
          "arn:aws:s3:::${var.management_cost_export_bucket}",
          "arn:aws:s3:::${var.management_cost_export_bucket}/recommendations/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetDatabase", "glue:GetPartitions"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.cost_savings_notifier.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sfn_policy_attach" {
  role       = aws_iam_role.step_function_role.name
  policy_arn = aws_iam_policy.step_function_policy.arn
}

# The Step Function State Machine
resource "aws_sfn_state_machine" "cost_savings_orchestrator" {
  name     = "CostSavingsOrchestrator"
  role_arn = aws_iam_role.step_function_role.arn

  definition = jsonencode({
    StartAt = "RunAthenaQuery"
    States = {
      RunAthenaQuery = {
        Type     = "Task"
        Resource = "arn:aws:states:::athena:startQueryExecution.sync"
        Parameters = {
          QueryString = "SELECT resource_arn AS resource_id, tags, current_resource_type AS resource_type, estimated_monthly_savings_after_discount AS savings, COALESCE(json_extract_scalar(recommended_resource_details, '$.ec2Instance.configuration.instance.type'), json_extract_scalar(recommended_resource_details, '$.rdsDbInstance.configuration.instance.type'), json_extract_scalar(recommended_resource_details, '$.rdsDbInstance.configuration.dbInstanceClass'), 'See AWS Console') AS recommended_instance_type FROM \"${local.athena_database_name}\".\"${local.athena_table_name}\" WHERE \"date\" = (SELECT max(\"date\") FROM \"${local.athena_database_name}\".\"${local.athena_table_name}\") AND action_type = 'MigrateToGraviton' AND current_resource_type IN ('Ec2Instance', 'RdsDbInstance')"
          WorkGroup   = aws_athena_workgroup.cost_optimization_wg.name
        }
        ResultPath = "$.AthenaResult"
        Next       = "NotifyTeams"
      }
      NotifyTeams = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.cost_savings_notifier.arn
          Payload = {
            # Extract the execution ID generated by Athena and pass it directly to Lambda
            "execution_id.$" = "$.AthenaResult.QueryExecution.QueryExecutionId"
          }
        }
        End = true
      }
    }
  })
}

# EventBridge Scheduler targeting the Step Function
resource "aws_iam_role" "scheduler_role" {
  name = "CostSavingsNotifierSchedulerRole"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "scheduler.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "scheduler_policy" {
  name = "CostSavingsNotifierSchedulerInvoke"
  role = aws_iam_role.scheduler_role.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.cost_savings_orchestrator.arn }]
  })
}

resource "aws_scheduler_schedule" "bimonthly_schedule" {
  name                = "CostSavingsNotifierBiMonthly"
  group_name          = "default"
  schedule_expression = "cron(0 9 1 1/2 ? *)"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_sfn_state_machine.cost_savings_orchestrator.arn
    role_arn = aws_iam_role.scheduler_role.arn
  }
}

# -----------------------------------------------------------------------------
# 6. CI/CD: WebhookSync Role (GitHub Actions OIDC)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "github_oidc_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:your-org/your-repo:*"]
    }
  }
}

data "aws_iam_policy_document" "webhook_sync_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.automation_cost_savings_data.arn}/config/table_account_name.json"]
  }
}

resource "aws_iam_role" "webhook_sync_role" {
  name               = "CostSavingsNotifierWebhookSyncRole"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume_role.json
}

resource "aws_iam_policy" "webhook_sync_policy" {
  name        = "CostSavingsNotifierWebhookSyncPolicy"
  description = "Allows GitHub Actions to push the webhook mapping file to the automation cost data S3 bucket."
  policy      = data.aws_iam_policy_document.webhook_sync_permissions.json
}

resource "aws_iam_role_policy_attachment" "webhook_sync_attach" {
  role       = aws_iam_role.webhook_sync_role.name
  policy_arn = aws_iam_policy.webhook_sync_policy.arn
}
