#!/usr/bin/env python3
"""
Unit test for the cross-region inference profile functionality in lambda.py
"""

import json
import os
import sys
import unittest
from unittest.mock import Mock, patch, MagicMock

# Add the current directory to Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Import the lambda module
import importlib.util
spec = importlib.util.spec_from_file_location("lambda_module", os.path.join(os.path.dirname(__file__), "lambda.py"))
lambda_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lambda_module)
MerakiAlertProcessor = lambda_module.MerakiAlertProcessor

class TestCrossRegionInference(unittest.TestCase):
    """Test cross-region inference profile functionality"""
    
    def setUp(self):
        """Set up test environment"""
        # Mock environment variables
        self.env_patcher = patch.dict(os.environ, {
            'BEDROCK_MODEL_ID': 'anthropic.claude-sonnet-4-20250514-v1:0',
            'BEDROCK_CLAUDE4_SONNET_PROFILE_ARN': 'arn:aws:bedrock:us-east-1::inference-profile/us.anthropic.claude-sonnet-4-20250514-v1:0',
            'BEDROCK_CLAUDE4_OPUS_PROFILE_ARN': 'arn:aws:bedrock:us-east-1::inference-profile/us.anthropic.claude-opus-4-20250514-v1:0',
            'GOOGLE_CHAT_WEBHOOK_URL': '',
            'SES_SENDER_EMAIL': 'test@example.com',
            'SES_RECIPIENT_EMAILS': 'recipient@example.com'
        })
        self.env_patcher.start()
        
        # Initialize the processor
        self.processor = MerakiAlertProcessor()
    
    def tearDown(self):
        """Clean up test environment"""
        self.env_patcher.stop()
    
    def test_initialization_with_inference_profiles(self):
        """Test that the processor initializes correctly with inference profile ARNs"""
        self.assertEqual(
            self.processor.claude4_sonnet_profile_arn,
            'arn:aws:bedrock:us-east-1::inference-profile/us.anthropic.claude-sonnet-4-20250514-v1:0'
        )
        self.assertEqual(
            self.processor.claude4_opus_profile_arn,
            'arn:aws:bedrock:us-east-1::inference-profile/us.anthropic.claude-opus-4-20250514-v1:0'
        )
        
        # Check that cross-region models mapping is correct
        self.assertIn('anthropic.claude-sonnet-4-20250514-v1:0', self.processor.cross_region_models)
        self.assertIn('anthropic.claude-opus-4-20250514-v1:0', self.processor.cross_region_models)
    
    @patch('lambda.bedrock_runtime')
    def test_invoke_with_inference_profile(self, mock_bedrock):
        """Test model invocation using inference profile ARN"""
        # Mock successful response
        mock_response = {
            'body': Mock()
        }
        mock_response['body'].read.return_value = json.dumps({
            'content': [{'text': '{"severity": "MEDIUM", "category": "Test", "summary": "Test response"}'}]
        })
        mock_bedrock.invoke_model.return_value = mock_response
        
        # Test Claude 4 Sonnet invocation
        prompt = "Test prompt"
        result = self.processor._invoke_bedrock_model(prompt, 'anthropic.claude-sonnet-4-20250514-v1:0')
        
        # Verify that invoke_model was called with the inference profile ARN
        mock_bedrock.invoke_model.assert_called_once()
        call_args = mock_bedrock.invoke_model.call_args
        
        # Should use the inference profile ARN, not the direct model ID
        self.assertEqual(
            call_args[1]['modelId'],
            'arn:aws:bedrock:us-east-1::inference-profile/us.anthropic.claude-sonnet-4-20250514-v1:0'
        )
    
    @patch('lambda.bedrock_runtime')
    def test_fallback_to_direct_invocation(self, mock_bedrock):
        """Test fallback to direct model invocation when inference profile fails"""
        # Mock inference profile failure, then success with direct invocation
        profile_error = Exception("inference-profile error")
        direct_success = {
            'body': Mock()
        }
        direct_success['body'].read.return_value = json.dumps({
            'content': [{'text': '{"severity": "MEDIUM", "category": "Test", "summary": "Direct invocation success"}'}]
        })
        
        mock_bedrock.invoke_model.side_effect = [profile_error, direct_success]
        
        # Test invocation
        prompt = "Test prompt"
        result = self.processor._invoke_bedrock_model(prompt, 'anthropic.claude-sonnet-4-20250514-v1:0')
        
        # Should have been called twice: once with profile ARN, once with direct model ID
        self.assertEqual(mock_bedrock.invoke_model.call_count, 2)
        
        # First call should use inference profile ARN
        first_call = mock_bedrock.invoke_model.call_args_list[0]
        self.assertEqual(
            first_call[1]['modelId'],
            'arn:aws:bedrock:us-east-1::inference-profile/us.anthropic.claude-sonnet-4-20250514-v1:0'
        )
        
        # Second call should use direct model ID
        second_call = mock_bedrock.invoke_model.call_args_list[1]
        self.assertEqual(second_call[1]['modelId'], 'anthropic.claude-sonnet-4-20250514-v1:0')
    
    @patch('lambda.bedrock_runtime')
    def test_direct_invocation_for_non_claude4_models(self, mock_bedrock):
        """Test that non-Claude 4 models use direct invocation"""
        # Mock successful response
        mock_response = {
            'body': Mock()
        }
        mock_response['body'].read.return_value = json.dumps({
            'content': [{'text': '{"severity": "MEDIUM", "category": "Test", "summary": "Claude 3.5 response"}'}]
        })
        mock_bedrock.invoke_model.return_value = mock_response
        
        # Test Claude 3.5 Sonnet invocation
        prompt = "Test prompt"
        result = self.processor._invoke_bedrock_model(prompt, 'anthropic.claude-3-5-sonnet-20241022-v2:0')
        
        # Should call invoke_model once with direct model ID
        mock_bedrock.invoke_model.assert_called_once()
        call_args = mock_bedrock.invoke_model.call_args
        self.assertEqual(call_args[1]['modelId'], 'anthropic.claude-3-5-sonnet-20241022-v2:0')

if __name__ == '__main__':
    # Run the tests
    unittest.main(verbosity=2)
