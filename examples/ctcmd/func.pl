use ClearCase::CtCmd qw(cleartool);

# Returns an array containing three scalars: (exit status, stdout, stderr)
my @results = cleartool('pwv');

# Now distribute stdout to stdout, stderr to stderr, and return the exit code.
print STDOUT $results[1];
print STDERR $results[2];
exit $results[0];
