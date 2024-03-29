#!perl
BEGIN {
    $ENV{KOHA_PLUGIN_DEV_MODE} = 1;
}

use Modern::Perl '2014';
use Test::More tests => 2;
use Test::Exception;
use Test::MockModule;
use Try::Tiny;

use DateTime;
use Scalar::Util qw(blessed);
use File::Basename;

use Koha::Plugin::Fi::KohaSuomi::SelfService;
use Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager;
use Koha::Patrons;
use Koha::Patron::Attribute;
use Koha::Patron::Attributes;
use Koha::Patron::Debarments;

use t::db_dependent::SelfService_context;
use t::db_dependent::opening_hours_context;
use t::lib::TestBuilder;
use Koha::Database;
use Koha::Account::Line;


use Koha::Libraries;
use Koha::Exception::SelfService::FeatureUnavailable;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my $todayYmd = DateTime->now()->ymd('-');
my $hours;

my $userenv;

subtest("Scenario: User with all possible blocks and bans tries to access a Self-Service resource. Testing that exceptions are reported in the correct order.", sub {
    plan tests => 17;

    $schema->storage->txn_begin;
    my $debarment; #Debarment of the scenario borrower
    my $f; #Fines of the scenario borrower
    my $ssblock; #Self-service branch specific block for the borrower

    my $user = $builder->build({
        source => 'Borrower',
        value => {
            cardnumber => '11A01',
            categorycode => 'ST',
            dateofbirth => $todayYmd,
            dateexpiry => '2001-01-01',
            lost     => 1,
            branchcode => 'CPL',
            gonenoaddress => 0,
        }
    });
    my $p = Koha::Patrons->find($user->{borrowernumber});
    my $b = $p->unblessed;

    C4::Context->_new_userenv('DUMMY SESSION');
    C4::Context->set_userenv($user->{borrowernumber},$user->{userid},'SSAPIUser','firstname','surname', 'CPL', 'CEEPEEÄL', 0, '', '');
    $userenv = C4::Context->userenv;

    subtest("Set opening hours", sub {
        plan tests => 1;

        $hours = t::db_dependent::opening_hours_context::createContext;
        C4::Context->set_preference("OpeningHours",$hours);
        ok(1, $hours);
    });
    subtest("Clear system preference 'SSRules'", sub {
        plan tests => 1;

        C4::Context->set_preference("SSRules",'');
        Koha::Caches->get_instance()->clear_from_cache('SSRules');
        ok(1, "Step ok");
    });
    subtest("Given a user with all relevant blocks and bans", sub {
        plan tests => 3;

        $p->extended_attributes(
            $p->extended_attributes->merge_and_replace_with([{ code => 'SST&C', attribute => '0' },
                                                             { code => 'SSBAN', attribute => '1' }])
        );

        Koha::Patron::Debarments::AddDebarment({borrowernumber => $b->{borrowernumber}});
        ok($debarment = $p->restrictions->search()->single,
           "Debarment given");

        ok($f = Koha::Account::Line->new({ borrowernumber => $b->{borrowernumber}, amountoutstanding => 1000, note => 'fid', interface => 'intranet' })->store(),
           "Fine given");

        ok($ssblock = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
            borrowernumber => $b->{borrowernumber},
            branchcode     => 'CPL',
        })),
            "Self-service branch specific block is given");
    });
    subtest("Self-service resource accessing is not properly configured", sub {
        plan tests => 1;

        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService::FeatureUnavailable',
                  "System preferences not properly set");
    });
    subtest("Given a system preference 'SSRules'", sub {
        plan tests => 1;

        C4::Context->set_preference("SSRules",
            "---\n".
            "TaC: 1\n".
            "Permission: 1\n".
            "BorrowerCategories: PT S\n".
            "MinimumAge: 15\n".
            "MaxFines: 1\n".
            "CardExpired: 1\n".
            "CardLost: 1\n".
            "Debarred: 1\n".
            "OpeningHours: 1\n".
            "BranchBlock: 1\n".
            "\n");
        Koha::Caches->get_instance()->clear_from_cache('SSRules');
        ok(1, "Step ok");
    });
    subtest("Self-service feature works, but terms and conditions are not accepted", sub {
        plan tests => 1;

        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService::TACNotAccepted',
                  "Finely behaving user hasn't agreed to terms and conditions of self-service usage");
    });
    subtest("Self-service terms and conditions accepted, but user's self-service permissions have been revoked", sub {
        plan tests => 1;

        $p->extended_attributes(
            $p->extended_attributes->merge_and_replace_with([{ code => 'SST&C', attribute => '1' },
                                                             { code => 'SSBAN', attribute => '1' }])
        );
        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService::PermissionRevoked',
                  "User Self-Service permission revoked");
    });
    subtest("Self-service permission reinstituted, but the user has a wrong borrower category", sub {
        plan tests => 1;

        $p->extended_attributes(
            $p->extended_attributes->merge_and_replace_with([{ code => 'SST&C', attribute => '1' },
                                                             { code => 'SSBAN', attribute => '0' }])
        );
        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService::BlockedBorrowerCategory',
                  "User's borrower category is not whitelisted");
    });
    subtest("Borrower category changed, but the user is still underaged", sub {
        plan tests => 5;

        $b->{categorycode} = ('PT'); Koha::Patrons->find($b->{borrowernumber})->set($b)->store;

        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;
        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService::Underage',
                  "Underage user has no permission");

        $b->{dateofbirth} = DateTime->now(time_zone => C4::Context->tz())->subtract(years => 15)->add(days => 1)->iso8601();
        ok(Koha::Patrons->find($b->{borrowernumber})->set($b)->store,
                  "Underage user is one day to 15 years old");
        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::_CheckMinimumAge($b, {MinimumAge => 15})}, 'Koha::Exception::SelfService::Underage',
                  "Underage user has no permission");

        $b->{dateofbirth} = DateTime->now(time_zone => C4::Context->tz())->subtract(years => 15)->iso8601();
        ok(Koha::Patrons->find($b->{borrowernumber})->set($b)->store,
                  "Underage user is 15 years and some seconds old");

        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;
        lives_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::_CheckMinimumAge($b, {MinimumAge => 15})},
                  "Underage user is no longer underage");
    });
    subtest("Borrower grew up, but his card is now expired", sub {
        plan tests => 2;

        $b->{dateofbirth} = ('2000-01-01'); Koha::Patrons->find($b->{borrowernumber})->set($b)->store;
        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService',
                  "User has no permission");
        like($@, qr/Card expired/, "And the card is expired");
    });
    subtest("Borrower renewed his card, but he lost his card!", sub {
        plan tests => 2;

        $b->{dateexpiry} = ('2075-01-01'); Koha::Patrons->find($b->{borrowernumber})->set($b)->store; #For sure Koha is no longer used in 2075
        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService',
                  "User has no permission");
        like($@, qr/Card lost/, "And the card is lost");
    });
    subtest("Borrower found his card, but is still debarred", sub {
        plan tests => 2;

        $b->{lost} = 0; Koha::Patrons->find($b->{borrowernumber})->set($b)->store;
        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService',
                  "User has no permission");
        like($@, qr/Debarred/, "And is debarred");
    });
    subtest("Borrower debarment lifted, but still has too many fines", sub {
        plan tests => 2;

        Koha::Patron::Debarments::DelDebarment($debarment->borrower_debarment_id);
        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService',
                  "User has no permission");
        like($@, qr/Too many fines '1000/, "And has too many fines");
    });
    subtest("Borrower is cleaned from his sins, but still the library is closed", sub {
        plan tests => 1;

        my $account = Koha::Account->new({ patron_id => $b->{borrowernumber} });
        $account->pay( { amount => 1000 } );
        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;
        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'UPL', 'accessMainDoor')}, 'Koha::Exception::SelfService::OpeningHours',
                  "Library is closed");
    });
    subtest("Borrower tries another library, but is blocked from that specific library", sub {
        plan tests => 2;

        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService::PermissionRevoked',
                  "User is blocked from this specific library");
        like($@->{expirationdate}, qr/^\d\d\d\d-\d\d-\d\d[T ]\d\d:\d\d:\d\d/,
                  "And the given exception has the block's expirationdate");
    });
    subtest("Branch specific block is lifted, finally Borrower is allowed access", sub {
        plan tests => 1;

        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::deleteBorrowersBlocks($b);

        ok(Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor'),
            "Finely behaving user accesses a self-service resource.");
    });
    subtest("Check the log entries", sub {
        plan tests => 72;

        my $logs = Koha::Plugin::Fi::KohaSuomi::SelfService::GetAccessLogs($b->{borrowernumber});
        t::db_dependent::SelfService_context::testLogs($logs, 0, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'misconfigured', $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 1, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'missingT&C',    $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 2, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'revoked',       $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 3, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'blockBorCat',   $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 4, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'underage',      $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 5, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'denied',        $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 6, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'denied',        $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 7, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'denied',        $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 8, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'denied',        $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 9, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'closed',        $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 10, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'revoked',      $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 11, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'granted',      $userenv);
    });

    Koha::Plugin::Fi::KohaSuomi::SelfService::FlushLogs();
    $schema->storage->txn_rollback;
});


subtest("Scenario: User with all possible blocks and bans tries to access a Self-Service resource. Library only checks for too many fines.", sub {
    plan tests => 5;

    $schema->storage->txn_begin;
    my $debarment; #Debarment of the scenario borrower
    my $f; #Fines of the scenario borrower

    my $user = $builder->build({
        source => 'Borrower',
        value => {
            cardnumber => '11A01',
            categorycode => 'ST',
            dateofbirth => $todayYmd,
            dateexpiry => '2001-01-01',
            lost     => 1,
            branchcode => 'CPL',
            gonenoaddress => 0,
        }
    });
    my $p = Koha::Patrons->find($user->{borrowernumber});
    my $b = $p->unblessed;

    C4::Context->_new_userenv('DUMMY SESSION');
    C4::Context->set_userenv($user->{borrowernumber},$user->{userid},'SSAPIUser','firstname','surname', 'CPL', 'CEEPEEÄL', 0, '', '');
    $userenv = C4::Context->userenv;

    subtest("Given a user with all relevant blocks and bans", sub {
        plan tests => 2;

        $p->extended_attributes(
            $p->extended_attributes->merge_and_replace_with([{ code => 'SSBAN', attribute => '1' }])
        );

        Koha::Patron::Debarments::AddDebarment({borrowernumber => $b->{borrowernumber}});
        ok($debarment = $p->restrictions->search()->single,
           "Debarment given");

        ok($f = Koha::Account::Line->new({ borrowernumber => $b->{borrowernumber}, amountoutstanding => 1000, note => 'fid', interface => 'intranet' })->store(),
           "Fine given");
    });
    subtest("Given a system preference 'SSRules'", sub {
        plan tests => 1;

        C4::Context->set_preference("SSRules",
            "---\n".
            "MaxFines: 1\n".
            "\n");
        Koha::Caches->get_instance()->clear_from_cache('SSRules');
        ok(1, "Step ok");
    });
    subtest("Borrower tries to access the library, but has too many fines", sub {
        plan tests => 2;

        $b = Koha::Patrons->find($user->{borrowernumber})->unblessed;

        throws_ok(sub {Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor')}, 'Koha::Exception::SelfService',
                  "User has no permission");
        like($@, qr/Too many fines '1000/, "And has too many fines");
    });
    subtest("Borrower pays his fines and is allowed access", sub {
        plan tests => 2;

        my $account = Koha::Account->new({ patron_id => $b->{borrowernumber} });
        ok($account->pay( { amount => 1000 } ),
           "Fines paid");

        ok(Koha::Plugin::Fi::KohaSuomi::SelfService::CheckSelfServicePermission($b, 'CPL', 'accessMainDoor'),
           "Naughty user accesses a self-service resource.");
    });
    subtest("Check the log entries", sub {
        plan tests => 12;

        my $logs = Koha::Plugin::Fi::KohaSuomi::SelfService::GetAccessLogs($b->{borrowernumber});
        t::db_dependent::SelfService_context::testLogs($logs, 0, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'denied',  $userenv);
        t::db_dependent::SelfService_context::testLogs($logs, 1, $b->{borrowernumber}, 'accessMainDoor', $todayYmd, 'granted', $userenv);
    });

    Koha::Plugin::Fi::KohaSuomi::SelfService::FlushLogs();
    $schema->storage->txn_rollback;
});


done_testing();
