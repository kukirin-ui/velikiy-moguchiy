# Sourced by the scripts in Scripts/ (from the ios folder).

# Value of a build setting for one configuration, as the build sees it:
# Config/Secrets.xcconfig (local, git-ignored) wins over Config/<configuration>.xcconfig,
# and a NAME[config=<configuration>] line wins over a plain NAME line.
#   xcconfig_setting Release VELIKIY_MOGUCHIY_APP_BUNDLE_IDENTIFIER
xcconfig_setting() {
  local configuration=$1 name=$2 file value
  for file in Config/Secrets.xcconfig "Config/$configuration.xcconfig"; do
    [[ -f "$file" ]] || continue
    value=$(grep -E "^$name\\[config=$configuration\\] *=" "$file" | tail -1 | sed -E 's/^[^]]*\] *= *//' || true)
    [[ -n "$value" ]] || value=$(grep -E "^$name *=" "$file" | tail -1 | sed -E 's/^[^=]*= *//' || true)
    if [[ -n "$value" ]]; then
      print -r -- "$value"
      return 0
    fi
  done
  return 0
}

# A Secrets.xcconfig from before the rename defines GOVORUN_* settings, which the build
# no longer reads: it would silently use the public com.example ids instead of yours.
require_renamed_secrets() {
  if [[ -f Config/Secrets.xcconfig ]] && grep -q '^GOVORUN_' Config/Secrets.xcconfig; then
    print -u2 "Config/Secrets.xcconfig still uses GOVORUN_* settings; rename them once:"
    print -u2 "  sed -i '' 's/^GOVORUN_/VELIKIY_MOGUCHIY_/' Config/Secrets.xcconfig"
    exit 1
  fi
}
