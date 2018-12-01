#!/usr/bin/perl

use Data::Dumper qw(Dumper);
use strict;
#use warnings;

my @day_sessions = (0,1,2,3,4,5,6);
my @session_items = qw(caltag day sdate edate stime etime session change);
my %session_field = (
 caltag => 0,
 day => 1,
 sdate => 2,
 edate => 3,
 stime => 4,
 etime => 5,
 sess => 6,
 change => 7
);

my $to_date=14;

use Date::Manip qw(ParseDate UnixDate DateCalc Date_Cmp ParseDateDelta);

my $date2 = ParseDate("2018/11/18, 5:45:50 PM");
my $date2 = ParseDate("now");
printf ("%s\n", UnixDate(DateCalc ($date2, "+1 hour"),"%m/%d/%Y %H:%M:%S"));
printf ("%s\n", DateCalc(ParseDate("22:00:00"),ParseDate("02:00:00")));
printf ("%s\n", DateCalc(ParseDate("22:00:00"),"+ 4 hour"));
exit;
#if ( Date_Cmp($mytime2, $mytime1) > 0 ){
#	printf("%s is greater than %s\n", $mytime2, $mytime1 );
#}

#my $date = ParseDate("now");
my $date = DateCalc("now", "-$to_date days");
my $datestr = UnixDate($date, "day %w: %a %b %e %H:%M:%S %Y %Z");    # as scalar

print "Date::Manip gives: $datestr\n";


#foreach my $i ( @day_sessions ){
#    print "day session ==> $i\n";
#}

#foreach my $i ( keys %session_field ){
#    print "sess field: $i ==> $session_field{$i}\n";
#}

my @session_list=();

open(SIN, "< schedule.txt") or die "Error: $!";
while(<SIN>){
   	chomp;

   	next if /^#/;
    my %session_tab=();
    my $offset=0;
   	foreach my $i ( my @fields = split( /~/ ) ){
    	#printf ("%s ==> %s\n", $session_items[ $offset ], $i);
        $session_tab{$session_items[ $offset ]} = $i;
		$offset++;
   	}

   push @session_list, \%session_tab;
}

close(SIN);

#print Dumper \@session_list;
@session_list = sort { Date_Cmp($a->{stime}, $b->{stime}) } @session_list;
#print Dumper \@session_list;

for ( my $i=0; $i<=$to_date; $i++ ){

    my $run_date = DateCalc("now", "+$i days");
    my $run_date_str = UnixDate($run_date, "%a %b %e %H:%M:%S %Y %Z");    # as scalar
    my $run_date_str = UnixDate($run_date, "%m/%d/%Y");    # as scalar
    my $run_date_wkday = UnixDate($run_date, "%w");
    my %session;
    my $day;

    if ( $run_date_wkday == 7  ){
   		$run_date_wkday=0;
	}

    printf("RunDate: %s\n", $run_date_str );

	for ( my $i=0; $i<=$#session_list; $i++ ){
        my @arr = split ( /,/, $session_list[$i]{day} );
        foreach my $x ( @arr ){
			if ( $x == $run_date_wkday ){
				printf ( "%s %s\n", $session_list[$i]{stime}, $session_list[$i]{etime});
			}	 
 	    }	
	}
}

exit;

for ( my $i=0; $i<=$#session_list; $i++ ){
	printf ("%s %s %s\n",  $session_list[$i]{day}, 
		$session_list[$i]{stime}, $session_list[$i]{etime} );
}

sub order_by_stime{
    my ($a, $b) = @_;
    
    return Date_Cmp($a, $b);

	if ( Date_Cmp($a, $b) > 0 ){
		printf("%s is greater than %s\n", $a, $b );
    }else{
		printf("%s is less than %s\n", $a, $b );
    }
}
