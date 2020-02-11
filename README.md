# s3-sync2
[![CircleCI](https://circleci.com/gh/jasontread/s3-sync2.svg?style=svg&circle-token=a487acc2bd234fcdadb0eb556c27a173d1c1123c)](https://circleci.com/gh/jasontread/s3-sync2)

This script facilitates bidirectional synchronization between a local file 
system path and an [Amazon S3](https://aws.amazon.com/s3/) storage bucket by 
wrapping the (unidirectional) 
[`aws s3 sync`](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html)
CLI. It is functionally similar to the following with added logic for event 
triggering, distributed use and automated 
[Amazon CloudFront](https://aws.amazon.com/cloudfront/) edge cache 
invalidations:

```
aws s3 sync <LocalPath> <S3Uri>
aws s3 sync <S3Uri> <LocalPath>
```

## Background
This script was created to solve the problem of utilizing S3 storage 
concurrently within clusters of ephemeral 
[AWS ECS Fargate](https://aws.amazon.com/fargate/) container instances with 
software that expects and depends on a traditional (persistent) file system for 
application data. Prior to writing this script, multiple alternatives were 
considered for this use case including:

* [s3fs-fuse](https://github.com/s3fs-fuse/s3fs-fuse) - A FUSE-based file 
system backed by Amazon S3. Unsuitable because it requires 
[privileged mode](https://twpower.github.io/178-run-container-as-privileged-mode-en)
which is not supported by ECS Fargate containers. Additionally, in some 
preliminary testing, even in privileged mode performance was poor and often 
files were corrupted in busy file systems.

* Peer-to-peer file synchronization tools - [Syncthing](https://syncthing.net)
and [Resilio Sync](https://www.resilio.com/individuals/). Unsuitable because 
they depend on at least 1 peer being active at all times as well as due to 
complexity involved in provisioning/deprovisioning of nodes within an often 
fast changing containerized environment.

* Client/server file synchronization tools - [Nextcloud](https://nextcloud.com)
and [ownCloud](https://owncloud.org/). Unsuitable because they depend on a 
maintaining a dedicated server (which is what we're trying to get away from 
with AWS Fargate), as well as the complexity of registering/deregistering new
clients within a fast changing containered environment.

* File hosting and collaboration services - [Dropbox](https://www.dropbox.com/)
and [Google Drive](https://www.google.com/drive/), for example. While these 
services could work, they are not designed with this use case in mind, and the 
costs would be too high, and orchestration of authorizing/deauthorizing 
container instances could be challenging.

## Usage
This script does not daemonize - it will run continually until terminated. 

```
s3-sync2 [options] <LocalPath> <S3Uri>
[--cf-dist-id | -c] = CF_DISTRIBUTION_ID
[--cf-inval-always]
[--cf-inval-paths] = CF_INVALIDATION_PATHS
[--debug]
[--dfs | -d]
[--dfs-lock-timeout | -t] = DFS_LOCK_TIMEOUT
[--dfs-lock-wait | -w] = DFS_LOCK_WAIT
[--event-queue | -q] = SQS_EVENT_QUEUE
[--event-queue-cleanup]
[--init-sync-down | -i]
[--init-sync-up | -u]
[--poll | -p] = POLL_INTERVAL_SECS
```

## Options
All standard 
[`aws s3 sync`](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html) 
CLI options are supported, in addition to the following `s3-sync2` specific 
options. As with `aws s3 sync`, the only options required by this script are 
`<LocalPath>` and `<S3Uri>` (which may be specified interchangeably).

`<LocalPath>` Local directory to synchronize - e.g. `/path/to/local/dir`

`<S3Uri>` Remote S3 URI - e.g. `s3://mybucket/remote/dir`

`--cf-dist-id | -c` ID of a CloudFront distributuion to trigger 
[edge cache invalidations](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Invalidation.html)
on when local changes occur.

`--cf-inval-always` By default CloudFront invalidations are triggered only by 
local changes. Setting this flag results in invalidations triggering by both 
local and remote/bucket changes (as detected by changes to `<LocalPath>` due to 
down synchronization)

`--cf-inval-paths` Value for the 
[`aws cloudfront create-invalidation --paths`](https://docs.aws.amazon.com/cli/latest/reference/cloudfront/create-invalidation.html)
argument. Default is invalidation of all cached objects: `/*`

`--debug` Show debug output

`--dfs | -d` Run as a quasi 
[distributed file system](https://en.wikipedia.org/wiki/Comparison_of_distributed_file_systems)
wherein multiple nodes can run this script concurrently. When enabled, an 
additional 
[distributed locking](https://redislabs.com/ebook/part-2-core-concepts/chapter-6-application-components-in-redis/6-2-distributed-locking/)
step is required when synchronizing from `<LocalPath>` to `<S3Uri>`. To do so, 
[S3's read-after-write consistency model](https://docs.aws.amazon.com/AmazonS3/latest/dev/Introduction.html#ConsistencyModel)
is leveraged in conjunction with an object `PUT` operation where the object 
contains a unique identifier for the node acquiring the lock.

`--dfs-lock-timeout | -t` the maximum time (secs) permitted for a distributed 
lock by another node before it is considered to be stale and force released. 
Default is `60` (1 minute)

`--dfs-lock-wait | -w` the maximum time (secs) to wait to acquire a distributed 
lock before exiting with an error. Default is 180 (3 minutes)

`--event-queue | -q` if set, this script will attempt to enable 
[S3 Event Notifications](https://docs.aws.amazon.com/AmazonS3/latest/dev/NotificationHowTo.html)
on the bucket associated with `<S3Uri>` with notifications sent to an 
[Amazon SQS](https://aws.amazon.com/sqs/) queue with the name specified by this 
option. If the queue does not exist, an attempt will be made to create it. The
event queues name specified should be unique for all nodes. Value may contain 
the token `[uid]` which will be replaced by the node's unique identifier 
(`/etc/machine-id` if present, or `hostname` otherwise). Event queue names can 
be a maximum of 80 characters and consist of alphanumeric characters, dashes or 
underscores only. If not set, `<S3Uri>` to `<LocalPath>` synchronization will 
trigger after each `--poll` interval is reached as opposed to only when changes 
occur provided by this option.

`--event-queue-cleanup` if set in conjunction with `--event-queue`, and this 
script receives a `SIGTERM` signal, then an attempt will be made to delete the
associated [Amazon SQS](https://aws.amazon.com/sqs/) queue.

`--init-sync-down | -i` if set, `aws s3 sync <S3Uri> <LocalPath>` will be 
invoked when the script starts

`--init-sync-up | -u` if set, `aws s3 sync <LocalPath> <S3Uri>` will be 
invoked when the script starts

`--poll | -p` frequency in seconds to check for both local and remote changes 
and trigger the necessary synchronization - default is 30.

## Dependencies
To avoid bloated container images and complex setup/configurations, this script 
intentionally utilizes minimal dependencies.

* [AWS Command Line Interface](https://aws.amazon.com/cli/) - this script 
uses `aws s3`, [`aws sqs`](https://docs.aws.amazon.com/cli/latest/reference/sqs/) 
and [`aws cloudfront`](https://docs.aws.amazon.com/cli/latest/reference/cloudfront/) 
(`sqs` and `cloudfront` are only utilized if the associated options are set). 
The AWS CLI must both be installed and supplied with the necessary credentials 
and [AWS IAM](https://aws.amazon.com/iam/) credentials/permissions required by 
these commands and the corresponding S3 storage bucket and SQS resources.

* [inotifywait](http://manpages.ubuntu.com/manpages/bionic/man1/inotifywait.1.html)
OPTIONAL - if installed, will be used to trigger `sync <LocalPath> <S3Uri>` 
events when local file system changes occur. More performant and efficient than 
the `md5sum` method below. Either `inotifywait` (preferred) OR `md5sum` must be 
present.

* [md5sum | md5](http://manpages.ubuntu.com/manpages/bionic/man1/md5sum.1.html) - 
If `inotifywait` is not present, the script will fallback to an 
[md5sum](https://en.wikipedia.org/wiki/Md5sum) method of determining when 
`<LocalPath>` changes have occurred.
