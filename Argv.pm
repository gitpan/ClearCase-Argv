package ClearCase::Argv;

$VERSION = '0.21';

use Argv 0.50 qw(MSWIN);

@ISA = qw(Argv);
@EXPORT_OK = (@Argv::EXPORT_OK, qw(ctsystem ctexec ctqx ctqv));

use strict;

# For programming purposes we can't allow per-user preferences.
$ENV{CLEARCASE_PROFILE} = '/Over/Ridden/by/ClearCase/Argv';

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
    my $self = shift;
    return unless MSWIN;
    my $csafe = $self->ipc_childsafe;
    return $csafe->cc_321_hack(@_) if $csafe;
}

# Starts or stops a cleartool coprocess.
sub ipc_cleartool {
    my $self = shift;	# this might be an instance or a classname
    my $level = shift;
    if (defined($level) && !$level) {
	return $self->ipc_childsafe(0);	# close up shop
    } elsif (!defined($level) && defined(wantarray)) {
	return $self->ipc_childsafe; # return the active ChildSafe object
    }
    my $chk = sub { return int grep /Error:\s/, @{$_[0]} };
    my %params = ( CHK => $chk, QUIT => 'exit' );
    my @args = ($ct, 'pwd -h', 'Usage: pwd', \%params);
    eval { require IPC::ChildSafe };
    if (!$@) {
	local $@;
	IPC::ChildSafe->VERSION(3.10);
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
		my $dbg = $self->{DBGLEVEL} || 0;
		warn "+ -->> $cmd\n" if $dbg;
		my $out = $self->{IPC_CHILD}->CmdExec($cmd);
		# CmdExec always returns a scalar through Win32::OLE so
		# we have to split it in case it's really a list.
		if ($out) {
		    my @stdout = $self->_fixup_COM_scalars($out);
		    push(@{$self->{IPC_STDOUT}}, @stdout);
		    print STDERR map {"+ <<-- $_"} @stdout if $dbg > 1;
		}
		if (my $err = Win32::OLE->LastError) {
		    $err =~ s/OLE exception from.*?:\s*//;
		    my @stderr = $self->_fixup_COM_scalars($err);
		    @stderr = grep !/Unspecified error/is, @stderr;
		    print STDERR map {"+ <<== $_"} @stderr if $dbg > 1;
		    push(@{$self->{IPC_STDERR}},
				    map {"cleartool: Error: $_"} @stderr);
		}
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
	if (!defined($level) || $level == 2) {
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
    # Ok, now we're looking at interactive-cleartool quoting ("man cleartool").
    if (!MSWIN) {
	# Special case - extract multiline comments from the cmd line and
	# put them in the stdin stream when using UNIX co-process model.
	for (my $i=0; $i < $#_; $i++) {
	    if ($_[$i] eq '-c' && $_[$i+1] =~ m%\n%s) {
		$self->ipc_childsafe->stdin("$_[$i+1]\n.");
		splice(@_, $i, 2, '-cq');
		last;
	    }
	}
    }
    for (@_) {
	# If requested, change / for \ in Windows file paths.
	s%/%\\%g if $self->inpathnorm;
	# Special case - turn internal newlines back to literal \n
	s%\n%\\n%g if !MSWIN;
	# Skip arg if already quoted ...
	next if m%^".*"$%s;
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
    my $csafe = $self->ipc_childsafe;
    my @prev = $self->opts;
    if ($csafe) {
	$self->opts('-cq', $self->opts) if !grep /^-cq/, @prev;
	$csafe->stdin("$cmnt\n.");
    } else {
	$self->opts('-c', $cmnt, $self->opts) if !grep /^-c/, @prev;
    }
    return $self;
}

# Add -/ipc_cleartool to list of supported attr-flags.
sub attropts {
    my $self = shift;
    return $self->SUPER::attropts(@_, 'ipc_cleartool');
}
*stdopts = \&attropts;		# backward compatibility

# A hack so the Argv functional interfaces can get propagated.
*system = \&Argv::system;
*exec = \&Argv::exec;
*qv = \&Argv::qv;
*MSWIN = \&Argv::MSWIN;

# Export our own functional interfaces as well.
sub ctsystem	{ return __PACKAGE__->new(@_)->system }
sub ctexec	{ return __PACKAGE__->new(@_)->exec }
sub ctqx	{ return __PACKAGE__->new(@_)->qx }
*ctqv = \&ctqx;  # just for consistency

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
    use ClearCase::Argv qw(ctsystem ctexec ctqx);
    ctsystem('pwv');
    my @lsco = ctqx(qw(lsco -avobs -s));
    # Similar to OO example: create label type iff it doesn't exist
    ctsystem(qw(mklbtype XX)) if !ctqx({stderr=>0}, "lstype lbtype:XX");

I<There are more examples in the ./examples subdir that comes with this
module. Also, the test script is designed as a demo and benchmark;
it's probably your best source for cut-and-paste code.>

=head1 DESCRIPTION

This is a subclass of I<Argv> for use with ClearCase.  It basically
overrides the prog() method to recognize the fact that ClearCase
commands have two words, e.g. "cleartool checkout".

It also provides a special method C<'ipc_cleartool'> which, as the name
implies, enables use of the IPC::ClearTool module such that subsequent
cleartool commands are sent to a coprocess.

I<ClearCase::Argv is otherwise identical to its base class, so see
"perldoc Argv" for substantial further documentation.>

=head1 IPC::ClearTool INTERFACE

The C<'ipc_cleartool'> method creates an IPC::ClearTool object and
sends subsequent commands to it. This method is highly
context-sensitive:

=over 4

=item *

When called with no arguments and a non-void context, it returns the
underlying ClearTool object (in case you want to use it directly).

=item *

When called with a non-zero argument it creates a ClearTool object; if
this fails for any reason a warning is printed and execution continues
in 'normal mode'. The warning may be suppressed or turned to a fatal
error by specifying different true values; see examples below.

=item *

When called with an argument of 0, it shuts down any existing
ClearTool object; any further executions would revert to 'normal mode'.

=back

=head2 Examples

    # use IPC::ClearTool if available, else continue silently
    ClearCase::Argv->ipc_cleartool(1);
    # use IPC::ClearTool if available, else print warning and continue
    ClearCase::Argv->ipc_cleartool(2);
    # same as above since default == 2
    ClearCase::Argv->ipc_cleartool;
    # use IPC::ClearTool, die if not available
    ClearCase::Argv->ipc_cleartool(3);
    # shut down the IPC::ClearTool coprocess
    ClearCase::Argv->ipc_cleartool(0);
    # Use the IPC::ClearTool object directly
    ClearCase::Argv->ipc_cleartool->cmd('pwv');

Typically C<ipc_cleartool> will be used as a class method to specify a
place for all cleartool commands to be sent. However, it may also be
invoked on an object to associate just that instance with a coprocess.

=head1 FUNCTIONAL INTERFACE

For those who don't like OO style, or who want to convert existing
scripts with the least effort, the I<execution methods> are made
available as traditional functions. Examples:

	use ClearCase::Argv qw(ctsystem ctexec ctqx);
	my $cwv = ctqx(pwv -s);
	ctsystem('mklbtype', ['-global'], 'FOO') && exit $?>>8;
	my @vobs = ctqx({autochomp=>1}, 'lsvob -s');

If you prefer you can override the "real" Perl builtins. This is
easier for converting an existing script which makes heavy use of
C<system(), exec(), or qx()>:

	use ClearCase::Argv qw(system exec qv);
	my $cwv = qv(cleartool pwv -s);
	system('cleartool', 'mklbtype', ['-global'], 'FOO') && exit $?>>8;
	my @vobs = qv({autochomp=>1}, 'lsvob -s');

Note that when using an overridden C<system()> et al you must still
specify 'cleartool' as the program, whereas C<ctsystem()> and friends
handle that.

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
pushed on a stack and popped off after being read once. This applies to
both class and instance uses. It's done this way to allow the following
locutions:

    ClearCase::Argv->stdout(0);	# turn off stdout for all objects
    $obj->stdout(0);		# turn off stdout for this object, forever
    $obj->stdout(0)->system;	# suppress stdout, this time only

This allows you to set up an object with various sticky attributes and
keep it around, executing it at will and overriding other attrs
temporarily. In the example below, note that another way of setting
sticky attrs is shown:

    my $obj = ClearCase::Argv->new({autofail=>1, autochomp=>1});
    my $view = $obj->argv('pwv -s')->qx;
    my $exists = $obj->argv('lstype', 'brtype:FOO')->autofail(0)->qx;

Here we keep an object with attrs 'autochomp' and 'autofail' (autofail
means to exit on any failure) around and use it to exec whichever
commands we want. While checking to see if a type exists, we suppress
autofail temporarily. On the next use the object will have both
attributes again.

=head1 BUGS

I suspect there are still some special quoting situations unaccounted
for in the I<quote> method. This will need to be refined over time. Bug
reports or patches gratefully accepted.

=head1 PORTABILITY

ClearCase::Argv should work on all ClearCase platforms. It's primarily
tested on Solaris 7 and NT 4.0, with CC 3.2.1 and 4.0, using Perl5.004
and 5.005. The CAL stuff doesn't work with CC <3.2.1.

=head1 FILES

The module is a subclass of I<Argv> and thus requires it to be installed.
If running in I<ipc mode> it will also need IPC::ClearTool.

=head1 SEE ALSO

perl(1), Argv, IPC::ClearTool, IPC::ChildSafe

=head1 AUTHOR

David Boyce <dsb@world.std.com>

=head1 COPYRIGHT

Copyright (c) 1999,19100 David Boyce. All rights reserved.  This Perl
program is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
