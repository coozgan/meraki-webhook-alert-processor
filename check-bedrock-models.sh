#!/bin/bash

# Bedrock Model Availability Checker
# This script checks which Claude models are available in your AWS region

set -e

# Prevent AWS CLI from using pager
export AWS_PAGER=""

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

# Check for required tools
check_prerequisites() {
    local missing_tools=()
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Please install the missing tools:"
        for tool in "${missing_tools[@]}"; do
            case $tool in
                aws)
                    echo "• AWS CLI: https://aws.amazon.com/cli/"
                    echo "  macOS: brew install awscli"
                    echo "  Ubuntu/Debian: sudo apt-get install awscli"
                    ;;
                jq)
                    echo "• jq: https://stedolan.github.io/jq/"
                    echo "  macOS: brew install jq"
                    echo "  Ubuntu/Debian: sudo apt-get install jq"
                    ;;
            esac
        done
        exit 1
    fi
}

# Check prerequisites first
check_prerequisites

# Get current region
REGION=${1:-$(aws configure get region)}
if [[ -z "$REGION" ]]; then
    REGION="us-east-1"
    print_warning "No region specified, using default: $REGION"
fi

print_status "Checking Bedrock model availability in region: $REGION"
echo ""

# Get all available Claude models dynamically
echo "Retrieving available Claude models..."
echo "=============================="

# Get all available Claude models from AWS Bedrock
print_status "Fetching available models from AWS Bedrock..."
available_models=()

# Get all foundation models and filter for Anthropic
if ! aws bedrock list-foundation-models --region "$REGION" >/dev/null 2>&1; then
    print_error "Failed to list foundation models. Check your AWS credentials and region."
    exit 1
fi

# Get all Claude models available in the region
all_claude_models=$(aws bedrock list-foundation-models \
    --region "$REGION" \
    --query 'modelSummaries[?contains(modelId, `anthropic`)].modelId' \
    --output text 2>/dev/null)

if [[ -z "$all_claude_models" ]]; then
    print_error "No Claude models found in region $REGION"
    exit 1
fi

# Convert to array
IFS=$'\t' read -ra CLAUDE_MODELS <<< "$all_claude_models"

echo "Found ${#CLAUDE_MODELS[@]} Claude models in region $REGION"
echo ""

# Check each model and get additional details
for model in "${CLAUDE_MODELS[@]}"; do
    echo -n "Checking $model... "
    
    # Get model details
    model_details=$(aws bedrock get-foundation-model \
        --model-identifier "$model" \
        --region "$REGION" \
        --output json 2>/dev/null)
    
    if [[ $? -eq 0 ]]; then
        # Extract model information
        model_name=$(echo "$model_details" | jq -r '.modelDetails.modelName // "N/A"')
        input_modalities=$(echo "$model_details" | jq -r '.modelDetails.inputModalities[]? // "N/A"' | tr '\n' ',' | sed 's/,$//')
        output_modalities=$(echo "$model_details" | jq -r '.modelDetails.outputModalities[]? // "N/A"' | tr '\n' ',' | sed 's/,$//')
        
        echo -e "${GREEN}✓ Available${NC}"
        echo "    Name: $model_name"
        echo "    Input: $input_modalities"
        echo "    Output: $output_modalities"
        
        available_models+=("$model")
    else
        echo -e "${RED}✗ Not Available${NC}"
    fi
    echo ""
done

echo ""
echo "=============================="
echo "Summary for region: $REGION"
echo "=============================="

if [[ ${#available_models[@]} -gt 0 ]]; then
    echo -e "${GREEN}Available Claude Models (${#available_models[@]}):${NC}"
    for model in "${available_models[@]}"; do
        echo "  ✓ $model"
    done
    echo ""
    
    # Recommend the best model based on hierarchy
    recommended_model=""
    
    # Priority order: Claude-4 (Sonnet > Opus) > Claude-3.7 > Claude-3.5-Sonnet > Claude-3-Sonnet > Claude-3-Haiku > Others
    for model in "${available_models[@]}"; do
        if [[ "$model" == *"claude-sonnet-4"* ]]; then
            recommended_model="$model"
            break
        fi
    done
    
    if [[ -z "$recommended_model" ]]; then
        for model in "${available_models[@]}"; do
            if [[ "$model" == *"claude-opus-4"* ]]; then
                recommended_model="$model"
                break
            fi
        done
    fi
    
    if [[ -z "$recommended_model" ]]; then
        for model in "${available_models[@]}"; do
            if [[ "$model" == *"claude-3-7-sonnet"* ]]; then
                recommended_model="$model"
                break
            fi
        done
    fi
    
    if [[ -z "$recommended_model" ]]; then
        for model in "${available_models[@]}"; do
            if [[ "$model" == *"claude-3-5-sonnet"* ]]; then
                recommended_model="$model"
                break
            fi
        done
    fi
    
    if [[ -z "$recommended_model" ]]; then
        for model in "${available_models[@]}"; do
            if [[ "$model" == *"claude-3-haiku"* ]]; then
                recommended_model="$model"
                break
            fi
        done
    fi
    
    # If still no recommendation, pick the first available
    if [[ -z "$recommended_model" ]]; then
        recommended_model="${available_models[0]}"
    fi
    
    if [[ -n "$recommended_model" ]]; then
        echo -e "${BLUE}Recommended Model:${NC} $recommended_model"
        echo ""
    fi
else
    echo -e "${RED}No Claude models are available in this region!${NC}"
    echo ""
fi

# Check if Bedrock is available in the region at all
print_info "Checking if Bedrock service is available in $REGION..."
if aws bedrock list-foundation-models --region "$REGION" >/dev/null 2>&1; then
    total_models=$(aws bedrock list-foundation-models \
        --region "$REGION" \
        --query 'length(modelSummaries)' \
        --output text)
    print_status "Bedrock is available with $total_models total foundation models"
else
    print_error "Bedrock service is not available in region $REGION"
    echo ""
    echo "Bedrock is available in these regions:"
    echo "• us-east-1 (N. Virginia)"
    echo "• us-west-2 (Oregon)"
    echo "• eu-west-1 (Ireland)"
    echo "• eu-central-1 (Frankfurt)"
    echo "• ap-southeast-1 (Singapore)"
    echo "• ap-southeast-2 (Sydney)"
    echo "• ap-northeast-1 (Tokyo)"
    echo "• ap-south-1 (Mumbai)"
    echo "• ca-central-1 (Canada)"
fi

echo ""
echo "To use a specific model in your CloudFormation deployment:"
echo "• Set the BedrockModelId parameter to your preferred model"
echo "• Or leave it empty for automatic region-based selection"
echo ""
echo "Example:"
echo "aws cloudformation deploy --parameter-overrides BedrockModelId=$recommended_model ..."
