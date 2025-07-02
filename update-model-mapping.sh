#!/bin/bash

# Dynamic CloudFormation Model Mapper
# This script updates the CloudFormation template with actual available models

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

# Function to get available models for a region
get_available_models() {
    local region="$1"
    local models
    
    # Get all Claude models for the region
    models=$(aws bedrock list-foundation-models \
        --region "$region" \
        --query 'modelSummaries[?contains(modelId, `anthropic.claude`)].modelId' \
        --output text 2>/dev/null | tr '\t' ' ')
    
    if [[ -z "$models" ]]; then
        echo ""
        return 1
    fi
    
    echo "$models"
    return 0
}

# Function to select best models from available list
select_models() {
    local models="$1"
    local primary="" secondary="" fallback=""
    
    # Convert to array
    IFS=' ' read -ra model_array <<< "$models"
    
    # Priority selection logic
    # 1. Primary: Claude 4 (Sonnet or Opus), then Claude 3.7, then Claude 3.5 Sonnet, then Claude 3 Sonnet
    # 2. Secondary: Next best available model (different from primary)
    # 3. Fallback: Claude Haiku or Instant (different from primary and secondary)
    
    # Find primary model - prioritize Claude 4 first
    for model in "${model_array[@]}"; do
        if [[ "$model" == *"claude-sonnet-4"* ]]; then
            primary="$model"
            break
        fi
    done
    
    if [[ -z "$primary" ]]; then
        for model in "${model_array[@]}"; do
            if [[ "$model" == *"claude-opus-4"* ]]; then
                primary="$model"
                break
            fi
        done
    fi
    
    if [[ -z "$primary" ]]; then
        for model in "${model_array[@]}"; do
            if [[ "$model" == *"claude-3-7-sonnet"* ]]; then
                primary="$model"
                break
            fi
        done
    fi
    
    if [[ -z "$primary" ]]; then
        for model in "${model_array[@]}"; do
            if [[ "$model" == *"claude-3-5-sonnet"* ]]; then
                primary="$model"
                break
            fi
        done
    fi
    
    if [[ -z "$primary" ]]; then
        for model in "${model_array[@]}"; do
            if [[ "$model" == *"claude-3-sonnet"* ]]; then
                primary="$model"
                break
            fi
        done
    fi
    
    # Find secondary model (different from primary)
    for model in "${model_array[@]}"; do
        if [[ "$model" != "$primary" ]]; then
            if [[ "$model" == *"claude-3-sonnet"* ]] || [[ "$model" == *"claude-3-5-sonnet"* ]]; then
                secondary="$model"
                break
            fi
        fi
    done
    
    # Find fallback model
    for model in "${model_array[@]}"; do
        if [[ "$model" != "$primary" && "$model" != "$secondary" ]]; then
            if [[ "$model" == *"claude-3-haiku"* ]]; then
                fallback="$model"
                break
            fi
        fi
    done
    
    if [[ -z "$fallback" ]]; then
        for model in "${model_array[@]}"; do
            if [[ "$model" != "$primary" && "$model" != "$secondary" ]]; then
                if [[ "$model" == *"claude-instant"* ]]; then
                    fallback="$model"
                    break
                fi
            fi
        done
    fi
    
    # Use primary as fallback if no other options
    if [[ -z "$secondary" ]]; then secondary="$primary"; fi
    if [[ -z "$fallback" ]]; then fallback="$primary"; fi
    
    echo "$primary|$secondary|$fallback"
}

# Main function
main() {
    print_status "🔄 Dynamic CloudFormation Model Mapper"
    echo ""
    
    # Confirm AWS CLI is available
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is required but not found"
        exit 1
    fi
    
    # Define regions to check
    regions=("us-east-1" "us-west-2" "eu-west-1" "eu-central-1" 
             "ap-southeast-1" "ap-southeast-2" "ap-northeast-1" 
             "ap-south-1" "ca-central-1")
    
    print_info "Checking model availability across regions..."
    echo ""
    
    # Create temporary mapping file
    mapping_file="/tmp/bedrock_mapping.yaml"
    
    cat > "$mapping_file" << 'EOF'
Mappings:
  # Regional model availability mapping - Auto-generated from actual AWS Bedrock API
  BedrockModels:
EOF
    
    # Check each region
    for region in "${regions[@]}"; do
        echo -n "Checking $region... "
        
        models=$(get_available_models "$region")
        if [[ $? -eq 0 && -n "$models" ]]; then
            selected=$(select_models "$models")
            IFS='|' read -r primary secondary fallback <<< "$selected"
            
            echo -e "${GREEN}✓${NC} Found $(echo $models | wc -w) models"
            
            # Add to mapping file
            cat >> "$mapping_file" << EOF
    ${region}:
      Primary: '${primary}'
      Secondary: '${secondary}'
      Fallback: '${fallback}'
EOF
        else
            echo -e "${RED}✗${NC} No models available"
            
            # Add default mapping for regions without Bedrock
            cat >> "$mapping_file" << EOF
    ${region}:
      Primary: 'anthropic.claude-3-sonnet-20240229-v1:0'
      Secondary: 'anthropic.claude-3-haiku-20240307-v1:0'
      Fallback: 'anthropic.claude-instant-v1'
EOF
        fi
    done
    
    # Add default mapping
    cat >> "$mapping_file" << 'EOF'
    # Default fallback for any other region
    default:
      Primary: 'anthropic.claude-3-sonnet-20240229-v1:0'
      Secondary: 'anthropic.claude-3-haiku-20240307-v1:0'
      Fallback: 'anthropic.claude-instant-v1'
EOF
    
    echo ""
    print_status "Generated mapping file: $mapping_file"
    echo ""
    print_info "Generated mapping preview:"
    echo "=========================================="
    head -20 "$mapping_file"
    echo "..."
    echo "=========================================="
    echo ""
    
    # Ask if user wants to update the CloudFormation template
    read -p "Do you want to update the CloudFormation template with this mapping? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Backup original template
        cp cloudformation-template.yaml cloudformation-template.yaml.backup
        print_info "Backed up original template to cloudformation-template.yaml.backup"
        
        # Create updated template
        # Extract everything before Mappings section
        sed -n '1,/^Mappings:/p' cloudformation-template.yaml | head -n -1 > /tmp/cf_before.yaml
        
        # Extract everything after Mappings section
        sed -n '/^Conditions:/,$p' cloudformation-template.yaml > /tmp/cf_after.yaml
        
        # Combine all parts
        cat /tmp/cf_before.yaml "$mapping_file" /tmp/cf_after.yaml > cloudformation-template.yaml
        
        print_status "✅ CloudFormation template updated successfully!"
        print_info "Original template backed up as cloudformation-template.yaml.backup"
        
        # Cleanup temp files
        rm -f /tmp/cf_before.yaml /tmp/cf_after.yaml
    else
        print_info "Template not updated. Mapping saved to $mapping_file for review."
    fi
    
    print_status "🎉 Dynamic mapping generation completed!"
}

# Show usage if help requested
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Dynamic CloudFormation Model Mapper"
    echo ""
    echo "This script automatically discovers available Claude models across AWS regions"
    echo "and generates/updates the CloudFormation template with the correct model mappings."
    echo ""
    echo "Usage: $0"
    echo ""
    echo "The script will:"
    echo "1. Check model availability across all major AWS regions"
    echo "2. Select the best available models for each region"
    echo "3. Generate a mapping section for CloudFormation"
    echo "4. Optionally update your cloudformation-template.yaml file"
    echo ""
    exit 0
fi

# Run main function
main "$@"
