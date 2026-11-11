#!/usr/bin/env bash

set -euo pipefail

FORMULA_CLASS=""
HOMEPAGE=""
VERSION=""
URL=""
SHA256=""
DESCRIPTION="CLI tool for interacting with iOS Simulators via accessibility and HID APIs"
LICENSE_NAME="MIT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --formula-class)
      FORMULA_CLASS="${2:-}"
      shift 2
      ;;
    --homepage)
      HOMEPAGE="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --url)
      URL="${2:-}"
      shift 2
      ;;
    --sha256)
      SHA256="${2:-}"
      shift 2
      ;;
    --description)
      DESCRIPTION="${2:-}"
      shift 2
      ;;
    --license)
      LICENSE_NAME="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$FORMULA_CLASS" || -z "$HOMEPAGE" || -z "$VERSION" || -z "$URL" || -z "$SHA256" ]]; then
  echo "Missing required arguments" >&2
  echo "Usage: $0 --formula-class CLASS --homepage URL --version VERSION --url URL --sha256 SHA256 [--description TEXT] [--license NAME]" >&2
  exit 1
fi

# Homebrew reads a release version from the URL; staging URLs need it stated.
VERSION_LINE="  version \"${VERSION}\"
"
if [[ "$URL" == *"v${VERSION}.tar.gz" ]]; then
  VERSION_LINE=""
fi

cat <<EOF
class ${FORMULA_CLASS} < Formula
  desc "${DESCRIPTION}"
  homepage "${HOMEPAGE}"
  url "${URL}"
${VERSION_LINE}  sha256 "${SHA256}"
  license "${LICENSE_NAME}"

  depends_on macos: :sonoma

  def install
    libexec.install "axe", "Frameworks", "AXe_AXe.bundle"
    bin.write_exec_script libexec/"axe"
  end

  # The archive ships unsigned; sign the frameworks, then the executable that loads them.
  post_install_steps do
    run "/usr/bin/codesign", args: [
      "--force", "--sign", "-", "--timestamp=none",
      "{{libexec}}/Frameworks/FBControlCore.framework",
      "{{libexec}}/Frameworks/FBSimulatorControl.framework",
      "{{libexec}}/axe"
    ]
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/axe --version")
  end
end
EOF
