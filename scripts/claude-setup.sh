#!/bin/bash
# claude-setup.sh - Set up Claude Code environment for this project
#
# Run this once after cloning the repository to configure Claude Code
# to automatically source env.sh on session start.

set -e

# WORKSPACE is parent of the git repo (jetson-pkvm)
WORKSPACE="$(cd "$(git rev-parse --show-toplevel)/.." && pwd)"
CLAUDE_DIR="${WORKSPACE}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.local.json"

mkdir -p "$CLAUDE_DIR"

# The hook pre-sets WORKSPACE then sources env.sh content
cat > "$SETTINGS_FILE" << EOF
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'export WORKSPACE=${WORKSPACE}' >> \"\$CLAUDE_ENV_FILE\" && tail -n +2 '${WORKSPACE}/env.sh' >> \"\$CLAUDE_ENV_FILE\""
          }
        ]
      }
    ]
  }
}
EOF

echo "Created ${SETTINGS_FILE}"
echo "WORKSPACE=${WORKSPACE}"
echo "Claude Code will now auto-source env.sh on session start."
