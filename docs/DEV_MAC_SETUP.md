# Set up a development Mac

This playbook prepares your **personal development account** to build and test Runner Menu. It
installs the GitHub CLI and ShellCheck, and verifies macOS and Swift requirements. You can rerun it
after an interrupted setup; installed formulas stay installed. It does not create a macOS user,
register a GitHub Actions runner, or store a GitHub credential.

## First-time bootstrap

1. Install Apple's Command Line Tools if they are not already present:

   ```bash
   xcode-select --install
   ```

   Finish the installer before continuing. A full Xcode installation is optional for this Swift
   package. The playbook requires macOS 14+ and Swift 6+.

2. Install [Homebrew](https://brew.sh/) using its official instructions, then install Ansible:

   ```bash
   brew install ansible
   ```

3. Clone this repository and run the local playbook from your own account:

   ```bash
   git clone https://github.com/adamXbot/gh-runner.git
   cd gh-runner
   ansible-galaxy collection install -r ansible/requirements.yml
   ansible-playbook ansible/dev-mac.yml
   ```

   The playbook runs locally without `sudo`. It works with native Homebrew on Apple Silicon or Intel
   Macs. If you already manage your Mac with Ansible, copy the playbook and the
   `community.general` collection requirement into that repository, or import the playbook from
   your existing site playbook.

4. Verify the checkout:

   ```bash
   ./run-tests.sh
   swift build
   ./build-app.sh
   open build/RunnerMenu.app
   ```

   For GitHub integration, run `gh auth login --hostname github.com --scopes repo` interactively in
   your development account. Keep long-lived GitHub credentials out of Ansible variables and
   inventories.

## If this Mac will also run CI jobs

Treat that as a separate setup. From the administrator account, read
[the runner hardening guide](RUNNER_HARDENING.md) and run
`./scripts/setup-macos-ci-account.sh` to preview creation of the standard `runner` account. Apply
it with `--apply` only when ready to choose that account's password. Sign in to `runner` once, then
use [the fleet registration guide](RUNNER_FLEET.md#registering-runners) to register private
repositories with short-lived tokens. Keep personal credentials and signing identities out of that
account. Runner Menu's dedicated-account mode needs a Developer ID-signed and notarized app in
`/Applications` to monitor those jobs.
