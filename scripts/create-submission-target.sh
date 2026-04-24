#!/bin/bash
set -e

# Impact Scholars Submission Target Creator
# Creates a target repo for PR review and opens the PR

export GH_PAGER=cat

DRY_RUN=false

usage() {
    echo "Usage: $0 [--dry-run] <author-repo-url> [target-repo-name]"
    echo ""
    echo "Arguments:"
    echo "  author-repo-url:    Full URL to author's repo (e.g., https://github.com/pollomarzo/paper-name)"
    echo "  target-repo-name:   Name for new repo in impact-scholars/ (auto-generated if omitted)"
    echo ""
    echo "Options:"
    echo "  --dry-run           Show what would be done without making changes"
    exit 1
}

# Parse arguments
if [ "$1" == "--dry-run" ]; then
    DRY_RUN=true
    shift
fi

if [ $# -lt 1 ]; then
    usage
fi

AUTHOR_REPO_URL="$1"
TARGET_NAME="${2:-}"
TEMPLATE_REPO="impact-scholars/isp-micropublication-template"
ORG="pollomarzo"

# Parse author info from URL
# Handle both https://github.com/USER/REPO and git@github.com:USER/REPO.git
if [[ "$AUTHOR_REPO_URL" =~ github\.com[/:]([^/]+)/([^/\.]+) ]]; then
    AUTHOR_USER="${BASH_REMATCH[1]}"
    AUTHOR_REPO="${BASH_REMATCH[2]}"
else
    echo "Error: Could not parse GitHub URL: $AUTHOR_REPO_URL"
    exit 1
fi

# Check gh CLI is installed and authenticated
if ! command -v gh &> /dev/null; then
    echo "Error: gh CLI not found. Install from https://cli.github.com/"
    exit 1
fi

gh auth status > /dev/null 2>&1 || { echo "Error: gh CLI not authenticated. Run 'gh auth login'"; exit 1; }

# Check required secrets are in environment (private repos don't inherit org secrets on free plan)
if [ -z "$CLOUDFLARE_API_TOKEN" ] || [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
    echo "Error: CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID must be set in environment"
    echo "  export CLOUDFLARE_API_TOKEN=..."
    echo "  export CLOUDFLARE_ACCOUNT_ID=..."
    exit 1
fi

# Verify author repo exists, is accessible, and is public
echo "=== Checking author repository ==="
REPO_INFO=$(gh api repos/$AUTHOR_USER/$AUTHOR_REPO 2>/dev/null) || {
    echo "Error: Repository not found or not accessible: $AUTHOR_USER/$AUTHOR_REPO"
    echo "Make sure:"
    echo "  - The URL is correct"
    echo "  - The repository exists"
    echo "  - The repository is public (required for cross-repo PRs)"
    exit 1
}

REPO_VISIBILITY=$(echo "$REPO_INFO" | jq -r '.visibility // .private')
if [ "$REPO_VISIBILITY" == "true" ] || [ "$REPO_VISIBILITY" == "private" ]; then
    echo "Error: Repository $AUTHOR_USER/$AUTHOR_REPO is private"
    echo "Submissions must be from public repositories."
    echo "Please make the repository public or contact the organizing team."
    exit 1
fi

echo "✓ Repository exists, is accessible, and is public"

# Auto-generate target name if not provided
if [ -z "$TARGET_NAME" ]; then
    # Format: author-repo-timestamp
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    TARGET_NAME="${AUTHOR_REPO}-${TIMESTAMP}"
fi

TARGET_REPO="$ORG/$TARGET_NAME"

echo ""
echo "=== Configuration ==="
echo "Dry run: $DRY_RUN"
echo "Author: $AUTHOR_USER/$AUTHOR_REPO"
echo "Target: $TARGET_REPO"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN MODE - No changes will be made ==="
    echo ""
    echo "Would execute:"
    echo "  1. gh repo create $TARGET_REPO --private --description 'Review target for $AUTHOR_USER/$AUTHOR_REPO'"
    echo "  2. gh secret set CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID on $TARGET_REPO"
    echo "  3. gh api repos/$AUTHOR_USER/$AUTHOR_REPO/contributors | invite each to $TARGET_REPO"
    echo "  4. git clone --branch bare --single-branch git@github.com:$TEMPLATE_REPO.git <temp-dir>"
    echo "  5. cd <temp-dir> && git checkout --orphan new-main && git commit -m 'startpoint'"
    echo "  6. git push git@github.com:$TARGET_REPO.git new-main:main --force"
    echo "  7. Create review branch: checkout author content, squash onto startpoint"
    echo "  8. Open PR: review → main"
    echo ""
    echo "=== Prerequisites check ==="
    if command -v gh &> /dev/null; then
        echo "✓ gh CLI installed"
        gh auth status 2>&1 | head -3 || echo "✗ gh CLI not authenticated"
    else
        echo "✗ gh CLI not found"
    fi
    if command -v git &> /dev/null; then
        echo "✓ git installed"
    else
        echo "✗ git not found"
    fi
    echo ""
    echo "PR would be: review branch → impact-scholars/$TARGET_NAME:main"
    exit 0
fi

echo "=== Step 1: Create target repo ==="
gh repo create "$TARGET_REPO" \
    --private \
    --description "Review target for $AUTHOR_USER/$AUTHOR_REPO" \
    || { echo "Failed to create repo (may already exist)"; exit 1; }

echo ""
echo "=== Step 2: Set Cloudflare secrets ==="
gh secret set CLOUDFLARE_API_TOKEN --repo "$TARGET_REPO" --body "$CLOUDFLARE_API_TOKEN" \
    && echo "  ✓ CLOUDFLARE_API_TOKEN set" \
    || { echo "Failed to set CLOUDFLARE_API_TOKEN"; exit 1; }
gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$TARGET_REPO" --body "$CLOUDFLARE_ACCOUNT_ID" \
    && echo "  ✓ CLOUDFLARE_ACCOUNT_ID set" \
    || { echo "Failed to set CLOUDFLARE_ACCOUNT_ID"; exit 1; }

echo ""
echo "=== Step 3: Grant contributors write access ==="
CONTRIBUTORS=$(gh api repos/$AUTHOR_USER/$AUTHOR_REPO/contributors --jq '.[].login' 2>/dev/null || true)
if [ -z "$CONTRIBUTORS" ]; then
    echo "⚠️  No contributors found, at least adding author ($AUTHOR_USER)..."
    CONTRIBUTORS="$AUTHOR_USER"
fi

echo "$CONTRIBUTORS" | while read -r username; do
    [ -z "$username" ] && continue
    # Skip the owner of the target repo — inviting the owner as collaborator returns 422
    if [ "$username" = "$ORG" ]; then
        echo "  Skipping $username (owner of $TARGET_REPO)"
        continue
    fi
    echo "  Inviting $username..."
    gh api repos/$TARGET_REPO/collaborators/$username \
        --method PUT \
        --field permission=push \
        2>/dev/null && echo "    ✓ Invited" || echo "    ⚠️  Failed (may already be collaborator)"
done

echo ""
echo "=== Step 4: Initialize main with single startpoint commit ==="
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

git clone --branch bare --single-branch "git@github.com:$TEMPLATE_REPO.git" "$TEMP_DIR"
cd "$TEMP_DIR"

# Create orphan branch with single commit
git checkout --orphan new-main
git add -A
git commit -m "startpoint" || { echo "Failed to create startpoint commit"; exit 1; }

# Remove origin and add new target
git remote remove origin
git remote add origin "git@github.com:$TARGET_REPO.git"
git push origin new-main:main --force

echo ""
echo "=== Step 5: Create review branch with author content ==="
# Fetch the main branch we just pushed from origin
echo "Fetching origin/main..."
git fetch origin main

# Add author repo as remote and fetch
git remote add author "https://github.com/$AUTHOR_USER/$AUTHOR_REPO.git"
echo "Fetching author/main..."
git fetch author main

# Create review branch from origin/main (bare skeleton)
git checkout -b review origin/main

# Remove bare skeleton files and replace with author content
git rm -rf .
git checkout author/main -- .

# Strip author's workflows and restore bare's publish.yml
# (author repo has validate.yml+deploy.yml; review target needs publish.yml)
rm -rf .github/workflows
git checkout origin/main -- .github/workflows/publish.yml

# Commit author content on top of bare history
git add -A
git commit -m "Submission from $AUTHOR_USER/$AUTHOR_REPO

Original repository: $AUTHOR_REPO_URL" || {
    echo "⚠️  No changes to commit (author content identical to bare)"
    exit 1
}

git push origin review

echo ""
echo "=== Step 6: Create PR ==="
PR_RESULT=$(gh api repos/$TARGET_REPO/pulls \
    --method POST \
    --field title="Submission: $AUTHOR_REPO" \
    --field head="review" \
    --field base="main" \
    --field body="Submitted by @$AUTHOR_USER

Original repository: $AUTHOR_REPO_URL

---

*This PR was created via the Impact Scholars submission workflow.*" 2>&1) || {
        echo "ERROR: Failed to create PR"
        echo "$PR_RESULT"
        exit 1
    }

echo "✓ PR created successfully!"
PR_URL=$(echo "$PR_RESULT" | jq -r '.html_url // empty' 2>/dev/null)
[ -n "$PR_URL" ] && echo "URL: $PR_URL"

echo ""
echo "=== Summary ==="
echo "Target repo: https://github.com/$TARGET_REPO"
echo "Author repo: $AUTHOR_REPO_URL"
echo "Contributors invited:"
echo "$CONTRIBUTORS" | sed 's/^/  - /'
[ -n "$PR_URL" ] && echo "PR: $PR_URL"
