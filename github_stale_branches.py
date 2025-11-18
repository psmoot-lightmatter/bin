#!/usr/bin/env python3
"""
GitHub Stale Branches Reporter

This script analyzes GitHub repositories to identify stale branches by reporting:
1. All branches in the repository
2. Age of the most recent commit on each branch
3. Whether the branch HEAD has been merged to the default branch

Usage:
    python github_stale_branches.py <owner/repo>
    python github_stale_branches.py owner repo

Examples:
    python github_stale_branches.py microsoft/vscode
    python github_stale_branches.py microsoft vscode

Requirements:
    - PyGithub library (pip install PyGithub) or gh CLI tool
    - GitHub token (via GITHUB_TOKEN env var or gh auth)
"""

import sys
import os
import json
import subprocess
from datetime import datetime, timezone
from typing import List, Dict, Tuple
import argparse


class GitHubAPI:
    """GitHub API wrapper that tries PyGithub first, falls back to gh CLI"""

    def __init__(self, owner: str, repo: str):
        self.owner = owner
        self.repo = repo
        self.repo_full_name = f"{owner}/{repo}"
        self.github_client = None
        self.github_repo = None

        # Try to initialize PyGithub
        try:
            from github import Github, Auth  # type: ignore

            token = os.environ.get("GITHUB_TOKEN")
            if token:
                # Strip any whitespace or line endings from token
                token = token.strip()
                auth = Auth.Token(token)
                self.github_client = Github(auth=auth)
            else:
                self.github_client = Github()  # Try without token (rate limited)

            self.github_repo = self.github_client.get_repo(self.repo_full_name)
            self.use_pygithub = True
            print(f"✓ Using PyGithub API for {self.repo_full_name}")
        except ImportError:
            print("PyGithub not available, will use gh CLI")
            self.use_pygithub = False
        except Exception as e:
            print(f"PyGithub failed ({e}), falling back to gh CLI")
            self.use_pygithub = False

    def _run_gh_command(self, args: List[str]) -> dict:
        """Run gh CLI command and return JSON response"""
        cmd = ["gh", "api"] + args

        # Clean environment to avoid token issues
        env = os.environ.copy()
        if "GITHUB_TOKEN" in env:
            # Strip whitespace from token if present
            clean_token = env["GITHUB_TOKEN"].strip()
            if clean_token != env["GITHUB_TOKEN"]:
                env["GITHUB_TOKEN"] = clean_token

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, check=True, env=env
            )
            return json.loads(result.stdout)
        except subprocess.CalledProcessError as e:
            raise Exception(f"gh CLI command failed: {e.stderr}")
        except FileNotFoundError:
            raise Exception(
                "gh CLI not found. Please install GitHub CLI or PyGithub library"
            )

    def get_default_branch(self) -> str:
        """Get the default branch name (usually main or master)"""
        if self.use_pygithub and self.github_repo:
            return self.github_repo.default_branch
        else:
            repo_info = self._run_gh_command([f"/repos/{self.repo_full_name}"])
            return repo_info["default_branch"]

    def get_branches(self) -> List[Dict]:
        """Get all branches in the repository"""
        if self.use_pygithub and self.github_repo:
            branches = []
            for branch in self.github_repo.get_branches():
                commit = branch.commit
                branches.append(
                    {
                        "name": branch.name,
                        "commit_sha": commit.sha,
                        "commit_date": commit.commit.author.date,
                        "commit_message": commit.commit.message.split("\n")[0],
                        "author": commit.commit.author.name
                        or commit.commit.author.login,
                    }
                )
            return branches
        else:
            branches_data = self._run_gh_command(
                [f"/repos/{self.repo_full_name}/branches"]
            )
            branches = []
            for branch in branches_data:
                # Get detailed commit info
                commit_data = self._run_gh_command(
                    [f'/repos/{self.repo_full_name}/commits/{branch["commit"]["sha"]}']
                )
                commit_date_str = commit_data["commit"]["author"]["date"]
                commit_date = datetime.fromisoformat(
                    commit_date_str.replace("Z", "+00:00")
                )

                # Get author info (prefer name, fallback to login)
                author_info = commit_data["commit"]["author"]
                author_name = author_info.get("name", "")
                if not author_name and "author" in commit_data:
                    author_name = commit_data["author"].get("login", "Unknown")
                if not author_name:
                    author_name = "Unknown"

                branches.append(
                    {
                        "name": branch["name"],
                        "commit_sha": branch["commit"]["sha"],
                        "commit_date": commit_date,
                        "commit_message": commit_data["commit"]["message"].split("\n")[
                            0
                        ],
                        "author": author_name,
                    }
                )
            return branches

    def is_branch_merged(self, branch_name: str, default_branch: str) -> bool:
        """Check if a branch has been merged into the default branch"""
        if branch_name == default_branch:
            return True  # Default branch is always "merged"

        if self.use_pygithub and self.github_repo:
            try:
                # Compare branches to see if branch is behind default (i.e., merged)
                comparison = self.github_repo.compare(default_branch, branch_name)
                # If ahead_by is 0, the branch is fully merged
                return comparison.ahead_by == 0
            except Exception:
                # If comparison fails, try merge-base approach
                return False
        else:
            try:
                # Use compare API to check if branch is ahead of default
                compare_data = self._run_gh_command(
                    [
                        f"/repos/{self.repo_full_name}/compare/{default_branch}...{branch_name}"
                    ]
                )
                return compare_data["ahead_by"] == 0
            except Exception:
                return False

    def get_current_user(self) -> str:
        """Get current user's name/login for filtering --mine branches"""
        if self.use_pygithub and self.github_repo:
            try:
                user = self.github_client.get_user()
                return user.name or user.login
            except Exception:
                pass

        # Fallback: try gh CLI to get current user
        try:
            user_data = self._run_gh_command(["/user"])
            return user_data.get("name", user_data.get("login", ""))
        except Exception:
            pass

        # Last fallback: try git config
        try:
            result = subprocess.run(
                ["git", "config", "user.name"], capture_output=True, text=True
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except Exception:
            pass

        return ""


def format_age(commit_date: datetime) -> str:
    """Format commit age in a human-readable way"""
    now = datetime.now(timezone.utc)
    if commit_date.tzinfo is None:
        commit_date = commit_date.replace(tzinfo=timezone.utc)

    age = now - commit_date
    days = age.days

    if days == 0:
        hours = age.seconds // 3600
        if hours == 0:
            minutes = age.seconds // 60
            return f"{minutes} minute{'s' if minutes != 1 else ''} ago"
        return f"{hours} hour{'s' if hours != 1 else ''} ago"
    elif days == 1:
        return "1 day ago"
    elif days < 30:
        return f"{days} days ago"
    elif days < 365:
        months = days // 30
        return f"{months} month{'s' if months != 1 else ''} ago"
    else:
        years = days // 365
        return f"{years} year{'s' if years != 1 else ''} ago"


def generate_report(api: GitHubAPI, mine_only: bool = False) -> None:
    """Generate and print the stale branches report"""
    print(f"\n🔍 Analyzing repository: {api.repo_full_name}")
    print("=" * 80)

    try:
        default_branch = api.get_default_branch()
        print(f"Default branch: {default_branch}")

        branches = api.get_branches()

        # Filter to current user's branches if --mine is specified
        if mine_only:
            current_user = api.get_current_user()
            if not current_user:
                print("❌ Could not determine current user for --mine filter")
                return

            print(f"Filtering branches for user: {current_user}")
            original_count = len(branches)
            branches = [b for b in branches if b["author"] == current_user]
            print(
                f"Found {len(branches)} branches (of {original_count} total) by {current_user}"
            )
        else:
            print(f"Total branches: {len(branches)}")
        print()

        # Sort branches by commit date (newest first)
        branches.sort(key=lambda x: x["commit_date"], reverse=True)

        # Calculate dynamic column widths
        max_branch_len = (
            max(len(branch["name"]) for branch in branches) if branches else 20
        )
        # Ensure minimum widths but allow for longer names
        branch_width = max(20, min(max_branch_len + 5, 60))  # Cap at 60 chars
        age_width = 15
        merged_width = 7
        author_width = 20

        # Headers
        header_line = f"{'Branch Name':<{branch_width}} {'Age':<{age_width}} {'Merged':<{merged_width}} {'Author':<{author_width}} {'Last Commit'}"
        print(header_line)
        print("-" * len(header_line))

        merged_count = 0
        stale_count = 0  # Branches older than 30 days

        for branch in branches:
            age_str = format_age(branch["commit_date"])
            is_merged = api.is_branch_merged(branch["name"], default_branch)
            merged_str = "✓" if is_merged else "✗"

            if is_merged:
                merged_count += 1

            # Consider branches stale if they're older than 30 days
            age_days = (
                datetime.now(timezone.utc)
                - (
                    branch["commit_date"]
                    if branch["commit_date"].tzinfo
                    else branch["commit_date"].replace(tzinfo=timezone.utc)
                )
            ).days
            if age_days > 30:
                stale_count += 1
                # Highlight stale branches
                branch_display = f"⚠️  {branch['name']}"
            else:
                branch_display = branch["name"]

            # Truncate branch name if it's still too long after dynamic sizing
            if len(branch_display) > branch_width:
                branch_display = branch_display[: branch_width - 3] + "..."

            # Get author and truncate if needed
            author_display = (
                branch["author"][: author_width - 1]
                if len(branch["author"]) >= author_width
                else branch["author"]
            )

            # Calculate remaining space for commit message
            remaining_width = max(
                20, 120 - branch_width - age_width - merged_width - author_width - 4
            )
            commit_msg = (
                branch["commit_message"][: remaining_width - 3] + "..."
                if len(branch["commit_message"]) > remaining_width
                else branch["commit_message"]
            )

            row = f"{branch_display:<{branch_width}} {age_str:>{age_width}} {merged_str:<{merged_width}} {author_display:<{author_width}} {commit_msg}"
            print(row)

        # Summary
        print("\n" + "=" * 80)
        print("📊 SUMMARY")
        print(f"Total branches: {len(branches)}")
        print(f"Merged branches: {merged_count}")
        print(f"Stale branches (>30 days): {stale_count}")

        if stale_count > 0:
            unmerged_stale = 0
            for branch in branches:
                age_days = (
                    datetime.now(timezone.utc)
                    - (
                        branch["commit_date"]
                        if branch["commit_date"].tzinfo
                        else branch["commit_date"].replace(tzinfo=timezone.utc)
                    )
                ).days
                if age_days > 30 and not api.is_branch_merged(
                    branch["name"], default_branch
                ):
                    unmerged_stale += 1

            print(f"⚠️  Unmerged stale branches: {unmerged_stale}")
            if unmerged_stale > 0:
                print("   Consider reviewing these branches for cleanup!")

    except Exception as e:
        print(f"❌ Error generating report: {e}")
        sys.exit(1)


def parse_arguments() -> Tuple[str, str, bool]:
    """Parse command line arguments for owner, repo, and mine flag"""
    parser = argparse.ArgumentParser(
        description="Generate a report of stale branches in a GitHub repository",
        epilog="Examples:\n"
        "  %(prog)s microsoft/vscode\n"
        "  %(prog)s microsoft vscode",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    # Support both "owner/repo" and "owner repo" formats
    parser.add_argument(
        "repo_path", nargs="+", help='Repository in format "owner/repo" or "owner repo"'
    )

    parser.add_argument(
        "--mine",
        action="store_true",
        help="Show only branches where current user is the author of HEAD commit",
    )

    args = parser.parse_args()

    if len(args.repo_path) == 1:
        # Format: owner/repo
        if "/" in args.repo_path[0]:
            owner, repo = args.repo_path[0].split("/", 1)
        else:
            parser.error("Repository must be in format 'owner/repo' or 'owner repo'")
    elif len(args.repo_path) == 2:
        # Format: owner repo
        owner, repo = args.repo_path
    else:
        parser.error("Too many arguments. Use 'owner/repo' or 'owner repo' format")

    return owner.strip(), repo.strip(), args.mine


def main():
    """Main entry point"""
    try:
        owner, repo, mine_only = parse_arguments()

        print("🚀 GitHub Stale Branches Reporter")
        print(f"Target repository: {owner}/{repo}")

        api = GitHubAPI(owner, repo)
        generate_report(api, mine_only=mine_only)

    except KeyboardInterrupt:
        print("\n❌ Operation cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
