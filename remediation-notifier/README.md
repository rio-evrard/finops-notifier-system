# Event Remediation Notifier

## Overview

This module provisions the central "Hub" infrastructure for AWS event-driven auto-remediations. It listens for cross-account AWS CloudTrail events via Amazon EventBridge, evaluates the state, instantly executes cross-account remediations, and safely buffers notifications to Microsoft Teams via SQS to ensure fault tolerance.

**Current Primary Use Case:** S3 Server Access Logging Guardrail. It detects when an S3 bucket is configured to log to itself, immediately disables the logging to prevent an infinite loop (and associated cost spikes), and notifies the resource owner.

## Architecture

This solution utilizes a decoupled, Hub-and-Spoke architecture leveraging Amazon EventBridge and SQS:

1. **Detection (Spoke):** A workload account modifies an S3 bucket logging configuration. CloudTrail logs the `PutBucketLogging` event. A local EventBridge rule forwards this to the central Automation account bus.
2. **Evaluation & Remediation (Lambda 1 - The Remediator):** The central EventBridge bus triggers the `S3-Remediator` Lambda. It analyzes the event payload. If the `TargetBucket` matches the `bucketName`, the Lambda instantly assumes the `WorkloadEventRemediationRole` in the spoke account, disables the bucket logging, drops a success message into an SQS Queue, and exits.
3. **Decoupled Buffer (SQS):** The `remediation-notifications-queue` safely buffers the remediation events, protecting the core remediation logic from external API failures or rate limits.
4. **Notification (Lambda 2 - The Communicator):** Triggered by the SQS queue, the `Remediation-Communicator` Lambda retrieves the webhook mapping file from S3, resolves the account name via AWS Organizations, and sends a Microsoft Teams Adaptive Card to the responsible team.

## Prerequisites & Spoke Dependencies

For this central module to function, all Workload (Spoke) accounts must have the following resources provisioned (typically via the AWS Vending Machine / Baseline):

- **EventBridge Forwarding Rule:** An EventBridge rule targeting the central event bus (`arn:aws:events:<region>:<automation_account_id>:event-bus/default`).
- **Cross-Account IAM Role:** An IAM role named `WorkloadEventRemediationRole` that trusts the `S3RemediatorRole` (created by this module) and grants necessary remediation permissions (e.g., `s3:PutBucketLogging`).

## Usage

```hcl
module "remediation_notifier" {
  source           = "../modules/remediation-notifier"
  count            = var.enable_remediation_notifier ? 1 : 0

  # The S3 bucket where the Teams webhook mapping file is stored
  config_s3_bucket = "automation-cost-savings-${var.environment}"
}
```

### Inputs

| Name               | Description                                                                         | Type     | Default | Required |
| ------------------ | ----------------------------------------------------------------------------------- | -------- | ------- | -------- |
| `config_s3_bucket` | The name of the S3 bucket storing the `table_account_name.json` configuration file. | `string` | n/a     | **Yes**  |

## Configuration: Webhook Mapping

The Communicator Lambda relies on a JSON file (`config/table_account_name.json`) stored in the `config_s3_bucket` to route Microsoft Teams notifications. This file is synced via GitHub Actions.

**Format:**

```json
[
  {
    "key_contact": "owner.team@company.com",
    "account_name": "project-alpha",
    "webhook": "https://company.webhook.office.com/webhookb2/..."
  },
  {
    "account_name": "default",
    "webhook": "https://company.webhook.office.com/webhookb2/..."
  }
]
```

> **Note:** If an account name is not found in the file, the Lambda will attempt to fall back to the `default` key. If neither exists, the remediation still executes (as it is handled upstream), but the notification is skipped.

## Current Guardrails

### 1. S3 Server Access Logging Loop Prevention

- **Trigger:** `s3:PutBucketLogging`
- **Condition:** If the `TargetBucket` is identical to the `BucketName` (the bucket is logging to itself).
- **Action Taken:** The Remediator Lambda makes an API call to disable Server Access Logging entirely on the offending bucket. This prevents the bucket from generating infinite recursive logs and associated AWS storage/API costs.

## Observability & Troubleshooting

Both Lambda functions utilize **Structured JSON Logging**.

### 1. Tracking Remediations (The Fix)

**Log Group:** `/aws/lambda/S3-Remediator`

```sql
fields @timestamp, data.account_id, data.target_bucket, event
| filter component = "remediator_lambda"
| filter event in ["MisconfigurationDetected", "RemediationSuccessful", "PushingToSQS"]
| sort @timestamp desc
```

_Expected Sequence:_ `RawEventReceived` -> `MisconfigurationDetected` -> `AssumingRole` -> `ExecutingRemediation` -> `RemediationSuccessful` -> `PushingToSQS`. _(Note: If a user legally disabled logging, the sequence stops safely at `LoggingDisabledByAccount`)_.

### 2. Tracking Notifications (The Communication)

**Log Group:** `/aws/lambda/Remediation-Communicator`

```sql
fields @timestamp, data.bucket, data.status_code, event
| filter component = "communicator_lambda"
| filter event in ["NotificationSent", "NotificationSkipped", "NotificationFailed"]
| sort @timestamp desc
```

_Expected Sequence:_ `SQSBatchReceived` -> `LoadingWebhookMap` -> `WebhookMapLoaded` -> `NotificationSent` (or `NotificationSkipped` if no webhook mapping exists).
