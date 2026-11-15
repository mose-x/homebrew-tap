class NvmRust < Formula
  desc "Blazing-fast Node.js version manager written in Rust"
  homepage "https://github.com/mose-x/nvm-rust"
  license "MIT"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/mose-x/nvm-rust/releases/download/v2.4.0/nvm-2.4.0-macos-arm64.tar.gz"
      sha256 "109d5ecf4a275fe9eb034f381b7110ae093f8f2a4090b93edf525718c3aecd23"
    else
      url "https://github.com/mose-x/nvm-rust/releases/download/v2.4.0/nvm-2.4.0-macos-x64.tar.gz"
      sha256 "9f2d4b57727429449d6b96afd1ab18ce81aabcb1724fbe9632a20bad5c45863f"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/mose-x/nvm-rust/releases/download/v2.4.0/nvm-2.4.0-linux-arm64.tar.gz"
      sha256 "abaaeb509366db34a22b6a335c0c9dcf12f17ab69248de6c8a0d1659865114c0"
    else
      url "https://github.com/mose-x/nvm-rust/releases/download/v2.4.0/nvm-2.4.0-linux-x64.tar.gz"
      sha256 "67b85f6ecbd5fe37abf93b3eeb5d2475eb2a6682d86364f448d6dd15bf9c8509"
    end
  end

  def install
    bin.install "nvm"
    libexec.install "shell" if File.directory?("shell")
  end

  def caveats
    <<~EOS
      Run `nvm init` once to create the shims, completions and shell config
      (it appends a few lines to ~/.zshrc or ~/.bashrc).

      nvm keeps its state and every installed Node.js version in ~/.nvm.rust.

      Before `brew uninstall nvm-rust`, run:
        nvm uninstall --self
      to clean up the shell configuration it added.
    EOS
  end

  test do
    assert_match "nvm", shell_output("#{bin}/nvm --version")
  end
end
