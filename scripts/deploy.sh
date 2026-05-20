#!/bin/bash
set -e

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-production-eks-cluster}"
NAMESPACE="${NAMESPACE:-production}"

echo "========================================"
echo "EKS Deployment Script"
echo "========================================"
echo "AWS Region: $AWS_REGION"
echo "Cluster Name: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
echo "========================================"

# Step 1: Deploy Infrastructure with Terraform
echo ""
echo "Step 1: Deploying AWS Infrastructure with Terraform..."
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Get Terraform outputs
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
MSK_BROKERS=$(terraform output -raw msk_bootstrap_brokers_tls)
CASSANDRA_ENDPOINT=$(terraform output -raw keyspaces_endpoint)
KEYSPACE_NAME=$(terraform output -raw keyspace_name)
CLUSTER_AUTOSCALER_ROLE=$(terraform output -raw cluster_autoscaler_role_arn)
ALB_CONTROLLER_ROLE=$(terraform output -raw aws_load_balancer_controller_role_arn)

cd ..

echo "✓ Infrastructure deployed successfully"

# Step 2: Configure kubectl
echo ""
echo "Step 2: Configuring kubectl..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

echo "✓ kubectl configured"

# Step 3: Install AWS Load Balancer Controller
echo ""
echo "Step 3: Installing AWS Load Balancer Controller..."
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$ALB_CONTROLLER_ROLE \
  --set region=$AWS_REGION \
  --set vpcId=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text)

echo "✓ AWS Load Balancer Controller installed"

# Step 4: Install Metrics Server
echo ""
echo "Step 4: Installing Metrics Server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

echo "✓ Metrics Server installed"

# Step 5: Install CloudWatch Container Insights
echo ""
echo "Step 5: Installing CloudWatch Container Insights..."
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluentd-quickstart.yaml

echo "✓ CloudWatch Container Insights installed"

# Step 6: Create namespace
echo ""
echo "Step 6: Creating namespace..."
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Namespace created"

# Step 7: Create secrets from AWS Secrets Manager
echo ""
echo "Step 7: Creating secrets..."
DB_SECRET=$(aws secretsmanager get-secret-value --secret-id $CLUSTER_NAME/database-credentials --query SecretString --output text)

kubectl create secret generic database-secrets \
  --from-literal=cassandra-endpoint=$(echo $DB_SECRET | jq -r '.cassandra_endpoint') \
  --from-literal=cassandra-username=$(echo $DB_SECRET | jq -r '.username') \
  --from-literal=cassandra-password=$(echo $DB_SECRET | jq -r '.password') \
  --from-literal=keyspace=$(echo $DB_SECRET | jq -r '.keyspace') \
  -n $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Secrets created"

# Step 8: Create ConfigMaps
echo ""
echo "Step 8: Creating ConfigMaps..."
kubectl create configmap kafka-config \
  --from-literal=brokers="$MSK_BROKERS" \
  -n $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✓ ConfigMaps created"

# Step 9: Update deployment YAMLs
echo ""
echo "Step 9: Updating deployment manifests..."
find k8s/manifests -name "*.yaml" -exec sed -i "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" {} \;
find k8s/manifests -name "*.yaml" -exec sed -i "s|<REGION>|$AWS_REGION|g" {} \;

echo "✓ Manifests updated"

# Step 10: Deploy Cluster Autoscaler
echo ""
echo "Step 10: Deploying Cluster Autoscaler..."
sed "s|<CLUSTER_AUTOSCALER_ROLE_ARN>|$CLUSTER_AUTOSCALER_ROLE|g" k8s/autoscaling/cluster-autoscaler.yaml | kubectl apply -f -

echo "✓ Cluster Autoscaler deployed"

# Step 11: Deploy applications
echo ""
echo "Step 11: Deploying applications..."
kubectl apply -f k8s/manifests/

echo "✓ Applications deployed"

# Step 12: Deploy HPA
echo ""
echo "Step 12: Deploying Horizontal Pod Autoscalers..."
kubectl apply -f k8s/autoscaling/hpa-all.yaml

echo "✓ HPA deployed"

# Step 13: Wait for deployments
echo ""
echo "Step 13: Waiting for deployments to be ready..."
kubectl wait --for=condition=available --timeout=600s deployment/frontend -n $NAMESPACE || true
kubectl wait --for=condition=available --timeout=600s deployment/gateway -n $NAMESPACE || true
kubectl wait --for=condition=available --timeout=600s deployment/bm-chat -n $NAMESPACE || true
kubectl wait --for=condition=available --timeout=600s deployment/backend -n $NAMESPACE || true

# Step 14: Get Application URL
echo ""
echo "Step 14: Getting Application URL..."
sleep 30
ALB_URL=$(kubectl get ingress application-ingress -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "Not ready yet")

echo ""
echo "========================================"
echo "Deployment Complete!"
echo "========================================"
echo "Application URL: http://$ALB_URL"
echo ""
echo "Useful commands:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl get svc -n $NAMESPACE"
echo "  kubectl get hpa -n $NAMESPACE"
echo "  kubectl logs -f deployment/gateway -n $NAMESPACE"
echo ""
