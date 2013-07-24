#!/usr/bin/env perl
use IO::Socket::INET;

#
# TO USE: please /msg your SSH Public Key to Mikey_ on EFnet.
# Please cron this script hourly.
# 0 * * * * /path/to/rtdump.pl 2>&1 > /dev/null
#

my $hostname = `uname -n`;
chomp($hostname);

# for people running the admin server on other ports / hosts
my $host_port = $ARGV[0];
my ($host, $port) = split(/:/, $host_port);
$port = 11234 unless $port;
$host = "localhost" unless $host;

my $rtfile = "/tmp/cjdroute.$hostname";

open(RTFILE, '>', $rtfile);
print RTFILE cjdrouting_table($host,$port);
close(RTFILE);

system("scp -q $rtfile " . "rtdump\@\[fc5d:baa5:61fc:6ffd:9554:67f0:e290:7535\]" . ":/var/rtdump");

unlink($rtfile);

print "\n      Mmmmmm... routes!  My Favorite!\n";
print "                               -NodeInfo\n\n";

sub cjdrouting_table {
    my ($host, $port) = @_;

    my $s = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto => 'tcp',
        Type => SOCK_STREAM) or die "can't connect to localhost:$port $!\n";

    print $s "d1:q19:NodeStore_dumpTable4:txid4:....e\n";

    my $encoded;
    while (my $line = <$s>) {
        $encoded .= $line;
        last if $line =~ /\.\.\.\.e/;
    }
    $s->close();

    # strip off trailing whitespace.
    $encoded =~ s/[\r\n]+$//g;

    return $encoded;
}

