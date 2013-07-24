package Cjdns::Route;

sub new {
    my ($class, $ip, $name, $path, $link, $db, $ping) = @_;
    my $self = bless { ip => $ip, name => $name, link => $link, db => $db, ping => $ping }, $class;
    ($self->{route}) = reverse(join('', map { sprintf("%04b", hex($_)) } split(//, $path))) =~ /^([0-1]+?)1[0]*$/;
    return $self;
}

sub link {
    my ($self, $v) = @_;
    if ($v) {
        $self->{link} = $v;
    }
    return $self->{link};
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
    return $self->{db}->{hostname} if ref($self->{db});
}

sub name {
    my ($self, $v) = @_;
    if ($v) {
        $self->{name} = $v;
    }
    return $self->{name} ? $self->{name} : $self->{db}->{common_name};
}

sub ping {
    my ($self) = @_;
    if ($self->{ping}) {
        return "$self->{ping}ms";
    }
    return undef;
}

sub ip {
    my ($self, $v) = @_;
    if ($v) {
        $self->{ip} = $v;
    }
    return $self->{ip};
}

sub route {
    my ($self, $v) = @_;
    if ($v) {
        $self->{route} = $v;
    }
    return $self->{route};
}

sub db {
    my ($self, $db) = @_;
    if ($db) {
        $self->{db} = $db;
    }
    return $self->{db};
}

1;
