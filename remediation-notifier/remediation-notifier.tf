# Remediation Notifier

# ==============================================================================
# 1. LOCALS & DATA SOURCES
# ==============================================================================
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_organizations_organization" "current" {}

# ==============================================================================
# 2. SQS BUFFER (The Decoupler)
# ==============================================================================
resource "aws_sqs_queue" "remediation_dlq" {
  name = "remediation-notifications-dlq"
}

resource "aws_sqs_queue" "remediation_queue" {
  name                       = "remediation-notifications-queue"
  visibility_timeout_seconds = 300 # Must be >= Lambda timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.remediation_dlq.arn
    maxReceiveCount     = 3
  })
}

# ==============================================================================
# 3. LAMBDA 1: THE REMEDIATOR (Fixes the issue, pushes to SQS)
# ==============================================================================
data "archive_file" "remediator_zip" {
  type        = "zip"
  output_path = "${path.module}/remediator.zip"
  source_file = "${path.module}/lambda_src/remediator.py" # Will need to split Python code
}

resource "aws_iam_role" "remediator_role" {
  name = "S3RemediatorRole"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "remediator_basic_execution" {
  role       = aws_iam_role.remediator_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "remediator_policy" {
  name        = "S3RemediatorPolicy"
  description = "Permissions for Remediator to assume workload roles and push to SQS"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeWorkloadRemediationRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::*:role/WorkloadEventRemediationRole"
      },
      {
        Sid      = "SendMessageToQueue"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.remediation_queue.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_remediator_policy" {
  role       = aws_iam_role.remediator_role.name
  policy_arn = aws_iam_policy.remediator_policy.arn
}

resource "aws_lambda_function" "remediator_lambda" {
  function_name    = "S3-Remediator"
  description      = "Instantly disables S3 self-logging loops and drops event into SQS"
  role             = aws_iam_role.remediator_role.arn
  handler          = "remediator.lambda_handler"
  runtime          = "python3.13"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.remediator_zip.output_path
  source_code_hash = data.archive_file.remediator_zip.output_base64sha256

  environment {
    variables = {
      SQS_QUEUE_URL = aws_sqs_queue.remediation_queue.url
    }
  }
}

# ==============================================================================
# 4. LAMBDA 2: THE COMMUNICATOR (Pulls from SQS, posts to Teams)
# ==============================================================================
data "archive_file" "communicator_zip" {
  type        = "zip"
  output_path = "${path.module}/communicator.zip"
  source_file = "${path.module}/lambda_src/communicator.py" # Will need to split Python code
}

resource "aws_iam_role" "communicator_role" {
  name = "RemediationCommunicatorRole"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "communicator_basic_execution" {
  role       = aws_iam_role.communicator_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# AWS Managed policy for Lambda to read from SQS
resource "aws_iam_role_policy_attachment" "communicator_sqs_execution" {
  role       = aws_iam_role.communicator_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

resource "aws_iam_policy" "communicator_policy" {
  name        = "RemediationCommunicatorPolicy"
  description = "Permissions to read Teams config and resolve Org accounts"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadWebhookConfig"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${var.config_s3_bucket}/config/table_account_name.json"
      },
      {
        Sid      = "DescribeOrganizationAccounts"
        Effect   = "Allow"
        Action   = "organizations:DescribeAccount"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_communicator_policy" {
  role       = aws_iam_role.communicator_role.name
  policy_arn = aws_iam_policy.communicator_policy.arn
}

resource "aws_lambda_function" "communicator_lambda" {
  function_name    = "Remediation-Communicator"
  description      = "Pulls remediated events from SQS and dispatches MS Teams notifications"
  role             = aws_iam_role.communicator_role.arn
  handler          = "communicator.lambda_handler"
  runtime          = "python3.13"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.communicator_zip.output_path
  source_code_hash = data.archive_file.communicator_zip.output_base64sha256

  environment {
    variables = {
      WEBHOOK_MAP_BUCKET = var.config_s3_bucket
      WEBHOOK_MAP_KEY    = "config/table_account_name.json"
    }
  }
}

# Link SQS to the Communicator Lambda
resource "aws_lambda_event_source_mapping" "sqs_to_communicator" {
  event_source_arn = aws_sqs_queue.remediation_queue.arn
  function_name    = aws_lambda_function.communicator_lambda.arn
  batch_size       = 10
}

# ==============================================================================
# 5. EVENTBRIDGE ROUTING (CENTRAL HUB)
# ==============================================================================

resource "aws_cloudwatch_event_bus_policy" "allow_org_events" {
  event_bus_name = "default"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOrganizationToPutEvents"
        Effect    = "Allow"
        Principal = "*"
        Action    = "events:PutEvents"
        Resource  = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/default"
        Condition = {
          StringEquals = { "aws:PrincipalOrgID" = data.aws_organizations_organization.current.id }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "catch_s3_logging_events" {
  name           = "CatchS3PutBucketLogging"
  description    = "Catches forwarded s3:PutBucketLogging events from workload accounts"
  event_bus_name = "default"

  event_pattern = jsonencode({
    "source" : ["aws.s3"],
    "detail-type" : ["AWS API Call via CloudTrail"],
    "detail" : {
      "eventSource" : ["s3.amazonaws.com"],
      "eventName" : ["PutBucketLogging"]
    }
  })
}

# Target is now the REMEDIATOR Lambda, not the single combined Lambda
resource "aws_cloudwatch_event_target" "trigger_remediator" {
  rule           = aws_cloudwatch_event_rule.catch_s3_logging_events.name
  event_bus_name = "default"
  arn            = aws_lambda_function.remediator_lambda.arn
}

resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediator_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.catch_s3_logging_events.arn
}
