package Koha::Plugin::Fi::KohaSuomi::SelfService::Log;

use Data::Dumper;

require Exporter;
@ISA = qw(Exporter);

@EXPORT_OK = qw(
    toString
);

sub toString {
    $Data::Dumper::Indent = 0;
    return Data::Dumper::Dumper($_[0]);
}

1;
