# Cost Savings Notifier Module

## Overview

This module provisions a fully automated, serverless pipeline that proactively identifies AWS cost-saving opportunities (such as migrating to Graviton processors or rightsizing instances) and notifies the respective resource owners via Microsoft Teams.

The system leverages AWS Cost Optimization Hub, AWS Step Functions, Amazon Athena, and AWS Lambda to process organizational billing data. To adhere to AWS Organizations data boundary limitations, this module reads organizational recommendation data cross-account from a central Management (Root) account S3 bucket, processing the results locally within the Automation account.

## Architectural Context: The Delegated Administrator Limitation

While AWS allows a member account (such as this Automation account) to be designated as a Delegated Administrator to _view_ Cost Optimization Hub data across the entire organization in the console, **AWS BCM Data Exports does not inherit this org-wide scope for member accounts**.

AWS restricts the extraction of organization-wide billing and cost management data strictly to the Management (Root) account. If a Delegated Administrator creates a Data Export, it will only generate files containing data for that specific member account.

**Architectural Impact:** To programmatically process org-wide recommendations, the infrastructure must be split. The Management account handles the actual Data Export generation and initial S3 storage, while this Terraform module (deployed in the Automation account) uses cross-account IAM permissions to crawl, catalog, query, and notify on that data.

## Architecture & Data Flow

1. **Configuration Sync (CI/CD):** A GitHub Actions workflow pushes a mapping of owner emails to MS Teams Webhook URLs (`table_account_name.json`) to the local Automation S3 bucket using an OIDC assumed role.
2. **Data Ingestion (Management Account):** The AWS Management account automatically exports organizational Cost Optimization Hub recommendations into its own centralized S3 bucket (set via `var.management_cost_export_bucket`) via AWS BCM Data Exports using daily partitions.
3. **Data Cataloging (Cross-Account):** An AWS Glue Crawler runs daily in the Automation account, scanning the partitioned Parquet files directly from the Management account's S3 bucket. It updates the `data` table inside the local `cost_optimization_reports` Glue database.
4. **Compute & Notification (Step Functions & Lambda):** An Amazon EventBridge Scheduler triggers the **CostSavingsOrchestrator** Step Function on a bi-monthly schedule.
   - The Step Function executes an Amazon Athena SQL query via a dedicated workgroup (`cost_optimization_wg`) and natively waits for it to succeed without consuming active compute time.
   - The Step Function passes the successful `QueryExecutionId` to the `CostSavingsNotifier` Lambda function.
   - The Lambda retrieves the results, mapping the dynamically extracted recommended instance types (e.g., `c6g.large`) to the respective `owner` tag.
   - Findings are mapped to the webhook JSON config and dispatched as rich Adaptive Cards to Microsoft Teams.

## Prerequisites

Before deploying this module, the following account-level configurations and external dependencies must be in place:

1. **Management Account Data Export:** An AWS BCM Data Export for the Cost Optimization Hub must be configured in the AWS Organization's Management (Root) account. The export must output to an S3 bucket (set via `var.management_cost_export_bucket`), and that bucket's policy must grant `s3:GetObject` and `s3:ListBucket` permissions to the Glue Crawler and Step Function IAM roles created by this module.
2. **Cost Allocation Tags:** The `owner` tag must be activated as a Cost Allocation Tag in the Billing Console of the Management account. _(Note: It takes up to 24 hours for newly activated tags to appear in data exports)._
3. **GitHub OIDC Provider:** An IAM OIDC identity provider for `token.actions.githubusercontent.com` must exist in the target automation account to allow the CI/CD pipeline to push the webhook mapping file.

## Observability & Troubleshooting

The Lambda function utilizes **Structured JSON Logging**. All operational events, errors, and notification dispatch statuses can be queried natively using CloudWatch Logs Insights.

**Log Group:** `/aws/lambda/CostSavingsNotifier`

**Common CloudWatch Insights Query:**

```sql
fields @timestamp, event, data.owner_email, data.total_savings, data.error
| filter component = "cost_savings_notifier"
| sort @timestamp desc
```

### Expected Log Sequence

1. `GravitonNotifierExecutionStarted`
2. `LoadingWebhookMap` -> `WebhookMapLoaded`
3. `FetchingAthenaResults` (Using the Execution ID passed by the Step Function)
4. `ResultsProcessed` (Includes a count of unique owners found)
5. `NotificationSent` (Iterates per owner, recording resource counts and HTTP status codes)

- _Alternative:_ `OwnerNotInWebhookMap` (Emitted as a WARNING if an owner tag is found but no webhook URL exists in the JSON config).

6. `GravitonNotifierExecutionFinished`
