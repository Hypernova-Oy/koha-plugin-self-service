#!perl

BEGIN {
    $ENV{LOG4PERL_VERBOSITY_CHANGE} = 6;
    $ENV{KOHA_PLUGIN_DEV_MODE} = 1;
}

use Modern::Perl '2015';
use Test::More tests => 10;
use Test::Exception;
use Test::Deep;
use Test::MockModule;
use Try::Tiny;

use Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Block;

use Koha::Database;
use Koha::Patron;

###   Set up global test context   ###
use t::lib::TestBuilder;
my $schema  = Koha::Database->new->schema;
$schema->storage->txn_begin;
my $builder = t::lib::TestBuilder->new();
my $blockedBorrower = $builder->build({ source => 'Borrower', value => {
    branchcode => 'CPL',
} });
my $librarian = $builder->build({ source => 'Borrower', value => {
    branchcode => 'FPL',
} });
my $now = DateTime->now(time_zone => C4::Context->tz);
my $nowYMD = DateTime->now(time_zone => C4::Context->tz)->ymd('-');
my $defaultExpirationdateYMD = Koha::Plugin::Fi::KohaSuomi::SelfService::Block::_getDefaultExpirationdate()->ymd('-');
my $SSBlockCleanOlderThanThis = C4::Context->preference('SSBlockCleanOlderThanThis');

subtest("Scenario: Create a block without a logged in user", sub {
    plan tests => 2;

    throws_ok(sub {
        my $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({}); #This should throw
        Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock($block);
    }, 'Koha::Exceptions::Plugin::ForbiddenAction');
    like($@, qr/Trying to create .+?Koha::Plugin::Fi::KohaSuomi::SelfService::Block/);
});

subtest("Scenario: Having logged in, create a block", sub {
    plan tests => 9;
    my $expectedBlock = { #This is what this subtest should result in.
        borrowernumber => $blockedBorrower->{borrowernumber},
        branchcode     => 'FPL',
        expirationdate => $now->clone()->add(days => C4::Context->preference('SSBlockDefaultDuration')),
        notes          => 'this is a no note',
        created_by     => $librarian->{borrowernumber},
        created_on     => $now->iso8601(),
    };

    login();

    ok(my $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
        borrowernumber => $expectedBlock->{borrowernumber},
        branchcode     => $expectedBlock->{branchcode},
        #expirationdate => $expectedBlock->{expirationdate}, #Let the constructor automatically set the expiration date based on defaults
        notes          => 'this is a no note',
    }),  "When a block is created");

    ok($block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock($block),
        "And the block is persisted");

    is($block->{created_by}, $librarian->{borrowernumber},
        "Then the block has the created_by autovivificated");
    is($block->{created_on}->ymd('-'), $now->ymd('-'),
        "And the created_on is now");
    is($block->{expirationdate}->ymd('-'), $expectedBlock->{expirationdate}->ymd('-'),
        "And the expirationdate uses NOW() + syspref 'SSBlockDefaultDuration'");
    is($block->{borrowernumber}, $blockedBorrower->{borrowernumber},
        "And the borrowernumber is as expected");
    is($block->{branchcode}, $expectedBlock->{branchcode},
        "And the branchcode is as expected");
    is($block->{notes}, $expectedBlock->{notes},
        "And the notes is as expected");
});

subtest("Scenario: Persist blocks with bad foreign key references", sub {
    plan tests => 6;

    throws_ok(sub {
        Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({    #This throws
                                                 borrowernumber => 9999,
                                                 branchcode     => 'CPL',
                                                 notes          => 'this is a no note2',
                                             }));
    }, 'Koha::Exceptions::Patron',
        "Given a bad borrower, we get a foreign key exception");
    like($@, qr/Missing Borrower when trying to add/);

    ok(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
                                                 borrowernumber => $blockedBorrower->{borrowernumber},
                                                 branchcode     => 'CPL',
                                                 notes          => 'this is a no note2',
                                             })),
        "Given a good borrowernumber, no exceptions are thrown");

    throws_ok(sub {
        Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({    #This throws
                                                 borrowernumber => $blockedBorrower->{borrowernumber},
                                                 branchcode     => 'NOT_EXISTS',
                                                 notes          => 'this is a no note3',
                                             }));
    }, 'Koha::Exceptions::Library::NotFound',
        "Given a bad branch, we get a foreign key exception");
    like($@, qr/Missing Branch when trying to add/);

    ok(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({    #This throws
                                                 borrowernumber => $blockedBorrower->{borrowernumber},
                                                 branchcode     => 'FPL',
                                                 notes          => 'this is a no note3',
                                             })),
        "Given a good branchcode, no exceptions are thrown");
});

subtest("Scenario: List all the blocks the bad borrower has accumulated so far", sub {
    plan tests => 4;

    ok(my $blocks = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::listBlocks($blockedBorrower->{borrowernumber}),
        "When all the blocks for a borrower are fetched");

    my $maketest = sub {
        return Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable(
            {
                borrowernumber       => $blockedBorrower->{borrowernumber},
                branchcode           => $_[0],
                expirationdate       => re(qr/^$defaultExpirationdateYMD/),
                notes                => re(qr/this is a no note/),
                created_by           => $librarian->{borrowernumber},
                created_on           => re(qr/^$nowYMD/),
            },
        );
    };
    cmp_deeply($blocks, [
        $maketest->('FPL'),
        $maketest->('CPL'),
        $maketest->('FPL'),
    ], "Then all the blocks are as expected");

    ok(my $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::getBlock($blocks->[0]->id),
        "When a single block has been fetched");

    cmp_deeply($block, $maketest->('FPL'),
        "Then the block is as expected");
});

subtest("Scenario: List only active blocks", sub {
    plan tests => 7;

    ok(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
        borrower       => $librarian,
        branchcode     => 'IPT',
        expirationdate => '2010-01-01',
    })),
        "Given the librarian had an expired block"); #What a rascal in his youth!

    ok(my $blocks = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::listBlocks($librarian, $now),
        "When all the blocks for the librarian are fetched for today");

    cmp_deeply($blocks, [], "Then there are no active blocks");

    ok($blocks = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::listBlocks($blockedBorrower, $now->clone()->add(years => 1)),
        "When all the blocks for the bad borrower are fetched, as if the current date was 1 year to the future");

    cmp_deeply($blocks, [], "Then the old block has expired");

    #Make sure that the precondition of having existing blocks is still in effect in this test Scenario
    ok($blocks = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::listBlocks($blockedBorrower),
        "However");

    is(scalar(@$blocks), 3,
        "Bad borrower still has active blocks today");
});

subtest("Scenario: Edit an existing block", sub {
    plan tests => 4;

    ok(my $blocks = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::listBlocks($blockedBorrower->{borrowernumber}),
        "Given all the blocks for a borrower");

    my $edited = $blocks->[0];
    $edited->{expirationdate} = DateTime->now()->add(days => 30);
    $edited->{notes}          = 'this is a no note4';

    ok(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock($edited),
        "When a block has been edited");

    is(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::getBlock($edited->id())->expirationdate->iso8601, $edited->expirationdate->iso8601,
        "Then the changes are persisted to the DB - expirationdate");
    is(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::getBlock($edited->id())->{notes}, $edited->{notes},
        "Then the changes are persisted to the DB - notes");
});

subtest("Scenario: Delete remaining blocks", sub {
    plan tests => 6;

    ok(my $blocks = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::listBlocks($blockedBorrower),
        "Given all the blocks for a borrower");

    my $deletedBlock = shift(@$blocks);
    is(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::deleteBlock($deletedBlock), 1, # Returns the number of rows deleted
        "When a block has been deleted");

    ok(not(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::getBlock($deletedBlock->id())),
        "Then block no. 1 no longer exists in DB");

    is(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::deleteBorrowersBlocks($blockedBorrower->{borrowernumber}), 2, # Returns the number of rows deleted
        "When all the two remaining blocks for a borrower have been deleted");

    ok(not(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::getBlock($blocks->[0]->id())),
        "Then block no. 2 no longer exists in DB");
    ok(not(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::getBlock($blocks->[1]->id())),
        "Then block no. 3 no longer exists in DB");
});

subtest("Scenario: Check if a Borrower has blocks", sub {
    plan tests => 11;

    my @blocks;
    ok($blocks[0] = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
        borrowernumber => $blockedBorrower->{borrowernumber},
        branchcode     => 'CPL',
    })),
        "Given a simple block has been given");

    ok(my $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::hasBlock($blockedBorrower, 'CPL'),
        "When the borrower is checked for blocks");

    cmp_deeply($block, Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable({
                           borrowernumber       => $blockedBorrower->{borrowernumber},
                           branchcode           => 'CPL',
                       }),
        "Then a block is found to be in effect");

    ok(! Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::hasBlock($blockedBorrower, 'CPL', DateTime->now(time_zone => C4::Context->tz)->add(years => 1)),
        "When the borrower's block has expired, the block is no longer in effect");

    ok(! Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::hasBlock($librarian->{borrowernumber}, 'CPL'),
        "When the borrower is not blocked in the first place, there is no block");



    subtest("Scenario: Test implicitly getting the branch to check for blocks from the loggedinbranch", sub {
        plan tests => 4;

        ok($blocks[0] = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
            borrowernumber => $blockedBorrower->{borrowernumber},
            branchcode     => 'FPL',
        })),
            "Given a block to the loggedinbranch FPL has been given");

        ok($block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::hasBlock($blockedBorrower),
            "When the block is checked for without explicitly providing the branch to check for");

        cmp_deeply($block, Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable({
            borrowernumber       => $blockedBorrower->{borrowernumber},
            branchcode           => 'FPL',
        }),
            "Then the block is in effect");

        ok(! Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::hasBlock($blockedBorrower, undef, DateTime->now(time_zone => C4::Context->tz)->add(years => 1)),
            "When the block is checked for without explicitly providing the branch and the borrower's block has expired, the block is no longer in effect");
    });


    # Test for exceptions

    throws_ok(sub { Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::hasBlock() }, 'Koha::Exceptions::BadParameter',
        "When checking without a borrowernumber");
    like($@, qr/mandatory parameter borrowernumber is not defined/,
        "Then the proper exception is caught, with a proper description of the error");

    C4::Context::_unset_userenv( 'DUMMY SESSION' );
    ok(1, "Given the user logs out");

    throws_ok(sub { Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::hasBlock(1002) }, 'Koha::Exceptions::Plugin::ForbiddenAction',
        "When checking without a branchcode, trying to infer defaults from loggedinuser");
    like($@, qr/but nobody is logged in/,
        "Then the proper exception is caught, with a proper description of the error");
});

subtest("Scenario: Cleanup stale blocks", sub {
    plan tests => 9;
    my @blocks;

    ok(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::cleanup(-360),
        "Given all blocks have been cleaned");

    login();

    ok($blocks[0] = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
        borrower       => $blockedBorrower,
        branchcode     => 'IPT',
        expirationdate => $now->clone()->subtract(days => $SSBlockCleanOlderThanThis-1),
    })),
        "Given a block which is due for tomorrow");

    ok($blocks[1] = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
        borrower       => $blockedBorrower,
        branchcode     => 'FPL',
        expirationdate => $now->clone()->subtract(days => $SSBlockCleanOlderThanThis),
    })),
        "And a block which is due for cleanup today");

    ok($blocks[2] = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
        borrower       => $blockedBorrower,
        branchcode     => 'FPL',
        expirationdate => $now->clone()->subtract(days => $SSBlockCleanOlderThanThis+1),
    })),
        "And a block which was due for cleanup yesterday");


    is(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::cleanup(), 2,
        "when all blocks for today have been cleaned");

    cmp_deeply(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::listBlocks($blockedBorrower), [Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable({
        expirationdate => re($now->clone()->subtract(days => $SSBlockCleanOlderThanThis - 1)->ymd()),
        branchcode     => 'IPT',
    })],
        "Then the block due for cleaning tomorrow remains");


    is(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::cleanup( $now->clone()->subtract(days => $SSBlockCleanOlderThanThis+1) ), 1,
        "when all blocks for tomorrow have been cleaned");

    cmp_deeply(Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::listBlocks($blockedBorrower), [],
        "Then nothing remains");
});

subtest("Scenario: Verify action logs are created.", sub {
    plan tests => 2;

    ok(my $logs = Koha::Plugin::Fi::KohaSuomi::SelfService::GetAccessLogs($librarian->{borrowernumber}),
        "Given all the self-service branch specific block action log entries");

    is(@$logs, 0,
        "Then there are no logs, since the Block-API doesn't generate ActionLog-entries");
});

done_testing();

$schema->storage->txn_rollback;

sub login {
    C4::Context->_new_userenv('DUMMY SESSION');
    ok(my $userenv = C4::Context->set_userenv($librarian->{borrowernumber},$librarian->{userid},'SSAPIUser','firstname','surname', 'FPL', 'FPL', 0, '', ''),
        "Given a logged in librarian");
}
