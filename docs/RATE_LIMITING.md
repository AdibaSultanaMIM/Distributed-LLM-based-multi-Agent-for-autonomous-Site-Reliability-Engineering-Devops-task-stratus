# LLM Rate Limiting with Nginx Proxy

This guide explains how to set up and use the Nginx forward proxy for rate limiting LLM API calls and token usage.

## Overview

The rate limiting system uses Nginx as a forward proxy to:
- Limit the number of LLM API requests per minute
- Control concurrent connections
- Automatically retry with exponential backoff when limits are exceeded
- Await/sleep when rate limits are crossed before retrying

## Architecture

```
Stratus Agent → Nginx Proxy (Rate Limiter) → LLM Provider API
                     ↓
                 429 Error
                     ↓
            Retry with Backoff
```

## Components

1. **Nginx Proxy** (`nginx/nginx.conf`): Handles rate limiting at the network level
2. **LiteLLM Backend** (`src/stratus/llm_backends/litellm_backend.py`): Implements retry logic with exponential backoff
3. **Docker Compose** (`docker-compose.yml`): Orchestrates nginx and stratus-agent containers
4. **Configuration** (`.env.ratelimit`): Environment variables for rate limiting settings

## Quick Start

### 1. Configure Environment Variables

Copy the rate limiting configuration to your main `.env` file:

```bash
cat .env.ratelimit >> .env
```

Or manually add these key variables to your `.env`:

```bash
# Enable nginx proxy
USE_NGINX_PROXY=true

# Proxy URLs (for docker-compose)
OPENAI_PROXY_URL=http://nginx-llm-proxy:8080
AZURE_OPENAI_PROXY_URL=http://nginx-llm-proxy:8081
ANTHROPIC_PROXY_URL=http://nginx-llm-proxy:8082

# Retry configuration
RATE_LIMIT_MAX_RETRIES=5
RATE_LIMIT_RETRY_DELAY=60
RATE_LIMIT_BACKOFF_FACTOR=1.5
```

### 2. Start the Services

```bash
docker-compose up -d
```

This will start:
- `nginx-llm-proxy`: Nginx proxy with rate limiting on ports 8080-8082
- `stratus-agent`: The Stratus agent configured to use the proxy

### 3. Verify Setup

Check that services are running:

```bash
docker-compose ps
```

Test the health endpoint:

```bash
curl http://localhost:8888/health
# Should return: healthy
```

Check nginx status:

```bash
curl http://localhost:8888/nginx_status
```

## Rate Limiting Configuration

### Request Rate Limits (Nginx)

Default limits (configured in `nginx/nginx.conf`):
- **Rate**: 10 requests per minute
- **Burst**: 5 additional requests (queued)
- **Delay**: 3 requests processed immediately, rest delayed
- **Connections**: 10 concurrent connections per IP

### Customizing Rate Limits

Edit `nginx/nginx.conf` and modify the `limit_req_zone` directive:

```nginx
# Change from 10r/m to 20r/m for 20 requests per minute
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=20r/m;
```

Then restart nginx:

```bash
docker-compose restart nginx-llm-proxy
```

### Token Limits

Token limits are currently enforced at the request level via `MAX_TOKENS_AGENTS` and `MAX_TOKENS_TOOLS` environment variables.

For per-minute token limiting, you would need to implement application-level tracking (see "Advanced Token Limiting" section below).

## Retry Behavior

When a rate limit is hit (HTTP 429), the system:

1. **Detects** the rate limit error
2. **Waits** with exponential backoff:
   - Attempt 1: Wait 60 seconds
   - Attempt 2: Wait 90 seconds
   - Attempt 3: Wait 135 seconds
   - Attempt 4: Wait 202.5 seconds
   - Attempt 5: Wait 303.75 seconds
3. **Retries** up to 5 times (configurable)
4. **Fails** if all retries exhausted

### Customizing Retry Behavior

Adjust these environment variables in `.env`:

```bash
# Increase max retries
RATE_LIMIT_MAX_RETRIES=10

# Reduce initial delay
RATE_LIMIT_RETRY_DELAY=30

# Increase backoff aggressiveness
RATE_LIMIT_BACKOFF_FACTOR=2.0
```

## Monitoring

### View Nginx Logs

```bash
# Access logs
docker-compose logs nginx-llm-proxy | grep access

# Error logs
docker-compose logs nginx-llm-proxy | grep error

# Rate limiting events
docker-compose logs nginx-llm-proxy | grep "limiting requests"
```

### View Application Logs

```bash
# See rate limit retries
docker-compose logs stratus-agent | grep "Rate limit"
```

### Persistent Logs

Nginx logs are stored in a Docker volume:

```bash
docker volume inspect stratus_nginx-logs
```

## Advanced Configuration

### Per-Provider Rate Limits

You can set different rate limits for each LLM provider by creating separate server blocks in `nginx.conf`:

```nginx
# OpenAI - 10 requests/minute
server {
    listen 8080;
    limit_req zone=openai_limit burst=5 delay=3;
    # ... rest of config
}

# Anthropic - 20 requests/minute
server {
    listen 8082;
    limit_req zone=anthropic_limit burst=10 delay=5;
    # ... rest of config
}
```

And define separate zones:

```nginx
limit_req_zone $binary_remote_addr zone=openai_limit:10m rate=10r/m;
limit_req_zone $binary_remote_addr zone=anthropic_limit:10m rate=20r/m;
```

### Advanced Token Limiting

For per-minute token limiting, you can implement a token bucket algorithm:

1. **Install Redis** (add to docker-compose.yml):

```yaml
redis:
  image: redis:alpine
  networks:
    - stratus-network
```

2. **Implement Token Tracker** (create `src/stratus/utils/token_limiter.py`):

```python
import time
import redis
from typing import Optional

class TokenBucketLimiter:
    def __init__(self, redis_url: str, capacity: int, refill_rate: float):
        self.redis = redis.from_url(redis_url)
        self.capacity = capacity
        self.refill_rate = refill_rate  # tokens per second
    
    def consume(self, tokens: int, key: str = "default") -> tuple[bool, Optional[float]]:
        """
        Try to consume tokens. Returns (success, wait_time).
        If success=False, wait_time indicates how long to wait.
        """
        now = time.time()
        bucket_key = f"token_bucket:{key}"
        
        # Get current bucket state
        bucket = self.redis.hgetall(bucket_key)
        
        if not bucket:
            # Initialize bucket
            current_tokens = self.capacity
            last_refill = now
        else:
            current_tokens = float(bucket[b'tokens'])
            last_refill = float(bucket[b'last_refill'])
            
            # Refill tokens based on time elapsed
            elapsed = now - last_refill
            refill_amount = elapsed * self.refill_rate
            current_tokens = min(self.capacity, current_tokens + refill_amount)
        
        # Check if we have enough tokens
        if current_tokens >= tokens:
            # Consume tokens
            current_tokens -= tokens
            self.redis.hset(bucket_key, mapping={
                'tokens': current_tokens,
                'last_refill': now
            })
            return True, None
        else:
            # Calculate wait time
            tokens_needed = tokens - current_tokens
            wait_time = tokens_needed / self.refill_rate
            return False, wait_time
```

3. **Integrate into LiteLLM Backend**:

```python
from stratus.utils.token_limiter import TokenBucketLimiter

# In __init__:
self.token_limiter = TokenBucketLimiter(
    redis_url=os.getenv("REDIS_URL", "redis://localhost:6379/0"),
    capacity=int(os.getenv("TOKEN_LIMIT_PER_MINUTE", "100000")),
    refill_rate=int(os.getenv("TOKEN_LIMIT_PER_MINUTE", "100000")) / 60
)

# Before making API call:
success, wait_time = self.token_limiter.consume(self.max_tokens)
if not success:
    logger.info(f"Token limit reached. Waiting {wait_time:.2f}s")
    time.sleep(wait_time)
```

## Troubleshooting

### Rate Limits Still Being Hit

1. **Check nginx is being used**:
   ```bash
   docker-compose logs stratus-agent | grep "Nginx proxy enabled"
   ```

2. **Verify proxy URLs**:
   ```bash
   docker-compose exec stratus-agent env | grep PROXY_URL
   ```

3. **Check nginx is receiving requests**:
   ```bash
   docker-compose logs nginx-llm-proxy | tail -20
   ```

### Connection Refused Errors

1. **Ensure nginx is healthy**:
   ```bash
   docker-compose ps nginx-llm-proxy
   curl http://localhost:8888/health
   ```

2. **Check network connectivity**:
   ```bash
   docker-compose exec stratus-agent ping nginx-llm-proxy
   ```

### Too Many Retries

If you're seeing excessive retries:

1. **Increase rate limits** in nginx.conf
2. **Reduce retry attempts**:
   ```bash
   RATE_LIMIT_MAX_RETRIES=3
   ```
3. **Increase initial delay**:
   ```bash
   RATE_LIMIT_RETRY_DELAY=120
   ```

## Disabling Rate Limiting

To disable the nginx proxy and make direct API calls:

```bash
# In .env
USE_NGINX_PROXY=false
```

Or run without docker-compose:

```bash
python -m stratus.main
```

## Performance Considerations

- **Latency**: Proxy adds minimal latency (~5-10ms)
- **Throughput**: Can handle 1000+ req/s with default nginx settings
- **Memory**: Rate limiting zones use ~10MB per zone
- **Retries**: Exponential backoff prevents thundering herd

## Example Scenarios

### Scenario 1: Conservative Rate Limiting

```bash
# nginx.conf
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=5r/m;

# .env
RATE_LIMIT_MAX_RETRIES=10
RATE_LIMIT_RETRY_DELAY=120
RATE_LIMIT_BACKOFF_FACTOR=2.0
```

### Scenario 2: Aggressive Usage

```bash
# nginx.conf
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=30r/m;

# .env
RATE_LIMIT_MAX_RETRIES=3
RATE_LIMIT_RETRY_DELAY=30
RATE_LIMIT_BACKOFF_FACTOR=1.2
```

### Scenario 3: Development (No Limits)

```bash
# .env
USE_NGINX_PROXY=false
```

## References

- [Nginx Rate Limiting](http://nginx.org/en/docs/http/ngx_http_limit_req_module.html)
- [LiteLLM Documentation](https://docs.litellm.ai/)
- [Token Bucket Algorithm](https://en.wikipedia.org/wiki/Token_bucket)
