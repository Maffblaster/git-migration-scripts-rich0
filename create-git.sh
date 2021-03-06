#!/bin/bash

proc_count=$(grep -c MHz /proc/cpuinfo)
[ ${proc_count} -eq 0 ] && proc_count=1
root="$(pwd)"
mkdir -p git
rm -rf git/* git/.git
set -f
mkdir -p git
cd git
git_root="$(pwd)"
git init --bare
git config core.logAllRefUpdates false
git config prune.expire now
mkdir -p objects/info

update_alternates() {
  local alternates="$(readlink -f "${git_root}/objects/info")/alternates"
  while read l; do
    l=$(readlink -f "$l")
    [ -e "$l/cvs2svn-tmp/git-dump.dat" ] || { echo "ignoring nonexistant alternates source $l" >&2; continue; }
    echo "$l/git/objects" >> "${alternates}"
    echo "$l"
  done
}

standalone_mode() {
  find final/ -maxdepth 1 -mindepth 1 -printf 'final/%P/\n' | \
    xargs -n1 readlink -f | update_alternates
}

if [ "$1" == --fast ]; then
  command=update_alternates
else
  command=standalone_mode
fi

# Roughly; since alternates are updated as we go- and since rewrite-commit-dump
# doesn't actually output anything till it's linearized the history, we have
# to delay fast-import's startup until we know we have data (meaning linearize
# has finished- thus the alternates are all in place).
# Bit tricky, but the gains have been worth it in performance- plus it means we
# we can discard the rewrite-commit-dump.py instance (~1.8GB ram release).
cd "${root}"
time {
  ${command} | ./rewrite-commit-dump.py > export-stream-rewritten;
  time git --git-dir "${git_root}" fast-import < export-stream-rewritten;
} 2>&1 > >(tee git-creation.log)
ret=$?
[ $ret -eq 0 ] || { echo "none zero exit... the hell? $ret"; exit 1; }

cd "${git_root}"
echo "recomposed; repacking and breaking alternate linkage..."
# Localize the content we actual use out of the alternates...
time git repack -Adf --window=100 --depth=100
# Wipe the alternates.
rm "${git_root}/objects/info/alternates" || { echo "no alternates means no sources..."; exit 2; }
echo "doing basic sanity check"
time git log -p refs/heads/master > /dev/null || echo "non zero exit code from git log run..."
echo "Done"
