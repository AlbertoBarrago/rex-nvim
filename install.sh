#!/bin/sh
# Install rex-nvim by linking bin/rex-nvim into a directory on PATH.
#
# Usage: ./install.sh [BIN_DIR]    (default: $HOME/.local/bin)
#
# A symlink, not a copy: `git pull` in this clone updates the CLI and its
# libraries together, since rex-nvim resolves lib/ relative to its real path.
# Binding file types to nvim is a separate step (`rex-nvim install`) because
# macOS asks to confirm each one.
set -eu

repo_dir=$(cd "$(dirname "$0")" && pwd -P)
bin_dir=${1:-"$HOME/.local/bin"}
target="$bin_dir/rex-nvim"

for tool in zsh nvim jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "install.sh: $tool is required (brew install $tool)" >&2
    exit 1
  fi
done
if ! command -v rex >/dev/null 2>&1; then
  echo "install.sh: warning: rex is not on PATH; rex-nvim finds it inside Rex Server.app at run time" >&2
fi

mkdir -p "$bin_dir"
if [ -e "$target" ] && [ ! -L "$target" ]; then
  echo "install.sh: $target exists and is not a symlink; remove it first" >&2
  exit 1
fi
chmod +x "$repo_dir/bin/rex-nvim"
ln -sfn "$repo_dir/bin/rex-nvim" "$target"
echo "linked $target -> $repo_dir/bin/rex-nvim"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "note: $bin_dir is not on PATH; add it to your shell profile" ;;
esac

echo "done: run 'rex-nvim install' to make nvim the app for code files"
