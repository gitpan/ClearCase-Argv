use Benchmark;

my $final = 0;

# Automatically generates an ok/nok msg, incrementing the test number.
BEGIN {
   my($next, @msgs);
   sub printok {
      push @msgs, ($_[0] ? '' : 'not ') . "ok @{[++$next]}\n";
      return !$_[0];
   }
   END {
      print "\n1..", scalar @msgs, "\n", @msgs;
   }
}

# Make sure output arrives synchronously.
select(STDERR); $| = 1; select(STDOUT); $| = 1;

use ClearCase::Argv qw(ctsystem ctqx);
$final += printok(1);

if (!`cleartool pwd -h`) {
    print qq(

******************************************************************
ClearCase::Argv is only useable if ClearCase is installed. It was
unable to figure out the install location so will not continue the
test.  You can work around this by modifying your PATH appropriately.
******************************************************************

);
    exit 0;
}

ClearCase::Argv->summary;	# start keeping stats

print qq(
************************************************************************
************************************************************************
This test script doubles as a demo of what you can do with the
ClearCase::Argv class. First, we'll run pwv to make sure you're
in a view/VOB:
************************************************************************
************************************************************************

);

my $wdv = ClearCase::Argv->new("pwv -wdview");
my $view = $wdv->qx;
chomp $view;
if ($? || !$view || $view =~ /\sNONE\s/) {
    print qq(Hmm, you're not in a view/VOB so subsequent tests will be skipped.
Unpack and "make test" within a VOB directory for full test results.
);
    exit 0;
} else {
    print "Good, you're in '$view'\n";
}

print qq(
************************************************************************
One thing we did sloppily above: we passed the command as a string,
thus defeating any chance for the module to (a) do anything smart
involving options parsing  or (b) avoid using a shell, which can have
various unfortunate side effects. So in the following lsvob command
we'll not only use a list but go further by segregating the options
part of the argv using an array ref.  This isn't necessary but is
almost always a good idea.  Let's also show how to turn on the debug
attribute:
************************************************************************

);

my $lsvob = ClearCase::Argv->new('lsvob', ['-s']);
$lsvob->dbglevel(1);
$lsvob->system;
$final += printok($? == 0);

print qq(
************************************************************************
Now we'll run an lsregion command just to show (1) how to create,
invoke, and destroy the Argv object on the fly and (2) that the debug
mode wasn't inherited since it was a mere instance attribute:
************************************************************************

);

ClearCase::Argv->new('lsregion')->system;

print qq(
************************************************************************
Next we test the functional interface, useful for those who don't
like the OO style (note that the functional interface is just
the preceding construct wrapped up in a function). We also turn
on debug output class-wide, just to show that we can:
************************************************************************

);
$final += printok($? == 0);

ClearCase::Argv->dbglevel(1);
ctsystem({-autofail=>1}, 'pwv');
$final += printok($? == 0);
my @views = ctqx('lsview');
$final += printok($? == 0);
print "You have ", scalar @views, " views in this region\n";
ClearCase::Argv->dbglevel(0);

print qq(
************************************************************************
Let's grab a list of the files in the current dir so we have something
to chew on later. While at it we'll demo the autochomp method:
************************************************************************

);

my $ls = ClearCase::Argv->new('ls', [qw(-s -nxn)]);
$ls->autochomp(1);
my @files = $ls->qx;
$final += printok($? == 0);
print "\@files = (@files)\n";

print qq(
************************************************************************
Now we use that list to demo the 'qxargs' feature - the ability to
automatically break commands into manageable chunks so as to avoid
overflowing shell or OS limits. We'll set the chunk size to 2,
which would be madness in real life but makes a good stress test.
At the same time we'll show how to easily modify the different areas
of an existing Argv object with the 'prog', 'opts', and 'args' methods:
************************************************************************

);

$ls->opts(qw(-d));
$ls->args(@files);
$ls->autochomp(0);
$ls->qxargs(2);
$ls->dbglevel(1);
print "\nResults:\n", $ls->qx, "\n";
$final += printok($? == 0);

print qq(
************************************************************************
Now we show how to turn stdout and stderr off and on in a platform-
independent way with no shell needed. These can be manipulated
class-wide or per instance:
************************************************************************

);

print "Run an lsvob command but suppress its stdout (class-wide form):\n";
ClearCase::Argv->stdout(0);	# turn stdout off
ClearCase::Argv->new(qw(lsvob))->dbglevel(1)->system;
ClearCase::Argv->stdout(1);	# turn stdout back on

print "And then a bogus cmd, suppressing the error (this instance only):\n";
ClearCase::Argv->new(qw(bogus-command))->dbglevel(1)->stderr(0)->system;

print q(
************************************************************************
Demonstrate how to use the AUTOLOAD mechanism, which allows you to
pass the cleartool command as a method name, e.g. "$obj->pwd('-s')".
************************************************************************

);

my $x = ClearCase::Argv->new({-dbglevel=>2});
$x->lslock('-s')->system;

my $reps = $ENV{CCARGV_TEST_REPS} || 50;
print qq(
************************************************************************
The following test doubles as a benchmark. It compares $reps
invocations of "cleartool lsview -l" using a fork/exec (`cmd`)
style vs $reps of the IPC::ClearTool model (if $reps is the
wrong number for your environment, you can override it with the
CCARGV_TEST_REPS environment variable).
************************************************************************

);

my $rc;
my $style = "FORK";
my($sum1, $sum2);

my $t1 = new Benchmark;
my $slow = ClearCase::Argv->new('lsview', ['-l']);
for (1..$reps) { $sum1 += unpack("%32C*", $slow->qx); $rc += $? }
print "$style: ", timestr(timediff(new Benchmark, $t1), 'noc'), "\n";
$final += printok($rc == 0);

# See if the coprocess module is available and use it if so.
ClearCase::Argv->ipc_cleartool;
$style = 'IPC ' if ClearCase::Argv->ipc_cleartool;

# The CAL CmdExec functionality was present but undocumented
# in CC 3.2.1. I've been told that it works fine except for one
# small (!) bug - the output is backward. This class method checks the
# CC version and reverses all output if it's 3.2.1. If it's <3.2.1,
# CAL is SOL; if greater this is a no-op.
ClearCase::Argv->cc_321_hack;

my $t2 = new Benchmark;
my $fast = ClearCase::Argv->new('lsview', ['-l']);
$rc = 0;
for (1..$reps) { $sum2 += unpack("%32C*", $fast->qx); $rc += $? }
print "$style: ", timestr(timediff(new Benchmark, $t2), 'noc'), "\n";
$final += printok($rc == 0);

warn "Warning: checksums differ between 1st and 2nd runs!"
						if printok($sum1 == $sum2);

print qq(
************************************************************************
With luck - if you have IPC::ChildSafe installed - you were able to
see a substantial speedup using it. I usually see multiples ranging
from 2:1 to 10:1, but this is dependent on a wide range of factors.
Next, demonstrate how to turn off the coprocess on a class-wide basis:
************************************************************************

);

print "THIS SPACE INTENTIONALLY LEFT BLANK.\n";
ClearCase::Argv->ipc_cleartool(0);		# turn off use of coprocess

print qq(
************************************************************************
Last, we'll use the 'summary' class method to see what's been done to date:
************************************************************************

);

print STDERR ClearCase::Argv->summary;	# print out the stats we kept
$final += printok(1);

print qq(
************************************************************************
And finally, remember that ClearCase::Argv is merely a subclass of Argv
which tunes it for ClearCase. See Argv's PODs for full documentation,
and see Argv's test script(s) for more demo material. We finish by
printing the pass/fail stats:
************************************************************************
);
