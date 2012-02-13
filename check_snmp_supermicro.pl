#!/usr/bin/perl
# author: Scott Barr <gsbarr@gmail.com>
#       This program is free software; you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation; either version 2 of the License, or
#       (at your option) any later version.
#       
#       This program is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#       GNU General Public License for more details.
#       
#       You should have received a copy of the GNU General Public License
#       along with this program; if not, write to the Free Software
#       Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#       MA 02110-1301, USA.
#       

use strict;
require 5.10.0;
use feature qw(switch say);
use lib qw( /usr/lib/nagios/plugins );
use utils qw($TIMEOUT);
use Net::SNMP;
use Getopt::Long;
use Nagios::Plugin;
use vars qw(
			$snmp_session
			$plugin
			$oid_prefix
			%oid_map
			$TIMEOUT
		);
		
use version; our $VERSION = '2.0';
# --------------------------- globals -------------------------- #
my %MonitoredItems=();
my @desc=();
my $PROGNAME      = "check_snmp_supermicro.pl";
my $opt_verbose   = undef;
my $opt_host      = 'localhost';
my $opt_community = 'public';
my $opt_port      = 161;
my %opt_test	  = ();
my $criticals 	  = q{};
my $warnings  	  = q{};
my $unknowns  	  = q{};
my $status		  = q{};
my $oid_prefix    = ".1.3.6.1.4.1.10876.2.1.1.1.1.";
my $monitor_unit  = '';
my $monitor_monitored = '';
my $monitor_low		= '';
my $monitor_high	= '';

$plugin    	   = Nagios::Plugin->new( shortname => $PROGNAME );
# ---------------------------- main ----------------------------- #
Getopt::Long::Configure( 'bundling' );
GetOptions(
	'version|V'     => sub { print "$PROGNAME version $VERSION\n"; exit 3; },
	'verbose|v'     => \$opt_verbose,
	'help|h'     	=> sub { print help(); exit 3; },
	'hostname|H=s'  => \$opt_host,
	'port|p=i'   	=> \$opt_port,
	'community|C=s' => \$opt_community,
	'timeout|t=i'   => \$TIMEOUT,
	'test|T:s'		=> \%opt_test,
);

if (!%opt_test) {
	$plugin->nagios_exit(UNKNOWN, help());
}

$SIG{'ALRM'} = sub {
	$plugin->nagios_exit(UNKNOWN, "Timeout exceeded " . $TIMEOUT);
};
alarm( $TIMEOUT ); # make sure we don't hang Nagios

my $snmp_error;
($snmp_session,$snmp_error) = Net::SNMP->session(
									-version => 	'snmpv2c',
									-hostname => 	$opt_host,
									-community => 	$opt_community,
									-port => 		$opt_port,
							    );
$plugin->nagios_exit(UNKNOWN, "SNMP Error: " . $snmp_error) unless (defined($snmp_session));

if (defined($opt_verbose)) {
		$snmp_session->debug(1); 
}
	
# Populate the hash with valid monitor names and indexes
my $result = $snmp_session->get_entries(-columns => [$oid_prefix."2"]);
if (!defined($result)) {
	$plugin->nagios_exit(UNKNOWN, "SNMP Error: ".$snmp_session->error());
}

while ( my ($oid, $reading) = each(%{$result}) ) {
	my $index  = substr($oid, (rindex($oid,".")+1) );
	$MonitoredItems{$reading} = $index;
}

# Check parsed tests and filter hash for valid names
my @indexes = grep { exists $MonitoredItems{$_} } keys %opt_test;

for my $test_name (@indexes) {
		
	my ($monitor_name, $monitor_type, $monitor_reading) = getMonitor($MonitoredItems{$test_name});
	
	# Get user warning level. Critical can be found from SuperDoctor.
	my ( $warn, $crit ) = split /,/mx, $opt_test{$test_name};
	$plugin->nagios_exit(UNKNOWN, "No warning level found for monitor '$test_name'") unless (defined($warn) || $monitor_type == 3);
	
	given($monitor_type) 
	{
	  when(0) { # Fan speed
		  $monitor_unit = "RPM";
		  my ($monitor_low, $monitor_monitored) = getOids($MonitoredItems{$test_name}, ('low', 'monitored'));
		  $plugin->nagios_exit(UNKNOWN, "The fan '$test_name' is not monitored.") unless ($monitor_monitored == 1);
		  
		  if (!$crit) {
			  $crit  = $monitor_low;
		  }
		  
		  if ( $monitor_reading < $crit ) {
			  $criticals .= " $test_name";
		  }
		  elsif ( $monitor_reading < $warn ) {
			  $warnings .= " $test_name";
		  }
	  }
	  when (1) { # Voltage
		  $monitor_unit = "V";
		  my ($warn_low, $warn_high, $crit_low, $crit_high) = ('','','','');
		  $monitor_reading = sprintf("%.2f", ($monitor_reading/1000)); # Convert into V from mV.
		  
		  my ($monitor_low, $monitor_high) = getOids($MonitoredItems{$test_name}, ('low', 'high'));
		  
		  if (!$crit) {
			$crit  = sprintf("%.2f", ($monitor_low/1000)) . ':' . sprintf("%.2f", ($monitor_high/1000));
		  }
		  
		  if ($warn =~ m/^([\d.]+):([\d.]+)$/) { 
			  ($warn_low, $warn_high) = ($1,$2);
		  } else {
			  $plugin->nagios_exit(UNKNOWN, "Cannot identify low and high end of the warning level range required by '$test_name'");
		  }
		  
		  if ($crit =~ m/^([\d.]+):([\d.]+)$/) { 
			  ($crit_low, $crit_high) = ($1,$2); 
		  } else {
			  $plugin->nagios_exit(UNKNOWN, "Cannot identify low and high end of the critical level range required by '$test_name'");
		  }
		  
		  if ( ($monitor_reading < $crit_low) || ($monitor_reading > $crit_high) ) {
			  $criticals .= " $test_name";
		  } elsif ( ($monitor_reading < $warn_low) || ($monitor_reading > $warn_high) ) {
			  $warnings .= " $test_name";
		  }
	  }
	  when (2) { # Temperature
		  $monitor_unit = "C";		  
		  my ($monitor_high) = getOids($MonitoredItems{$test_name}, ('high'));
		  
		  if (!$crit) {
			$crit = $monitor_high;
		  }
		  
		  if ( $monitor_reading > $crit ) {
			  $criticals .= " $test_name";
		  }
		  elsif ( $monitor_reading > $warn ) {
			  $warnings .= " $test_name";
		  }
	  }
	  when (3) { # Good (0) and bad (1) stuff i.e. Power supply
		   $criticals .= " $test_name" unless ($monitor_reading == 0);
	  }
	}
		
	$status = $status . "$test_name=$monitor_reading;$warn;$crit;;";
	push(@desc, "$test_name=$monitor_reading$monitor_unit");
}

if ('fan-speeds' ~~ %opt_test) {
	
	my ( $warn, $crit ) = split /,/mx, $opt_test{'fan-speeds'};
	$plugin->nagios_exit(UNKNOWN, "No warning level found for fan speeds") unless (defined($warn));
	
	$result = $snmp_session->get_entries(-columns => [$oid_prefix."3"]);
	if (!defined($result)) {
		$plugin->nagios_exit(UNKNOWN, "SNMP Error: ".$snmp_session->error());
	}
	
	while ( my ($oid, $reading) = each(%{$result}) ) {
		if ($reading == 0) {
			
			my $index  = substr($oid, (rindex($oid,".")+1) );
			my ($monitor_name, $monitor_type, $monitor_reading, $monitor_low, $monitor_monitored) = getOids($index, ('name','type','value','low','monitored'));
			next unless ($monitor_monitored == 1);
			
			if (!$crit) {
				$crit  = $monitor_low;
			}
			
			if ( $monitor_reading < $crit ) {
				$criticals .= " $monitor_name";
			}
			elsif ( $monitor_reading < $warn ) {
				$warnings .= " $monitor_name";
			}
			
			$status = $status . "$monitor_name=$monitor_reading;$warn;$crit;;";
			push(@desc, "$monitor_name=${monitor_reading}RPM");
		}
	}
		
}

$snmp_session->close;
alarm( 0 ); # we're not going to hang after this.


if ($status) {
	$status = "|" . $status;
}

my $desc = join(' ', @desc);

if ( $criticals ne q{} ) {
   $plugin->nagios_exit(CRITICAL, "$desc$status");
}

if ( $warnings ne q{} ) {
   $plugin->nagios_exit(WARNING, "$desc$status");    
}

if ( $unknowns ne q{} || !$status ) {
  $plugin->nagios_exit(UNKNOWN, "$desc$status");    
}

$plugin->nagios_exit(OK, "$desc$status");    

# ---------------------------- Support methods ------------------ #
sub getOids {
	my ($monitor_index, @monitor_attrs) = @_;

	my %oid_map = ( 'name'	=>	$oid_prefix."2.".$monitor_index,
					'type'	=>	$oid_prefix."3.".$monitor_index,
					'value'	=>	$oid_prefix."4.".$monitor_index,
					'low'	=>	$oid_prefix."6.".$monitor_index,
					'high'	=>	$oid_prefix."5.".$monitor_index,
					'monitored'	=>	$oid_prefix."10.".$monitor_index );
	my @oids = ();
	
	for my $attr (@monitor_attrs) {
		if ($oid_map{$attr}) {
			push(@oids, $oid_map{$attr});
		}
	}
	
	my $res = $snmp_session->get_request( -varbindlist => \@oids);
	$plugin->nagios_exit(UNKNOWN, "SNMP Error: " . $snmp_session->error()) unless (defined($res));
	
	my @result = ();
	for my $attr (@monitor_attrs) {
		if ($oid_map{$attr}) {
			push(@result, $res->{$oid_map{$attr}});
		}
	}
	
	return @result;
}

sub getMonitor {
	my ($monitor_index) = @_;
	return getOids($monitor_index, ('name','type','value'));
}

sub help {
print <<EOT;
Usage: $PROGNAME -H <host> -C <snmp_community> [-T] 
Check the health of Supermicro hardware via SNMP. The plugin depends on the installation of the
sd_extension supplied with the SuperDoctor software. See their README file for more information
about getting SNMP configured for the extension.

Monitor names for the test argument can be found from the output of the sdt command that is installed
with SuperDoctor. See examples below.

	-V, --version
		print current version
	-v, --verbose
		print extra debugging information
	-T, --test
		Perform a test(s) of the specified monitor(s).
		Example:
			-T 'System Temperature'=50,60
		will give a warning if the value of the monitor reaches 50 degrees and a critical status 
		if it reaches 60 degrees celcius. For voltage monitors define the lower:upper limits of 
		the warning and critical levels.
		Example:
			--test 'CPU Core Voltage'=1.10:1.29,0.92:1.38 or
			-T '+5V Voltage'=4.69:5.20 -T '+5Vsb Voltage'=4.69:5.20
		Critical levels may be omitted and will be substitued by the builtin limits set by Supermicro.
		Some monitored items have states. For example: "Power Supply Failure" has a reading of Good or Bad. 
		These items can have warning and critical levels omiited and will raise critical when the state is bad.
		Example:
			-T 'Chassis Intrusion'
	-h, --help
		print this help message
	-H, --hostname=HOST
		name or IP address of host to check (default: localhost)
	-C, --community=COMMUNITY NAME
		community name for the host's SNMP agent (default: public)
	-p, --port
		SNMP connect port (default: 161)
EOT
}
