# Enterprise FinOps & Auto-Remediation Engine

This repository contains the Infrastructure as Code (Terraform) to deploy a self-healing, enterprise-scale FinOps and security guardrail platform on AWS.

These modules implement the "Guardrails, Not Gates" philosophy by combining proactive cost-optimization analytics with real-time, event-driven remediation.

📖 **Companion Blog Post:** [Building a Self-Healing FinOps Engine at Enterprise Scale](LINK_TO_YOUR_BLOG_POST)

## 🏗️ Architecture Overview

The platform is split into two distinct, decoupled modules that share a common GitOps notification routing layer.

1. **`cost-savings-notifier` (Pattern A - The Proactive Guide):** An asynchronous pipeline using AWS BCM Data Exports, AWS Glue, Athena, and Step Functions to identify resources (like EC2/RDS) that should be migrated to AWS Graviton for cost savings.
2. **`event-remediation-notifier` (Pattern B - The Reactive Guardrail):** A high-speed, Hub-and-Spoke EventBridge architecture that detects critical financial misconfigurations (e.g., S3 infinite logging loops) in real-time, instantly severs the loop via cross-account STS, and safely buffers notifications via SQS.

## 📂 Repository Structure

```text
├── modules/
│   ├── cost-savings-notifier/      # Pattern A: Step Functions, Athena, Lambda
│   └── remediation-notifier/       # Pattern B: EventBridge, SQS, Remediator & Communicator Lambdas
└── main.tf                         # Example Root Module deployment
```

## 🔗 Shared Dependency: GitOps Routing

Both modules rely on a centralized, GitOps-managed routing table to map AWS resource owners (or AWS Account Names) to their respective Microsoft Teams webhook URLs.

This file must be uploaded to the S3 bucket referenced in the module variables (typically managed via a GitHub Actions OIDC pipeline).

**Example `table_account_name.json`:**

```json
[
  {
    "key_contact": "owner.team@company.com",
    "account_name": "project-alpha",
    "webhook": "[https://company.webhook.office.com/](https://company.webhook.office.com/)..."
  }
]
```

---

## 🚀 Module Usage

You can invoke these modules from your central Automation/Hub account. They are designed with feature toggles (`count`) to allow flexible deployments across different environments.

### 1. Cost Savings Notifier (Pattern A)

Deploys the bi-monthly batch analytics engine to notify teams of Graviton migration opportunities.

```hcl
module "cost_savings_notifier" {
  source                 = "../modules/cost-savings-notifier"
  count                  = var.enable_cost_savings_notifier ? 1 : 0

  cost_savings_s3_bucket = "automation-cost-savings-${var.environment}"
  aws_region             = var.aws_region
}
```

**Variables:**

- `enable_cost_savings_notifier` (bool): Feature toggle to deploy the module.
- `cost_savings_s3_bucket` (string): The S3 bucket where Athena query results and the routing JSON are stored.
- `aws_region` (string): The AWS region for the deployment.

### 2. Event Remediation Notifier (Pattern B)

Deploys the SQS buffer and the decoupled Remediator/Communicator Lambdas to stop active misconfigurations.

```hcl
module "remediation_notifier" {
  source           = "../modules/remediation-notifier"
  count            = var.enable_remediation_notifier ? 1 : 0

  config_s3_bucket = "automation-cost-savings-${var.environment}"
}
```

**Variables:**

- `enable_remediation_notifier` (bool): Feature toggle to deploy the module.
- `config_s3_bucket` (string): The S3 bucket where the `table_account_name.json` routing file is stored.

---

## 🔒 IAM & Cross-Account Prerequisites

- **Data Exports:** The `cost-savings-notifier` assumes that the Management (Root) account is delivering AWS BCM Cost Optimization Hub exports to a designated S3 bucket, and that this Hub account has cross-account read access to it.
- **Spoke Forwarding:** The `remediation-notifier` assumes that workload (Spoke) accounts have an EventBridge rule configured to forward `s3:PutBucketLogging` CloudTrail events to the default Event Bus of the Hub account where this module is deployed.
- **Cross-Account Remediation:** The workload (Spoke) accounts must contain an IAM Role named `WorkloadEventRemediationRole` that trusts the `S3RemediatorRole` created by this module.
