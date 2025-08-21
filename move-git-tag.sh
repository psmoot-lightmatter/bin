#!/bin/bash

# Script to move a Git tag from one commit to another
# Handles both lightweight and annotated tags
#
# Usage: move_git_tag.sh <tag_name> <new_ref>
#
# Parameters:
#   tag_name: The name of the tag to move
#   new_ref:  The commit hash, branch name, or other Git reference where the tag should be moved
#
# Examples:
#   ./move_git_tag.sh v1.0.0 abc1234
#   ./move_git_tag.sh release-tag main
#   ./move_git_tag.sh v2.1.0 HEAD~1

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to show usage
show_usage() {
    echo "Usage: $0 <tag_name> <new_ref>"
    echo ""
    echo "Move a Git tag from its current location to a new commit."
    echo "Handles both lightweight and annotated tags."
    echo ""
    echo "Parameters:"
    echo "  tag_name    Name of the tag to move"
    echo "  new_ref     Target commit (hash, branch name, or Git reference)"
    echo ""
    echo "Examples:"
    echo "  $0 v1.0.0 abc1234"
    echo "  $0 release-tag main"
    echo "  $0 v2.1.0 HEAD~1"
    echo ""
    echo "Options:"
    echo "  -h, --help  Show this help message"
}

# Check for help flag
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
fi

# Validate arguments
if [[ $# -ne 2 ]]; then
    print_error "Invalid number of arguments."
    echo ""
    show_usage
    exit 1
fi

TAG_NAME="$1"
NEW_REF="$2"

# Validate we're in a Git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not in a Git repository."
    exit 1
fi

# Check if the tag exists
if ! git rev-parse --verify "refs/tags/$TAG_NAME" > /dev/null 2>&1; then
    print_error "Tag '$TAG_NAME' does not exist."
    exit 1
fi

# Validate the new reference
if ! git rev-parse --verify "$NEW_REF" > /dev/null 2>&1; then
    print_error "Invalid reference '$NEW_REF'. Please provide a valid commit hash, branch name, or Git reference."
    exit 1
fi

# Get the full commit hash for the new reference
NEW_COMMIT=$(git rev-parse "$NEW_REF")
print_info "Target commit: $NEW_COMMIT"

# Get current tag information
# Use ^{commit} to resolve annotated tags to their target commit
CURRENT_COMMIT=$(git rev-parse "refs/tags/$TAG_NAME^{commit}")
print_info "Current tag '$TAG_NAME' points to: $CURRENT_COMMIT"

# Check if the tag is already at the target commit
if [[ "$CURRENT_COMMIT" == "$NEW_COMMIT" ]]; then
    print_warning "Tag '$TAG_NAME' is already pointing to commit $NEW_COMMIT"
    exit 0
fi

# Determine if it's an annotated tag or lightweight tag
TAG_TYPE=""
if git cat-file -t "refs/tags/$TAG_NAME" | grep -q "tag"; then
    TAG_TYPE="annotated"
    print_info "Detected annotated tag"

    # Get tag message and tagger information
    TAG_MESSAGE=$(git tag -l --format='%(contents)' "$TAG_NAME")
    TAG_TAGGER=$(git tag -l --format='%(taggername) <%(taggeremail)>' "$TAG_NAME")
    TAG_DATE=$(git tag -l --format='%(taggerdate)' "$TAG_NAME")

    print_info "Tag message: ${TAG_MESSAGE:-"(no message)"}"
    print_info "Original tagger: $TAG_TAGGER"
    print_info "Original date: $TAG_DATE"
else
    TAG_TYPE="lightweight"
    print_info "Detected lightweight tag"
fi

# Confirm the operation
echo ""
print_info "Move tag '$TAG_NAME' from $CURRENT_COMMIT to $NEW_COMMIT"

# Backup the original tag reference (in case we need to restore)
BACKUP_REF="refs/tags/backup-$TAG_NAME-$(date +%s)"
git update-ref "$BACKUP_REF" "refs/tags/$TAG_NAME"
print_info "Created backup reference: $BACKUP_REF"

# Move the tag
print_info "Moving tag '$TAG_NAME'..."

if [[ "$TAG_TYPE" == "annotated" ]]; then
    # For annotated tags, we need to recreate the tag with the same message
    # Delete the old tag first
    git tag -d "$TAG_NAME"

    # Create new annotated tag
    if [[ -n "$TAG_MESSAGE" ]]; then
        git tag -a "$TAG_NAME" -m "$TAG_MESSAGE" "$NEW_REF"
    else
        git tag -a "$TAG_NAME" -m "Moved tag to $NEW_COMMIT" "$NEW_REF"
    fi
else
    # For lightweight tags, delete and recreate
    git tag -d "$TAG_NAME"
    git tag "$TAG_NAME" "$NEW_REF"
fi

# Verify the move was successful
# Use ^{commit} to resolve annotated tags to their target commit
FINAL_COMMIT=$(git rev-parse "refs/tags/$TAG_NAME^{commit}")
if [[ "$FINAL_COMMIT" == "$NEW_COMMIT" ]]; then
    print_success "Successfully moved tag '$TAG_NAME' to commit $NEW_COMMIT"

    # Show the tag information
    echo ""
    print_info "Tag information:"
    git show --no-patch --format="  Commit: %H%n  Author: %an <%ae>%n  Date: %ad%n  Subject: %s" "$TAG_NAME"

    # Clean up backup reference
    git update-ref -d "$BACKUP_REF"
    print_info "Cleaned up backup reference"

    # Remind about remote repositories
    echo ""
    print_warning "Note: If this tag exists on remote repositories, you'll need to force push:"
    print_warning "  git push origin :refs/tags/$TAG_NAME  # Delete remote tag"
    print_warning "  git push origin refs/tags/$TAG_NAME   # Push updated tag"
    print_warning "Or use: git push --force origin refs/tags/$TAG_NAME"
else
    print_error "Failed to move tag. Tag is pointing to $FINAL_COMMIT instead of $NEW_COMMIT"

    # Restore from backup
    print_info "Restoring original tag from backup..."
    git update-ref "refs/tags/$TAG_NAME" "$BACKUP_REF"
    git update-ref -d "$BACKUP_REF"
    exit 1
fi
