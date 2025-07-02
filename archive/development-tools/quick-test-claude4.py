#!/usr/bin/env python3
"""
Quick test to verify inference profile functionality
"""

import boto3
import json
from botocore.exceptions import ClientError

def test_claude_4_sonnet():
    """Test Claude 4 Sonnet with inference profile"""
    bedrock = boto3.client('bedrock-runtime')
    region = boto3.Session().region_name or 'ap-southeast-1'
    
    # Use the correct inference profile ARN for Claude 4 Sonnet in ap-southeast-1
    inference_profile_arn = 'arn:aws:bedrock:ap-southeast-1::inference-profile/apac.anthropic.claude-sonnet-4-20250514-v1:0'
    model_id = 'anthropic.claude-sonnet-4-20250514-v1:0'
    
    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 50,
        "messages": [
            {
                "role": "user",
                "content": "Hello! Please respond with just 'Hello from Claude 4!'"
            }
        ],
        "temperature": 0.1,
        "top_p": 0.9
    }
    
    print(f"Testing in region: {region}")
    
    # Test 1: Direct model invocation (should fail)
    print("\n1. Testing direct model invocation (expected to fail):")
    try:
        response = bedrock.invoke_model(
            modelId=model_id,
            body=json.dumps(request_body),
            contentType='application/json'
        )
        response_body = json.loads(response['body'].read())
        print(f"✓ Unexpected success: {response_body['content'][0]['text']}")
    except ClientError as e:
        print(f"✗ Expected failure: {e.response['Error']['Message']}")
    
    # Test 2: Inference profile invocation (should succeed)
    print("\n2. Testing inference profile invocation:")
    try:
        response = bedrock.invoke_model(
            modelId=inference_profile_arn,
            body=json.dumps(request_body),
            contentType='application/json'
        )
        response_body = json.loads(response['body'].read())
        print(f"✓ Success with inference profile: {response_body['content'][0]['text']}")
        return True
    except ClientError as e:
        print(f"✗ Failed with inference profile: {e.response['Error']['Message']}")
        return False

if __name__ == "__main__":
    print("Quick Claude 4 Sonnet Inference Profile Test")
    print("=" * 50)
    success = test_claude_4_sonnet()
    print(f"\nTest result: {'PASS' if success else 'FAIL'}")
