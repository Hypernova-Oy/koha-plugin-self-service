package Koha::Plugin::Fi::KohaSuomi::SelfService::BlockManager;

# Copyright 2018 Hypernova Oy
#
# This file is part of Koha.
#

use Modern::Perl '2015';

use Try::Tiny;
use Scalar::Util qw(blessed);

use Storable;

use C4::Context;
use Koha::Plugin::Fi::KohaSuomi::SelfService;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Block;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Log qw(toString);

use Koha::Exceptions;
use Koha::Plugin::Fi::KohaSuomi::SelfService::Exception;

use Koha::Logger;
my $logger = Koha::Logger->get;

our $actionLogModuleName = 'SELF-SERVICE';

my $plugin = Koha::Plugin::Fi::KohaSuomi::SelfService->new();

my %sqlCache;

=head2 cleanup

Removes old blocks from the database

 @param1 {Integer} OPTIONAL. Number of days. Remove blocks that have been expired longer than this. Defaults to syspref 'SSBlockCleanOlderThanThis'
 @returns {Integer} The number of rows affected. See DBI::execute
 @throws Koha::Exceptions::Exception
 @throws Koha::Exception::SelfService::FeatureUnavailable, if syspref 'SSBlockCleanOlderThanThis' is not set and no days are given as parameter.

=cut

sub cleanup {
    my $maxAgeDays = $_[0] // C4::Context->preference('SSBlockCleanOlderThanThis');
    Koha::Exception::SelfService::FeatureUnavailable->throw(error => "Trying to clean stale self-service branch-specific blocks, but the syspref 'SSBlockCleanOlderThanThis' is not properly configured.") unless(defined($maxAgeDays));
    $logger->info("Cleaning blocks older than '$maxAgeDays' days") if $logger->is_info();

    my $dbh = C4::Context->dbh();
    my $table = $plugin->get_qualified_table_name('borrower_ss_blocks');

    if (_isSthStale($sqlCache{cleanBlockSth}, $dbh)) {
        $logger->debug(sprintf("Preparing a new statement using '%s' to clean blocks", $dbh->{Driver})) if $logger->is_debug();
        $sqlCache{cleanBlockSth} = $dbh->prepare("DELETE FROM $table WHERE DATEDIFF(NOW(), expirationdate) >= ?") || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    }

    my $count = $sqlCache{cleanBlockSth}->execute($maxAgeDays) || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    $logger->info("Cleaned '$count' blocks");

    return $count;
}

=head2 createBlock

 @param1 {HASHRef} Block attributes
                   ->{borrower} is a shorthand for passing a borrowerish object to get the borrowernumber from.

=cut

sub createBlock {
    my $b = Storable::dclone($_[0]);
    if ($b->{borrower}) {
        $b->{borrowernumber} = eval{$b->{borrower}->borrowernumber} || eval{$b->{borrower}->{borrowernumber}} || $b->{borrower}; #Make it possible to write smoothly flowing code with simple usability hacks
        delete $b->{borrower};
    }

    return Koha::Plugin::Fi::KohaSuomi::SelfService::Block->new($b);
}

=head2 deleteBlock

 @param1 {Koha::Plugin::Fi::KohaSuomi::SelfService::Block || Integer} Do not use Integer if possible.
 @returns {Integer} The number of rows affected. See DBI::execute
 @throws Koha::Exceptions::Exception

=cut

sub deleteBlock {
    my ($block) = @_;
    my $borrower_ss_block_id = (blessed($block)) ? $block->id : $block;
    $logger->debug("Deleting block id '$borrower_ss_block_id'") if $logger->is_debug();

    my $dbh = C4::Context->dbh();
    my $table = $plugin->get_qualified_table_name('borrower_ss_blocks');

    if (_isSthStale($sqlCache{deleteBlockSth}, $dbh)) {
        $logger->debug(sprintf("Preparing a new statement using '%s' to delete block '%s'", $dbh->{Driver}, $borrower_ss_block_id)) if $logger->is_debug();
        $sqlCache{deleteBlockSth} = $dbh->prepare("DELETE FROM $table WHERE borrower_ss_block_id = ?") || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    }

    my $deletedCount = $sqlCache{deleteBlockSth}->execute($borrower_ss_block_id) || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    C4::Log::logaction($actionLogModuleName, 'BRANCHBLOCK-DEL', $borrower_ss_block_id, undef);
    return $deletedCount;
}

=head2 deleteBorrowersBlocks

 @param1 {Integer || HASHRef || Koha::Patron} The borrower whose blocks to delete
 @returns {Integer} The number of rows affected. See DBI::execute
 @throws Koha::Exceptions::Exception

=cut

sub deleteBorrowersBlocks {
    my $borrowernumber = $_[0] ? eval{$_[0]->borrowernumber} || eval{$_[0]->{borrowernumber}} || $_[0] : $_[0];
    my $dbh = C4::Context->dbh();
    my $table = $plugin->get_qualified_table_name('borrower_ss_blocks');

    if (_isSthStale($sqlCache{deleteBorrowersBlocksSth}, $dbh)) {
        $logger->debug(sprintf("Preparing a new statement using '%s' to delete borrowers '%s' blocks", $dbh->{Driver}, $borrowernumber)) if $logger->is_debug();
        $sqlCache{deleteBorrowersBlocksSth} = $dbh->prepare("DELETE FROM $table WHERE borrowernumber = ?") || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    }

    my $rowsDeleted = $sqlCache{deleteBorrowersBlocksSth}->execute($borrowernumber) || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    C4::Log::logaction($actionLogModuleName, 'BRANCHBLOCK-DELALL', $borrowernumber, undef);
    return $rowsDeleted;
}

=head2 getBlock

 @param1 {Integer} borrower_ss_block_id
 @returns {Koha::Plugin::Fi::KohaSuomi::SelfService::Block}
 @throws Koha::Exceptions::Exception

=cut

sub getBlock {
    my ($borrower_ss_block_id) = @_;
    my $dbh = C4::Context->dbh();
    my $table = $plugin->get_qualified_table_name('borrower_ss_blocks');

    if (_isSthStale($sqlCache{getBlockSth}, $dbh)) {
        $logger->debug(sprintf("Preparing a new statement using '%s' to delete block '%s'", $dbh->{Driver}, $borrower_ss_block_id)) if $logger->is_debug();
        $sqlCache{getBlockSth} = $dbh->prepare("SELECT * FROM $table WHERE borrower_ss_block_id = ?") || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    }

    my ($block) = $dbh->selectall_array($sqlCache{getBlockSth}, { Slice => {} }, $borrower_ss_block_id);
    Koha::Exceptions::Exception->throw(error => $dbh->errstr()) if $dbh->errstr();
    bless($block, 'Koha::Plugin::Fi::KohaSuomi::SelfService::Block') if ($block);
    $logger->debug(sprintf("Got '%s'", ($block) ? toString($block): 'undef')) if $logger->is_debug();
    return $block;
}

=head2 hasBlock

 @param1 {Integer or Koha::Patron or HASH}  borrowernumber whose blocks to inspect
 @param2 {String}   OPTIONAL. Branchcode of the library we check the block for. Defaults to C4::Context->userenv->{branch} (the loggedinbranch) if omitted.
 @param3 {DateTime or ISO8601-String} OPTIONAL. The point in time to check for active blocks (not expired at this time). Defaults to NOW().
 @returns {Koha::Plugin::Fi::KohaSuomi::SelfService::Block or undef}
 @throws {Koha::Exceptions::Plugin::ForbiddenAction} When no branchcode is provided as a parameter and there is no logged in user whose loggedinbranch to infer

=cut

sub hasBlock {
    my $borrowernumber = $_[0] ? eval{$_[0]->borrowernumber} || eval{$_[0]->{borrowernumber}} || $_[0] : $_[0];
    Koha::Exceptions::BadParameter->throw(error => "Trying to check for blocks, but the mandatory parameter borrowernumber is not defined") unless $borrowernumber;
    my $branchcode = ($_[1])                  ? $_[1] :
                     (C4::Context->userenv()) ? C4::Context->userenv()->{branch} : undef;
    Koha::Exceptions::Plugin::ForbiddenAction->throw(error => "Trying to check for blocks, but nobody is logged in?") unless ($branchcode);
    my $expirationStatusDate = $_[2] || DateTime->now(time_zone => C4::Context->tz);
    if (ref($expirationStatusDate)) {
        $expirationStatusDate = $expirationStatusDate->iso8601();
    }

    my $dbh = C4::Context->dbh();
    my $table = $plugin->get_qualified_table_name('borrower_ss_blocks');

    if (_isSthStale($sqlCache{hasBlockSth}, $dbh)) {
        $logger->debug(sprintf("Preparing a new statement using '%s' to check blocks for bn:'%s' branch:'%s' date:'%s'", $dbh->{Driver}, $borrowernumber, $branchcode, $expirationStatusDate)) if $logger->is_debug();
        $sqlCache{hasBlockSth} = $dbh->prepare("SELECT * FROM $table WHERE borrowernumber = ? AND branchcode = ? AND expirationdate >= ?") || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    }

    my ($block) = $dbh->selectall_array($sqlCache{hasBlockSth}, { Slice => {} }, $borrowernumber, $branchcode, $expirationStatusDate);
    Koha::Exceptions::Exception->throw(error => $dbh->errstr()) if $dbh->errstr();
    $block = bless($block, 'Koha::Plugin::Fi::KohaSuomi::SelfService::Block') if ($block);
    $logger->debug(sprintf("Checked '%s'", ($block) ? toString($block): 'undef')) if $logger->is_debug();
    return $block;
}

=head2 listBlocks

 @param1 {Integer || HASHRef || Koha::Patron} The borrower whose blocks to list
 @param2 {DateTime or ISO8601-String} OPTIONAL. The point in time to check for active blocks (not expired at this time). Defaults to list all blocks regardless of expiration.
 @returns {ARRAYRef of Koha::Plugin::Fi::KohaSuomi::SelfService::Block}
 @throws Koha::Exceptions::Exception

=cut

sub listBlocks {
    my $borrowernumber = $_[0] ? eval{$_[0]->borrowernumber} || eval{$_[0]->{borrowernumber}} || $_[0] : $_[0];
    my $expirationStatusDate = $_[1] || '0000-00-00';
    if (ref($expirationStatusDate)) {
        $expirationStatusDate = $expirationStatusDate->iso8601();
    }

    my $dbh = C4::Context->dbh();
    my $table = $plugin->get_qualified_table_name('borrower_ss_blocks');

    if (_isSthStale($sqlCache{listBlockSth}, $dbh)) {
        $logger->debug(sprintf("Preparing a new statement using '%s' to get blocks for borrowernumber '%s'", $dbh->{Driver}, $borrowernumber)) if $logger->is_debug();
        $sqlCache{listBlockSth} = $dbh->prepare("SELECT * FROM $table WHERE borrowernumber = ? AND expirationdate >= ?") || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    }

    my @blocks = $dbh->selectall_array($sqlCache{listBlockSth}, { Slice => {} }, $borrowernumber, $expirationStatusDate);
    Koha::Exceptions::Exception->throw(error => $dbh->errstr()) if $dbh->errstr();
    @blocks = map {my $b = $_; bless($b, 'Koha::Plugin::Fi::KohaSuomi::SelfService::Block')} @blocks;
    return \@blocks;
}

=head2 storeBlock

Persist a Koha::Plugin::Fi::KohaSuomi::SelfService::Block to the DB

 @param1 {Koha::Plugin::Fi::KohaSuomi::SelfService::Block}
 @throws Koha::Exceptions::Exception
 @throws Koha::Exceptions::Patron
 @throws Koha::Exceptions::Library::NotFound

=cut

sub storeBlock {
    my ($block) = @_;
    my $dbh = C4::Context->dbh();

    _checkForeignKeys($block);

    $block->xssScrub();

    my $table = $plugin->get_qualified_table_name('borrower_ss_blocks');

    #UPDATE
    if ($block->id) {
        if (_isSthStale($sqlCache{updateBlockSth}, $dbh)) {
            $logger->debug(sprintf("Preparing a new statement using '%s' to update %s", $dbh->{Driver}, toString($block))) if $logger->is_debug();
            $sqlCache{updateBlockSth} = $dbh->prepare("UPDATE $table SET borrowernumber = ?, branchcode = ?, expirationdate = ?, notes = ? WHERE borrower_ss_block_id = ?");
        }

        #TODO Updating an existing block has some limitations? Disallow changing branch etc. Easier to implement traceability
        $sqlCache{updateBlockSth}->execute(
            $block->{borrowernumber},
            $block->{branchcode},
            $block->{expirationdate},
            $block->{notes},
            $block->{borrower_ss_block_id},
        ) || Koha::Exceptions::Exception->throw(error => $sqlCache{createBlockSth}->errstr());

        C4::Log::logaction($actionLogModuleName, 'BRANCHBLOCK-MOD', $block->{borrower_ss_block_id}, $block->toYaml());
    }
    #INSERT
    else {
        if (_isSthStale($sqlCache{createBlockSth}, $dbh)) {
            $logger->debug(sprintf("Preparing a new statement using '%s' to create %s", $dbh->{Driver}, toString($block))) if $logger->is_debug();
            $sqlCache{createBlockSth} = $dbh->prepare("INSERT INTO $table VALUES (?,?,?,?,?,?,?)");
        }

        $sqlCache{createBlockSth}->execute(
            undef,
            $block->{borrowernumber},
            $block->{branchcode},
            $block->{expirationdate},
            $block->{notes},
            $block->{created_by},
            $block->{created_on},
        ) || Koha::Exceptions::Exception->throw(error => $sqlCache{createBlockSth}->errstr());
        $block->{borrower_ss_block_id} = $sqlCache{createBlockSth}->{mysql_insertid} // $sqlCache{createBlockSth}->last_insert_id() // Koha::Exceptions::Exception->throw(error => "Couldn't get the last_insert_id from a newly created block $block");

        C4::Log::logaction($actionLogModuleName, 'BRANCHBLOCK-ADD', $block->{borrower_ss_block_id}, $block->toYaml());
    }

    return $block;
}

#invalidate cache if dbh reference changes. This means that the connection has been lost.
sub _isSthStale {
    my ($sth, $dbh) = @_;
    return 1 unless $sth;
    return not(_sameDBConn($sth, $dbh));
}
sub _sameDBConn {
    my ($sth, $dbh) = @_;
    return $sth->{Database}->{Driver} eq $dbh->{Driver};
}

=head1 Referential integrity

MySQL/MariaDB doesn't allow defining foreign key relations, which would preserve the old value ON DELETE.
Thus we need to emulate the behaviour in software, so we can preserve a solid history of blocks
regardless of coming and going branches and librarians.

=head2 _checkForeignKeys

 @param1 {Koha::Plugin::Fi::KohaSuomi::SelfService::Block}
 @throws Koha::Exceptions::Exception
 @throws Koha::Exceptions::Patron
 @throws Koha::Exceptions::Library::NotFound

=cut

sub _checkForeignKeys {
    _checkBorrowerOrCreatorExists($_[0]);
    _checkBranchExists($_[0]);
}

# Borrower is foreign key constrained and DBI throws an error if that is violated, but handling that error would lead to so much exception handling code in DB accessors, that it is much easier to check for the exception here.
# The other approach is to start refactoring the Koha's DB accessors to handle MySQL error codes and throw respective Koha-exceptions so we can display intelligent
# HTTP status codes and error messages via the REST API.
sub _checkBorrowerOrCreatorExists {
    my ($block) = @_;
    my $dbh = C4::Context->dbh();

    if (_isSthStale($sqlCache{checkBorrowerSth}, $dbh)) {
        $logger->debug(sprintf("Preparing a new statement using '%s'", $dbh->{Driver})) if $logger->is_debug();
        $sqlCache{checkBorrowerSth} = $dbh->prepare("SELECT borrowernumber FROM borrowers WHERE borrowernumber = ?") || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    }

    # This could be handled in one SQL request instead of two, but that would lead to a much more complex query. There is no practical difference here regarding performance.
    # So optimizing towards easier maintenance.
    my ($bn) = $dbh->selectrow_array($sqlCache{checkBorrowerSth}, undef, $block->created_by());
    Koha::Exceptions::Exception->throw(error => $dbh->errstr()) if $dbh->errstr();
    Koha::Exceptions::Patron->throw(error => sprintf("Missing Creator when trying to add '%s'", toString($block))) unless $bn;

    ($bn) = $dbh->selectrow_array($sqlCache{checkBorrowerSth}, undef, $block->borrowernumber());
    Koha::Exceptions::Exception->throw(error => $dbh->errstr()) if $dbh->errstr();
    Koha::Exceptions::Patron->throw(error => sprintf("Missing Borrower when trying to add '%s'", toString($block))) unless $bn;

    return 1;
}

sub _checkBranchExists {
    my ($block) = @_;
    my $dbh = C4::Context->dbh();

    if (_isSthStale($sqlCache{checkBranchSth}, $dbh)) { #invalidate cache if dbh reference changes. This means that the connection has been lost.
        $logger->debug(sprintf("Preparing a new statement using '%s'", $dbh->{Driver})) if $logger->is_debug();
        $sqlCache{checkBranchSth} = $dbh->prepare("SELECT branchcode FROM branches WHERE branchcode = ?") || Koha::Exceptions::Exception->throw(error => $dbh->errstr());
    }

    my ($bc) = $dbh->selectrow_array($sqlCache{checkBranchSth}, undef, $block->branchcode());
    Koha::Exceptions::Exception->throw(error => $dbh->errstr()) if $dbh->errstr();
    Koha::Exceptions::Library::NotFound->throw(error => sprintf("Missing Branch when trying to add '%s'", toString($block))) unless $bc;
    return $bc;
}

1;
