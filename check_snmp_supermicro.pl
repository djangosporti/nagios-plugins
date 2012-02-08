#!/usr/bin/perl
# author: Scott Barr <gsbarr@gmail.com>
# license: GPL - http://www.fsf.org/licenses/gpl.txt

use strict;
require 5.10.0;
use feature qw(switch say);
use lib qw( /usr/lib/nagios/plugins );
use utils qw($TIMEOUT);
use Net::SNMP;
use Getopt::Long;
use Nagios::Plugin;
use vars qw(
			$opt_version
			$opt_timeout
			$opt_help
			$opt_host
			$opt_community
			$opt_verbose
			$opt_port
			$snmp_session
			$PROGNAME
			$TIMEOUT
			$test_name
			$limits
			$plugin
			%test_names
			$monitor_unit
			$criticals
			$warnings
			$unknowns
			$status
			@desc
			$monitor
			$monitor_index
		);
		
use version; our $VERSION = '2.0';
# --------------------------- globals -------------------------- #

my %StatusOIDS=();
my %Fans=();
my %Voltages=();
my @desc=();

$PROGNAME      = "check_snmp_supermicro.pl";
$plugin    	   = Nagios::Plugin->new( shortname => $PROGNAME );
$opt_verbose   = undef;
$opt_host      = 'localhost';
$opt_community = 'public';
$opt_port      = 161;
$test_name     = undef;
$criticals 	   = q{};
$warnings  	   = q{};
$unknowns  	   = q{};
$status		   = q{};

my $oid_prefix  = ".1.3.6.1.4.1."; 		#Enterprises
   $oid_prefix .= "10876.2.1.1.1.1."; 	#Supermicro board


# ---------------------------- main ----------------------------- #
Getopt::Long::Configure( 'bundling' );
GetOptions(
	'version|V'     => sub { print "$PROGNAME version $VERSION\n"; exit 3; },
	'verbose|v'     => \$opt_verbose,
	'help|h'     	=> \$opt_help,
	'hostname|H=s'  => \$opt_host,
	'port|p=i'   	=> \$opt_port,
	'community|C=s' => \$opt_community,
	'timeout|t=i'   => \$TIMEOUT,
	'test|T=s'		=> \%test_names,
);

if ( !%test_names || defined($opt_help) ) {
	$plugin->nagios_exit(UNKNOWN, help());
}

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
		$snmp_session->debug(-debug => 'DEBUG_ALL'); 
}

# Validate SNMP connection
my $result = $snmp_session ->get_request("1.3.6.1.2.1.1.3.0"); #sysUpTime
if (!defined($result)) {
	$plugin->nagios_exit(UNKNOWN, "SNMP Error: Please check connection settings.");
}
	
# Populate the hash with valid monitor names and indexes
my $count = 1;
while ( $count ) {
        my $oid_name = $oid_prefix."2.".$count;
        my $oid_type = $oid_prefix."3.".$count;

        my $name = $snmp_session->get_request(-varbindlist => [$oid_name]);
        $name = ($name->{$oid_name});
        if (!defined($name) || $name eq 'noSuchInstance') {
                last;
        }
        
        my $type = $snmp_session->get_request(-varbindlist => [$oid_type]);
        $type = ($type->{$oid_type});

        $StatusOIDS{$name} = $count;
        $Fans{$name} = $count if ($type == 0);
        $Voltages{$name} = $count if ($type == 1);
        $count++;
}

# Check parsed monitors or macros
while ( ( $test_name, $limits ) = each %test_names ) {
	
	my ( $warn, $crit ) = split /,/mx, $limits;
	if ( !defined($warn) ) {
		$plugin->nagios_exit(UNKNOWN, "No warning level found for monitor '$test_name'");
	}
	
	if ( $test_name ~~ %StatusOIDS ) {
			
		my $oid_template = $oid_prefix."%d.".$StatusOIDS{$test_name};
		my ($monitor_low, $monitor_high) = ('','');
		
		my $monitor_reading  = SNMP_getvalue($snmp_session, sprintf($oid_template, 4));
		my $monitor_type 	 = SNMP_getvalue($snmp_session, sprintf($oid_template, 3));
		
		given($monitor_type) 
		{
		  when(0) { # Fan speed
			  $monitor_unit = "RPM";
			  
			  my $monitored = SNMP_getvalue($snmp_session, sprintf($oid_template, 10));
			  if ($monitored == 0) {
				  $plugin->nagios_exit(UNKNOWN, "The fan '$test_name' is not monitored.");
			  }
			  
			  if (!$crit) {
				  $crit  = SNMP_getvalue($snmp_session, sprintf($oid_template, 6));
			  }
			  
			  if ( $monitor_reading < $crit ) {
				  $criticals = $criticals . " $test_name=$monitor_reading";
			  }
			  elsif ( $monitor_reading < $warn ) {
				  $warnings = $warnings . " $test_name=$monitor_reading";
			  }
		  }
		  when (1) { # Voltage
			  $monitor_unit = "V";
			  my ($warn_low, $warn_high, $crit_low, $crit_high) = ('','','','');
			  $monitor_reading = sprintf("%.2f", ($monitor_reading/1000));
			  
			  if (!$crit) {
				$crit  = sprintf("%.2f", ( SNMP_getvalue($snmp_session, sprintf($oid_template, 6)) / 1000 ));
				$crit .= ':' . sprintf("%.2f", ( SNMP_getvalue($snmp_session, sprintf($oid_template, 5)) / 1000 ) );
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
				  $criticals = $criticals . " $test_name=$monitor_reading";
			  } elsif ( ($monitor_reading < $warn_low) || ($monitor_reading > $warn_high) ) {
				  $warnings = $warnings . " $test_name=$monitor_reading";
			  }
		  }
		  when (2) { # Temperature
			  $monitor_unit = "C";
			  
			  if (!$crit) {
				$crit = SNMP_getvalue($snmp_session, sprintf($oid_template, 5));
			  }
			  
			  if ( $monitor_reading > $crit ) {
				  $criticals = $criticals . " $test_name=$monitor_reading";
			  }
			  elsif ( $monitor_reading > $warn ) {
				  $warnings = $warnings . " $test_name=$monitor_reading";
			  }
		  }
		}
		
		$status = $status . "$test_name=$monitor_reading;$warn;$crit;;";
		push(@desc, "$test_name=$monitor_reading$monitor_unit");
		
	} elsif ($test_name eq 'fan-speeds') {
		
		for my $monitor ( sort (keys %Fans) ) {
			
			my $oid_template = $oid_prefix."%d.".$Fans{$monitor};
			my $fan_monitored = SNMP_getvalue($snmp_session, sprintf($oid_template, 10));
			if ($fan_monitored == 0) {
				next;
			}
			
			my $monitor_reading  = SNMP_getvalue($snmp_session, sprintf($oid_template, 4));
			
			if (!$crit) {
				$crit  = SNMP_getvalue($snmp_session, sprintf($oid_template, 6));
			}
			
			if ( $monitor_reading < $crit ) {
				$criticals = $criticals . " $monitor=$monitor_reading";
			}
			elsif ( $monitor_reading < $warn ) {
				$warnings = $warnings . " $monitor=$monitor_reading";
			}
			
			$status = $status . "$monitor=$monitor_reading;$warn;$crit;;";
			push(@desc, "$monitor=${monitor_reading}RPM");
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
sub SNMP_getvalue {
	my ($snmp_session,$oid) = @_;

	my $res = $snmp_session->get_request(
			-varbindlist => [$oid]);

	if (!defined($res)) {
		$plugin->nagios_exit(UNKNOWN, "SNMP Error: " . $snmp_session->error);
	}
	
	return($res->{$oid});
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
		Perform a test of the specified monitor.
		Example:
			-T 'System Temperature'=50,60
		will give a warning if the value of the monitor reaches 50 degrees and a critical status 
		if it reaches 60 degrees celcius. For voltage monitors define the lower:upper limits of 
		the warning and critical levels.
		Example:
			--test 'CPU Core Voltage'=1.10:1.29,0.92:1.38
		Critical levels may be omitted and will be substitued by the builtin limits set by Supermicro.
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
