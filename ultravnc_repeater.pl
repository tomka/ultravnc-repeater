#!/usr/bin/perl
#
# Copyright (c) 2009-2011 by Karl J. Runge <runge@karlrunge.com>
#
# ultravnc_repeater.pl is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or (at
# your option) any later version.
# 
# ultravnc_repeater.pl is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with ultravnc_repeater.pl; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA
# or see <http://www.gnu.org/licenses/>.


# 2011-05-27: Modified by Karl Runge and Keith Willis <ratchunk@gmail.com>
#
#  Notes:
#  ------
#   1. This is a new release which has been significantly modified by Karl Runge.
#   2. In Refuse Mode the "Another user is already listening on this ID - Bad Connection" error will be displayed
#      if a new connection is being established on the same ID when the socket is still open.
#   3. Karl re-wrote this version using the environment variable array "$ENV" to store any command-line and CGI arguments whilst still retaining the original support for environment variables.
#      I have retained this more flexible approach and have also included initialisation for some environment variable default values.
#
#  Changes List:
#  -------------
#   1. Accept command line arguments instead of using environment variables
#   2. Added CGI support so that the script can be started from a HTTP request.
#      (Karl has noted some security issues with this approach and I also suggest only using this if you wish to write a web interface to the script)
#   3. Removed command-line looping argument from forked child processes to prevent them re-forking indefinitely and thus creating a "Fork Bomb"
#   4. Modified "established_linux_proc()" function to assume that if the Socket number is not found in the TCP dump then it is no longer connected.
#      This prevents the "Another user is already listening on this ID - Bad Connection" error appearing when the viewer session has been manually cancelled previously by the user.
#   5. Added "clean_connections()" function provided by Karl Runge to prevent unclosed file descriptors in a CLOSE_WAIT state if a VNC server disconnects without first having had a client connect.
#   6. Added a "validateEnv()" function to ensure that only valid argument values may be passed to the script.
#   7. Chained the Log and PID files to reside in the same folder as the script. This pretty much removes most of the security issues mentioned by Karl.
#   8. Log and PID files are forced to have only ".log" and ".pid" file extensions.
#   9. IP Address Logging has been added for both the client and server connections.
#  10. An explicit call to the Perl interpreter has been added to the "exec" command call when in looping mode. (Some system configurations required this.)
#
#  To Do:
#  ------
#   1. Add Daemon Process Kill functionality
#   2. Add Authentication
#   3. Add a way to query current connections
#   4. Provide a better technique for the "established()" function.
#   5. Add support for multiple clients to connect concurrently to the same server.
#
#  Examples of some Useful Bash Commands: (for recovery and debugging)
#  --------------------------------------
#   /home/user/public_html/cgi-bin/ultravnc_repeater.pl -L BG -r -C -c 5901 -s 5501 -l repeater.log -p repeater.pid
#   pgrep -l perl
#   ps -p 20748 -f
#   netstat -anp --tcp
#   netstat -anp --tcp | grep perl
#   pkill perl
#   pkill ultravnc_repeat
#   kill 20748 20754 20761 22750 22753 22754 22803 22806 22878 22879 23060 23062 23077 23080 23081 23097 23098

use strict;
use File::Basename;    # Provides support for "dirname()" function used when initialising default envirnoment values for $ENV{ULTRAVNC_REPEATER_PIDFILE} and $ENV{ULTRAVNC_REPEATER_LOGFILE}
use Cwd qw(abs_path);  # Provides support for "abs_path()" function used when initialising default envirnoment values for $ENV{ULTRAVNC_REPEATER_PIDFILE} and $ENV{ULTRAVNC_REPEATER_LOGFILE}

# Default Parameters Values
my $usage = '
ultravnc_repeater.pl: (version 2.2)
          perl script implementing the ultravnc repeater
          proxy protocol.

protocol: Listen on one port for vnc clients (default 5900.)
          Listen on one port for vnc servers (default 5500.)
          Read 250 bytes from connecting vnc client or server.
          Accept ID:<string> from clients and servers, connect them
          together once both are present.

          The string "RFB 000.000\n" is sent to the client (the client
          must understand this means send ID:... or host:port.)

          Also accept <host>:<port> from clients and make the
          connection to the vnc server immediately. 

          Note there is no authentication or security WRT ID names or
          identities; it is up to the client and server to completely
          manage that aspect and whether to encrypt the subsequent VNC
          session, etc.

Usage:  ultravnc_repeater.pl [-h] [-r] [-C 0|1] [-R 0|1] [-L 1|BG]  [-b repeater_buffer_size] [-c client_port] [-s server_port] [-l ULTRAVNC_REPEATER_LOGFILE] [-p ULTRAVNC_REPEATER_PIDFILE]

Set "-h" to view this help documentation.

Use -r or set the env. var. ULTRAVNC_REPEATER_REFUSE to refuse new server/client connections when there is an existing server/client ID.
The default is to close the previous one.

Use -C or set the env. var. ULTRAVNC_REPEATER_CLEAN to specify whether to have the script periodically check for and close initial connections that have gone away before the partner connects (currently only works on Linux.)

Use -R or set the env. var. ULTRAVNC_REPEATER_NO_RFB to disable sending "RFB 000.000" to the client.
Then this program acts as general TCP rendezvous tool.
The default is to send.

Use -L or set the env. var. ULTRAVNC_REPEATER_LOOP to run an outer loop restarting the server if it exits.
The -L BG mode forks into the background, (i.e. running as a daemon).
This is undefined by default, (i.e. no looping).

Use "-b" or set the env. var. ULTRAVNC_REPEATER_BUFSIZE to modify the ultravnc proxy handshake buffer size for your own special application.
Default Value = 250 (bytes).

Use "-c" or set the env. var. ULTRAVNC_REPEATER_CLIENT_PORT to set the Client Port.
The default is 5901.

Use "-s" or set the env. var. ULTRAVNC_REPEATER_SERVER_PORT to set the Server Port.
The default is 5501.

Use -l to set the logfile (or set the ULTRAVNC_REPEATER_LOGFILE env. var.)
e.g. "-l repeater.log"

Use -p to set a file to store the master pid in for your own tracking (same as ULTRAVNC_REPEATER_PIDFILE).
For example, a cronjob may supply a -p pidfile and check if the process id stored in the file is still running before deciding to run this script.

Examples:
---------
 env ULTRAVNC_REPEATER_LOOP=BG ULTRAVNC_REPEATER_LOGFILE=u.log ultravnc_repeater.pl ...
 ultravnc_repeater.pl -L BG -l u.log  ...
    
    ultravnc_repeater.pl
    ultravnc_repeater.pl -r
    ultravnc_repeater.pl -C 1
    ultravnc_repeater.pl -R 1
    ultravnc_repeater.pl -L 1
    ultravnc_repeater.pl -L BG
    ultravnc_repeater.pl -b 250
    ultravnc_repeater.pl -c 5901
    ultravnc_repeater.pl -s 5501
    ultravnc_repeater.pl -c 5901 -s 5501
    ultravnc_repeater.pl -l repeater.log
    ultravnc_repeater.pl -p pid.log
    ultravnc_repeater.pl -l repeater.log -p pid.log
    ultravnc_repeater.pl -l repeater.log -p pid.log -r -c 5901 -s 5500 -L BG -R 1
    ultravnc_repeater.pl -r -C -R 1 -L BG -b 250 -c 5901 -s 5501 -l repeater.log -p repeater.pid

Note: The corresponding environment variables will be set from the command-line arguments and also from the default values.
';

if (@ARGV && $ARGV[0] =~ /-h/) 
{
 print $usage;
 exit 0;
}

# Set default environment variable values
if (!exists $ENV{ULTRAVNC_REPEATER_CLEAN}) {$ENV{ULTRAVNC_REPEATER_CLEAN} = '1';}
if (!exists $ENV{ULTRAVNC_REPEATER_LOGFILE}) {$ENV{ULTRAVNC_REPEATER_LOGFILE} = 'repeater.log';}  # Note: abs_path($0) = /home/user/public_html/cgi-bin/ultravnc_repeater.pl
if (!exists $ENV{ULTRAVNC_REPEATER_NO_RFB}) {$ENV{ULTRAVNC_REPEATER_NO_RFB} = '';}
if (!exists $ENV{ULTRAVNC_REPEATER_BUFSIZE}) {$ENV{ULTRAVNC_REPEATER_BUFSIZE} = '250';}
if (!exists $ENV{ULTRAVNC_REPEATER_REFUSE}) {$ENV{ULTRAVNC_REPEATER_REFUSE} = '';}
if (!exists $ENV{ULTRAVNC_REPEATER_CLIENT_PORT}) {$ENV{ULTRAVNC_REPEATER_CLIENT_PORT} = '5900';}
if (!exists $ENV{ULTRAVNC_REPEATER_SERVER_PORT}) {$ENV{ULTRAVNC_REPEATER_SERVER_PORT} = '5500';}

# my $client_port0 = 5900;
# my $server_port0 = 5500;

check_cgi();

# Read any command-line arguments into environment variable array
while (@ARGV) 
{
 if ($ARGV[0] =~ /^-*(ULTRAVNC_REPEATER_\w+)=(.+)/) {$ENV{$1} = $2; shift;}
 elsif ($ARGV[0] eq '-l') {shift; $ENV{ULTRAVNC_REPEATER_LOGFILE} = shift;}
 elsif ($ARGV[0] eq '-p') {shift; $ENV{ULTRAVNC_REPEATER_PIDFILE} = shift;}
 elsif ($ARGV[0] eq '-c') {shift; $ENV{ULTRAVNC_REPEATER_CLIENT_PORT} = shift;}
 elsif ($ARGV[0] eq '-s') {shift; $ENV{ULTRAVNC_REPEATER_SERVER_PORT} = shift;}
 elsif ($ARGV[0] eq '-b') {shift; $ENV{ULTRAVNC_REPEATER_BUFSIZE} = shift;}
 elsif ($ARGV[0] eq '-L') 
 {
  shift;
  if (@ARGV && $ARGV[0] =~ /^(1|0|BG)$/) {$ENV{ULTRAVNC_REPEATER_LOOP} = shift;} 
  else {$ENV{ULTRAVNC_REPEATER_LOOP} = '1';}
 } 
 elsif ($ARGV[0] eq '-R') 
 {
  shift;
  if (@ARGV && $ARGV[0] =~ /^(1|0)$/) {$ENV{ULTRAVNC_REPEATER_NO_RFB} = shift;} 
  else {$ENV{ULTRAVNC_REPEATER_NO_RFB} = '1';}
 }
 elsif ($ARGV[0] eq '-C') 
 {
  shift;
  if (@ARGV && $ARGV[0] =~ /^(1|0)$/) {$ENV{ULTRAVNC_REPEATER_CLEAN} = shift;}
  else {$ENV{ULTRAVNC_REPEATER_CLEAN} = '1';}
 }
 elsif ($ARGV[0] eq '-r') 
 {
  shift;
  if (@ARGV && $ARGV[0] =~ /^(1|0)$/) {$ENV{ULTRAVNC_REPEATER_REFUSE} = shift;}
  else {$ENV{ULTRAVNC_REPEATER_REFUSE} = '0';}
 }
 else {last;}
}

# Validate the arguments
validateEnv();

# Set up logging:
#
if (exists $ENV{ULTRAVNC_REPEATER_LOGFILE}) 
{
 my $lf = dirname(abs_path($0)) . '/' . $ENV{ULTRAVNC_REPEATER_LOGFILE};
 
 close STDOUT;
 if (!open(STDOUT, ">>$lf")) {die "ultravnc_repeater.pl: $lf $!\n";}
 close STDERR;
 open(STDERR, ">&STDOUT");
}
select(STDERR); $| = 1;
select(STDOUT); $| = 1;

# interrupt handler:
#
my $looppid = '';
my $pidfile = '';
#
sub get_out 
{
 lprint("$_[0]:\t$$ looppid=$looppid");
 if ($looppid) 
 {
  kill 'TERM', $looppid;
  fsleep(0.2);
 }
 unlink $pidfile if $pidfile;
 cleanup();
 exit 0;
}

# logging printer:
#
sub lprint 
{
 print STDERR scalar(localtime), ": ", @_, "\n";
}

# These are overridden in actual server thread:
#
$SIG{INT}  = \&get_out;
$SIG{TERM} = \&get_out;

# pidfile:
#
sub open_pidfile 
{
 if (exists $ENV{ULTRAVNC_REPEATER_PIDFILE}) 
 {
  my $pf = dirname(abs_path($0)) . '/' . $ENV{ULTRAVNC_REPEATER_PIDFILE};
  
  if (open(PID, ">$pf")) 
  {
   print PID "$$\n";
   close PID;
   $pidfile = $pf;
  }
  else {lprint("could not open pidfile: $pf - $! - continuing...");}
  delete $ENV{ULTRAVNC_REPEATER_PIDFILE};
 }
}

####################################################################
# Set ULTRAVNC_REPEATER_LOOP=1 to have this script create an outer loop
# restarting itself if it ever exits.  Set ULTRAVNC_REPEATER_LOOP=BG to
# do this in the background as a daemon.  Same as -L option.

if (exists $ENV{ULTRAVNC_REPEATER_LOOP}) 
{
 my $csl = $ENV{ULTRAVNC_REPEATER_LOOP};
 if ($csl ne 'BG' && $csl ne '1') {die "ultravnc_repeater.pl: invalid ULTRAVNC_REPEATER_LOOP.\n";}
 if ($csl eq 'BG') 
 {
  # go into bg as "daemon":
  setpgrp(0, 0);
  
  my $pid = fork();

  if (! defined $pid) {die "ultravnc_repeater.pl: $!\n";}  # Executed by both Parent and Child processes
  elsif ($pid)  # Executed by both Parent and Child processes, (Parent will see the Child process's PID, Child will see 0)
  {
   wait;  # Parent process waits for Child process to terminate (Executed by Parent process only)
   exit 0;
  }
  
  # Executed by Child process only
  if (fork) {exit 0;}
  
  # Executed by orphaned Grandchild process only
  setpgrp(0, 0);
  close STDIN;
  if (! $ENV{ULTRAVNC_REPEATER_LOGFILE}) 
  {
   close STDOUT;
   close STDERR;
  }
 }
 
# Remove Command-Line Looping argument, (This prevents forked child processes inheriting the parent process's command-line arguments and re-forking indefinitely and thus creating a "Fork Bomb")
 delete $ENV{ULTRAVNC_REPEATER_LOOP};

 if (exists $ENV{ULTRAVNC_REPEATER_PIDFILE}) {open_pidfile();}

 # ***NOTE*** This following code is executed by the orphaned Grandchild process of the original Parent Process if in Background Looping mode, or by the Parent process if in Foreground Looping mode
 lprint("ultravnc_repeater.pl: starting service. master-pid=$$");
 while (1) 
 {
  $looppid = fork;  # Create a new process running the same program at the same point. It returns the child pid to the parent process, 0 to the child process, or undef if the fork is unsuccessful.
  
  if (! defined $looppid) {sleep 10;}
  elsif ($looppid) {wait;}                # Pause this process and wait for the forked child process to terminate
  else {exec 'perl', $0, @ARGV; exit 1;}  # Executed by the forked child process executes a system command and never returns (Note: $0 Contains the name of the file containing the perl script being executed and the array ARGV contains the command line arguments intended for the script.)
  
  lprint("ultravnc_repeater.pl: re-starting service.  master-pid=$$");
  sleep 1;
 }
 exit 0;
}
if (exists $ENV{ULTRAVNC_REPEATER_PIDFILE}) {open_pidfile();}

# End of background/daemon stuff.
####################################################################

use warnings;
use IO::Socket::INET;
use IO::Select;

# Test for INET6 support:
#
my $have_inet6 = 0;
eval "use IO::Socket::INET6;";
$have_inet6 = 1 if $@ eq "";
print "perl module IO::Socket::INET6 not available: no IPv6 support.\n" if ! $have_inet6;

my $prog = 'ultravnc_repeater';
my %ID;

my $refuse = 0;
my $init_timeout = 5;

my $select_timeout = 15;

if (exists $ENV{ULTRAVNC_REPEATER_REFUSE} && $ENV{ULTRAVNC_REPEATER_REFUSE}) 
{
 $refuse = 1;
 lprint("enabling refuse mode (-r).");
}

# my $client_port = shift;
# my $server_port = shift;
# 
# if (exists $ENV{ULTRAVNC_REPEATER_CLIENT_PORT}) {$client_port0 = $ENV{ULTRAVNC_REPEATER_CLIENT_PORT};}
# if (exists $ENV{ULTRAVNC_REPEATER_SERVER_PORT}) {$server_port0 = $ENV{ULTRAVNC_REPEATER_SERVER_PORT};}
# 
# $client_port = $client_port0 unless $client_port;
# $server_port = $server_port0 unless $server_port;
my $client_port = $ENV{ULTRAVNC_REPEATER_CLIENT_PORT};
my $server_port = $ENV{ULTRAVNC_REPEATER_SERVER_PORT};

my $uname = `uname`;
chomp $uname;

my $repeater_bufsize = 250;
$repeater_bufsize = $ENV{ULTRAVNC_REPEATER_BUFSIZE} if exists $ENV{ULTRAVNC_REPEATER_BUFSIZE};

my ($RIN, $WIN, $EIN, $ROUT);

my $client_listen = IO::Socket::INET->new
(
 Listen    => 10,
 LocalPort => $client_port, 
 ReuseAddr => 1,
 Proto => "tcp"
);
my $err1 = $!;
my $err2 = '';
$client_listen = '' if ! $client_listen;

my $client_listen6 = '';
if ($have_inet6) 
{
 eval {$client_listen6 = IO::Socket::INET6->new
 (
  Listen    => 10,
  LocalPort => $client_port,
  ReuseAddr => 1,
  Domain    => AF_INET6,
  LocalAddr => "::",
  Proto     => "tcp"
 );};
 $err2 = $!;
}
if (! $client_listen && ! $client_listen6) 
{
 cleanup();
 die "$prog: error: client listen on port $client_port: $err1 - $err2\n";
}

my $server_listen = IO::Socket::INET->new
(
 Listen    => 10,
 LocalPort => $server_port, 
 ReuseAddr => 1,
 Proto => "tcp"
);
$err1 = $!;
$err2 = '';
$server_listen = '' if ! $server_listen;

my $server_listen6 = '';
if ($have_inet6) 
{
 eval {$server_listen6 = IO::Socket::INET6->new
 (
  Listen    => 10,
  LocalPort => $server_port,
  ReuseAddr => 1,
  Domain    => AF_INET6,
  LocalAddr => "::",
  Proto     => "tcp"
 );};
 $err2 = $!;
}
if (! $server_listen && ! $server_listen6) 
{
 cleanup();
 die "$prog: error: server listen on port $server_port: $err1 - $err2\n";
}

my $select = new IO::Select();
if (! $select) 
{
 cleanup();
 die "$prog: select $!\n";
}

$select->add($client_listen)  if $client_listen;
$select->add($client_listen6) if $client_listen6;
$select->add($server_listen)  if $server_listen;
$select->add($server_listen6) if $server_listen6;

$SIG{INT}  = sub {cleanup(); exit;};
$SIG{TERM} = sub {cleanup(); exit;};

my $SOCK1 = '';
my $SOCK2 = '';
my $CURR = '';

lprint("$prog: starting up.  pid: $$");
lprint("watching for IPv4 connections on $client_port/client.") if $client_listen;
lprint("watching for IPv4 connections on $server_port/server.") if $server_listen;
lprint("watching for IPv6 connections on $client_port/client.") if $client_listen6;
lprint("watching for IPv6 connections on $server_port/server.") if $server_listen6;

my $alarm_sock = '';
my $got_alarm = 0;
sub alarm_handler 
{
 lprint("$prog: got sig alarm.");
 if ($alarm_sock ne '') {close $alarm_sock;}
 $alarm_sock = '';
 $got_alarm = 1;
}

while (1) 
{
 my @ready = $select->can_read($select_timeout);
 foreach my $fh (@ready) 
 {
  if (($client_listen && $fh == $client_listen) || ($client_listen6 && $fh == $client_listen6)) {lprint("new vnc client connecting.");}
  elsif (($server_listen && $fh == $server_listen) || ($server_listen6 && $fh == $server_listen6)) {lprint("new vnc server connecting.");}
  
  my $sock = $fh->accept();
  if (! $sock) {lprint("$prog: accept $!"); next;}

  if (($client_listen && $fh == $client_listen) || ($client_listen6 && $fh == $client_listen6)) {lprint('Client IP Address: ' . $sock->peerhost());}  # log the Client IP address
  if (($server_listen && $fh == $server_listen) || ($server_listen6 && $fh == $server_listen6)) {lprint('Server IP Address: ' . $sock->peerhost());}  # log the Server IP address

  if (($client_listen && $fh == $client_listen) || ($client_listen6 && $fh == $client_listen6)) 
  {
   if (exists $ENV{ULTRAVNC_REPEATER_NO_RFB} && $ENV{ULTRAVNC_REPEATER_NO_RFB}) {lprint("ULTRAVNC_REPEATER_NO_RFB: not sending RFB 000.000");}
   else 
   {
    my $str = "RFB 000.000\n";
    my $len = length $str;
    my $n = syswrite($sock, $str, $len, 0);
    if ($n != $len) 
    {
     lprint("$prog: bad $str write: $n != $len $!");
     close $sock;
    }
   }
  }

  my $buf = '';
  my $size = $repeater_bufsize;
  $size = 1024 unless $size;

  $SIG{ALRM} = "alarm_handler";
  $alarm_sock = $sock;
  $got_alarm = 0;
  alarm($init_timeout);
  my $n = sysread($sock, $buf, $size);
  alarm(0);

  if ($got_alarm) {lprint("$prog: read timed out: $!");}
  elsif (! defined $n) {lprint("$prog: read error: $!");}
  elsif ($repeater_bufsize > 0 && $n != $size) {lprint("$prog: short read $n != $size $!"); close $sock;}
  elsif (($client_listen && $fh == $client_listen) || ($client_listen6 && $fh == $client_listen6)) {do_new_client($sock, $buf);}
  elsif (($server_listen && $fh == $server_listen) || ($server_listen6 && $fh == $server_listen6)) {do_new_server($sock, $buf);}
 }
 clean_connections();
}

sub clean_connections 
{
 if (exists $ENV{ULTRAVNC_REPEATER_CLEAN} && $ENV{ULTRAVNC_REPEATER_CLEAN}) 
 {
  foreach my $id (keys %ID) 
  {
   next if !exists $ID{$id}{sock};
   if (!established($ID{$id}{sock})) 
   {
    lprint("socket for ID:$id is no longer established, closing it.");
    close $ID{$id}{sock};
    delete $ID{$id};
   }
  }
 }
}

sub do_new_client 
{
 my ($sock, $buf) = @_;

 if ($buf =~ /^ID:(\w+)/) 
 {
  my $id = $1;
  if (exists $ID{$id} && exists $ID{$id}{client} && $ID{$id}{client} eq "0") 
  {
   if (!established($ID{$id}{sock})) 
   {
    lprint("server socket for ID:$id is no longer established, closing it.");
    close $ID{$id}{sock};
    delete $ID{$id};
   }
   else {lprint("server socket for ID:$id is still established.");}
  }
  if (exists $ID{$id}) 
  {
   if ($ID{$id}{client}) 
   {
    my $ref = $refuse;
    if ($ref && !established($ID{$id}{sock})) 
    {
     lprint("socket for ID:$id is no longer established, closing it.");
     $ref = 0;
    }
    if ($ref) 
    {
     lprint("refusing extra vnc client for ID:$id.");
     close $sock;
     return;
    }
    else 
    {
     lprint("closing and deleting previous vnc client with ID:$id.");
     close $ID{$id}{sock};

     lprint("storing new vnc client with ID:$id.");
     $ID{$id}{client} = 1;
     $ID{$id}{sock} = $sock;
    }
   }
   else 
   {
    lprint("hooking up new vnc client with existing vnc server for ID:$id.");
    my $sock2 = $ID{$id}{sock};
    delete $ID{$id};
    hookup($sock, $sock2, "ID:$id"); 
   }
  }
  else 
  {
   lprint("storing new vnc client with ID:$id.");
   $ID{$id}{client} = 1;
   $ID{$id}{sock} = $sock;
  }
 }
 else 
 {
  my $str = sprintf("%s", $buf);
  $str =~ s/\s*$//g;
  $str =~ s/\0*$//g;
  my $host = '';
  my $port = '';
  if ($str =~ /^(.+):(\d+)$/) 
  {
   $host = $1;
   $port = $2;
  }
  else 
  {
   $host = $str;
   $port = 5900;
  }
  if ($port < 0) 
  {
   my $pnew = -$port;
   lprint("resetting port from $port to $pnew.");
   $port = $pnew;
  }
  elsif ($port < 200) 
  {
   my $pnew = $port + 5900;
   lprint("resetting port from $port to $pnew.");
   $port = $pnew;
  }
  lprint("making vnc client connection directly to vnc server host='$host' port='$port'.");
  my $sock2 =  IO::Socket::INET->new
  (
   PeerAddr => $host,
   PeerPort => $port,
   Proto => "tcp"
  );
  if (! $sock2 && $have_inet6) 
  {
   lprint("IPv4 connect error: $!, trying IPv6 ...");
   eval{$sock2 = IO::Socket::INET6->new
   (
    PeerAddr => $host,
    PeerPort => $port,
    Proto => "tcp"
   );};
   lprint("IPv6 connect error: $!") if !$sock2;
  }
  else {lprint("IPv4 connect error: $!") if !$sock2;}
  if (!$sock2) 
  {
   lprint("failed to connect to $host:$port.");
   close $sock;
   return;
  }
  hookup($sock, $sock2, "$host:$port"); 
 }
}

sub do_new_server 
{
 my ($sock, $buf) = @_;

 if ($buf =~ /^ID:(\w+)/) {
  my $id = $1;
  my $store = 1;
  if (exists $ID{$id} && exists $ID{$id}{client} && $ID{$id}{client} eq "1") 
  {
   if (!established($ID{$id}{sock})) 
   {
    lprint("client socket for ID:$id is no longer established, closing it.");
    close $ID{$id}{sock};
    delete $ID{$id};
   }
   else {lprint("client socket for ID:$id is still established.");}
  }
  if (exists $ID{$id}) 
  {
   if (! $ID{$id}{client}) 
   {
    my $ref = $refuse;
    if ($ref && !established($ID{$id}{sock})) 
    {
     lprint("socket for ID:$id is no longer established, closing it.");
     $ref = 0;
    }
    if ($ref) 
    {
     lprint("refusing extra vnc server for ID:$id.");
     close $sock;
     return;
    }
    else 
    {
     lprint("closing and deleting previous vnc server with ID:$id.");
     close $ID{$id}{sock};

     lprint("storing new vnc server with ID:$id.");
     $ID{$id}{client} = 0;
     $ID{$id}{sock} = $sock;
    }
   }
   else 
   {
    lprint("hooking up new vnc server with existing vnc client for ID:$id.");
    my $sock2 = $ID{$id}{sock};
    delete $ID{$id};
    hookup($sock, $sock2, "ID:$id"); 
   }
  }
  else 
  {
   lprint("storing new vnc server with ID:$id.");
   $ID{$id}{client} = 0;
   $ID{$id}{sock} = $sock;
  }
 }
 else 
 {
  lprint("invalid ID:NNNNN string for vnc server: $buf");
  close $sock;
  return;
 }
}

sub established 
{
 my $fh = shift;

 return established_linux_proc($fh);

 # not working:
 my $est = 1;
 my $str = "Z";
 my $res;
 #$res = recv($fh, $str, 1, MSG_PEEK | MSG_DONTWAIT);
 if (defined($res)) 
 {
  lprint("established OK:  $! '$str'.");
  $est = 1;
 }
 else 
 {
  # would check for EAGAIN here to decide ...
  lprint("established err: $! '$str'.");
  $est = 1;
 }
 return $est;
}

sub established_linux_proc 
{
 # hack for Linux to see if remote side has gone away:
 my $fh = shift;

 # if we can't figure things out, we must return true.
 if ($uname !~ /Linux/) {return 1;}

 my @proc_net_tcp = ();
 if (-e "/proc/net/tcp") {push @proc_net_tcp, "/proc/net/tcp";}    # If "/proc/net/tcp" file exists then push IPv4 socket data pseudo path into array
 if (-e "/proc/net/tcp6") {push @proc_net_tcp, "/proc/net/tcp6";}  # If "/proc/net/tcp6" file exists then push IPv6 socket data pseudo path into array
 if (! @proc_net_tcp) {return 1;}

 my $n = fileno($fh);
 if (!defined($n)) {return 1;}

 my $proc_fd = "/proc/$$/fd/$n";
 if (! -e $proc_fd) {return 1;}

 my $val = readlink($proc_fd);
 if (! defined $val || $val !~ /socket:\[(\d+)\]/) {return 1;}
 my $num = $1;

 my $st = '';

 foreach my $tcp (@proc_net_tcp) 
 {
  if (! open(TCP, "<$tcp")) {next;}
  while (<TCP>) 
  {
   next if /^\s*[A-z]/;
   chomp;
   #  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode                                                     
   # 170: 0102000A:170C FE02000A:87FA 01 00000000:00000000 00:00000000 00000000  1001        0 423294766 1 f6fa4100 21 4 4 2 -1
   # 172: 0102000A:170C FE02000A:87FA 08 00000000:00000001 00:00000000 00000000  1001        0 423294766 1 f6fa4100 21 4 4 2 -1
   my @items = split(' ', $_);
   my $state = $items[3];
   my $inode = $items[9];
   if (!defined $state || $state !~ /^\d+$/) {next;}
   if (!defined $inode || $inode !~ /^\d+$/) {next;}
   if ($inode == $num) 
   {
    $st = $state;
    last;
   }
  }
  close TCP;
  last if $st ne '';
 }

# if ($st ne '' && $st != 1) {return 0;}
 if ($st eq '') {return 0;}    # Socket number not found in TCP dump, assuming no longer connected
 elsif ($st != 1) {return 0;}

 return 1;
}

sub handler 
{
 lprint("\[$$/$CURR] got SIGTERM.");
 close $SOCK1 if $SOCK1;
 close $SOCK2 if $SOCK2;
 exit;
}

sub hookup 
{
 my ($sock1, $sock2, $tag) = @_;

 my $worker = fork();

 if (! defined $worker) 
 {
  lprint("failed to fork worker: $!");
  close $sock1;
  close $sock2;
  return;
 }
 elsif ($worker) 
 {
  close $sock1;
  close $sock2;
  wait;
 }
 else 
 {
  cleanup();
  if (fork) {exit 0;}
  setpgrp(0, 0);
  $SOCK1 = $sock1;
  $SOCK2 = $sock2;
  $CURR  = $tag;
  $SIG{TERM} = "handler";
  $SIG{INT}  = "handler";
  xfer_both($sock1, $sock2);
  exit 0;
 }
}

sub xfer 
{
 my ($in, $out) = @_;

 $RIN = $WIN = $EIN = "";
 $ROUT = "";
 vec($RIN, fileno($in), 1) = 1;
 vec($WIN, fileno($in), 1) = 1;
 $EIN = $RIN | $WIN;

 my $buf;

 while (1) 
 {
  my $nf = 0;
  while (! $nf) {$nf = select($ROUT=$RIN, undef, undef, undef);}
  my $len = sysread($in, $buf, 8192);
  if (! defined($len)) 
  {
   next if $! =~ /^Interrupted/;
   lprint("\[$$/$CURR] $!");
   last;
  }
  elsif ($len == 0) 
  {
   lprint("\[$$/$CURR] Input is EOF.");
   last;
  }
  my $offset = 0;
  my $quit = 0;
  while ($len) 
  {
   my $written = syswrite($out, $buf, $len, $offset);
   if (! defined $written) 
   {
    lprint("\[$$/$CURR] Output is EOF. $!");
    $quit = 1;
    last;
   }
   $len -= $written;
   $offset += $written;
  }
  last if $quit;
 }
 close($out);
 close($in);
 lprint("\[$$/$CURR] finished xfer.");
}

sub xfer_both 
{
 my ($sock1, $sock2) = @_;

 my $parent = $$;

 my $child = fork();

 if (! defined $child) 
 {
  lprint("$prog\[$$/$CURR] failed to fork: $!");
  return;
 }

 $SIG{TERM} = "handler";
 $SIG{INT}  = "handler";

 if ($child) 
 {
  lprint("[$$/$CURR] parent 1 -> 2.");
  xfer($sock1, $sock2);
  select(undef, undef, undef, 0.25);
  if (kill 0, $child) 
  {
   select(undef, undef, undef, 0.9);
   if (kill 0, $child) 
   {
    lprint("\[$$/$CURR] kill TERM child $child");
    kill "TERM", $child;
   }
   else {lprint("\[$$/$CURR] child  $child gone.");}
  }
 } 
 else 
 {
  select(undef, undef, undef, 0.05);
  lprint("[$$/$CURR] child  2 -> 1.");
  xfer($sock2, $sock1);
  select(undef, undef, undef, 0.25);
  if (kill 0, $parent) 
  {
   select(undef, undef, undef, 0.8);
   if (kill 0, $parent) 
   {
    lprint("\[$$/$CURR] kill TERM parent $parent.");
    kill "TERM", $parent;
   }
   else {lprint("\[$$/$CURR] parent $parent gone.");}
  }
 }
}

sub fsleep 
{
 my ($time) = @_;
 select(undef, undef, undef, $time) if $time;
}

sub cleanup 
{
 close $client_listen  if $client_listen;
 close $client_listen6 if $client_listen6;
 close $server_listen  if $server_listen;
 close $server_listen6 if $server_listen6;
 foreach my $id (keys %ID) {close $ID{$id}{sock};}
}

sub url_decode 
{
 # for CGI mode
 foreach (@_) 
 {
  tr/+/ /;
  s/%([\dA-F][\dA-F])/pack("c",hex($1))/ige;
 }
 @_;
}

sub check_cgi 
{
 # called via CGI launcher
 my $request = '';
 
 if (!exists $ENV{REQUEST_METHOD}) {;}
 elsif ($ENV{REQUEST_METHOD} eq 'POST' && exists $ENV{CONTENT_LENGTH}) {read(STDIN, $request, $ENV{CONTENT_LENGTH});}
 elsif ($ENV{REQUEST_METHOD} eq 'GET'  && exists $ENV{QUERY_STRING}) {$request = $ENV{QUERY_STRING};}
 
 delete $ENV{REQUEST_METHOD} if exists $ENV{REQUEST_METHOD};

 return if $request =~ /^\s*$/;

 my %req = &url_decode(split(/[&=]/, $request));

 print "Content-type: text/html\n\n";

 if (exists $req{help} && $req{help} =~ /^(true|1)$/i) 
 {
  print $usage;
  exit 0;
 }

 # WARNING: There may be a CGI security problem here letting
 # a remote user set logfile, pidfile, and perhaps the others.
 # Consider the user the CGI process runs as.  Can they write to
 # important files?  Do the following checks and open() calls
 # prevent running arbitrary commands?  Please audit for your
 # configuration and add extra checks.  Consider limiting logfile
 # and pidfile to reside in a fixed directory.
 #
 $ENV{ULTRAVNC_REPEATER_LOGFILE} = $req{logfile} if exists $req{logfile} && $req{logfile} !~ /[\\\/|<>&*+]/;
 $ENV{ULTRAVNC_REPEATER_PIDFILE} = $req{pidfile} if exists $req{pidfile} && $req{pidfile} !~ /[\\\/|<>&*+]/;
 $ENV{ULTRAVNC_REPEATER_BUFSIZE} = $req{bufsize} if exists $req{bufsize} && $req{bufsize} =~ /^\d+$/;
 $ENV{ULTRAVNC_REPEATER_CLIENT_PORT} = $req{cport} if exists $req{cport} && $req{cport} =~ /^\d+$/;
 $ENV{ULTRAVNC_REPEATER_SERVER_PORT} = $req{sport} if exists $req{sport} && $req{sport} =~ /^\d+$/;
 $ENV{ULTRAVNC_REPEATER_LOOP} = $req{loop} if exists $req{loop} && $req{loop} =~ /^(BG|1|0)$/;
 $ENV{ULTRAVNC_REPEATER_NO_RFB} = 1 if exists $req{norfb} && $req{norfb} =~ /^(true|1)$/i;
 $ENV{ULTRAVNC_REPEATER_CLEAN} = 1 if exists $req{clean} && $req{clean} =~ /^(true|1)$/i;
 $ENV{ULTRAVNC_REPEATER_REFUSE} = 1 if exists $req{refuse} && $req{refuse} =~ /^(true|1)$/i;
}

# This routine checks that all the environment variables are correctly formatted and resets them to their default values if they aren't
# (This should prevent any of the security issues mentioned earlier by Karl...  Keith.)
sub validateEnv()
{
 if (exists $ENV{ULTRAVNC_REPEATER_LOGFILE})
 {
  if ($ENV{ULTRAVNC_REPEATER_LOGFILE} !~ /^[a-z _\-\.]+$/i) {lprint("Invalid log file name: [" . $ENV{ULTRAVNC_REPEATER_LOGFILE} . "]"); $ENV{ULTRAVNC_REPEATER_LOGFILE} = 'repeater.log';}
  elsif (($ENV{ULTRAVNC_REPEATER_LOGFILE} !~ s/^([a-z _\-\.]+\.)[a-z]+$/$1log/i)) {$ENV{ULTRAVNC_REPEATER_LOGFILE} = $ENV{ULTRAVNC_REPEATER_LOGFILE} . '.log';}
 } 

 if (exists $ENV{ULTRAVNC_REPEATER_PIDFILE})
 {
  if ($ENV{ULTRAVNC_REPEATER_PIDFILE} !~ /^[a-z _\-\.]+$/i) {lprint("Invalid pid file name: [" . $ENV{ULTRAVNC_REPEATER_PIDFILE} . "]"); $ENV{ULTRAVNC_REPEATER_PIDFILE} = 'repeater.pid';}
  elsif (($ENV{ULTRAVNC_REPEATER_PIDFILE} !~ s/^([a-z _\-\.]+\.)[a-z]+$/$1pid/i)) {$ENV{ULTRAVNC_REPEATER_PIDFILE} = $ENV{ULTRAVNC_REPEATER_PIDFILE} . '.pid';}
 } 

 if (exists $ENV{ULTRAVNC_REPEATER_BUFSIZE} && $ENV{ULTRAVNC_REPEATER_BUFSIZE} !~ /^\d+$/) {lprint("Invalid buffer size: [" . $ENV{ULTRAVNC_REPEATER_BUFSIZE} . "]"); $ENV{ULTRAVNC_REPEATER_BUFSIZE} = '250';}
 if (exists $ENV{ULTRAVNC_REPEATER_CLIENT_PORT} && $ENV{ULTRAVNC_REPEATER_CLIENT_PORT} !~ /^\d+$/) {lprint("Invalid client port: [" . $ENV{ULTRAVNC_REPEATER_CLIENT_PORT} . "]"); $ENV{ULTRAVNC_REPEATER_CLIENT_PORT} = '5900';}
 if (exists $ENV{ULTRAVNC_REPEATER_SERVER_PORT} && $ENV{ULTRAVNC_REPEATER_SERVER_PORT} !~ /^\d+$/) {lprint("Invalid server port: [" . $ENV{ULTRAVNC_REPEATER_SERVER_PORT} . "]"); $ENV{ULTRAVNC_REPEATER_SERVER_PORT} = '5500';}
 if (exists $ENV{ULTRAVNC_REPEATER_LOOP} && $ENV{ULTRAVNC_REPEATER_LOOP} !~ /^(BG|1|0)$/) {lprint("Invalid repeater loop: [" . $ENV{ULTRAVNC_REPEATER_LOOP} . "]"); $ENV{ULTRAVNC_REPEATER_LOOP} = '';}
 if (exists $ENV{ULTRAVNC_REPEATER_NO_RFB} && $ENV{ULTRAVNC_REPEATER_NO_RFB} !~ /^[01]*$/) {lprint("Invalid RFB setting: [" . $ENV{ULTRAVNC_REPEATER_NO_RFB} . "]"); $ENV{ULTRAVNC_REPEATER_NO_RFB} = '';}
 if (exists $ENV{ULTRAVNC_REPEATER_CLEAN} && $ENV{ULTRAVNC_REPEATER_CLEAN} !~ /^[01]*$/) {lprint("Invalid clean  setting: [" . $ENV{ULTRAVNC_REPEATER_CLEAN} . "]"); $ENV{ULTRAVNC_REPEATER_CLEAN} = '1';}
 if (exists $ENV{ULTRAVNC_REPEATER_REFUSE} && $ENV{ULTRAVNC_REPEATER_REFUSE} !~ /^[01]*$/) {lprint("Invalid refuse setting: [" . $ENV{ULTRAVNC_REPEATER_REFUSE} . "]"); $ENV{ULTRAVNC_REPEATER_REFUSE} = '';}
}
