# Auto-Scaling Deep Dive

## Overview

This EKS cluster implements a **3-tier auto-scaling strategy** for maximum flexibility and cost efficiency.

## Architecture Layers

### Layer 1: Pod-Level Scaling (HPA)
**What**: Horizontal Pod Autoscaler scales application replicas  
**When**: Real-time response to load changes  
**Speed**: Seconds to minutes  
**Cost**: Minimal (reuses existing nodes)

### Layer 2: Node-Level Scaling (Cluster Autoscaler)
**What**: Adds/removes EC2 instances  
**When**: Pods can't be scheduled due to resource constraints  
**Speed**: 2-5 minutes (AWS instance launch time)  
**Cost**: Per-second EC2 billing

### Layer 3: Event-Driven Scaling (KEDA)
**What**: Scales based on external events  
**When**: Workload-specific triggers (Kafka lag, SQS, etc.)  
**Speed**: Seconds  
**Cost**: Minimal (reuses existing infrastructure)

## Component Scaling Behavior

### Frontend (Web Server)

**Configuration**:
- Min: 3 pods | Max: 20 pods
- Triggers: CPU > 70%, Memory > 80%

**Scale-Up Behavior**:
- Can double capacity every 30 seconds
- Adds up to 4 pods per interval
- No stabilization window (immediate response)

**Scale-Down Behavior**:
- Waits 5 minutes before starting
- Removes max 50% of pods per minute
- OR removes max 2 pods per minute
- Uses whichever is slower (more conservative)

**Example Flow**:
```
09:00 - Normal traffic: 3 pods, CPU 40%
09:15 - Traffic spike: CPU jumps to 80%
09:15:30 - HPA scales: 3 → 6 pods (doubled)
09:16:00 - CPU still 75%: 6 → 9 pods (50% increase)
09:16:30 - CPU drops to 65%: stable at 9 pods
09:30 - Traffic normalizes: CPU 30%
09:35 - Start scale-down (5 min passed): 9 → 7 pods (2 removed)
09:36 - Continue: 7 → 5 pods (2 removed)
09:37 - Continue: 5 → 3 pods (2 removed)
```

### Gateway (API Gateway)

**Configuration**:
- Min: 3 pods | Max: 30 pods
- Triggers: CPU > 65%, Memory > 75%, Requests > 1000/sec per pod

**Scale-Up Behavior**:
- Aggressive: can double every 15 seconds
- Adds up to 5 pods per interval
- Immediate response (no wait)

**Scale-Down Behavior**:
- Waits 5 minutes
- Removes max 30% per minute
- Conservative to protect traffic

**Example Flow**:
```
Traffic: 3,000 req/s across 3 pods = 1,000 req/s each (at threshold)
↓
Spike: 15,000 req/s arrives
↓
15,000 ÷ 3 = 5,000 req/s per pod (5x over threshold)
↓
00:00 - Scale: 3 → 6 pods (doubled in 15s)
00:15 - 15,000 ÷ 6 = 2,500/pod (still 2.5x over)
00:15 - Scale: 6 → 12 pods (doubled in 15s)
00:30 - 15,000 ÷ 12 = 1,250/pod (still 25% over)
00:30 - Scale: 12 → 18 pods (50% increase)
00:45 - 15,000 ÷ 18 = 833/pod (under threshold)
00:45 - Stable at 18 pods
```

### BM Chat (WebSocket Service)

**Configuration**:
- Min: 3 pods | Max: 25 pods
- Triggers: CPU > 70%, Memory > 80%, Active connections > 500 per pod

**Scale-Up Behavior**:
- Moderate: 50% increase every 30 seconds
- Adds 1-2 pods at a time
- Quick but not aggressive

**Scale-Down Behavior**:
- Very slow: waits 10 minutes (!)
- Removes only 25% per 2 minutes
- Extremely conservative for WebSocket

**Why Slow Scale-Down?**
WebSocket connections are long-lived. Aggressive scale-down would:
- Disconnect active users
- Cause chat message loss
- Degrade user experience

**Example Flow**:
```
Normal: 1,500 connections across 3 pods = 500 per pod
↓
Growth: 3,000 connections (live event starts)
↓
3,000 ÷ 3 = 1,000 per pod (2x threshold)
↓
00:00 - Scale: 3 → 5 pods (50% increase)
00:30 - 3,000 ÷ 5 = 600 per pod (still over)
00:30 - Scale: 5 → 7 pods (40% increase)
01:00 - 3,000 ÷ 7 = 428 per pod (under threshold)
01:00 - Stable
↓
Event ends: connections drop to 1,000
01:10 - Still at 7 pods (waiting 10 minutes)
01:20 - Start scale-down: 7 → 6 pods (1 removed)
01:22 - Continue: 6 → 5 pods (1 removed)
01:24 - Continue: 5 → 4 pods (1 removed)
01:26 - Continue: 4 → 3 pods (1 removed)
```

### Backend (Event Processors)

**Configuration**:
- Min: 5 pods | Max: 50 pods
- Triggers: CPU > 75%, Memory > 85%, Kafka lag > 1,000 messages

**Scale-Up Behavior**:
- Very aggressive: can double every 20 seconds
- OR adds 10 pods per interval
- Uses whichever adds more pods
- No waiting (processes backlog ASAP)

**Scale-Down Behavior**:
- Waits 5 minutes
- Removes 40% per minute
- Moderate speed

**KEDA Integration**:
Also has KEDA scaler watching Kafka lag independently

**Example Flow**:
```
Normal: 5 pods processing 5K msg/sec, lag = 100
↓
Event burst: 50K messages arrive in queue
↓
Lag jumps: 100 → 45,000 messages
↓
00:00 - KEDA triggers: lag > 1,000
00:00 - HPA scales: 5 → 10 pods (doubled)
00:20 - Lag: 40,000 (still high)
00:20 - Scale: 10 → 20 pods (doubled)
00:40 - Lag: 30,000 (still high)
00:40 - Scale: 20 → 40 pods (doubled)
01:00 - Lag: 15,000 (still high)
01:00 - Scale: 40 → 50 pods (max, +10)
01:20 - Processing at max capacity
02:00 - Lag: 800 (under threshold)
02:05 - Start scale-down: 50 → 30 pods (40% reduction)
02:06 - Continue: 30 → 18 pods (40% reduction)
02:07 - Continue: 18 → 11 pods (40% reduction)
02:08 - Continue: 11 → 7 pods (40% reduction)
02:09 - Continue: 7 → 5 pods (reaches minimum)
```

## Node-Level Scaling

### How Cluster Autoscaler Works

1. **Scale-Up Trigger**:
   - Pod in "Pending" state for > 30 seconds
   - Reason: "Insufficient CPU" or "Insufficient Memory"

2. **Scale-Up Process**:
   ```
   Pending pod detected
   ↓
   Calculate resources needed
   ↓
   Check which node group can fit
   ↓
   Request ASG to launch instance
   ↓
   Wait for instance (2-3 minutes)
   ↓
   Instance joins cluster
   ↓
   Pod scheduled and starts
   ```

3. **Scale-Down Trigger**:
   - Node utilization < 50% for > 10 minutes
   - All pods can be moved to other nodes
   - PodDisruptionBudgets allow eviction

4. **Scale-Down Process**:
   ```
   Node underutilized for 10+ minutes
   ↓
   Check: Can we move all pods?
   ↓
   Check: PDBs allow it?
   ↓
   Mark node as unschedulable
   ↓
   Gracefully drain pods (600s grace period)
   ↓
   Wait for pods to terminate
   ↓
   Terminate EC2 instance
   ↓
   Update ASG desired capacity
   ```

### Node Group Configuration

**Application Node Group**:
- Instance: t3.xlarge (4 vCPU, 16 GB RAM)
- Min: 3 nodes
- Max: 10 nodes
- Capacity Type: ON_DEMAND
- Use: All application workloads

**System Node Group**:
- Instance: t3.large (2 vCPU, 8 GB RAM)
- Min: 2 nodes
- Max: 4 nodes
- Capacity Type: SPOT (70% cheaper!)
- Use: Monitoring, logging, system pods
- Taints: Prevents application pods from scheduling here

### Safety Mechanisms

**PodDisruptionBudgets (PDBs)**:
- Frontend: Min 2 pods must be available
- Gateway: Min 2 pods must be available
- BM Chat: Min 2 pods must be available
- Backend: Min 3 pods must be available

This ensures:
- No service goes completely down during node drain
- Rolling updates don't break everything
- Scale-down doesn't cause outages

**Graceful Termination**:
- Pods get 600 seconds to shut down cleanly
- SIGTERM sent first (app can clean up)
- SIGKILL sent after timeout (force kill)
- Connections drained from load balancers

## Cost Implications

### Scaling Costs by Time

**Normal Load** (3 nodes):
```
Hourly: 3 × $0.1664 = $0.50/hour
Daily: $12/day
Monthly: ~$365/month
```

**Medium Load** (6 nodes):
```
Hourly: 6 × $0.1664 = $1.00/hour
Daily: $24/day
Monthly: ~$730/month
```

**High Load** (10 nodes):
```
Hourly: 10 × $0.1664 = $1.66/hour
Daily: $40/day
Monthly: ~$1,215/month
```

### Typical Traffic Patterns

**E-commerce Site**:
- Normal: 3 nodes (8 AM - 6 PM weekdays)
- Low: 3 nodes (nights/weekends)
- Peak: 8 nodes (lunch hour 12-2 PM)
- Cost: ~$500/month

**SaaS Application**:
- Business hours: 5 nodes (9 AM - 5 PM)
- Off hours: 3 nodes
- Weekends: 3 nodes
- Cost: ~$450/month

**Gaming Platform**:
- Peak: 10 nodes (evenings 6 PM - 11 PM)
- Normal: 5 nodes (afternoons)
- Low: 3 nodes (mornings 2 AM - 9 AM)
- Cost: ~$650/month

## Monitoring Scaling

### Real-Time Monitoring

```bash
# Watch HPA status
kubectl get hpa -n production -w

# Watch pod count
watch -n 2 'kubectl get pods -n production | grep -E "frontend|gateway|bm-chat|backend"'

# Watch node count
watch -n 5 'kubectl get nodes'

# Cluster Autoscaler logs
kubectl logs -f deployment/cluster-autoscaler -n kube-system | grep -i "scale"
```

### Historical Analysis

```bash
# View scaling events (last 1 hour)
kubectl get events -n production --sort-by='.lastTimestamp' | grep -i scale | tail -20

# HPA decisions
kubectl describe hpa backend-hpa -n production

# Node scaling decisions
kubectl logs deployment/cluster-autoscaler -n kube-system --tail=100 | grep "ScaleUp\|ScaleDown"
```

### Metrics to Track

**Pod-Level**:
- Current replicas vs desired
- CPU/Memory utilization %
- Custom metric values (requests/sec, connections, lag)

**Node-Level**:
- Node count
- Total cluster CPU/Memory usage
- Pending pods count
- Unschedulable events

**Application**:
- Request latency (p50, p95, p99)
- Error rate
- Throughput

## Tuning Recommendations

### When to Adjust Scale-Up Speed

**Make it faster** (more aggressive):
- Latency-sensitive applications
- User-facing services
- Cost is less important than performance

**Make it slower** (more conservative):
- Batch processing
- Background jobs
- Cost optimization is priority

### When to Adjust Scale-Down Speed

**Make it faster**:
- Highly variable traffic
- Cost optimization critical
- Pods start quickly (< 30 seconds)

**Make it slower**:
- Long-lived connections (WebSocket, gRPC streams)
- Slow pod startup (> 2 minutes)
- Data loss risk during shutdown

### Tuning HPA

```yaml
# More aggressive scale-up
scaleUp:
  stabilizationWindowSeconds: 0  # No waiting
  policies:
  - type: Percent
    value: 200  # Triple capacity
    periodSeconds: 15  # Every 15 seconds

# More conservative scale-down
scaleDown:
  stabilizationWindowSeconds: 600  # Wait 10 minutes
  policies:
  - type: Percent
    value: 10  # Only 10% at a time
    periodSeconds: 120  # Every 2 minutes
```

## Testing Auto-Scaling

### Load Test Frontend

```bash
# Install hey (HTTP load generator)
go install github.com/rakyll/hey@latest

# Light load
hey -z 2m -c 50 http://<alb-url>

# Medium load (should trigger scale-up)
hey -z 5m -c 200 -q 50 http://<alb-url>

# Heavy load (should scale to max)
hey -z 10m -c 500 -q 100 http://<alb-url>

# Watch scaling
watch -n 2 'kubectl get hpa frontend-hpa -n production'
```

### Simulate Kafka Backlog

```bash
# Produce many messages
kubectl run kafka-producer --image=confluentinc/cp-kafka:latest -it --rm -- bash

# Inside the pod:
for i in {1..50000}; do 
  echo "message $i" | kafka-console-producer \
    --topic backend-events \
    --bootstrap-server <msk-endpoint>
done

# Watch backend scale
watch -n 2 'kubectl get hpa backend-hpa -n production'
```

### Force Node Scaling

```bash
# Create resource-heavy pods
kubectl run stress-test --image=polinux/stress --replicas=20 -- \
  stress --cpu 2 --timeout 600

# Watch nodes scale up
watch -n 5 'kubectl get nodes'

# View autoscaler logs
kubectl logs -f deployment/cluster-autoscaler -n kube-system
```

## Troubleshooting

### HPA Not Scaling

**Issue**: HPA shows "unknown" for metrics
```bash
kubectl describe hpa <name> -n production
```

**Causes**:
1. Metrics server not installed
2. Resource requests not set in deployment
3. Metrics not available yet (wait 30 seconds)

**Fix**:
```bash
# Install metrics server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify resource requests in deployment
kubectl get deployment <name> -n production -o yaml | grep -A 5 resources
```

### Cluster Autoscaler Not Working

**Issue**: Pods stuck in "Pending" but nodes not scaling

**Check logs**:
```bash
kubectl logs deployment/cluster-autoscaler -n kube-system --tail=50
```

**Common issues**:
1. IAM permissions missing
2. ASG not tagged correctly
3. Max capacity reached
4. Instance type unavailable in AZ

**Verify tags**:
```bash
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?Tags[?Key=='k8s.io/cluster-autoscaler/enabled']]"
```

### Slow Scale-Down

**Issue**: Pods not scaling down after load decreases

**This is often intentional!** Check:
1. Stabilization window (5-10 minutes)
2. PodDisruptionBudgets might block
3. Scale-down policy is conservative

**View HPA decision**:
```bash
kubectl describe hpa <name> -n production
# Look for "ScaleDown" events and "Conditions"
```

## Best Practices

1. **Set Resource Requests/Limits**: Required for HPA
2. **Use PodDisruptionBudgets**: Prevent cascading failures
3. **Monitor Scaling Metrics**: Use CloudWatch/Grafana
4. **Test Scaling Regularly**: Run load tests monthly
5. **Tune for Your Workload**: One size doesn't fit all
6. **Cost Alerts**: Set up billing alarms
7. **Gradual Rollout**: Test changes in staging first
8. **Document Decisions**: Record why you chose specific values

---

For more information:
- [Kubernetes HPA Documentation](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
- [KEDA Documentation](https://keda.sh/docs/)
