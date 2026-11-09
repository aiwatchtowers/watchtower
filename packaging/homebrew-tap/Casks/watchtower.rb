cask "watchtower" do
  version "0.26.5"
  sha256 "fa9c207e2a48bfcf27ce1179fb4f6e3f046ee8052ae7d9bb1b1c69c52e89f4a7"

  url "https://github.com/aiwatchtowers/watchtower/releases/download/v#{version}/Watchtower-#{version}-arm64.zip"
  name "Watchtower"
  desc "Reads Slack, mail, calendar and Jira and gives coding agents a board"
  homepage "https://aiwatchtowers.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Watchtower.app"
  binary "#{appdir}/Watchtower.app/Contents/MacOS/watchtower"

  zap trash: [
    "~/.config/watchtower",
    "~/.local/share/watchtower",
    "~/Library/Application Support/Watchtower",
    "~/Library/Caches/com.watchtower.desktop",
    "~/Library/HTTPStorages/com.watchtower.desktop",
    "~/Library/Preferences/com.watchtower.desktop.plist",
    "~/Library/Saved Application State/com.watchtower.desktop.savedState",
    "~/Library/WebKit/com.watchtower.desktop",
  ]
end
