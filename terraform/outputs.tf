output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster OIDC Issuer"
  value       = module.eks.cluster_oidc_issuer_url
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "ecr_repositories" {
  description = "ECR Repository URLs"
  value = {
    for repo in aws_ecr_repository.repositories : repo.name => repo.repository_url
  }
}

output "msk_bootstrap_brokers_tls" {
  description = "MSK Kafka Bootstrap Brokers (TLS)"
  value       = aws_msk_cluster.kafka.bootstrap_brokers_tls
  sensitive   = true
}

output "msk_zookeeper_connect_string" {
  description = "MSK Zookeeper Connection String"
  value       = aws_msk_cluster.kafka.zookeeper_connect_string
  sensitive   = true
}

output "keyspaces_endpoint" {
  description = "Amazon Keyspaces Endpoint"
  value       = "cassandra.${var.aws_region}.amazonaws.com:9142"
}

output "keyspace_name" {
  description = "Keyspace name"
  value       = aws_keyspaces_keyspace.main.name
}

output "cluster_autoscaler_role_arn" {
  description = "IAM Role ARN for Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "aws_load_balancer_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

output "keda_operator_role_arn" {
  description = "IAM Role ARN for KEDA Operator"
  value       = aws_iam_role.keda_operator.arn
}

output "database_secret_arn" {
  description = "ARN of database credentials secret"
  value       = aws_secretsmanager_secret.database.arn
}

output "kafka_secret_arn" {
  description = "ARN of Kafka configuration secret"
  value       = aws_secretsmanager_secret.kafka.arn
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
}
