variable "cost_savings_s3_bucket" {
  description = "The name of the S3 bucket where cost savings reports will be stored. The bucket name must be globally unique and follow AWS S3 naming conventions."
  type        = string
}

variable "aws_region" {
  description = "The AWS region where the resources will be deployed."
  type        = string
}

variable "management_cost_export_bucket" {
  description = "The name of the S3 bucket in the Management (Root) account where AWS BCM Cost Optimization Hub exports are stored. This module requires cross-account read access to this bucket."
  type        = string
}
