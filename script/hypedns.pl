#!/home/hype/perl5/perlbrew/perls/perl-5.18.0/bin/perl

# this is running as root and im tired of thiiiisss
##!/usr/bin/env perl

BEGIN { use Net::INET6Glue; }

use strict;
use Net::DNS::Resolver;
use Time::HiRes qw/time/;
use MongoDB;
use MongoDB::OID;
use MongoDB::Cursor;
use NetAddr::IP::Util qw/:ipv6/;
use IO::Socket;
use Stanford::DNS;
use Stanford::DNSserver;
use Cache::Memcached;
use utf8;

$MongoDB::Cursor::slave_okay = 1;

# mhm.  we're gonna be nice about this
my @tlds = qw/ac ad ae aero af ag ai al am an ao aq ar arpa as asia at au aw ax az ba bb bd be bf bg bh bi biz bj bm bn bo br bs bt bv bw by bz ca cat cc cd cf cg ch ci ck cl cm cn co com coop cr cu cv cw cx cy cz de dj dk dm do dz ec edu ee eg er es et eu fi fj fk fm fo fr ga gb gd ge gf gg gh gi gl gm gn gov gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in info int io iq ir is it je jm jo jobs jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mg mh mil mk ml mm mn mo mobi mp mq mr ms mt mu museum mv mw mx my mz na name nc ne net nf ng ni nl no np nr nu nz om org pa pe pf pg ph pk pl pm pn pr pro ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si sj sk sl sm sn so sr st su sv sx sy sz tc td tel tf tg th tj tk tl tm tn to tp tr travel tt tv tw tz ua ug uk us uy uz va vc ve vg vi vn vu wf ws xn--0zwm56d xn--11b5bs3a9aj6g xn--3e0b707e xn--45brj9c xn--80akhbyknj4f xn--90a3ac xn--9t4b11yi5a xn--clchc0ea0b2g2a9gcd xn--deba0ad xn--fiqs8s xn--fiqz9s xn--fpcrj9c3d xn--fzc2c9e2c xn--g6w251d xn--gecrj9c xn--h2brj9c xn--hgbk6aj7f53bba xn--hlcj6aya9esc7a xn--j6w193g xn--jxalpdlp xn--kgbechtv xn--kprw13d xn--kpry57d xn--lgbbat1ad8j xn--mgbaam7a8h xn--mgbayh7gpa xn--mgbbh1a71e xn--mgbc0a9azcg xn--mgberp4a5d4ar xn--o3cw4h xn--ogbpf8fl xn--p1ai xn--pgbs0dh xn--s9brj9c xn--wgbh1c xn--wgbl6a xn--xkc2al3hye2a xn--xkc2dl3a5ee0h xn--yfro4i67o xn--ygbi2ammx xn--zckzah xxx ye yt za zm zw localdomain/;

# do (invisible?) recursion!
my $res = Net::DNS::Resolver->new(
    nameservers => [qw(198.50.223.85 8.8.8.8 8.8.4.4)],
);

$res->persistent_tcp(1);
$res->persistent_udp(1);

# cache
our $memd = Cache::Memcached->new(
    {
        servers => [ '127.0.0.1:11211' ],
    }
);

my $db = MongoDB::Connection->new(query_timeout => 60000 * 45)->get_database('nodeinfo');
my $VERSION = "0.03";

print "[startup] NodeInfo DNS Server $VERSION " . scalar(localtime) . "\n";
# (c) 2012 Michael Gregorowicz
# server adapted from Jan-Piet Mens 
# (http://jpmens.net/2010/05/03/dns-backed-by-couchdb-redux/)

my %querytypes = (
    '1'    => 'A',
    '2'    => 'NS',
    '5'    => 'CNAME',
    '6'    => 'SOA',
    '12'    => 'PTR',
    '15'    => 'MX',
    '16'    => 'TXT',
    '28'    => 'AAAA',
    '33'    => 'SRV',
    '252'    => 'AXFR',
    '255'    => 'ANY',
    );

my %rquerytypes = map { ($querytypes{$_}, $_) } keys %querytypes;

my $ns = new Stanford::DNSserver (
    listen_on => [@ARGV],
    port      =>        53,
    defttl    =>        60,
    debug     =>         1,
    daemon    =>      "no",
    pidfile   => "/var/tmp/voodoo.pid",
    dontwait  => 1,
    logfunc   => sub { return; print shift; print "\n" },
    exitfunc  => sub {
            print "Bye! $!, $@\n";
            });

$ns->add_dynamic("" => \&handler);

# start the server loop
$ns->answer_queries();

sub handler {
    my ($domain, $host, $qtype, $qclass, $dm, $from) = @_;

    my $query_type = $querytypes{$qtype};

    print "[hypedns] start query: $host, type: $query_type, from: $from\n";
    my $start_time = time;

    #print "HOST=[$host], QUERY=[$querytypes{$qtype}] FROM=[$from]\n";

    my $ip6_ptr_resolve;
    # 5.3.5.7.0.9.2.e.0.f.7.6.4.5.5.9.d.f.f.6.c.f.1.6.5.a.a.b.d.5.c.f.ip6.arpa
    # get the ip from an arpa host if we're getting one
    if ($host =~ /^([0-9a-f\.]+)ip6\.arpa\.?/i) {
        my $rnums = lc($1);
        $rnums =~ s/\.//g;
        my $nums = reverse($rnums);
        my @sextets;
        while ($nums =~ m/([0-9a-f]{4})/g) {
            push(@sextets, $1);
        }
        $ip6_ptr_resolve = join(":", @sextets);
    }

    # host to ip, ip to host.
    my ($res_type, $node);

    if ($ip6_ptr_resolve) {
        my $cur = $db->get_collection('nodes')->find({ ip => $ip6_ptr_resolve });
        if ($cur->count > 0) {
            $res_type = "a2h";
            $node = $cur->next;
            unless ($node->{hostname}) {
                $node->{hostname} = $node->{common_name};
            }
        }
    } else {
        $host =~ s/[^A-Za-z0-9-\._]//g;
        my $h2acur = $db->get_collection('nodes')->find({ hostname => qr/^$host$/i });
        my $i2acur = $db->get_collection('nodes')->find({ common_name => qr/^$host$/i });
        my $a2hcur = $db->get_collection('nodes')->find({ ip => $host });
        if ($h2acur->count > 0) {
            $res_type = "h2a";
            $node = $h2acur->next;
        } elsif ($a2hcur->count > 0) {
            $res_type = "a2h";
            $node = $a2hcur->next;
        } elsif ($i2acur->count > 0) {
            $res_type = "i2a";
            $node = $i2acur->next;
        }
    }

    $dm->{rcode} = NOERROR;
    
    # soa!
    my $s = {
        mname => $host,
        rname => 'hostmaster@' . $host,
        serial => ref($node) ? $node->{last_check_time} : time,
        refresh => 86400,
        retry => 7200,
        expire => 3600000,
        minimum => 172800,
    };

    my $ttl = '3600';
    
    # answer soa queries
    if ($qtype == T_SOA || $qtype == T_ANY) {
        $dm->{answer} .= dns_answer(QPTR, T_SOA, C_IN, $ttl,
            rr_SOA($s->{mname}, $s->{rname}, $s->{serial},
                $s->{refresh}, $s->{retry}, $s->{expire},
                $s->{minimum}));
        $dm->{ancount} += 1;

    }

    # answer ns queries
    if ($qtype == T_NS || $qtype == T_ANY) {
        $dm->{answer} .= dns_answer(QPTR, T_NS, C_IN, $ttl, rr_NS("nodeinfo.hype"));
        $dm->{ancount} += 1;
    }

    # answer AAAA queries
    if (($qtype == T_AAAA || $qtype == T_ANY) && ($res_type eq "h2a" && !tld_conflict($host)) || $res_type eq "i2a") {
        if ($node->{ip}) {
            $dm->{answer} .= dns_answer(QPTR, T_AAAA, C_IN, $ttl, rr_AAAA(ipv6_aton($node->{ip})));
            $dm->{ancount} += 1;
        } else {
            warn "[info]: internet IPv6 host detected: $node->{common_name}\n";
        }
    } 

    # we don't answer A queries
    if (($qtype == T_A || $qtype == T_ANY) && $res_type eq "h2a") {
    #    $dm->{answer} .= dns_answer(QPTR, T_A, C_IN, $ttl, rr_A(ipv6_aton($node->{ip})));
    #    $dm->{ancount} += 1;
        $dm->{answer} .= dns_answer(dns_simple_dname($host), T_CNAME, C_IN, $ttl, dns_simple_dname($host));
        $dm->{ancount} += 1;
        $dm->{add} .= dns_answer(QPTR, T_AAAA, C_IN, $ttl, rr_AAAA(ipv6_aton($node->{ip})));
        $dm->{adcount} += 1;
    }

    # mx!
    if (($qtype == T_MX || $qtype == T_ANY) && $node->{mx}) {
        $dm->{answer} .= dns_answer(QPTR, T_MX, C_IN, $ttl,
            rr_MX(10, $node->{mx}));
        $dm->{ancount} += 1;
    }

    # no cname queries for now
    #if ($qtype == T_CNAME || $qtype == T_ANY) {
    #    $dm->{answer} .= dns_answer(QPTR, T_CNAME, C_IN, $ttl,
    #        rr_CNAME($rr->{data}));
    #    $dm->{ancount} += 1;
    #}

    # no txt queries for now
    #if (($qtype == T_TXT || $qtype == T_ANY) && $rr->{type} eq 'txt') {
    #    for my $txt (@{$rr->{data}}) {
    #        $dm->{answer} .= dns_answer(QPTR, T_TXT, C_IN, $ttl,
    #                rr_TXT($txt));
    #        $dm->{ancount} += 1;
    #    }
    #}

    # PTR for reverse lookups.
    if (($qtype == T_PTR || $res_type eq "a2h") && $node) {
        $dm->{answer} .= dns_answer(QPTR, T_PTR, C_IN, $ttl,
            rr_PTR($node->{hostname}));
        $dm->{ancount} += 1;
    }

    # If no answers available, return NXDOMAIN

    my $referred = 0;
    my $cache_hit = 0;
    if (! $dm->{ancount} ) {
        # we're going to cache these first.
        if (my $answer = get_cache("$host.$query_type")) {
            $cache_hit = 1;
            unless ($answer eq "EMPTY") {
                foreach my $answer (split(/:%:%:/, $answer)) {
                    $dm->{answer} .= $answer;
                    $dm->{ancount} += 1;
                }
            }
        } else {
            my $dnspacket = $res->query($host, $query_type); 
            if ($dnspacket) {
                # build the to_cache first.
                my @to_cache;
                my $localttl;
                foreach my $rr (sort $dnspacket->answer) {
                    # these are all answers!
                    if ($rr->type eq "A") {
                        push(@to_cache, dns_answer(QPTR, $rquerytypes{$rr->type}, C_IN, $rr->ttl, $rr->rdata));
                    } elsif ($rr->type eq "AAAA") {
                        push(@to_cache, dns_answer(QPTR, $rquerytypes{$rr->type}, C_IN, $rr->ttl, $rr->rdata));
                    } else {
                        push(@to_cache, dns_answer(dns_simple_dname($host), $rquerytypes{$rr->type}, C_IN, $rr->ttl, $rr->rdata));
                    }
                }
                
                my $to_cache_string;
                if (scalar(@to_cache)) {
                    $to_cache_string = join(':%:%:', @to_cache);
                    set_cache("$host.$query_type", $to_cache_string, 3600 * 24 * 14);
                } else {
                    $to_cache_string = "EMPTY";
                    set_cache("$host.$query_type", $to_cache_string, 3600);
                }

                unless ($to_cache_string eq "EMPTY") {
                    # for consistency!
                    foreach my $answer (split(/:%:%:/, $to_cache_string)) {
                        $dm->{answer} .= $answer;
                        $dm->{ancount} += 1;
                    }
                }
            } else {
                $dm->{rcode} = NXDOMAIN;
            }
        }
        if ($dm->{ancount}) {
            #print "[ni-dns] Query successfully referred.\n";
            $referred = 1;
        }
    }
    my $time_taken = sprintf("%.4fs", (time - $start_time));
    if ($referred) {
        if ($cache_hit) {
            print "[hypedns] end query: $host, type: $querytypes{$qtype}, from: $from [r+] $time_taken\n";# if $time_taken > 1;
        } else {
            print "[hypedns] end query: $host, type: $querytypes{$qtype}, from: $from [r] $time_taken\n";# if $time_taken > 1;
        }
    } elsif ($cache_hit) {
        print "[hypedns] end query: $host, type: $querytypes{$qtype}, from: $from [-] $time_taken\n";# if $time_taken > 1;
    } else {
        if ($dm->{ancount}) {
            print "[hypedns] end query: $host, type: $querytypes{$qtype}, from: $from [+] $time_taken\n";# if $time_taken > 1;
        } else {
            set_cache("$host.$query_type", "EMPTY", 3600);
            print "[hypedns] end query: $host, type: $querytypes{$qtype}, from: $from [not found] $time_taken\n";# if $time_taken > 1;
        }
    }
}

sub tld_conflict {
    my ($host) = @_;
    $host = lc($host);
    foreach my $tld (@tlds) {
        if ($host =~ /\.$tld$/) {
            return $tld;
        }
    }
    return undef;
}

sub get_cache {
    my ($hash) = @_;
    if (my $cached = $memd->get($hash)) {
        return $cached;
    }
    return undef;
}

sub set_cache {
    my ($hash, $to_cache, $timeout) = @_;
    $timeout = (3600 * 48) unless $timeout;
    $memd->set($hash, $to_cache, $timeout);
}

