cask "svc" do
  on_arm do
    version "2.2.0"
    sha256 "3a1c5cdf577d21414fc7892b5d3cc8d50aabe39a8a115e9cc7737f2f2562d91e"

    url "https://github.com/mose-x/svc/releases/download/v#{version}/svc-#{version}-macos-arm64.dmg"
  end
  on_intel do
    version "2.2.0"
    sha256 "c2e8f94448380e6011da79dd140d78a04991978775cb1aa9c8979c6bb67995b1"

    url "https://github.com/mose-x/svc/releases/download/v#{version}/svc-#{version}-macos-x64.dmg"
  end

  name "svc"
  desc "Manage multiple SDK versions (Node.js, JDK, Go, Python, Rust) in one app"
  homepage "https://github.com/mose-x/svc"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on :macos

  app "svc.app"

  uninstall quit: "com.wails.svc"

  zap trash: [
    "~/Library/Caches/com.wails.svc",
    "~/Library/HTTPStorages/com.wails.svc",
    "~/Library/Preferences/com.wails.svc.plist",
    "~/Library/Saved Application State/com.wails.svc.savedState",
    "~/Library/WebKit/com.wails.svc",
  ]

  caveats do
    <<~EOS
      The app is not code signed, so the first launch may be blocked by
      Gatekeeper: right-click svc in /Applications, choose Open, then confirm
      Open in the dialog.

      svc keeps every managed SDK, its shims and its settings in ~/.svc, and
      `svc init` adds one `source ~/.svc.rc` line to your shell rc. None of
      that is removed by `brew uninstall`, and `brew uninstall --zap` only
      clears the app's own Library files. Delete ~/.svc, ~/.svc.rc and the
      source line yourself for a complete cleanup.
    EOS
  end
end
