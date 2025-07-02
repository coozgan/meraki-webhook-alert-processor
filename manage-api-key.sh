#!/bin/bash

# AWS Lambda Webhook API Key Management Script
# This script helps manage API keys for the Meraki webhook API Gateway

set -e

# Configuration
STACK_NAME=""
REGION=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print functions
print_status() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_header() {
    echo -e "${BOLD}${BLUE}$1${NC}"
}

# Function to show usage
show_usage() {
    echo "AWS Lambda Webhook API Key Management"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  get         Get the current API key value"
    echo "  regenerate  Create a new API key (deactivates old one)"
    echo "  test        Test the webhook with the API key"
    echo "  status      Show API key status and information"
    echo ""
    echo "Options:"
    echo "  -s, --stack-name    CloudFormation stack name (required)"
    echo "  -r, --region        AWS region (required)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 get -s my-webhook-stack -r us-east-1"
    echo "  $0 regenerate -s my-webhook-stack -r us-east-1"
    echo "  $0 test -s my-webhook-stack -r us-east-1"
    echo ""
}

# Function to get stack outputs
get_stack_output() {
    local output_key="$1"
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text 2>/dev/null || echo ""
}

# Function to check if API key is configured
check_api_key_configured() {
    local api_key_id=$(get_stack_output "WebhookApiKeyId")
    if [[ -z "$api_key_id" || "$api_key_id" == "None" ]]; then
        print_error "API Key authentication is not enabled for this stack."
        print_status "To enable API key authentication, redeploy the stack with EnableApiKey=true"
        exit 1
    fi
}

# Function to get API key value
get_api_key() {
    print_header "🔑 Getting API Key Value"
    
    check_api_key_configured
    
    local api_key_id=$(get_stack_output "WebhookApiKeyId")
    local api_key_command=$(get_stack_output "ApiKeyRetrievalCommand")
    
    print_status "API Key ID: $api_key_id"
    print_status "Retrieving API key value..."
    
    local api_key_value
    api_key_value=$(aws apigateway get-api-key \
        --api-key "$api_key_id" \
        --include-value \
        --region "$REGION" \
        --query "value" \
        --output text 2>/dev/null)
    
    if [[ -n "$api_key_value" ]]; then
        print_success "API Key retrieved successfully!"
        echo ""
        echo "API Key Value: $api_key_value"
        echo ""
        print_warning "⚠️  Keep this key secure! Do not share it in logs or version control."
    else
        print_error "Failed to retrieve API key value"
        exit 1
    fi
}

# Function to regenerate API key
regenerate_api_key() {
    print_header "🔄 Regenerating API Key"
    
    check_api_key_configured
    
    local api_key_id=$(get_stack_output "WebhookApiKeyId")
    
    print_status "Current API Key ID: $api_key_id"
    print_warning "This will generate a new API key value and invalidate the old one."
    
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Operation cancelled."
        exit 0
    fi
    
    print_status "Generating new API key value..."
    
    # Generate new API key value
    local new_key_value
    new_key_value=$(aws apigateway update-api-key \
        --api-key "$api_key_id" \
        --patch-ops "op=replace,path=/value,value=$(openssl rand -base64 32)" \
        --region "$REGION" \
        --query "value" \
        --output text 2>/dev/null)
    
    if [[ -n "$new_key_value" ]]; then
        print_success "API Key regenerated successfully!"
        echo ""
        echo "New API Key Value: $new_key_value"
        echo ""
        print_warning "⚠️  Update your webhook configurations with the new key!"
        print_warning "⚠️  The old key is no longer valid."
    else
        print_error "Failed to regenerate API key"
        exit 1
    fi
}

# Function to test webhook
test_webhook() {
    print_header "🧪 Testing Webhook"
    
    local webhook_url=$(get_stack_output "WebhookApiUrl")
    if [[ -z "$webhook_url" ]]; then
        print_error "Could not retrieve webhook URL from stack outputs"
        exit 1
    fi
    
    print_status "Webhook URL: $webhook_url"
    
    # Check if API key is configured
    local api_key_id=$(get_stack_output "WebhookApiKeyId")
    local test_command=""
    
    if [[ -n "$api_key_id" && "$api_key_id" != "None" ]]; then
        print_status "API Key authentication is enabled. Getting API key..."
        
        local api_key_value
        api_key_value=$(aws apigateway get-api-key \
            --api-key "$api_key_id" \
            --include-value \
            --region "$REGION" \
            --query "value" \
            --output text 2>/dev/null)
        
        if [[ -n "$api_key_value" ]]; then
            test_command="curl -X POST -H \"x-api-key: $api_key_value\" -H \"Content-Type: application/json\" -d '{\"alertType\":\"test\",\"organizationId\":\"123456\",\"networkId\":\"N_123456\",\"deviceSerial\":\"Q2XX-XXXX-XXXX\"}' \"$webhook_url\""
        else
            print_error "Failed to retrieve API key for testing"
            exit 1
        fi
    else
        print_status "API Key authentication is disabled."
        test_command="curl -X POST -H \"Content-Type: application/json\" -d '{\"alertType\":\"test\",\"organizationId\":\"123456\",\"networkId\":\"N_123456\",\"deviceSerial\":\"Q2XX-XXXX-XXXX\"}' \"$webhook_url\""
    fi
    
    print_status "Sending test request..."
    echo ""
    echo "Test Command:"
    echo "$test_command"
    echo ""
    
    # Execute the test
    local response
    response=$(eval "$test_command" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        print_success "Test request sent successfully!"
        echo "Response: $response"
    else
        print_error "Test request failed!"
        echo "Error: $response"
        exit 1
    fi
    
    print_status "Check CloudWatch logs for processing details:"
    local log_group=$(get_stack_output "CloudWatchLogGroup")
    if [[ -n "$log_group" ]]; then
        echo "aws logs tail $log_group --follow --region $REGION"
    fi
}

# Function to show API key status
show_status() {
    print_header "📊 API Key Status"
    
    local webhook_url=$(get_stack_output "WebhookApiUrl")
    local api_key_id=$(get_stack_output "WebhookApiKeyId")
    local usage_example=$(get_stack_output "WebhookUsageExample")
    
    print_status "Stack Name: $STACK_NAME"
    print_status "Region: $REGION"
    print_status "Webhook URL: $webhook_url"
    echo ""
    
    if [[ -n "$api_key_id" && "$api_key_id" != "None" ]]; then
        print_success "API Key Authentication: ENABLED"
        print_status "API Key ID: $api_key_id"
        
        # Check if key exists and is enabled
        local key_info
        key_info=$(aws apigateway get-api-key \
            --api-key "$api_key_id" \
            --region "$REGION" \
            --query "{Name:name,Id:id,Enabled:enabled,CreatedDate:createdDate}" \
            --output table 2>/dev/null || echo "")
        
        if [[ -n "$key_info" ]]; then
            echo ""
            echo "$key_info"
        fi
        
        echo ""
        print_status "Usage Example:"
        echo "$usage_example"
    else
        print_warning "API Key Authentication: DISABLED"
        print_status "The webhook is publicly accessible without authentication."
        echo ""
        print_status "Usage Example:"
        echo "$usage_example"
    fi
}

# Parse command line arguments
COMMAND=""
while [[ $# -gt 0 ]]; do
    case $1 in
        get|regenerate|test|status)
            COMMAND="$1"
            shift
            ;;
        --stack-name|-s)
            STACK_NAME="$2"
            shift 2
            ;;
        --region|-r)
            REGION="$2"
            shift 2
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$COMMAND" ]]; then
    print_error "Command is required"
    show_usage
    exit 1
fi

if [[ -z "$STACK_NAME" ]]; then
    print_error "Stack name is required"
    show_usage
    exit 1
fi

if [[ -z "$REGION" ]]; then
    print_error "Region is required"
    show_usage
    exit 1
fi

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is required but not installed"
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity --region "$REGION" &> /dev/null; then
    print_error "AWS credentials not configured or invalid for region $REGION"
    exit 1
fi

# Verify stack exists
if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null; then
    print_error "CloudFormation stack '$STACK_NAME' not found in region '$REGION'"
    exit 1
fi

# Execute command
case $COMMAND in
    get)
        get_api_key
        ;;
    regenerate)
        regenerate_api_key
        ;;
    test)
        test_webhook
        ;;
    status)
        show_status
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        show_usage
        exit 1
        ;;
esac

print_success "Operation completed successfully!"
