#!/bin/bash

# API Gateway Redeployment Script
# This script forces a redeployment of the API Gateway to ensure API key configuration is active

set -e

# Configuration
STACK_NAME="meraki-webhook-processor-dev"
REGION="ap-southeast-1"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_status "🚀 API Gateway Redeployment Script"
echo ""

# Get API Gateway ID
API_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayId'].OutputValue" \
    --output text)

if [[ -z "$API_ID" ]]; then
    print_error "Could not retrieve API Gateway ID from stack"
    exit 1
fi

print_info "API Gateway ID: $API_ID"

# Create new deployment
print_status "Creating new API Gateway deployment..."
DEPLOYMENT_ID=$(aws apigateway create-deployment \
    --rest-api-id "$API_ID" \
    --stage-name "dev" \
    --stage-description "Redeployment to activate API key authentication" \
    --description "Manual redeployment $(date '+%Y-%m-%d %H:%M:%S')" \
    --region "$REGION" \
    --query "id" \
    --output text)

if [[ -n "$DEPLOYMENT_ID" ]]; then
    print_status "✅ New deployment created: $DEPLOYMENT_ID"
else
    print_error "Failed to create new deployment"
    exit 1
fi

# Wait a moment for deployment to propagate
print_info "Waiting for deployment to propagate..."
sleep 5

# Test the API key functionality
print_status "Testing API key functionality..."

# Get the API key
API_KEY=$(aws apigateway get-api-key \
    --api-key "4x5jva2cl0" \
    --include-value \
    --region "$REGION" \
    --query "value" \
    --output text)

WEBHOOK_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/dev/webhook"

echo ""
print_info "Testing webhook with API key..."
echo "URL: $WEBHOOK_URL"
echo "API Key: ${API_KEY:0:10}..."
echo ""

# Test with API key
response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "x-api-key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"alertType":"test","message":"API key test"}' \
    "$WEBHOOK_URL")

http_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n -1)

if [[ "$http_code" == "200" ]]; then
    print_status "✅ API key authentication working! (HTTP $http_code)"
    echo "Response: $response_body"
elif [[ "$http_code" == "403" ]]; then
    print_error "❌ Still getting 403 Forbidden (HTTP $http_code)"
    echo "Response: $response_body"
    echo ""
    print_info "This might indicate a CloudFormation template issue. Try updating the stack."
else
    print_warning "⚠️ Unexpected response (HTTP $http_code)"
    echo "Response: $response_body"
fi

echo ""

# Test without API key (should fail)
print_info "Testing webhook without API key (should fail)..."
response_no_key=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"alertType":"test"}' \
    "$WEBHOOK_URL")

http_code_no_key=$(echo "$response_no_key" | tail -n1)

if [[ "$http_code_no_key" == "403" ]]; then
    print_status "✅ Correctly rejecting requests without API key (HTTP $http_code_no_key)"
elif [[ "$http_code_no_key" == "200" ]]; then
    print_error "❌ API key authentication is NOT working - requests without key are succeeding"
else
    print_warning "⚠️ Unexpected response without API key (HTTP $http_code_no_key)"
fi

echo ""
print_status "🎉 Redeployment completed!"
echo ""
print_info "If you're still getting 403 errors, try:"
echo "1. Redeploy the CloudFormation stack: ./deploy-advanced.sh"
echo "2. Check CloudWatch logs for detailed error messages"
echo "3. Verify the Lambda function is properly configured"
