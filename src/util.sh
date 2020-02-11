#!/bin/bash

# Returns a unique identifier (UID) for this machine. The unique machine ID is 
# the first of:
#   /etc/machine-id (if exists)
#   IOPlatformExpertDevice (OS X)
#   hostname
#
function get_uid() {
  local _tmp
  local _uid
  
  _uid=$(hostname)
  if [ -f /etc/machine-id ]; then
    _uid=$(cat /etc/machine-id)
  else
    _tmp=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk '/IOPlatformUUID/ { split($0, line, "\""); printf("%s\n", line[4]); }')
    if [ "$_tmp" != "" ]; then
      _uid="$_tmp"
    fi
  fi
  echo "$_uid"
}

# Generic debug printer function. Uses the following arguments: 
#
#  $1 => the message to print
#  $2 => the message level - one of ERROR, WARN or DEBUG (default)
#  $3 => function or script name (optional)
#  $4 => line number within the function or script (optional)
# 
# This function uses the environment variable DEBUG to determine which messages 
# to display and which to suppress. This variable should be set to one of 
# ERROR, WARN, DEBUG or NONE. If not set (or an invalid option), ERROR is 
# assumed
# Start time for print_msg
export print_msg_start=$SECONDS
function print_msg() {
  local _level
  local _level_msg
  local _level_label
  local _message_id
  local _runtime
  
  [ "$3" ] && [ "$4" ] && _message_id="$3 [$4]"
  [ "$3" ] && _message_id="$3"
  _runtime=$(( SECONDS - print_msg_start))
  
  case "$DEBUG" in
    NONE|none)
      _level=-1
      ;;
    DEBUG|debug)
      _level=3
      ;;
    WARN|warn)
      _level=2
      ;;
    *)
      _level=1
      ;;
  esac
  
  case "$2" in
    DEBUG|debug)
      _level_msg=3
      _level_label=DEBUG
      ;;
    WARN|warn)
      _level_msg=2
      _level_label=WARN
      ;;
    *)
      _level_msg=1
      _level_label=ERROR
      ;;
  esac
  
  if [ "$_level_msg" -le "$_level" ] && [ "$1" ]; then
    printf "%ds %s > [%s] %s\\n" "$_runtime" "$_message_id" "$_level_label" "$1"
  fi
}


# Invoked when the script starts - performs validation checks and initializations
function s3_sync2_startup() {
  local _tmp_file
  local _tmp_file_name
  
  # Both <LocalPath> and <S3Uri> are required
  if [ "$LOCAL_PATH" = "" ] || [ "$S3_URI" = "" ]; then
    print_msg "<LocalPath> and <S3Uri> are required" error util.sh $LINENO
    exit 1
  else
    print_msg "<LocalPath> [$LOCAL_PATH] and <S3Uri> [$S3_URI] are valid" debug util.sh $LINENO
  fi

  # <LocalPath> and <S3Uri> should not include trailing slashes
  if [ "${LOCAL_PATH: -1}" = "/" ] || [ "${S3_URI: -1}" = "/" ]; then
    print_msg "<LocalPath> and <S3Uri> should not included trailing slashes" error util.sh $LINENO
    exit 1
  fi
  
  # Validate polling interval
  if [[ "$POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]] && [ "$POLL_INTERVAL" -ge 1 ] && [ "$POLL_INTERVAL" -le 3600 ]; then
    print_msg "--poll $POLL_INTERVAL is valid" debug util.sh $LINENO
  else
    print_msg "--poll $POLL_INTERVAL is invalid - it must be a positive integer between 1-3600" error util.sh $LINENO
    exit 1
  fi

  # Validate AWS CLI is installed
  if command -v aws &>/dev/null; then
    print_msg "aws cli is installed" debug util.sh $LINENO
  else
    print_msg "aws cli is not installed" error util.sh $LINENO
    exit 1
  fi

  # Validate inotifywait or md5sum are installed
  if command -v inotifywait &>/dev/null || command -v md5sum &>/dev/null || command -v md5 &>/dev/null; then
    print_msg "inotifywait or md5sum|md5 are installed" debug util.sh $LINENO
  else
    print_msg "either inotifywait or md5sum must be installed" error util.sh $LINENO
    exit 1
  fi

  # Validate aws cli credentials and <S3Uri>
  if eval "aws $AWS_CLI_OPTIONS s3 ls >/dev/null"; then
    print_msg "Validated aws cli credentials and <S3Uri> s3://$S3_BUCKET" debug util.sh $LINENO
  else
    print_msg "unable to validate <S3Uri> using > aws $AWS_CLI_OPTIONS s3 ls s3://$S3_BUCKET" error util.sh $LINENO
    exit 1
  fi

  # Validate both <LocalPath> and <S3Uri> are writable
  _tmp_file=$(mktemp)
  _tmp_file_name=$(basename "$_tmp_file")
  if cp "$_tmp_file" "$LOCAL_PATH/$_tmp_file_name"; then
    rm -f _tmp_file_name "$LOCAL_PATH/$_tmp_file_name"
    print_msg "<LocalPath> $LOCAL_PATH is writable" debug util.sh $LINENO
  else
    print_msg "<LocalPath> $LOCAL_PATH is not writable" error util.sh $LINENO
    exit 1
  fi
  if eval "aws $AWS_CLI_OPTIONS s3 cp $_tmp_file $S3_URI/$_tmp_file_name" >/dev/null && \
     eval "aws $AWS_CLI_OPTIONS s3 rm $S3_URI/$_tmp_file_name" >/dev/null; then
    print_msg "<S3Uri> $S3_URI is valid and writable" debug util.sh $LINENO
  else
    print_msg "<S3Uri> $S3_URI is not writable" error util.sh $LINENO
    exit 1
  fi
  
  # Validate CloudFront distribution
  if [ "$CF_DISTRIBUTION_ID" != "" ]; then
    print_msg "Validating CloudFront distribution [id=$CF_DISTRIBUTION_ID]" debug util.sh $LINENO
    if eval "aws $AWS_CLI_OPTIONS cloudfront get-distribution --id $CF_DISTRIBUTION_ID" >/dev/null; then
      print_msg "Successfully validated CloudFront distribution" debug util.sh $LINENO
    else
      print_msg "CloudFront distribution is not valid" error util.sh $LINENO
      exit 1
    fi
  fi
  
  # Validate DFS locking
  if [ "$DFS" -eq 1 ]; then
    print_msg "Validating DFS distributed locking [bucket=$S3_BUCKET; lock=$DFS_LOCK_FILE]" debug util.sh $LINENO
    if eval s3_distributed_lock "$S3_BUCKET" "$DFS_LOCK_FILE" "$DFS_LOCK_TIMEOUT" "$DFS_LOCK_WAIT"; then
      print_msg "Successfully validated obtaining a DFS lock" debug util.sh $LINENO
      if eval s3_distributed_unlock "$S3_BUCKET" "$DFS_LOCK_FILE"; then
        print_msg "Successfully validated releasing a DFS lock" debug util.sh $LINENO
      else
        print_msg "Unable to validate releasing a DFS lock" error util.sh $LINENO
        exit 1
      fi
    else
      print_msg "Unable to validate obtaining a DFS lock" error util.sh $LINENO
      exit 1
    fi
  fi
  
}
