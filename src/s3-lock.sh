#!/bin/bash

# Attempts to create a distributed lock using S3's read-after-write consistency 
# model [see https://docs.aws.amazon.com/AmazonS3/latest/dev/Introduction.html#ConsistencyModel].
# To do so, it first checks if the lock file exists. If it does not exist, it 
# invokes put-object using a unique machine ID as the lock file and then 
# immediately invokes get-object. If the contents of the lock file object match 
# those of the unique machine ID then the lock is assumed to be successful and 
# the function exits with exit code 0. If not it exits with exit code 1. 
# 
# If the lock file exists, howevever, then a get-object operation is performed, 
# and if the object contents matches the unique machine ID, then the lock will 
# be deleted and the lock attempt proceed normally.
#
# Finally, if the lock file exists, and it is older than the lock timeout 
# argument, then it will be assumed to be stale and the object deleted (but 
# lock will still be considered unsuccessful - i.e. exit 1).
#
# If successful, use s3_distributed_unlock to release the lock.
#
# This function uses the following arguments:
# 
#  $1 => S3 bucket - e.g. mybucket (required)
#  $2 => lock file path without leading / - e.g. dir/.lock (required)
#  $3 => max lock time (secs) - e.g. 60 = 1 minute - default 60
#  $4 => max time to wait for lock (secs) - 0 for none - default 180 (3 mins)
#  $5 => hardcoded machine UID for testing
#  $6 => wait start time - used for recursive calls when wait time is > 0
#        and lock is initially unsuccessful
# 
# In addition the following environment varialbes may be set:
#  $AWS_CLI_OPTIONS => aws cli options
#  $DEBUG => debug flag - one of ERROR, WARN, DEBUG or NONE
# 
function s3_distributed_lock() (
  local _date_args
  local _lock_file
  local _lock_uid
  local _modified_threshold
  local _object
  local _runtime
  local _start_time
  local _status
  local _timeout
  local _timestamp
  local _try_wait
  local _uid
  local _uid_file
  local _wait
  
  # Defaults values
  [ "$6" ] && _start_time="$6" || _start_time=$SECONDS
  _status=0
  [ "$3" ] && _timeout="$3" || _timeout=60
  _try_wait=0
  [ "$5" ] && _uid="$5" || _uid=$(get_uid)
  [ "$4" ] && _wait="$4" || _wait=180
  
  if [ "$1" != "" ] && [ "$2" != "" ]; then
    _lock_file=$(mktemp)
    _uid_file=$(mktemp)
    echo "$_uid" >"$_uid_file"
    
    _timestamp=$(date +%s)
    # Date args are different in BSD vs GNU
    date -d @"$_timestamp" &>/dev/null && _date_args='-d @' || _date_args='-r '
    _modified_threshold=$(date -u "$_date_args"$((_timestamp - _timeout)) "+%FT%T.000Z")
    
    if [ "$_modified_threshold" = "" ]; then
      print_msg "Unable to determine date modification threshold" error s3_distributed_lock $LINENO
      _status=1
    else
      print_msg "Attempting to obtain distributed lock using s3://$1/$2 [uid=$_uid] [timeout=$_timeout] [wait=$_wait] [modified_threshold=$_modified_threshold]" debug s3_distributed_lock $LINENO
      while read -r _object; do
        if [ "$_object" = "$2" ]; then
          print_msg "Found existing lock - checking contents" debug s3_distributed_lock $LINENO
          if ! eval "aws $AWS_CLI_OPTIONS s3api get-object --bucket $1 --key $_object $_lock_file &>/dev/null" || ! [ -f "$_lock_file" ] ; then
            print_msg "Unable to get-object > aws $AWS_CLI_OPTIONS s3api get-object --bucket $1 --key $_object $_lock_file" error s3_distributed_lock $LINENO
            _status=1
          else
            print_msg "Successfully downloaded lock file to $_lock_file" debug s3_distributed_lock $LINENO
            if diff "$_uid_file" "$_lock_file" &>/dev/null; then
              print_msg "Stale lock file for this UID discovered [s3://$1/$_object] - deleting" warn s3_distributed_lock $LINENO
              if ! eval "aws $AWS_CLI_OPTIONS s3api delete-object --bucket $1 --key $_object &>/dev/null"; then
                print_msg "Unable to delete stale lock file" error s3_distributed_lock $LINENO
                _status=1
              else
                print_msg "Stale lock file deleted successfully" debug s3_distributed_lock $LINENO
              fi
            else
              _lock_uid=$(cat "$_lock_file")
              print_msg "Existing lock file UID [$_lock_uid] does not match this machine [$_uid] - lock unsuccessful" warn s3_distributed_lock $LINENO
              _status=1
              _try_wait=1
            fi
          fi
          break
        elif [ "$_object" != "None" ]; then
          print_msg "Skipping object $_object because it does not exactly match lock path $2" debug s3_distributed_lock $LINENO
        fi
      done < <(eval "aws $AWS_CLI_OPTIONS --output text s3api list-objects --bucket $1 --prefix $2 --query=\"Contents[?LastModified >= '$_modified_threshold'].{Key:Key}\"")
    fi
    
    if [ $_status -eq 0 ]; then
      print_msg "Attempting to put-object [s3://$1/$2]" debug s3_distributed_lock $LINENO
      if eval "aws $AWS_CLI_OPTIONS s3api put-object --body $_uid_file --bucket $1 --key $2 &>/dev/null"; then
        print_msg "Successfully put-object - using get-object to validate object contents match UID (based on S3 read-after-write consistency)" debug s3_distributed_lock $LINENO
        if eval "aws $AWS_CLI_OPTIONS s3api get-object --bucket $1 --key $2 $_lock_file &>/dev/null"; then
          print_msg "get-object successful" debug s3_distributed_lock $LINENO
          if diff "$_uid_file" "$_lock_file" &>/dev/null; then
            print_msg "UID matches - lock successful" debug s3_distributed_lock $LINENO
          else
            print_msg "UID does not match - lock unsuccessful" warn s3_distributed_lock $LINENO
            _status=1
            _try_wait=1
          fi
        else
          print_msg "Unable to get-object" error s3_distributed_lock $LINENO
          _status=1
        fi
      else
        print_msg "Unable to put-object" error s3_distributed_lock $LINENO
        _status=1
      fi
    fi
    rm -f "$_uid_file"
    rm -f "$_lock_file"
  else
    print_msg "Missing required arguments [bucket=$1] [path=$2]" error s3_distributed_lock $LINENO
    _status=1
  fi
  
  # Try again if current wait time is less than max wait time
  _runtime=$(( SECONDS - _start_time ))
  if [ $_status -eq 1 ] && [ $_try_wait -eq 1 ] && [ $_runtime -lt $_wait ]; then
    print_msg "Unable to obtain lock but still within max wait period [$_runtime < $_wait] - sleeping 1-30 secs and retrying" debug s3_distributed_lock $LINENO
    sleep $(( RANDOM % 30 ))
    s3_distributed_lock "$1" "$2" "$_timeout" "$_wait" "$_uid" "$_start_time"
    exit $?
  else  
    exit $_status
  fi
)


# Used to release a distributed lock previously obtained from 
# s3_distributed_lock. The lock will not be purged if the lock file does not 
# exist, or does not match the machine UID (exit code 1).
#
# This function uses the following arguments:
# 
#  $1 => S3 bucket - e.g. mybucket (required)
#  $2 => lock file path without leading / - e.g. dir/.lock (required)
#  $3 => Optional hardcoded UID - use for testing
# 
# In addition the following environment varialbes may be set:
#  $AWS_CLI_OPTIONS => aws cli options
#  $DEBUG => debug flag - one of ERROR, WARN, DEBUG or NONE
# 
function s3_distributed_unlock() (
  local _lock_file
  local _object
  local _status
  local _uid
  local _uid_file
  
  # Defaults values
  _status=0
  [ "$3" ] && _uid="$3" || _uid=$(get_uid)
  
  if [ "$1" != "" ] && [ "$2" != "" ]; then
    _lock_file=$(mktemp)
    _uid_file=$(mktemp)
    echo "$_uid" >"$_uid_file"
    
    print_msg "Attempting to release distributed lock from s3://$1/$2 [uid=$_uid]" debug s3_distributed_unlock $LINENO
    
    while read -r _object; do
      if [ "$_object" = "$2" ]; then
        print_msg "Found existing lock - checking contents" debug s3_distributed_unlock $LINENO
        if ! eval "aws $AWS_CLI_OPTIONS s3api get-object --bucket $1 --key $_object $_lock_file &>/dev/null" || [ ! -f "$_lock_file" ]; then
          print_msg "Unable to get-object > aws $AWS_CLI_OPTIONS s3api get-object --bucket $1 --key $_object $_lock_file" error s3_distributed_unlock $LINENO
          _status=1
        else
          print_msg "Successfully downloaded lock file to $_lock_file" debug s3_distributed_unlock $LINENO
          if diff "$_uid_file" "$_lock_file" &>/dev/null; then
            print_msg "Lock file validated - deleting" debug s3_distributed_unlock $LINENO
            if ! eval "aws $AWS_CLI_OPTIONS s3api delete-object --bucket $1 --key $_object &>/dev/null"; then
              print_msg "Unable to delete lock file" error s3_distributed_unlock $LINENO
              _status=1
            else
              print_msg "Lock file deleted successfully" debug s3_distributed_unlock $LINENO
            fi
          else
            _lock_uid=$(cat "$_lock_file")
            print_msg "Lock file UID [$_lock_uid] does not match this machine [$_uid]" error s3_distributed_unlock $LINENO
          fi
        fi
        break
      elif [ "$_object" != "None" ]; then
        print_msg "Skipping object $_object because it does not exactly match lock path $2" debug s3_distributed_unlock $LINENO
      fi
    done < <(eval "aws $AWS_CLI_OPTIONS --output text s3api list-objects --bucket $1 --prefix $2 --query=\"Contents[].{Key:Key}\"")
    
    rm -f "$_uid_file"
    rm -f "$_lock_file"
  else
    print_msg "Missing required arguments [bucket=$1] [path=$2]" error s3_distributed_unlock $LINENO
    _status=1
  fi
  
  exit $_status
)
