## ChangeLog for get_mysql_stats

## 2.6

  * Fix "Use of uninitialized value $time in numeric gt" error

## 2.5

  * Changed how checking for support of innodb is done

## 2.4

  * Changed the checking of the innodb version
  * Update innodb checks for MySQL 5.5

## 2.3

  * Added status variable to allow checking if the innodb processing completed
  * Moved several innodb calculations inside of check for innodb
  * Added status variable for innodb dirty page percentage  

## 2.2

  * Added --long-query-time option
  * Added support for counting the number of thread running longer than long-query-time
  * Updated documentation for options that can be negated

## 2.1

  * Made table_open_cache backwards-compatible
  * Calculate key buffer used
  * Calculate key buffer unflushed
  * Added precautionary check for Pages read ahead so that it doesn't get caught 
    by Pages read

## 2.0
 
  * Changed the cache file name to include the port if not 3306
  * Added --socket for support for socket connections
  * Added --port option
  * Added --cache-dir option
  * Added --poll-time option
  * Added --debug option
  * Added --check-general  
  * Added --check-innodb
  * Added --check-master
  * Added --check-slave
  * Added --check-procs
  * Added --heartbeat
  * Changed --nocache to support --no-cache and --cache as well
  * Changed option --pass to --password
  * Cleaned up options code
  * Changed to only create lock file if using caching
  * Added option --config-file for support for config file
  * Modified buffer pool calculations
  * Added extra checking around file locks
  * Changed error and debug printing and handling
  * Fixed problems with innodb statuses
  * Code cleanup
  
## 1.2
 
  * Added Thread Cache hitrate, Key Cache hitrate, InnoDB Buffer pool hitrate 
  * Added Handler Keyed row reads, Handler Unkeyed row reads
  * Added InnoDB Buffer Pool Usage, InnoDB Buffer Pool Modified
  * Changed calculation of cache timout

## 1.1 

  * Fixed the handling of the lock files
  
## 1.0 

  * Initial Release