package ClearCase::Argv;

use Argv 0.41;

use strict;
use vars qw($VERSION @ISA @EXPORT_OK);
@ISA = qw(Argv);
@EXPORT_OK = (@Argv::EXPORT_OK, qw(ccsystem ccexec ccqx));
$VERSION = '0.15';

# For programming purposes we can't allow per-user preferences.
$ENV{CLEARCASE_PROFILE} = '/no/such/profile';

# Allow EV's setting class data in the derived class to override
# the base class's defaults.
for (grep !/^_/, keys %Argv::Argv) {
    (my $ev = uc(join('_', __PACKAGE__, $_))) =~ s%::%_%g;
    $Argv::Argv{$_} = $ENV{$ev} if defined $ENV{$ev};
}

# Attempt to find the definitive cleartool path at startup. But don't
# try excruciatingly hard - it would take unwarranted time. Admins
# with a really strange install can make a patch.
if ($^O !~ /win32/i) {
    $ENV{PATH} .= ':/usr/atria/bin'
			if -d '/usr/atria/bin' && $ENV{PATH} !~ m%/atria/bin%;
} else {
    for (   'C:/Program Files/Rational/ClearCase/bin',
	    'D:/Program Files/Rational/ClearCase/bin',
	    'C:/atria/bin',
	    'D:/atria/bin') {
	if (-d $_) { $ENV{PATH} .= ";$_"; last }
    }
}


# Change a prog value of q(ls) to qw(cleartool ls). If the value is
# already an array or array ref leave it alone.
sub prog {
    my $self = shift;
    my $prg = shift;
    if (@_ || ref $prg) {
	return $self->SUPER::prog($prg, @_);
    } else {
	return $self->SUPER::prog(['cleartool', $prg], @_);
    }
}

# Win32 only. CmdExec works in CC 3.2.1 but output is backwards!
# This class method determines if 3.2.1 is in use and sets an attr
# which causes the lines to be reversed.
# We could do this automatically but want to avoid penalizing 4.0+ users.
sub cc_321_hack {
    return unless $^O =~ /win32/i;
    my $self = shift;
    my $csafe = $self->ipc_childsafe;
    return $csafe->cc_321_hack if $csafe;
}

# This sets up the appropriate commands for a cleartool coprocess.
sub ipc_cleartool {
    my $self = shift;	# this might be an instance or a classname
    my $level = shift;
    my $chk;
    my @args;
    if (defined($level) && !$level) {
	return $self->ipc_childsafe(0);	# close up shop
    } else {
	$chk = sub { return int grep /Error:\s/, @{$_[0]} };
	my %params = ( CHK => $chk, QUIT => 'exit' );
	@args = ('cleartool', 'pwd -h', 'Usage: pwd', \%params);
    }
    eval { require IPC::ChildSafe };
    if (!$@) {
	local $@;
	IPC::ChildSafe->VERSION(3.06);
	if ($^O =~ /win32/i) {
	    require Win32::OLE;
	    no strict 'subs';
	    local $^W = 0;
	    package IPC::ChildSafe;
	    *IPC::ChildSafe::_open = sub {
		my $self = shift;
		$self->{IPC_CHILD} = Win32::OLE->new('ClearCase.ClearTool')
			    || die "Cannot create ClearCase.ClearTool object\n";
		Win32::OLE->Option(Warn => 0);
		return $self;
	    };
	    *IPC::ChildSafe::_puts = sub {
		my $self = shift;
		my $cmd = shift;
		my $dbg = $self->{DBGLEVEL};
		warn "+ -->> $cmd\n" if $dbg;
		my $out = $self->{IPC_CHILD}->CmdExec($cmd);
		my $error = int Win32::OLE->LastError;
		$self->{IPC_STATUS} = $error;
		# CmdExec always returns a scalar through Win32::OLE so
		# we have to split it in case it's really a list.
		my @stdout = $self->_fixup_COM_scalars($out);
		print map {"+ <<-- $_"} @stdout if @stdout && $dbg > 1;
		push(@{$self->{IPC_STDOUT}}, @stdout);
		push(@{$self->{IPC_STDERR}},
		    $self->_fixup_COM_scalars(Win32::OLE->LastError)) if $error;
		return $self;
	    };
	    *IPC::ChildSafe::finish = sub {
		my $self = shift;
		undef $self->{IPC_CHILD};
		return 0;
	    };
	} else {
	    no strict 'subs';
	    local $^W = 0;
	    package IPC::ChildSafe;
	    *_puts = sub {
		my $self = shift;
		my $cmd = shift;
		child_puts($cmd, ${$self->{IPC_CHILD}},
				   $self->{IPC_STDOUT}, $self->{IPC_STDERR});
		# Special case - throw away comment prompt from stderr.
		shift @{$self->{IPC_STDERR}} if $self->stdin &&
				${$self->{IPC_STDERR}}[0] =~ /Comment.*:$/;
		return $self;
	    };
	}
    }
    if ($@ || !defined $self->ipc_childsafe(@args)) {
	if ($level == 2 || !defined($level)) {
	    if ($@ =~ /^(Can't locate [^(]+)/) {
		$@ = "$1 - continuing in normal mode\n";
	    }
	    warn("Warning: $@");
	} elsif ($level != 1) {
	    die("Error: $@");
	}
	return undef;
    }
    return $self;
}

# The cleartool command has different quoting rules from any
# shell, so subclass the quoting method to deal with it. Not
# currently well tested with esoteric cmd lines such as mkattr.
sub quote
{
    my $self = shift;
    if (!$self->ipc_childsafe) {
	if (@_ > 2) {
	    return $self->SUPER::quote(@_);
	} else {
	    # We don't want to quote the 2nd word
	    # in the case where @_ = ('cleartool', 'pwv -s');
	    $self->SUPER::quote($_[0]);
	    return @_;
	}
    }
    if ($^O !~ /win32/i) {
	$self->optset('IPC_COMMENT');
	if (my @cmnt = $self->factor('IPC_COMMENT', [qw(c=s)], undef, \@_)) {
	    $self->ipc_childsafe->stdin("$cmnt[1]\n.");
	}
    }
    for (@_) {
	# If requested, change / for \ in Windows file paths.
	s%/%\\%g if $self->pathnorm;
	# Skip arg if already quoted ...
	next if substr($_, 0, 1) eq '"' && substr($_, -1, 1) eq '"';
	# ... or contains no special chars.
	next unless m%[*\s~?\[\]]%;
	# Now quote embedded quotes ...
	$_ =~ s%(\\*)"%$1$1\\"%g;
	# quote trailing \ so it won't quote the " ...
	s%\\{1}$%\\\\%;
	# and last the entire string.
	$_ = qq("$_");
    }
    return @_;
}

sub comment {
    my $self = shift;
    my $cmnt = shift;
    $self->dbg("setting comment to '$cmnt'");
    my $csafe = $self->ipc_childsafe;
    if ($csafe) {
	$self->opts('-cq', $self->opts);
	$csafe->stdin("$cmnt\n.");
    } else {
	$self->opts('-c', $cmnt, $self->opts);
    }
    return $self;
}

sub stdopts {
    my $self = shift;
    return $self->SUPER::stdopts(@_, 'ipc_cleartool');
}

# A hack so the Argv functional interfaces can get propagated.
*system = *Argv::system;
*exec = *Argv::exec;
*qv = *Argv::qv;

# Export our own functional interfaces as well.
sub ccsystem	{ return __PACKAGE__->new(@_)->system }
sub ccexec	{ return __PACKAGE__->new(@_)->exec }
sub ccqx	{ return __PACKAGE__->new(@_)->qx }

1;

__END__

=head1 NAME

ClearCase::Argv - ClearCase-specific subclass of Argv

=head1 SYNOPSIS

    use ClearCase::Argv;
    my $describe = ClearCase::Argv->new('desc', [qw(-fmt %c)], "filename");
    $describe->parse(qw(fmt=s));
    $describe->system;

=head1 DESCRIPTION

This is a subclass of Argv for use with ClearCase.  It basically
overrides the prog() method to recognize the fact that ClearCase
commands have two words, e.g. "cleartool checkout' or 'multitool
lsepoch'.

It also provides a special method 'ipc_cleartool' which, as the name
implies, enables use of the IPC::ClearTool module such that all
cleartool commands are run as a coprocess. Attempts to use this method
on platforms where IPC::ClearTool is not available will result in a
warning and execution will continue using traditional fork/exec.

Functionally ClearCase::Argv is identical to its base class, so see
"perldoc Argv" and/or "perldoc IPC::ChildSafe" for all other
documentation.

=head1 BUGS

I believe there are still some special I<cleartool> quoting situations
unaccounted for in the C<quote> method. This will need to be refined
over time. Patches gratefully accepted.

=head1 PORTABILITY

This module should work on all ClearCase platforms. It was primarily
tested on Solaris 7 and NT 4.0, with CC 3.2.1 and 4.0.

=head1 AUTHOR

David Boyce <dsb@world.std.com>

Copyright (c) 1999,19100 David Boyce. All rights reserved.  This Perl
program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

perl(1), Argv, IPC::ClearTool, IPC::ChildSafe

=cut
