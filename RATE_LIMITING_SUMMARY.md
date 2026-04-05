# 🚀 Nginx Rate Limiting Implementation Summary

## What Was Added

I've implemented a complete nginx-based forward proxy system for LLM API rate limiting with automatic retry logic. Here's what was created:

### 📁 Files Created

1. **nginx/nginx.conf** - Nginx rate limiting configuration (10 req/min)
2. **nginx/nginx.prod.conf** - Production configuration (30 req/min, optimized)
3. **docker-compose.yml** - Docker orchestration for nginx + stratus-agent
4. **docker-compose.override.yml.example** - Production deployment example
5. **.env.ratelimit** - Rate limiting configuration variables
6. **docs/RATE_LIMITING.md** - Comprehensive documentation
7. **scripts/setup_rate_limiting.sh** - Interactive setup script
8. **scripts/test_rate_limiting.py** - Testing utility

### 🔧 Files Modified

1. **src/stratus/llm_backends/litellm_backend.py** - Added retry logic with exponential backoff
2. **README.md** - Added rate limiting section

## Key Features

### ✅ Request Rate Limiting
- **Default**: 10 requests per minute
- **Burst capacity**: 5 additional requests (queued)
- **Delay threshold**: 3 requests processed immediately
- **Production**: 30 requests per minute with 15 burst

### ✅ Automatic Retry with Exponential Backoff
When rate limit is hit (HTTP 429):
- **Attempt 1**: Wait 60 seconds
- **Attempt 2**: Wait 90 seconds (60 × 1.5)
- **Attempt 3**: Wait 135 seconds (90 × 1.5)
- **Attempt 4**: Wait 202.5 seconds
- **Attempt 5**: Wait 303.75 seconds

### ✅ Multi-Provider Support
Separate proxies for:
- OpenAI (port 8080)
- Azure OpenAI (port 8081)
- Anthropic (port 8082)

### ✅ Connection Limiting
- Max 10-20 concurrent connections per IP
- Prevents connection exhaustion

## How It Works

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│   Stratus    │────────▶│    Nginx     │────────▶│  LLM API     │
│   Agent      │         │    Proxy     │         │  Provider    │
└──────────────┘         └──────────────┘         └──────────────┘
                                │
                                │ Rate limit exceeded
                                ▼
                         ┌──────────────┐
                         │  Return 429  │
                         └──────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │  Retry with Backoff     │
                    │  (Exponential Delay)    │
                    └─────────────────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │  Wait & Retry           │
                    │  (Up to 5 attempts)     │
                    └─────────────────────────┘
```

## Quick Start

### 1. Setup (Interactive)
```bash
bash scripts/setup_rate_limiting.sh
```

### 2. Setup (Manual)
```bash
# Add to .env
USE_NGINX_PROXY=true
RATE_LIMIT_MAX_RETRIES=5
RATE_LIMIT_RETRY_DELAY=60
RATE_LIMIT_BACKOFF_FACTOR=1.5
```

### 3. Start Services
```bash
docker-compose up -d
```

### 4. Test Rate Limiting
```bash
python scripts/test_rate_limiting.py
```

### 5. Monitor
```bash
# Health check
curl http://localhost:8888/health

# Nginx status
curl http://localhost:8888/nginx_status

# View logs
docker-compose logs nginx-llm-proxy
```

## Configuration Options

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `USE_NGINX_PROXY` | false | Enable/disable nginx proxy |
| `RATE_LIMIT_MAX_RETRIES` | 5 | Maximum retry attempts |
| `RATE_LIMIT_RETRY_DELAY` | 60 | Initial delay in seconds |
| `RATE_LIMIT_BACKOFF_FACTOR` | 1.5 | Exponential backoff multiplier |
| `OPENAI_PROXY_URL` | http://nginx-llm-proxy:8080 | OpenAI proxy URL |
| `AZURE_OPENAI_PROXY_URL` | http://nginx-llm-proxy:8081 | Azure proxy URL |
| `ANTHROPIC_PROXY_URL` | http://nginx-llm-proxy:8082 | Anthropic proxy URL |

### Nginx Rate Limits

Edit `nginx/nginx.conf` to customize:

```nginx
# Change rate (e.g., 20 requests per minute)
limit_req_zone $binary_remote_addr zone=llm_req_limit:10m rate=20r/m;

# Change burst capacity
limit_req zone=llm_req_limit burst=10 delay=5;

# Change connection limit
limit_conn llm_conn_limit 15;
```

## Token Limiting (Future Enhancement)

The current implementation limits **requests per minute**. For **token-based limiting**, you would need to:

1. **Track token usage** from LLM responses
2. **Implement token bucket algorithm**
3. **Use Redis** for distributed tracking
4. **Add pre-request token check**

See [docs/RATE_LIMITING.md](docs/RATE_LIMITING.md) for implementation details.

## Production Deployment

### Use Production Config
```bash
# Copy production nginx config
cp nginx/nginx.prod.conf nginx/nginx.conf

# Copy production docker-compose override
cp docker-compose.override.yml.example docker-compose.override.yml

# Start with production settings
docker-compose up -d
```

### Production Settings
- **Rate**: 30 requests/minute
- **Burst**: 15 requests
- **Retries**: 10 attempts
- **Initial delay**: 120 seconds
- **Backoff**: 2.0x

## Testing

### Manual Test
```bash
# Make multiple requests quickly
for i in {1..15}; do
  echo "Request $i"
  curl -X POST http://localhost:8080/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-3.5-turbo","messages":[{"role":"user","content":"test"}]}'
  sleep 1
done
```

### Automated Test
```bash
python scripts/test_rate_limiting.py
```

Expected behavior:
- First 10 requests: Success (immediate)
- Requests 11-15: Success (with retries and delays)
- Total time: ~60-90 seconds for 15 requests

## Monitoring & Logs

### View Rate Limiting Events
```bash
docker-compose logs nginx-llm-proxy | grep "limiting requests"
```

### View Retry Events
```bash
docker-compose logs stratus-agent | grep "Rate limit"
```

### Real-time Monitoring
```bash
docker-compose logs -f
```

### Nginx Status
```bash
curl http://localhost:8888/nginx_status
```

Output:
```
Active connections: 2
server accepts handled requests
 100 100 150
Reading: 0 Writing: 1 Waiting: 1
```

## Troubleshooting

### Problem: Rate limits still being exceeded
**Solution**: Check if proxy is enabled
```bash
docker-compose logs stratus-agent | grep "Nginx proxy enabled"
```

### Problem: Connection refused
**Solution**: Ensure nginx is running
```bash
docker-compose ps nginx-llm-proxy
curl http://localhost:8888/health
```

### Problem: Too many retries
**Solution**: Increase rate limit in nginx.conf or reduce max retries

### Problem: Disable rate limiting
**Solution**: Set `USE_NGINX_PROXY=false` in .env

## Benefits

1. ✅ **Cost Control**: Prevents excessive API calls
2. ✅ **Error Prevention**: Avoids provider rate limit errors
3. ✅ **Automatic Recovery**: Retries with exponential backoff
4. ✅ **Configurable**: Easy to adjust limits and retry behavior
5. ✅ **Observable**: Comprehensive logging and monitoring
6. ✅ **Production-Ready**: Optimized configs for different environments
7. ✅ **Multi-Provider**: Supports all major LLM providers

## Next Steps

1. **Enable rate limiting**: Run `bash scripts/setup_rate_limiting.sh`
2. **Test it**: Run `python scripts/test_rate_limiting.py`
3. **Monitor**: Check logs with `docker-compose logs -f`
4. **Customize**: Adjust limits in nginx.conf as needed
5. **Deploy**: Use production config for live environments

## Documentation

- **Main Guide**: [docs/RATE_LIMITING.md](docs/RATE_LIMITING.md)
- **Config Reference**: [.env.ratelimit](.env.ratelimit)
- **Setup Script**: [scripts/setup_rate_limiting.sh](scripts/setup_rate_limiting.sh)
- **Test Script**: [scripts/test_rate_limiting.py](scripts/test_rate_limiting.py)

## Example Usage

```python
# The LiteLLM backend automatically handles rate limiting
from stratus.llm_backends.litellm_backend import LiteLLMBackend

# With USE_NGINX_PROXY=true, this will:
# 1. Route through nginx proxy
# 2. Respect rate limits
# 3. Automatically retry on 429 errors
# 4. Use exponential backoff
response = backend.inference(
    system_prompt="You are a helpful assistant.",
    input="Hello, world!"
)
```

No code changes needed - just enable the proxy in .env!

---

**Questions or issues?** See [docs/RATE_LIMITING.md](docs/RATE_LIMITING.md) for detailed troubleshooting.
