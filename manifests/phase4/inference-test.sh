#!/bin/bash
# inference-test.sh - End-to-end vLLM inference validation

set -e

echo "=== vLLM End-to-End Inference Validation ==="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PORT_FORWARD_PORT=8000
SERVICE_NAME="vllm-service-head-svc"
NAMESPACE="llm-serving"
TEST_PROMPT="Hello! How are you?"
MAX_TOKENS=50

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}ERROR: kubectl not found${NC}"
  exit 1
fi

# Check if ray service exists
echo "Checking if RayService exists..."
if ! kubectl get rayservice $SERVICE_NAME -n $NAMESPACE &> /dev/null; then
  echo -e "${YELLOW}WARNING: RayService '$SERVICE_NAME' not found in namespace '$NAMESPACE'${NC}"
  echo "Do you want to continue anyway? (y/n)"
  read -r response
  if [[ "$response" != "y" ]]; then
    exit 1
  fi
fi

# Kill any existing port-forward on the port
echo "Cleaning up existing port-forward processes..."
pkill -f "port-forward.*$SERVICE_PORT" 2>/dev/null || true
sleep 1

# Start port-forward in background
echo "Starting port-forward to vLLM service..."
kubectl port-forward -n $NAMESPACE svc/$SERVICE_NAME $PORT_FORWARD_PORT:8000 &
PF_PID=$!

# Wait for port-forward to be ready
echo "Waiting for port-forward to be ready..."
for i in {1..30}; do
  if curl -s http://localhost:$PORT_FORWARD_PORT/health &> /dev/null; then
    echo "Port-forward ready!"
    break
  fi
  if [ $i -eq 30 ]; then
    echo -e "${RED}ERROR: Port-forward failed to start${NC}"
    kill $PF_PID 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

# Test 1: Health endpoint
echo ""
echo "=== Test 1: Health Endpoint ==="
HEALTH_RESPONSE=$(curl -s http://localhost:$PORT_FORWARD_PORT/health || echo "FAILED")
echo "Response: $HEALTH_RESPONSE"
if echo "$HEALTH_RESPONSE" | grep -q "healthy"; then
  echo -e "${GREEN}✓ Health check passed${NC}"
else
  echo -e "${RED}✗ Health check failed${NC}"
fi

# Test 2: List models
echo ""
echo "=== Test 2: List Models ==="
MODELS_RESPONSE=$(curl -s http://localhost:$PORT_FORWARD_PORT/v1/models || echo "FAILED")
echo "Response: $MODELS_RESPONSE"
if echo "$MODELS_RESPONSE" | grep -q "data"; then
  echo -e "${GREEN}✓ List models passed${NC}"
else
  echo -e "${RED}✗ List models failed${NC}"
fi

# Test 3: Chat completions
echo ""
echo "=== Test 3: Chat Completions ==="
echo "Prompt: $TEST_PROMPT"

RESPONSE=$(curl -s -X POST http://localhost:$PORT_FORWARD_PORT/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"meta-llama/Llama-2-7b-chat-hf\",
    \"messages\": [{\"role\": \"user\", \"content\": \"$TEST_PROMPT\"}],
    \"max_tokens\": $MAX_TOKENS
  }" 2>&1)

echo "Response: $RESPONSE"

# Check for valid response
if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
  CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
  echo -e "${GREEN}✓ Inference test passed${NC}"
  echo "Generated content: $CONTENT"
  RESULT=0
else
  ERROR=$(echo "$RESPONSE" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null || echo "Parse error")
  echo -e "${RED}✗ Inference test failed: $ERROR${NC}"
  RESULT=1
fi

# Cleanup
echo ""
echo "Cleaning up port-forward..."
kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true

if [ $RESULT -eq 0 ]; then
  echo ""
  echo -e "${GREEN}=== ALL TESTS PASSED ===${NC}"
else
  echo ""
  echo -e "${RED}=== TESTS FAILED ===${NC}"
fi

exit $RESULT