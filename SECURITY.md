# Security

This is a local single-user editor. Keep the Docker port bound to localhost; public server hosting requires a separate security design. Do not put personal rolling footage, microphone recordings, project data, Apple keys, provisioning profiles or GitHub tokens into source control or public issues.

Report a security issue privately to the repository owner. This repository is public. Use GitHub private vulnerability reporting when enabled or contact the maintainer privately before sharing exploit details; do not put sensitive reports in public issues. No monitored security email address is claimed here.

GitHub Actions use read-only tokens and credential-free checkouts by default. Only the release-publishing job receives contents write permission. Apple signing is isolated in the `ios-release` environment and never runs for pull requests. Its temporary keychain, profile and API key are cleaned after use. Do not switch workflows to `pull_request_target` to run untrusted contribution code with secrets.

Dependabot opens dependency update PRs. Repository vulnerability alerts and automated security fixes are enabled by the setup script where the account supports them. Private-repository branch protection, environments and advanced security features depend on the GitHub plan; setup reports unsupported settings rather than claiming they are active.

The current source and native export implementation require the test gates described in docs/VERIFICATION.md. Physical iPhone acceptance and signing have not been established merely by a successful browser test.
