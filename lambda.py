import json
import boto3
import logging
from typing import Dict, Any, Optional, List
from datetime import datetime
import urllib3
import os
from botocore.exceptions import ClientError
from functools import lru_cache
import re

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients (reuse across invocations)
bedrock_runtime = boto3.client('bedrock-runtime')
ses_client = boto3.client('ses')

# Initialize HTTP pool manager with connection pooling
http = urllib3.PoolManager(
    num_pools=10,
    maxsize=10,
    retries=urllib3.Retry(
        total=3,
        backoff_factor=0.3,
        status_forcelist=[500, 502, 503, 504]
    )
)

class MerakiAlertProcessor:
    """
    Main class for processing Meraki webhook alerts
    """
    
    def __init__(self):
        # Get model ID from environment variable, with fallback
        self.bedrock_model_id = os.environ.get('BEDROCK_MODEL_ID', 'anthropic.claude-sonnet-4-20250514-v1:0')
        self.max_tokens = 1000
        self.temperature = 0.1
        self.top_p = 0.9
        
        # Get inference profile ARNs from environment variables
        self.claude4_sonnet_profile_arn = os.environ.get('BEDROCK_CLAUDE4_SONNET_PROFILE_ARN')
        self.claude37_sonnet_profile_arn = os.environ.get('BEDROCK_CLAUDE37_SONNET_PROFILE_ARN')
        self.claude35_sonnet_v2_profile_arn = os.environ.get('BEDROCK_CLAUDE35_SONNET_V2_PROFILE_ARN')
        self.claude35_sonnet_profile_arn = os.environ.get('BEDROCK_CLAUDE35_SONNET_PROFILE_ARN')
        self.claude3_sonnet_profile_arn = os.environ.get('BEDROCK_CLAUDE3_SONNET_PROFILE_ARN')
        self.claude3_haiku_profile_arn = os.environ.get('BEDROCK_CLAUDE3_HAIKU_PROFILE_ARN')
        
        # Dynamic fallback models prioritizing Claude 4, then Claude 3.5, then Claude 3
        self.fallback_models = [
            'anthropic.claude-sonnet-4-20250514-v1:0',
            'anthropic.claude-opus-4-20250514-v1:0',
            'anthropic.claude-3-7-sonnet-20250219-v1:0',
            'anthropic.claude-3-5-sonnet-20241022-v2:0',
            'anthropic.claude-3-5-sonnet-20240620-v1:0',
            'anthropic.claude-3-sonnet-20240229-v1:0',
            'anthropic.claude-3-haiku-20240307-v1:0',
            'anthropic.claude-instant-v1'
        ]
        
        # Models that require cross-region inference profiles
        self.cross_region_models = {
            'anthropic.claude-sonnet-4-20250514-v1:0': self.claude4_sonnet_profile_arn,
            'anthropic.claude-3-7-sonnet-20250219-v1:0': self.claude37_sonnet_profile_arn,
            'anthropic.claude-3-5-sonnet-20241022-v2:0': self.claude35_sonnet_v2_profile_arn,
            'anthropic.claude-3-5-sonnet-20240620-v1:0': self.claude35_sonnet_profile_arn,
            'anthropic.claude-3-sonnet-20240229-v1:0': self.claude3_sonnet_profile_arn,
            'anthropic.claude-3-haiku-20240307-v1:0': self.claude3_haiku_profile_arn
        }
    
    def process_webhook(self, event: Dict[str, Any], context: Any) -> Dict[str, Any]:
        """
        Main webhook processing method
        """
        try:
            logger.info(f"Processing webhook event: {json.dumps(event, default=str)}")
            
            # Parse webhook payload
            webhook_data = self._parse_webhook_payload(event)
            
            # Validate required fields
            if not self._validate_webhook_data(webhook_data):
                return self._create_error_response(400, "Invalid webhook data")
            
            # Extract alert information
            alert_info = self._extract_alert_info(webhook_data)
            
            # Process the alert with Bedrock
            analysis_result = self._analyze_alert_with_bedrock(webhook_data)
            
            # Send notifications asynchronously (in production, consider using SQS/SNS)
            self._send_notifications(analysis_result, webhook_data)
            
            # Create success response
            return self._create_success_response(alert_info, analysis_result)
            
        except ValueError as e:
            logger.error(f"Validation error: {str(e)}")
            return self._create_error_response(400, str(e))
        except Exception as e:
            logger.error(f"Unexpected error processing webhook: {str(e)}", exc_info=True)
            return self._create_error_response(500, "Internal server error")
    
    def _parse_webhook_payload(self, event: Dict[str, Any]) -> Dict[str, Any]:
        """
        Parse webhook payload from different event sources
        """
        if 'body' in event:
            # API Gateway integration
            body = event['body']
            if isinstance(body, str):
                try:
                    return json.loads(body)
                except json.JSONDecodeError as e:
                    raise ValueError(f"Invalid JSON in request body: {str(e)}")
            return body
        else:
            # Direct Lambda invocation
            return event
    
    def _validate_webhook_data(self, webhook_data: Dict[str, Any]) -> bool:
        """
        Validate essential webhook data fields
        """
        required_fields = ['alertType']
        return all(field in webhook_data for field in required_fields)
    
    def _extract_alert_info(self, webhook_data: Dict[str, Any]) -> Dict[str, str]:
        """
        Extract and sanitize alert information
        """
        return {
            'alert_type': webhook_data.get('alertType', 'Unknown'),
            'organization_name': webhook_data.get('organizationName', 'Unknown'),
            'organization_url': webhook_data.get('organizationUrl', ''),
            'network_name': webhook_data.get('networkName', 'Unknown'),
            'network_url': webhook_data.get('networkUrl', ''),
            'alert_data': webhook_data.get('alertData', {})
        }
    
    def _analyze_alert_with_bedrock(self, webhook_data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Analyze the Meraki webhook alert using Amazon Bedrock with Anthropic Claude
        """
        try:
            prompt = self._create_analysis_prompt(webhook_data)
            
            # Try with primary model first
            return self._invoke_bedrock_model(prompt, self.bedrock_model_id)
            
        except Exception as e:
            logger.error(f"Bedrock analysis failed with primary model {self.bedrock_model_id}: {str(e)}")
            
            # Try fallback models if primary fails
            for fallback_model in self.fallback_models:
                if fallback_model != self.bedrock_model_id:
                    try:
                        logger.info(f"Trying fallback model: {fallback_model}")
                        return self._invoke_bedrock_model(prompt, fallback_model)
                    except Exception as fallback_error:
                        logger.error(f"Fallback model {fallback_model} also failed: {str(fallback_error)}")
                        continue
            
            # If all models fail, return fallback analysis
            logger.error("All Bedrock models failed, using fallback analysis")
            return self._create_fallback_analysis(str(e))
    
    def _invoke_bedrock_model(self, prompt: str, model_id: str) -> Dict[str, Any]:
        """
        Invoke a specific Bedrock model, using inference profiles for Claude 4 models
        """
        # Check if this model requires a cross-region inference profile
        inference_profile_arn = self.cross_region_models.get(model_id)
        
        # Anthropic Claude request format
        request_body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": self.max_tokens,
            "messages": [
                {
                    "role": "user",
                    "content": prompt
                }
            ],
            "temperature": self.temperature,
            "top_p": self.top_p
        }
        
        try:
            if inference_profile_arn:
                # Use inference profile ARN for Claude 4 models
                logger.info(f"Using inference profile ARN for model {model_id}: {inference_profile_arn}")
                response = bedrock_runtime.invoke_model(
                    modelId=inference_profile_arn,
                    body=json.dumps(request_body),
                    contentType='application/json'
                )
            else:
                # Use direct model ID for Claude 3.x and other models
                logger.info(f"Using direct model ID: {model_id}")
                response = bedrock_runtime.invoke_model(
                    modelId=model_id,
                    body=json.dumps(request_body),
                    contentType='application/json'
                )
        except ClientError as e:
            # If inference profile fails, try direct model invocation as fallback
            if inference_profile_arn and 'inference-profile' in str(e):
                logger.warning(f"Inference profile failed for {model_id}, trying direct invocation: {str(e)}")
                response = bedrock_runtime.invoke_model(
                    modelId=model_id,
                    body=json.dumps(request_body),
                    contentType='application/json'
                )
            else:
                raise e
        
        response_body = json.loads(response['body'].read())
        # Claude response format
        analysis_text = response_body['content'][0]['text']
        
        return self._parse_bedrock_response(analysis_text)
    
    def _create_analysis_prompt(self, webhook_data: Dict[str, Any]) -> str:
        """
        Create a structured prompt for Bedrock analysis
        """
        alert_type = webhook_data.get('alertType', 'Unknown')
        alert_data = webhook_data.get('alertData', {})
        
        # Sanitize alert data for prompt injection protection
        sanitized_alert_data = self._sanitize_for_prompt(alert_data)
        
        return f"""
You are a network infrastructure expert analyzing Cisco Meraki webhook alerts. 

Analyze this alert and respond in JSON format:

Alert Details:
- Alert Type: {alert_type}
- Organization: {webhook_data.get('organizationName', 'Unknown')}
- Network: {webhook_data.get('networkName', 'Unknown')}
- Alert Data: {json.dumps(sanitized_alert_data, indent=2)}

Respond with ONLY a JSON object in this exact format:
{{
    "severity": "CRITICAL|HIGH|MEDIUM|LOW|INFO",
    "category": "Security|Connectivity|Performance|Configuration|Hardware|Informational",
    "summary": "Clear description of what happened",
    "impact": "Potential impact on network operations",
    "recommendations": ["Action 1", "Action 2", "Action 3"],
    "requires_immediate_action": true/false,
    "estimated_resolution_time": "Time estimate"
}}
"""
    
    def _sanitize_for_prompt(self, data: Any, max_length: int = 1000) -> Any:
        """
        Sanitize data for prompt injection protection
        """
        if isinstance(data, str):
            # Remove potential prompt injection patterns and limit length
            sanitized = re.sub(r'[^\w\s\-\.\@\:\/]', '', data)
            return sanitized[:max_length]
        elif isinstance(data, dict):
            return {k: self._sanitize_for_prompt(v, max_length) for k, v in data.items()}
        elif isinstance(data, list):
            return [self._sanitize_for_prompt(item, max_length) for item in data]
        else:
            return data
    
    def _parse_bedrock_response(self, response_text: str) -> Dict[str, Any]:
        """
        Parse and validate the structured response from Bedrock
        """
        try:
            # Clean up response text
            response_text = response_text.strip()
            if response_text.startswith('```json'):
                response_text = response_text[7:-3].strip()
            elif response_text.startswith('```'):
                response_text = response_text[3:-3].strip()
            
            parsed_response = json.loads(response_text)
            
            # Validate and set defaults for required fields
            return self._validate_analysis_response(parsed_response)
            
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse Bedrock response as JSON: {str(e)}")
            return self._create_fallback_analysis("JSON parsing failed")
    
    def _validate_analysis_response(self, response: Dict[str, Any]) -> Dict[str, Any]:
        """
        Validate and normalize analysis response
        """
        defaults = {
            'severity': 'MEDIUM',
            'category': 'Unknown',
            'summary': 'Alert received but analysis incomplete',
            'impact': 'Unable to determine impact',
            'recommendations': ['Manual review required', 'Check Meraki dashboard'],
            'requires_immediate_action': True,
            'estimated_resolution_time': 'Unknown'
        }
        
        # Ensure all required fields exist with valid values
        for key, default_value in defaults.items():
            if key not in response or not response[key]:
                response[key] = default_value
        
        # Validate severity levels
        valid_severities = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'INFO']
        if response['severity'].upper() not in valid_severities:
            response['severity'] = 'MEDIUM'
        
        return response
    
    def _create_fallback_analysis(self, error_msg: str) -> Dict[str, Any]:
        """
        Create fallback analysis when Bedrock fails
        """
        return {
            'severity': 'HIGH',
            'category': 'System Error',
            'summary': f'Alert received but analysis failed: {error_msg}',
            'impact': 'Unable to determine impact - manual review required',
            'recommendations': [
                'Manual review required',
                'Check Meraki dashboard for details',
                'Contact system administrator if issues persist'
            ],
            'requires_immediate_action': True,
            'estimated_resolution_time': 'Unknown'
        }
    
    def _send_notifications(self, analysis_result: Dict[str, Any], webhook_data: Dict[str, Any]):
        """
        Send notifications via multiple channels
        """
        try:
            # Send Google Chat notification
            self._send_google_chat_message(analysis_result)
        except Exception as e:
            logger.error(f"Failed to send Google Chat message: {str(e)}")
        
        try:
            # Send email notification
            self._send_email_alert(analysis_result, webhook_data)
        except Exception as e:
            logger.error(f"Failed to send email alert: {str(e)}")
    
    def _send_google_chat_message(self, analysis_result: Dict[str, Any]) -> int:
        """
        Send message to Google Chat webhook
        """
        webhook_url = os.environ.get("GOOGLE_CHAT_WEBHOOK_URL")
        if not webhook_url:
            logger.warning("GOOGLE_CHAT_WEBHOOK_URL not configured, skipping Google Chat notification")
            return 0
        
        message_text = self._format_google_chat_message(analysis_result)
        
        response = http.request(
            "POST",
            webhook_url,
            body=json.dumps({"text": message_text}),
            headers={"Content-Type": "application/json"}
        )
        
        if response.status == 200:
            logger.info("Google Chat message sent successfully")
        else:
            logger.error(f"Google Chat message failed with status: {response.status}")
        
        return response.status
    
    def _format_google_chat_message(self, analysis_result: Dict[str, Any]) -> str:
        """
        Format message for Google Chat with proper formatting
        """
        severity_emoji = {
            'CRITICAL': '🔴',
            'HIGH': '🟠', 
            'MEDIUM': '🟡',
            'LOW': '🟢',
            'INFO': 'ℹ️'
        }.get(analysis_result.get('severity', '').upper(), '⚪')
        
        recommendations = analysis_result.get('recommendations', [])
        rec_text = '\n'.join([f'• {rec}' for rec in recommendations])
        
        return f"""{severity_emoji} *NETWORK ALERT*

*Severity:* {analysis_result.get('severity', 'Unknown')}
*Category:* {analysis_result.get('category', 'Unknown')}

*Summary:* {analysis_result.get('summary', 'No summary available')}

*Impact:* {analysis_result.get('impact', 'Unknown impact')}

*Recommended Actions:*
{rec_text}

*Urgent:* {'*YES*' if analysis_result.get('requires_immediate_action') else 'No'}
*ETA:* {analysis_result.get('estimated_resolution_time', 'Unknown')}"""
    
    def _send_email_alert(self, analysis_result: Dict[str, Any], webhook_data: Dict[str, Any]):
        """
        Send email alert using Amazon SES
        """
        sender_email = os.environ.get("SES_SENDER_EMAIL")
        recipient_emails = self._parse_recipient_emails()
        
        if not sender_email or not recipient_emails:
            logger.warning("Email configuration incomplete, skipping email notification")
            return
        
        try:
            subject = self._create_email_subject(analysis_result, webhook_data)
            html_body = EmailFormatter.create_html_body(analysis_result, webhook_data)
            text_body = EmailFormatter.create_text_body(analysis_result, webhook_data)
            
            response = ses_client.send_email(
                Source=sender_email,
                Destination={'ToAddresses': recipient_emails},
                Message={
                    'Subject': {'Data': subject, 'Charset': 'UTF-8'},
                    'Body': {
                        'Text': {'Data': text_body, 'Charset': 'UTF-8'},
                        'Html': {'Data': html_body, 'Charset': 'UTF-8'}
                    }
                }
            )
            
            logger.info(f"Email sent successfully. MessageId: {response['MessageId']}")
            
        except ClientError as e:
            logger.error(f"SES error: {str(e)}")
            raise
        except Exception as e:
            logger.error(f"Email sending error: {str(e)}")
            raise
    
    def _parse_recipient_emails(self) -> List[str]:
        """
        Parse and validate recipient email addresses
        """
        recipients_str = os.environ.get("SES_RECIPIENT_EMAILS", "")
        if not recipients_str:
            return []
        
        emails = [email.strip() for email in recipients_str.split(",") if email.strip()]
        
        # Basic email validation
        email_pattern = re.compile(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')
        valid_emails = [email for email in emails if email_pattern.match(email)]
        
        if len(valid_emails) != len(emails):
            logger.warning(f"Some email addresses were invalid and filtered out")
        
        return valid_emails
    
    def _create_email_subject(self, analysis_result: Dict[str, Any], webhook_data: Dict[str, Any]) -> str:
        """
        Create email subject with appropriate urgency indicators
        """
        severity = analysis_result.get('severity', 'UNKNOWN').upper()
        alert_type = webhook_data.get('alertType', 'Unknown')
        organization = webhook_data.get('organizationName', 'Unknown')
        network = webhook_data.get('networkName', 'Unknown')
        
        urgency_prefix = {
            'CRITICAL': '[URGENT] 🔴',
            'HIGH': '[HIGH] 🟠',
            'MEDIUM': '[MEDIUM] 🟡',
            'LOW': '[LOW] 🟢',
            'INFO': '[INFO] ℹ️'
        }.get(severity, '[ALERT] ⚪')
        
        return f"{urgency_prefix} Meraki Alert: {alert_type} - {organization}/{network}"
    
    def _create_success_response(self, alert_info: Dict[str, str], analysis_result: Dict[str, Any]) -> Dict[str, Any]:
        """
        Create successful response
        """
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Content-Type',
                'Access-Control-Allow-Methods': 'POST, OPTIONS'
            },
            'body': json.dumps({
                'message': 'Webhook processed successfully',
                'alert_type': alert_info['alert_type'],
                'organization': alert_info['organization_name'],
                'network': alert_info['network_name'],
                'analysis': analysis_result,
                'timestamp': datetime.utcnow().isoformat()
            })
        }
    
    def _create_error_response(self, status_code: int, message: str) -> Dict[str, Any]:
        """
        Create error response
        """
        return {
            'statusCode': status_code,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': 'Request failed',
                'message': message,
                'timestamp': datetime.utcnow().isoformat()
            })
        }


class EmailFormatter:
    """
    Utility class for email formatting
    """
    
    @staticmethod
    def create_html_body(analysis_result: Dict[str, Any], webhook_data: Dict[str, Any]) -> str:
        """
        Create HTML formatted email body
        """
        severity = analysis_result.get('severity', 'UNKNOWN').upper()
        severity_color = {
            'CRITICAL': '#dc3545',
            'HIGH': '#fd7e14', 
            'MEDIUM': '#ffc107',
            'LOW': '#28a745',
            'INFO': '#17a2b8'
        }.get(severity, '#6c757d')
        
        recommendations_html = "".join([f"<li>{rec}</li>" for rec in analysis_result.get('recommendations', [])])
        
        return f"""
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Meraki Network Alert</title>
        </head>
        <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0;">
            <div style="max-width: 600px; margin: 0 auto; padding: 20px;">
                <div style="background-color: {severity_color}; color: white; padding: 15px; border-radius: 5px; margin-bottom: 20px;">
                    <h1 style="margin: 0; font-size: 24px;">🚨 Meraki Network Alert</h1>
                    <p style="margin: 5px 0 0 0; font-size: 18px;">Severity: {severity}</p>
                </div>
                
                <div style="background-color: #f8f9fa; padding: 15px; border-radius: 5px; margin-bottom: 20px;">
                    <h2 style="color: #495057; margin-top: 0;">Alert Details</h2>
                    <table style="width: 100%; border-collapse: collapse;">
                        <tr>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6; font-weight: bold;">Organization:</td>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6;">{webhook_data.get('organizationName', 'Unknown')}</td>
                        </tr>
                        <tr>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6; font-weight: bold;">Network:</td>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6;">{webhook_data.get('networkName', 'Unknown')}</td>
                        </tr>
                        <tr>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6; font-weight: bold;">Alert Type:</td>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6;">{webhook_data.get('alertType', 'Unknown')}</td>
                        </tr>
                        <tr>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6; font-weight: bold;">Category:</td>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6;">{analysis_result.get('category', 'Unknown')}</td>
                        </tr>
                        <tr>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6; font-weight: bold;">Timestamp:</td>
                            <td style="padding: 8px; border-bottom: 1px solid #dee2e6;">{datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}</td>
                        </tr>
                    </table>
                </div>
                
                <div style="margin-bottom: 20px;">
                    <h3 style="color: #495057;">Summary</h3>
                    <p style="background-color: #e9ecef; padding: 12px; border-radius: 4px; margin: 0;">
                        {analysis_result.get('summary', 'No summary available')}
                    </p>
                </div>
                
                <div style="margin-bottom: 20px;">
                    <h3 style="color: #495057;">Impact Assessment</h3>
                    <p style="background-color: #fff3cd; padding: 12px; border-radius: 4px; margin: 0; border-left: 4px solid #ffc107;">
                        {analysis_result.get('impact', 'Unknown impact')}
                    </p>
                </div>
                
                <div style="margin-bottom: 20px;">
                    <h3 style="color: #495057;">Recommended Actions</h3>
                    <ul style="background-color: #d1ecf1; padding: 15px; border-radius: 4px; border-left: 4px solid #17a2b8;">
                        {recommendations_html}
                    </ul>
                </div>
                
                <div style="background-color: #f8f9fa; padding: 15px; border-radius: 5px; border-left: 4px solid {'#dc3545' if analysis_result.get('requires_immediate_action') else '#28a745'};">
                    <h3 style="margin-top: 0; color: #495057;">Action Required</h3>
                    <p style="margin: 0; font-weight: bold; color: {'#dc3545' if analysis_result.get('requires_immediate_action') else '#28a745'};">
                        {'⚠️ IMMEDIATE ACTION REQUIRED' if analysis_result.get('requires_immediate_action') else '✅ No immediate action required'}
                    </p>
                    <p style="margin: 5px 0 0 0;">
                        <strong>Estimated Resolution Time:</strong> {analysis_result.get('estimated_resolution_time', 'Unknown')}
                    </p>
                </div>
                
                <div style="margin-top: 30px; padding: 15px; background-color: #e9ecef; border-radius: 5px; font-size: 12px; color: #6c757d;">
                    <p style="margin: 0;">This alert was automatically generated and analyzed by AWS Lambda with Amazon Bedrock.</p>
                    <p style="margin: 5px 0 0 0;">For more details, check your Meraki Dashboard or contact your network administrator.</p>
                </div>
            </div>
        </body>
        </html>
        """
    
    @staticmethod
    def create_text_body(analysis_result: Dict[str, Any], webhook_data: Dict[str, Any]) -> str:
        """
        Create plain text email body
        """
        severity = analysis_result.get('severity', 'UNKNOWN').upper()
        
        recommendations_text = "\n".join([f"{i}. {rec}" for i, rec in enumerate(analysis_result.get('recommendations', []), 1)])
        
        return f"""
MERAKI NETWORK ALERT
==================

SEVERITY: {severity}
ORGANIZATION: {webhook_data.get('organizationName', 'Unknown')}
NETWORK: {webhook_data.get('networkName', 'Unknown')}
ALERT TYPE: {webhook_data.get('alertType', 'Unknown')}
CATEGORY: {analysis_result.get('category', 'Unknown')}
TIMESTAMP: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}

SUMMARY
-------
{analysis_result.get('summary', 'No summary available')}

IMPACT ASSESSMENT
-----------------
{analysis_result.get('impact', 'Unknown impact')}

RECOMMENDED ACTIONS
-------------------
{recommendations_text}

ACTION REQUIRED
---------------
{'IMMEDIATE ACTION REQUIRED' if analysis_result.get('requires_immediate_action') else 'No immediate action required'}
Estimated Resolution Time: {analysis_result.get('estimated_resolution_time', 'Unknown')}

---
This alert was automatically generated and analyzed by AWS Lambda with Amazon Bedrock.
For more details, check your Meraki Dashboard or contact your network administrator.
        """.strip()


# Global processor instance
processor = MerakiAlertProcessor()

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    AWS Lambda entry point
    """
    return processor.process_webhook(event, context)

@lru_cache(maxsize=128)
def get_alert_context(alert_type: str) -> str:
    """
    Provide additional context based on alert type (cached for performance)
    """
    alert_contexts = {
        'sensor_change_detected': 'Environmental sensor reading has changed significantly',
        'appliance_connectivity_change': 'Network appliance connectivity status has changed',
        'client_connectivity_change': 'Client device connectivity status has changed',
        'settings_changed': 'Network or device configuration has been modified',
        'firmware_upgrade_started': 'Device firmware upgrade process has begun',
        'firmware_upgrade_completed': 'Device firmware upgrade has finished'
    }
    
    return alert_contexts.get(alert_type, 'Unknown alert type')
