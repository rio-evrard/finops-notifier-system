module "remediation_notifier" {
  source           = "../modules/remediation-notifier"
  count            = var.enable_remediation_notifier ? 1 : 0
  config_s3_bucket = "automation-cost-savings-${var.environment}"
}

variable "enable_remediation_notifier" {
  default = true  
}

module "cost_savings_notifier" {
  source                 = "../modules/cost-savings-notifier"
  count                  = var.enable_cost_savings_notifier ? 1 : 0
  cost_savings_s3_bucket = "automation-cost-savings-${var.environment}"
  aws_region             = var.aws_region
}

variable "enable_cost_savings_notifier" {
  default = true
}