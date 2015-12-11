#!/usr/bin/perl

# basic script to load SSR genotypes

# usage: load_ssr.pl -H hostname D dbname  -i infile

# In General row headings are the accession name (or synonym) , which needs to be looked up in the stock table, and column headings are marker name, or alias.

# copy and edit this file as necessary
# common changes include the following:


=head1

 NAME

load_ssr.pl - a script to load ssr genotypes into the SGN database (see sgn.ssr table) .

=head1 DESCRIPTION

usage: load_ssr.pl

Options:

=over 5

=item -H

The hostname of the server hosting the database.

=item -D

the name of the database

=item -t

(optional) test mode. Rollback after the script terminates. Database should not be affected. Good for test runs.


=item -i

infile with the marker info

=item -o

outfile for catching errors and other messages

=back

The tab-delimited snp genotype file must have stocks and markers which already exist in the database.
Non-existing stocks or markers will be skipped.


=head1 AUTHORS

Naama Menda <nm249@cornell.edu>
Jeremy Edwards <jde22@cornell.edu>

=cut

use strict;
use warnings;

#use CXGN::Tools::File::Spreadsheet;
use CXGN::Tools::Text;
use File::Slurp;
use Bio::Chado::Schema;
use SGN::Schema;

use CXGN::Marker;
use CXGN::Marker::Tools;
use CXGN::DB::Connection;
use CXGN::DB::InsertDBH;
use CXGN::DB::SQLWrappers;

use Spreadsheet::ParseExcel;

use Getopt::Std;

our ($opt_H, $opt_D, $opt_i, $opt_t, $opt_o);
getopts('H:D:ti:o:');

my $dbh = CXGN::DB::InsertDBH->new({
    dbname => $opt_D,
    dbhost => $opt_H,
    dbargs => {AutoCommit => 0,
               RaiseError => 1}
                                   });

my $schema= Bio::Chado::Schema->connect( sub { $dbh->get_actual_dbh() } , );
my $sgn_schema = SGN::Schema->connect( sub { $dbh->get_actual_dbh() }, { on_connect_do => ['set search_path to public,phenome,sgn;'] } );
my $sql=CXGN::DB::SQLWrappers->new($dbh);

#try to open the excel file and report any errors
my $parser   = Spreadsheet::ParseExcel->new();
my $excel_obj = $parser->parse($opt_i);

if ( !$excel_obj ) {
  die "Input file error: ".$parser->error()."\n";
}

my $worksheet = ( $excel_obj->worksheets() )[0]; #support only one worksheet
my ( $row_min, $row_max ) = $worksheet->row_range();
my ( $col_min, $col_max ) = $worksheet->col_range();

if (($col_max - $col_min)  < 1 || ($row_max - $row_min) < 1 ) { #must have header and at least one row of accessions and one column of markers
  die "Input file error: spreadsheet is missing header\n";
}

# check for correct header
my $accession_name_head;
if ($worksheet->get_cell(0,0)) {
  $accession_name_head  = $worksheet->get_cell(0,0)->value();
}
if (!$accession_name_head || $accession_name_head ne 'accession_name') {
  die "Input file error: no \"accession_name\" in header\n";
}

my @stocks;
my %stock_row;
for my $row ( 1 .. $row_max ) {
  my $accession_name;
  if ($worksheet->get_cell($row,0)) {
    $accession_name = $worksheet->get_cell($row,0)->value();
  } else {
    next; #skip blank lines
  }
  push @stocks, $accession_name;
  if ($stock_row{$accession_name}) {
      die "Duplicate stock found: $accession_name\n";
  }
  $stock_row{$accession_name} = $row;
}
my @markers;
my %marker_col;
for my $col ( 1 .. $col_max ) {
  my $marker_name;
  if ($worksheet->get_cell(0,$col)) {
    $marker_name = $worksheet->get_cell(0,$col)->value();
  } else {
    next; #skip blank lines
  }
  push @markers, $marker_name;
  if ($marker_col{$marker_name}) {
      die "Duplicate marker found: $marker_name\n";
  }
  $marker_col{$marker_name} = $col;
}

eval {
    # make an object to give us the values from the spreadsheet
    #my $ss = CXGN::Tools::File::Spreadsheet->new($opt_i);
    #my @stocks = $ss->row_labels(); # row labels are the marker names
    #my @markers = $ss->column_labels(); # column labels are the headings for the data columns
    for my $stock_name (@stocks) {
        print "stockname = $stock_name\n";

	my $stock_search;
	$stock_search = $schema->resultset("Stock::Stock")->search( { name => $stock_name });
	if (!$stock_search) { 
	    die ("No stock found for stock $stock_name! \n\n");
	}
	if ($stock_search->count() > 1) {
	    die ("Multiple stocks found for stock $stock_name! \n\n");
	}
	my $stock_id = $stock_search->first->stock_id();

        message( "*************Stock name = $stock_name, id = $stock_id\n" );
        for my $marker_name (@markers) {
            print "marker: $marker_name\n";
            my @marker_ids =  CXGN::Marker::Tools::marker_name_to_ids($dbh,$marker_name);
            if (@marker_ids>1) { die "Too many IDs found for marker '$marker_name'" }
            # just get the first ID in the list (if the list is longer than 1, we've already died)
            my $marker_id = $marker_ids[0];

            if(!$marker_id) {
                message("Marker $marker_name does not exist! Skipping!!\n");
                next;
            }
            else {  message( "Marker name : $marker_name, marker_id found: $marker_id\n" ) ; }

	    my $band_size;
	    $band_size = $worksheet->get_cell($stock_row{$stock_name},$marker_col{$marker_name})->value();

	    if ($band_size !~ /^[0-9]*$/) {
                message("non-numeric band size ($band_size). Skipping!!");
	    }

	    my $pcr_experiment = $sgn_schema->resultset("PcrExperiment")->create({marker_id => $marker_id, stock_id => $stock_id});
	    my $pcr_exp_accession = $sgn_schema->resultset("PcrExpAccession")->create({pcr_experiment_id => $pcr_experiment->pcr_experiment_id(), stock_id => $stock_id});
	    my $pcr_product = $sgn_schema->resultset("PcrProduct")->create({pcr_exp_accession_id => $pcr_exp_accession->pcr_exp_accession_id(), band_size => $band_size});
        }
    }
};

if ($@) {
    print $@;
    print "Failed; rolling back.\n";
    $dbh->rollback();
}
else {
    print"Succeeded.\n";
    if ($opt_t) {
        print"Rolling back.\n";
        $dbh->rollback();
    }
    else  {
        print"Committing.\n";
        $dbh->commit();
    }
}

sub message {
    my $message = shift;
    print $message;
    write_file( $opt_o,  {append => 1 }, $message . "\n" )  if $opt_o;
}
