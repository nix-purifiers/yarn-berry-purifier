# SPDX-License-Identifier: MIT
#
# A git repository for the checks of git dependencies: the files of
# directory `src` in one commit, with a fixed author, committer and date, so
# its commit hash is the same in every build. The result is a checkout with
# its .git directory, as fetchgit with `leaveDotGit` returns one.
{ runCommand, git }:
src:
runCommand "git-repository" { nativeBuildInputs = [ git ]; } ''
  cp -r ${src} "$out"
  chmod -R u+w "$out"
  cd "$out"
  export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
  export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
  export GIT_AUTHOR_DATE=1970-01-01T00:00:01Z GIT_COMMITTER_DATE=1970-01-01T00:00:01Z
  git init -q -b main
  git add -A
  git commit -q -m fixture
''
