# AWS EKS Production Deployment

Complete production-ready AWS EKS deployment with auto-scaling, monitoring, and managed services.

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Setup](#detailed-setup)
- [Auto-Scaling](#auto-scaling)
- [Monitoring](#monitoring)
- [Cost Estimation](#cost-estimation)
- [Troubleshooting](#troubleshooting)

## 🏗️ Architecture Overview

This deployment includes:

- **Amazon EKS**: Managed Kubernetes cluster (v1.28)
- **Amazon ECR**: Container registry for Docker images
- **Amazon MSK**: Managed Kafka for event streaming
- **Amazon Keyspaces**: Managed Cassandra-compatible database
- **Application Load Balancer**: Traffic distribution
- **Auto-Scaling**: 3-tier scaling (HPA, Cluster Autoscaler, KEDA)
- **CloudWatch**: Centralized logging and monitoring
- **AWS Secrets Manager**: Secure credential management

### Component Architecture

```
Internet → ALB → Gateway → Backend Services
                    ↓
                  Kafka (MSK)
                    ↓
                  Backend → Cassandra (Keyspaces)
```

## ✨ Features

### High Availability
- Multi-AZ deployment across 3 availability zones
- Minimum 2 replicas per service with Pod Disruption Budgets
- Health checks and automatic pod recovery

### Auto-Scaling
- **Pod-level**: HPA scales based on CPU, memory, and custom metrics
- **Node-level**: Cluster Autoscaler adds/removes EC2 instances
- **Event-driven**: KEDA scales based on Kafka lag, SQS, CloudWatch

### Security
- Private subnets for application workloads
- Secrets stored in AWS Secrets Manager
- Encryption at rest (EBS, S3, MSK, Keyspaces)
- Encryption in transit (TLS everywhere)
- IAM roles for service accounts (IRSA)

### Monitoring & Logging
- CloudWatch Container Insights for metrics
- Centralized logging with Fluent Bit
- Prometheus metrics from all services
- CloudWatch alarms for critical thresholds

## 📦 Prerequisites

### Required Tools
- AWS CLI v2
- kubectl v1.28+
- Terraform v1.5+
- Helm v3.x
- Docker
- jq

### AWS Permissions
- EKS full access
- EC2 full access
- VPC management
- IAM role creation
- MSK, Keyspaces, ECR access

### Installation Commands

```bash
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Terraform
wget https://releases.hashicorp.com/terraform/1.5.0/terraform_1.5.0_linux_amd64.zip
unzip terraform_1.5.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## 🚀 Quick Start

### 1. Clone and Configure

```bash
git clone <your-repo>
cd eks-deployment

# Configure AWS credentials
aws configure

# Update variables
vi terraform/variables.tf
```

### 2. Deploy Everything

```bash
# Run the complete deployment script
./scripts/deploy.sh
```

This script will:
1. Deploy all infrastructure (15-20 minutes)
2. Configure kubectl
3. Install add-ons (ALB Controller, Metrics Server)
4. Create secrets and configmaps
5. Deploy applications
6. Configure auto-scaling

### 3. Build and Push Images

```bash
# Get your ECR registry URL
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com"

# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY

# Build and push images
docker build -t $ECR_REGISTRY/frontend:latest ./frontend
docker push $ECR_REGISTRY/frontend:latest

docker build -t $ECR_REGISTRY/gateway:latest ./gateway
docker push $ECR_REGISTRY/gateway:latest

docker build -t $ECR_REGISTRY/bm-chat:latest ./bm-chat
docker push $ECR_REGISTRY/bm-chat:latest

docker build -t $ECR_REGISTRY/backend:latest ./backend
docker push $ECR_REGISTRY/backend:latest
```

### 4. Verify Deployment

```bash
# Check all pods are running
kubectl get pods -n production

# Check services
kubectl get svc -n production

# Check HPA status
kubectl get hpa -n production

# Get application URL
kubectl get ingress application-ingress -n production
```

## 📚 Detailed Setup

### Step 1: Infrastructure Deployment

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

**What gets created:**
- VPC with public/private subnets
- EKS cluster with 2 node groups
- MSK Kafka cluster (3 brokers)
- Keyspaces tables
- ECR repositories
- Security groups
- IAM roles

**Time:** ~15-20 minutes

### Step 2: Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name production-eks-cluster
kubectl get nodes
```

### Step 3: Install Add-ons

```bash
# AWS Load Balancer Controller
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"

helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=production-eks-cluster

# Metrics Server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# CloudWatch Container Insights
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluentd-quickstart.yaml
```

### Step 4: Create Secrets

```bash
# Secrets are automatically pulled from AWS Secrets Manager
kubectl create namespace production

# Database secrets
DB_SECRET=$(aws secretsmanager get-secret-value --secret-id production-eks-cluster/database-credentials --query SecretString --output text)

kubectl create secret generic database-secrets \
  --from-literal=cassandra-endpoint=$(echo $DB_SECRET | jq -r '.cassandra_endpoint') \
  --from-literal=cassandra-username=$(echo $DB_SECRET | jq -r '.username') \
  --from-literal=cassandra-password=$(echo $DB_SECRET | jq -r '.password') \
  -n production
```

### Step 5: Deploy Applications

```bash
# Update image URLs in manifests
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
find k8s/manifests -name "*.yaml" -exec sed -i "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" {} \;
find k8s/manifests -name "*.yaml" -exec sed -i "s|<REGION>|us-east-1|g" {} \;

# Deploy
kubectl apply -f k8s/manifests/
kubectl apply -f k8s/autoscaling/

# Watch deployment
kubectl get pods -n production -w
```

## 📈 Auto-Scaling

### How It Works

**3-Tier Scaling Architecture:**

1. **Pod-Level (HPA)** - Scales in seconds
   - Frontend: 3-20 pods based on CPU/Memory
   - Gateway: 3-30 pods based on CPU/Memory/Request rate
   - BM Chat: 3-25 pods based on WebSocket connections
   - Backend: 5-50 pods based on Kafka lag

2. **Node-Level (Cluster Autoscaler)** - Scales in 2-5 minutes
   - Application nodes: 3-10 (t3.xlarge)
   - System nodes: 2-4 (t3.large SPOT)

3. **Event-Driven (KEDA)** - Scales based on external metrics
   - Kafka consumer lag
   - SQS queue depth
   - CloudWatch custom metrics

### Scaling Examples

**Traffic Spike Example:**
```
Normal: 3 gateway pods, 3 nodes
↓
Traffic increases 10x
↓
HPA scales: 3 → 6 → 12 → 18 pods (in 90 seconds)
↓
Pods pending (not enough resources)
↓
Cluster Autoscaler: 3 → 7 nodes (in 3-4 minutes)
↓
All pods running, handling 10x traffic
```

**Kafka Backlog Example:**
```
Normal: 5 backend pods, lag = 100 messages
↓
Event burst: 50,000 messages arrive
↓
KEDA detects: lag > 1,000
↓
Scales: 5 → 10 → 20 → 40 → 50 pods (in 80 seconds)
↓
Processes backlog in 5 minutes
↓
Scales down gradually: 50 → 20 → 10 → 5 (over 20 minutes)
```

### Monitor Scaling

```bash
# Watch HPA
kubectl get hpa -n production -w

# Describe HPA
kubectl describe hpa backend-hpa -n production

# Cluster Autoscaler logs
kubectl logs -f deployment/cluster-autoscaler -n kube-system

# View scaling events
kubectl get events -n production --sort-by='.lastTimestamp' | grep -i scale
```

## 📊 Monitoring

### CloudWatch Dashboards

1. **Container Insights Dashboard**
   - Pod CPU/Memory usage
   - Node utilization
   - Network I/O

2. **Application Metrics**
   - Request rate
   - Error rate
   - Latency (p50, p95, p99)

3. **Auto-Scaling Dashboard**
   - Pod count over time
   - Node count over time
   - Scaling events

### Key Metrics

```bash
# View pod resource usage
kubectl top pods -n production

# View node resource usage
kubectl top nodes

# Application logs
kubectl logs -f deployment/gateway -n production
kubectl logs -f deployment/backend -n production --tail=100
```

### Alarms

- High CPU (> 80% for 10 minutes)
- High Memory (> 85% for 10 minutes)
- Pod crash loops (> 5 restarts)
- Kafka lag (> 10,000 messages)
- Node count low (< 3 nodes)

## 💰 Cost Estimation

### Monthly Costs (us-east-1)

**Baseline (Low Traffic):**
- EKS Control Plane: $73
- 3x t3.xlarge nodes: ~$365
- 2x t3.large SPOT: ~$49
- MSK (3 brokers): ~$550
- Keyspaces (pay-per-request): ~$50-200
- ALB: ~$23
- Data transfer: ~$50
- **Total: ~$1,160-1,310/month**

**Peak (High Traffic - 10 nodes):**
- EKS Control Plane: $73
- 10x t3.xlarge nodes: ~$1,215
- 4x t3.large SPOT: ~$97
- MSK: ~$550
- Keyspaces: ~$500-1,000
- ALB: ~$23
- Data transfer: ~$200
- **Total: ~$2,658-3,158/month**

### Cost Optimization

1. **Savings Plans**: 30-60% savings with 1-3 year commitment
2. **Spot Instances**: Already using SPOT for system nodes (70% savings)
3. **Right-sizing**: Monitor and adjust instance types
4. **Auto-scaling**: Only pay for what you use
5. **Reserved Capacity**: For predictable MSK/Keyspaces usage

## 🔧 Troubleshooting

### Pods Not Starting

```bash
# Describe pod
kubectl describe pod <pod-name> -n production

# Check logs
kubectl logs <pod-name> -n production

# Check events
kubectl get events -n production --sort-by='.lastTimestamp'

# Common issues:
# - Image pull errors: Check ECR permissions
# - Resource limits: Increase requests/limits
# - Config errors: Check secrets/configmaps
```

### Scaling Issues

```bash
# HPA not working
kubectl describe hpa <hpa-name> -n production
# Check: Metrics server installed? Resource requests set?

# Nodes not scaling
kubectl logs deployment/cluster-autoscaler -n kube-system
# Check: IAM permissions? ASG tags? Max capacity?

# Slow scale-down
# This is intentional! Check stabilization windows in HPA
```

### Database Connection Issues

```bash
# Test Keyspaces connection
kubectl run -it --rm debug --image=cassandra:latest --restart=Never -- \
  cqlsh cassandra.us-east-1.amazonaws.com 9142 --ssl

# Check secrets
kubectl get secret database-secrets -n production -o yaml
```

### Kafka Issues

```bash
# Check MSK brokers
aws kafka list-clusters
aws kafka describe-cluster --cluster-arn <arn>

# Test connectivity
kubectl run kafka-test --image=confluentinc/cp-kafka:latest -it --rm -- bash
kafka-topics --list --bootstrap-server <msk-endpoint>
```

### Network Issues

```bash
# Check ingress
kubectl describe ingress application-ingress -n production

# Check ALB
aws elbv2 describe-load-balancers
aws elbv2 describe-target-health --target-group-arn <arn>

# Test service connectivity
kubectl exec -it <pod-name> -n production -- curl http://gateway:8080/health
```

## 📖 Additional Documentation

- [Auto-Scaling Deep Dive](docs/AUTOSCALING.md)
- [Monitoring Guide](docs/MONITORING.md)
- [Disaster Recovery](docs/DISASTER_RECOVERY.md)
- [Security Best Practices](docs/SECURITY.md)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📝 License

MIT License - see LICENSE file for details

## 📞 Support

For issues and questions:
- Check [Troubleshooting](#troubleshooting) section
- Review CloudWatch logs
- Contact DevOps team

---
This is my K8S demo Repo


**Built with ❤️ by DevOps Team**
