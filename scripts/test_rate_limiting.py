#!/usr/bin/env python3
"""
Test script to demonstrate nginx rate limiting for LLM API calls.
This script makes multiple rapid API calls to trigger rate limits.
"""

import os
import sys
import time
from datetime import datetime

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))

from stratus.llm_backends.litellm_backend import LiteLLMBackend
from dotenv import load_dotenv

load_dotenv()


def print_with_timestamp(message: str):
    """Print message with timestamp"""
    timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"[{timestamp}] {message}")


def test_rate_limiting():
    """Test rate limiting by making rapid API calls"""
    
    print("=" * 70)
    print("LLM Rate Limiting Test")
    print("=" * 70)
    
    # Check configuration
    use_proxy = os.getenv("USE_NGINX_PROXY", "false").lower() == "true"
    max_retries = int(os.getenv("RATE_LIMIT_MAX_RETRIES", "5"))
    retry_delay = int(os.getenv("RATE_LIMIT_RETRY_DELAY", "60"))
    
    print(f"\nConfiguration:")
    print(f"  USE_NGINX_PROXY: {use_proxy}")
    print(f"  MAX_RETRIES: {max_retries}")
    print(f"  RETRY_DELAY: {retry_delay}s")
    
    if not use_proxy:
        print("\n⚠️  WARNING: Nginx proxy is disabled!")
        print("   Set USE_NGINX_PROXY=true in .env to test rate limiting")
        print("   These tests will make direct API calls without rate limiting.")
        response = input("\nContinue anyway? (y/n): ")
        if response.lower() != 'y':
            print("Test cancelled.")
            return
    
    # Initialize backend
    try:
        backend = LiteLLMBackend(
            provider=os.getenv("PROVIDER_TOOLS", "openai"),
            model_name=os.getenv("MODEL_TOOLS", "gpt-3.5-turbo"),
            url=os.getenv("URL_TOOLS", ""),
            api_key=os.getenv("API_KEY_TOOLS", ""),
            api_version=os.getenv("API_VERSION_TOOLS", ""),
            seed=int(os.getenv("SEED_TOOLS", "0")),
            top_p=float(os.getenv("TOP_P_TOOLS", "0.95")),
            temperature=float(os.getenv("TEMPERATURE_TOOLS", "0.7")),
            reasoning_effort=os.getenv("REASONING_EFFORT_TOOLS", ""),
            thinking_tools=os.getenv("THINKING_TOOLS", ""),
            thinking_budget_tools=int(os.getenv("THINKING_BUDGET_TOOLS", "16000")),
            max_tokens=100,  # Small for testing
        )
    except Exception as e:
        print(f"\n❌ Failed to initialize backend: {e}")
        print("\nMake sure all required environment variables are set:")
        print("  - PROVIDER_TOOLS")
        print("  - MODEL_TOOLS")
        print("  - API_KEY_TOOLS")
        return
    
    print(f"\nBackend initialized:")
    print(f"  Provider: {backend.provider}")
    print(f"  Model: {backend.model_name}")
    print(f"  URL: {backend.url}")
    
    # Test parameters
    num_requests = 15  # More than rate limit (10/min)
    delay_between = 0.5  # Fast requests to trigger limit
    
    print(f"\nTest parameters:")
    print(f"  Number of requests: {num_requests}")
    print(f"  Delay between requests: {delay_between}s")
    print(f"  Expected rate limit: 10 requests/minute")
    print(f"\n⚠️  This test will make {num_requests} API calls.")
    print(f"   At 10 req/min, this should trigger rate limiting after request 10.")
    
    if use_proxy:
        print(f"   Rate-limited requests will automatically retry with backoff.")
        total_time = retry_delay * (1.5 ** (max_retries - 1))
        print(f"   Maximum wait time per retry: ~{total_time:.0f}s")
    
    response = input("\nProceed with test? (y/n): ")
    if response.lower() != 'y':
        print("Test cancelled.")
        return
    
    # Run test
    print("\n" + "=" * 70)
    print("Starting API calls...")
    print("=" * 70 + "\n")
    
    results = []
    start_time = time.time()
    
    for i in range(num_requests):
        request_num = i + 1
        print_with_timestamp(f"Request #{request_num} - Starting...")
        
        request_start = time.time()
        
        try:
            # Make simple API call
            response = backend.inference(
                system_prompt="You are a helpful assistant.",
                input=f"Say 'Request {request_num} completed' in 5 words or less."
            )
            
            request_duration = time.time() - request_start
            
            print_with_timestamp(f"Request #{request_num} - ✓ Success ({request_duration:.2f}s)")
            print_with_timestamp(f"Response: {response[:50]}...")
            
            results.append({
                'request': request_num,
                'success': True,
                'duration': request_duration,
                'error': None
            })
            
        except Exception as e:
            request_duration = time.time() - request_start
            error_msg = str(e)
            
            print_with_timestamp(f"Request #{request_num} - ✗ Failed ({request_duration:.2f}s)")
            print_with_timestamp(f"Error: {error_msg[:100]}")
            
            results.append({
                'request': request_num,
                'success': False,
                'duration': request_duration,
                'error': error_msg
            })
        
        # Delay before next request
        if i < num_requests - 1:
            time.sleep(delay_between)
        
        print()
    
    # Summary
    total_time = time.time() - start_time
    successful = sum(1 for r in results if r['success'])
    failed = sum(1 for r in results if not r['success'])
    
    print("=" * 70)
    print("Test Summary")
    print("=" * 70)
    print(f"\nTotal requests: {num_requests}")
    print(f"Successful: {successful}")
    print(f"Failed: {failed}")
    print(f"Total time: {total_time:.2f}s")
    print(f"Average time per request: {total_time / num_requests:.2f}s")
    
    if use_proxy:
        print(f"\nRate limiting behavior:")
        long_requests = [r for r in results if r['duration'] > 10]
        if long_requests:
            print(f"  Requests with retries: {len(long_requests)}")
            print(f"  Longest request: {max(r['duration'] for r in long_requests):.2f}s")
            print(f"  ✓ Rate limiting is working correctly!")
        else:
            print(f"  ⚠️  No rate limiting detected.")
            print(f"     Either the limit wasn't reached, or proxy isn't configured.")
    
    print("\n" + "=" * 70)
    
    # Detailed results
    print("\nDetailed Results:")
    print("-" * 70)
    for r in results:
        status = "✓" if r['success'] else "✗"
        print(f"Request #{r['request']:2d}: {status} ({r['duration']:6.2f}s) {r['error'][:50] if r['error'] else ''}")


if __name__ == "__main__":
    try:
        test_rate_limiting()
    except KeyboardInterrupt:
        print("\n\nTest interrupted by user.")
    except Exception as e:
        print(f"\n\n❌ Test failed with error: {e}")
        import traceback
        traceback.print_exc()
