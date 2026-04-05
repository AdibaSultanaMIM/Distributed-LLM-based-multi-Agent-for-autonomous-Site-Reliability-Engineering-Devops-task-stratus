# Rate Limiting Architecture Diagrams

## System Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                      Stratus Agent Container                    │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              LiteLLM Backend                              │  │
│  │  • Detects rate limit errors (429)                       │  │
│  │  • Implements exponential backoff                        │  │
│  │  • Retries up to 5 times                                 │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │                                          │
└───────────────────────┼──────────────────────────────────────────┘
                        │
                        │ HTTP Request
                        ▼
┌────────────────────────────────────────────────────────────────┐
│                   Nginx Proxy Container                         │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │           Rate Limiting Layer                            │  │
│  │  • Limit: 10 requests/minute                             │  │
│  │  • Burst: 5 additional requests                          │  │
│  │  • Connection limit: 10 concurrent                       │  │
│  └────────────────────┬─────────────────────────────────────┘  │
│                       │                                          │
│         ┌─────────────┴──────────────┬──────────────┐          │
│         ▼                            ▼              ▼          │
│  ┌──────────┐              ┌──────────────┐  ┌──────────┐     │
│  │ OpenAI   │              │ Azure OpenAI │  │Anthropic │     │
│  │  :8080   │              │    :8081     │  │  :8082   │     │
│  └────┬─────┘              └──────┬───────┘  └─────┬────┘     │
└───────┼────────────────────────────┼────────────────┼──────────┘
        │                            │                │
        │                            │                │
        ▼                            ▼                ▼
┌───────────────────────────────────────────────────────────────┐
│                    External LLM APIs                           │
│  • api.openai.com                                             │
│  • *.openai.azure.com                                         │
│  • api.anthropic.com                                          │
└───────────────────────────────────────────────────────────────┘
```

## Request Flow with Rate Limiting

```
┌─────────┐
│ Start   │
└────┬────┘
     │
     ▼
┌─────────────────────────┐
│ Application makes       │
│ LLM API request         │
└────┬────────────────────┘
     │
     ▼
┌─────────────────────────┐      ┌─────────────────────┐
│ Route through nginx     │─────▶│ Within rate limit?  │
│ proxy (if enabled)      │      └──┬──────────────┬───┘
└─────────────────────────┘         │              │
                                    │ Yes          │ No
                                    ▼              ▼
                          ┌──────────────┐  ┌─────────────────┐
                          │ Forward to   │  │ Return HTTP 429 │
                          │ LLM API      │  │ (Rate Limited)  │
                          └──┬───────────┘  └────┬────────────┘
                             │                    │
                             ▼                    ▼
                    ┌────────────────┐   ┌────────────────────┐
                    │ Get response   │   │ Backend detects    │
                    │ from LLM       │   │ rate limit error   │
                    └──┬─────────────┘   └────┬───────────────┘
                       │                       │
                       ▼                       ▼
                  ┌────────────┐      ┌────────────────────────┐
                  │ Return to  │      │ Calculate backoff delay│
                  │ application│      │ delay = retry_delay *  │
                  └────────────┘      │ (backoff_factor^attempt)│
                                      └────┬───────────────────┘
                                           │
                                           ▼
                                  ┌────────────────────┐
                                  │ Sleep for delay    │
                                  │ (60s, 90s, 135s...)│
                                  └────┬───────────────┘
                                       │
                                       ▼
                                  ┌────────────────────┐
                                  │ Retry < max_retries?│
                                  └──┬──────────────┬──┘
                                     │ Yes          │ No
                                     │              ▼
                                     │         ┌──────────┐
                                     │         │ Fail with│
                                     │         │ error    │
                                     │         └──────────┘
                                     │
                                     └────────▶ (Back to request)
```

## Rate Limiting Behavior Timeline

```
Time (seconds)    Request    Status         Wait Time
─────────────────────────────────────────────────────────
0                 Req #1     ✓ Success      -
6                 Req #2     ✓ Success      -
12                Req #3     ✓ Success      -
18                Req #4     ✓ Success      -
24                Req #5     ✓ Success      -
30                Req #6     ✓ Success      -
36                Req #7     ✓ Success      -
42                Req #8     ✓ Success      -
48                Req #9     ✓ Success      -
54                Req #10    ✓ Success      -
60                Req #11    ✗ Rate Limited 60s (burst full)
120               Req #11    ✓ Success      - (retry 1)
126               Req #12    ✗ Rate Limited 60s
186               Req #12    ✓ Success      - (retry 1)
```

## Exponential Backoff Pattern

```
Attempt    Delay Calculation              Wait Time
──────────────────────────────────────────────────────
1          60 × (1.5^0) = 60 × 1.0        60 seconds
2          60 × (1.5^1) = 60 × 1.5        90 seconds
3          60 × (1.5^2) = 60 × 2.25      135 seconds
4          60 × (1.5^3) = 60 × 3.375     202.5 seconds
5          60 × (1.5^4) = 60 × 5.0625    303.75 seconds

Total maximum wait time: ~791.25 seconds (~13 minutes)
```

## Docker Compose Network

```
┌──────────────────────────────────────────────────┐
│          stratus-network (bridge)                │
│                                                  │
│  ┌─────────────────┐      ┌──────────────────┐ │
│  │ nginx-llm-proxy │◄────▶│ stratus-agent    │ │
│  │ (nginx:alpine)  │      │ (python:3.12)    │ │
│  └────┬────────────┘      └──────────────────┘ │
│       │                                          │
│       │ Ports exposed:                           │
│       │ 8080 (OpenAI)                           │
│       │ 8081 (Azure)                            │
│       │ 8082 (Anthropic)                        │
│       │ 8888 (Health)                           │
│       │                                          │
└───────┼──────────────────────────────────────────┘
        │
        ▼
   Host Machine
   localhost:8080-8082, localhost:8888
```

## Configuration Files Relationship

```
.env
├── USE_NGINX_PROXY=true
├── RATE_LIMIT_MAX_RETRIES=5
├── RATE_LIMIT_RETRY_DELAY=60
└── RATE_LIMIT_BACKOFF_FACTOR=1.5
    │
    ▼
docker-compose.yml
├── nginx-llm-proxy service
│   ├── mounts: nginx/nginx.conf
│   └── ports: 8080, 8081, 8082, 8888
└── stratus-agent service
    ├── depends_on: nginx-llm-proxy
    └── env: USE_NGINX_PROXY, RATE_LIMIT_*
        │
        ▼
nginx/nginx.conf
├── limit_req_zone (rate=10r/m)
├── limit_req (burst=5, delay=3)
└── limit_conn (limit=10)
    │
    ▼
src/stratus/llm_backends/litellm_backend.py
├── _configure_proxy_url()
├── _is_rate_limit_error()
└── _handle_rate_limit() → exponential backoff
```

## Token vs Request Limiting

```
┌─────────────────────────────────────────────────────────┐
│                  Current Implementation                  │
│                  (Request-based)                         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Rate Limit: 10 requests/minute                         │
│                                                          │
│  ┌──────┐ ┌──────┐ ┌──────┐ ... ┌──────┐              │
│  │Req #1│ │Req #2│ │Req #3│     │Req#10│              │
│  │ 100  │ │ 50   │ │ 200  │     │ 500  │ tokens       │
│  │tokens│ │tokens│ │tokens│     │tokens│              │
│  └──────┘ └──────┘ └──────┘     └──────┘              │
│                                                          │
│  All requests counted equally regardless of tokens      │
│                                                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              Future Enhancement                          │
│              (Token-based)                               │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Token Bucket: 100,000 tokens/minute                    │
│  Refill Rate: ~1,667 tokens/second                      │
│                                                          │
│  ┌──────────────────────────────────────┐              │
│  │   Token Bucket                       │              │
│  │   Capacity: 100,000                  │              │
│  │   Current:  ████████░░░░░ 75,000     │              │
│  └──────────────────────────────────────┘              │
│                                                          │
│  Before request: Check if tokens available              │
│  After request:  Deduct actual tokens used              │
│  Continuous:     Refill at constant rate                │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## Health Check Flow

```
┌──────────┐
│  Start   │
└────┬─────┘
     │
     ▼
┌─────────────────────┐
│ docker-compose up   │
└────┬────────────────┘
     │
     ▼
┌─────────────────────────────────┐
│ Start nginx-llm-proxy           │
└────┬────────────────────────────┘
     │
     │ Every 30s
     ▼
┌─────────────────────────────────┐
│ wget http://localhost:8888/health│
└────┬────────────────────────────┘
     │
     ▼
┌──────────────┐       ┌───────────────┐
│ Response OK? │──Yes─▶│ Status: healthy│
└──┬───────────┘       └───────────────┘
   │ No
   │ (After 3 retries)
   ▼
┌────────────────────┐
│ Status: unhealthy  │
│ Restart container  │
└────────────────────┘
```
