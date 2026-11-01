# Homebrew formula, served straight from this repo (no separate tap repo needed):
#   brew tap rohiitgit/nohog https://github.com/rohiitgit/nohog
#   brew install nohog
# Builds from source with the Command Line Tools, so no Apple Developer signing is involved.
# On each release: update `url` and `sha256` (shasum -a 256 of the tag's .tar.gz).
class Nohog < Formula
  desc "Keep Spotlight from indexing node_modules and other dev junk"
  homepage "https://github.com/rohiitgit/nohog"
  url "https://github.com/rohiitgit/nohog/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "FILL_IN_AFTER_TAGGING"
  license "MIT"
  head "https://github.com/rohiitgit/nohog.git", branch: "main"

  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin_path = Utils.safe_popen_read("swift", "build", "-c", "release", "--show-bin-path").chomp
    bin.install "#{bin_path}/nohog"
  end

  service do
    run [opt_bin/"nohog", "watch"]
    keep_alive successful_exit: false
    process_type :background
    log_path "#{Dir.home}/Library/Logs/nohog.log"
    error_log_path "#{Dir.home}/Library/Logs/nohog.log"
  end

  def caveats
    <<~EOS
      Start the background agent (runs at login, survives upgrades):
        brew services start nohog
      To stop it and remove every exclusion nohog added:
        brew services stop nohog && nohog uninstall
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/nohog --version").strip
  end
end
