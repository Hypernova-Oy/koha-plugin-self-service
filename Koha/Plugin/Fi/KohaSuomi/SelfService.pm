package Koha::Plugin::Fi::KohaSuomi::SelfService;

# Copyright 2016 KohaSuomi
# Copyright 2018 The National Library of Finland
# Copyright 2019 Hypernova Oy
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use Mojo::JSON qw(decode_json);;

use Carp;
use DateTime::Format::ISO8601;
use Time::Piece ();
use Try::Tiny;
use Scalar::Util qw(blessed);
use YAML::XS;

use C4::Context;
use C4::Log;
use C4::Members::Attributes;

use Koha::Caches;
use Koha::Logger;
use Koha::Patron::Debarments;

use Koha::Plugin::Fi::KohaSuomi::SelfService::Install;

use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::BlockedBorrowerCategory;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::FeatureUnavailable;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::OpeningHours;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::PermissionRevoked;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::TACNotAccepted;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::Underage;

our $VERSION = "{VERSION}";

our $metadata = {
    name            => 'Koha Self Service Permission API',
    author          => 'Lari Taskula',
    date_authored   => '2019-11-05',
    date_updated    => "2019-11-05",
    minimum_version => '19.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin implements Self Service Permission API for use with access control devices'
};

my $logger = bless({lazyLoad => {category => __PACKAGE__}}, 'Koha::Logger');

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub install {
    my ( $self, $args ) = @_;

    return Koha::Plugin::Fi::KohaSuomi::SelfService::Install::install($self, $args);
}

sub uninstall {
    my ( $self, $args ) = @_;

    return Koha::Plugin::Fi::KohaSuomi::SelfService::Install::uninstall($self, $args);
}

sub upgrade {
    my ( $self, $args ) = @_;

    return Koha::Plugin::Fi::KohaSuomi::SelfService::Install::upgrade($self, $args);
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_dir = $self->mbf_dir();
    my $spec = JSON::Validator->new->schema($spec_dir . "/openapi.json")->schema->{data};

    return $spec;
}

sub api_namespace {
    my ( $self ) = @_;

    return 'kohasuomi';
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            SSRules => C4::Context->preference( 'SSRules' ),
            OpeningHours => C4::Context->preference( 'OpeningHours' ),
            EncryptionConfiguration => C4::Context->preference( 'EncryptionConfiguration' ),
            SSBlockCleanOlderThanThis => C4::Context->preference( 'SSBlockCleanOlderThanThis' ),
            SSBlockDefaultDuration => C4::Context->preference( 'SSBlockDefaultDuration' ),
        );

        $self->output_html( $template->output() );
    }
    else {
        C4::Context->set_preference('SSRules', $cgi->param('SSRules'));
        C4::Context->set_preference('OpeningHours', $cgi->param('OpeningHours'));
        C4::Context->set_preference('EncryptionConfiguration', $cgi->param('EncryptionConfiguration'));
        C4::Context->set_preference('SSBlockCleanOlderThanThis', $cgi->param('SSBlockCleanOlderThanThis'));
        C4::Context->set_preference('SSBlockDefaultDuration', $cgi->param('SSBlockDefaultDuration'));

        $self->go_home();
    }
}

=head2 CheckSelfServicePermission
 @param {Koha::Patron or something castable}
 @param {String} Branchcode of the Branch where the user is requesting access
 @param {String} Action the user is trying to do, eg. access the main doors
=cut

sub CheckSelfServicePermission {
    my ($patron, $requestingBranchcode, $action) = @_;
    $requestingBranchcode = C4::Context->userenv->{branch} unless $requestingBranchcode;
    $action = 'accessMainDoor' unless $action;

    $patron = $patron->unblessed if ref($patron) eq 'Koha::Patron';

    try {
        _HasSelfServicePermission($patron, $requestingBranchcode, $action);
    } catch {
        $logger->debug("Caught error. Type:'".ref($_)."', stringified: '$_'") if $logger->is_debug;
        unless (blessed($_) && $_->can('rethrow')) {
            confess $_;
        }
        if ($_->isa('Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::Underage')) {
            _WriteAccessLog($action, $patron->{borrowernumber}, 'underage');
            $_->rethrow();
        }
        elsif ($_->isa('Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::TACNotAccepted')) {
            _WriteAccessLog($action, $patron->{borrowernumber}, 'missingT&C');
            $_->rethrow();
        }
        elsif ($_->isa('Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::BlockedBorrowerCategory')) {
            _WriteAccessLog($action, $patron->{borrowernumber}, 'blockBorCat');
            $_->rethrow();
        }
        elsif ($_->isa('Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::PermissionRevoked')) {
            _WriteAccessLog($action, $patron->{borrowernumber}, 'revoked');
            $_->rethrow();
        }
        elsif ($_->isa('Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::OpeningHours')) {
            _WriteAccessLog($action, $patron->{borrowernumber}, 'closed');
            $_->rethrow();
        }
        elsif ($_->isa('Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::FeatureUnavailable')) {
            _WriteAccessLog($action, $patron->{borrowernumber}, 'misconfigured');
            $_->rethrow();
        }
        elsif ($_->isa('Koha::Plugin::Fi::KohaSuomi::SelfService::Exception')) {
            _WriteAccessLog($action, $patron->{borrowernumber}, 'denied');
            $_->rethrow();
        }
        $_->rethrow;
    };
    _WriteAccessLog($action, $patron->{borrowernumber}, 'granted');
    return 1;
}

sub _HasSelfServicePermission {
    my ($patron, $requestingBranchcode, $action) = @_;

    my $rules = GetRules();

    _CheckTaC($patron, $rules)              if ($rules->{TaC});
    _CheckPermission($patron, $rules)       if ($rules->{Permission});
    _CheckBorrowerCategory($patron, $rules) if ($rules->{BorrowerCategories});
    _CheckMinimumAge($patron, $rules)       if ($rules->{MinimumAge});
    _CheckCardExpired($patron, $rules)      if ($rules->{CardExpired});
    _CheckCardLost($patron, $rules)         if ($rules->{CardLost});
    _CheckDebarred($patron, $rules)         if ($rules->{Debarred});
    _CheckMaxFines($patron, $rules)         if ($rules->{MaxFines});

    _CheckBranchBlock($patron, $rules, $requestingBranchcode) if ($rules->{BranchBlock} && $action ne 'blockList'); #Blocklists deal with this using custom logic.

    if ($rules->{OpeningHours}) {
        $rules->{OpeningHours} = $requestingBranchcode if ($requestingBranchcode);
        _CheckOpeningHours($patron, $rules);
    }

    return 1;
}

sub _CheckCardLost {
    my ($patron, $rules) = @_;
    Koha::Plugin::Fi::KohaSuomi::SelfService::Exception->throw(error => "Card lost") if ($patron->{lost});
}

sub _CheckCardExpired {
    my ($patron, $rules) = @_;
    Koha::Plugin::Fi::KohaSuomi::SelfService::Exception->throw(error => "Card expired") if ($patron->{dateexpiry} lt Time::Piece::localtime->strftime('%F'));
}

sub _CheckDebarred {
    my ($patron, $rules) = @_;
    Koha::Plugin::Fi::KohaSuomi::SelfService::Exception->throw(error => "Debarred") if ($patron->{debarred});
}

sub _CheckMaxFines {
    my ($patron, $rules) = @_;

    my $dbh = C4::Context->dbh();
    my @totalFines = $dbh->selectrow_array('SELECT SUM(amountoutstanding) FROM accountlines WHERE borrowernumber = ?', undef, $patron->{borrowernumber});
    return unless $totalFines[0];
    my $maxFinesBeforeBlock = C4::Context->preference('noissuescharge');
    if ($totalFines[0] >= $maxFinesBeforeBlock) {
        Koha::Plugin::Fi::KohaSuomi::SelfService::Exception->throw(error => "Too many fines '$totalFines[0]'"); #It might be ok to throw something specific about max fines, but then Toveri needs to be retrofitted to handle the new exception type.
    }
}

sub _CheckMinimumAge {
    my ($patron, $rules) = @_;
    if ($patron->{dateofbirth}) {
        my $dob = DateTime::Format::ISO8601->parse_datetime($patron->{dateofbirth});
        $dob->set_time_zone( C4::Context->tz() );
        my $minimumDob = DateTime->now(time_zone => C4::Context->tz())->subtract(years => $rules->{MinimumAge});
        if (DateTime->compare($dob, $minimumDob) < 0) {
            return 1;
        }
    }

    Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::Underage->throw(minimumAge => $rules->{MinimumAge});
}

sub _CheckTaC {
    my ($patron, $rules) = @_;
    my $agreement = C4::Members::Attributes::GetBorrowerAttributeValue($patron->{borrowernumber}, 'SST&C');
    unless ($agreement) {
        Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::TACNotAccepted->throw();
    }
}

sub _CheckPermission {
    my ($patron, $rules) = @_;
    my $ban = C4::Members::Attributes::GetBorrowerAttributeValue($patron->{borrowernumber}, 'SSBAN');
    if ($ban) {
        Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::PermissionRevoked->throw();
    }
}

sub _CheckBorrowerCategory {
    my ($patron, $rules) = @_;

    unless ($patron->{categorycode} && $rules->{BorrowerCategories} =~ /$patron->{categorycode}/) {
        Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::BlockedBorrowerCategory->throw(error => "Borrower category '".$patron->{categorycode}."' is not allowed");
    }
}

sub _CheckBranchBlock {
    my ($patron, $rules, $requestingBranchcode) = @_;
    my $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::hasBlock($patron, $requestingBranchcode);
    if ($block) {
        Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::PermissionRevoked->throw(expirationdate => $block->{expirationdate});
    }
}

sub _CheckOpeningHours {
    my ($patron, $rules) = @_;
    my $branchcode = $rules->{OpeningHours};
    # If no branchcode to check the opening hours for has been given, let it pass. This is important to allow using the same code from block list generating code, and for realtime checks.
    return 1 unless ($branchcode);

    unless (isLibraryOpen($branchcode)) {
        my $openingHours = getOpeningHours($branchcode);
        Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::OpeningHours->throw(
            error => "Self-service resource closed at this time. Try again later.",
            startTime => $openingHours->[0],
            endTime => $openingHours->[1],
        );
    }
}

sub GetAccessLogs {
    my ($userNumber) = @_;

    return C4::Log::GetLogs(undef, undef, undef, ['SS'], undef, $userNumber, undef);
}

=head2 _WriteAccessLog
@PARAM1 String, action to log, typically 'accessMainDoor' or other Self-service component
@PARAM2 Int, the borrowernumber of the user accessing the Self-service resource
@PARAM3 String, what was the outcome of the authorization? Typically 'denied', 'granted', 'underage', 'missingT&C'
@RETURNS undef, since C4::Log has no useful return values.
=cut

sub _WriteAccessLog {
    my ($action, $accessingBorrowernumber, $resolution) = @_;
    C4::Log::logaction('SS', $action, $accessingBorrowernumber, $resolution);
}

=head2
Deletes all Self-service logs from the koha.action_logs-table
=cut

sub FlushLogs {
    C4::Context->dbh->do("DELETE FROM action_logs WHERE module = 'SS'");
}

=head2 GetRules
    my $rules = GetRules();
Retrieves the Self-Service rules. This is basically a list of checks triggered, with the corresponding parameters if any.
@RETURNS HASHRef of:
            'TaC'                => Boolean, Terms and conditions of self-service usage accepted
            'Permission'         => Boolean, permissions to access the self-service resource. Basically not having SSBAN -borrower attribute.
            'BorrowerCategories' => String, list of allowed borrower categories
            'MinimumAge'         => Integer, age limit for self-service resources
            'CardExpired'        => Boolean, check for expired card
            'CardLost'           => Boolean, check for a lost card
            'Debarred'           => Boolean, check if user account is debarred
            'MaxFines'           => Boolean, checks the syspref 'MaxFine' against the borrowers accumulated fines,
            'OpeningHours'       => Boolean, use the syspref 'OpeningHours' to check against the current time and branch.
@THROWS Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::FeatureUnavailable if SSRules is not properly configured
=cut

sub GetRules {
    my $cache = Koha::Caches->get_instance();
    my $rules = $cache->get_from_cache('SSRules');
    return $rules if $rules;

    my $ssrules = C4::Context->preference('SSRules');
    $rules = eval { YAML::XS::Load($ssrules) };
    if ($rules && ref($rules) eq 'HASH') {
        $cache->set_in_cache('SSRules', $rules, {expiry => 300});
        return $rules;
    }

    Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::FeatureUnavailable->throw(error => "System preference 'SSRules' '".($ssrules||'undef')."' is not properly defined: $@");
}

=head2 isLibraryOpen

  my $open = isLibraryOpen($branchcode || 'CPL' [, $DateTime]);

@PARAM1 String, branchcode
@PARAM2 DateTime, OPTIONAL time to check for openness. Defaults to current time | now().
@RETURNS Boolean, Library is open or not
@THROWS from _getOpeningHoursFromSyspref()

=cut

sub isLibraryOpen {
    my ($branchcode, $dt) = @_;

    $dt = DateTime->now(time_zone => C4::Context->tz()) unless $dt;
    my $hm = sprintf("%02d:%02d", $dt->hour,$dt->minute);
    my $openingHours = getOpeningHours($branchcode, $dt);
    return 1 if ($openingHours->[0] le $hm && $hm lt $openingHours->[1]);
    return undef;
}

=head2 getOpeningHours

Gets opening hours for the given branchcode. Opening hours are an array of
weekdays, with arrays of start time and ending time

@PARAM1 String, branchcode
@PARAM2 DateTime, OPTIONAL weekday to check for openness. Defaults to current time | now()
@RETURNS ARRAYRef of HH:MM, ex.
        [
          '12:22', #opening time
          '22:00', #closing time
        ]

@THROWS from _getOpeningHoursFromSyspref()

=cut

sub getOpeningHours {
    my ($branchcode, $dt) = @_;
    #Should cache the syspref de-yaml-ization, but no Koha::Cache here yet.

    $dt = DateTime->now(time_zone => C4::Context->tz()) unless $dt;
    my $openingHours = _getOpeningHoursFromSyspref();
    my $branchOpeningHours = $openingHours->{$branchcode};
    Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::FeatureUnavailable->throw(error => "System preference 'OpeningHours' is missing opening hours for branch '$branchcode'")
        unless $branchOpeningHours;

                                                #Array starts from 0, DateTime->day_of_week start from 1
    my $dailyOpeningHours = $branchOpeningHours->[ $dt->day_of_week()-1 ];
    Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::FeatureUnavailable->throw(error => "System preference 'OpeningHours' is missing opening hours for branch '$branchcode' and weekday '".$dt->day_of_week()."'")
        unless $dailyOpeningHours;

    return $dailyOpeningHours;
}

=head2 _getOpeningHoursFromSyspref

@DEPRECATED use Bug 17015 when it comes out

@RETURNS HASHRef of ARRAYRef of ARRAYRef of HH:MM, ex.
  {
    CPL => [
      ['12:22', #opening time
       '22:00', #closing time
      ],
      ['12:23',
       '21:30',
      ],
      ...
    ],
    FPL => [
      ...
   ],
    ...
  }

@THROWS Koha::Plugin::Fi::KohaSuomi::SelfService::Exception::FeatureUnavailable if syspref "OpeningHours" is not properly set

=cut

sub _getOpeningHoursFromSyspref {
    my $logger = Koha::Logger->get({category => __PACKAGE__});
    my $sp = C4::Context->preference('OpeningHours');
    Koha::Exceptions::Config->throw(error => 'System preference "OpeningHours" not set. Cannot get opening hours!')
        unless $sp;
    eval {
        $sp = YAML::XS::Load( $sp );
    };
    Koha::Exceptions::Config->throw(error => 'System preference "OpeningHours" is not valid YAML. Validate it using yamllint! or '.$@)
        if $@;
    $logger->debug("'OpeningHours'-syspref: ".Data::Dumper::Dumper($sp)) if $logger->is_debug;
    return $sp;
}

1;
