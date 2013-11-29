#!/usr/bin/perl

# GeoReferencePlates - a utility to automatically georeference FAA Instrument Approach Plates / Terminal Procedures
# Copyright (C) 2013  Jesse McGraw (jlmcgraw@gmail.com)

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see [http://www.gnu.org/licenses/].

#Known issues:

#Output some statistics from the process to see which plates are working 
#Change the logic for obstacles to find nearest text to icon and not vice versa (the current method)
#Relies on icons being drawn very specific ways, it won't work if these ever change
#Relies on text being in PDF.  I've found at least one example that doesn't use text (plates from KSSC)
#Plates from KCDN are coming out of gdalwarp way too big.  Why?  the same command line works fine elsewhere

#There has been no attempt to optimize anything yet or make code modular
#Images are being warped when they really shouldn't need to be.   Try using ULLR method
#Investigate not creating the intermediate PNG
#Accumulate GCPs across the streams
#Discard outliers (eg obstacles in the airport view box, or missed approach waypoints
#Very easy to mismatch obstacles with their height text.  How to weed out false ones?
use 5.010;

use strict;
use warnings;

#use diagnostics;

use PDF::API2;
use DBI;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use File::Basename;
use Getopt::Std;

#PDF constants
use constant mm => 25.4 / 72;
use constant in => 1 / 72;
use constant pt => 1;

#Some subroutines
use GeoReferencePlatesSubroutines;

use vars qw/ %opt /;
my $opt_string = 'vs:a:';
my $arg_num = scalar @ARGV;

unless ( getopts( "$opt_string", \%opt ) ) {
    say "Usage: $0 -v -a<FAA airport ID> <pdf_file>\n";
    exit(1);
}
if ( $arg_num < 1 ) {
    say "Usage: $0 -v -a<FAA airport ID> <pdf_file>\n";
    exit(1);
}

my $debug = $opt{v};

my ( $output, $targetpdf );
my ( $pdfx, $pdfy, $pdfCenterX, $pdfCenterY, $pngx, $pngy );
my $retval;

#Get the target PDF file from command line options
$targetpdf = $ARGV[0];

#Get the airport ID in case we can't guess it from PDF (KSSC is an example)
my $airportid = $opt{a};
if ($airportid) {
    say "Supplied airport ID: $airportid";
}

say $targetpdf;
my ( $filename, $dir, $ext ) = fileparse( $targetpdf, qr/\.[^.]*/ );
my $outputpdf = $dir . "marked-" . $filename . ".pdf";
my $targetpng = $dir . $filename . ".png";
my $targettif = $dir . $filename . ".tif";
my $targetvrt = $dir . $filename . ".vrt";

die "Source file needs to be a PDF" if !( $ext =~ m/^\.pdf$/i );

if ($debug) {
    say "Directory: " . $dir;
    say "File:      " . $filename;
    say "Suffix:    " . $ext;

    #Check that suffix is PDF for input file
    say "OutputPdf: $outputpdf";
    say "TargetPng: $targetpng";
    say "TargetTif: $targettif";
    say "TargetVrt: $targetvrt";
}

open my $file, '<', $targetpdf
  or die "can't open '$targetpdf' for reading : $!";
close $file;

#-----------------------------------------------
#Get the lat/lon of the airport for the plate we're working on
#This line will try to pull the lat/lon at the bottom of the drawing instead of a DB query
#pdftotext  <pdf_name> - | grep -P '\b\d+’[NS]-\d+’[EW]'
my $airportLatitudeDec  = "";
my $airportLongitudeDec = "";

my @pdftotext;
@pdftotext = qx(pdftotext $targetpdf  -enc ASCII7 -);
$retval    = $? >> 8;
die "No output from pdftotext.  Is it installed?  Return code was $retval"
  if ( @pdftotext eq "" || $retval != 0 );

#Die if the chart says it's not to scale
foreach my $line (@pdftotext) {
    if ( $line =~ m/chartnott/i ) {
        die "Chart not to scale, can't georeference";
    }

}

#-----------------------------------------------
#Open the database
my ( $dbh, $sth );
$dbh = DBI->connect(
    "dbi:SQLite:dbname=locationinfo.db",
    "", "", { RaiseError => 1 },
) or die $DBI::errstr;

#Try to pull out the lat/lon at the bottom of the chart, die if can't
foreach my $line (@pdftotext) {

    # if ( $line =~ m/(\d+)'([NS])\s?-\s?(\d+)'([EW])/ ) {
    if ( $line =~ m/([\d ]+)'([NS])\s?-\s?([\d ]+)'([EW])/ ) {
        my (
            $aptlat,    $aptlon,    $aptlatd,   $aptlond,
            $aptlatdeg, $aptlatmin, $aptlondeg, $aptlonmin
        );
        $aptlat  = $1;
        $aptlatd = $2;
        $aptlon  = $3;
        $aptlond = $4;

        $aptlatdeg = substr( $aptlat, 0,  -2 );
        $aptlatmin = substr( $aptlat, -2, 2 );

        $aptlondeg = substr( $aptlon, 0,  -2 );
        $aptlonmin = substr( $aptlon, -2, 2 );

        $airportLatitudeDec =
          &coordinatetodecimal(
            $aptlatdeg . "-" . $aptlatmin . "-00" . $aptlatd );

        $airportLongitudeDec =
          &coordinatetodecimal(
            $aptlondeg . "-" . $aptlonmin . "-00" . $aptlond );

        say
"Airport LAT/LON from plate: $airportLatitudeDec $airportLongitudeDec";
    }

}

if ( $airportLongitudeDec eq "" or $airportLatitudeDec eq "" ) {

    #We didn't get any airport info from the PDF, let's check the database
    #Get airport from database
    die
"You must specify an airport ID (eg. -a SMF) since there was no info on the PDF"
      if $airportid eq "";

    #Query the database for airport
    $sth = $dbh->prepare(
"SELECT  FaaID, Latitude, Longitude, Name  FROM airports  WHERE  FaaID = '$airportid'"
    );
    $sth->execute();
    my $allSqlQueryResults = $sth->fetchall_arrayref();

    foreach my $row (@$allSqlQueryResults) {
        my ( $airportFaaId, $airportname );
        (
            $airportFaaId, $airportLatitudeDec, $airportLongitudeDec,
            $airportname
        ) = @$row;
        say "Airport ID: $airportFaaId";
        say "Airport Latitude: $airportLatitudeDec";
        say "Airport Longitude: $airportLongitudeDec";
        say "Airport Name: $airportname";
    }

}

die "No airport coordinate information on PDF or database, try   -a <airport> "
  if ( $airportLongitudeDec eq "" or $airportLatitudeDec eq "" );

#----------------------------------------------------------
#Get the mediabox size
my $mutoolinfo;
$mutoolinfo = qx(mutool info $targetpdf);
$retval     = $? >> 8;
die "No output from mutool info.  Is it installed? Return code was $retval"
  if ( $mutoolinfo eq "" || $retval != 0 );

foreach my $line ( split /[\r\n]+/, $mutoolinfo ) {
    ## Regular expression magic to grab what you want
    if ( $line =~ /([-\.0-9]+) ([-\.0-9]+) ([-\.0-9]+) ([-\.0-9]+)/ ) {
        $pdfx       = $3 - $1;
        $pdfy       = $4 - $2;
        $pdfCenterX = $pdfx / 2;
        $pdfCenterY = $pdfy / 2;
        say "PDF Mediabox size: " . $pdfx . "x" . $pdfy;
        say "PDF Mediabox center: " . $pdfCenterX . "x" . $pdfCenterY;
    }
}

#---------------------------------------------------
#Convert PDF to a PNG
my $pdftoppmoutput;
$pdftoppmoutput = qx(pdftoppm -png -r 300 $targetpdf > $targetpng);

$retval = $? >> 8;
die "Error from pdftoppm.   Return code is $retval" if $retval != 0;

#---------------------------------------------------------------------------------------------------------
#Find the dimensions of the PNG
my $fileoutput;
$fileoutput = qx(file $targetpng );
$retval     = $? >> 8;
die "No output from file.  Is it installed? Return code was $retval"
  if ( $fileoutput eq "" || $retval != 0 );

foreach my $line ( split /[\r\n]+/, $fileoutput ) {
    ## Regular expression magic to grab what you want
    if ( $line =~ /([-\.0-9]+)\s+x\s+([-\.0-9]+)/ ) {
        $pngx = $1;
        $pngy = $2;
    }
}

my $scalefactorx = $pngx / $pdfx;
my $scalefactory = $pngy / $pdfy;

say "PNG size: " . $pngx . "x" . $pngy;
say "Scalefactor PDF->PNG X:  " . $scalefactorx;
say "Scalefactor PDF->PNG Y:  " . $scalefactory;

#--------------------------------------------------------------------------------------------------------------
#Get number of objects/streams in the targetpdf
my $mutoolshowoutput;
$mutoolshowoutput = qx(mutool show $targetpdf x);
$retval           = $? >> 8;
die "No output from mutool show.  Is it installed? Return code was $retval"
  if ( $mutoolshowoutput eq "" || $retval != 0 );

my $objectstreams;

foreach my $line ( split /[\r\n]+/, $mutoolshowoutput ) {
    ## Regular expression magic to grab what you want
    if ( $line =~ /^(\d+)\s+(\d+)$/ ) {
        $objectstreams = $2;
    }
}
say "Object streams: " . $objectstreams;

#Finding each of these icons can be rolled into one loop instead of separate one for each type
#----------------------------------------------------------------------------------------------------------
#Find obstacles in the pdf
my $obstacleregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m ([\.0-9]+) [\.0-9]+ l ([\.0-9]+) [\.0-9]+ l S Q q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ [-\.0-9]+ c f\* Q/;

my %obstacles = ();

for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempobstacles        = $output =~ /$obstacleregex/ig;
    my $tempobstacles_length = 0 + @tempobstacles;

    #6 data points for each obstacle
    my $tempobstacles_count = $tempobstacles_length / 6;

    if ( $tempobstacles_length >= 6 ) {
        for ( my $i = 0 ; $i < $tempobstacles_length ; $i = $i + 6 ) {

#put them into a hash
#This finds the midpoint X of the obstacle triangle (the X,Y of the dot itself was too far right)
            $obstacles{$i}{"X"} = $tempobstacles[$i] + $tempobstacles[ $i + 2 ];
            $obstacles{$i}{"Y"} = $tempobstacles[ $i + 1 ];
            $obstacles{$i}{"Height"}             = "unknown";
            $obstacles{$i}{"BoxesThatPointToMe"} = "0";
        }

    }
}

#print Dumper ( \%obstacles );
say "Found " . keys(%obstacles) . " obstacle icons";

# #-------------------------------------------------------------------------------------------------------
# #Find fixes in the PDF
my $fixregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm 0 0 m ([-\.0-9]+) [\.0-9]+ l [-\.0-9]+ ([\.0-9]+) l 0 0 l S Q/;
my %fixicons = ();
for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempfixes        = $output =~ /$fixregex/ig;
    my $tempfixes_length = 0 + @tempfixes;

    #4 data points for each fix
    #$1 = x
    #$2 = y
    #$3 = delta x (will be negative)
    #$4 = delta y (will be negative)
    my $tempfixes_count = $tempfixes_length / 4;

    if ( $tempfixes_length >= 4 ) {
        for ( my $i = 0 ; $i < $tempfixes_length ; $i = $i + 4 ) {

            #put them into a hash
            #code here is making the x/y the center of the triangle
            $fixicons{$i}{"X"} = $tempfixes[$i] + ( $tempfixes[ $i + 2 ] / 2 );
            $fixicons{$i}{"Y"} =
              $tempfixes[ $i + 1 ] + ( $tempfixes[ $i + 3 ] / 2 );
            $fixicons{$i}{"Name"} = "none";
        }

    }
}

say "Found " . keys(%fixicons) . " fix icons";

#--------------------------------------------------------------------------------------------------------
#Find first half of gps waypoints
my $gpswaypointregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+0 0 l\s+f\*\s+Q/;

my %gpswaypoints = ();

for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempgpswaypoints        = $output =~ /$gpswaypointregex/ig;
    my $tempgpswaypoints_length = 0 + @tempgpswaypoints;
    my $tempgpswaypoints_count  = $tempgpswaypoints_length / 2;

    if ( $tempgpswaypoints_length >= 2 ) {
        for ( my $i = 0 ; $i < $tempgpswaypoints_length ; $i = $i + 2 ) {

            #put them into a hash
            $gpswaypoints{$i}{"X"}          = $tempgpswaypoints[$i];
            $gpswaypoints{$i}{"Y"}          = $tempgpswaypoints[ $i + 1 ];
            $gpswaypoints{$i}{"iconCenterXPdf"} = $tempgpswaypoints[$i] + 8;
            $gpswaypoints{$i}{"iconCenterYPdf"} = $tempgpswaypoints[ $i + 1 ];
            $gpswaypoints{$i}{"Name"}       = "none";
        }

    }
}
say "Found " . keys(%gpswaypoints) . " GPS waypoint icons";

#--------------------------------------------------------------------------------------------------------
#Find Final Approach Fix icon
my $fafregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+[-\.0-9]+\s+c\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+q 1 0 0 1 [\.0-9]+ [\.0-9]+ cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q/;
my %finalapproachfixes = ();
for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempfinalapproachfixes        = $output =~ /$fafregex/ig;
    my $tempfinalapproachfixes_length = 0 + @tempfinalapproachfixes;
    my $tempfinalapproachfixes_count  = $tempfinalapproachfixes_length / 2;

    if ( $tempfinalapproachfixes_length >= 2 ) {
        for ( my $i = 0 ; $i < $tempfinalapproachfixes_length ; $i = $i + 2 ) {

            #put them into a hash
            $finalapproachfixes{$i}{"X"}    = $tempfinalapproachfixes[$i];
            $finalapproachfixes{$i}{"Y"}    = $tempfinalapproachfixes[ $i + 1 ];
            $finalapproachfixes{$i}{"Name"} = "none";
        }

    }
}
say "Found " . keys(%finalapproachfixes) . " Final Approach Fix icons";

# #--------------------------------------------------------------------------------------------------------
# #Find Visual Descent Point icon
my $vdpregex =
qr/q 1 0 0 1 ([\.0-9]+) ([\.0-9]+) cm\s+0 0 m\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+[-\.0-9]+\s+[-\.0-9]+\s+l\s+0 0 l\s+f\*\s+Q\s+0.72 w \[\]0 d/;

my %visualdescentpoints = ();
for ( my $i = 0 ; $i < ( $objectstreams - 1 ) ; $i++ ) {
    $output = qx(mutool show $targetpdf $i x);
    $retval = $? >> 8;
    die "No output from mutool show.  Is it installed? Return code was $retval"
      if ( $output eq "" || $retval != 0 );

    #Remove new lines
    $output =~ s/\n/ /g;
    my @tempvisualdescentpoints        = $output =~ /$vdpregex/ig;
    my $tempvisualdescentpoints_length = 0 + @tempvisualdescentpoints;
    my $tempvisualdescentpoints_count  = $tempvisualdescentpoints_length / 2;

    if ( $tempvisualdescentpoints_length >= 2 ) {
        for ( my $i = 0 ; $i < $tempvisualdescentpoints_length ; $i = $i + 2 ) {

            #put them into a hash
            $visualdescentpoints{$i}{"X"} = $tempvisualdescentpoints[$i];
            $visualdescentpoints{$i}{"Y"} = $tempvisualdescentpoints[ $i + 1 ];
            $visualdescentpoints{$i}{"Name"} = "none";
        }

    }
}
say "Found " . keys(%visualdescentpoints) . " Visual Descent Point icons";

#--------------------------------------------------------------------------
#Get list of potential fix/intersection/waypoint  textboxes
#For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
#We'll convert them to PDF coordinates
my $fixtextboxregex =
qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">([A-Z]{5})</;

my $invalidfixnamesregex = qr/tower|south/i;
my %fixtextboxes         = ();

my @pdftotextbbox = qx(pdftotext $targetpdf -bbox - );
$retval = $? >> 8;
die "No output from pdftotext -bbox.  Is it installed? Return code was $retval"
  if ( @pdftotextbbox eq "" || $retval != 0 );

foreach my $line (@pdftotextbbox) {
    if ( $line =~ m/$fixtextboxregex/ ) {

#Exclude invalid fix names.  A smarter way to do this would be to use the DB lookup to limit to local fix names
        next if $5 =~ m/$invalidfixnamesregex/;

        $fixtextboxes{ $1 . $2 }{"RasterX"}    = $1;
        $fixtextboxes{ $1 . $2 }{"RasterY"}    = $2;
        $fixtextboxes{ $1 . $2 }{"Width"}      = $3 - $1;
        $fixtextboxes{ $1 . $2 }{"Height"}     = $4 - $2;
        $fixtextboxes{ $1 . $2 }{"Text"}       = $5;
        $fixtextboxes{ $1 . $2 }{"PdfX"}       = $1;
        $fixtextboxes{ $1 . $2 }{"PdfY"}       = $pdfy - $2;
        $fixtextboxes{ $1 . $2 }{"iconCenterXPdf"} = $1 + ( ( $3 - $1 ) / 2 );
        $fixtextboxes{ $1 . $2 }{"iconCenterYPdf"} = $pdfy - $2;
    }

}

#print Dumper ( \%fixtextboxes );
say "Found " . keys(%fixtextboxes) . " Potential Fix text boxes";

#--------------------------------------------------------------------------
#Get list of potential obstacle height textboxes
#For whatever dumb reason they're in raster coordinates (0,0 is top left, Y increases downwards)
#Look for 3+ digit numbers not ending in 0
my $obstacletextboxregex =
qr/xMin="([\d\.]+)" yMin="([\d\.]+)" xMax="([\d\.]+)" yMax="([\d\.]+)">([\d]{2,}[1-9])</;

my %obstacletextboxes = ();

foreach my $line (@pdftotextbbox) {
    if ( $line =~ m/$obstacletextboxregex/ ) {
        $obstacletextboxes{ $1 . $2 }{"RasterX"}    = $1;
        $obstacletextboxes{ $1 . $2 }{"RasterY"}    = $2;
        $obstacletextboxes{ $1 . $2 }{"Width"}      = $3 - $1;
        $obstacletextboxes{ $1 . $2 }{"Height"}     = $4 - $2;
        $obstacletextboxes{ $1 . $2 }{"Text"}       = $5;
        $obstacletextboxes{ $1 . $2 }{"PdfX"}       = $1;
        $obstacletextboxes{ $1 . $2 }{"PdfY"}       = $pdfy - $2;
        $obstacletextboxes{ $1 . $2 }{"iconCenterXPdf"} = $1 + ( ( $3 - $1 ) / 2 );
        $obstacletextboxes{ $1 . $2 }{"iconCenterYPdf"} = $pdfy - $2;
    }

}

#print Dumper ( \%obstacletextboxes );
say "Found " . keys(%obstacletextboxes) . " Potential obstacle text boxes";

#----------------------------------------------------------------------------------------------------------
#Modify the PDF

my $pdf = PDF::API2->open($targetpdf);

my %font = (
    Helvetica => {
        Bold => $pdf->corefont( 'Helvetica-Bold', -encoding => 'latin1' ),

    #      Roman  => $pdf->corefont('Helvetica',         -encoding => 'latin1'),
    #      Italic => $pdf->corefont('Helvetica-Oblique', -encoding => 'latin1'),
    },
    Times => {

    #      Bold   => $pdf->corefont('Times-Bold',        -encoding => 'latin1'),
        Roman => $pdf->corefont( 'Times', -encoding => 'latin1' ),

    #      Italic => $pdf->corefont('Times-Italic',      -encoding => 'latin1'),
    },
);

#Set up the various types of boxes to draw on the output PDF
my $page = $pdf->openpage(1);

my $obstacle_box = $page->gfx;
$obstacle_box->strokecolor('red');

my $fix_box = $page->gfx;
$fix_box->strokecolor('yellow');

my $gpswaypoint_box = $page->gfx;
$gpswaypoint_box->strokecolor('blue');

my $faf_box = $page->gfx;
$faf_box->strokecolor('purple');

my $vdp_box = $page->gfx;
$vdp_box->strokecolor('green');

#Draw the various types of boxes on the output PDF
foreach my $key ( sort keys %obstacles ) {
    $obstacle_box->rect(
        $obstacles{$key}{X} - 4,
        $obstacles{$key}{Y} - 2,
        7, 8
    );
    $obstacle_box->stroke;
}

foreach my $key ( sort keys %fixicons ) {
    $fix_box->rect( $fixicons{$key}{X} - 4, $fixicons{$key}{Y} - 4, 9, 9 );
    $fix_box->stroke;
}
foreach my $key ( sort keys %fixtextboxes ) {
    $fix_box->rect(
        $fixtextboxes{$key}{PdfX},    $fixtextboxes{$key}{PdfY} + 2,
        $fixtextboxes{$key}{"Width"}, -( $fixtextboxes{$key}{"Height"} + 2 )
    );
    $fix_box->stroke;
}
foreach my $key ( sort keys %gpswaypoints ) {
    $gpswaypoint_box->rect(
        $gpswaypoints{$key}{X} - 1,
        $gpswaypoints{$key}{Y} - 8,
        17, 16
    );
    $gpswaypoint_box->stroke;
}

foreach my $key ( sort keys %finalapproachfixes ) {
    $faf_box->rect(
        $finalapproachfixes{$key}{X} - 5,
        $finalapproachfixes{$key}{Y} - 5,
        10, 10
    );
    $faf_box->stroke;
}

foreach my $key ( sort keys %visualdescentpoints ) {
    $vdp_box->rect(
        $visualdescentpoints{$key}{X} - 3,
        $visualdescentpoints{$key}{Y} - 7,
        8, 8
    );
    $vdp_box->stroke;
}

#--------------------------------------------------------------------------
#Get a list of potential obstacle heights from the PDF text array
#(alternately, iterate through each obstacle and find the closest text box

my @obstacle_heights;

foreach my $line (@pdftotext) {

    #Find 3+ digit numbers that don't end in 0
    if ( $line =~ m/^([\d]{2,}[1-9])$/ ) {
        next if $1 > 30000;
        push @obstacle_heights, $1;
    }

}

if ($debug) {
    say "Potential obstacle heights from PDF";
    print join( " ", @obstacle_heights ), "\n";
    @obstacle_heights = onlyuniq(@obstacle_heights);
    say "Unique potential obstacle heights from PDF";
    print join( " ", @obstacle_heights ), "\n";
}

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Find obstacles with a certain height in the DB
my $radius = ".4";    #~15 miles

my %unique_obstacles_from_db = ();
say
"Obstacles with unique heights within $radius degrees of airport from database with height also on PDF";
foreach my $heightmsl (@obstacle_heights) {

    #Query the database for obstacles of $heightmsl within our $radius
    $sth = $dbh->prepare(
        "SELECT * FROM obstacles WHERE (HeightMsl=$heightmsl) and 
                                       (Latitude >  $airportLatitudeDec - $radius ) and 
                                       (Latitude < $airportLatitudeDec +$radius ) and 
                                       (Longitude >  $airportLongitudeDec - $radius ) and 
                                       (Longitude < $airportLongitudeDec +$radius )"
    );
    $sth->execute();

    my $all  = $sth->fetchall_arrayref();
    my $rows = $sth->rows();

   #Don't show results of searches that have more than one result, ie not unique
    next if ( $rows != 1 );
    if ($debug) {
        my $fields = $sth->{NUM_OF_FIELDS};
        print "We have selected $fields obstacle field(s)\n";

        my $rows = $sth->rows();
        print
          "HeightMsl: $heightmsl.  We have selected $rows obstacle row (s)\n";

    }

    foreach my $row (@$all) {
        my ( $lat, $lon, $heightmsl, $heightagl ) = @$row;
        foreach my $pdf_obstacle_height (@obstacle_heights) {
            if ( $pdf_obstacle_height == $heightmsl ) {
                $unique_obstacles_from_db{$heightmsl}{"Lat"} = $lat;
                $unique_obstacles_from_db{$heightmsl}{"Lon"} = $lon;
            }
        }
    }

}

if ($debug) {
    my $fields = $sth->{NUM_OF_FIELDS};
    print "We have selected $fields obstacle field(s)\n";

    my $rows = $sth->rows();
    print "We have selected $rows obstacle row(s)\n";

    say "Unique obstacles from database lookup";
    print Dumper ( \%unique_obstacles_from_db );

}

#Find a text box with text that matches the height of each of our unique_obstacles_from_db
#Add the center coordinates of that box to unique_obstacles_from_db hash
foreach my $key ( keys %unique_obstacles_from_db ) {
    foreach my $key2 ( keys %obstacletextboxes ) {
        if ( $obstacletextboxes{$key2}{"Text"} == $key ) {
            $unique_obstacles_from_db{$key}{"Label"} =
              $obstacletextboxes{$key2}{"Text"};
            $unique_obstacles_from_db{$key}{"TextBoxX"} =
              $obstacletextboxes{$key2}{"iconCenterXPdf"};
            $unique_obstacles_from_db{$key}{"TextBoxY"} =
              $obstacletextboxes{$key2}{"iconCenterYPdf"};

        }

    }
}

$obstacle_box->strokecolor('orange');

#Only outline our unique potential obstacle_heights
foreach my $key ( sort keys %obstacletextboxes ) {

    #Is there a obstacletextbox with the same text as our obstacle's height?
    if ( exists $unique_obstacles_from_db{ $obstacletextboxes{$key}{"Text"} } )
    {
        #Yes, draw a box around it
        $obstacle_box->rect(
            $obstacletextboxes{$key}{"PdfX"},
            $obstacletextboxes{$key}{"PdfY"} + 2,
            $obstacletextboxes{$key}{"Width"},
            -( $obstacletextboxes{$key}{"Height"} + 1 )
        );
        $obstacle_box->stroke;
    }
}

#Try to find closest obstacle icon to each text box for the obstacles in unique_obstacles_from_db
foreach my $key ( sort keys %unique_obstacles_from_db ) {
    my $distance_to_closest_obstacle_icon_x;
    my $distance_to_closest_obstacle_icon_y;
    my $distance_to_closest_obstacle_icon = 999999999999;
    foreach my $key2 ( keys %obstacles ) {
        $distance_to_closest_obstacle_icon_x =
          $unique_obstacles_from_db{$key}{"TextBoxX"} - $obstacles{$key2}{"X"};
        $distance_to_closest_obstacle_icon_y =
          $unique_obstacles_from_db{$key}{"TextBoxY"} - $obstacles{$key2}{"Y"};

        my $hyp = sqrt( $distance_to_closest_obstacle_icon_x**2 +
              $distance_to_closest_obstacle_icon_y**2 );
        if ( ( $hyp < $distance_to_closest_obstacle_icon ) && ( $hyp < 20 ) ) {
            $distance_to_closest_obstacle_icon = $hyp;
            $unique_obstacles_from_db{$key}{"ObsIconX"} =
              $obstacles{$key2}{"X"};
            $unique_obstacles_from_db{$key}{"ObsIconY"} =
              $obstacles{$key2}{"Y"};
        }

    }

    # say "$distance_to_closest_obstacle_icon";
}

#clean up unique_obstacles_from_db
#remove entries that have no ObsIconX or Y
foreach my $key ( sort keys %unique_obstacles_from_db ) {
    unless ( ( exists $unique_obstacles_from_db{$key}{"ObsIconX"} )
        && ( exists $unique_obstacles_from_db{$key}{"ObsIconY"} ) )
    {
        delete $unique_obstacles_from_db{$key};
    }
}

#Remove entries that share an ObsIconX and ObsIconY with another entry
my @a;
foreach my $key ( sort keys %unique_obstacles_from_db ) {

    foreach my $key2 ( sort keys %unique_obstacles_from_db ) {
        if (
            ( $key ne $key2 )
            && ( $unique_obstacles_from_db{$key}{"ObsIconX"} ==
                $unique_obstacles_from_db{$key2}{"ObsIconX"} )
            && ( $unique_obstacles_from_db{$key}{"ObsIconY"} ==
                $unique_obstacles_from_db{$key2}{"ObsIconY"} )
          )
        {
            push @a, $key;

            # push @a, $key2;
            say "Duplicate obstacle";
        }

    }
}
foreach my $entry (@a) {
    delete $unique_obstacles_from_db{$entry};
}

#Draw a line from obstacle icon to closest text boxes
my $obstacle_line = $page->gfx;
$obstacle_line->strokecolor('blue');
foreach my $key ( sort keys %unique_obstacles_from_db ) {
    $obstacle_line->move(
        $unique_obstacles_from_db{$key}{"ObsIconX"},
        $unique_obstacles_from_db{$key}{"ObsIconY"}
    );
    $obstacle_line->line(
        $unique_obstacles_from_db{$key}{"TextBoxX"},
        $unique_obstacles_from_db{$key}{"TextBoxY"}
    );
    $obstacle_line->stroke;
}

if ($debug) {
    say "Unique obstacles from database lookup";
    print Dumper ( \%unique_obstacles_from_db );
}

#------------------------------------------------------------------------------------------------------------------------------------------
#Find fixes near the airport
my %fixes_from_db = ();
say
"Fixes within $radius degrees of airport  ($airportLongitudeDec, $airportLatitudeDec) from database";

#What type of fixes to look for
my $type = "%REP-PT";

#Query the database for fixes within our $radius
$sth = $dbh->prepare(
"SELECT * FROM fixes WHERE  (Latitude >  $airportLatitudeDec - $radius ) and 
                                (Latitude < $airportLatitudeDec +$radius ) and 
                                (Longitude >  $airportLongitudeDec - $radius ) and 
                                (Longitude < $airportLongitudeDec +$radius ) and
                                (Type like '$type')"
);
$sth->execute();

my $allSqlQueryResults = $sth->fetchall_arrayref();

foreach my $row (@$allSqlQueryResults) {
    my ( $fixname, $lat, $lon, $fixtype ) = @$row;
    $fixes_from_db{$fixname}{"Name"} = $fixname;
    $fixes_from_db{$fixname}{"Lat"}  = $lat;
    $fixes_from_db{$fixname}{"Lon"}  = $lon;
    $fixes_from_db{$fixname}{"Type"} = $fixtype;

}

if ($debug) {
    my $rows   = $sth->rows();
    my $fields = $sth->{NUM_OF_FIELDS};

    say "All $type fixes from database";
    say "We have selected $fields field(s)";
    say "We have selected $rows row(s)";

    print Dumper ( \%fixes_from_db );
}

#Orange outline fixtextboxes that have a valid fix name in them
#Delete fixtextboxes that don't have a valid nearby fix in them
foreach my $key ( keys %fixtextboxes ) {

    #Is there a fixtextbox with the same text as our fix?
    if ( exists $fixes_from_db{ $fixtextboxes{$key}{"Text"} } ) {

        #Yes, draw an orange box around it
        $fix_box->rect(
            $fixtextboxes{$key}{"PdfX"},
            $fixtextboxes{$key}{"PdfY"} + 2,
            $fixtextboxes{$key}{"Width"},
            -( $fixtextboxes{$key}{"Height"} + 1 )
        );
        $fix_box->strokecolor('orange');
        $fix_box->stroke;
    }
    else {
        #delete $fixtextboxes{$key};
    }
}

#Try to find closest fixtextbox to each fix icon
foreach my $key ( sort keys %fixicons ) {
    my $distance_to_closest_fixtextbox_x;
    my $distance_to_closest_fixtextbox_y;

    #Initialize this to a very high number so everything is closer than it
    my $distance_to_closest_fixtextbox = 999999999999;
    foreach my $key2 ( keys %fixtextboxes ) {
        $distance_to_closest_fixtextbox_x =
          $fixtextboxes{$key2}{"iconCenterXPdf"} - $fixicons{$key}{"X"};
        $distance_to_closest_fixtextbox_y =
          $fixtextboxes{$key2}{"iconCenterYPdf"} - $fixicons{$key}{"Y"};

        my $hyp = sqrt( $distance_to_closest_fixtextbox_x**2 +
              $distance_to_closest_fixtextbox_y**2 );

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
        say "Hypotenuse: $hyp" if $debug;
        if ( ( $hyp < $distance_to_closest_fixtextbox ) && ( $hyp < 27 ) ) {
            $distance_to_closest_fixtextbox = $hyp;
            $fixicons{$key}{"Name"} = $fixtextboxes{$key2}{"Text"};
            $fixicons{$key}{"TextBoxX"} = $fixtextboxes{$key2}{"iconCenterXPdf"};
            $fixicons{$key}{"TextBoxY"} = $fixtextboxes{$key2}{"iconCenterYPdf"};
            $fixicons{$key}{"Lat"} =
              $fixes_from_db{ $fixicons{$key}{"Name"} }{"Lat"};
            $fixicons{$key}{"Lon"} =
              $fixes_from_db{ $fixicons{$key}{"Name"} }{"Lon"};
        }

    }

}

#fixes_from_db should now only have fixes that are mentioned on the PDF
if ($debug) {
    say "fixes_from_db";
    print Dumper ( \%fixes_from_db );
    say "fix icons";
    print Dumper ( \%fixicons );
    say "fixtextboxes";
    print Dumper ( \%fixtextboxes );
}

#clean up fixicons
#remove entries that have no name
foreach my $key ( sort keys %fixicons ) {
    if ( $fixicons{$key}{"Name"} eq "none" )

    {
        delete $fixicons{$key};
    }
}

if ($debug) {
    say "fixicons after deleting entries with no name";
    print Dumper ( \%fixicons );
}

#Draw a line from fix icon to closest text boxes
my $fix_line = $page->gfx;

foreach my $key ( sort keys %fixicons ) {
    $fix_line->move( $fixicons{$key}{"X"}, $fixicons{$key}{"Y"} );
    $fix_line->line( $fixicons{$key}{"TextBoxX"}, $fixicons{$key}{"TextBoxY"} );
    $fix_line->strokecolor('blue');
    $fix_line->stroke;
}

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Find GPS waypoints near the airport
my %gpswaypoints_from_db = ();
say
"GPS waypoints within $radius degrees of airport  ($airportLongitudeDec, $airportLatitudeDec) from database";

#What type of fixes to look for
$type = "RNAV%";

#Query the database for fixes within our $radius
$sth = $dbh->prepare(
"SELECT * FROM fixes WHERE  (Latitude >  $airportLatitudeDec - $radius ) and 
                                (Latitude < $airportLatitudeDec +$radius ) and 
                                (Longitude >  $airportLongitudeDec - $radius ) and 
                                (Longitude < $airportLongitudeDec +$radius ) and
                                (Type like '$type')"
);
$sth->execute();
$allSqlQueryResults = $sth->fetchall_arrayref();

foreach my $row (@$allSqlQueryResults) {
    my ( $fixname, $lat, $lon, $fixtype ) = @$row;
    $gpswaypoints_from_db{$fixname}{"Name"} = $fixname;
    $gpswaypoints_from_db{$fixname}{"Lat"}  = $lat;
    $gpswaypoints_from_db{$fixname}{"Lon"}  = $lon;
    $gpswaypoints_from_db{$fixname}{"Type"} = $fixtype;

}

if ($debug) {
    my $rows   = $sth->rows();
    my $fields = $sth->{NUM_OF_FIELDS};

    say "All $type fixes from database";
    say "We have selected $fields field(s)";
    say "We have selected $rows row(s)";

    print Dumper ( \%gpswaypoints_from_db );
}

#Orange outline fixtextboxes that have a valid fix name in them
#Delete fixtextboxes that don't have a valid nearby fix in them
foreach my $key ( keys %fixtextboxes ) {

    #Is there a fixtextbox with the same text as our fix?
    if ( exists $gpswaypoints_from_db{ $fixtextboxes{$key}{"Text"} } ) {

        #Yes, draw an orange box around it
        $fix_box->rect(
            $fixtextboxes{$key}{"PdfX"},
            $fixtextboxes{$key}{"PdfY"} + 2,
            $fixtextboxes{$key}{"Width"},
            -( $fixtextboxes{$key}{"Height"} + 1 )
        );
        $fix_box->strokecolor('orange');
        $fix_box->stroke;
    }
    else {
        #delete $fixtextboxes{$key};

    }
}

#Try to find closest fixtextbox to each fix icon
foreach my $key ( sort keys %gpswaypoints ) {
    my $distance_to_closest_fixtextbox_x;
    my $distance_to_closest_fixtextbox_y;

    #Initialize this to a very high number so everything is closer than it
    my $distance_to_closest_fixtextbox = 999999999999;
    foreach my $key2 ( keys %fixtextboxes ) {
        $distance_to_closest_fixtextbox_x =
          $fixtextboxes{$key2}{"iconCenterXPdf"} - $gpswaypoints{$key}{"X"};
        $distance_to_closest_fixtextbox_y =
          $fixtextboxes{$key2}{"iconCenterYPdf"} - $gpswaypoints{$key}{"Y"};

        my $hyp = sqrt( $distance_to_closest_fixtextbox_x**2 +
              $distance_to_closest_fixtextbox_y**2 );

#The 27 here was chosen to make one particular sample work, it's not universally valid
#Need to improve the icon -> textbox mapping
        say "Hypotenuse: $hyp" if $debug;
        if ( ( $hyp < $distance_to_closest_fixtextbox ) && ( $hyp < 27 ) ) {
            $distance_to_closest_fixtextbox = $hyp;
            $gpswaypoints{$key}{"Name"} = $fixtextboxes{$key2}{"Text"};
            $gpswaypoints{$key}{"TextBoxX"} =
              $fixtextboxes{$key2}{"iconCenterXPdf"};
            $gpswaypoints{$key}{"TextBoxY"} =
              $fixtextboxes{$key2}{"iconCenterYPdf"};
            $gpswaypoints{$key}{"Lat"} =
              $gpswaypoints_from_db{ $gpswaypoints{$key}{"Name"} }{"Lat"};
            $gpswaypoints{$key}{"Lon"} =
              $gpswaypoints_from_db{ $gpswaypoints{$key}{"Name"} }{"Lon"};
        }

    }

}

#gpswaypoints_from_db should now only have fixes that are mentioned on the PDF
if ($debug) {
    say "gpswaypoints_from_db";
    print Dumper ( \%gpswaypoints_from_db );
    say "gps waypoint icons";
    print Dumper ( \%gpswaypoints );
    say "fixtextboxes";
    print Dumper ( \%fixtextboxes );
}

#clean up gpswaypoints
#remove entries that have no name
foreach my $key ( sort keys %gpswaypoints ) {
    if ( $gpswaypoints{$key}{"Name"} eq "none" )

    {
        delete $gpswaypoints{$key};
    }
}

if ($debug) {
    say "gpswaypoints after deleting entries with no name";
    print Dumper ( \%gpswaypoints );
}

#Remove duplicate gps waypoints, prefer the one closest to the Y center of the PDF
OUTER:
foreach my $key ( sort keys %gpswaypoints ) {

 #my $hyp = sqrt( $distance_to_pdf_center_x**2 + $distance_to_pdf_center_y**2 );
    foreach my $key2 ( sort keys %gpswaypoints ) {

        if (   ( $gpswaypoints{$key}{"Name"} eq $gpswaypoints{$key2}{"Name"} )
            && ( $key ne $key2 ) )
        {
            my $name = $gpswaypoints{$key}{"Name"};
            say "A ha, I found a duplicate GPS waypoint name: $name";
            my $distance_to_pdf_center_x1 =
              abs( $pdfCenterX - $gpswaypoints{$key}{"X"} );
            my $distance_to_pdf_center_y1 =
              abs( $pdfCenterY - $gpswaypoints{$key}{"Y"} );
            say $distance_to_pdf_center_y1;
            my $distance_to_pdf_center_x2 =
              abs( $pdfCenterX - $gpswaypoints{$key2}{"X"} );
            my $distance_to_pdf_center_y2 =
              abs( $pdfCenterY - $gpswaypoints{$key2}{"Y"} );
            say $distance_to_pdf_center_y2;

            if ( $distance_to_pdf_center_y1 < $distance_to_pdf_center_y2 ) {
                delete $gpswaypoints{$key2};
                say "Deleting the 2nd entry";
                goto OUTER;
            }
            else {
                delete $gpswaypoints{$key};
                say "Deleting the first entry";
                goto OUTER;
            }
        }

    }

}

#Draw a line from fix icon to closest text boxes
my $gpswaypoint_line = $page->gfx;

foreach my $key ( sort keys %gpswaypoints ) {
    $gpswaypoint_line->move( $gpswaypoints{$key}{"iconCenterXPdf"},
        $gpswaypoints{$key}{"iconCenterYPdf"} );
    $gpswaypoint_line->line( $gpswaypoints{$key}{"TextBoxX"},
        $gpswaypoints{$key}{"TextBoxY"} );
    $gpswaypoint_line->strokecolor('blue');
    $gpswaypoint_line->stroke;
}

#Save our new PDF since we're done with it
$pdf->saveas($outputpdf);

#Close the database
$sth->finish();
$dbh->disconnect();

#---------------------------------------------------------------------------------------------------------------------------------------------------
#Create the list of Ground Control Points
my @gcps;
say "Obstacle Ground Control Points (x,y,lon,lat)";

#Add obstacles to Ground Control Points array
foreach my $key ( sort keys %unique_obstacles_from_db ) {

#I'm trying rounding vs. not rounding the pixel coordinates.  I thought you might have to round but gdal_translate seems happy without
#my $rounded = int($float + 0.5);
# my $roundedpngx =int( $unique_obstacles_from_db{$key}{"ObsIconX"}*$scalefactorx+.5);
    my $roundedpngx =
      $unique_obstacles_from_db{$key}{"ObsIconX"} * $scalefactorx;

# my $roundedpngy = int($pngy - $unique_obstacles_from_db{$key}{"ObsIconY"}*$scalefactory+.5);
    my $roundedpngy =
      $pngy - ( $unique_obstacles_from_db{$key}{"ObsIconY"} * $scalefactory );
    my $lon = $unique_obstacles_from_db{$key}{"Lon"};
    my $lat = $unique_obstacles_from_db{$key}{"Lat"};
    if ( $roundedpngy && $roundedpngx && $lon && $lat ) {
        say "$roundedpngx $roundedpngy $lon $lat" if $debug;
        push @gcps, "-gcp $roundedpngx $roundedpngy $lon $lat ";
    }
}

#Add fixes to Ground Control Points array
say "Fix Ground Control Points" if $debug;
foreach my $key ( sort keys %fixicons ) {
    my $roundedpngx = $fixicons{$key}{"X"} * $scalefactorx;
    my $roundedpngy = $pngy - ( $fixicons{$key}{"Y"} * $scalefactory );
    my $lon         = $fixicons{$key}{"Lon"};
    my $lat         = $fixicons{$key}{"Lat"};
    if ( $roundedpngy && $roundedpngx && $lon && $lat ) {
        say "$roundedpngx $roundedpngy $lon $lat" if $debug;
        push @gcps, "-gcp $roundedpngx $roundedpngy $lon $lat ";
    }
}

#Add GPS waypoints to Ground Control Points array
say "GPS waypoint Ground Control Points" if $debug;
foreach my $key ( sort keys %gpswaypoints ) {

    my $roundedpngx = $gpswaypoints{$key}{"X"} * $scalefactorx;
    my $roundedpngy = $pngy - ( $gpswaypoints{$key}{"Y"} * $scalefactory );
    my $lon         = $gpswaypoints{$key}{"Lon"};
    my $lat         = $gpswaypoints{$key}{"Lat"};
    if ( $roundedpngy && $roundedpngx && $lon && $lat ) {

        say "$roundedpngx $roundedpngy $lon $lat" if $debug;

        push @gcps, "-gcp $roundedpngx $roundedpngy $lon $lat ";
    }
}

my $gcpstring = "";
for my $line (@gcps) {
    $gcpstring = $gcpstring . $line;
}
if ($debug) {
    say "Ground Control Points command line string";
    say $gcpstring;
}

#Try to georeference based on the list of Ground Control Points
die "Need more Ground Control Points" if 0 + @gcps < 2;
my $gdal_translateoutput;
$gdal_translateoutput =
qx(gdal_translate  -strict -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" $gcpstring -of VRT $targetpng $targetvrt);
$retval = $? >> 8;
die "No output from gdal_translate  Is it installed? Return code was $retval"
  if ( $gdal_translateoutput eq "" || $retval != 0 );
say $gdal_translateoutput;

my $gdalwarpoutput;
$gdalwarpoutput =
qx(gdalwarp -t_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" -dstalpha -order 1  -overwrite  -r bilinear $targetvrt $targettif);
$retval = $? >> 8;
die "No output from gdalwarp.  Is it installed? Return code was $retval"
  if ( $gdalwarpoutput eq "" || $retval != 0 );

#command line paramets to consider adding: "-r lanczos", "-order 1", "-overwrite"
# -refine_gcps tolerance minimum_gcps:
# (GDAL >= 1.9.0) refines the GCPs by automatically eliminating outliers. Outliers will be
# eliminated until minimum_gcps are left or when no outliers can be detected. The
# tolerance is passed to adjust when a GCP will be eliminated. Note that GCP refinement
# only works with polynomial interpolation. The tolerance is in pixel units if no
# projection is available, otherwise it is in SRS units. If minimum_gcps is not provided,
# the minimum GCPs according to the polynomial model is used.

say $gdalwarpoutput;

#This version tries using the PDF directly instead of the intermediate PNG
# say $gcpstring;
# $output = qx(gdal_translate -a_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" $gcpstring -of VRT $targetpdf $targetpdf.vrt);
# say $output;
# $output = qx(gdalwarp -t_srs "+proj=latlong +ellps=WGS84 +datum=WGS84 +no_defs" -dstalpha $targetpdf.vrt $targettif);
# say $output;

#;
#;
