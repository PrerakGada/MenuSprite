#!/usr/bin/env python3
"""Render a checksum-pinned cask from the exact release archive."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("archive", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
version = json.loads((Path(__file__).resolve().parent.parent / 'distribution/version.json').read_text())
assert args.archive.name == version['archive_asset'], 'Archive does not match the release manifest'
checksum = hashlib.file_digest(args.archive.open("rb"), "sha256").hexdigest()
body = '''# frozen_string_literal: true

cask "menusprite" do
  version "HOMEBREW_VERSION"
  sha256 "CHECKSUM"

  url "https://github.com/PrerakGada/menusprite-releases/releases/download/v#{version.csv.first}-preview.1/MenuSprite-#{version.csv.first}-preview.1-arm64.zip"
  name "MenuSprite"
  desc "Customizable menu bar system monitor"
  homepage "https://github.com/PrerakGada/menusprite-releases"

  livecheck do
    url "https://raw.githubusercontent.com/PrerakGada/menusprite-releases/main/version.json"
    strategy :json do |json|
      json["homebrew_version"]
    end
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "MenuSprite.app"

  uninstall quit: "in.prerakgada.MenuSprite"

  zap trash: [
    "~/Library/Application Support/MenuSprite",
    "~/Library/Caches/in.prerakgada.MenuSprite",
    "~/Library/Preferences/in.prerakgada.MenuSprite.plist",
    "~/Library/Saved Application State/in.prerakgada.MenuSprite.savedState",
  ]
end
'''.replace("CHECKSUM", checksum).replace("HOMEBREW_VERSION", version['homebrew_version']).replace('preview.1', version['channel'])
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(body)
print(args.output)
