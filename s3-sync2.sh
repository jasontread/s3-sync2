#!/bin/bash

# Default arguments
export AWS_CLI_OPTIONS=
export AWS_PROFILE_OPTION=
export LOCAL_PATH=
export S3_BUCKET=
export S3_URI=
export CF_DISTRIBUTION_ID=
export CF_INVALIDATE_ALWAYS=0
export CF_INVALIDATION_PATHS='/*'
export DEBUG=0
export DFS=0
export DFS_LOCK_TIMEOUT=60
export DFS_LOCK_WAIT=180
export SQS_EVENT_QUEUE=
export SQS_EVENT_QUEUE_CLEANUP=0
export INIT_SYNC_DOWN=0
export INIT_SYNC_UP=0
export POLL_INTERVAL_SECS=30


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
      echo " --debug                 Show debug output"
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
      echo " --event-queue | -q      if set, this script will attempt to enable S3 Event "
      echo "                         Notifications on the bucket associated with <S3Uri>" 
      echo "                         with notifications sent to an Amazon SQS queue with the "
      echo "                         name specified by this option. If the queue does not exist,"
      echo "                         an attempt will be made to create it. The event queues name" 
      echo "                         specified should be unique for all nodes. Value may contain"
      echo "                         the token [uid] which will be replaced by the node's unique"
      echo "                         identifier (/etc/machine-id if present, or hostname "
      echo "                         otherwise). Event queue names can be a maximum of 80 "
      echo "                         characters and consist of alphanumeric characters, dashes or "
      echo "                         underscores only. If not set, <S3Uri> to <LocalPath> "
      echo "                         synchronization will trigger after each --poll interval is "
      echo "                         reached as opposed to only when changes occur provided by "
      echo "                         this option."
      echo " "
      echo " --event-queue-cleanup   if set in conjunction with --event-queue, and this script "
      echo "                         receives a SIGTERM signal, then an attempt will be made to "
      echo "                         delete the associated Amazon SQS queue."
      echo " "
      echo " --init-sync-down | -i   if set, aws s3 sync <S3Uri> <LocalPath> will be invoked when"
      echo "                         the script starts"
      echo " "
      echo " --init-sync-up | -u     if set, aws s3 sync <LocalPath> <S3Uri> will be invoked when"
      echo "                         the script starts"
      echo " "
      echo " --poll | -p             frequency in seconds to check for both local and remote "
      echo "                         changes and trigger the necessary synchronization - default "
      echo "                         is 30."
      echo "                         "
      exit 0
      ;;
    -c|--cf-dist-id)
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
      DEBUG=1
      ;;
    -d|--dfs)
      shift
      DFS=1
      ;;
    -t|--dfs-lock-timeout)
      shift
      DFS_LOCK_TIMEOUT=$1
      shift
      ;;
    -w)
      shift
      DFS_LOCK_WAIT=$1
      shift
      ;;
    -q|--event-queue)
      shift
      SQS_EVENT_QUEUE=$1
      shift
      ;;
    --event-queue-cleanup)
      shift
      SQS_EVENT_QUEUE_CLEANUP=1
      ;;
    -i|--init-sync-down)
      shift
      INIT_SYNC_DOWN=1
      ;;
    -u|--init-sync-up)
      shift
      INIT_SYNC_UP=1
      ;;
    -p|--poll)
      shift
      POLL_INTERVAL_SECS=$1
      shift
      ;;
    --profile)
      shift
      export AWS_PROFILE_OPTION=" --profile $1"
      shift
      ;;
    *)
      if [ -d "$1" ]; then
        LOCAL_PATH=$1
      elif [ "${1:0:5}" = "s3://" ]; then
        S3_URI=$1
        S3_BUCKET=$(echo "${S3_URI:5}" | cut -d'/' -f1)
      elif [ "${1:0:2}" = "--" ]; then
        AWS_CLI_OPTIONS="$AWS_CLI_OPTIONS $1"
      else
        AWS_CLI_OPTIONS="$AWS_CLI_OPTIONS \"$1\""
      fi
      shift
      ;;
  esac
done


# Both <LocalPath> and <S3Uri> are required
if [ "$LOCAL_PATH" = "" ] || [ "$S3_URI" = "" ]; then
  echo "ERROR: <LocalPath> and <S3Uri> are required"
  exit 1
fi

# Validate AWS CLI is installed
if ! command -v aws &>/dev/null; then
  echo "ERROR: aws cli is not installed"
  exit 1
fi

# Validate inotifywait or md5sum are installed
if ! command -v inotifywait &>/dev/null && ! command -v md5sum &>/dev/null && ! command -v md5 &>/dev/null; then
  echo "ERROR: either inotifywait or md5sum must be installed"
  exit 1
fi

# Validate aws cli credentials and <S3Uri>
if ! eval "aws $AWS_PROFILE_OPTION s3 ls s3://$S3_BUCKET >/dev/null"; then
  echo "ERROR: unable to validate <S3Uri> using > aws ${AWS_PROFILE_OPTION} s3 ls s3://${S3_BUCKET}"
  exit 1
fi

# shellcheck disable=SC1090
for f in "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/src/*.sh; do
  . "$f"
done
# TODO
