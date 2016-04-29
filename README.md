dumprestore
===========

Dump &amp; restore scripts

Using dump and restore commands :
Pros.:
* official tool for ext2/3/4 file systems.
* dump can work on mounted file systems (recommend to be read-only).
* incremental dumps.
* restore entire file system or only files.
* can use SSH to upload dump files.

Cons.:
* only ext2/3/4 filesystems are supported.
* RHEL 5 dump program version does not support the ext4 file system.
