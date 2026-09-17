class DatalinkScanner < Formula
  include Language::Python::Virtualenv

  desc "macOS interface for the Apperson DataLink 1200 optical mark scanner"
  homepage "https://github.com/dhohnholt/datalink_Mac_OS_interface"
  url "https://github.com/dhohnholt/datalink_Mac_OS_interface/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "ec78708925a5654f73621f2a65fa7291d6c9c7f2bdbd5e611b4c5d662947357b"
  license "MIT"
  head "https://github.com/dhohnholt/datalink_Mac_OS_interface.git", branch: "main"

  depends_on :macos
  depends_on "python@3.13"

  resource "pyserial" do
    url "https://files.pythonhosted.org/packages/1e/7d/ae3f0a63f41e4d2f6cb66a5b57197850f919f59e558159a4dd3a818f5082/pyserial-3.5.tar.gz"
    sha256 "3c77e014170dfffbd816e6ffc205e9842efb10be9f58ec16d3e8675b4925cddb"
  end

  def install
    virtualenv_install_with_resources

    # A launcher bundle so the workspace can be opened from the Dock or
    # Spotlight. It execs bin/datalink-scanner through the stable opt path,
    # so `brew upgrade` updates the app without rebuilding the bundle.
    system "packaging/make_app_bundle.sh",
           "--cli", opt_bin/"datalink-scanner",
           "--output", prefix,
           "--version", version,
           "--icon", "packaging/DataLinkScanner.icns"
  end

  def caveats
    <<~EOS
      To open the workspace from the Dock or Spotlight, link the app once:
        datalink-scanner install-app

      That symlinks it into /Applications, so future `brew upgrade` runs
      update the app in place.

      Or start it straight from a terminal:
        datalink-scanner

      The DataLink 1200 shows up as a USB serial port. If `datalink-scanner
      ports` lists nothing, install the Silicon Labs CP210x VCP driver and
      reconnect the scanner.

      Scans are saved locally to:
        ~/Library/Application Support/DataLink Scanner/captures
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/datalink-scanner --version")

    # `ports` exits 1 when no scanner is attached, which is the case on a
    # build machine; it still proves the entry point and imports resolve.
    output = shell_output("#{bin}/datalink-scanner ports", 1)
    assert_match "No USB serial ports found", output

    assert_predicate prefix/"DataLink Scanner.app/Contents/MacOS/DataLink Scanner", :executable?

    # The workspace must come up and serve its own UI without a scanner.
    port = free_port
    pid = spawn bin/"datalink-scanner", "serve", "--no-browser", "--port", port.to_s,
                "--capture-dir", testpath/"captures"
    begin
      sleep 3
      assert_match "Scanner workspace", shell_output("curl -s http://127.0.0.1:#{port}/")
    ensure
      Process.kill "TERM", pid
      Process.wait pid
    end
  end
end
