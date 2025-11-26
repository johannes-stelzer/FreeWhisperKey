class Freewhisperkey < Formula
  desc "Menu bar push-to-talk transcription utility powered by whisper.cpp"
  homepage "https://github.com/johannes-stelzer/FreeWhisperKey"
  url "https://github.com/johannes-stelzer/FreeWhisperKey/archive/refs/heads/main.tar.gz"
  sha256 "9f5db6edb165e901f531504b564b918efeff28ba4d8085fdc82461221b43c794"
  version "0.0.0"
  license "BSD-3-Clause"

  depends_on "swift" => :build

  def install
    system "swift", "build", "-c", "release"
    bin.install ".build/release/FreeWhisperKey"
  end

  test do
    assert_match "Mach-O", shell_output("file #{bin}/FreeWhisperKey")
  end

  service do
    run [opt_bin/"FreeWhisperKey"]
    keep_alive true
    log_path var/"log/freewhisperkey.log"
    error_log_path var/"log/freewhisperkey.log"
  end
end
