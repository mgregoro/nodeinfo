package NodeInfo::Node;
use Mojo::Base 'Mojolicious::Controller';
use Bencode qw(bencode bdecode);
use IO::Socket;
use Data::UUID;

# for making sure there's no tld conflict
my @tlds = qw/ac ad ae aero af ag ai al am an ao aq ar arpa as asia at au aw ax az ba bb bd be bf bg bh bi biz bj bm bn bo br bs bt bv bw by bz ca cat cc cd cf cg ch ci ck cl cm cn co com coop cr cu cv cw cx cy cz de dj dk dm do dz ec edu ee eg er es et eu fi fj fk fm fo fr ga gb gd ge gf gg gh gi gl gm gn gov gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in info int io iq ir is it je jm jo jobs jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mg mh mil mk ml mm mn mo mobi mp mq mr ms mt mu museum mv mw mx my mz na name nc ne net nf ng ni nl no np nr nu nz om org pa pe pf pg ph pk pl pm pn pr pro ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si sj sk sl sm sn so sr st su sv sx sy sz tc td tel tf tg th tj tk tl tm tn to tp tr travel tt tv tw tz ua ug uk us uy uz va vc ve vg vi vn vu wf ws xn--0zwm56d xn--11b5bs3a9aj6g xn--3e0b707e xn--45brj9c xn--80akhbyknj4f xn--90a3ac xn--9t4b11yi5a xn--clchc0ea0b2g2a9gcd xn--deba0ad xn--fiqs8s xn--fiqz9s xn--fpcrj9c3d xn--fzc2c9e2c xn--g6w251d xn--gecrj9c xn--h2brj9c xn--hgbk6aj7f53bba xn--hlcj6aya9esc7a xn--j6w193g xn--jxalpdlp xn--kgbechtv xn--kprw13d xn--kpry57d xn--lgbbat1ad8j xn--mgbaam7a8h xn--mgbayh7gpa xn--mgbbh1a71e xn--mgbc0a9azcg xn--mgberp4a5d4ar xn--o3cw4h xn--ogbpf8fl xn--p1ai xn--pgbs0dh xn--s9brj9c xn--wgbh1c xn--wgbl6a xn--xkc2al3hye2a xn--xkc2dl3a5ee0h xn--yfro4i67o xn--ygbi2ammx xn--zckzah xxx ye yt za zm zw/;

sub list_ni_tlds {
    my ($self) = @_;
    my $nl = $self->nl;
    my $tlds;
    foreach my $node ($nl->nodes_paged(1, $nl->count)) {
        next unless $node->hostname;
        my @dc = split(/\./, $node->hostname);
        $tlds->{lc($dc[$#dc])}++;
    }
    $self->render(text => "<pre>" . join("\n", keys %$tlds) . "</pre>");
}

# This action will render a template
sub list {
    my ($self) = @_;

    my $nl = $self->nl;
    
    if ($self->param('page') && $self->param('httponly')) {
        my $npp;
        if ($self->param('npp')) {
            $npp = "&npp=" . $self->param('npp');
        }
        if ($self->param('page') > $nl->nodes_pages($self->param('npp') || 10, 1)) {
            my $dest_string = "/nodes/list/" . $nl->nodes_pages($self->param('npp') || 10, 1) . "?httponly=1$npp";
            my ($base) = $self->req->url->base =~ /^([^,]+),/;
            $self->redirect_to($base . $dest_string);
            #$self->redirect_to("/nodes/list/" . $nl->nodes_pages($self->param('npp') || 10, 1) . "?httponly=1$npp");
            return;
        }
    }

    $self->respond_to(
        json => sub {
            if ($self->param('ips_only')) {
                if ($self->param('httponly')) {
                    $self->render(json => {
                        nodes => [map { ($_->ip, $_->name) } $nl->nodes_paged(1, $nl->count, $self->param('httponly'))],
                    });
                } else {
                    $self->render(json => {
                        nodes => [map { ($_->ip, $_->name) } $nl->nodes],
                    });
                }
            } else {
                $self->render(json => {
                    nodes => [$nl->nodes_as_hashrefs($self->param('everything'))],
                });
            }
        },
        html => sub {
            $self->render(
                nl => $nl,
            );
        },
    );

}

# TODO GET RID OF THIS IT STILL EXISTS!@#!@ it's in $self.
sub remote_ip {
    my ($self) = @_;
    
    my $ip;
    unless ($ip = $self->req->headers->header('X-Real-IP')) {
        $ip = $self->tx->remote_address;
    }
    if ($ip =~ /^[\.0-9]+$/) {
        return $ip;
    } elsif ($ip =~ /^[0-9a-f\:]+$/i) {
        return join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));
    } else {
        return undef;
    }
}

sub set_myhostname {
    my ($self) = @_;
    my $remote_ip = $self->remote_ip;
    my $nl = $self->nl;
    my $db = $self->db;

    if ($self->req->headers->referrer) {
        $self->render(text => '_WHY YOU GOTTA GO FOR THE GROIN_');
        return;
    }

    my $node = $nl->node($remote_ip);

    unless ($node) {
        # we make a new one if it's up!
        my $ping = `/bin/ping6 -W 1 -c 1 $remote_ip | /bin/grep time=`;
        my ($ptime) = $ping =~ /time=([\d\.]+ \w+)/;
        warn "[autoviv]: $remote_ip ping responded in $ptime\n";
        if ($ptime) {
            # generate a "name" from the last 4
            my @c = split(/:/, $remote_ip);
            my $common_name = $c[$#c];

            # ok so now we generate one.
            my $db = $self->db;
            my $id = $db->get_collection('nodes')->insert(
                {
                    ip => $remote_ip,
                    ping => $ptime,
                    common_name => $common_name,
                    link_quality => 0,
                }
            );

            $node = NodeInfo::Data::Node->new($db->get_collection('nodes')->find_one({ _id => $id }));
        }
    }

    if ($node) {
        # check for collisions.

        if (my $hostname = $self->param('hostname')) {
            my $cur = $db->get_collection('nodes')->find({hostname => qr/^$hostname$/i});
            if ($cur->count > 1) {
                $self->render(text => '_OH GOD NO MULTIPLE DUPES OH MAN THIS SUCKS SO BAD_');
                return;
            } elsif ($cur->count == 1) {
                my $nodedb = $cur->next;
                if ($nodedb->{ip} eq $remote_ip) {
                    $node->db->{hostname} = $hostname;
                    $self->render(text => $hostname);
                } else {
                    $self->render(text => '_HOSTNAME NOT AVAILABLE_');
                    return;
                }
            } else {
                $node->db->{hostname} = $hostname;
                $self->render(text => $hostname);
            }
        }

        $node->db->{hostname} = $self->param('hostname');
        $db->get_collection('nodes')->save($node->db);
        $self->render(text => $self->param('hostname'));
    } else {
        $self->render(text => '_NODE NOT FOUND_');
    }
}

sub get_myhostname {
    my ($self) = @_;
    my $remote_ip = $self->remote_ip;
    my $nl = $self->nl;
    my $db = $self->db;
    my $node = $nl->node($remote_ip);

    unless ($node) {
        # we make a new one if it's up!
        my $ping = `/bin/ping6 -W 1 -c 1 $remote_ip | /bin/grep time=`;
        my ($ptime) = $ping =~ /time=([\d\.]+ \w+)/;
        warn "[autoviv]: $remote_ip ping responded in $ptime\n";
        if ($ptime) {
            # generate a "name" from the last 4
            my @c = split(/:/, $remote_ip);
            my $common_name = $c[$#c];

            # ok so now we generate one.
            my $db = $self->db;
            my $id = $db->get_collection('nodes')->insert(
                {
                    ip => $remote_ip,
                    ping => $ptime,
                    common_name => $common_name,
                    link_quality => 0,
                }
            );

            $node = NodeInfo::Data::Node->new($db->get_collection('nodes')->find_one({ _id => $id }));
        }
    }


    if ($node) {
        if (my $host = $node->db->{hostname}) {
            $self->render(text => $host);
        } else {
            $self->render(text => '_EMPTY_');
        }    
    } else {
        $self->render(text => '_NODE NOT FOUND_');
    }
}

sub comment {
    my ($self) = @_;
    my $nl = $self->nl;
    my $ip = $self->stash('node');

    # zeropad the ip if it has 7 :'s.
    if ($ip =~ /^[0-9a-f]+(?::[0-9a-f]+){7}$/) {
        $ip = join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));
    }

    # the (t)node .. (t)arget
    my $tnode = $nl->node($ip);

    # the (c)node .. (c)ommenter
    my $cnode = $nl->node($self->remote_ip);

    if ($cnode) {
        if (my $cid = $self->param('delete')) {
            my $pre_count = scalar(@{$tnode->db->{comments}});
            my @comments;
            foreach my $comment (@{$tnode->db->{comments}}) {
                unless ($comment->{comment_id} eq $cid && $comment->{comment_author} eq $cnode->ip) {
                    push(@comments, $comment);
                }
            }
            if (scalar(@comments) == $pre_count - 1) {
                # update the db with the new comments.
                $tnode->db->{comments} = \@comments;
                $self->db->get_collection('nodes')->save($tnode->db);
                $self->render(json => { success => 1, deleted => $cid });
            } else {
                $self->render(json => { success => 0 });
            }
        } elsif (my $comment_text = $self->param('comment')) {
            $comment_text =~ s/</&lt;/g;

            my @lines = split(/\r*\n/, $comment_text);

            # quote lines, content lines
            my (@ql, @cl);

            foreach my $line (@lines) {
                if ($line =~ /^>/) {
                    push (@ql, $line);
                } else {
                    push (@cl, $line);
                }
            }
            
            $comment_text = undef;
            # re-assemble the content, two <p> tags.
            if (scalar(@ql)) {
                $comment_text = '<p class="comment-quote">' . join("<br/>", @ql) . '</p>';
            } 

            # this is a connect info line.  put it in a pre tag.
            if ($cl[0] =~ /^\s*\"\d+\.\d+\.\d+\.\d+:/) {
                $comment_text .= "<h5 class='margin-top: 5px;'>Public Node Connection Information</h5><pre style='font-size: 10px; padding: 0; border: 0; margin-top:5px;'>";
                foreach my $line (@cl) {
                    # clean out tabs..
                    $line =~ s/\t/ /g;

                    # two spaces deep.
                    $line =~ s/^\s+/  /g;

                    # ip definition, and brackets are on the left edge.
                    $line =~ s/^  {/{/g;
                    $line =~ s/^  }/}/g;
                    $line =~ s/^  "(\d+)/"$1/g;

                    # comments can go home.
                    next if $line =~ /^\s*\/\//;

                    # any cr's can too.
                    $line =~ s/\r//g;

                    # here we are.  ahh.
                    $comment_text .= "$line\n";
                }
                $comment_text .= "</pre>";
            } else {
                $comment_text .= '<p class="comment-body">' . join("<br/>", @cl) . '</p>';
            }

            my $c_id = $self->_new_uuid();
            my $comment = {
                comment_id => $c_id,
                comment_time => time,
                comment_author => $cnode->ip,
                comment_text => $comment_text,
            };

            # add the comment to the database
            push(@{$tnode->db->{comments}}, $comment);

            # keep track of the mod time!
            $tnode->db->{update_time} = time;

            $self->db->get_collection('nodes')->save($tnode->db);

            # let's try adding these to the stash first?
            $self->stash('comment', $comment);
            $self->stash('nl', $nl);

            $self->render(json => {success => 1, 
                rendered_html => $self->render(template => 'node/comment', partial => 1)});
        } else {
            $self->render(json => {success => 0, message => 'no comment was supplied.'});
        }
    } else {
        $self->render(json => {success => 0, message => 'no comments from the anonymous peanut gallery'});
    }
}

sub save_nodeinfo {
    my ($self) = @_;
    my $nl = $self->nl;
    my $ip = $self->stash('node');

    # zeropad the ip if it has 7 :'s.
    if ($ip =~ /^[0-9a-f]+(?::[0-9a-f]+){7}$/) {
        $ip = join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));
    }

    my $remote_ip = $self->remote_ip;
    if ($self->param('is_submit')) {
        if ($remote_ip eq $ip) {
            if ($self->req->headers->referrer !~ /^http:\/\/nodeinfo\.hype/ && 
                $self->req->headers->referrer !~ /^http:\/\/\[fc5d:baa5:61fc:6ffd:9554:67f0:e290:7535\]/) {
                warn "Yes... " . $self->req->headers->referrer . "\n";
                $self->render(json => {success => 0, message => "you're mean"});
                return;
            }
            my $db = $self->db;
            my $node = $nl->node($ip);

            if (my $hostname = $self->param('hostname')) {
                my $cur = $db->get_collection('nodes')->find({hostname => $hostname});
                if ($cur->count > 1) {
                    warn "BAD more than one person has $hostname!\n";
                    $self->render(json => {success => 0});
                    return;
                } elsif ($cur->count == 1) {
                    my $nodedb = $cur->next;
                    if ($nodedb->{ip} eq $ip) {
                        warn "$ip == $nodedb->{ip}\n";
                        $node->db->{hostname} = $hostname;
                    } else {
                        $self->render(json => {success => 0, message=> "$hostname currently resolves to $nodedb->{ip}"});
                        return;
                    }
                } else {
                    if (my $tld = _tld_conflict($hostname, $ip)) {
                        $self->render(json => {success => 0, message=> "$hostname conflicts with ICANN/IANA '$tld'"});
                    } else {
                        $node->db->{hostname} = $hostname;
                    }
                }
            }
            $node->db->{location} = $self->param('location');
            $node->db->{mx} = $self->param('mx');
            $node->db->{os} = $self->param('os');
            $node->db->{hardware} = $self->param('hardware');
            $node->db->{connect_info} = $self->param('connect_info');
            $node->db->{update_time} = time;
            $db->get_collection('nodes')->save($node->db);

            $self->render(json => { success => 1});
        }  else {
            warn "$ip does not match $remote_ip!\n";
            $self->render(json => {success => 0});
        }
    } else {
        $self->render(json => {success => 0});
    }
}

# ok this is for rendering the list.. LIVE.. DO IT LIVE.
sub live_list {
    my ($self) = @_;

    my $nl = $self->nl;

    # ay bay bay
    $self->render(
        nl => $nl,
    );
}

sub nmap {
    my ($self) = @_;

    my $nl = $self->nl;

    # get the IP from the url/placeholder.
    my $ip = $self->stash('node');

    # zeropad the ip if it has 7 :'s.
    if ($ip =~ /^[0-9a-f]+(?::[0-9a-f]+){7}$/) {
        $ip = join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));
    }

    if (my $uuid = $self->param('uuid')) {
        if (-e "/tmp/nmap.$uuid") {
            # ok the file exists..
            if (-s "/tmp/nmap.$uuid" > 64) {
                # it's non zero.  serve and delete.
                my $output;
                open(NMAP, '<', "/tmp/nmap.$uuid");
                {
                    local $/;
                    $output = <NMAP>;
                }
                close(NMAP);
                unlink("/tmp/nmap.$uuid");
                $self->render(text => "$output\n");
            } else {
                $self->render(text => 'wait');
            }
        } else {
            if ($uuid =~ /^[a-f0-9\-]$/i) {
                system("nmap -6 $ip 2>&1 > /tmp/nmap.$uuid &");
                $self->render(text => $uuid);
            } else {
                $self->render(text => 'lol');
            }
        }
    } else {
        my $uuid = _new_uuid();
        if ($uuid) {
            system("nmap -6 $ip 2>&1 > /tmp/nmap.$uuid &");
            $self->render(text => $uuid);
        } else {
            $self->render('my bad');
        }
    }
}

# This action will show a node's info..
sub details {
    my ($self) = @_;
    my $nl = $self->nl;

    # get the IP from the url/placeholder.
    my $ip = lc($self->stash('node'));

    # zeropad the ip if it has 7 :'s.
    if ($ip =~ /^[0-9a-f]+(?::[0-9a-f]+){7}$/) {
        $ip = join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));
    }

    my $node = $nl->node($ip);

    if ($node) {
        $self->render(
            nl => $nl,
            node => $node,
        );
    } elsif ($ip =~ /^[0-9a-f\:]+$/i) {
        # we make a new one if it's up!
        my $ping = `/bin/ping6 -W 1 -c 1 $ip | /bin/grep time=`;
        my ($ptime) = $ping =~ /time=([\d\.]+ \w+)/;
        if ($ptime) {
            # generate a "name" from the last 4
            my @c = split(/:/, $ip);
            my $common_name = $c[$#c];

            # ok so now we generate one.
            my $db = $self->db;
            my $id = $db->get_collection('nodes')->insert(
                {
                    ip => $ip,
                    ping => $ptime,
                    common_name => $common_name,
                    link_quality => 0,
                }
            );
            $node = NodeInfo::Data::Node->new($db->get_collection('nodes')->find_one({ _id => $id }));
            $self->render(
                nl => $nl,
                node => $node,
            );
        } else {
            $self->render(
                status => 404,
                nl => $nl,
                template => "general/error_message",
                message_short => "Node Not Found",
                message_long => "We searched high and low for $ip, but we couldn't find it.  Maybe our routing table is stale.  Either way, try again later.",
            );
        }
    }
}

# This action will show a node's info..
sub live_details {
    my ($self) = @_;

    my $nl = $self->nl;

    # get the IP from the url/placeholder.
    my $ip = $self->stash('node');

    # zeropad the ip if it has 7 :'s.
    if ($ip =~ /^[0-9a-f]+(?::[0-9a-f]+){7}$/) {
        $ip = join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));
    }

    # lay a quick ping down and hopefully get a reply.
    my $ping = `ping6 -W 1 -c 1 $ip | grep time=`;
    my ($ptime) = $ping =~ /time=([\d\.]+ \w+)/;

    # if it doesn't ping, keep track.
    $ptime = "N/A" unless $ptime;

    # report back!
    $self->render(
        node => $nl->node($ip),
        ping => "$ptime",
    );
}

sub cjdrouting_table {
    my ($self) = @_;
    my $port = $self->stash('port');

    my $s = IO::Socket::INET->new(
        PeerAddr => 'localhost',
        PeerPort => $port,
        Proto => 'tcp',
        Type => SOCK_STREAM);

    print $s "d1:q19:NodeStore_dumpTable4:txid4:....e\n";

    my $encoded;
    while (my $line = <$s>) {
        $encoded .= $line;
        last if $line =~ /\.\.\.\.e/;
    }
    $s->close();

    # strip off trailing whitespace.
    $encoded =~ s/[\r\n]+$//g;

    $self->render(json => {routingTable => bdecode($encoded)->{routingTable}});
}

sub _tld_conflict {
    my ($host, $ip) = @_;

    # zeropad the ip if it has 7 :'s.
    if ($ip =~ /^[0-9a-f]+(?::[0-9a-f]+){7}$/) {
        $ip = join(':', map { sprintf("%04x", hex($_)) } split(/:/, $ip));
    }

    my $addr = `dig +short AAAA $host`;
    chomp($addr);
    if ($addr) {
        $addr = join(':', map { sprintf("%04x", hex($_)) } split(/:/, $addr));
        if (lc($addr) eq lc($ip)) {
            # if the host resolves to this ip, let it happen
            return undef;
        }
    }

    $host = lc($host);
    foreach my $tld (@tlds) {
        if ($host =~ /\.$tld$/) {
            return $tld;
        }
    }
    return undef;
}

sub _new_uuid {
    my $ud = Data::UUID->new;
    return $ud->create_str;
}

1;
