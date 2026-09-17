class DatalinkScanner < Formula
  include Language::Python::Virtualenv

  desc "macOS interface for the Apperson DataLink 1200 optical mark scanner"
  homepage "https://github.com/dhohnholt/datalink_Mac_OS_interface"
  url "https://github.com/dhohnholt/datalink_Mac_OS_interface/archive/refs/tags/v1.7.2.tar.gz"
  sha256 "487613941ae988fbd27a177b9ae5b42daaa0b62fd78e3f0125a3d37ccc3dfd6b"
  license "MIT"
  head "https://github.com/dhohnholt/datalink_Mac_OS_interface.git", branch: "main"

  bottle do
    root_url "https://github.com/dhohnholt/datalink_Mac_OS_interface/releases/download/v1.7.2"
    sha256 cellar: :any, arm64_tahoe: "0275e8b28130720776c4142dd6d6e701227945bd047d3b60b1721f321d74b660"
  end


  depends_on :macos
  depends_on "python@3.13"

  resource "pyserial" do
    url "https://files.pythonhosted.org/packages/1e/7d/ae3f0a63f41e4d2f6cb66a5b57197850f919f59e558159a4dd3a818f5082/pyserial-3.5.tar.gz"
    sha256 "3c77e014170dfffbd816e6ffc205e9842efb10be9f58ec16d3e8675b4925cddb"
  end

  resource "pyobjc-core" do
    url "https://files.pythonhosted.org/packages/a5/78/abc4ce5920305780aeb36b4067a86253378b36e29ba96673a3deb02eb03a/pyobjc_core-12.2.2.tar.gz"
    sha256 "3906452339cd06a3bb07df103c2511d4cb0f7a22d8771c0b802eba15d9a642b6"
  end

  resource "pyobjc-framework-Cocoa" do
    url "https://files.pythonhosted.org/packages/75/76/49c6da2c6a831020b4854ba20079d5a1030474bffc776b7b73c2eeff8c15/pyobjc_framework_cocoa-12.2.2.tar.gz"
    sha256 "c96c0ef69a71afbbb0e6a7d594b455c5fe47d62e0db376ee7a2b4b828c16ace9"
  end

  resource "pyobjc-framework-Quartz" do
    url "https://files.pythonhosted.org/packages/35/b1/426a37c7ae37280b3ffca2571fb48f211946aee2f4ca31a603ed1943c4a7/pyobjc_framework_quartz-12.2.2.tar.gz"
    sha256 "810f97b210cfd93704d240860286dfd6df09f9f1c52525fc5c2166723aea3f9e"
  end

  resource "pyobjc-framework-WebKit" do
    url "https://files.pythonhosted.org/packages/6f/1f/766e338197f7051c25f23cb0d350caa88234b31c3a759127f2cbb67f3376/pyobjc_framework_webkit-12.2.2.tar.gz"
    sha256 "e5588df2a73b377b59a994cc2a78b467e4341f4e4d28b52e8671e21a2811d3c1"
  end

  def install
    virtualenv_install_with_resources

    # A launcher bundle so the workspace can be opened from the Dock or
    # Spotlight. It execs bin/datalink-scanner through the stable opt path,
    # so `brew upgrade` updates the app without rebuilding the bundle.
    # --python lets the bundle carry its own copy of the framework interpreter,
    # without which macOS names the app "Python" in the Dock.
    system "packaging/make_app_bundle.sh",
           "--cli", opt_bin/"datalink-scanner",
           "--python", libexec/"bin/python",
           "--output", prefix,
           "--version", version,
           "--icon", "src/datalink_scanner/resources/DataLinkScanner.icns"
  end

  def caveats
    <<~EOS
      To open the workspace from the Dock or Spotlight, link the app once:
        datalink-scanner install-app

      That symlinks it into /Applications, so future `brew upgrade` runs
      update the app in place.

      Or start it straight from a terminal:
        datalink-scanner

      `datalink-scanner serve` opens the same workspace in a web browser
      instead, which is useful for troubleshooting.

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

    # Without the interpreter inside the bundle, macOS calls the app "Python".
    assert_predicate prefix/"DataLink Scanner.app/Contents/MacOS/python-runtime", :executable?

    # The native app cannot run headless on a build machine, but the server
    # behind it can, and that is what would break on a packaging mistake.
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
