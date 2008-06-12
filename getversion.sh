#!/usr/bin/env bash
# -*- shell-script -*-

bzr="bzr --no-plugins --no-aliases"
$bzr rocks > /dev/null || (echo "ERROR: cannot run bzr." && exit 1)
nick=`$bzr nick`
news=`$bzr root`/NEWS
tag=`head -1 $news | cut -c 3-`
devo=`head -1 $news | fgrep -s devo > /dev/null && echo devo`
revno=`$bzr revno`

if [ "$devo" = "devo" ] ; then
  rdir=$tag-$revno
  version=$rdir
else
  tag=(`$bzr tags --sort=time | tail -1`)
  if [ "${tag[1]}" != "$revno" ]; then
    echo "ERROR: No tag present at the head revision."
    echo "ERROR: First you must create a release tag!"
    exit -1
  fi
  tag=${tag[0]}
  rdir=$tag-$revno
  version=$tag
fi
