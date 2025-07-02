#!/bin/bash

# Test Bedrock Model Checker
export AWS_PAGER=""

REGION="us-east-1"

echo "Testing Bedrock model availability in $REGION"
echo ""

# Get all Claude models
echo "Getting all Claude models..."
aws bedrock list-foundation-models \
    --region "$REGION" \
    --query 'modelSummaries[?contains(modelId, `anthropic`)].modelId' \
    --output text > /tmp/claude_models.txt

if [[ $? -eq 0 ]]; then
    echo "✅ Successfully retrieved models"
    echo ""
    echo "Available Claude models:"
    cat /tmp/claude_models.txt | tr '\t' '\n' | sort
else
    echo "❌ Failed to retrieve models"
fi

rm -f /tmp/claude_models.txt
