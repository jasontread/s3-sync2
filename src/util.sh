#!/bin/bash

# trap SIGINT|SIGTERM function - used for any necessary cleanup before 
# terminating
function cleanup() {
  print_msg "cleanup invoked" debug cleanup $LINENO
  export KILLED=1
  kill -SIGINT "$(jobs -p)"
}

# Sets/updates the global env variable LOCAL_CHECKSUM. Sets to an empty string
# on error
function get_local_checksum() {
  LOCAL_CHECKSUM=
  
  local _files_count
  local _md5_cmd
  
  # Determine which md5 command to use
  command -v md5sum &>/dev/null && _md5_cmd=md5sum || _md5_cmd=md5
  
  # Determine number of files in LOCAL_PATH
  _files_count=$(find "$LOCAL_PATH" -type f | wc -l)
  if [ ! "$_files_count" ]; then
    print_msg "Unable to determine file count in $LOCAL_PATH" error get_local_checksum $LINENO
  fi
  
  # Generate md5 checksum for files in LOCAL_PATH
  _files_count="${_files_count// /}"
  print_msg "Generating checksum for $LOCAL_PATH using $_md5_cmd [num files: $_files_count]" debug get_local_checksum $LINENO
  if [ "$_files_count" -gt 0 ]; then
    LOCAL_CHECKSUM=$(eval "find $LOCAL_PATH $MD5_NOT_PATH_OPT -type f -exec $_md5_cmd {} \\; | sort -k 2 | $_md5_cmd | tr -s '[:blank:]' ',' | cut -d',' -f1")
  # If LOCAL_PATH is empty, use the string EMPTY instead
  else
    LOCAL_CHECKSUM=EMPTY
  fi
  print_msg "Generated checksum [$LOCAL_CHECKSUM]" debug get_local_checksum $LINENO
}

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
# assumed. ERROR messages are printed to stderr and all others stdout
# Start time for print_msg
export print_msg_start=$SECONDS
function print_msg() {
  local _dest
  local _level
  local _level_msg
  local _level_label
  local _message_id
  local _runtime
  _dest=1
  
  if [ "$3" ] && [ "$4" ]; then
    _message_id="$3 [$4]"
  else
    _message_id="$3"
  fi
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
      _dest=2
      _level_msg=1
      _level_label=ERROR
      ;;
  esac
  
  if [ "$_level_msg" -le "$_level" ] && [ "$1" ]; then
    
    printf "%-27s > [%-5s] [%2ss] %s\\n" "$_message_id" "$_level_label" "$_runtime" "$1" >&$_dest
  fi
}


# Invoked when the script starts - performs validation checks and initializations
function startup() {
  local _tmp_file
  local _tmp_file_name
  
  # Both <LocalPath> and <S3Uri> are required
  if [ ! "$LOCAL_PATH" ] || [ ! "$S3_URI" ]; then
    print_msg "<LocalPath> and <S3Uri> are required [LOCAL_PATH=$LOCAL_PATH] [S3_URI=$S3_URI]" error startup $LINENO
    exit 1
  else
    print_msg "<LocalPath> [$LOCAL_PATH] and <S3Uri> [$S3_URI] are valid" debug startup $LINENO
  fi

  # <LocalPath> and <S3Uri> should not include trailing slashes
  if [ "${LOCAL_PATH: -1}" = "/" ] || [ "${S3_URI: -1}" = "/" ]; then
    print_msg "<LocalPath> and <S3Uri> should not included trailing slashes" error startup $LINENO
    exit 1
  fi
  
  # Validate MD5_SKIP_PATH
  if [ "$MD5_SKIP_PATH" ]; then
    for path in $( echo "$MD5_SKIP_PATH" | tr "|" "\\n" ); do
      if [[ ! "$path" =~ "$LOCAL_PATH".* ]]; then
        print_msg "Invalid --md5-skip-path option - path $path is not in <LocalPath> $LOCAL_PATH" error startup $LINENO
        exit 1
      elif [ "${path: -1}" = "/" ]; then
        print_msg "Invalid --md5-skip-path option - path $path should not include trailing slash" error startup $LINENO
        exit 1
      fi
    done
  fi
  
  # Both --init-sync-down and --init-sync-up should not be set
  if [ "$INIT_SYNC_DOWN" -eq 1 ] && [ "$INIT_SYNC_UP" -eq 1 ]; then
    print_msg "Both --init-sync-down and --init-sync-up should not be set" error startup $LINENO
    exit 1
  fi
  
  # Validate polling interval
  if [[ "$POLL_INTERVAL" =~ ^[0-9]*$ ]] && [ "$POLL_INTERVAL" -ge 0 ] && [ "$POLL_INTERVAL" -le 3600 ]; then
    print_msg "--poll $POLL_INTERVAL is valid" debug startup $LINENO
  else
    print_msg "--poll $POLL_INTERVAL is invalid - it must be a positive integer between 0-3600" error startup $LINENO
    exit 1
  fi
  
  # Validate max failures
  if [[ "$MAX_FAILURES" =~ ^[1-9][0-9]*$ ]] && [ "$MAX_FAILURES" -ge 0 ]; then
    print_msg "--max-failures $MAX_FAILURES is valid" debug startup $LINENO
  else
    print_msg "--max-failures $MAX_FAILURES is invalid - it must be a positive integer" error startup $LINENO
    exit 1
  fi

  # Validate AWS CLI is installed
  if command -v aws &>/dev/null; then
    print_msg "aws cli is installed" debug startup $LINENO
  else
    print_msg "aws cli is not installed" error startup $LINENO
    exit 1
  fi

  # Validate md5sum or md5 are installed
  if command -v md5sum &>/dev/null || command -v md5 &>/dev/null; then
    print_msg "md5sum|md5 are installed" debug startup $LINENO
  else
    print_msg "either md5sum or md5 must be installed" error startup $LINENO
    exit 1
  fi

  # Validate aws cli credentials and <S3Uri>
  if eval "aws $AWS_CLI_OPTIONS s3 ls >/dev/null"; then
    print_msg "Validated aws cli credentials and <S3Uri> s3://$S3_BUCKET" debug startup $LINENO
  else
    print_msg "unable to validate <S3Uri> using > aws $AWS_CLI_OPTIONS s3 ls s3://$S3_BUCKET" error startup $LINENO
    exit 1
  fi
  
  # Validate that <LocalPath> exits and is writeable
  if [ -w "$LOCAL_PATH" ]; then
    print_msg "<LocalPath> $LOCAL_PATH exists and is writable" debug startup $LINENO
  elif [ -d "$LOCAL_PATH" ]; then
    print_msg "<LocalPath> $LOCAL_PATH is not writable" error startup $LINENO
    exit 1
  else
    print_msg "<LocalPath> $LOCAL_PATH does not exist" error startup $LINENO
    exit 1
  fi

  # Validate <S3Uri> exists and is writable
  _tmp_file=$(mktemp)
  _tmp_file_name=$(basename "$_tmp_file")
  if eval "aws $AWS_CLI_OPTIONS s3 cp $_tmp_file $S3_URI/$_tmp_file_name" >/dev/null && \
     eval "aws $AWS_CLI_OPTIONS s3 rm $S3_URI/$_tmp_file_name" >/dev/null; then
    print_msg "<S3Uri> $S3_URI is valid and writable" debug startup $LINENO
  else
    print_msg "<S3Uri> $S3_URI is not writable" error startup $LINENO
    exit 1
  fi
  
  # Validate CloudFront distribution
  if [ "$CF_DISTRIBUTION_ID" != "" ]; then
    print_msg "Validating CloudFront distribution [id=$CF_DISTRIBUTION_ID]" debug startup $LINENO
    if eval "aws $AWS_CLI_OPTIONS cloudfront get-distribution --id $CF_DISTRIBUTION_ID" >/dev/null; then
      print_msg "Successfully validated CloudFront distribution" debug startup $LINENO
    else
      print_msg "CloudFront distribution is not valid" error startup $LINENO
      exit 1
    fi
  fi
  
  # Validate DFS locking
  if [ "$DFS" -eq 1 ]; then
    if [ "$DFS_UID" ]; then
      print_msg "Validating DFS distributed locking [bucket=$S3_BUCKET; lock=$DFS_LOCK_FILE; DFS_UID=$DFS_UID]" debug startup $LINENO
      if eval s3_distributed_lock "$S3_BUCKET" "$DFS_LOCK_FILE" "$DFS_LOCK_TIMEOUT" "$DFS_LOCK_WAIT" "$DFS_UID"; then
        print_msg "Successfully validated obtaining a DFS lock" debug startup $LINENO
        if eval s3_distributed_unlock "$S3_BUCKET" "$DFS_LOCK_FILE" "$DFS_UID"; then
          print_msg "Successfully validated releasing a DFS lock" debug startup $LINENO
        else
          print_msg "Unable to validate releasing a DFS lock" error startup $LINENO
          exit 1
        fi
      else
        print_msg "Unable to validate obtaining a DFS lock" error startup $LINENO
        exit 1
      fi
    else 
      print_msg "Unable to get system UID for DFS locking" error startup $LINENO
      exit 1
    fi
  fi
}


# Primary sychronization function - invoked in a subshell every $POLL_INTERVAL 
# seconds. This function accepts 1 argument - $1=up|down which, if specified, 
# limits sychronization to the designation direction. If not specified, both 
# directions will be synchronized
local_tracker=$(mktemp)
function s3_sync2() (
  
  # local_tracker temp file must be accessible
  if [ ! -f "$local_tracker" ] && ! touch "$local_tracker"; then
    print_msg "Unable to validate releasing a DFS lock" error s3_sync2 $LINENO
    exit 1
  fi
  
  # LOCAL_PATH no longer exists
  if [ ! -d "$LOCAL_PATH" ]; then
    print_msg "<LocalPath> $LOCAL_PATH does not exist" error s3_sync2 $LINENO
    exit 1
  # LOCAL_PATH is no longer writeable
  elif [ ! -w "$LOCAL_PATH" ]; then
    print_msg "<LocalPath> $LOCAL_PATH is not writeable" error s3_sync2 $LINENO
    exit 1
  else
    # Uplink synchronization
    if [ ! "$1" ] || [ "$1" = "up" ]; then
      local _checksum_previous
      local _files_count
      local _lock_file
      local _md5_cmd
    
      # Determine current checksum
      get_local_checksum
      
      if [ ! "$LOCAL_CHECKSUM" ]; then
        print_msg "Unable to determine $LOCAL_PATH checksum" error s3_sync2 $LINENO
        exit 1
      fi
      
      # Get previous checksum and write current checksum to the tracker file
      _checksum_previous=$(cat "$local_tracker")
    
      # Checksums have changed
      if [ "$_checksum_previous" ] && [ "$_checksum_previous" != "$LOCAL_CHECKSUM" ]; then
        print_msg "Checksums has changed [$LOCAL_CHECKSUM!=$_checksum_previous] - initiating synchronization <LocalPath> to <S3Uri>" debug s3_sync2 $LINENO
        if [ "$DFS" -ne 1 ] || eval s3_distributed_lock "$S3_BUCKET" "$DFS_LOCK_FILE" "$DFS_LOCK_TIMEOUT" "$DFS_LOCK_WAIT" "$DFS_UID"; then
          # If --delete is set, then generate lock file locally so it is not deleted by the synchronization
          if [ "$DFS" -eq 1 ] && [[ "$AWS_CLI_CMD_SYNC_UP" =~ .*"--delete".* ]]; then
            _lock_file="$LOCAL_PATH/.s3-sync2.lock"
            print_msg "Downloading lock file locally [$_lock_file] so it is not deleted remotely" debug s3_sync2 $LINENO
            if eval "aws $AWS_CLI_OPTIONS s3 cp s3://$S3_BUCKET/$DFS_LOCK_FILE $_lock_file"; then
              print_msg "Lock file downloaded successfully" debug s3_sync2 $LINENO
            else
              print_msg "Unable to download lock file" warn s3_sync2 $LINENO
            fi
          fi
          if eval "$AWS_CLI_CMD_SYNC_UP"; then
            if [ -f "$_lock_file" ]; then rm -f "$_lock_file"; fi
            s3_distributed_unlock "$S3_BUCKET" "$DFS_LOCK_FILE" "$DFS_UID"
            print_msg "Uplink synchronization successful" debug s3_sync2 $LINENO
            # Validate CloudFront distribution
            if [ "$CF_DISTRIBUTION_ID" != "" ]; then
              print_msg "Issuing CloudFront invalidation [distribution=$CF_DISTRIBUTION_ID] [paths=$CF_INVALIDATION_PATHS]" debug startup $LINENO
              if eval "aws $AWS_CLI_OPTIONS cloudfront create-invalidation --distribution-id $CF_DISTRIBUTION_ID --paths \"$CF_INVALIDATION_PATHS\"" >/dev/null; then
                print_msg "Invalidation successful" debug startup $LINENO
              else
                print_msg "Invalidation failed" warn startup $LINENO
              fi
            fi
          else
            if [ -f "$_lock_file" ]; then rm -f "$_lock_file"; fi
            s3_distributed_unlock "$S3_BUCKET" "$DFS_LOCK_FILE" "$DFS_UID"
            print_msg "Uplink synchronization failed" error s3_sync2 $LINENO
            exit 1
          fi
        else
          print_msg "Uplink synchronization failed - unable to obtain DFS distributed lock" error s3_sync2 $LINENO
          exit 1
        fi
      # Checksums have not changed  
      elif [ "$_checksum_previous" ]; then
        print_msg "Checksum [$LOCAL_CHECKSUM] has not changed - skipping <LocalPath> to <S3Uri> synchronization" debug s3_sync2 $LINENO
      # No previous checksum - this is the first invocation
      else
        print_msg "Initial sync call - skipping <LocalPath> to <S3Uri> synchronization" debug s3_sync2 $LINENO
      fi
    else
      print_msg "Skipping uplink synchronization due to type argument [$1]" debug s3_sync2 $LINENO
    fi
    
    # Downlink synchronization
    if [ ! "$1" ] || [ "$1" = "down" ]; then
      print_msg "Invoking downlink synchronization <S3Uri> to <LocalPath>" debug s3_sync2 $LINENO
      if eval "$AWS_CLI_CMD_SYNC_DOWN"; then
        print_msg "Downlink synchronization successful" debug s3_sync2 $LINENO
        
        # Determine new checksum
        get_local_checksum
        
        if [ ! "$LOCAL_CHECKSUM" ]; then
          print_msg "Unable to determine $LOCAL_PATH checksum" error s3_sync2 $LINENO
          exit 1
        fi
      else
        print_msg "Downlink synchronization failed" error s3_sync2 $LINENO
        exit 1
      fi
    else
      print_msg "Skipping downlink synchronization due to type argument [$1]" debug s3_sync2 $LINENO
    fi
    
    print_msg "Setting local checksum [$LOCAL_CHECKSUM]" debug s3_sync2 $LINENO
    echo "$LOCAL_CHECKSUM" > "$local_tracker"
  fi
)
