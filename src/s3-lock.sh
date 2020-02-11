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
#  $3 => lock timeout (secs) - e.g. 60 = 1 minute - default 300
#  $4 => AWS cli profile (optional) - set to 0 to ignore if also specifying $5
#  $5 => Debug flag (set to 1 to enable debug output)
#  $6 => Optional hardcoded UID - use for testing
# 
s3_distributed_lock() {
  exit=0
  profile=
  if [[ "$4" != "" && "$4" != "0" ]]; then
    profile="--profile $4"
  fi
  if [[ "$1" != "" && "$2" != "" ]]; then
    timeout=300
    if [[ "$3" != "" ]]; then
      timeout="$3"
    fi
    lock_file=$(mktemp)
    uid_file=$(mktemp)
    uid="$6"
    if [[ "$uid" = "" ]]; then
      uid=$(get_uid)
    fi
    echo "$uid" >"$uid_file"
    
    # Date args are different in BSD vs GNU
    timestamp=$(date +%s)
    date_args='-d @'
    
    if date -d @"$timestamp" &>/dev/null; then
      date_args='-r '
    fi
    modified_threshold=$(date -u "$date_args"$((timestamp - timeout)) "+%FT%T.000Z")
    if [[ "$modified_threshold" = "" ]]; then
      if [[ "$5" = "1" ]]; then
        echo " > ERROR: Unable to determine date modification threshold"
      fi
      exit=1
    fi
    
    if [[ "$5" = "1" ]]; then
      echo "Attempting to obtain distributed lock using s3://$1/$2 [uid=$uid] [timeout=$timeout] [modified_threshold=$modified_threshold] [$profile]"
    fi
    while read -r object; do
      if [[ "$object" = "$2" ]]; then
        if [[ "$5" = "1" ]]; then
          echo " > Found existing lock - checking contents"
        fi
        if ! aws "$profile" s3api get-object --bucket "$1" --key "$object" "$lock_file" &>/dev/null || ! [ -f "$lock_file" ] ; then
          if [[ "$5" = "1" ]]; then
            echo " > ERROR: unable to get-object > aws $profile s3api get-object --bucket $1 --key $object $lock_file"
          fi
          exit=1
        else
          if [[ "$5" = "1" ]]; then
            echo " > Successfully downloaded lock file to $lock_file"
          fi
          if diff "$uid_file" "$lock_file" &>/dev/null; then
            if [[ "$5" = "1" ]]; then
              echo " > Stale lock file for this UID discovered [s3://$1/$object] - deleting"
            fi
            if ! aws "$profile" s3api delete-object --bucket "$1" --key "$object" &>/dev/null; then
              if [[ "$5" = "1" ]]; then
                echo " > ERROR: Unable to delete stale lock file"
              fi
              exit=1
            elif [[ "$5" = "1" ]]; then
              echo " > Stale lock file deleted successfully"
            fi
          else
            lock_uid=$(cat "$lock_file")
            if [[ "$5" = "1" ]]; then
              echo " > Existing lock file UID [$lock_uid] does not match this machine [$uid] - lock unsuccessful"
            fi
            exit=1
          fi
        fi
        break
      elif [[ "$5" = "1" && "$object" != "None" ]]; then
        echo " > Skipping object $object because it does not exactly match lock path $2"
      fi
    done < <(aws "$profile" --output text s3api list-objects --bucket "$1" --prefix "$2" --query='Contents[?LastModified >= `'"$modified_threshold"'`].{Key:Key}')
    
    if [ $exit -eq 0 ]; then
      if [[ "$5" = "1" ]]; then
        echo " > Attempting to put-object [s3://$1/$2]"
      fi
      if aws "$profile" s3api put-object --body "$uid_file" --bucket "$1" --key "$2" &>/dev/null; then
        if [[ "$5" = "1" ]]; then
          echo " > Successfully put-object - using get-object to validate object contents match UID (based on S3 read-after-write consistency)"
        fi
        if aws "$profile" s3api get-object --bucket "$1" --key "$2" "$lock_file" &>/dev/null; then
          if [[ "$5" = "1" ]]; then
            echo " > get-object successful"
          fi
          if diff "$uid_file" "$lock_file" &>/dev/null; then
            if [[ "$5" = "1" ]]; then
              echo " > UID matches - lock successful"
            fi
          else
            if [[ "$5" = "1" ]]; then
              echo " > WARNING: UID does not match - lock unsuccessful"
            fi
            exit=1
          fi
        else
          if [[ "$5" = "1" ]]; then
            echo " > ERROR: Unable to get-object"
          fi
          exit=1
        fi
      else
        if [[ "$5" = "1" ]]; then
          echo " > ERROR: Unable to put-object"
        fi
        exit=1
      fi
    fi
    rm -f "$uid_file"
    rm -f "$lock_file"
  else
    if [[ "$5" = "1" ]]; then
      echo "ERROR: Missing required arguments [bucket=$1] [path=$2]"
    fi
    exit=1
  fi
  
  exit $exit
}


# Used to release a distributed lock previously obtained from 
# s3_distributed_lock. The lock will not be purged if the lock file does not 
# exist, or does not match the machine UID (exit code 1).
#
# This function uses the following arguments:
# 
#  $1 => S3 bucket - e.g. mybucket (required)
#  $2 => lock file path without leading / - e.g. dir/.lock (required)
#  $3 => AWS cli profile (optional) - set to 0 to ignore if also specifying $5
#  $4 => Debug flag (set to 1 to enable debug output)
#  $5 => Optional hardcoded UID - use for testing
# 
function s3_distributed_unlock() {
  exit=0
  profile=
  if [[ "$3" != "" && "$3" != "0" ]]; then
    profile="--profile $3"
  fi
  if [[ "$1" != "" && "$2" != "" ]]; then
    lock_file=$(mktemp)
    uid_file=$(mktemp)
    uid="$5"
    if [[ "$uid" = "" ]]; then
      uid=$(get_uid)
    fi
    echo "$uid" >"$uid_file"
    
    if [[ "$4" = "1" ]]; then
      echo "Attempting to release distributed lock from s3://$1/$2 [uid=$uid] [$profile]"
    fi
    while read -r object; do
      if [[ "$object" = "$2" ]]; then
        if [[ "$4" = "1" ]]; then
          echo " > Found existing lock - checking contents"
        fi
        if ! aws "$profile" s3api get-object --bucket "$1" --key "$object" "$lock_file" &>/dev/null || [ ! -f "$lock_file" ]; then
          if [[ "$4" = "1" ]]; then
            echo " > ERROR: unable to get-object > aws $profile s3api get-object --bucket $1 --key $object $lock_file"
          fi
          exit=1
        else
          if [[ "$4" = "1" ]]; then
            echo " > Successfully downloaded lock file to $lock_file"
          fi
          if diff "$uid_file" "$lock_file" &>/dev/null; then
            if [[ "$4" = "1" ]]; then
              echo " > Lock file validated - deleting"
            fi
            if ! aws "$profile" s3api delete-object --bucket "$1" --key "$object" &>/dev/null; then
              if [[ "$4" = "1" ]]; then
                echo " > ERROR: Unable to delete lock file"
              fi
              exit=1
            elif [[ "$4" = "1" ]]; then
              echo " > Lock file deleted successfully"
            fi
          else
            lock_uid=$(cat "$lock_file")
            if [[ "$4" = "1" ]]; then
              echo " > ERROR: Lock file UID [$lock_uid] does not match this machine [$uid]"
            fi
          fi
        fi
        break
      elif [[ "$4" = "1" && "$object" != "None" ]]; then
        echo " > Skipping object $object because it does not exactly match lock path $2"
      fi
    done < <(aws "$profile" --output text s3api list-objects --bucket "$1" --prefix "$2" --query='Contents[].{Key:Key}')
    
    rm -f "$uid_file"
    rm -f "$lock_file"
  else
    if [[ "$4" = "1" ]]; then
      echo "ERROR: Missing required arguments [bucket=$1] [path=$2]"
    fi
    exit=1
  fi
  
  exit $exit
}


# Returns a unique identifier (UID) for this machine. The unique machine ID is 
# the first of:
#   /etc/machine-id (if exists)
#   IOPlatformExpertDevice (OS X)
#   hostname
#
get_uid() {
  uid=$(hostname)
  if [ -f /etc/machine-id ]; then
    uid=$(cat /etc/machine-id)
  else
    tmp=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk '/IOPlatformUUID/ { split($0, line, "\""); printf("%s\n", line[4]); }')
    if [[ "$tmp" != "" ]]; then
      uid="$tmp"
    fi
  fi
  echo "$uid"
}
