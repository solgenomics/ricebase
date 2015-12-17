#!/usr/bin/env perl

=head1

load_accessions.pl

=head1 SYNOPSIS

    $load_accessions.pl -H [dbhost] -D [dbname] -I [input file] -o [ownername] -s [speciesname] -p [population name] 

=head1 COMMAND-LINE OPTIONS

 -H  host name
 -D  database name
 -o  owner name
 -s  species name
 -p  population name
 -t  Test run . Rolling back at the end.

=head2 DESCRIPTION


=head2 AUTHOR

Jeremy D. Edwards (jde22@cornell.edu)

May 2015

=head2 TODO

Add support for other spreadsheet formats

=cut

use strict;
use warnings;

use lib 'lib';
use Getopt::Std;
use Bio::Chado::Schema;
use CXGN::Phenome::Schema;
use Spreadsheet::ParseExcel;
use CXGN::DB::InsertDBH;
use CXGN::DB::Connection;
use CXGN::Stock::AddStocks;
use SGN::Schema;
use Try::Tiny;

our ($opt_H, $opt_D, $opt_I, $opt_o, $opt_s, $opt_p);
getopts('H:D:I:o:s:p:');

sub print_help {
  print STDERR "A script to load accessions\nUsage: load_accessions.pl -D [database name] -H [database host, e.g., localhost] -I [input file] -o [owner name] -s [species name] -p [accession panel] \n";
}

if (!$opt_D || !$opt_H || !$opt_I || !$opt_o) {
  print_help();
  die("Exiting: options missing\n");
}

#try to open the excel file and report any errors
my $parser   = Spreadsheet::ParseExcel->new();
my $excel_obj = $parser->parse($opt_I);

if ( !$excel_obj ) {
  die "Input file error: ".$parser->error()."\n";
}

my $worksheet = ( $excel_obj->worksheets() )[0]; #support only one worksheet
my ( $row_min, $row_max ) = $worksheet->row_range();
my ( $col_min, $col_max ) = $worksheet->col_range();

if (($col_max - $col_min)  < 0 || ($row_max - $row_min) < 1 ) { #must have header and at least one row of accessions (no column check)
  die "Input file error: spreadsheet is missing header\n";
}

my $accession_name_head;

if ($worksheet->get_cell(0,0)) {
  $accession_name_head  = $worksheet->get_cell(0,0)->value();
}

if (!$accession_name_head || $accession_name_head ne 'accession_name') {
  die "Input file error: no \"accession_name\" in header\n";
}

my @accession_names;
my %stockprop_lookup;

for my $row ( 1 .. $row_max ) {
  my $accession_name;
  my $current_row = $row+1;
  my @stockprops;
  my @stockprop_names;

  if ($worksheet->get_cell($row,0)) {
    $accession_name = $worksheet->get_cell($row,0)->value();
  } else {
    next; #skip blank lines
  }
  push @accession_names, $accession_name;

  for my $col ( 1 .. $col_max ) {
      if ($worksheet->get_cell($row,$col)) {
	  my %stockprop_and_name;
	  $stockprop_and_name{'name'} = $worksheet->get_cell(0,$col)->value();
	  $stockprop_and_name{'value'} = $worksheet->get_cell($row,$col)->value();
	  push @stockprops, \%stockprop_and_name;
      } else {
	  next; #skip blank columns
      }
  }
  $stockprop_lookup{$accession_name}=\@stockprops;
}

my $dbh = CXGN::DB::InsertDBH
  ->new({
	 dbname => $opt_D,
	 dbhost => $opt_H,
	 dbargs => {AutoCommit => 1,
		    RaiseError => 1},
	});

my $chado_schema = Bio::Chado::Schema->connect(  sub { $dbh->get_actual_dbh() },  { on_connect_do => ['SET search_path TO  public;'] } );
my $phenome_schema = CXGN::Phenome::Schema->connect(  sub { $dbh->get_actual_dbh() }, { on_connect_do => ['set search_path to public,phenome;'] }  );

my $db_name = $opt_o;

my $coderef= sub  {
    for my $accession (@accession_names) {
	my $stock;
	$stock = $chado_schema->resultset("Stock::Stock")->find(
	    { uniquename => $accession,
	    });
	if ($stock) {
	    my @stockprop_and_names = @{$stockprop_lookup{$accession}};
	    for my $stockprop_and_name (@stockprop_and_names) {
		my $stockprop_name = $stockprop_and_name->{'name'};
		my $stockprop_value = $stockprop_and_name->{'value'};
		print STDERR "Adding stockprop of type $stockprop_name with value $stockprop_value for stock $accession.\n";
		$stock->create_stockprops({ $stockprop_name => $stockprop_value},
					  {autocreate => 1,
					   cv_name => 'local',
					   allow_duplicate_values=> 1,
					  });
		#also add add as synonyms
		$stock->create_stockprops({ synonym => $stockprop_value},
					  {autocreate => 1,
					   cv_name => 'local',
					   allow_duplicate_values=> 1,
					  });
	    }
	}
	else {
	    print STDERR "\n\nERROR:Could not find stock $accession.\n\n";
	}
    }
};

try {
    $chado_schema->txn_do($coderef);
#    if (!$opt_t) { print "Transaction succeeded! Commiting stocks and their properties! \n\n"; }
} catch {
    die "An error occured! Rolling back  and reseting database sequences!\n";
};

