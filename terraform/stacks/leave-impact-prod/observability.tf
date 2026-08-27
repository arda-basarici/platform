# Spend guardrails. The budget was created by hand during the aws-bootstrap probe
# (2026-08-22) and adopted here, so Terraform owns its thresholds from now on.
# $30 is the alarm ceiling, not a target; the 25 % forecast alert is the early
# warning that a resource was left running.
import {
  to = aws_budgets_budget.monthly
  id = "445743457479:leave-impact-monthly"
}

resource "aws_budgets_budget" "monthly" {
  name         = "leave-impact-monthly"
  budget_type  = "COST"
  limit_amount = "30.0"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = {
      forecast_25 = { type = "FORECASTED", threshold = 25 }
      actual_50   = { type = "ACTUAL", threshold = 50 }
      actual_80   = { type = "ACTUAL", threshold = 80 }
      actual_100  = { type = "ACTUAL", threshold = 100 }
    }
    content {
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      comparison_operator        = "GREATER_THAN"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
