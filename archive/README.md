# Archive Directory

This directory contains older versions and unused files that have been superseded by the current implementation.

## Archived Files

### `cloudformation-template-with-logging.yaml`
- **Archived on**: July 2, 2025
- **Reason**: Superseded by the main `cloudformation-template.yaml` which includes enhanced features like:
  - Regional Bedrock model auto-selection
  - API key authentication
  - Improved IAM roles and permissions
  - Better CloudWatch integration

### `deploy.sh`
- **Archived on**: July 2, 2025  
- **Reason**: Superseded by `deploy-advanced.sh` which includes:
  - Interactive configuration setup
  - Enhanced error handling and validation
  - API key management integration
  - Better deployment feedback and monitoring
  - Configuration persistence

## Current Active Files

For the latest implementation, use these files in the parent directory:

- `cloudformation-template.yaml` - Main CloudFormation template
- `deploy-advanced.sh` - Advanced deployment script
- `manage-api-key.sh` - API key management utility
- `lambda.py` - Lambda function code
- `check-bedrock-models.sh` - Bedrock model availability checker
- `requirements.txt` - Python dependencies
- `README.md` - Complete documentation

## Recovery

If you need to restore any archived files, they can be moved back to the parent directory:

```bash
# Example: Restore the old deploy script
mv archive/deploy.sh ./deploy-old.sh
```

However, it's recommended to use the current active files as they include all the latest features and improvements.
