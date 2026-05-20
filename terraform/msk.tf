resource "aws_msk_cluster" "kafka" {
  cluster_name           = "${var.cluster_name}-kafka"
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.kafka_broker_count

  broker_node_group_info {
    instance_type  = var.kafka_instance_type
    client_subnets = module.vpc.private_subnets
    
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 100
        
        provisioned_throughput {
          enabled           = true
          volume_throughput = 250
        }
      }
    }
    
    connectivity_info {
      public_access {
        type = "DISABLED"
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
    
    encryption_at_rest_kms_key_arn = aws_kms_key.msk.arn
  }

  configuration_info {
    arn      = aws_msk_configuration.kafka.arn
    revision = aws_msk_configuration.kafka.latest_revision
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
      
      s3 {
        enabled = true
        bucket  = aws_s3_bucket.msk_logs.id
        prefix  = "msk-logs/"
      }
    }
  }

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "${var.cluster_name}-kafka"
    }
  )
}

resource "aws_msk_configuration" "kafka" {
  name              = "${var.cluster_name}-config"
  kafka_versions    = [var.kafka_version]
  
  server_properties = <<PROPERTIES
auto.create.topics.enable=true
delete.topic.enable=true
log.retention.hours=168
default.replication.factor=3
min.insync.replicas=2
num.partitions=3
compression.type=snappy
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
PROPERTIES
}

resource "aws_security_group" "msk" {
  name_prefix = "${var.cluster_name}-msk-"
  description = "Security group for MSK cluster"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Kafka plaintext"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  ingress {
    description = "Kafka TLS"
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
  
  ingress {
    description = "Zookeeper"
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "${var.cluster_name}-msk-sg"
    }
  )
}

resource "aws_kms_key" "msk" {
  description             = "KMS key for MSK encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "${var.cluster_name}-msk-kms"
    }
  )
}

resource "aws_kms_alias" "msk" {
  name          = "alias/${var.cluster_name}-msk"
  target_key_id = aws_kms_key.msk.key_id
}

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${var.cluster_name}"
  retention_in_days = 7

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "/aws/msk/${var.cluster_name}"
    }
  )
}

resource "aws_s3_bucket" "msk_logs" {
  bucket = "${var.cluster_name}-msk-logs-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "${var.cluster_name}-msk-logs"
    }
  )
}

resource "aws_s3_bucket_versioning" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "msk_logs" {
  bucket = aws_s3_bucket.msk_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_caller_identity" "current" {}
