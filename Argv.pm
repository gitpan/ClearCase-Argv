package ClearCase::Argv;

use Argv 0.47 qw(MSWIN);

use strict;
use vars qw($VERSION @ISA @EXPORT_OK);
@ISA = qw(Argv);
@EXPORT_OK = (@Argv::EXPORT_OK, qw(ccsystem ccexec ccqx ccqv));
$VERSION = '0.18';

# For programming purposes we can't allow per-user preferences.
$ENV{CLEARCASE_PROFILE} = '/overridden/by/ClearCase/Argv';

# Allow EV's setting class data in the derived class to override
# the base class's defaults.There's probably a better way.
for (grep !/^_/, keys %Argv::Argv) {
    (my $ev = uc(join('_', __PACKAGE__, $_))) =~ s%::%_%g;
    $Argv::Argv{$_} = $ENV{$ev} if defined $ENV{$ev};
}

my $ct = 'cleartool';

# Attempt to find the definitive ClearCase bin path at startup. Don't
# try excruciatingly hard - it would take unwarranted time. And don't
# do so at all if running setuid or as root. If this doesn't work,
# the path can be set explicitly via the 'cleartool' class method.
if (!MSWIN && ($< == 0 || $< != $>)) {
    $ct = '/usr/atria/bin/cleartool';	# running setuid or as root
} elsif ($ENV{PATH} !~ m%\W(atria|clearcase)\Wbin\b%i) {
    if (!MSWIN) {
	my $abin = $ENV{ATRIAHOME} ? "$ENV{ATRIAHOME}/bin" : '/usr/atria/bin';
	$ENV{PATH} .= ":$abin" if -d $abin && $ENV{PATH} !~ m%/atria/bin%;
    } else {
	for (   "$ENV{ATRIAHOME}/bin",
		'C:/Program Files/Rational/ClearCase/bin',
		'D:/Program Files/Rational/ClearCase/bin',
		'C:/atria/bin',
		'D:/atria/bin') {
	    if (-d $_ && $ENV{PATH} !~ m%$_%) {
		$ENV{PATH} .= ";$_";
		last;
	    }
	}
    }
}

# Class method to specify the location of 'cleartool'.
sub cleartool { (undef, $ct) = @_ }

# Change a prog value of q(ls) to qw(cleartool ls). If the value is
# already an array or array ref leave it alone. Same thing if the 1st
# word contains /cleartool/.
sub prog {
    my $self = shift;
    my $prg = shift;
    if (@_ || ref($prg) || $prg =~ /cleartool/) {
	return $self->SUPER::prog($prg, @_);
    } else {
	return $self->SUPER::prog([$ct, $prg], @_);
    }
}

# Win32 only. CmdExec works in CC 3.2.1 but output is backwards!
# This class method determines if 3.2.1 is in use and sets an attr
# which causes the lines to be reversed.
# We could do this automatically but want to avoid penalizing 4.0+ users.
# This method is defined but a no-op on UNIX.
sub cc_321_hack {
    return unless MSWIN;
    my $self = shift;
    my $csafe = $self->ipc_childsafe;
    return $csafe->cc_321_hack if $csafe;
}

# Starts or stops a cleartool coprocess.
sub ipc_cleartool {
    my $self = shift;	# this might be an instance or a classname
    my $level = shift;
    my($chk, @args);
    if (defined($level) && !$level) {
	return $self->ipc_childsafe(0);	# close up shop
    } else {
	$chk = sub { return int grep /Error:\s/, @{$_[0]} };
	my %params = ( CHK => $chk, QUIT => 'exit' );
	@args = ($ct, 'pwd -h', 'Usage: pwd', \%params);
    }
    eval { require IPC::ChildSafe };
    if (!$@) {
	local $@;
	IPC::ChildSafe->VERSION(3.08);
	if (MSWIN) {
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
		my @stdout = $self->_fixup_COM_scalars($out) if $out;
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
## THIS STUFF IS REALLY COMPLEX WITH ALL THE PERMUTATIONS
## OF PLATFORMS AND API'S. WATCH OUT.
sub quote
{
    my $self = shift;
    # Don't quote the 2nd word where @_ = ('cleartool', 'pwv -s');
    return @_ if @_ == 2;
    # If IPC::ChildSafe not in use, protect against the shell.
    return $self->SUPER::quote(@_) if @_ > 2 && !$self->ipc_childsafe;
    # Special case - extract comments and place them in stdin stream
    # when using UNIX co-process model.
    if (!MSWIN) {
	$self->optset('IPC_COMMENT');
	if (my @cmnt = $self->factor('IPC_COMMENT', [qw(c=s)], undef, \@_)) {
	    $self->ipc_childsafe->stdin("$cmnt[1]\n.");
	}
    }
    # Ok, now we're looking at interactive-cleartool quoting ("man cleartool").
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

# Hack - allow a comment to be registered here. The next command will
# see it with -c "comment" if in regular mode or -cq and reading the
# comment from stdin if in ipc_cleartool mode.
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

# Add -/ipc_cleartool to list of supported attr-flags.
sub attropts {
    my $self = shift;
    return $self->SUPER::attropts(@_, 'ipc_cleartool');
}
*stdopts = *attropts;		# backward compatibility

# A hack so the Argv functional interfaces can get propagated.
*system = *Argv::system;
*exec = *Argv::exec;
*qv = *Argv::qv;
*MSWIN = *Argv::MSWIN;

# Export our own functional interfaces as well.
sub ccsystem	{ return __PACKAGE__->new(@_)->system }
sub ccexec	{ return __PACKAGE__->new(@_)->exec }
sub ccqx	{ return __PACKAGE__->new(@_)->qx }
*ccqv = *ccqx;  # just for consistency

1;

__END__

=head1 NAME

ClearCase::Argv - ClearCase-specific subclass of Argv

=head1 SYNOPSIS

    # OO interface
    use ClearCase::Argv;
    ClearCase::Argv->dbglevel(1);
    # Note how the command, flags, and arguments are separated ...
    my $describe = ClearCase::Argv->new('desc', [qw(-fmt %c)], ".");
    # Run the basic "ct describe" command.
    $describe->system;
    # Run it with with stderr turned off.
    $describe->stderr(0)->system;
    # Run it without the flags.
    $describe->system(-);
    # Create label type iff it doesn't exist
    ClearCase::Argv->new(qw(mklbtype -nc XX))
		if ClearCase::Argv->new(qw(lstype lbtype:XX))->stderr(0)->qx;

    # functional interface
    use ClearCase::Argv qw(ccsystem ccexec ccqx);
    ccsystem('pwv');
    my @lsco = ccqx(qw(lsco -avobs -s));
    # Similar to OO example: create label type iff it doesn't exist
    ccsystem(qw(mklbtype -nc XX)) if !ccqx({stderr=>0}, "lstype lbtype:XX");

B<There are more examples in the ./examples subdir that comes with this
module. Also, the test script is designed as a demo and benchmark;
it's probably your best source for cut-and-paste code.

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
"perldoc Argv" for substantial further documentation.

=head1 FUNCTIONAL INTERFACE

For those who don't like OO style, or who want to convert existing
scripts with the least effort, the I<execution methods> are made
available as traditional functions. Examples:

	use ClearCase::Argv qw(ccsystem ccexec ccqx);
	my $cwv = ccqx(pwv -s);
	ccsystem('mklbtype', ['-global'], 'FOO') && exit $?>>8;
	my @vobs = ccqx({autochomp=>1}, 'lsvob -s');

or if you prefer you can override the "real" Perl builtins. This
is easier for converting a script which already uses system(), exec(),
or qx() a lot:

	use ClearCase::Argv qw(system exec qv);
	my $cwv = qv(cleartool pwv -s);
	system('cleartool', 'mklbtype', ['-global'], 'FOO') && exit $?>>8;
	my @vobs = qv({autochomp=>1}, 'lsvob -s');

Note that when using an overridden system() et al you must still specify
'cleartool' as the program, whereas ccsystem() and friends handle that.

=head1 CAREFUL PROGRAMMERS WANTED

If you're the kind of programmer who tends to execute whole strings
such as C<system("cleartool pwv -s")> or who uses backquotes in a void
context, this module won't help you much. These are bad habits
regardless of whether you use ClearCase::Argv and you should strive to
overcome them.

=head1 STICKINESS

A subtlety: when an execution attribute is set in a void context, it's
I<"sticky">, meaning that it's set until explicitly reset. But in a
non-void context the new value is temporary or I<"non-sticky">; it's
pushed on a stack and popped off after being used once. This applies to
both class and instance uses. It's done this way to allow the following
locutions:

    ClearCase::Argv->stdout(0);	# turns off stdout for all objects
    $obj->stdout(0);		# turns off stdout for this object, forever
    $obj->stdout(0)->system;	# suppresses stdout, this time only

Which allows you to set up an object with some sticky attributes and
keep it around, executing it at will and overriding other attrs
temporarily. In the example below, note that another way of setting
sticky attrs is shown:

    my $obj = ClearCase::Argv->new({autofail=>1, autochomp=>1});
    my $view = $obj->cmd('pwv -s')->qx;
    my $exists = $obj->cmd('lstype', 'brtype:FOO')->autofail(0)->qx;

Here we keep an object with attrs 'autofail' and 'autochomp' around
and use it to exec whatever commands we want (autofail means to
exit on any failure), but we suppress the autofail attr when
we're just looking to see if a type exists yet.

=head1 BUGS

I suspect there are still some special I<cleartool> quoting situations
unaccounted for in the C<quote> method. This will need to be refined
over time. Bug reports or patches gratefully accepted.

=head1 PORTABILITY

This module should work on all ClearCase platforms. It's primarily
tested on Solaris 7 and NT 4.0, with CC 3.2.1 and 4.0, using Perl5.004
and 5.005. The CAL stuff doesn't work with CC <3.2.1.

=head1 AUTHOR

David Boyce <dsb@world.std.com>

Copyright (c) 1999,19100 David Boyce. All rights reserved.  This Perl
program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

perl(1), Argv, IPC::ClearTool, IPC::ChildSafe

=cut
