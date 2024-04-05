#!/usr/bin/env bash
# This is a fairly intricate script to format Nixpkgs for each commit of a nixfmt PR, pushing the result to a Git repo.
# Notable features:
# - It only minimally depends on GitHub: All operations are done using Git directly
# - Reuse of previous work: Formatting all of Nixpkgs takes some time, we don't want to recompute it if not necessary
# - Handles force pushes gracefully and linearises merge commits
#

set -euo pipefail

if (( $# < 3 )); then
  echo "Usage: $0 NIXFMT_URL NIXFMT_PR_NUMBER NIXPKGS_URL"
  echo "- NIXFMT_URL: A git remote URL for the nixfmt repo against which the PR is made"
  echo "- NIXFMT_PR_NUMBER: The PR number"
  echo "- NIXPKGS_URL: A writable git remote URL for the Nixpkgs repo where branches can be created for the formatted result."
  echo "  The branch will be called \`nixfmt-<NIXFMT_PR_NUMBER>\`"
  exit 1
fi

nixfmtUrl=$1
nixfmtPrNumber=$2
nixpkgsUrl=$3

nixpkgsUpstreamUrl=https://github.com/NixOS/nixpkgs
nixpkgsMirrorBranch=nixfmt-$nixfmtPrNumber

tmp=$(mktemp -d)
cd "$tmp"
trap 'rm -rf "$tmp"' exit

step() {
  echo -e "\e[34m$1\e[0m"
}

# Checks whether a revision range is linear, returns 1 if it's not
# Usage: isLinear REPO REV_RANGE
# - REPO: The local Git repo that contains the revisions
# - REV_RANGE: The revision range, see `man git log`
isLinear() {
  local repo=$1
  local revs=$2
  # Loops through all merge commits in the range
  for _mergeCommit in $(git 2>/dev/null -C "$repo" log --pretty=format:%H --min-parents=2 "$revs"); do
    # And returns as soon as the first is found
    return 1
  done
}

step "Fetching nixfmt pull request and creating a branch for the head commit"
git init nixfmt
git -C nixfmt fetch "$nixfmtUrl" "refs/pull/$nixfmtPrNumber/merge"
nixfmtBaseCommit=$(git -C nixfmt rev-parse FETCH_HEAD^1)
nixfmtHeadCommit=$(git -C nixfmt rev-parse FETCH_HEAD^2)
git -C nixfmt switch -c main "$nixfmtHeadCommit"

# In case the PR contains merge commits, we strip those away, such that the resulting Nixpkgs history is always linear.
step "Linearising nixfmt history after the base commit"
# https://stackoverflow.com/a/17994534
FILTER_BRANCH_SQUELCH_WARNING=1 git -C nixfmt filter-branch --parent-filter 'cut -f 2,3 -d " "' "$nixfmtBaseCommit"..main

nixfmtCommitCount=$(git -C nixfmt rev-list --count "$nixfmtBaseCommit"..main)
if (( nixfmtCommitCount == 0 )); then
  step "No commits, deleting the nixpkgs branch $nixpkgsMirrorBranch if it exists"
  # git push requires a repository to work at all, _any_ repository!
  git init -q trash
  git -C trash push "$nixpkgsUrl" :refs/heads/"$nixpkgsMirrorBranch"
  rm -rf trash
  exit 0
else
  echo "There are $nixfmtCommitCount linearised commits"
fi

# All the commits of the PR, including the base commit (which may change as the base branch is updated)
prCommits=("$nixfmtBaseCommit")
readarray -t -O 1 prCommits < <(git -C nixfmt rev-list --reverse "$nixfmtBaseCommit"..main)

# Computes the commit subject of the Nixpkgs commit that contains the formatted changes
# Usage: bodyForCommitIndex INDEX
# - INDEX: The index of the nixfmt commit in the PR that is being used
#   0 means the PR's base commit
bodyForCommitIndex() {
  local index=$1
  local commit=${prCommits[$index]}
  local url=$nixfmtUrl/commit/$commit
  local subject
  subject=$(git -C nixfmt show -s --format=%s "$commit")

  if (( index == 0 )); then
    url=$nixfmtUrl/commit/$commit
    echo -e "base: $subject\n\nFormat using the base commit from nixfmt PR $nixfmtPrNumber: $url"
  else
    url=$nixfmtUrl/pull/$nixfmtPrNumber/commits/$commit
    echo -e "$index: $subject\n\nFormat using commit number $index from nixfmt PR $nixfmtPrNumber: $url"
  fi
}

step "Fetching upstream Nixpkgs commit history"
git init --bare nixpkgs.git

git -C nixpkgs.git remote add upstream "$nixpkgsUpstreamUrl"
# This makes sure that we don't actually have to fetch any contents, otherwise we'd wait forever!
git -C nixpkgs.git config remote.upstream.promisor true
git -C nixpkgs.git config remote.upstream.partialclonefilter tree:0

git -C nixpkgs.git fetch --no-tags upstream HEAD:master

# Instead of e.g. fetching Nixpkgs master, which would continuously move, we "pin" Nixpkgs to the latest commit before the PRs commit
step "Finding the last Nixpkgs commit before the first commit on nixfmt's branch"
nixfmtFirstCommit=${prCommits[1]}
# Commit date, not author date, not sure what's better
nixfmtFirstCommitDateEpoch=$(git -C nixfmt log -1 --format=%ct "$nixfmtFirstCommit")
nixfmtFirstCommitDateHuman=$(git -C nixfmt log -1 --format=%ci "$nixfmtFirstCommit")
echo "The first nixfmt commit is $nixfmtFirstCommit on $nixfmtFirstCommitDateHuman"

nixpkgsBaseCommit=$(git -C nixpkgs.git rev-list -1 master --before="$nixfmtFirstCommitDateEpoch")
nixpkgsBaseCommitDateHuman=$(git -C nixpkgs.git log -1 --format=%ci "$nixpkgsBaseCommit")

echo "The last Nixpkgs commit before then is $nixpkgsBaseCommit on $nixpkgsBaseCommitDateHuman, which will be used as the Nixpkgs base commit"

step "Fetching Nixpkgs commit history in branch $nixpkgsMirrorBranch if it exists"
git -C nixpkgs.git remote add mirror "$nixpkgsUrl"
git -C nixpkgs.git config remote.mirror.promisor true
git -C nixpkgs.git config remote.mirror.partialclonefilter tree:0

# After this:
# - $nixpkgsCommitCount should be the number of commits that can be reused
# - $startingCommit should be the nixpkgs commit that the branch should be reset to
nixpkgsCommitCount=0
startingCommit=$nixpkgsBaseCommit
if ! git -C nixpkgs.git fetch --no-tags mirror "$nixpkgsMirrorBranch":mirrorBranch; then
  echo "There is not, likely a new PR"
else
  echo "There is, it points to $(git -C nixpkgs.git rev-parse mirrorBranch)"
  step "Checking to which extent work from the existing branch can be reused"
  if [[ -z "$(git -C nixpkgs.git branch --contains="$nixpkgsBaseCommit" mirrorBranch)" ]]; then
    echo "It cannot, the desired base commit is not present at all, likely caused by a rebase"
  else
    if ! isLinear nixpkgs.git "$nixpkgsBaseCommit"..mirrorBranch; then
      echo "It cannot, the branch is not linear, this is a bug, but not fatal"
    else
      #echo "It can!"
      previousNixpkgsCommitCount=$(git -C nixpkgs.git rev-list --count "$nixpkgsBaseCommit"..mirrorBranch)
      echo "There's $previousNixpkgsCommitCount commits in the branch on top of the base commit"
      # E.g. if the nixfmt PR has 1 commit, the Nixpkgs PR has two

      # Iterate through the Nixpkgs commits and check whether they match the nixfmt ones

      # Check if there's at least 1 commit in nixpkgs and at least 0 commits in nixfmt
      # Check if commit 1 in nixpkgs corresponds to commit 0 in nixfmt
      # If true, increase nixpkgsCommitCount by one, otherwise break
      # Check if there's at least 2 commits in nixpkgs and at least 1 commit in nixfmt
      # If so, check if commit 2 in nixpkgs corresponds to commit 1 in nixfmt
      # ...
      while
        if (( nixpkgsCommitCount > nixfmtCommitCount )); then
          echo "All nixfmt commits are already cached"
          false
        elif (( nixpkgsCommitCount + 1 > previousNixpkgsCommitCount )); then
          echo "Not all nixfmt commits are cached"
          false
        else
          # A bit messy, but we kind of go back from the head of the branch via parents.
          # This only works correctly because we verified that the branch is linear.
          # An alternative would be to read the commits into an array, just like it's done for prCommits
          nixpkgsCommit=$(git -C nixpkgs.git rev-parse "mirrorBranch~$((previousNixpkgsCommitCount - (nixpkgsCommitCount + 1)))")
          nixfmtCommit=${prCommits[$nixpkgsCommitCount]}

          echo "Checking whether commit with index $(( nixpkgsCommitCount + 1 )) ($nixpkgsCommit) in nixpkgs corresponds to commit with index $nixpkgsCommitCount ($nixfmtCommit) in nixfmt"

          # We generate the bodies of the commits to contain the nixfmt commit so we can check against it here to verify it's the same
          body=$(git -C nixpkgs.git log -1 "$nixpkgsCommit" --pretty=%B)
          expectedBody=$(bodyForCommitIndex "$nixpkgsCommitCount")
          if [[ "$body" == "$expectedBody" ]]; then
            echo "It does!"
          else
            echo "It does not, body of nixpkgs commit is:"
            echo "$body"
            echo "But expected body is"
            echo "$expectedBody"
            false
          fi
        fi
      do
        nixpkgsCommitCount=$(( nixpkgsCommitCount + 1 ))
        startingCommit=$(git -C nixpkgs.git rev-parse "mirrorBranch~$(( previousNixpkgsCommitCount - nixpkgsCommitCount ))")
      done

      echo "$nixpkgsCommitCount commits can be reused, starting from $startingCommit"
    fi
  fi
fi


git init nixpkgs
git -C nixpkgs config user.name "GitHub Actions"
git -C nixpkgs config user.email "actions@users.noreply.github.com"

step "Fetching contents of Nixpkgs base commit $nixpkgsBaseCommit"
# This is needed because for every commit we reset Nixpkgs to the base branch before formatting
git -C nixpkgs fetch --no-tags --depth 1 "$nixpkgsUpstreamUrl" "$nixpkgsBaseCommit"

step "Fetching contents of the starting commit and updating the mirror branch"
# This is only needed so we can push the resulting diff after formatting
if (( nixpkgsCommitCount == 0 )); then
  # No reusable commits, create a new branch, starting commit is the same as the base commit here
  git -C nixpkgs switch -c mirrorBranch "$startingCommit"
else
  # Reusable commits, fetch the starting one and set a local branch to it
  git -C nixpkgs fetch --no-tags --depth 1 "$nixpkgsUrl" "$startingCommit":mirrorBranch
  git -C nixpkgs switch mirrorBranch
fi

git -C nixpkgs push --force "$nixpkgsUrl" mirrorBranch:"$nixpkgsMirrorBranch"

if (( nixpkgsCommitCount - 1 == nixfmtCommitCount )); then
  echo "Already up-to-date"
  exit 0
fi

# Update the result symlink to a specific nixfmt version
# Usage: step INDEX
# - INDEX: The nixfmt commit index to use, 0 is for the PR's base commit
update() {
  local index=$1
  nixfmtCommit=${prCommits[$index]}

  step "Checking out nixfmt at $nixfmtCommit"
  git -C nixfmt checkout -q "$nixfmtCommit"

  step "Building nixfmt"
  nix-build nixfmt
}

# Format Nixpkgs with a specific nixfmt version and push the result.
# Usage: step INDEX
# - INDEX: The nixfmt commit index to format with, 0 is for the PR's base commit
next() {
  local index=$1

  update "$index"

  if [[ -n "$appliedNixfmtPath" && "$appliedNixfmtPath" == "$(realpath result)" ]]; then
    echo "The nixfmt store path didn't change, saving ourselves a formatting"
  else
    step "Checking out Nixpkgs at the base commit"
    git -C nixpkgs checkout "$nixpkgsBaseCommit" -- .

    step "Running nixfmt on nixpkgs"
    if ! time xargs -r -0 -P"$(nproc)" -n1 -a <(find nixpkgs -type f -name '*.nix' -print0) result/bin/nixfmt; then
      echo -e "\e[31mFailed to run nixfmt on some files\e[0m"
      exit 1
    fi
    git -C nixpkgs add -A

    appliedNixfmtPath=$(realpath result)
  fi

  step "Committing the formatted result"
  git -C nixpkgs commit --allow-empty -m "$(bodyForCommitIndex "$index")"

  step "Pushing result"
  git -C nixpkgs push "$nixpkgsUrl" mirrorBranch:"$nixpkgsMirrorBranch"
  nixpkgsCommitCount=$(( nixpkgsCommitCount + 1 ))
}

appliedNixfmtPath=
if (( nixpkgsCommitCount == 0 )); then
  # If we don't have a base-formatted Nixpkgs commit yet, create it
  next 0
else
  # Otherwise, just build the nixfmt that was used for the current commit, such that we know the store path
  update "$(( nixpkgsCommitCount - 1 ))"
  appliedNixfmtPath=$(realpath result)
fi

while (( nixpkgsCommitCount - 1 < nixfmtCommitCount )); do
  # The number of commits in Nixpkgs is also the index of the nixfmt commit to apply next
  # E.g. with 1 Nixpkgs commit (only the base formatted one), we need to run the 1st commit from the nixfmt PR next
  next "$nixpkgsCommitCount"
done
