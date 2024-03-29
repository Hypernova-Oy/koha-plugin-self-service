#!/usr/bin/env perl

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

BEGIN {
    #$ENV{LOG4PERL_VERBOSITY_CHANGE} = 6;
    #$ENV{MOJO_OPENAPI_DEBUG} = 1;
    #$ENV{MOJO_LOG_LEVEL} = 'debug';
    $ENV{VERBOSE} = 1;
    $ENV{KOHA_PLUGIN_DEV_MODE} = 1;
}

use Modern::Perl;
use utf8;

use Test::More tests => 5;
use Test::Deep;
use Test::Mojo;

use t::lib::TestBuilder;
use t::lib::Mocks;
use t::db_dependent::Util qw(build_patron);
use Mojo::Cookie::Request;

use Koha::Database;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Block;
use Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager;

my $schema = Koha::Database->schema;
my $builder = t::lib::TestBuilder->new;
$t::db_dependent::Util::builder = $builder;

my $t = Test::Mojo->new('Koha::REST::V1');
t::lib::Mocks::mock_preference( 'RESTBasicAuth', 1 );

subtest "List/GET blocks when there are no blocks to list" => sub {
    plan tests => 15;

    $schema->storage->txn_begin;

    my ($patron, $host) = build_patron();
    my ($librarian, $librarian_host) = build_patron({
        permissions => [
            { module => 4, subpermission => 'ss_blocks_list' },
        ]
    });

    $t->get_ok($host . '/api/v1/contrib/kohasuomi/borrowers/'.$librarian->borrowernumber.'/ssblocks')
      ->status_is('403')
      ->json_like('/error', qr/Missing required permission/, 'List: No permission');


    $t->get_ok($host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks')
      ->status_is('404')
      ->json_like('/error', qr/No self-service blocks/,
        "No self-service blocks (allow-owner access)");


    $t->get_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks')
      ->status_is('404')
      ->json_like('/error', qr/No self-service blocks/,
        "No self-service blocks");


    $t->get_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks/0')
      ->status_is('403')
      ->json_like('/error', qr/Missing required permission/, 'GET: No permission');


    ($librarian, $librarian_host) = build_patron({
        permissions => [
            { module => 4, subpermission => 'ss_blocks_get' },
        ]
    });

    $t->get_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks/0')
      ->status_is('404')
      ->json_like('/error', qr/No such self-service block/,
        "No such self-service block");


    $schema->storage->txn_rollback;
};

subtest '/borrowers/{borrowernumber}/ssblocks POST' => sub {
    plan tests => 13;

    $schema->storage->txn_begin;

    my ($patron, $host) = build_patron();
    my ($librarian, $librarian_host) = build_patron({
        permissions => [
            { module => 4, subpermission => 'ss_blocks_create' },
        ]
    });

    my @blocks = (
        { borrowernumber => $librarian->borrowernumber, branchcode => 'CPL', created_by => $librarian->borrowernumber, notes => 'asd', expirationdate => DateTime->now(time_zone => C4::Context->tz())->add(days => 1)->datetime(' ') },
        { borrowernumber => $patron->borrowernumber, branchcode => 'FPL', created_by => $librarian->borrowernumber, notes => undef, },
        { borrowernumber => $patron->borrowernumber, branchcode => 'IPT', created_by => $librarian->borrowernumber, notes => '', },
    );

    $t->post_ok($host . '/api/v1/contrib/kohasuomi/borrowers/'.$librarian->borrowernumber.'/ssblocks' => {Accept => '*/*'} => json => $blocks[0])
      ->status_is('403')
      ->json_like('/error', qr/Missing required permission/, 'No permission');


    for my $i (0..$#blocks) {
        $t->post_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$blocks[$i]->{borrowernumber}.'/ssblocks' => {Accept => '*/*'} => json => $blocks[$i])
          ->status_is('200');
        print($t->tx->res->body);
    
        cmp_deeply($t->tx->res->json, noclass(Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable($blocks[$i])));
        $blocks[$i]->{borrower_ss_block_id} = $t->tx->res->json->{borrower_ss_block_id};
    }

    subtest("Scenario: Sanitate XSS", sub {
        plan tests => 3;

        push(@blocks, { borrowernumber => $patron->borrowernumber, branchcode => 'CPL', notes => '<<script></script>script>...</script>'});
        $t->post_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks' => {Accept => '*/*'} => json => $blocks[3])
          ->status_is('200')
          ->json_is('/notes', '😄😄script😆😄/script😆script😆...😄/script😆',
            "notes-field sanitated against xss");
    
        $blocks[3]->{borrower_ss_block_id} = $t->tx->res->json->{borrower_ss_block_id};
    });

    $schema->storage->txn_rollback;
};

subtest "List/GET blocks when there is something to list/GET" => sub {
    plan tests => 10;

    $schema->storage->txn_begin;

    my ($patron, $host) = build_patron();
    my ($librarian, $librarian_host) = build_patron({
        permissions => [
            { module => 4, subpermission => 'ss_blocks_list' },
            { module => 4, subpermission => 'ss_blocks_get' },
        ]
    });

    my @blocks = (
        { borrowernumber => $librarian->borrowernumber, branchcode => 'CPL', created_by => $librarian->borrowernumber, notes => 'asd', expirationdate => DateTime->now(time_zone => C4::Context->tz())->add(days => 1)->datetime(' ') },
        { borrowernumber => $patron->borrowernumber, branchcode => 'FPL', created_by => $librarian->borrowernumber, notes => undef, },
        { borrowernumber => $patron->borrowernumber, branchcode => 'IPT', created_by => $librarian->borrowernumber, notes => '', },
    );
    foreach my $block (@blocks) {
        $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock(
            Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock($block)
        );
        $block->{'created_on'} = $block->{'created_on'}->strftime('%Y-%m-%d %H:%M:%S');
        $block->{'expirationdate'} = $block->{'expirationdate'}->strftime('%Y-%m-%d %H:%M:%S') if ref($block->{expirationdate}) eq 'DateTime';
    }

    $t->get_ok($host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks')
      ->status_is('200');

    cmp_deeply(
        $t->tx->res->json,
        [
            noclass(Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable($blocks[1])),
            noclass(Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable($blocks[2]))
        ],
        "Blocked Borrower 1 has two blocks");

    $t->get_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$librarian->borrowernumber.'/ssblocks')
      ->status_is('200');

    cmp_deeply(
        $t->tx->res->json,
        [noclass(Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable($blocks[0]))],
        "Blocked Borrower 2 has one blocks");

    $t->get_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$librarian->borrowernumber.'/ssblocks/'.$blocks[0]->{borrower_ss_block_id})
      ->status_is('200');

    cmp_deeply($t->tx->res->json, noclass(Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable($blocks[0])),
        "Get Block");


    subtest("Scenario: Expired blocks are not returned by default", sub {
        plan tests => 4;

        ok(my $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
            borrower       => $patron->unblessed,
            branchcode     => 'IPT',
            created_by     => $librarian->borrowernumber,
            expirationdate => '2010-01-01',
        })),
            "Blocked Borrower 1 is given an expired block");

        $t->get_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks')
          ->status_is('200');
    
        cmp_deeply(
            $t->tx->res->json,
            [
                noclass(Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable($blocks[1])),
                noclass(Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable($blocks[2]))
            ],
            "Blocked Borrower 1 still has two blocks");
    });

    $schema->storage->txn_rollback;
};

subtest '/borrowers/{borrowernumber}/ssblocks DELETE' => sub {
    plan tests => 15;

    $schema->storage->txn_begin;

    my ($patron, $host) = build_patron();
    my ($librarian, $librarian_host) = build_patron({
        permissions => [
            { module => 4, subpermission => 'ss_blocks_delete' },
        ]
    });

    my @blocks = (
        { borrowernumber => $librarian->borrowernumber, branchcode => 'CPL', created_by => $librarian->borrowernumber, notes => 'asd', expirationdate => DateTime->now(time_zone => C4::Context->tz())->add(days => 1)->datetime(' ') },
        { borrowernumber => $patron->borrowernumber, branchcode => 'FPL', created_by => $librarian->borrowernumber, notes => undef, },
        { borrowernumber => $patron->borrowernumber, branchcode => 'IPT', created_by => $librarian->borrowernumber, notes => '', },
    );
    foreach my $block (@blocks) {
        $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock(
            Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock($block)
        );
    }

    $t->delete_ok($host . '/api/v1/contrib/kohasuomi/borrowers/'.$librarian->borrowernumber.'/ssblocks')
      ->status_is('403')
      ->json_like('/error', qr/Missing required permission/, 'No permission');


    $t->delete_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks')
      ->status_is('200');

    cmp_deeply($t->tx->res->json, {deleted_count => 2},
        "Deleted all Blocks and deleted_count is as expected");

    $t->delete_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks')
      ->status_is('200');

    cmp_deeply($t->tx->res->json, {deleted_count => 0},
        "Deleted all Blocks and deleted_count is zero");

    $t->delete_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks/'.$blocks[0]->{borrower_ss_block_id})
      ->status_is('200');

    cmp_deeply($t->tx->res->json, {deleted_count => 1},
        "Deleted a single Block and deleted_count is 1");

    $t->delete_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks/'.$blocks[0]->{borrower_ss_block_id})
      ->status_is('200');

    cmp_deeply($t->tx->res->json, {deleted_count => 0},
        "Trying to delete a single Block which doesn't exist and deleted_count is 0");

    $schema->storage->txn_rollback;
};

subtest "/borrowers/{borrowernumber}/ssblocks/hasblock/{branchcode}" => sub {
    plan tests => 7;

    $schema->storage->txn_begin;

    my ($patron, $host) = build_patron();
    my ($librarian, $librarian_host) = build_patron({
        permissions => [
            { module => 4, subpermission => 'ss_blocks_get' },
        ]
    });

    ok(my $block = Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::storeBlock( Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager::createBlock({
        borrowernumber => $patron->borrowernumber,
        branchcode     => 'CPL',
        created_by     => $librarian->borrowernumber
    })),
        "Given a simple block has been given");

    $t->get_ok($host . '/api/v1/contrib/kohasuomi/borrowers/'.$patron->borrowernumber.'/ssblocks/hasblock/'.'CPL')
      ->status_is('200');

    cmp_deeply(
        $t->tx->res->json,
        noclass(Koha::Plugin::Fi::KohaSuomi::SelfService::Block::get_deeply_testable({
            borrowernumber => $patron->borrowernumber,
            branchcode => 'CPL',})),
        "Borrower is blocked to branch CPL");

    $t->get_ok($librarian_host . '/api/v1/contrib/kohasuomi/borrowers/'.$librarian->borrowernumber.'/ssblocks/hasblock/'.'IPT')
      ->status_is('204');

    cmp_deeply(
        $t->tx->res->json, undef,
        "Borrower is blocked to branch IPT");

    $schema->storage->txn_rollback;
};

1;
