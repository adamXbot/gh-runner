# Security Policy

Runner Menu controls GitHub Actions self-hosted runners and invokes trusted local tools. Security
reports are taken seriously.

## Supported versions

Before the first tagged release, security fixes are made on the `main` branch. After releases begin,
only the latest release and `main` will receive security updates.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting flow: open the repository's **Security** tab, choose
**Advisories**, and select **Report a vulnerability**. If private reporting is temporarily
unavailable, contact a maintainer privately through the contact method on their GitHub profile and
ask for a secure reporting channel. Do not send sensitive details publicly.

Include, where possible:

- A description of the issue and its potential impact.
- A minimal reproduction or proof of concept.
- The affected commit or version and macOS version.
- Any suggested mitigation.

Remove credentials, runner registration or removal tokens, repository secrets, personal paths, and
sensitive job output from all reports and attachments.

You should receive an acknowledgement within five business days and a status update within ten
business days. Remediation and disclosure timing will depend on severity and complexity. Please
allow time for a fix before public disclosure.

## Security-sensitive areas

Reports involving command execution, path handling, runner registration tokens, update integrity,
archive extraction, process control, or unintended disclosure of runner logs are especially useful.

The security policy covers Runner Menu itself. Vulnerabilities in GitHub Actions Runner, GitHub CLI,
Swift, or macOS should also be reported to their respective maintainers.
