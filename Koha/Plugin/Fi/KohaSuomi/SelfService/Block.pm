package Koha::Plugin::Fi::KohaSuomi::SelfService::Block;

# Copyright 2018 Hypernova Oy
#
# This file is part of Koha.
#

use Modern::Perl '2015';

use Try::Tiny;
use Scalar::Util qw(blessed);
use utf8;

use Data::Dumper;
use DateTime;
use DateTime::Format::MySQL;
use YAML::XS;
use Storable;

use C4::Context;
use Koha::Logger;
use Koha::Plugin::Fi::KohaSuomi::SelfService;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Log qw(toString);

use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception;

use Koha::Exceptions::Library;
use Koha::Exceptions::Patron;
use Koha::Exceptions::Plugin;

use Koha::Logger;
my $logger = Koha::Logger->get;

use fields qw(borrower_ss_block_id borrowernumber branchcode expirationdate created_by created_on);

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::SelfService::Block - Branch-specific self-service library access block for a borrower

=head1 DESCRIPTION

Implemented using DBI as this subsystem is performance-critical as it is used in daily full-DB block-list generation.

=cut

=head2 new

There could be validations inside, but that is very atypical for perl modules out there. Let's trust the Swagger validation
as that sits at a clear infrastructure boundary.

 @throws {Koha::Exceptions::Plugin::ForbiddenAction} When there is no logged in user and no created_by is provided

=cut

sub new {
    my ($class, $params) = @_;
    my $self = bless($params, $class); #Use the BlockManager if you want to detach the given parameters from the object itself.
    $logger->trace(sprintf("Constructor params '%s'", toString($self))) if $logger->is_trace();

    $self->{created_by} = C4::Context->userenv->{number} if (not($self->{created_by}) && C4::Context->userenv); #Current logged in user
    Koha::Exceptions::Plugin::ForbiddenAction->throw(error => sprintf("Trying to create '%s', but nobody is logged in?", toString($self))) unless ($self->{created_by});

    $self->{created_on} = DateTime->now(time_zone => C4::Context->tz) unless ($self->{created_on});

    $self->{expirationdate} = _getDefaultExpirationdate() unless ($self->{expirationdate});
    return $self;
}

sub _getDefaultExpirationdate {
    my $ddur = C4::Context->preference('SSBlockDefaultDuration') // Koha::Exception::SelfService::FeatureUnavailable->throw(error => "Syspref 'SSBlockDefaultDuration' is undefined");
    return DateTime->now(time_zone => C4::Context->tz)->add(days => $ddur);
}

sub swaggerize {
    $_[0]->{borrower_ss_block_id} += 0;
    $_[0]->{borrowernumber}       += 0;
    $_[0]->{expirationdate}       = (blessed($_[0]->{expirationdate})) ? $_[0]->{expirationdate}->iso8601() : $_[0]->{expirationdate};
    $_[0]->{created_by}           += 0;
    $_[0]->{created_on}           = (blessed($_[0]->{created_on})) ? $_[0]->{created_on}->iso8601() : $_[0]->{created_on};

    my %a = %{$_[0]}; #unbless the reference
    return \%a;
}

sub toYaml {
    return YAML::XS::Dump(Storable::dclone($_[0])->swaggerize); # DateTime must be serialized as a string first
}

=head2 xssScrub

It would be better to use HTML::Scrubber but redesigning Koha's API validation strategies is outside the scope of this work.

=cut

sub xssScrub {
    $_[0]->{notes} =~ s/</😄/gsm if $_[0]->{notes};
    $_[0]->{notes} =~ s/>/😆/gsm if $_[0]->{notes};
}

sub _parseDateTime {
    my $dt;
    eval {
        $dt = DateTime::Format::MySQL->parse_datetime($_[0]);
    };
    if ($@) {
        my $e = $@;
        eval {
            $dt = DateTime::Format::MySQL->parse_datetime($_[0]);
        };
        if ($@) {
            die "Invalid date format: '$_[0]' is not of MySQL or ISO8601 format";
        }
    }
    return $dt;
}

=head1 ACCESSORS

=cut

sub id { return $_[0]->{borrower_ss_block_id}; }
sub borrowernumber { return $_[0]->{borrowernumber}; }
sub branchcode { return $_[0]->{branchcode}; }
sub created_by { return $_[0]->{created_by}; }

#Lazy load DateTime as it is somewhat expensive
sub expirationdate {
    $_[0]->{expirationdate} = DateTime::Format::MySQL->parse_datetime($_[0]->{expirationdate}) unless (blessed($_[0]->{expirationdate}));
    return $_[0]->{expirationdate};
}
sub created_on {
    $_[0]->{created_on} = DateTime::Format::MySQL->parse_datetime($_[0]->{created_on}) unless (blessed($_[0]->{created_on}));
    return $_[0]->{created_on};
}

=head1 TEST UTILS

Static subroutines to help testing these objects

=head2 get_deeply_testable

 @param1 {HASHRef} Block-object's attributes to overload defaults with
 @returns {Koha::Plugin::Fi::KohaSuomi::SelfService::Block} a Test::Deep::cmp_deeply -testable instance of a typical object

=cut

sub get_deeply_testable {
    my ($got) = @_;
    require Test::Deep::Regexp;
    return bless({
        borrower_ss_block_id => $got->{borrower_ss_block_id} // Test::Deep::Regexp->new(qr/^\d+$/),
        borrowernumber       => $got->{borrowernumber}       // Test::Deep::Regexp->new(qr/^\d+$/),
        branchcode           => $got->{branchcode},
        expirationdate       => $got->{expirationdate}       // Test::Deep::Regexp->new(qr/^\d\d\d\d-\d\d-\d\d[ T]\d\d:\d\d:\d\d/),
        notes                => $got->{notes},
        created_by           => $got->{created_by}           // Test::Deep::Regexp->new(qr/^\d+$/),
        created_on           => $got->{created_on}           // Test::Deep::Regexp->new(qr/^\d\d\d\d-\d\d-\d\d[ T]\d\d:\d\d:\d\d/),
    }, 'Koha::Plugin::Fi::KohaSuomi::SelfService::Block');
};

1;
