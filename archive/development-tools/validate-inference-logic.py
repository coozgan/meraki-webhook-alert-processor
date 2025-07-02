#!/usr/bin/env python3
"""
Validate cross-region inference profile logic without making actual AWS calls
"""

import os
import sys

# Add the current directory to Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

def test_inference_profile_mapping():
    """Test the inference profile mapping logic"""
    print("🧪 Testing Cross-Region Inference Profile Logic")
    print("=" * 50)
    
    # Mock environment variables
    mock_env = {
        'BEDROCK_MODEL_ID': 'anthropic.claude-sonnet-4-20250514-v1:0',
        'BEDROCK_CLAUDE4_SONNET_PROFILE_ARN': 'arn:aws:bedrock:ap-southeast-1::inference-profile/apac.anthropic.claude-sonnet-4-20250514-v1:0',
        'BEDROCK_CLAUDE37_SONNET_PROFILE_ARN': 'arn:aws:bedrock:ap-southeast-1::inference-profile/apac.anthropic.claude-3-7-sonnet-20250219-v1:0',
        'BEDROCK_CLAUDE35_SONNET_V2_PROFILE_ARN': 'arn:aws:bedrock:ap-southeast-1::inference-profile/apac.anthropic.claude-3-5-sonnet-20241022-v2:0',
        'BEDROCK_CLAUDE35_SONNET_PROFILE_ARN': 'arn:aws:bedrock:ap-southeast-1::inference-profile/apac.anthropic.claude-3-5-sonnet-20240620-v1:0',
        'BEDROCK_CLAUDE3_SONNET_PROFILE_ARN': 'arn:aws:bedrock:ap-southeast-1::inference-profile/apac.anthropic.claude-3-sonnet-20240229-v1:0',
        'BEDROCK_CLAUDE3_HAIKU_PROFILE_ARN': 'arn:aws:bedrock:ap-southeast-1::inference-profile/apac.anthropic.claude-3-haiku-20240307-v1:0',
        'GOOGLE_CHAT_WEBHOOK_URL': '',
        'SES_SENDER_EMAIL': 'test@example.com',
        'SES_RECIPIENT_EMAILS': 'recipient@example.com'
    }
    
    # Set mock environment
    for key, value in mock_env.items():
        os.environ[key] = value
    
    # Import the lambda module
    import importlib.util
    spec = importlib.util.spec_from_file_location("lambda_module", "lambda.py")
    lambda_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lambda_module)
    
    # Create processor instance
    processor = lambda_module.MerakiAlertProcessor()
    
    print(f"✓ Primary model: {processor.bedrock_model_id}")
    print(f"✓ Fallback models: {len(processor.fallback_models)} models")
    print(f"✓ Cross-region models: {len(processor.cross_region_models)} models")
    
    print("\n📋 Cross-Region Model Mappings:")
    print("-" * 30)
    for model_id, profile_arn in processor.cross_region_models.items():
        if profile_arn:
            profile_name = profile_arn.split('/')[-1] if profile_arn else 'None'
            print(f"✓ {model_id}")
            print(f"  → {profile_name}")
        else:
            print(f"✗ {model_id} (no profile ARN)")
    
    # Test the model selection logic
    print("\n🎯 Testing Model Selection Logic:")
    print("-" * 35)
    
    test_models = [
        'anthropic.claude-sonnet-4-20250514-v1:0',
        'anthropic.claude-3-5-sonnet-20241022-v2:0',
        'anthropic.claude-3-sonnet-20240229-v1:0',
        'anthropic.claude-instant-v1'
    ]
    
    for model in test_models:
        profile_arn = processor.cross_region_models.get(model)
        if profile_arn:
            print(f"✓ {model} → Uses inference profile")
        else:
            print(f"○ {model} → Uses direct invocation")
    
    print(f"\n✅ Validation Complete!")
    print(f"   - Environment variables: {len(mock_env)} set")
    print(f"   - Inference profiles: {sum(1 for arn in processor.cross_region_models.values() if arn)} available")
    print(f"   - Fallback models: {len(processor.fallback_models)} configured")
    
    return True

if __name__ == "__main__":
    try:
        test_inference_profile_mapping()
    except Exception as e:
        print(f"❌ Test failed: {e}")
        sys.exit(1)
