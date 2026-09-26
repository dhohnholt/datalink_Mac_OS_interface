class DatalinkScanner < Formula
  include Language::Python::Virtualenv

  desc "macOS interface for the Apperson DataLink 1200 optical mark scanner"
  homepage "https://github.com/dhohnholt/datalink_Mac_OS_interface"
  url "https://github.com/dhohnholt/datalink_Mac_OS_interface/archive/refs/tags/v1.9.11.tar.gz"
  sha256 "f8e66236861158f0587db68ecdf2e19ccd35cfea096d6d07054aabc8b8d96153"
  license "MIT"
  head "https://github.com/dhohnholt/datalink_Mac_OS_interface.git", branch: "main"

  bottle do
    root_url "https://github.com/dhohnholt/datalink_Mac_OS_interface/releases/download/v1.9.11"
    sha256 cellar: :any, arm64_tahoe: "759a51bed38225f09bbce5231139b058efd734a1a00d3c8b1a57f6780946d04f"
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

  # Homebrew rewrites paths inside the keg when it pours a bottle, and that
  # rewriting breaks the ad-hoc signature the app bundle was built with:
  #
  #   nested code is modified or invalid
  #   file modified: .../Contents/MacOS/python-runtime
  #
  # An app in that state still opens from a terminal, because `open` does not
  # consult Gatekeeper, and Finder, the Dock and Launchpad refuse it with
  # "The application can't be opened" and no reason given.
  #
  # Relocation cannot be avoided: python-runtime carries a reference to
  # python@3.13's own Cellar path, so the bottle can never be
  # :any_skip_relocation. The seal has to be remade afterwards instead, which
  # is what this does. Signing is inner-out, and writes only inside the
  # prefix, which is the one thing a sandboxed formula phase is allowed to do.
  #
  # Homebrew skips post_install when building a bottle, so this runs on the
  # poured upgrades everybody gets, not on the maintainer's own release.
  # `brew postinstall datalink-scanner` runs it by hand.
  def post_install
    app = prefix/"DataLink Scanner.app"
    return unless app.exist?

    runtime = app/"Contents/MacOS/python-runtime"
    system "/usr/bin/codesign", "--force", "--sign", "-", runtime if runtime.exist?
    system "/usr/bin/codesign", "--force", "--sign", "-", app
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
