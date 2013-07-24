package NodeInfo::Data::Node;

sub new {
    my ($class, $db) = @_;
    my $self = bless { db => $db }, $class;
    return $self;
}

sub runs_service {
    my ($self, $service) = @_;
    return undef unless $service;
    if (my $db = $self->db) {
        foreach my $svc (@{$db->{services}}) {
            if ($svc->{service} eq $service) {
                return 1;
            } elsif ($svc->{port} eq $service) {
                return 1;
            }
        }
    }
    return undef;
}


sub hostname {
    my ($self) = @_;
    return $self->{db}->{hostname};
}

sub name {
    my ($self) = @_;
    if ($self->{db}->{hostname}) {
        return $self->{db}->{hostname};
    } else {
        return $self->{db}->{common_name};
    }
}

# works the same as 'ping' allows for numeric only :)
sub cjdping {
    my ($self, $numeric) = @_;
    if ($numeric) {
        my $ping = $self->{db}->{cjdping};
        $ping =~ s/[^0-9\.]+//g;
        if ($ping) {
            return $ping;
        } else {
            # na's come last ;P
            return "1000000";
        }
    } else {
        if (my $ping = $self->{db}->{cjdping}) {
            if ($ping =~ /^0\.(\d+) ms/o) {
                $ping = sprintf("%.2f ms", "0.$1");
            }
            $ping =~ s/\s+//g;
            return $ping;
        }
    }
    return undef;
}

sub ping {
    my ($self, $numeric) = @_;
    if ($numeric) {
        my $ping = $self->{db}->{ping};
        $ping =~ s/[^0-9\.]+//g;
        if ($ping) {
            return $ping;
        } else {
            # na's come last ;P
            return "1000000";
        }
    } else {
        if (my $ping = $self->{db}->{ping}) {
            if ($ping =~ /^0\.(\d+) ms/o) {
                $ping = sprintf("%.2f ms", "0.$1");
            }
            $ping =~ s/\s+//g;
            return $ping;
        }
    }
    return undef;
}

sub connect_info {
    my ($self) = @_;
    return $self->{db}->{connect_info};
}

sub ip {
    my ($self) = @_;
    return $self->{db}->{ip};
}

sub link {
    my ($self) = @_;
    return $self->{db}->{link_quality};
}

sub db {
    my ($self) = @_;
    return $self->{db};
}

1;
