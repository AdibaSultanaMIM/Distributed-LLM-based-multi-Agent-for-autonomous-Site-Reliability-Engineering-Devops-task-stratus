#!/bin/bash
# Quick Installation Guide for Nginx Rate Limiting

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Stratus Agent - Nginx Rate Limiting Quick Install      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# 1. Check prerequisites
echo "Step 1: Checking prerequisites..."
if ! command -v docker &> /dev/null; then
    echo "❌ Docker not found. Please install Docker first:"
    echo "   https://docs.docker.com/get-docker/"
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo "❌ Docker Compose not found. Please install Docker Compose:"
    echo "   https://docs.docker.com/compose/install/"
    exit 1
fi
echo "✓ Docker and Docker Compose found"
echo ""

# 2. Configure environment
echo "Step 2: Configuring environment..."
if [ ! -f .env ]; then
    echo "⚠️  No .env file found."
    if [ -f .env.tmpl ]; then
        read -p "Create .env from .env.tmpl? (y/n): " response
        if [ "$response" = "y" ]; then
            cp .env.tmpl .env
            echo "✓ Created .env from template"
        else
            echo "❌ Cannot proceed without .env file"
            exit 1
        fi
    else
        echo "❌ No .env.tmpl found. Please create .env manually."
        exit 1
    fi
fi

# Add rate limiting config to .env if not present
if ! grep -q "USE_NGINX_PROXY" .env; then
    echo "" >> .env
    echo "# Rate Limiting Configuration" >> .env
    echo "USE_NGINX_PROXY=true" >> .env
    echo "RATE_LIMIT_MAX_RETRIES=5" >> .env
    echo "RATE_LIMIT_RETRY_DELAY=60" >> .env
    echo "RATE_LIMIT_BACKOFF_FACTOR=1.5" >> .env
    echo "OPENAI_PROXY_URL=http://nginx-llm-proxy:8080" >> .env
    echo "AZURE_OPENAI_PROXY_URL=http://nginx-llm-proxy:8081" >> .env
    echo "ANTHROPIC_PROXY_URL=http://nginx-llm-proxy:8082" >> .env
    echo "✓ Added rate limiting config to .env"
else
    echo "✓ Rate limiting config already present in .env"
fi
echo ""

# 3. Start services
echo "Step 3: Starting services with Docker Compose..."
docker-compose up -d
echo ""

# 4. Wait for services to be healthy
echo "Step 4: Waiting for services to be healthy..."
sleep 5

# Check nginx health
max_attempts=12
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if curl -s http://localhost:8888/health | grep -q "healthy"; then
        echo "✓ Nginx proxy is healthy"
        break
    fi
    attempt=$((attempt + 1))
    echo "  Waiting for nginx... (attempt $attempt/$max_attempts)"
    sleep 5
done

if [ $attempt -eq $max_attempts ]; then
    echo "❌ Nginx failed to become healthy"
    echo "   Check logs: docker-compose logs nginx-llm-proxy"
    exit 1
fi
echo ""

# 5. Verify setup
echo "Step 5: Verifying setup..."
echo ""
echo "Service Status:"
docker-compose ps
echo ""

echo "Nginx Health Check:"
curl -s http://localhost:8888/health
echo ""

echo "Nginx Status:"
curl -s http://localhost:8888/nginx_status
echo ""

# 6. Show next steps
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Installation Complete! ✓                                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "✓ Nginx rate limiting proxy is running"
echo "✓ Rate limit: 10 requests/minute"
echo "✓ Automatic retry with exponential backoff enabled"
echo ""
echo "Next steps:"
echo ""
echo "1. Test rate limiting:"
echo "   python scripts/test_rate_limiting.py"
echo ""
echo "2. View logs:"
echo "   docker-compose logs -f"
echo ""
echo "3. Monitor rate limiting:"
echo "   docker-compose logs nginx-llm-proxy | grep 'limiting requests'"
echo ""
echo "4. Customize settings:"
echo "   bash scripts/setup_rate_limiting.sh"
echo ""
echo "5. Read documentation:"
echo "   cat docs/RATE_LIMITING.md"
echo ""
echo "Service endpoints:"
echo "  • OpenAI proxy:     http://localhost:8080"
echo "  • Azure OpenAI:     http://localhost:8081"
echo "  • Anthropic:        http://localhost:8082"
echo "  • Health check:     http://localhost:8888/health"
echo "  • Nginx status:     http://localhost:8888/nginx_status"
echo ""
echo "To disable rate limiting:"
echo "  Set USE_NGINX_PROXY=false in .env and restart"
echo ""
