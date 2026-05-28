root := justfile_directory()
dmg_path := root + "/dist/Voxa.dmg"

default:
  @just --list

package:
  ./scripts/package-macos.sh

install: package
  open "{{dmg_path}}"
