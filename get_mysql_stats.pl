#!/usr/bin/perl

# ============================================================================
# This is a script to retrieve information from a mysql server for input into
# a zabbix monitored system. Based off of the ss_get_mysql_stats.php program
# developed by Baron Schwartz for use with Cacti graphing process.
#
# Adapted by: Joe Grasse
#
# THIS PROGRAM IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
# MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, version 2.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc., 59 Temple
# Place, Suite 330, Boston, MA  02111-1307  USA.
# ============================================================================

my $mysql_user = "";
my $mysql_password = "";
my $debug = 0;            # Turn on/off debug output
my $cache_dir  = '/tmp';  # Set dir for cache file
my $poll_time  = 30;      # Adjust to match your polling interval.
my %chk_options = (
  'general' => 1,         # Do you want to check the General server statistics?
  'innodb'  => 0,         # Do you want to check InnoDB statistics?
  'master'  => 0,         # Do you want to check binary logging?
  'slave'   => 0,         # Do you want to check slave status?
  'procs'   => 0          # Do you want to check SHOW PROCESSLIST?
);

# ============================================================================
# You should not need to change anything below this line.
# ============================================================================

use strict;
use warnings;
use Getopt::Long;
use Fcntl qw(:flock);
use DBI;
use Math::BigInt;

my $program_name = $0;
my $version_num = "2.5";
my %options;
my %status;
my %engines;

my $LOG_DEBUG = 1;
my $LOG_WARNING = 2;
my $LOG_ERR = 3;

my $cache_file;
my $lock_file;

my $exit_code = 0;

sub version{
  my $length = length($program_name);
  my $position = rindex($program_name, '/') + 1;
  
  print substr($program_name, $position, $length)." $version_num\n";
  exit 0
}

sub usage{
$exit_code = $_[0];

my $default_general = $chk_options{'general'} ? 'Yes' : 'No';
my $default_innodb = $chk_options{'innodb'} ? 'Yes' : 'No';
my $default_master = $chk_options{'master'} ? 'Yes' : 'No';
my $default_slave = $chk_options{'slave'} ? 'Yes' : 'No';
my $default_procs = $chk_options{'procs'} ? 'Yes' : 'No';

my $txt = <<END;
Usage: $program_name --host hostname --items item1,item2... [options]

  --host              Hostname to connect to; You can use host:port syntax to specify a port.
  --items             Comma-separated list of the items whose data you want.
  --user              MySQL username; defaults to \$mysql_user if not given.
  --password          MySQL password; defaults to \$mysql_password if not given.
  --socket            MySQL socket.
  --port              MySQL port
  --cache-dir         Directory for cache file; defaults to \$cache_dir if not given
  --cache             Store stats in cache file. Default
  --no-cache          Do not cache results in a file.
  --config-file       Configuration file.
  --poll-time         Used to determine if cache file is expired; defaults to \$poll_time
  --heartbeat         MySQL heartbeat table to track slave lag. Format: db.table
                      Example create table statement:

                       CREATE TABLE heartbeat (
                         id int NOT NULL PRIMARY KEY,
                         ts datetime NOT NULL
                       );
                   
                      The heartbeat table requires at least one row. You can insert a row by 
                      doing:
                   
                      INSERT INTO heartbeat (id,ts) VALUES (1,NOW());
  
  --[no]check-general Check the general statistics. Required by some of the other options. 
                        Default: $default_general
  --[no]check-innodb  Check innodb statistics. Enables check-general. Default: $default_innodb
  --[no]check-master  Check binary logging. Enables check-general. Default: $default_master
  --[no]check-slave   Check slave status. Default: $default_slave
  --[no]check-procs   Check processlist. Default: $default_procs
  --long-query-time   If a query runs longer than this many seconds, it is counted in the
                        long_queries status variable.
  --debug             Display debug ouput
  --version           Version information.

END

print $txt;
exit($exit_code);
}

sub hms{
  my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
  return sprintf("%02d:%02d:%02d", $hour, $min, $sec);
}

sub ymd
{
  my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
  return sprintf("%04d%02d%02d", $year+1900, $mon+1, $mday);
}

sub timestamp { return ymd() . " " . hms(); }

sub _print_msg{
  my $log_level = pop;
  my @messages = @_;
  
  my $msg_txt = timestamp();

  if($log_level eq $LOG_DEBUG){
    $msg_txt = $msg_txt . " Debug: ";
  }
  elsif ($log_level eq $LOG_WARNING){
    $msg_txt = $msg_txt . " Warning: ";
  } 
  elsif ($log_level eq $LOG_ERR){
    $msg_txt = $msg_txt . " Error: ";
  }

  foreach my $msg (@messages){
    print $msg_txt . $msg . "\n";
  }
}

sub log_msg{
  my $log_level = pop;
  my @msg = @_;
  
  # Print debug messages only if in debug mode
  return if (! $options{'debug'}) and ($log_level eq $LOG_DEBUG);
  
  _print_msg(@msg, $log_level);
  
  # Abort if log level is error
  if($log_level eq $LOG_ERR){
    exit(1);
  }
}

sub get_args{
	my $ret = GetOptions( \%options,
		"host=s",
		"items=s@",
		"user=s",
		"password=s",
		"socket=s",
		"port=i",
		"cache-dir=s",
		"cache!",
		"config-file=s",
		"poll-time=i",
		"heartbeat=s",
		"check-general!",
		"check-innodb!",
		"check-master!",
		"check-slave!",
		"check-procs!",
		"long-query-time=i",
		"debug!",
		"help",
		"version"
  );
  
  unless( $ret ){
    usage(1);
  }
  
  if( $options{'help'}){
    usage(0);
  }
  
  if( $options{'version'}){
    version();
  }
}

sub validate_options{
  if( !$options{'host'} ){
    print "Required option --host is missing\n";
    usage(1);
  }
  elsif($options{'host'} =~ /:/){
    ($options{'host'},$options{'port'}) = split(/:/,$options{'host'});
  }
  
  if( !$options{'items'} ){
    print "Required option --items is missing\n";
    usage(1);
  }
  else{
    @{$options{'items'}} = split(/,/,join(',',@{$options{'items'}})); # allows format --items item1,item2 or --items item1 --items item2
  }
  
  if(defined($options{'heartbeat'}) && !($options{'heartbeat'} =~ /.+\..+/)){
      print "Invalid format for option --heartbeat\n";
      usage(1);
  }
  
  # set values to defaults if not already set
  $options{'user'} = $mysql_user unless defined($options{'user'});
  $options{'password'} = $mysql_password unless defined($options{'password'});
  $options{'cache'} = 1 unless defined($options{'cache'});
  $options{'cache-dir'} = '/tmp' unless defined($options{'cache-dir'});
  $options{'poll-time'} = $poll_time unless defined($options{'poll-time'});
  $options{'check-general'} = $chk_options{'general'} unless defined($options{'check-general'});
  $options{'check-innodb'} = $chk_options{'innodb'} unless defined($options{'check-innodb'});
  $options{'check-master'} = $chk_options{'master'} unless defined($options{'check-master'});
  $options{'check-slave'} = $chk_options{'slave'} unless defined($options{'check-slave'});
  $options{'check-procs'} = $chk_options{'procs'} unless defined($options{'check-procs'});
  $options{'debug'} = $debug unless defined($options{'debug'});
  
  if(($options{'check-innodb'} || $options{'check-master'}) && !$options{'check-general'}){
    $options{'check-general'} = 1;
  }
}

sub parse_config_file{
  if($options{'config-file'}){
    my $items_started_empty = 0;
    if (!open (CONFIG, "<$options{'config-file'}")){
      log_msg("Can not open $options{'config-file'}: $!", $LOG_ERR);
    }
    
    log_msg("Parsing configuration file ".$options{'config-file'},$LOG_DEBUG);
    
    while(<CONFIG>){
      chomp;
      s/#.*//;
      s/^\s*//;
      s/\s*$//;
      
      next unless length;
      
      my ($var, $value) = split(/\s*=\s*/, $_, 2);

      if((!defined($options{$var}) || $options{$var} eq "" || ($items_started_empty && $var eq "items"))){
        # config option is an item add to the items array 
        if($var eq "items"){
          push(@{$options{$var}},$value);
          $items_started_empty = 1;
        }
        # config option can be turned on or off
        elsif(
          $var =~ /^(no-?|)check-general$/ 
          || $var =~ /^(no-?|)check-innodb$/ 
          || $var =~ /^(no-?|)check-master$/ 
          || $var =~ /^(no-?|)check-slave$/ 
          || $var =~ /^(no-?|)check-procs$/ 
          || $var =~ /^(no-?|)debug$/ 
          || $var =~ /^(no-?|)cache$/
        ){
          # value is not defined so figure out what it needs to be
          if(!defined($value)){
            if($var =~ /^no./){
              $var =~ s/^no-?//;
              $value = 0;
            }
            else{
              $value = 1;
            }
          }
          $options{$var} = $value;
        }
        else{
          $options{$var} = $value;
        }
      }
    }
    
    close(CONFIG);
  }
}

sub get_data{
  my $sth;
  my $hash_ref;
  my @innodb_version_array = (0,0,0);
  my $ex_locked = 0;
  my %status = ('mysql_alive' => 0);

  my $base_file = $options{'cache-dir'}.((substr($options{'cache-dir'},-1,1) eq "/" ) ? "" : "/").$options{host};
  
  if(defined($options{'port'})){
    if($options{'port'} ne "3306"){
      $base_file .= "-".$options{'port'};
    }
  }
  elsif(defined($options{'socket'})){
    my $socket = $options{'socket'};
    $socket =~ s/\//_/g;
    $base_file .= "-".$socket;
  }
  
  $base_file .= "-mysql_cache_stats";  
  
  $cache_file = $base_file.".txt";
  $lock_file = $base_file.".lock";

  # First, check the cache.
  if($options{'cache'}){
    log_msg("Cache file is ".$cache_file,$LOG_DEBUG);
    # open a shared lock
    if(open(LOCK, ">$lock_file")){
      if(flock LOCK, LOCK_SH){
        # Check that the file exists and is non-zero in size and that it is still a valid cache file
        if( (-e $cache_file) && (-s $cache_file) > 0 && (stat(_))[10] + ($options{'poll-time'} * .9) > time ){
          log_msg("Using cache file.",$LOG_DEBUG);
          # The file is fresh enough to use.
          if(open(CACHE_FILE, $cache_file)){
            my @arr = <CACHE_FILE>;
            close(CACHE_FILE);
  
            if(@arr > 0){
              return join("",@arr);
            }
          }
          else{
            log_msg("Failed to open cache file: $!", $LOG_WARNING);
          }
        }
        log_msg("Cache file is to small or stale.",$LOG_DEBUG);
    
        # close shared lock
        close LOCK;
      }
      else{
        log_msg("Failed to get shared lock: $!", $LOG_WARNING);
      }
    }
    else{
      log_msg("Failed to open lock file for shared lock: $!", $LOG_WARNING);
    }

    # open an exclusive lock
    if(open(LOCK, ">$lock_file")){
      if(flock LOCK, LOCK_EX){
        $ex_locked = 1;
      }
      else{
        log_msg("Failed to get exclusive lock: $!", $LOG_WARNING);
      }
    }
    else{
      log_msg("Failed to open lock file for exclusive lock: $!", $LOG_WARNING);
    }
  }  
  
  my $dsn = "DBI:mysql:host=".$options{'host'};
  
  if($options{'port'}){
    $dsn .= ";port=".$options{'port'};
  }
  elsif($options{'socket'}){
    $dsn .= ";mysql_socket=".$options{'socket'};
  }
  
  my %attr = (
		PrintError => 0,
		RaiseError => 0
	);

  log_msg("Connecting to mysql with DSN ".$dsn,$LOG_DEBUG);
	my $dbh = DBI->connect($dsn, $options{'user'}, $options{'password'}, \%attr) or log_msg("Failed connection to MySQL: ". $DBI::errstr, $LOG_ERR);
  
  $status{'mysql_alive'} = 1;
  
  if($options{'check-general'}){
    # Get SHOW STATUS and convert the name-value array into a simple
    # associative array.
    log_msg("Get server status variables",$LOG_DEBUG);
    $sth = $dbh->prepare("SHOW /*!50002 GLOBAL */ STATUS");
    if(!$sth->execute){
      log_msg("Failed SHOW /*!50002 GLOBAL */ STATUS with: ".$sth->errstr,$LOG_ERR);
    }
    while(my $ref = $sth->fetchrow_arrayref){
      $status{lc($ref->[0])} = $ref->[1];
    }
    
    # Calculate keyed reads
    $status{'handler_read_keyed'} = $status{'handler_read_first'} + $status{'handler_read_key'} + $status{'handler_read_next'} + $status{'handler_read_prev'};
  
    # Calculate unkeyed reads
    $status{'handler_read_unkeyed'} = $status{'handler_read_rnd'} + $status{'handler_read_rnd_next'};
    
    # Calculate queries per second
    if($status{'questions'} && $status{'uptime'}){
      $status{'queries_per_second'} = sprintf("%.3f", ($status{'questions'} / $status{'uptime'})); 
    }
    
    # Calculate the Thread cache hitrate
    if($status{'connections'} > 0){
      $status{'hitrate_thread_cache'} = sprintf("%.3f",(100 - (($status{'threads_created'} / $status{'connections'}) * 100)));
    }
    
    # Calculate the Key Cache hitrate
    if($status{'key_read_requests'} > 0){
      $status{'hitrate_key_cache'} = sprintf("%.3f",(100 - (($status{'key_reads'} / $status{'key_read_requests'}) * 100)));
    }
    
    # Calculate the InnoDB Buffer pool hitrate
    if(defined($status{'innodb_buffer_pool_read_requests'}) && $status{'innodb_buffer_pool_read_requests'} > 0){
      $status{'hitrate_buffer_pool'} = sprintf("%.3f",(100 - (($status{'innodb_buffer_pool_reads'} / $status{'innodb_buffer_pool_read_requests'}) * 100)));
    }
    
    # Calculate the Temp table hitrate
    if($status{'created_tmp_tables'} + $status{'created_tmp_disk_tables'} > 0){
      $status{'hitrate_temp_tables'} = sprintf("%.3f",(100 - (($status{'created_tmp_disk_tables'} / ($status{'created_tmp_tables'} + $status{'created_tmp_disk_tables'})) * 100)));
    }
    
    # Get SHOW VARIABLES and convert the name-value array into a simple
    # associative array.
    log_msg("Get server variables",$LOG_DEBUG);
    $sth = $dbh->prepare("SHOW VARIABLES");
    if(!$sth->execute){
      log_msg("Failed SHOW VARIABLES with: ".$sth->errstr,$LOG_ERR);
    }
    while(my $ref = $sth->fetchrow_arrayref){
      $status{lc($ref->[0])} = $ref->[1];
    }
    
    # Make table_open_cache backwards-compatible with table_cache
    if($status{'table_open_cache'}){
      $status{'table_cache'} = $status{'table_open_cache'};
    }
    
    # Setup new key buffer variables
    %status = (
      %status,
      'key_buffer_bytes_used'      => Math::BigInt->new($status{'key_buffer_size'}),
      'key_buffer_bytes_unflushed' => Math::BigInt->new($status{'key_blocks_not_flushed'}),
    );
    
    # Calculate how much of the key buffer is used
    my $key_buf_unused = Math::BigInt->new($status{'key_blocks_unused'});
    $key_buf_unused->bmul($status{'key_cache_block_size'});
    $status{'key_buffer_bytes_used'}->bsub($key_buf_unused);
    
    # Calculate how much of the key buffer is unflushed
    $status{'key_buffer_bytes_unflushed'}->bmul($status{'key_cache_block_size'});    
    
    # Get SHOW ENGINES associative array.
    log_msg("Get engines",$LOG_DEBUG);
    $sth = $dbh->prepare("SHOW ENGINES");
    if(!$sth->execute){
      log_msg("Failed SHOW ENGINES with: ".$sth->errstr,$LOG_ERR);
    }
    while(my $ref = $sth->fetchrow_arrayref){
      $engines{lc($ref->[0])} = $ref->[1];
    }
  }
  
  # Get SHOW SLAVE STATUS.
  if($options{'check-slave'}){
    log_msg("Get server slave status",$LOG_DEBUG);
    $hash_ref = $dbh->selectrow_hashref("SHOW SLAVE STATUS");
    if($hash_ref){
      # Must lowercase keys because different versions have different
      # lettercase.
      $hash_ref = { map { lc($_) => $hash_ref->{$_} } keys %$hash_ref };
      
      $status{'relay_log_space'} = $hash_ref->{'relay_log_space'};
      $status{'slave_lag'}       = ($hash_ref->{'seconds_behind_master'}) ? $hash_ref->{'seconds_behind_master'} : 0;
      
      if(defined($options{'heartbeat'})){
        log_msg("Getting slave lag from heartbeat table",$LOG_DEBUG);
        
        my ($heartbeat_db,$heartbeat_tb) = split(/\./,$options{'heartbeat'});
        
        my @array = $dbh->selectrow_array("SELECT GREATEST(0,UNIX_TIMESTAMP() - UNIX_TIMESTAMP(ts) - 1) AS slave_lag FROM `$heartbeat_db`.`$heartbeat_tb` WHERE id = 1");
        if(@array){
          $status{'slave_lag'} = $array[0];
        }
        else{
          log_msg("Failed to get slave lag from ".$options{'heartbeat'}.(($dbh->errstr) ? " with: ".$dbh->errstr : ''),$LOG_WARNING);
        }
      }
      
      $status{'slave_error'} = ($hash_ref->{'last_error'}) ? $hash_ref->{'last_error'} : 'No Error';

      $status{'slave_sql_running'} = ($hash_ref->{'slave_sql_running'} eq 'Yes') ? 1 : 0;
      $status{'slave_io_running'} = ($hash_ref->{'slave_io_running'} eq 'Yes') ? 1 : 0;
    }
    elsif($dbh->errstr){
      log_msg("Failed SHOW SLAVE STATUS with: ". $dbh->errstr, $LOG_ERR);
    }
  }
  
  # Get info on master logs.
  if($options{'check-master'} && defined($status{'log_bin'}) && $status{'log_bin'} eq 'ON'){
    log_msg("Get server log status",$LOG_DEBUG);
    $sth = $dbh->prepare("SHOW MASTER LOGS");
    if(!$sth->execute){
      log_msg("Failed SHOW MASTER LOGS with: ".$sth->errstr,$LOG_ERR);
    }
    
    $status{'binary_log_space'} = Math::BigInt->new();
    
    while(my $hash_ref = $sth->fetchrow_hashref){
      # lowercase keys
      $hash_ref = { map { lc($_) => $hash_ref->{$_} } keys %$hash_ref};
      # Older versions of MySQL may not have the File_size column in the
      # results of the command.  Zero-size files indicate the user is
      # deleting binlogs manually from disk (bad user! bad!) but we should
      # not croak with a thread-stack error just because of the bad user.
      if ( $hash_ref->{'file_size'} && $hash_ref->{'file_size'} > 0 ){
        $status{'binary_log_space'}->badd($hash_ref->{'file_size'});
      }
      else {
        $sth->finish;
        last;
      }
    }
  }

  # Get SHOW PROCESSLIST and aggregate it.
  if($options{'check-procs'}){
    log_msg("Get server process list",$LOG_DEBUG);
    $sth = $dbh->prepare("SHOW PROCESSLIST");
    if(!$sth->execute){
      log_msg("Failed SHOW PROCESSLIST with: ".$sth->errstr,$LOG_ERR);
    }
    
    # Values for the 'state' column from SHOW PROCESSLIST (converted to
    # lowercase, with spaces replaced by underscores)
    %status = (
      %status,
      'state_closing_tables'       => 0,
      'state_copying_to_tmp_table' => 0,
      'state_end'                  => 0,
      'state_freeing_items'        => 0,
      'state_init'                 => 0,
      'state_locked'               => 0,
      'state_login'                => 0,
      'state_preparing'            => 0,
      'state_reading_from_net'     => 0,
      'state_sending_data'         => 0,
      'state_sorting_result'       => 0,
      'state_statistics'           => 0,
      'state_updating'             => 0,
      'state_writing_to_net'       => 0,
      'state_none'                 => 0,
      'state_other'                => 0, # Everything not listed above
    );

    if($options{'long-query-time'}){
      $status{'long_queries'} = 0;
    }
    
    while(my $hash_ref = $sth->fetchrow_hashref){
      my $id = $hash_ref->{'Id'};
      my $user = $hash_ref->{'User'};
      my $host = $hash_ref->{'Host'};
      my $command = $hash_ref->{'Command'};
      my $time = $hash_ref->{'Time'};
      my $state = $hash_ref->{'State'};
      if ( ! $state ){
        $state = 'none';
      }
      elsif ( $state eq 'NULL' ){
        $state = 'null';
      }

      $state =~ s/\s/_/g;
      $state = lc($state);

      if (exists $status{"state_$state"}){
        $status{"state_$state"}++;
      }
      else {
        $status{"state_other"}++;
      }

      # Count the number of queries that have been running for longer than long-query-time
      # Don't include system and sleeping threads
      if($id != $dbh->{'mysql_thread_id'}                       # Current Thread
        && ($user ne "system user" && $host ne "")              # master replication threads
        && ($user ne "event_scheduler" && $command ne "Daemon") # event scheduler thread
        && $command ne "Binlog Dump"                            # connected slave client thread
        && $command ne "Sleep"                                  # inactive thread
        && $options{'long-query-time'}
        && $time > $options{'long-query-time'}
      )
      {
        $status{'long_queries'}++;
      }
      log_msg("Thread: [user: $user] [host: $host] [command: $command] [time: $time] [state: $state]",$LOG_DEBUG);
    }
  }
  
  # Get SHOW INNODB STATUS and extract the desired metrics from it.
  if($options{'check-innodb'} && ((defined($status{'have_innodb'}) && $status{'have_innodb'} eq 'YES') || (defined($engines{'innodb'}) && ($engines{'innodb'} eq 'YES' || $engines{'innodb'} eq 'DEFAULT')))){
    log_msg("Get server innodb status",$LOG_DEBUG);

    # Initialize some values
    %status = (
      %status,
      'innodb_spin_waits'           => Math::BigInt->new(),
      'innodb_spin_rounds'          => Math::BigInt->new(),
      'innodb_os_waits'             => Math::BigInt->new(),
      'innodb_transactions_current' => Math::BigInt->new(),
      'innodb_transactions_active'  => Math::BigInt->new(),
      'innodb_lock_wait_secs'       => Math::BigInt->new(),
      'innodb_transactions_locked'  => Math::BigInt->new(),
      'innodb_tables_in_use'        => Math::BigInt->new(),
      'innodb_locked_tables'        => Math::BigInt->new(),
      'innodb_lock_structs'         => Math::BigInt->new(),
      'innodb_processing_completed' => 0
    );

    if(!defined($status{'innodb_version'})){
      $status{'innodb_version'} = '0.0.0';
    }
    
    @innodb_version_array = split(/\./,$status{'innodb_version'});
    log_msg("Innodb Version: $status{'innodb_version'}", $LOG_DEBUG);

    my $innodb_prg = 0;
    my $found_merged_line = 0;

    $hash_ref = $dbh->selectrow_hashref("SHOW /*!50000 ENGINE*/ INNODB STATUS");
    if($hash_ref){
      foreach my $line (split(/\n/, $hash_ref->{'Status'})){        
        my @row = split(/\s/, $line);
        
        #log_msg($line,$LOG_DEBUG);

        # SEMAPHORES
        if(index($line, 'Mutex spin waits') == 0){  
          # Mutex spin waits 79626940, rounds 157459864, OS waits 698719
          # Mutex spin waits 0, rounds 247280272495, OS waits 316513438
          $status{'innodb_spin_waits'} = $status{'innodb_spin_waits'}->badd(to_num($row[3]));
          $status{'innodb_spin_rounds'} = $status{'innodb_spin_rounds'}->badd(to_num($row[5]));
          $status{'innodb_os_waits'} = $status{'innodb_os_waits'}->badd(to_num($row[8]));
        }
        elsif(index($line, 'RW-shared spins') == 0){
          # RW-shared spins 3859028, OS waits 2100750; RW-excl spins 4641946, OS waits 1530310 // Before version 1.1.2 of innodb
          # RW-shared spins 7, rounds 210, OS waits 7 // version 1.1.2 or greater of innodb
          if($innodb_version_array[0] == 0 || ($innodb_version_array[0] == 1 && $innodb_version_array[1] <= 0) || ($innodb_version_array[0] == 1 && $innodb_version_array[1] == 1 && $innodb_version_array[2] < 2)){
            $status{'innodb_spin_waits'} = $status{'innodb_spin_waits'}->badd(to_num($row[2]));
            $status{'innodb_spin_waits'} = $status{'innodb_spin_waits'}->badd(to_num($row[8]));
            $status{'innodb_os_waits'} = $status{'innodb_os_waits'}->badd(to_num($row[5]));
            $status{'innodb_os_waits'} = $status{'innodb_os_waits'}->badd(to_num($row[11]));
          }
          else{
            $status{'innodb_spin_waits'} = $status{'innodb_spin_waits'}->badd(to_num($row[2]));
            $status{'innodb_os_waits'} = $status{'innodb_os_waits'}->badd(to_num($row[7]));
          }
        }
        elsif(index($line, 'RW-excl spins') == 0){
          # RW-excl spins 0, rounds 0, OS waits 0 // version 1.1 or greater of innodb
          $status{'innodb_spin_waits'} = $status{'innodb_spin_waits'}->badd(to_num($row[2]));
          $status{'innodb_os_waits'} = $status{'innodb_os_waits'}->badd(to_num($row[7]));
        }

        # TRANSACTIONS
        elsif(index($line, 'Trx id counter') == 0){
          # The beginning of the TRANSACTIONS section: start counting
          # transactions
          # Trx id counter 0 1170664159 // normal
          # Trx id counter 861B144C     // version 1.0 or greater of innodb
          if($innodb_version_array[0] >= 1){
            $status{'innodb_transactions'} = Math::BigInt->new("0x".$row[3]);
          }
          else{
            $status{'innodb_transactions'} = make_bigint($row[3],$row[4]);
          }
        }
        elsif(index($line, 'Purge done for trx') == 0){
          # Purge done for trx's n:o < 0 1170663853 undo n:o < 0 0 // normal
          # Purge done for trx's n:o < 861B135D undo n:o < 0       // version 1.0 or greater of innodb
          if($innodb_version_array[0] >= 1){
            $innodb_prg = Math::BigInt->new("0x".$row[6]);
          }
          else{
            $innodb_prg = make_bigint($row[6],$row[7]);
          }
        }
        elsif(index($line, 'History list length') == 0){
          # History list length 132
          $status{'innodb_history_list'} = to_num($row[3]);
        }
        elsif( $status{'innodb_transactions'} && index($line, '---TRANSACTION') == 0){
          # ---TRANSACTION 0 2069064737, not started, process no 2589, OS thread id 1161386304 // normal
          # ---TRANSACTION 0, not started, process no 13510, OS thread id 1170446656           // version 1.0
          # ---TRANSACTION 106C2F, not started                                                 // version 1.1 or greater of innodb
          $status{'innodb_transactions_current'}->binc();
          if(index($line, 'ACTIVE') > -1 ){
            $status{'innodb_transactions_active'}->binc();
          }
        }
        elsif(index($line, '------- TRX HAS BEEN') == 0){
          # ------- TRX HAS BEEN WAITING 32 SEC FOR THIS LOCK TO BE GRANTED:
          $status{'innodb_lock_wait_secs'}->badd(to_num($row[5]));
        }
        elsif($status{'innodb_transactions'} && index($line, 'LOCK WAIT') == 0){
          # LOCK WAIT 2 lock struct(s), heap size 368
          $status{'innodb_transactions_locked'}->binc();
        }
        elsif(index($line, 'read views open inside') > -1){
          # 1 read views open inside InnoDB
          $status{'innodb_read_views'} = to_num($row[0]);
        }
        elsif(index($line, 'mysql tables in use') == 0){
          # mysql tables in use 2, locked 2
          $status{'innodb_tables_in_use'}->badd(to_num($row[4]));
          $status{'innodb_locked_tables'}->badd(to_num($row[6]));
        }
        elsif(index($line, 'lock struct(s)') > -1){
          # 23 lock struct(s), heap size 3024, undo log entries 27
          $status{'innodb_lock_structs'}->badd(to_num($row[0]));
        }

        # FILE I/O
        elsif(index($line, 'OS file reads') > -1){
          # 8782182 OS file reads, 15635445 OS file writes, 947800 OS fsyncs
          if(!defined($status{'innodb_data_reads'})){
            $status{'innodb_data_reads'}  = to_num($row[0]);
          }
          if(!defined($status{'innodb_data_writes'})){
            $status{'innodb_data_writes'} = to_num($row[4]);
          }
          if(!defined($status{'innodb_data_fsyncs'})){
            $status{'innodb_data_fsyncs'} = to_num($row[8]);
          }
        }
        elsif(index($line, 'Pending normal aio') == 0){
          # Pending normal aio reads: 0, aio writes: 0,
          # Pending normal aio reads: 0 [0, 0, 0, 0, 0, 0, 0, 0] , aio writes: 0 [0, 0, 0, 0, 0, 0, 0, 0] , // version 1.1 or greater of innodb
          if(!defined($status{'innodb_data_pending_reads'})){
            $status{'innodb_data_pending_reads'}  = to_num($row[4]);
          }
          if(!defined($status{'innodb_data_pending_writes'})){
            if($innodb_version_array[0] == 0 || ($innodb_version_array[0] == 1 && $innodb_version_array[1] <= 0)){
              $status{'innodb_data_pending_writes'} = to_num($row[7]);
            }
            else{
              # Get the first number after "aio writes:"
              my @tmp_line = split('aio writes: ',"@row");
              my @tmp_aio_writes_array = split(' ',$tmp_line[1]);
              $status{'innodb_data_pending_writes'} = $tmp_aio_writes_array[0];
            }
          }
        }
        elsif(index($line, ' ibuf aio reads') == 0){
          #  ibuf aio reads: 0, log i/o's: 0, sync i/o's: 0 // note the space at the front
          $status{'innodb_insert_buffer_aio_pending_reads'} = to_num($row[4]);
          $status{'innodb_aio_log_pending_ios'}    = to_num($row[7]);
          $status{'innodb_aio_sync_pending_ios'}   = to_num($row[10]);
        }
        elsif(index($line, 'Pending flushes (fsync)') == 0){
          # Pending flushes (fsync) log: 0; buffer pool: 0
          if(!defined($status{'innodb_os_log_pending_fsyncs'})){
            $status{'innodb_os_log_pending_fsyncs'} = to_num($row[4]);
          }
          $status{'innodb_buffer_pool_pending_fsync'} = to_num($row[7]);
        }

        # INSERT BUFFER AND ADAPTIVE HASH INDEX
        elsif(index($line, 'Ibuf for space 0: size ') == 0){
          # Older InnoDB code seemed to be ready for an ibuf per tablespace.  It
          # had two lines in the output.  Newer has just one line, see below.
          # Ibuf for space 0: size 1, free list len 887, seg size 889, is not empty
          # Ibuf for space 0: size 1, free list len 887, seg size 889,
          $status{'innodb_insert_buffer_cells_used'}  = to_num($row[5]);
          $status{'innodb_insert_buffer_cells_free'}  = to_num($row[9]);
          $status{'innodb_insert_buffer_cell_count'}  = to_num($row[12]);
        }
        elsif(index($line, 'Ibuf: size ') == 0){
          # Ibuf: size 1, free list len 4634, seg size 4636,
          # Ibuf: size 1, free list len 0, seg size 2, 21 merges // version 1.1 or greater of innodb
          $status{'innodb_insert_buffer_cells_used'}  = to_num($row[2]);
          $status{'innodb_insert_buffer_cells_free'}  = to_num($row[6]);
          $status{'innodb_insert_buffer_cell_count'}  = to_num($row[9]);
          if(defined($row[10])){
            $status{'innodb_insert_buffer_merges'}  = to_num($row[10]);
          }
        }
        # version 1.1 or greater of innodb
        # merged operations:
        #  insert 4, delete mark 37, delete 0
        # discarded operations:
        #  insert 0, delete mark 0, delete 0
        elsif(index($line, 'merged operations:') == 0){
          $found_merged_line = 1;
        }
        elsif($found_merged_line){
          if(index($line, ' insert ') == 0){
            #  insert 4, delete mark 37, delete 0
            $status{'innodb_insert_buffer_inserts'} = to_num($row[2]);
            $status{'innodb_insert_buffer_merged'} =  Math::BigInt->new(to_num($row[2]))->badd(to_num($row[5]))->badd(to_num($row[7]));
          }
          $found_merged_line = 0;
        }
        elsif(index($line, 'merged recs') > -1){
          # 19817685 inserts, 19817684 merged recs, 3552620 merges
          $status{'innodb_insert_buffer_inserts'} = to_num($row[0]);
          $status{'innodb_insert_buffer_merged'}  = to_num($row[2]);
          $status{'innodb_insert_buffer_merges'}  = to_num($row[5]);
        }
        elsif(index($line, 'Hash table size ') == 0){
          # In some versions of InnoDB, the used cells is omitted.
          # Hash table size 4425293, used cells 4229064, ....
          # Hash table size 57374437, node heap has 72964 buffer(s) <-- no used cells
          $status{'innodb_hash_index_cells_total'} = to_num($row[3]);
          $status{'innodb_hash_index_cells_used'}  = to_num($row[6]);
        }

        # LOG
        elsif(index($line, "log i/o's done") > -1){
          # 3430041 log i/o's done, 17.44 log i/o's/second
          $status{'innodb_log_io'} = to_num($row[0]);
        }
        elsif(index($line, "pending log writes") > -1){
          # 0 pending log writes, 0 pending chkp writes
          $status{'innodb_log_pending_writes'}  = to_num($row[0]);
          $status{'innodb_chkp_pending_writes'} = to_num($row[4]);
        }
        elsif(index($line, "Log sequence number") == 0){
          # Log sequence number 13093949495856 // version 1.0 or greater of innodb
          # Log sequence number 125 3934414864 // normal
          if($innodb_version_array[0] >= 1){
            $status{'innodb_log_bytes_written'} = $row[3];
          }
          else{
            $status{'innodb_log_bytes_written'} = make_bigint($row[3],$row[4]);
          }
        }
        elsif(index($line, "Log flushed up to") == 0){
          # Log flushed up to   13093948219327 // version 1.0 or greater of innodb
          # Log flushed up to   125 3934414864 // normal
          if($innodb_version_array[0] >= 1){
            $status{'innodb_log_bytes_flushed'} = $row[6];
          }
          else{
            $status{'innodb_log_bytes_flushed'} = make_bigint($row[6],$row[7]);
          }
        }
        elsif(index($line, "Last checkpoint at") == 0){
          # Last checkpoint at  61591          // version 1.0 or greater of innodb
          # Last checkpoint at  125 3934293461 // normal
          if($innodb_version_array[0] >= 1){
            $status{'innodb_last_checkpoint'} = $row[4];
          }
          else{
            $status{'innodb_last_checkpoint'} = make_bigint($row[4],$row[5]);
          }
        }

        # BUFFER POOL AND MEMORY
        elsif(index($line, "Total memory allocated") == 0){
          # Total memory allocated 29642194944; in additional pool allocated 0
          $status{'innodb_total_mem_alloc'}       = to_num($row[3]);
          $status{'innodb_additional_mem_pool_alloc'} = to_num($row[8]);
        }
        elsif(index($line, "Buffer pool size ") == 0 && !defined($status{'innodb_buffer_pool_size'})){
          # Buffer pool size        1769471
          $status{'innodb_buffer_pool_size'} = to_num($row[5]) * 16384;
        }
        elsif(index($line, "Free buffers") == 0 && !defined($status{'innodb_buffer_pool_pages_free'})){
          # Free buffers            0
          $status{'innodb_buffer_pool_pages_free'} = to_num($row[8]);
        }
        elsif(index($line, "Database pages") == 0 && !defined($status{'innodb_buffer_pool_pages_data'})){
          # Database pages          1696503
          $status{'innodb_buffer_pool_pages_data'} = to_num($row[6]);
        }
        elsif(index($line, "Modified db pages") == 0 && !defined($status{'innodb_buffer_pool_pages_dirty'})){
          # Modified db pages       160602
          $status{'innodb_buffer_pool_pages_dirty'} = to_num($row[4]);
        }
        elsif(index($line, "Pages read ahead") == 0){
          # Must come before "Pages read"
          # Don't do anything for now
        }
        elsif(index($line, "Pages read") == 0){
          # Pages read 15240822, created 1770238, written 21705836
          if(!defined($status{'innodb_pages_read'})){
            $status{'innodb_pages_read'}    = to_num($row[2]);
          }
          if(!defined($status{'innodb_pages_created'})){
            $status{'innodb_pages_created'} = to_num($row[4]);
          }
          if(!defined($status{'innodb_pages_written'})){
            $status{'innodb_pages_written'} = to_num($row[6]);
          }
        }
        
        # ROW OPERATIONS
        elsif(index($line, 'Number of rows inserted') == 0){
          # Number of rows inserted 50678311, updated 66425915, deleted 20605903, read 454561562
          if(!defined($status{'innodb_rows_inserted'})){
            $status{'innodb_rows_inserted'} = to_num($row[4]);
          }
          if(!defined($status{'innodb_rows_updated'})){
            $status{'innodb_rows_updated'}  = to_num($row[6]);
          }
          if(!defined($status{'innodb_rows_deleted'})){
            $status{'innodb_rows_deleted'}  = to_num($row[8]);
          }
          if(!defined($status{'innodb_rows_read'})){
            $status{'innodb_rows_read'}     = to_num($row[10]);
          }
        }
        elsif(index($line, " queries inside InnoDB") > 0){
          # 0 queries inside InnoDB, 0 queries in queue
          $status{'innodb_queries_inside'} = to_num($row[0]);
          $status{'innodb_queries_queued'}  = to_num($row[4]);
        }
        elsif(index($line, 'END OF INNODB MONITOR OUTPUT') == 0){
          $status{'innodb_processing_completed'} = 1;
          log_msg("InnoDB processing Complete", $LOG_DEBUG);
          last;
        }        
      }
      
      if(defined($status{'innodb_transactions'})){
        $status{'innodb_transactions_unpurged'} = Math::BigInt->new($status{'innodb_transactions'})->bsub($innodb_prg);
      }
      
      if(defined($status{'innodb_log_bytes_written'}) && defined($status{'innodb_log_bytes_flushed'})){
        $status{'innodb_unflushed_log'} = Math::BigInt->new($status{'innodb_log_bytes_written'})->bsub($status{'innodb_log_bytes_flushed'});
        # TODO: I'm not sure what the deal is here; need to debug this.  But the
        # unflushed log bytes spikes a lot sometimes and it's impossible for it to
        # be more than the log buffer.
        #$status{'innodb_unflushed_log'} = max($status{'innodb_unflushed_log'}, $status{'innodb_log_buffer_size'});
      }
      
      if(defined($status{'innodb_log_bytes_written'}) && defined($status{'innodb_last_checkpoint'})){
        $status{'innodb_uncheckpointed_bytes'} = Math::BigInt->new($status{'innodb_log_bytes_written'})->bsub($status{'innodb_last_checkpoint'});
      }
    }
    else{
      log_msg("Failed SHOW /*!50000 ENGINE*/ INNODB STATUS with: ". $dbh->errstr, $LOG_ERR);
    }

    # InnoDB Buffer Pool
    # calculate amount of data
    if(defined($status{'innodb_buffer_pool_pages_data'})){
      $status{'innodb_buffer_pool_data'} = $status{'innodb_buffer_pool_pages_data'} * 16384;
    }
    # calculate amount free
    if(defined($status{'innodb_buffer_pool_pages_free'})){
      $status{'innodb_buffer_pool_free'} = $status{'innodb_buffer_pool_pages_free'} * 16384;
    }
    # calculate amount modified
    if(defined($status{'innodb_buffer_pool_pages_dirty'})){
      $status{'innodb_buffer_pool_modified'} = $status{'innodb_buffer_pool_pages_dirty'} * 16384;
    }
    # calculate dirty page percent
    if(defined($status{'innodb_buffer_pool_pages_dirty'}) && defined($status{'innodb_buffer_pool_pages_data'}) && defined($status{'innodb_buffer_pool_pages_free'})){
      $status{'innodb_dirty_pages_pct'} = sprintf("%.1f", (100 * $status{'innodb_buffer_pool_pages_dirty'})/(1 + $status{'innodb_buffer_pool_pages_data'} + $status{'innodb_buffer_pool_pages_free'}));
    }
  }
  
  my @output;
  while(my ($key, $value) = each(%status)){
    push(@output, "$key:$value");
  }

  my $result = join("\n", @output);

  if($ex_locked){  
    if(open(CACHE_FILE, ">$cache_file")){
      print CACHE_FILE $result;
      
      close(CACHE_FILE);
    }
    else{
      log_msg("Failed to open cache file: $!", $LOG_WARNING);
    }
  }
  elsif($options{'cache'}){
    log_msg("Cache file not locked, not saving to cache", $LOG_WARNING);
  }

	$dbh->disconnect();
	
	# close exclusive lock
	if($ex_locked){
    close LOCK;
    $ex_locked = 0;
  }
	
	return $result;
}

sub make_bigint{
  my $hi = shift;
  my $low = shift;
  
  $hi = $hi ? $hi : 0;
  $low = $low ? $low : 0;
  
  return(Math::BigInt->new($hi)->blsft(32)->badd($low));
}

sub to_num{
  my $string = $_[0];

  if($string=~m/(\d*)/){
    $string=$1;
  }
  else{
    $string = 0;
  }

  return $string;
}

sub max{
  my $max = $_[0];
  
  for ( @_[ 1..$#_ ] ){
    $max = $_ if $_ > $max;
  }
  return $max;
}

sub in_array{
  my ($search_for,$arr) = @_;
  
  foreach my $value (@$arr){
    return 1 if $value eq $search_for;
  }
  return 0;
}

sub main{
  get_args();
  parse_config_file();
  validate_options();

  my $result = get_data();
  
  my @output;

  foreach my $item (split("\n", $result)){
    # get length of item identifier
    my $length = index($item, ':');

    if(in_array(substr($item, 0, $length), \@{$options{'items'}})){
      push(@output, $item);
    }
  }
  print(join("\n", @output)."\n");
}

main();

exit($exit_code);