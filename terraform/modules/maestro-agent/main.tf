# =============================================================================
# Maestro Agent Module - Main Configuration
# =============================================================================

# Get current AWS account and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Secret names for Maestro Agent
locals {
  agent_cert_secret_name   = "maestro/agent-cert"
  agent_config_secret_name = "maestro/agent-config"

  common_tags = merge(
    var.tags,
    {
      Component         = "maestro-agent"
      ManagementCluster = var.cluster_id
      ManagedBy         = "terraform"
    }
  )
}

# =============================================================================
# Maestro Agent Secrets (managed by terraform, populated from IoT Mint outputs)
# =============================================================================

resource "aws_secretsmanager_secret" "maestro_agent_cert" {
  name        = local.agent_cert_secret_name
  description = "Maestro Agent MQTT certificate material for ${var.cluster_id}"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "maestro_agent_cert" {
  secret_id     = aws_secretsmanager_secret.maestro_agent_cert.id
  secret_string = var.maestro_agent_cert_json
}

resource "aws_secretsmanager_secret" "maestro_agent_config" {
  name        = local.agent_config_secret_name
  description = "Maestro Agent MQTT configuration for ${var.cluster_id}"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "maestro_agent_config" {
  secret_id     = aws_secretsmanager_secret.maestro_agent_config.id
  secret_string = var.maestro_agent_config_json
}
