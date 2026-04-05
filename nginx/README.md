# Nginx Configuration for LLM Rate Limiting

This directory contains Nginx configurations for rate limiting LLM API calls.

## Files

### nginx.conf
- **Purpose**: Default development configuration
- **Rate Limit**: 10 requests per minute
- **Burst**: 5 additional requests
- **Use Case**: Development and testing

### nginx.prod.conf
- **Purpose**: Production-optimized configuration
- **Rate Limit**: 30 requests per minute
- **Burst**: 15 additional requests
- **Use Case**: Production deployments
- **Features**:
  - Connection pooling
  - Optimized timeouts
  - Better logging
  - Gzip compression
  - Enhanced performance

## Quick Configuration Changes

### Change Request Rate Limit

Find and modify this line:
```nginx
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=10r/m;
```

Examples:
- `rate=5r/m` - 5 requests per minute (very conservative)
- `rate=20r/m` - 20 requests per minute (moderate)
- `rate=60r/m` - 60 requests per minute (1 req/sec)
- `rate=120r/m` - 120 requests per minute (2 req/sec)

### Change Burst Capacity

Find and modify:
```nginx
limit_req zone=llm_req_limit burst=5 delay=3;
```

- `burst=5` - Allow 5 extra requests (queued)
- `delay=3` - Process first 3 immediately, delay the rest

### Change Connection Limit

Find and modify:
```nginx
limit_conn llm_conn_limit 10;
```

- `10` - Maximum 10 concurrent connections

## Rate Limiting Explained

### Request Rate
`rate=10r/m` means:
- 10 requests per 60 seconds
- Equals 1 request every 6 seconds
- Requests within this rate: allowed immediately
- Requests exceeding this rate: rejected or queued (if burst available)

### Burst Capacity
`burst=5` means:
- Up to 5 additional requests can be queued
- Total capacity: 10 (rate) + 5 (burst) = 15 requests per minute
- Without burst: requests are rejected immediately if rate exceeded
- With burst: requests are queued and processed as capacity becomes available

### Delay Threshold
`delay=3` means:
- First 3 burst requests: processed immediately (no delay)
- Remaining burst requests: delayed to match the rate limit
- Example with burst=5, delay=3:
  - Requests 1-10: immediate (within rate)
  - Requests 11-13: immediate (burst, no delay)
  - Requests 14-15: delayed (burst, with delay)
  - Request 16+: rejected (429 error)

## Example Scenarios

### Conservative (Cost-sensitive)
```nginx
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=5r/m;
limit_req zone=llm_req_limit burst=2 delay=1;
```
- 5 requests/minute base rate
- 2 extra requests allowed
- Only 1 processed immediately
- Good for: Minimizing LLM API costs

### Moderate (Default)
```nginx
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=10r/m;
limit_req zone=llm_req_limit burst=5 delay=3;
```
- 10 requests/minute base rate
- 5 extra requests allowed
- 3 processed immediately
- Good for: Development and testing

### Aggressive (Production)
```nginx
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=30r/m;
limit_req zone=llm_req_limit burst=15 delay=10;
```
- 30 requests/minute base rate
- 15 extra requests allowed
- 10 processed immediately
- Good for: High-throughput production

## Per-Provider Rate Limits

You can set different limits for different LLM providers:

```nginx
# Define separate zones
limit_req_zone $binary_remote_addr zone=openai_limit:10m rate=10r/m;
limit_req_zone $binary_remote_addr zone=azure_limit:10m rate=20r/m;
limit_req_zone $binary_remote_addr zone=anthropic_limit:10m rate=15r/m;

# Apply in server blocks
server {
    listen 8080;
    limit_req zone=openai_limit burst=5 delay=3;
    # ... OpenAI config
}

server {
    listen 8081;
    limit_req zone=azure_limit burst=10 delay=5;
    # ... Azure config
}

server {
    listen 8082;
    limit_req zone=anthropic_limit burst=7 delay=4;
    # ... Anthropic config
}
```

## Testing Rate Limits

### Method 1: Manual cURL
```bash
# Send 15 rapid requests
for i in {1..15}; do
  echo "Request $i"
  curl -i http://localhost:8080/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-3.5-turbo","messages":[{"role":"user","content":"test"}]}'
done
```

### Method 2: Test Script
```bash
python scripts/test_rate_limiting.py
```

### Method 3: Watch Nginx Logs
```bash
# Terminal 1: Watch rate limit events
docker-compose logs -f nginx-llm-proxy | grep limiting

# Terminal 2: Make requests
# You'll see "limiting requests" messages when limits are hit
```

## Applying Configuration Changes

### For Development (docker-compose)
```bash
# Edit nginx.conf
vim nginx/nginx.conf

# Restart nginx
docker-compose restart nginx-llm-proxy

# Or reload nginx (no downtime)
docker-compose exec nginx-llm-proxy nginx -s reload
```

### For Production
```bash
# Test configuration first
docker-compose exec nginx-llm-proxy nginx -t

# If test passes, reload
docker-compose exec nginx-llm-proxy nginx -s reload
```

## Monitoring

### Check if rate limiting is working
```bash
# Look for "limiting requests" in logs
docker-compose logs nginx-llm-proxy | grep "limiting requests"
```

### View current status
```bash
curl http://localhost:8888/nginx_status
```

Output example:
```
Active connections: 5
server accepts handled requests
 245 245 389
Reading: 0 Writing: 2 Waiting: 3
```

### View rate limit headers
```bash
curl -I http://localhost:8080/
# Look for:
# X-RateLimit-Limit: 10/minute
# X-RateLimit-Burst: 5
```

## Advanced: IP-based vs User-based Rate Limiting

Current implementation uses IP-based limiting:
```nginx
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=10r/m;
```

For user-based limiting (if you have auth headers):
```nginx
# Define zone based on API key or user ID
limit_req_zone $http_authorization zone=llm_req_limit:10m rate=10r/m;

# Or based on custom header
limit_req_zone $http_x_user_id zone=llm_req_limit:10m rate=10r/m;
```

## Troubleshooting

### Rate limits not working
1. Check if requests are going through nginx:
   ```bash
   docker-compose logs nginx-llm-proxy | tail -20
   ```

2. Verify USE_NGINX_PROXY=true in .env

3. Check nginx config syntax:
   ```bash
   docker-compose exec nginx-llm-proxy nginx -t
   ```

### Too many 429 errors
1. Increase rate limit in nginx.conf
2. Increase burst capacity
3. Check if multiple processes are making requests

### Nginx not starting
1. Check port conflicts:
   ```bash
   sudo lsof -i :8080
   sudo lsof -i :8081
   sudo lsof -i :8082
   ```

2. Check nginx logs:
   ```bash
   docker-compose logs nginx-llm-proxy
   ```

## References

- [Nginx Rate Limiting](http://nginx.org/en/docs/http/ngx_http_limit_req_module.html)
- [Nginx Connection Limiting](http://nginx.org/en/docs/http/ngx_http_limit_conn_module.html)
- [Nginx Proxy Module](http://nginx.org/en/docs/http/ngx_http_proxy_module.html)
