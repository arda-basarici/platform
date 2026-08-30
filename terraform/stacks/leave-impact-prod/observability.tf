# Spend guardrails and the host alarms. The budget was created by hand when the account was first set
# up (2026-08-22, the agent's probe days) and adopted here, so Terraform owns its
# thresholds from now on.
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

# --- One channel for every alert ---------------------------------------------
# Every automated alert in this account lands on one SNS topic with one e-mail
# subscriber. The subscription is confirmed by a click in the recipient's mailbox
# (`PendingConfirmation` until then), which Terraform can neither do nor see —
# a deliberate out-of-band step, recorded in the README's evidence table.
resource "aws_sns_topic" "alerts" {
  name = "leave-impact-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Setting a policy replaces SNS's default one, so every publisher must be named:
# both are service principals, pinned to this account. The first version of this
# policy granted the account and not the CloudWatch service; the forced-ALARM test
# on 2026-08-30 found the alarm's publish refused — the exact silent failure the
# test exists for.
data "aws_iam_policy_document" "alerts_topic" {
  dynamic "statement" {
    for_each = {
      CloudWatchAlarms     = "cloudwatch.amazonaws.com"
      CostAnomalyDetection = "costalerts.amazonaws.com"
    }
    content {
      sid       = statement.key
      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.alerts.arn]
      principals {
        type        = "Service"
        identifiers = [statement.value]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# --- The app host's status checks -------------------------------------------
# Two checks, two responses. A *system* failure is AWS's hardware or network under
# the instance: recovery (a stop/start onto healthy hardware, same id, same EIP,
# same volumes) fixes it, and the alarm says so explicitly rather than leaning on
# the account-level default recovery. An *instance* failure is the OS itself —
# hung, out of memory, disk full — where an automatic reboot would erase the
# evidence; that one only notifies. Both key on the instance resource, so a
# replacement re-points them by itself. Two consecutive failed minutes, not one:
# a single missed check is a blip.
locals {
  status_checks = {
    system   = { metric = "StatusCheckFailed_System", actions = ["arn:aws:automate:eu-central-1:ec2:recover", aws_sns_topic.alerts.arn] }
    instance = { metric = "StatusCheckFailed_Instance", actions = [aws_sns_topic.alerts.arn] }
  }
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  for_each = local.status_checks

  alarm_name          = "leave-agent-app-${each.key}-check"
  alarm_description   = "EC2 ${each.key} status check failing on the application host"
  namespace           = "AWS/EC2"
  metric_name         = each.value.metric
  dimensions          = { InstanceId = aws_instance.app.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching" # no datapoints at all is the worst case, not a quiet one

  alarm_actions = each.value.actions
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# --- Cost anomalies --------------------------------------------------------
# AWS created this monitor and its subscription when the account was set up
# (2026-08-22, the default per-service monitor); the subscription was hand-tuned
# the same day from "$100 and 40 %" to $2 absolute and is adopted here. Delivery
# moves from the daily e-mail digest to the topic: an anomaly is mailed when it
# is found, not in the next day's summary (`IMMEDIATE` is SNS-only).
import {
  to = aws_ce_anomaly_monitor.services
  id = "arn:aws:ce::445743457479:anomalymonitor/78fc0fc5-64c4-4bd1-8721-5cb987b7e88c"
}

resource "aws_ce_anomaly_monitor" "services" {
  name              = "Default-Services-Monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

import {
  to = aws_ce_anomaly_subscription.services
  id = "arn:aws:ce::445743457479:anomalysubscription/8cf5d904-084d-4349-a7c3-b187b4b48707"
}

resource "aws_ce_anomaly_subscription" "services" {
  name             = "Default-Services-Subscription"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["2"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
}
