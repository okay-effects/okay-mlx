#!/bin/sh
# okay-mlx's installer (macOS, Apple Silicon): the release's native gateway and MLX's libraries in ~/.okay-mlx, the
# command `okay-mlx` in ~/.local/bin.
#   curl -fsSL https://raw.githubusercontent.com/okay-effects/okay-mlx/master/install.sh | sh
# OKAY_MLX_VERSION=0.1.0 for a given release (the latest by default). Nothing is run as root.
set -eu
repo=okay-effects/okay-mlx
version=${OKAY_MLX_VERSION:-latest}
home="$HOME/.okay-mlx"
cmd_dir="$HOME/.local/bin"
asset=okay-mlx-macos-arm64.tar.gz

say() { printf '%s\n' "$*"; }
fail() { printf 'okay-mlx: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || fail "MLX needs a Mac with Apple Silicon"
command -v curl >/dev/null || fail "curl is needed"
if [ "$version" = latest ]; then url="https://github.com/$repo/releases/latest/download/$asset"
else url="https://github.com/$repo/releases/download/v$version/$asset"; fi
mkdir -p "$home" "$cmd_dir"
say "downloading $url"
curl -fL --progress-bar -o "$home/$asset" "$url" || fail "the download failed"
rm -rf "$home/bin" "$home/lib"
tar xzf "$home/$asset" -C "$home" && rm "$home/$asset"

# the command: the gateway (`okay-mlx serve 8090`, ask, bench), and `okay-mlx service install|uninstall|status`
cat > "$cmd_dir/okay-mlx" <<'LAUNCHER'
#!/bin/sh
# okay-mlx's command (made by install.sh)
set -eu
bin="$HOME/.okay-mlx/bin/okay-mlx"
label=io.github.okay-effects.okay-mlx
plist="$HOME/Library/LaunchAgents/$label.plist"
log="$HOME/.okay-mlx/serve.log"
service() {
  case "${1:-}" in
    install)
      # the model loaded first (the argument, else MLX_MODEL, else Qwen3-4B), the port (8090)
      model=${2:-${MLX_MODEL:-mlx-community/Qwen3-4B-4bit}}; port=${3:-8090}
      mkdir -p "$HOME/Library/LaunchAgents"
      cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$bin</string><string>serve</string><string>$port</string></array>
  <key>EnvironmentVariables</key><dict><key>MLX_MODEL</key><string>$model</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict></plist>
PLIST
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$plist"
      echo "okay-mlx serves http://127.0.0.1:$port now, and with every login ($model first); its log: $log" ;;
    uninstall)
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true; rm -f "$plist"
      echo "okay-mlx no longer starts by itself" ;;
    status)
      launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -E "^\s*(state|pid) =" || echo "not installed"
      grep -E "loaded:|closed:" "$log" 2>/dev/null | tail -1 ;;
    *) echo "okay-mlx service install [model] [port] | uninstall | status"; exit 1 ;;
  esac
}
if [ "${1:-}" = service ]; then shift; service "$@"; exit; fi
exec "$bin" "$@"
LAUNCHER
chmod +x "$cmd_dir/okay-mlx"

say ""
say "okay-mlx installed: $cmd_dir/okay-mlx"
case ":$PATH:" in
  *":$cmd_dir:"*) ;;
  *) say "add it to your PATH: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
say "models come from the HuggingFace cache: e.g. hf download mlx-community/Qwen3.6-35B-A3B-4bit"
say ""
say "a question:          okay-mlx ask What is a KV cache?"
say "the gateway:         okay-mlx serve 8090"
say "or with every login: okay-mlx service install mlx-community/Qwen3.6-35B-A3B-4bit"
