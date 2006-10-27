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

************************************************************************
ClearCase::Argv is only useable when ClearCase is installed.
ClearCase could not be found so testing will not continue. If you
really do have ClearCase installed you may need to add it to PATH.
************************************************************************

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

my $wdv = ClearCase::Argv->new("pwv -wdview -s");
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
One thing we did sloppily above: we passed the command as a string
("pwv -wdview -s"), thus defeating any chance for the module to (a) do
anything intelligent with options parsing or (b) avoid using a shell,
which can have various unfortunate side effects. So in the following
lsvob command we'll not only use a list but go further by segregating
the options part of the argv using an array ref.  This isn't necessary
but is almost always a good idea.  Let's also show how to turn on the
debug attribute:
************************************************************************

);

my $lsvob = ClearCase::Argv->new('lsvob', ['-s']);
$lsvob->dbglevel(1);
$lsvob->system;
$final += printok($? == 0);

print qq(
************************************************************************
Now we'll run an lsregion command just to show (1) how to create,
invoke, and destroy an Argv object on the fly and (2) that the debug
mode wasn't inherited since it was a mere instance attribute:
************************************************************************

);

ClearCase::Argv->new('lsregion')->system;

print qq(
************************************************************************
Next we test the functional interface, useful for those who don't
like the OO style (note that the functional interface is just
the preceding construct wrapped up in a function). We also toggle
debug output class-wide, just to show that we can:
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

$ls->prog('ls');	# redundant setting
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

my $x = ClearCase::Argv->new({-dbglevel=>1});
$x->lslock('-s')->system;

print "\n\tTHIS SPACE INTENTIONALLY LEFT BLANK :-)\n";

my $reps = $ENV{CCARGV_TEST_REPS} || 50; print qq(
************************************************************************
The following test doubles as a benchmark. It compares $reps
invocations of "cleartool lsview -s" using a fork/exec (`cmd`) style
vs $reps using the ClearCase::CtCmd (in-process) and IPC::ClearTool
(co-process) models, if those modules are installed. If not, it will
fall back to fork/exec.  If $reps is the wrong number for your
environment, you can override it with the CCARGV_TEST_REPS environment
variable.
************************************************************************

);

my($rc, $sum1, $sum2, $sum3);

my $t1 = new Benchmark;
my $slow = ClearCase::Argv->new('lsview', ['-s'], $view);
for (1..$reps) { $sum1 += unpack("%32C*", $slow->qx); $rc += $? }
print ClearCase::Argv->exec_style, " : ";
print timestr(timediff(new Benchmark, $t1), 'noc'), "\n";
$final += printok($rc == 0);

# See if the coprocess module is available and try it if so.
if (ClearCase::Argv->ipc(1)) {
    my $t2 = new Benchmark;
    my $fast = ClearCase::Argv->new('lsview', ['-s'], $view);
    $rc = 0;
    for (1..$reps) { $sum2 += unpack("%32C*", $fast->qx); $rc += $? }
    print ClearCase::Argv->exec_style, " : ";
    print timestr(timediff(new Benchmark, $t2), 'noc'), "\n";
    ClearCase::Argv->ipc(0);		# turn off use of coprocess
    $final += printok($rc == 0);
    warn "Warning: output differs between FORK and IPC runs!"
						    if printok($sum1 == $sum2);
}

# See if the ClearCase::CtCmd module is available and try it if so.
if (ClearCase::Argv->ctcmd(1)) {
    my $t3 = new Benchmark;
    my $api = ClearCase::Argv->new('lsview', ['-s'], $view);
    $rc = 0;
    for (1..$reps) { $sum3 += unpack("%32C*", $api->qx); $rc += $? }
    print ClearCase::Argv->exec_style, " : ";
    print timestr(timediff(new Benchmark, $t3), 'noc'), "\n";
    ClearCase::Argv->ctcmd(0);		# turn off use of CtCmd
    $final += printok($rc == 0);
    warn "Warning: output differs between FORK and CTCMD runs!"
						if printok($sum1 == $sum3);
}

print qq(
************************************************************************
With luck, if you have ClearCase::CtCmd or IPC::ChildSafe installed,
you were able to see a substantial speedup using them. I usually see
multiples ranging from 50% to 10:1, but this is dependent on a wide
range of factors.
************************************************************************

************************************************************************
One interesting use case occurs when you want to run a command that can
take a lot of time and/or generate a lot of output, but there's a good
chance you'll find what you're looking for early and can abort the
command at that time. Or you may only need to keep a small subset of
text received and thus save a lot of memory. In these cases the ->pipe
method with an accompanying callback function may be the best choice.
Here's a demo of a potentially very long-running command which we abort
after receiving a maximum of 10 lines of output.
************************************************************************

);

my $t4 = new Benchmark;
my $thruPipe = ClearCase::Argv->new('find', ['-all', '-type', 'd', '-print']);
$thruPipe->readonly('yes');
my $counter = 10;
# Define the callback which will end the pipe early.
$thruPipe->pipecb(sub { return --$counter; });
print "Using ->pipe and aborting after max 10 lines...\n";
$thruPipe->pipe;
print "  " . timestr(timediff(new Benchmark, $t4), 'noc'), "\n";
$final += printok(1);

print qq(
************************************************************************
NOTE: in a very small vob, the results above may be in favor of qx due
to the fact that pipe introduces some overhead (particularly on Windows).

Last, we'll use the 'summary' class method to see what cmds were run:
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
