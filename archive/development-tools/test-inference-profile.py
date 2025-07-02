#!/usr/bin/env python3
"""
Test script to verify cross-region inference profile functionality for Claude 4 models
"""

import boto3
import json
import os
from botocore.exceptions import ClientError

def test_model_invocation(model_id, inference_profile_arn=None):
    """Test model invocation with and without inference profiles"""
    bedrock = boto3.client('bedrock-runtime')
    
    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 100,
        "messages": [
            {
                "role": "user",
                "content": "Hello! Please respond with a brief greeting."
            }
        ],
        "temperature": 0.1,
        "top_p": 0.9
    }
    
    print(f"\n=== Testing Model: {model_id} ===")
    
    # Test direct model invocation
    try:
        print(f"Testing direct model invocation...")
        response = bedrock.invoke_model(
            modelId=model_id,
            body=json.dumps(request_body),
            contentType='application/json'
        )
        response_body = json.loads(response['body'].read())
        print(f"✓ Direct invocation successful: {response_body['content'][0]['text'][:50]}...")
        return True
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_msg = e.response['Error']['Message']
        print(f"✗ Direct invocation failed: {error_code} - {error_msg}")
        
        # If direct fails and we have an inference profile, try that
        if inference_profile_arn and "inference profile" in error_msg.lower():
            try:
                print(f"Testing inference profile ARN: {inference_profile_arn}")
                response = bedrock.invoke_model(
                    modelId=inference_profile_arn,
                    body=json.dumps(request_body),
                    contentType='application/json'
                )
                response_body = json.loads(response['body'].read())
                print(f"✓ Inference profile invocation successful: {response_body['content'][0]['text'][:50]}...")
                return True
            except ClientError as profile_error:
                print(f"✗ Inference profile invocation also failed: {profile_error.response['Error']['Code']} - {profile_error.response['Error']['Message']}")
                return False
        return False

def main():
    """Main test function"""
    print("Testing Bedrock model invocation with inference profiles")
    print("=" * 60)
    
    # Get current region
    session = boto3.Session()
    region = session.region_name or 'us-east-1'
    print(f"Current region: {region}")
    
    # Test models and their corresponding inference profile ARNs
    test_cases = [
        {
            'model_id': 'anthropic.claude-sonnet-4-20250514-v1:0',
            'inference_profile_arn': f'arn:aws:bedrock:{region}::inference-profile/us.anthropic.claude-sonnet-4-20250514-v1:0'
        },
        {
            'model_id': 'anthropic.claude-opus-4-20250514-v1:0',
            'inference_profile_arn': f'arn:aws:bedrock:{region}::inference-profile/us.anthropic.claude-opus-4-20250514-v1:0'
        },
        {
            'model_id': 'anthropic.claude-3-5-sonnet-20241022-v2:0',
            'inference_profile_arn': None  # Claude 3.5 doesn't need inference profiles
        }
    ]
    
    results = []
    for test_case in test_cases:
        success = test_model_invocation(
            test_case['model_id'], 
            test_case['inference_profile_arn']
        )
        results.append({
            'model': test_case['model_id'],
            'success': success
        })
    
    print(f"\n=== Test Results Summary ===")
    for result in results:
        status = "✓ PASS" if result['success'] else "✗ FAIL"
        print(f"{status}: {result['model']}")
    
    successful_tests = sum(1 for r in results if r['success'])
    print(f"\nOverall: {successful_tests}/{len(results)} tests passed")

if __name__ == "__main__":
    main()
