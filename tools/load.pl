#! /usr/bin/perl

# $Header:$

# Simple script to load the driver and get it ready.

use strict;
use warnings;

use File::Basename;
use FileHandle;
use Getopt::Long;
use IO::File;
use POSIX;

my $SUDO = "setuid root";

#######################################################################
#   Command line switches.					      #
#######################################################################
my %opts = (
	here => 0,
	v => 0,
	);

sub main
{
	Getopt::Long::Configure('no_ignore_case');
	usage() unless GetOptions(\%opts,
		'fast',
		'help',
		'here',
		'v+',
		);

	usage() if ($opts{help});
	if (! -f "$ENV{HOME}/bin/setuid" ) {
		$SUDO = "sudo";
	}
	print "Syncing...\n";
	spawn("sync ; sync");
	if ( -e "/dev/dtrace" ) {
		spawn("$SUDO rmmod dtracedrv");
		spawn("sync ; sync");
	}

	#####################################################################
	#   Here  goes...we could crash the kernel... We sleep for a bit at
	#   present  since we need the /dev entries to appear. Chmod 666 so
	#   we can avoid being root all the time whilst we debug.
	#####################################################################
	print "Loading: dtracedrv.ko\n";
	spawn("$SUDO insmod dtracedrv.ko dtrace_here=$opts{here}");
        my $sectop = "/sys/module/dtracedrv/sections/";
        if ($opts{v} > 1 && -e $sectop . ".text") {
          # print KGDB module load command
          print "# KGDB:\n";
          open(IN, $sectop . ".text");
          my $line = <IN>; chomp($line);
          my $cmd = "add-symbol-file dtracedrv.ko " . $line;
          foreach my $s (".bss", ".eh_frame", ".data", ".rodata",
                         ".init.text", ".exit.text") {
            my $ss = $sectop . $s;
            if (-e $ss && open(IN, $ss)) {
              $line = <IN>; chomp($line);
              $cmd .= " -s $s " . $line;
            }
          }
          print $cmd, "\n";
        }
	sleep(1);

	mkdev("/dev/dtrace");
	mkdev("/dev/dtrace_helper");
	mkdev("/dev/fbt");
	
	###############################################
	#   Read  symbols  in  /proc/kallsyms into a  #
	#   hash				      #
	###############################################
	my $fh = new FileHandle("/proc/kallsyms");
	my %syms;
	while (<$fh>) {
		chomp;
		my $s = (split(" ", $_))[2];
		$syms{$s} = $_;
	}
	###############################################
	#   Need  to  'export'  GPL  symbols  to the  #
	#   driver  so  we can call these functions.  #
	#   Until  this  is  done,  the  driver is a  #
	#   little unsafe(!) Items below labelled as  #
	#   'optional'  are  allowed to be missing -  #
	#   we   only  ever  wanted  them  for  some  #
	#   initial  debugging,  and  dont need them  #
	#   any more.				      #
	#   					      #
	#   Colon  separated entries let us fallback  #
	#   to  an  alternate mechanism to find what  #
	#   we are after (see fbt_linux.c)	      #
	###############################################
	print "Preparing symbols...\n";
	my $err = 0;
	# Symbols we used to need, but no longer:
	# get_symbol_offset
	foreach my $s (qw/
		__symbol_get
		access_process_vm
		hrtimer_cancel
		hrtimer_init
		hrtimer_start
		kallsyms_addresses:optional
		kallsyms_lookup_name
		kallsyms_num_syms:optional
		kallsyms_op:optional
		kernel_text_address
		modules:print_modules
		sys_call_table:syscall_call
		/) {
		my $done = 0;
		foreach my $rawsym (split(":", $s)) {
			if ($rawsym eq 'optional') {
				$done = 1;
				last;
			}
			next if !defined($syms{$rawsym});
			my $fh = new FileHandle(">/dev/fbt");
			if (!$fh) {
				print "Cannot open /dev/fbt -- $!\n";
			}
                        if (1 < $opts{v}) {
                          print STDERR "echo \"$syms{$rawsym}\" > /dev/fbt\n";
                        }
                        print $fh $syms{$rawsym} . "\n" if $fh;
			$done = 1;
			last;
		}
		if (! $done) {
			print "ERROR: This kernel is missing: '$s'\n";
			$err++;
		}
	}
	if ( "$err" != 0 ) {
		print "Please do not run dtrace - your kernel is not supported.\n";
		exit(1);
	}

	#####################################################################
	#   Keep  a  copy of probes to avoid polluting /var/log/messages as
	#   we debug the driver..
	#####################################################################
	if (!$opts{fast}) {
		print "Probes available: ";
		my $pname =strftime("/tmp/probes-%Y%m%d-%H:%M", localtime);
		if ( -f "/tmp/probes.current" && ! -f $pname ) {
			if (!rename("/tmp/probes.current", "/tmp/probes.prev")) {
				print "rename error /tmp/probes.current -- $!\n";
			}
		}
		spawn("../../build/dtrace -l | tee $pname | wc -l ");
		unlink("/tmp/probes.current");
		if (!symlink($pname, "/tmp/probes.current")) {
			print "symlink($pname, /tmp/probes.current) error -- $!\n";
		}
	}
}
#####################################################################
#   If  the  /dev entries are not there then maybe we are on an old
#   kernel,   or  distro  (my  old  non-RAMfs  Knoppix  distro  for
#   instance).
#####################################################################
sub mkdev
{	my $dev = shift;

	my $name = basename($dev);
	if ( ! -e "/dev/$name" && -e "/sys/class/misc/$name/dev" ) {
		my $fh = new FileHandle("/sys/class/misc/$name/dev");
		my $dev = <$fh>;
		chomp($dev);
		$dev =~ s/:/ /;
		spawn("$SUDO mknod /dev/$name c $dev");
	}
	spawn("$SUDO chmod 666 /dev/$name");
}
sub spawn
{	my $cmd = shift;

	print $cmd, "\n" if $opts{'v'};
	system($cmd);
}

#######################################################################
#   Print out command line usage.				      #
#######################################################################
sub usage
{
	print "load.pl: load dtrace driver and prime the links to the kernel.\n";
	print "Usage: load.pl [-v] [-here] [-fast]\n";
	print "\n";
	print "Switches:\n";
	print "\n";
	print "   -v      Be more verbose about loading process (repeat for more).\n";
	print "   -fast   Dont do 'dtrace -l' after load to avoid kernel messages.\n";
	print "   -here   Enable tracing to /var/log/messages\n.";
	print "\n";
	exit(1);
}

main();
0;

