# Hubble CLI Master Guide

## Quick Reference

### Essential Commands

```bash
# Configuration
hubble config view
hubble status
hubble list nodes

# Basic observation
hubble observe
hubble observe --namespace <ns>
hubble observe --last 10
hubble observe --follow

# Filtering
hubble observe --from-pod <ns>/<pod>
hubble observe --to-service <ns>/<svc>
hubble observe --protocol http
hubble observe --verdict DROPPED

# Layer 7
hubble observe --protocol dns
hubble observe --protocol http --http-method GET
hubble observe --http-path /api/*

# Export
hubble observe --output json > flows.json
hubble observe --input-file flows.json
```

## Complete Command Reference

### Selection Flags

| Flag | Description | Example |
|------|-------------|---------|
| `--all` | Show all flows in buffer | `hubble observe --all` |
| `--last N` | Show last N flows | `hubble observe --last 100` |
| `--first N` | Show first N flows | `hubble observe --first 50` |
| `--follow` / `-f` | Tail live flows | `hubble observe -f` |
| `--since TIME` | Flows since time | `hubble observe --since 1h` |
| `--until TIME` | Flows until time | `hubble observe --until 30m` |

### Filter Flags

| Flag | Description | Example |
|------|-------------|---------|
| `--namespace` / `-n` | Filter by namespace | `-n production` |
| `--pod` | Filter by pod | `--pod frontend-xyz` |
| `--label` | Filter by label | `--label app=web` |
| `--from-pod` | From specific pod | `--from-pod ns/pod` |
| `--to-pod` | To specific pod | `--to-pod ns/pod` |
| `--from-service` | From service | `--from-service ns/svc` |
| `--to-service` | To service | `--to-service ns/svc` |
| `--from-ip` | From IP | `--from-ip 10.0.1.50` |
| `--to-ip` | To IP | `--to-ip 10.0.2.100` |
| `--from-identity` | From identity | `--from-identity 12345` |
| `--to-identity` | To identity | `--to-identity 2` |
| `--from-fqdn` | From FQDN | `--from-fqdn api.com` |
| `--to-fqdn` | To FQDN | `--to-fqdn github.com` |
| `--port` | Filter by port | `--port 8080` |
| `--protocol` | Filter by protocol | `--protocol http` |
| `--verdict` | Filter by verdict | `--verdict DROPPED` |
| `--not` | Negate next filter | `--not --label app=test` |

### HTTP-Specific Flags

| Flag | Description | Example |
|------|-------------|---------|
| `--http-status` | HTTP status code | `--http-status 500` |
| `--http-method` | HTTP method | `--http-method POST` |
| `--http-path` | HTTP URL path | `--http-path /api/users` |

### Output Flags

| Flag | Description | Example |
|------|-------------|---------|
| `--output` / `-o` | Format (compact/table/json/jsonpb) | `-o json` |
| `--print-node-name` | Show node names | Add to any observe command |
| `--no-dns-translation` | Show IPs not DNS names | Add to any observe command |

## Practical Examples

### Troubleshooting Scenarios

**Connection Refused**:
```bash
# Find drops between services
hubble observe \
  --from-pod production/frontend-xyz \
  --to-service production/backend \
  --verdict DROPPED
```

**Slow Requests**:
```bash
# Find high-latency HTTP requests
hubble observe --protocol http --output json | \
  jq 'select(.l7.latency_ns > 500000000)'
```

**DNS Resolution Issues**:
```bash
# Check DNS queries and responses
hubble observe --protocol dns --namespace production
```

### Security Analysis

**External Connections Audit**:
```bash
# All external traffic (identity 2 = world)
hubble observe --to-identity 2 --since 24h

# Group by destination
hubble observe --to-identity 2 --output json | \
  jq -r '.flow.destination.fqdn' | sort | uniq -c
```

**Policy Violations**:
```bash
# All denied connections
hubble observe --verdict DROPPED --since 1h

# By source namespace
hubble observe --verdict DROPPED --output json | \
  jq -r '.flow.source.namespace' | sort | uniq -c
```

### Performance Monitoring

**Request Rates**:
```bash
# HTTP requests per minute
hubble observe --protocol http --since 5m | wc -l
```

**Error Rates**:
```bash
# HTTP 5xx errors
hubble observe --protocol http --http-status 500 --since 5m
```

## Automation Scripts

### Daily Security Report

```bash
#!/bin/bash
# daily-hubble-report.sh

DATE=$(date +%Y-%m-%d)
REPORT="hubble-report-$DATE.txt"

cat > $REPORT <<EOF
Hubble Security Report - $DATE
================================

$(hubble observe --since 24h | wc -l) total flows

Denied Connections: $(hubble observe --verdict DROPPED --since 24h | wc -l)

External Connections: $(hubble observe --to-identity 2 --since 24h | wc -l)

Top 10 Source Pods:
$(hubble observe --since 24h --output json | jq -r '.flow.source.pod_name' | sort | uniq -c | sort -rn | head -10)

DNS Queries:
$(hubble observe --protocol dns --since 24h | wc -l) total queries

HTTP Errors (5xx):
$(hubble observe --protocol http --http-status 500 --since 24h | wc -l)
EOF

echo "Report saved to $REPORT"
```

### Continuous SIEM Export

```bash
#!/bin/bash
# export-to-siem.sh

ELASTICSEARCH_URL="http://elasticsearch:9200"
INDEX="hubble-flows"

hubble observe --follow --output json | while read -r line; do
  curl -X POST "$ELASTICSEARCH_URL/$INDEX/_doc" \
    -H 'Content-Type: application/json' \
    -d "$line"
done
```

### Alert on Suspicious Activity

```bash
#!/bin/bash
# alert-on-drops.sh

THRESHOLD=10
WINDOW="5m"

while true; do
  DROPS=$(hubble observe --verdict DROPPED --since $WINDOW | wc -l)
  
  if [ $DROPS -gt $THRESHOLD ]; then
    echo "ALERT: $DROPS dropped connections in last $WINDOW"
    # Send alert (email, Slack, PagerDuty, etc.)
    ./send-alert.sh "High drop rate: $DROPS"
  fi
  
  sleep 300  # Check every 5 minutes
done
```

## Tips and Tricks

### Performance Tips

1. **Always use --namespace**: Reduces data scanned
2. **Combine filters**: More specific = faster
3. **Use --last instead of --all**: Limits output
4. **JSON only when needed**: Compact format is faster

### jq Recipes

**Extract source pods**:
```bash
hubble observe --output json | jq -r '.flow.source.pod_name'
```

**Group by destination service**:
```bash
hubble observe --output json | \
  jq -r '.flow.destination.service_name' | \
  sort | uniq -c | sort -rn
```

**Find unique HTTP paths**:
```bash
hubble observe --protocol http --output json | \
  jq -r '.l7.http.url' | sort -u
```

**Calculate average latency**:
```bash
hubble observe --protocol http --output json | \
  jq -s 'map(.l7.latency_ns) | add / length / 1000000' # ms
```

### Common Patterns

**Before/After Policy Change**:
```bash
# Before
hubble observe --namespace prod > before.txt

# Apply policy change
kubectl apply -f new-policy.yaml

# After
hubble observe --namespace prod > after.txt

# Compare
diff before.txt after.txt
```

**Verify Service Communication**:
```bash
# Generate traffic
kubectl exec frontend -- curl backend

# Verify in Hubble
hubble observe \
  --from-pod ns/frontend \
  --to-service ns/backend \
  --last 1
```

## Troubleshooting Hubble CLI

**Connection Issues**:
```bash
# Verify port forward
ps aux | grep "port-forward.*hubble-relay"

# Test connection
hubble status

# Check Relay logs
kubectl -n kube-system logs deployment/hubble-relay
```

**No Data Returned**:
```bash
# Check if data exists
hubble observe --all | head

# Verify filters aren't too restrictive
hubble observe --namespace demo  # Remove other filters

# Check ring buffer size
hubble status
```

**Performance Issues**:
```bash
# Reduce output
hubble observe --last 10  # Instead of --all

# Use specific filters
hubble observe --namespace prod --pod specific-pod
```

## Additional Resources

- [Hubble CLI GitHub](https://github.com/cilium/hubble)
- [Hubble Documentation](https://docs.cilium.io/en/stable/gettingstarted/hubble/)
- **Repository Labs**: See parent directory for hands-on exercises

---

**Master the CLI, Master Observability**
