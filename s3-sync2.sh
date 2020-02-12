#!/bin/bash

# source scripts in src/*.sh
# shellcheck disable=SC1090
for f in "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/src/*.sh; do
  . "$f"
done

# Default arguments
export AWS_CLI_CMD_SYNC_DOWN=
export AWS_CLI_CMD_SYNC_UP=
export AWS_CLI_OPTIONS=
export AWS_CLI_SYNC_OPTIONS=
export AWS_CLI_SYNC_OPTIONS_DOWN=
export AWS_CLI_SYNC_OPTIONS_UP=
[ "$LOCAL_PATH" ] || export LOCAL_PATH=
export S3_BUCKET=
[ "$S3_URI" ] || export S3_URI=
[ "$CF_DISTRIBUTION_ID" ] || export CF_DISTRIBUTION_ID=
[ "$CF_INVALIDATION_PATHS" ] || export CF_INVALIDATION_PATHS='/*'
[ "$DEBUG" ] || export DEBUG='ERROR'
export DFS=0
export DFS_LOCK_FILE=
[ "$DFS_LOCK_TIMEOUT" ] || export DFS_LOCK_TIMEOUT=60
[ "$DFS_LOCK_WAIT" ] || export DFS_LOCK_WAIT=180
export INIT_SYNC_DOWN=0
export INIT_SYNC_UP=0
export MAX_FAILURES=3
export MD5_NOT_PATH_OPT=
export MD5_SKIP_PATH=
[ "$POLL_INTERVAL" ] || export POLL_INTERVAL=30
export NODE_UID=
export KILLED=0
last_aws_option=
sync_failures=0

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
      echo " --max-failures | -x     max sychronization failures before exiting (0 for infinite)."
      echo "                         Default is 3"
      echo " "
      echo " --md5-skip-path | -s    by default, every file in <LocalPath> is used to generate "
      echo "                         md5 checksums determining when contents have changed. The "
      echo "                         script cannot translate --include/--exclude sync options"
      echo "                         to local file paths. Use this option to alter this behavior"
      echo "                         by specifying 1 or more paths in <LocalPath> to exclude"
      echo "                         from checksum calculations. Do not repeat this option - if"
      echo "                         multiple paths should be excluded, use pipes (|) to separate"
      echo "                         each. Each path designated should be a child of <LocalPath>."
      echo "                         Only directories may be specified and they should not "
      echo "                         include the trailing slash"
      echo " "
      echo " --poll | -p             frequency in seconds to check for both local and remote "
      echo "                         changes and trigger the necessary synchronization - default "
      echo "                         is 30. Must be between 0 and 3600. If 0, then script will "
      echo "                         immediately exit after option validation and initial "
      echo "                         synchronization"
      echo " "
      echo " --sync-opt-down-*       An aws s3 sync option that should only be applied when "
      echo "                         syncing down <S3Uri> to <LocalPath>. For example, to only "
      echo "                         apply the --delete flag in this direction, set this option "
      echo "                         --s3-opt-up-delete"
      echo " "
      echo " --sync-opt-up-*         Same as above, but for syncing up <LocalPath> to <S3Uri>"
      echo "                         "
      exit 0
      ;;
    --cf-dist-id|-c)
      shift
      CF_DISTRIBUTION_ID=$1
      shift
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
      DFS_UID="$(get_uid)"
      AWS_CLI_SYNC_OPTIONS_DOWN=" --exclude \"*/.s3-sync2.lock\"$AWS_CLI_SYNC_OPTIONS_DOWN"
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
    --max-failures|-x)
      shift
      MAX_FAILURES=$1
      shift
      ;;
    --md5-skip-path|-s)
      shift
      MD5_SKIP_PATH="${1//\~/$HOME}"
      for path in $( echo "$MD5_SKIP_PATH" | tr "|" "\\n" ); do
        MD5_NOT_PATH_OPT=" -not -path \"$path/*\"$MD5_NOT_PATH_OPT"
      done
      shift
      ;;
    --poll|-p)
      shift
      POLL_INTERVAL=$1
      shift
      ;;
    --endpoint-url|--color|--profile|--region|--ca-bundle|--cli-read-timeout|--cli-connect-timeout)
      opt="$1"
      shift
      export AWS_CLI_OPTIONS=" $opt $1$AWS_CLI_OPTIONS"
      shift
      ;;
    --no-verify-ssl|--no-sign-request)
      export AWS_CLI_OPTIONS=" $1$AWS_CLI_OPTIONS"
      shift
      ;;
    --sync-opt-down-*)
      AWS_CLI_SYNC_OPTIONS_DOWN="$AWS_CLI_SYNC_OPTIONS_DOWN ${1/sync\-opt\-down\-/}"
      last_aws_option=down
      shift
      ;;
    --sync-opt-up-*)
      AWS_CLI_SYNC_OPTIONS_UP="$AWS_CLI_SYNC_OPTIONS_UP ${1/sync\-opt\-up\-/}"
      last_aws_option=up
      shift
      ;;
    *)
      if [ "$1" = "--output" ]; then
        print_msg "aws --output option is not supported and will be ignored" warn s3-sync2.sh $LINENO
        shift
      elif [ -z $LOCAL_PATH ] && [ -d "$1" ]; then
        LOCAL_PATH=$1
      elif [ -z $S3_URI ] && [ "${1:0:5}" = "s3://" ]; then
        S3_URI=$1
        S3_BUCKET=$(echo "${S3_URI:5}" | cut -d'/' -f1)
        [ "$S3_URI" = "s3://$S3_BUCKET" ] && DFS_LOCK_FILE='.s3-sync2.lock' || DFS_LOCK_FILE="${S3_URI/s3:\/\/$S3_BUCKET\//}/.s3-sync2.lock"
      elif [ "${1:0:2}" = "--" ]; then
        AWS_CLI_SYNC_OPTIONS="$AWS_CLI_SYNC_OPTIONS $1"
        last_aws_option=
      elif [ "$last_aws_option" = "down" ]; then
        AWS_CLI_SYNC_OPTIONS_DOWN="$AWS_CLI_SYNC_OPTIONS_DOWN \"$1\""
      elif [ "$last_aws_option" = "up" ]; then
        AWS_CLI_SYNC_OPTIONS_UP="$AWS_CLI_SYNC_OPTIONS_UP \"$1\""
      else
        AWS_CLI_SYNC_OPTIONS="$AWS_CLI_SYNC_OPTIONS \"$1\""
      fi
      shift
      ;;
  esac
done

# Full aws cli commands for downlink and uplink synchronization
AWS_CLI_CMD_SYNC_DOWN="aws$AWS_CLI_OPTIONS s3 sync $S3_URI $LOCAL_PATH$AWS_CLI_SYNC_OPTIONS$AWS_CLI_SYNC_OPTIONS_DOWN"
AWS_CLI_CMD_SYNC_UP="aws$AWS_CLI_OPTIONS s3 sync $LOCAL_PATH $S3_URI$AWS_CLI_SYNC_OPTIONS$AWS_CLI_SYNC_OPTIONS_UP"

print_msg "Initiating s3-sync2.sh [PID=$$] with the following runtime options: 
                                            [LOCAL_PATH=$LOCAL_PATH]
                                            [S3_URI=$S3_URI]
                                            [S3_BUCKET=$S3_BUCKET]
                                            [CF_DISTRIBUTION_ID=$CF_DISTRIBUTION_ID]
                                            [CF_INVALIDATION_PATHS=$CF_INVALIDATION_PATHS]
                                            [DEBUG=$DEBUG]
                                            [DFS=$DFS]
                                            [DFS_LOCK_FILE=$DFS_LOCK_FILE]
                                            [DFS_LOCK_TIMEOUT=$DFS_LOCK_TIMEOUT]
                                            [DFS_LOCK_WAIT=$DFS_LOCK_WAIT]
                                            [DFS_UID=$DFS_UID]
                                            [INIT_SYNC_DOWN=$INIT_SYNC_DOWN]
                                            [INIT_SYNC_UP=$INIT_SYNC_UP]
                                            [MAX_FAILURES=$MAX_FAILURES]
                                            [MD5_NOT_PATH_OPT=$MD5_NOT_PATH_OPT]
                                            [MD5_SKIP_PATH=$MD5_SKIP_PATH]
                                            [POLL_INTERVAL=$POLL_INTERVAL]
                                            [AWS_CLI_OPTIONS=$AWS_CLI_OPTIONS]
                                            [AWS_CLI_CMD_SYNC_DOWN=$AWS_CLI_CMD_SYNC_DOWN]
                                            [AWS_CLI_CMD_SYNC_UP=$AWS_CLI_CMD_SYNC_UP]" debug s3-sync2.sh $LINENO

# trap SIGINT and SIGTERM (sets KILLED=1)
trap cleanup SIGINT
trap cleanup SIGTERM

# startup validation/initialization
startup

# Initialization synchronizations
# Perform downilnk initializaiton if --init-sync-down set
if [ "$INIT_SYNC_DOWN" -eq 1 ]; then
  print_msg "Invoking downlink synchronization for --init-sync-down option" debug s3-sync2.sh $LINENO
  if eval "$AWS_CLI_CMD_SYNC_DOWN"; then
    print_msg "Downlink synchronization successful" debug s3-sync2.sh $LINENO
  else
    print_msg "Downlink synchronization failed" error s3-sync2.sh $LINENO
    exit 1
  fi
# Perform uplink initializaiton if --init-sync-up set
elif [ "$INIT_SYNC_UP" -eq 1 ]; then
  print_msg "Invoking uplink synchronization for --init-sync-up option" debug s3-sync2.sh $LINENO
  if eval "$AWS_CLI_CMD_SYNC_UP"; then
    print_msg "Uplink synchronization successful" debug s3-sync2.sh $LINENO
  else
    print_msg "Uplink synchronization failed" error s3-sync2.sh $LINENO
    exit 1
  fi
fi

# Use infinite loop to invoke synchronization every $POLL_INTERVAL seconds
interval=0
while :; do
  interval=$(( interval + 1 ))
  if [ "$POLL_INTERVAL" -eq 0 ]; then
    print_msg "exiting due to --poll 0" debug s3-sync2.sh $LINENO
    exit    
  elif [ "$KILLED" -eq 1 ]; then
    print_msg "SIGINT or SIGTERM signal received - attempting 1 final uplink synchronization and exiting" warn s3-sync2.sh $LINENO
    s3_sync2 up
    exit
  elif ! s3_sync2; then
    sync_failures=$(( sync_failures + 1 ))
    print_msg "Synchronization failed [#$sync_failures of max $MAX_FAILURES]" error s3-sync2.sh $LINENO
    if [ "$MAX_FAILURES" -gt 0 ] && [ "$sync_failures" -ge "$MAX_FAILURES" ]; then
      print_msg "Max failures threshold $MAX_FAILURES reached - exiting" error s3-sync2.sh $LINENO
      exit 1
    fi
  else
    print_msg "Successfully invoked synchronization [#$interval] - sleeping $POLL_INTERVAL secs before next synchronization" debug s3-sync2.sh $LINENO
  fi
  sleep "$POLL_INTERVAL" &
  wait
done
