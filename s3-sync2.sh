#!/bin/bash

# source scripts in src/*.sh
# shellcheck disable=SC1090
for f in "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/src/*.sh; do
  . "$f"
done

# Default arguments
export AWS_CLI_OPTIONS=
export AWS_CLI_SYNC_OPTIONS=
export LOCAL_PATH=
export S3_BUCKET=
export S3_URI=
export CF_DISTRIBUTION_ID=
export CF_INVALIDATE_ALWAYS=0
export CF_INVALIDATION_PATHS='/*'
export DEBUG='ERROR'
export DFS=0
export DFS_LOCK_FILE=
export DFS_LOCK_TIMEOUT=60
export DFS_LOCK_WAIT=180
export INIT_SYNC_DOWN=0
export INIT_SYNC_UP=0
export POLL_INTERVAL=30

# Script arguments
while test $# -gt 0; do
  case "$1" in
    -h|--help)
      echo " "
      echo " This script facilitates bidirectional synchronization between a local file "
      echo " system path and an Amazon S3 storage bucket by wrapping the (unidirectional) "
      echo "aws s3 sync CLI."
      echo " "
      echo " s3-sync2 [options] <LocalPath> <S3Uri>"
      echo " "
      echo " "
      echo " OPTIONS"
      echo " "
      echo " All standard aws s3 sync CLI options are supported, in addition to the  "
      echo " following s3-sync2 specific options."
      echo " "
      echo " "
      echo " <LocalPath>             Local directory to synchronize - e.g. /path/to/local/dir"
      echo " "
      echo " <S3Uri>                 Remote S3 URI - e.g. s3://mybucket/remote/dir"
      echo " "
      echo " --cf-dist-id | -c       ID of a CloudFront distributuion to trigger edge cache "
      echo "                         invalidations n when local changes occur."
      echo " "
      echo " --cf-inval-always       By default CloudFront invalidations are triggered only "
      echo "                         by local changes. Setting this flag results in "
      echo "                         invalidations triggering by both local and remote/bucket "
      echo "                         changes (as detected by changes to <LocalPath> due to down "
      echo "                         synchronization)"
      echo " "
      echo " --cf-inval-paths        Value for the aws cloudfront create-invalidation --paths"
      echo "                         argument. Default is invalidation of all cached objects: /*"
      echo " "
      echo " --debug                 Debug output level - one of ERROR (default), WARN, DEBUG"
      echo "                         or NONE"
      echo " "
      echo " --dfs | -d              Run as a quasi distributed file system wherein multiple "
      echo "                         nodes can run this script concurrently. When enabled, an "
      echo "                         additional distributed locking step is required when "
      echo "                         synchronizing from <LocalPath> to <S3Uri>. To do so, S3's "
      echo "                         read-after-write consistency model is leveraged in "
      echo "                         conjunction with an object PUT operation where the object "
      echo "                         contains a unique identifier for the node acquiring the "
      echo "                         lock."
      echo " "
      echo " --dfs-lock-timeout | -t the maximum time (secs) permitted for a distributed lock "
      echo "                         by another node before it is considered to be stale and "
      echo "                         force released. Default is 60 (1 minute)"
      echo " "
      echo " --dfs-lock-wait | -w    the maximum time (secs) to wait to acquire a distributed "
      echo "                         lock before exiting with an error. Default is 180 (3 minutes)"
      echo " "
      echo " --init-sync-down | -i   if set, aws s3 sync <S3Uri> <LocalPath> will be invoked when"
      echo "                         the script starts"
      echo " "
      echo " --init-sync-up | -u     if set, aws s3 sync <LocalPath> <S3Uri> will be invoked when"
      echo "                         the script starts"
      echo " "
      echo " --poll | -p             frequency in seconds to check for both local and remote "
      echo "                         changes and trigger the necessary synchronization - default "
      echo "                         is 30. Must be between 1 and 3600"
      echo "                         "
      exit 0
      ;;
    --cf-dist-id|-c)
      shift
      CF_DISTRIBUTION_ID=$1
      shift
      ;;
    --cf-inval-always)
      shift
      CF_INVALIDATE_ALWAYS=1
      ;;
    --cf-inval-paths)
      shift
      CF_INVALIDATION_PATHS=$1
      shift
      ;;
    --debug)
      shift
      DEBUG=$1
      shift
      ;;
    --dfs|-d)
      shift
      DFS=1
      ;;
    --dfs-lock-timeout|-t)
      shift
      DFS_LOCK_TIMEOUT=$1
      shift
      ;;
    --dfs-lock-wait|-w)
      shift
      DFS_LOCK_WAIT=$1
      shift
      ;;
    --init-sync-down|-i)
      shift
      INIT_SYNC_DOWN=1
      ;;
    --init-sync-up|-u)
      shift
      INIT_SYNC_UP=1
      ;;
    --poll|-p)
      shift
      POLL_INTERVAL=$1
      shift
      ;;
    --profile)
      shift
      export AWS_CLI_OPTIONS=" --profile $1$AWS_CLI_OPTIONS"
      shift
      ;;
    --region)
      shift
      export AWS_CLI_OPTIONS=" --region $1$AWS_CLI_OPTIONS"
      shift
      ;;
    *)
      if [ -d "$1" ]; then
        LOCAL_PATH=$1
      elif [ "${1:0:5}" = "s3://" ]; then
        S3_URI=$1
        S3_BUCKET=$(echo "${S3_URI:5}" | cut -d'/' -f1)
        [ "$S3_URI" = "s3://$S3_BUCKET" ] && DFS_LOCK_FILE='.s3-sync2.lock' || DFS_LOCK_FILE="${S3_URI/s3:\/\/$S3_BUCKET\//}/.s3-sync2.lock"
      elif [ "${1:0:2}" = "--" ]; then
        AWS_CLI_OPTIONS="$AWS_CLI_OPTIONS $1"
      else
        AWS_CLI_SYNC_OPTIONS="$AWS_CLI_SYNC_OPTIONS \"$1\""
      fi
      shift
      ;;
  esac
done

# startup validation/initialization
s3_sync2_startup

# TODO

