# Contributing to Meraki Webhook Alert Processor

Thank you for your interest in contributing to the Meraki Webhook Alert Processor! This document provides guidelines for contributing to the project.

## Code of Conduct

By participating in this project, you agree to maintain a respectful and inclusive environment for all contributors.

## How to Contribute

### Reporting Bugs

Before reporting a bug, please:
1. Check the existing issues to avoid duplicates
2. Ensure you're using the latest version
3. Include detailed reproduction steps
4. Provide relevant log outputs and error messages

### Suggesting Features

Feature requests are welcome! Please:
1. Check existing issues for similar requests
2. Provide a clear description of the feature
3. Explain the use case and benefits
4. Consider implementation complexity

### Submitting Changes

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature/your-feature-name`
3. **Make your changes** with clear, descriptive commits
4. **Test thoroughly** including:
   - Lambda function functionality
   - CloudFormation template validation
   - Deployment scripts
   - Documentation updates
5. **Update documentation** as needed
6. **Submit a pull request** with:
   - Clear description of changes
   - Reference to related issues
   - Test results and screenshots if applicable

## Development Guidelines

### Code Style

- Follow Python PEP 8 guidelines
- Use meaningful variable and function names
- Include docstrings for functions and classes
- Keep functions focused and concise

### Testing

- Test changes in a development AWS environment
- Validate CloudFormation templates before submitting
- Ensure deployment scripts work across different environments
- Test with different AWS regions where applicable

### Documentation

- Update README.md for significant changes
- Include code comments for complex logic
- Update CloudFormation parameter descriptions
- Add examples for new features

## Project Structure

Please maintain the established project structure:
- Core production files in root directory
- Development/testing tools in `archive/development-tools/`
- Documentation updates in README.md

## Security Considerations

- Never commit AWS credentials or sensitive data
- Review IAM permissions for least privilege
- Validate input sanitization for security
- Consider security implications of changes

## Questions?

Feel free to open an issue for questions about contributing or reach out to the maintainers.

Thank you for contributing! 🚀
