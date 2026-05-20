resource "aws_keyspaces_keyspace" "main" {
  name = "${var.environment}_keyspace"

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "${var.environment}_keyspace"
    }
  )
}

resource "aws_keyspaces_table" "chat_messages" {
  keyspace_name = aws_keyspaces_keyspace.main.name
  table_name    = "chat_messages"

  schema_definition {
    column {
      name = "user_id"
      type = "text"
    }
    
    column {
      name = "timestamp"
      type = "timestamp"
    }
    
    column {
      name = "message"
      type = "text"
    }
    
    column {
      name = "room_id"
      type = "text"
    }

    partition_key {
      name = "user_id"
    }

    clustering_key {
      name     = "timestamp"
      order_by = "DESC"
    }
  }

  point_in_time_recovery {
    status = "ENABLED"
  }

  capacity_specification {
    throughput_mode = "PAY_PER_REQUEST"
  }

  encryption_specification {
    type = "AWS_OWNED_KMS_KEY"
  }

  ttl {
    status = "ENABLED"
  }

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "chat_messages"
    }
  )
}

resource "aws_keyspaces_table" "user_sessions" {
  keyspace_name = aws_keyspaces_keyspace.main.name
  table_name    = "user_sessions"

  schema_definition {
    column {
      name = "session_id"
      type = "text"
    }
    
    column {
      name = "user_id"
      type = "text"
    }
    
    column {
      name = "created_at"
      type = "timestamp"
    }
    
    column {
      name = "last_active"
      type = "timestamp"
    }

    partition_key {
      name = "session_id"
    }
  }

  point_in_time_recovery {
    status = "ENABLED"
  }

  capacity_specification {
    throughput_mode = "PAY_PER_REQUEST"
  }

  encryption_specification {
    type = "AWS_OWNED_KMS_KEY"
  }

  ttl {
    status = "ENABLED"
  }

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "user_sessions"
    }
  )
}
