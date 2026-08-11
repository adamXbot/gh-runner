cask "runner-menu" do
  # TEMPLATE — rendered by the shared release workflow
  # (privacykey/gh-workflows macos-sparkle-release.yml): @@VERSION@@,
  # @@SHA256@@ and @@URL@@ are substituted per release and the result is
  # pushed to adamXbot/homebrew-tap/Casks/runner-menu.rb. Do not hand-edit
  # version/sha256/url here.
  version "@@VERSION@@"
  sha256 "@@SHA256@@"

  url "@@URL@@"
  name "Runner Menu"
  desc "Menu-bar app for managing GitHub Actions self-hosted runners"
  homepage "https://github.com/adamXbot/gh-runner"

  # Sparkle's appcast lives on gh-pages. Linking it here lets Cask users
  # confirm the version they are installing matches what the in-app updater
  # would fetch.
  livecheck do
    url "https://adamxbot.github.io/gh-runner/appcast.xml"
    strategy :sparkle
  end

  app "Runner Menu.app"

  # A runner keeps working after the app quits — it is a launchd agent, not a
  # child process — so uninstalling the app does not stop CI. Anything that
  # would tear runners down belongs in the app's own unregister flow, where
  # the consequence is visible, not in a cask uninstall.
  zap trash: [
    "~/Library/Application Support/RunnerMenu",
    "~/Library/Caches/com.kostarelas.RunnerMenu",
    "~/Library/Preferences/com.kostarelas.RunnerMenu.plist",
    "~/Library/Saved Application State/com.kostarelas.RunnerMenu.savedState",
  ]
end
