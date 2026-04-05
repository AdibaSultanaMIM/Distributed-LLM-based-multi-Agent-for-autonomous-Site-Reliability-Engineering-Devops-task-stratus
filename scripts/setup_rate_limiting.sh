#!/bin/bash

# Rate Limiting Setup Script for Stratus Agent
# This script helps configure and test the nginx rate limiting proxy

set -e

COLOR_RESET='\033[0m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'

echo -e "${COLOR_BLUE}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Stratus Agent - LLM Rate Limiting Setup                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${COLOR_RESET}"

# Function to print colored messages
print_success() {
    echo -e "${COLOR_GREEN}✓ $1${COLOR_RESET}"
}

print_warning() {
    echo -e "${COLOR_YELLOW}⚠ $1${COLOR_RESET}"
}

print_error() {
    echo -e "${COLOR_RED}✗ $1${COLOR_RESET}"
}

print_info() {
    echo -e "${COLOR_BLUE}ℹ $1${COLOR_RESET}"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
print_info "Checking prerequisites..."

if ! command_exists docker; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi
print_success "Docker is installed"

if ! command_exists docker-compose; then
    print_error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi
print_success "Docker Compose is installed"

# Check if .env file exists
if [ ! -f .env ]; then
    print_warning ".env file not found. Creating from template..."
    if [ -f .env.example ]; then
        cp .env.example .env
        print_success "Created .env from .env.example"
    else
        print_error "No .env or .env.example found. Please create .env file."
        exit 1
    fi
fi

# Function to update or add env variable
update_env() {
    local key=$1
    local value=$2
    local file=${3:-.env}
    
    if grep -q "^${key}=" "$file"; then
        # Update existing
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        # Add new
        echo "${key}=${value}" >> "$file"
    fi
}

# Configuration menu
echo ""
print_info "Configuration Menu:"
echo "1. Enable rate limiting with default settings (10 req/min)"
echo "2. Enable rate limiting with custom settings"
echo "3. Disable rate limiting"
echo "4. Test current configuration"
echo "5. View logs"
echo "6. Reset configuration"
echo "7. Exit"
echo ""
read -p "Select an option (1-7): " choice

case $choice in
    1)
        print_info "Enabling rate limiting with default settings..."
        update_env "USE_NGINX_PROXY" "true"
        update_env "RATE_LIMIT_MAX_RETRIES" "5"
        update_env "RATE_LIMIT_RETRY_DELAY" "60"
        update_env "RATE_LIMIT_BACKOFF_FACTOR" "1.5"
        update_env "OPENAI_PROXY_URL" "http://nginx-llm-proxy:8080"
        update_env "AZURE_OPENAI_PROXY_URL" "http://nginx-llm-proxy:8081"
        update_env "ANTHROPIC_PROXY_URL" "http://nginx-llm-proxy:8082"
        print_success "Rate limiting enabled with default settings"
        print_info "Rate limit: 10 requests/minute, 5 burst, 5 max retries"
        ;;
    
    2)
        print_info "Custom configuration..."
        read -p "Enter max retries (default: 5): " retries
        retries=${retries:-5}
        read -p "Enter retry delay in seconds (default: 60): " delay
        delay=${delay:-60}
        read -p "Enter backoff factor (default: 1.5): " backoff
        backoff=${backoff:-1.5}
        
        update_env "USE_NGINX_PROXY" "true"
        update_env "RATE_LIMIT_MAX_RETRIES" "$retries"
        update_env "RATE_LIMIT_RETRY_DELAY" "$delay"
        update_env "RATE_LIMIT_BACKOFF_FACTOR" "$backoff"
        update_env "OPENAI_PROXY_URL" "http://nginx-llm-proxy:8080"
        update_env "AZURE_OPENAI_PROXY_URL" "http://nginx-llm-proxy:8081"
        update_env "ANTHROPIC_PROXY_URL" "http://nginx-llm-proxy:8082"
        
        print_success "Custom configuration applied"
        print_info "Max retries: $retries, Delay: ${delay}s, Backoff: $backoff"
        print_warning "Note: To change rate limit (req/min), edit nginx/nginx.conf"
        ;;
    
    3)
        print_info "Disabling rate limiting..."
        update_env "USE_NGINX_PROXY" "false"
        print_success "Rate limiting disabled"
        ;;
    
    4)
        print_info "Testing configuration..."
        
        # Check if services are running
        if docker-compose ps | grep -q "nginx-llm-proxy.*Up"; then
            print_success "Nginx proxy is running"
        else
            print_warning "Nginx proxy is not running. Starting services..."
            docker-compose up -d
            sleep 5
        fi
        
        # Test health endpoint
        print_info "Testing health endpoint..."
        if curl -s http://localhost:8888/health | grep -q "healthy"; then
            print_success "Health check passed"
        else
            print_error "Health check failed"
        fi
        
        # Test nginx status
        print_info "Testing nginx status..."
        if curl -s http://localhost:8888/nginx_status >/dev/null 2>&1; then
            print_success "Nginx status endpoint accessible"
            echo ""
            curl -s http://localhost:8888/nginx_status
        else
            print_error "Nginx status endpoint not accessible"
        fi
        
        # Check environment variables
        print_info "Checking environment variables..."
        if grep -q "USE_NGINX_PROXY=true" .env; then
            print_success "Rate limiting is enabled"
        else
            print_warning "Rate limiting is disabled"
        fi
        ;;
    
    5)
        print_info "Log viewer menu:"
        echo "1. Nginx access logs"
        echo "2. Nginx error logs"
        echo "3. Stratus agent logs"
        echo "4. All logs (follow mode)"
        read -p "Select log type (1-4): " log_choice
        
        case $log_choice in
            1)
                print_info "Showing nginx access logs..."
                docker-compose logs --tail=50 nginx-llm-proxy | grep access
                ;;
            2)
                print_info "Showing nginx error logs..."
                docker-compose logs --tail=50 nginx-llm-proxy | grep error
                ;;
            3)
                print_info "Showing stratus agent logs..."
                docker-compose logs --tail=50 stratus-agent
                ;;
            4)
                print_info "Following all logs (Ctrl+C to exit)..."
                docker-compose logs -f
                ;;
            *)
                print_error "Invalid option"
                ;;
        esac
        ;;
    
    6)
        print_warning "This will reset rate limiting configuration to defaults."
        read -p "Are you sure? (y/n): " confirm
        if [ "$confirm" = "y" ]; then
            print_info "Resetting configuration..."
            update_env "USE_NGINX_PROXY" "true"
            update_env "RATE_LIMIT_MAX_RETRIES" "5"
            update_env "RATE_LIMIT_RETRY_DELAY" "60"
            update_env "RATE_LIMIT_BACKOFF_FACTOR" "1.5"
            print_success "Configuration reset to defaults"
        else
            print_info "Reset cancelled"
        fi
        ;;
    
    7)
        print_info "Exiting..."
        exit 0
        ;;
    
    *)
        print_error "Invalid option"
        exit 1
        ;;
esac

# Ask if user wants to restart services
echo ""
read -p "Do you want to restart services to apply changes? (y/n): " restart
if [ "$restart" = "y" ]; then
    print_info "Restarting services..."
    docker-compose down
    docker-compose up -d
    sleep 5
    
    # Verify services are up
    if docker-compose ps | grep -q "Up"; then
        print_success "Services restarted successfully"
        echo ""
        docker-compose ps
    else
        print_error "Failed to start services"
        docker-compose logs --tail=20
    fi
fi

echo ""
print_success "Done! For more information, see docs/RATE_LIMITING.md"
