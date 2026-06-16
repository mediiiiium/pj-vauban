#!/bin/bash
# Usage: bash setup.sh <target-repo-path> [ecosystem: npm|pip|none]
#
# Examples:
#   bash setup.sh ~/now-on-tap npm
#   bash setup.sh ~/podcast pip
#   bash setup.sh ~/brewdrop none

set -e

TARGET="$1"
ECOSYSTEM="${2:-none}"
VAUBAN_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$TARGET" ]; then
  echo "Usage: bash setup.sh <target-repo-path> [npm|pip|none]"
  exit 1
fi

if [ ! -d "$TARGET/.git" ]; then
  echo "Error: $TARGET is not a git repository"
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"
echo "Setting up pj-vauban in: $TARGET (ecosystem: $ECOSYSTEM)"
echo ""

# 1. scripts/gemini_review.py
mkdir -p "$TARGET/scripts"
cp "$VAUBAN_DIR/scripts/gemini_review.py" "$TARGET/scripts/gemini_review.py"
echo "✓ scripts/gemini_review.py"

# 2. .pre-commit-config.yaml
cat > "$TARGET/.pre-commit-config.yaml" << 'EOF'
repos:
  - repo: https://github.com/Yelp/detect-secrets
    rev: v1.5.0
    hooks:
      - id: detect-secrets
        args: ['--baseline', '.secrets.baseline']

  - repo: local
    hooks:
      - id: gemini-review
        name: Gemini Code Review
        entry: python3 scripts/gemini_review.py
        language: system
        stages: [pre-push]
        pass_filenames: false
        always_run: true
        verbose: true
EOF
echo "✓ .pre-commit-config.yaml"

# 3. .github/workflows/semgrep.yml
mkdir -p "$TARGET/.github/workflows"
cat > "$TARGET/.github/workflows/semgrep.yml" << 'EOF'
name: Semgrep
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
  security-events: write   # SARIF を Security タブへ上げるのに必要
jobs:
  semgrep:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: pip install semgrep
      # 検出があれば --error で job を落とし push/PR をブロックする
      - name: Semgrep scan
        run: semgrep scan --config=auto --sarif --output=semgrep.sarif --error
      # ブロックされても結果は必ず残す。
      # Security タブへの上げは public/GHAS のみ可。private で未契約だと失敗するが
      # continue-on-error で job は落とさない（ブロックは scan 側が担う）。
      - name: Upload SARIF to GitHub Security
        if: always()
        continue-on-error: true
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: semgrep.sarif
      # private repo でも確認できるよう SARIF を成果物としても残す
      - name: Upload SARIF artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: semgrep-sarif
          path: semgrep.sarif
EOF
echo "✓ .github/workflows/semgrep.yml"

# 3b. .semgrepignore（誤検知の抑制ポイント）
if [ ! -f "$TARGET/.semgrepignore" ]; then
  cat > "$TARGET/.semgrepignore" << 'EOF'
# Semgrep のスキャン対象から除外するパス
# https://semgrep.dev/docs/ignoring-files-folders-code
#
# 個別の検出を黙らせたい場合は、該当行の直前に  # nosemgrep  コメントを置く。
node_modules/
.venv/
venv/
vendor/
dist/
build/
__pycache__/
*.min.js
EOF
  echo "✓ .semgrepignore（新規生成）"
else
  echo "✓ .semgrepignore（既存を維持）"
fi

# 4. .github/dependabot.yml（ecosystem 指定時のみ）
if [ "$ECOSYSTEM" != "none" ]; then
  cat > "$TARGET/.github/dependabot.yml" << EOF
version: 2
updates:
  - package-ecosystem: "$ECOSYSTEM"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      all-dependencies:
        patterns:
          - "*"
EOF
  echo "✓ .github/dependabot.yml (ecosystem: $ECOSYSTEM)"
fi

# 5. pre-commit フックのインストール
cd "$TARGET"

python3 -m pip install detect-secrets pre-commit google-genai --quiet --user

if [ ! -f ".secrets.baseline" ]; then
  python3 -m detect_secrets scan \
    --exclude-files 'node_modules/.*' \
    --exclude-files '\.venv/.*' \
    --exclude-files 'vendor/.*' \
    --exclude-files '__pycache__/.*' \
    --exclude-files 'dist/.*' \
    --exclude-files 'build/.*' \
    > .secrets.baseline
  echo "✓ .secrets.baseline（新規生成）"
else
  echo "✓ .secrets.baseline（既存を維持）"
fi

python3 -m pre_commit install
python3 -m pre_commit install --hook-type pre-push
echo "✓ pre-commit フック（commit + push）インストール済み"

echo ""
echo "完了: $TARGET"
echo ""
echo "残りの作業:"
echo "  1. GEMINI_API_KEY を環境変数に設定する"
echo "  2. GitHub Marketplace から Qodo Merge を連携する"
echo "  3. 作成されたファイルをコミット・プッシュする"
