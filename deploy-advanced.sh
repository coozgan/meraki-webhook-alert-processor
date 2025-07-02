#!/bin/bash

# Advanced Meraki Webhook Lambda Deployment Script
# This script handles dependencies and creates a proper deployment package

set -e

# Configuration
STACK_NAME="meraki-webhook-processor"
TEMPLATE_FILE="cloudformation-template.yaml"
LAMBDA_CODE_FILE="lambda.py"
REQUIREMENTS_FILE="requirements.txt"
ENVIRONMENT="dev"
REGION="us-east-1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install AWS CLI first."
        exit 1
    fi
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        print_error "Python 3 not found. Please install Python 3 first."
        exit 1
    fi
    
    # Check pip
    if ! command -v pip3 &> /dev/null; then
        print_error "pip3 not found. Please install pip3 first."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI not configured or credentials invalid. Please run 'aws configure' first."
        exit 1
    fi
    
    print_status "Prerequisites check completed"
}

# Function to validate required files
validate_files() {
    print_status "Validating required files..."
    
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        print_error "CloudFormation template file not found: $TEMPLATE_FILE"
        exit 1
    fi
    
    if [[ ! -f "$LAMBDA_CODE_FILE" ]]; then
        print_error "Lambda code file not found: $LAMBDA_CODE_FILE"
        exit 1
    fi
    
    if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
        print_warning "Requirements file not found: $REQUIREMENTS_FILE"
        print_info "Creating basic requirements.txt..."
        cat > "$REQUIREMENTS_FILE" << EOF
boto3>=1.34.0
botocore>=1.34.0
urllib3>=2.0.0
EOF
    fi
    
    print_status "File validation completed"
}

# Function to get user configuration
get_configuration() {
    echo ""
    echo "=========================================="
    echo "          CONFIGURATION SETUP"
    echo "=========================================="
    echo ""
    
    # Read configuration from file if exists
    CONFIG_FILE=".deployment-config"
    if [[ -f "$CONFIG_FILE" ]]; then
        print_info "Loading previous configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
    fi
    
    echo "Current configuration (press Enter to keep existing values):"
    echo ""
    
    read -p "Environment (dev/staging/prod) [${ENVIRONMENT}]: " ENV_INPUT
    read -p "AWS Region [${REGION}]: " REGION_INPUT
    read -p "Stack Name [${STACK_NAME}]: " STACK_INPUT
    echo ""
    read -p "Google Chat Webhook URL [${GOOGLE_CHAT_WEBHOOK_URL:-}]: " GOOGLE_CHAT_INPUT
    read -p "SES Sender Email [${SES_SENDER_EMAIL:-}]: " SES_SENDER_INPUT
    read -p "SES Recipient Emails (comma-separated) [${SES_RECIPIENT_EMAILS:-}]: " SES_RECIPIENTS_INPUT
    echo ""
    read -p "Custom Bedrock Model ID (leave empty for auto-selection) [${BEDROCK_MODEL_ID:-}]: " BEDROCK_MODEL_INPUT
    
    # Use input or keep existing values
    ENVIRONMENT=${ENV_INPUT:-$ENVIRONMENT}
    REGION=${REGION_INPUT:-$REGION}
    STACK_NAME=${STACK_INPUT:-$STACK_NAME}
    GOOGLE_CHAT_WEBHOOK_URL=${GOOGLE_CHAT_INPUT:-$GOOGLE_CHAT_WEBHOOK_URL}
    SES_SENDER_EMAIL=${SES_SENDER_INPUT:-$SES_SENDER_EMAIL}
    SES_RECIPIENT_EMAILS=${SES_RECIPIENTS_INPUT:-$SES_RECIPIENT_EMAILS}
    BEDROCK_MODEL_ID=${BEDROCK_MODEL_INPUT:-$BEDROCK_MODEL_ID}
    
    # Add environment suffix to stack name if not already present
    if [[ ! "$STACK_NAME" =~ -${ENVIRONMENT}$ ]]; then
        STACK_NAME="${STACK_NAME}-${ENVIRONMENT}"
    fi
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
ENVIRONMENT="$ENVIRONMENT"
REGION="$REGION"
STACK_NAME="$STACK_NAME"
GOOGLE_CHAT_WEBHOOK_URL="$GOOGLE_CHAT_WEBHOOK_URL"
SES_SENDER_EMAIL="$SES_SENDER_EMAIL"
SES_RECIPIENT_EMAILS="$SES_RECIPIENT_EMAILS"
BEDROCK_MODEL_ID="$BEDROCK_MODEL_ID"
EOF
    
    print_status "Configuration saved to $CONFIG_FILE"
}

# Function to create deployment package
create_deployment_package() {
    print_status "Creating deployment package..."
    
    # Create build directory
    BUILD_DIR="build"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    
    # Copy Lambda code
    cp "$LAMBDA_CODE_FILE" "$BUILD_DIR/"
    
    # Install dependencies if requirements.txt has content
    if [[ -s "$REQUIREMENTS_FILE" ]]; then
        print_status "Installing Python dependencies..."
        pip3 install -r "$REQUIREMENTS_FILE" -t "$BUILD_DIR/" --no-deps --quiet
        
        # Remove unnecessary files to reduce package size
        find "$BUILD_DIR" -name "*.pyc" -delete
        find "$BUILD_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
        find "$BUILD_DIR" -name "*.dist-info" -type d -exec rm -rf {} + 2>/dev/null || true
        find "$BUILD_DIR" -name "tests" -type d -exec rm -rf {} + 2>/dev/null || true
    fi
    
    # Create ZIP file
    DEPLOYMENT_PACKAGE="lambda-deployment.zip"
    cd "$BUILD_DIR"
    zip -r "../$DEPLOYMENT_PACKAGE" . -q
    cd ..
    
    # Get package size
    PACKAGE_SIZE=$(ls -lah "$DEPLOYMENT_PACKAGE" | awk '{print $5}')
    print_status "Deployment package created: $DEPLOYMENT_PACKAGE ($PACKAGE_SIZE)"
    
    # Check package size warning
    PACKAGE_SIZE_BYTES=$(stat -f%z "$DEPLOYMENT_PACKAGE" 2>/dev/null || stat -c%s "$DEPLOYMENT_PACKAGE")
    if [[ $PACKAGE_SIZE_BYTES -gt 52428800 ]]; then  # 50MB
        print_warning "Package size exceeds 50MB. Consider using Lambda layers for large dependencies."
    fi
}

# Function to validate SES configuration
validate_ses_configuration() {
    if [[ -n "$SES_SENDER_EMAIL" ]]; then
        print_status "Validating SES configuration..."
        
        # Check if SES is available in the region
        if ! aws ses describe-configuration-sets --region "$REGION" &>/dev/null; then
            print_warning "SES might not be available in region $REGION"
            print_info "Common SES regions: us-east-1, us-west-2, eu-west-1"
        fi
        
        # Check email verification status
        VERIFICATION_STATUS=$(aws ses get-identity-verification-attributes \
            --identities "$SES_SENDER_EMAIL" \
            --region "$REGION" \
            --query "VerificationAttributes.\"$SES_SENDER_EMAIL\".VerificationStatus" \
            --output text 2>/dev/null || echo "NotFound")
        
        case "$VERIFICATION_STATUS" in
            "Success")
                print_status "SES email verification: ✓ Verified"
                ;;
            "Pending")
                print_warning "SES email verification: ⏳ Pending"
                print_info "Check your email for verification link"
                ;;
            "Failed"|"NotFound")
                print_warning "SES email verification: ❌ Not verified"
                print_info "Run: aws ses verify-email-identity --email-address '$SES_SENDER_EMAIL' --region '$REGION'"
                ;;
        esac
    fi
}

# Function to check if stack exists
stack_exists() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" &>/dev/null
}

# Function to deploy CloudFormation stack
deploy_cloudformation() {
    print_status "Deploying CloudFormation stack..."
    
    local action
    if stack_exists; then
        action="update-stack"
        print_info "Updating existing stack: $STACK_NAME"
    else
        action="create-stack"
        print_info "Creating new stack: $STACK_NAME"
    fi
    
    # Prepare parameters
    local params=""
    params+="ParameterKey=Environment,ParameterValue=$ENVIRONMENT"
    
    if [[ -n "$GOOGLE_CHAT_WEBHOOK_URL" ]]; then
        params+=" ParameterKey=GoogleChatWebhookUrl,ParameterValue=$GOOGLE_CHAT_WEBHOOK_URL"
    fi
    
    if [[ -n "$SES_SENDER_EMAIL" ]]; then
        params+=" ParameterKey=SenderEmail,ParameterValue=$SES_SENDER_EMAIL"
    fi
    
    if [[ -n "$SES_RECIPIENT_EMAILS" ]]; then
        params+=" ParameterKey=RecipientEmails,ParameterValue=$SES_RECIPIENT_EMAILS"
    fi
    
    if [[ -n "$BEDROCK_MODEL_ID" ]]; then
        params+=" ParameterKey=BedrockModelId,ParameterValue=$BEDROCK_MODEL_ID"
    fi
    
    # Deploy stack
    aws cloudformation $action \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters $params \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" \
        --no-cli-pager
    
    print_status "Waiting for CloudFormation operation to complete..."
    
    # Wait for completion with timeout
    local wait_start=$(date +%s)
    local timeout=1800  # 30 minutes
    
    if [[ "$action" == "create-stack" ]]; then
        aws cloudformation wait stack-create-complete \
            --stack-name "$STACK_NAME" \
            --region "$REGION" &
    else
        aws cloudformation wait stack-update-complete \
            --stack-name "$STACK_NAME" \
            --region "$REGION" &
    fi
    
    local wait_pid=$!
    
    # Monitor progress
    while kill -0 $wait_pid 2>/dev/null; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - wait_start))
        
        if [[ $elapsed -gt $timeout ]]; then
            kill $wait_pid 2>/dev/null || true
            print_error "Timeout waiting for CloudFormation operation"
            exit 1
        fi
        
        echo -ne "\rWaiting... ${elapsed}s elapsed"
        sleep 5
    done
    echo ""
    
    wait $wait_pid
    local wait_result=$?
    
    if [[ $wait_result -ne 0 ]]; then
        print_error "CloudFormation operation failed"
        print_info "Check AWS Console for detailed error information"
        exit 1
    fi
    
    print_status "CloudFormation deployment completed"
}

# Function to update Lambda function code
update_lambda_function() {
    print_status "Updating Lambda function code..."
    
    # Get Lambda function name from stack outputs
    LAMBDA_FUNCTION_NAME=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionName'].OutputValue" \
        --output text)
    
    if [[ -z "$LAMBDA_FUNCTION_NAME" ]]; then
        print_error "Could not retrieve Lambda function name from stack"
        exit 1
    fi
    
    # Update function code
    aws lambda update-function-code \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --zip-file fileb://"$DEPLOYMENT_PACKAGE" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
    
    # Wait for update to complete
    print_status "Waiting for function update..."
    aws lambda wait function-updated \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$REGION"
    
    print_status "Lambda function updated successfully"
}

# Function to run post-deployment tests
run_tests() {
    print_status "Running post-deployment tests..."
    
    # Get stack outputs
    WEBHOOK_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='WebhookApiUrl'].OutputValue" \
        --output text)
    
    if [[ -z "$WEBHOOK_URL" ]]; then
        print_error "Could not retrieve webhook URL from stack"
        return 1
    fi
    
    # Test 1: Basic connectivity
    print_info "Testing basic connectivity..."
    if curl -s -f -X OPTIONS "$WEBHOOK_URL" > /dev/null; then
        print_status "✓ Basic connectivity test passed"
    else
        print_warning "✗ Basic connectivity test failed"
    fi
    
    # Test 2: POST request with test payload
    print_info "Testing webhook with sample payload..."
    
    cat > test-payload.json << EOF
{
    "alertType": "test_alert",
    "organizationName": "Test Organization",
    "networkName": "Test Network",
    "alertData": {
        "message": "Deployment test alert"
    }
}
EOF
    
    local response=$(curl -s -w "%{http_code}" -o test-response.json \
        -X POST \
        -H "Content-Type: application/json" \
        -d @test-payload.json \
        "$WEBHOOK_URL")
    
    if [[ "$response" == "200" ]]; then
        print_status "✓ Webhook test passed (HTTP 200)"
    else
        print_warning "✗ Webhook test failed (HTTP $response)"
        print_info "Response content:"
        cat test-response.json 2>/dev/null || echo "No response content"
    fi
    
    # Cleanup test files
    rm -f test-payload.json test-response.json
}

# Function to display deployment summary
display_summary() {
    echo ""
    echo "=========================================="
    echo "         DEPLOYMENT SUMMARY"
    echo "=========================================="
    echo ""
    
    # Get all stack outputs
    local outputs=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs" \
        --output table)
    
    echo "Stack Outputs:"
    echo "$outputs"
    echo ""
    
    # Get specific URLs
    WEBHOOK_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='WebhookApiUrl'].OutputValue" \
        --output text)
    
    LOG_GROUP=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='CloudWatchLogGroup'].OutputValue" \
        --output text)
    
    BEDROCK_MODEL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='BedrockModelId'].OutputValue" \
        --output text)
    
    SUPPORTED_MODELS=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='SupportedModels'].OutputValue" \
        --output text)
    
    # Get API key information if available
    API_KEY_ID=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='WebhookApiKeyId'].OutputValue" \
        --output text 2>/dev/null || echo "")
    
    API_KEY_COMMAND=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='ApiKeyRetrievalCommand'].OutputValue" \
        --output text 2>/dev/null || echo "")
    
    USAGE_EXAMPLE=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='WebhookUsageExample'].OutputValue" \
        --output text 2>/dev/null || echo "")
    
    echo "Key Information:"
    echo "• Webhook URL: $WEBHOOK_URL"
    echo "• Lambda Function: $LAMBDA_FUNCTION_NAME"
    echo "• CloudWatch Logs: $LOG_GROUP"
    echo "• AWS Region: $REGION"
    echo "• Environment: $ENVIRONMENT"
    echo "• Bedrock Model: $BEDROCK_MODEL"
    echo ""
    
    echo "Model Information:"
    echo "• Active Model: $BEDROCK_MODEL"
    echo "• $SUPPORTED_MODELS"
    echo ""
    
    # Display API Key information if enabled
    if [[ -n "$API_KEY_ID" && "$API_KEY_ID" != "None" ]]; then
        echo "Security Information:"
        echo "• API Key Authentication: ENABLED ✓"
        echo "• API Key ID: $API_KEY_ID"
        echo ""
        echo "To get your API Key value:"
        echo "$API_KEY_COMMAND"
        echo ""
        echo "Usage Example:"
        echo "$USAGE_EXAMPLE"
        echo ""
    else
        echo "Security Information:"
        echo "• API Key Authentication: DISABLED"
        echo "• Note: Webhook is publicly accessible"
        echo ""
        echo "Usage Example:"
        echo "$USAGE_EXAMPLE"
        echo ""
    fi
    
    echo "Management Commands:"
    if [[ -n "$API_KEY_ID" && "$API_KEY_ID" != "None" ]]; then
        echo "• Get API Key: $API_KEY_COMMAND"
        echo "• Monitor logs: aws logs tail $LOG_GROUP --follow --region $REGION"
        echo "• Test webhook: Use the curl command above with your API key"
    else
        echo "• Monitor logs: aws logs tail $LOG_GROUP --follow --region $REGION"
        echo "• Test webhook: $USAGE_EXAMPLE"
    fi
    echo ""
    
    if [[ -n "$SES_SENDER_EMAIL" ]]; then
        echo "Email notifications: Configured ✓"
    else
        echo "Email notifications: Not configured (update stack to enable)"
    fi
    
    if [[ -n "$GOOGLE_CHAT_WEBHOOK_URL" ]]; then
        echo "Google Chat notifications: Configured ✓"
    else
        echo "Google Chat notifications: Not configured (update stack to enable)"
    fi
    echo ""
}

# Function to cleanup temporary files
cleanup() {
    print_status "Cleaning up temporary files..."
    rm -rf build/
    rm -f lambda-deployment.zip
    rm -f test-*.json
}

# Main execution function
main() {
    echo "=============================================="
    echo "    MERAKI WEBHOOK LAMBDA DEPLOYER v2.0"
    echo "=============================================="
    echo ""
    
    # Run all deployment steps
    check_prerequisites
    validate_files
    get_configuration
    validate_ses_configuration
    create_deployment_package
    deploy_cloudformation
    update_lambda_function
    run_tests
    display_summary
    cleanup
    
    print_status "🎉 Deployment completed successfully!"
}

# Handle interruption
trap 'print_error "Deployment interrupted"; cleanup; exit 1' INT TERM

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --environment|-e)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --region|-r)
            REGION="$2"
            shift 2
            ;;
        --stack-name|-s)
            STACK_NAME="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -e, --environment    Environment (dev/staging/prod)"
            echo "  -r, --region         AWS region"
            echo "  -s, --stack-name     CloudFormation stack name"
            echo "  -h, --help           Show this help message"
            echo ""
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Run main function
main "$@"
