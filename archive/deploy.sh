#!/bin/bash

# Meraki Webhook Lambda Deployment Script
# This script deploys the CloudFormation stack and updates the Lambda function code

set -e

# Configuration
STACK_NAME="meraki-webhook-processor"
TEMPLATE_FILE="cloudformation-template.yaml"
LAMBDA_CODE_FILE="lambda.py"
ENVIRONMENT="dev"
REGION="us-east-1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Function to check if AWS CLI is configured
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install AWS CLI first."
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI not configured or credentials invalid. Please run 'aws configure' first."
        exit 1
    fi
    
    print_status "AWS CLI configured successfully"
}

# Function to validate required files
validate_files() {
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        print_error "CloudFormation template file not found: $TEMPLATE_FILE"
        exit 1
    fi
    
    if [[ ! -f "$LAMBDA_CODE_FILE" ]]; then
        print_error "Lambda code file not found: $LAMBDA_CODE_FILE"
        exit 1
    fi
    
    print_status "Required files validated"
}

# Function to get user inputs
get_user_inputs() {
    echo "Please provide the following configuration values:"
    echo "Press Enter to skip optional parameters (they can be updated later)"
    echo ""
    
    read -p "Google Chat Webhook URL (optional): " GOOGLE_CHAT_WEBHOOK_URL
    read -p "SES Sender Email (required for email notifications): " SES_SENDER_EMAIL
    read -p "SES Recipient Emails (comma-separated): " SES_RECIPIENT_EMAILS
    read -p "Environment (dev/staging/prod) [${ENVIRONMENT}]: " ENV_INPUT
    read -p "AWS Region [${REGION}]: " REGION_INPUT
    read -p "Stack Name [${STACK_NAME}]: " STACK_INPUT
    
    # Use defaults if empty
    ENVIRONMENT=${ENV_INPUT:-$ENVIRONMENT}
    REGION=${REGION_INPUT:-$REGION}
    STACK_NAME=${STACK_INPUT:-$STACK_NAME}
    
    # Add environment suffix to stack name
    STACK_NAME="${STACK_NAME}-${ENVIRONMENT}"
    
    print_status "Configuration collected"
}

# Function to validate SES email if provided
validate_ses_email() {
    if [[ -n "$SES_SENDER_EMAIL" ]]; then
        print_status "Checking SES email verification status..."
        
        # Check if email is verified in SES
        VERIFIED=$(aws ses get-identity-verification-attributes \
            --identities "$SES_SENDER_EMAIL" \
            --region "$REGION" \
            --query "VerificationAttributes.\"$SES_SENDER_EMAIL\".VerificationStatus" \
            --output text 2>/dev/null || echo "NotFound")
        
        if [[ "$VERIFIED" != "Success" ]]; then
            print_warning "Email $SES_SENDER_EMAIL is not verified in SES"
            print_warning "You may need to verify it before email notifications work"
            print_warning "Run: aws ses verify-email-identity --email-address $SES_SENDER_EMAIL --region $REGION"
        else
            print_status "SES email verified successfully"
        fi
    fi
}

# Function to check if stack exists
stack_exists() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" &> /dev/null
}

# Function to deploy CloudFormation stack
deploy_stack() {
    local action
    if stack_exists; then
        action="update-stack"
        print_status "Updating existing CloudFormation stack: $STACK_NAME"
    else
        action="create-stack"
        print_status "Creating new CloudFormation stack: $STACK_NAME"
    fi
    
    # Build parameters
    local params="ParameterKey=Environment,ParameterValue=$ENVIRONMENT"
    
    if [[ -n "$GOOGLE_CHAT_WEBHOOK_URL" ]]; then
        params="$params ParameterKey=GoogleChatWebhookUrl,ParameterValue=$GOOGLE_CHAT_WEBHOOK_URL"
    fi
    
    if [[ -n "$SES_SENDER_EMAIL" ]]; then
        params="$params ParameterKey=SenderEmail,ParameterValue=$SES_SENDER_EMAIL"
    fi
    
    if [[ -n "$SES_RECIPIENT_EMAILS" ]]; then
        params="$params ParameterKey=RecipientEmails,ParameterValue=$SES_RECIPIENT_EMAILS"
    fi
    
    # Deploy stack
    aws cloudformation $action \
        --stack-name "$STACK_NAME" \
        --template-body file://"$TEMPLATE_FILE" \
        --parameters $params \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"
    
    print_status "Waiting for stack deployment to complete..."
    
    # Wait for stack operation to complete
    if [[ "$action" == "create-stack" ]]; then
        aws cloudformation wait stack-create-complete \
            --stack-name "$STACK_NAME" \
            --region "$REGION"
    else
        aws cloudformation wait stack-update-complete \
            --stack-name "$STACK_NAME" \
            --region "$REGION"
    fi
    
    print_status "Stack deployment completed successfully"
}

# Function to get Lambda function name from stack
get_lambda_function_name() {
    LAMBDA_FUNCTION_NAME=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionName'].OutputValue" \
        --output text)
    
    if [[ -z "$LAMBDA_FUNCTION_NAME" ]]; then
        print_error "Could not retrieve Lambda function name from stack"
        exit 1
    fi
    
    print_status "Lambda function name: $LAMBDA_FUNCTION_NAME"
}

# Function to update Lambda function code
update_lambda_code() {
    print_status "Creating deployment package..."
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    
    # Copy Lambda code
    cp "$LAMBDA_CODE_FILE" "$TEMP_DIR/"
    
    # Create deployment package
    cd "$TEMP_DIR"
    zip -r "../lambda-deployment.zip" .
    cd - > /dev/null
    
    # Update Lambda function
    print_status "Updating Lambda function code..."
    aws lambda update-function-code \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --zip-file fileb://lambda-deployment.zip \
        --region "$REGION"
    
    # Wait for update to complete
    print_status "Waiting for function update to complete..."
    aws lambda wait function-updated \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$REGION"
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    rm -f lambda-deployment.zip
    
    print_status "Lambda function code updated successfully"
}

# Function to display stack outputs
display_outputs() {
    print_status "Retrieving stack outputs..."
    
    WEBHOOK_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='WebhookApiUrl'].OutputValue" \
        --output text)
    
    API_GATEWAY_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='ApiGatewayUrl'].OutputValue" \
        --output text)
    
    LOG_GROUP=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='CloudWatchLogGroup'].OutputValue" \
        --output text)
    
    echo ""
    echo "=================================================="
    echo "           DEPLOYMENT COMPLETED"
    echo "=================================================="
    echo ""
    echo "Webhook URL: $WEBHOOK_URL"
    echo "API Gateway Base URL: $API_GATEWAY_URL"
    echo "Lambda Function: $LAMBDA_FUNCTION_NAME"
    echo "CloudWatch Logs: $LOG_GROUP"
    echo "AWS Region: $REGION"
    echo ""
    echo "Next Steps:"
    echo "1. Configure your Meraki dashboard to send webhooks to: $WEBHOOK_URL"
    echo "2. Test the webhook endpoint"
    echo "3. Monitor logs in CloudWatch: $LOG_GROUP"
    echo ""
    if [[ -n "$SES_SENDER_EMAIL" ]]; then
        echo "Email notifications configured with sender: $SES_SENDER_EMAIL"
    else
        echo "To enable email notifications, update the stack with SES_SENDER_EMAIL parameter"
    fi
    echo ""
}

# Function to test webhook endpoint
test_webhook() {
    read -p "Would you like to test the webhook endpoint? (y/n): " TEST_WEBHOOK
    
    if [[ "$TEST_WEBHOOK" =~ ^[Yy]$ ]]; then
        print_status "Testing webhook endpoint..."
        
        # Create test payload
        cat > test-payload.json << EOF
{
    "alertType": "sensor_change_detected",
    "organizationName": "Test Organization",
    "networkName": "Test Network",
    "alertData": {
        "sensorType": "temperature",
        "value": 75.5,
        "threshold": 70.0
    }
}
EOF
        
        # Test the endpoint
        HTTP_STATUS=$(curl -s -o test-response.json -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d @test-payload.json \
            "$WEBHOOK_URL")
        
        if [[ "$HTTP_STATUS" == "200" ]]; then
            print_status "Webhook test successful! (HTTP $HTTP_STATUS)"
            echo "Response:"
            cat test-response.json | python3 -m json.tool
        else
            print_error "Webhook test failed! (HTTP $HTTP_STATUS)"
            echo "Response:"
            cat test-response.json
        fi
        
        # Cleanup test files
        rm -f test-payload.json test-response.json
    fi
}

# Main execution
main() {
    echo "========================================"
    echo "    Meraki Webhook Lambda Deployer"
    echo "========================================"
    echo ""
    
    check_aws_cli
    validate_files
    get_user_inputs
    validate_ses_email
    
    echo ""
    print_status "Starting deployment process..."
    
    deploy_stack
    get_lambda_function_name
    update_lambda_code
    display_outputs
    test_webhook
    
    print_status "Deployment process completed!"
}

# Handle script interruption
trap 'print_error "Script interrupted"; exit 1' INT

# Run main function
main "$@"
