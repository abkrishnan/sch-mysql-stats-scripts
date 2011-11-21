#!/usr/bin/perl 
use Date::Manip;
use strict;
use warnings;
use Getopt::Long;

#this is in seconds
my $min_time_diff = 60;
my $help;
my $query_day;
my %FORM;
my $log_file;
my $SLOW_LOGS_DIR = "/opt/mysql_db_logs/";
my $SLOW_LOGS_BASEFILENAME = "mysqlslow.log_appdb";

main();

sub find_time_diff
{
    my $date1 = ParseDate($_[0]);
    my $date2 = ParseDate($_[1]);

    my $delta = DateCalc($date1, $date2, 1);
    my $diff_seconds = Delta_Format($delta, 0, '%sh');
    return $diff_seconds;
}

sub parse_options 
{ 
    my $temp_interval;
    my $temp_day;
    my $filename;

    GetOptions('logfile=s' => \$filename, 'interval=i' => \$temp_interval, 'day=s' => \$temp_day, 'help' => \$help) or usage();

    if (defined $filename) { 
        $log_file = $filename;
    }

    if (defined $temp_interval) { 
        $min_time_diff = $temp_interval;
        #print "Setting minimum sample interval to $min_time_diff\n";
    }

    if (defined $temp_day) { 
        $query_day = $temp_day;
    }
    
    if (defined $help) { 
        usage();
    }   
}

sub usage()
{
    print <<EOF;

        usage: $0 [OPTION]

            --interval  : [minimum time iterval between samples]
            --day       : [yymmdd]
            --help      : print this help message

            example: $0 --interval=300 --day=1111..

EOF
    exit;
}

sub main
{ 
    my $time = 0;
    my %time_query_count ;
    my $slow_query_interval = 0;
    my $new_time_stamp = 0;
    my $prev_time_stamp = 0;
    my $query_count = 0;
    my $time_stamp = 0;
    my $printable_timestamp = 0;

    #parse_options();
    read_form_data();
    log_request();
    open SLOWLOGFILE, $log_file or display_error($!);

    while (<SLOWLOGFILE>) {
        # Skip unnecessary lines
        next if ( m|/.*mysqld, Version:.+, started with:| );
        next if ( m|Tcp port: \d+  Unix socket: .*mysql.sock| );
        next if ( m|Time\s+Id\s+Command\s+Argument| );
        next if (/^\#\s+User.Host.*/);
        next if (/^\#\s+Query_time:.*/);

        if (/Time:\s+(\d\d)(\d\d)(\d\d)\s+(\d+):(\d\d):(\d\d)$/) {
            my $day_of_query = "$1"."$2"."$3";
            if (defined $query_day && !($day_of_query =~ m/$query_day/)) { 
                #print "did not match comparing $query_day to $day_of_query\n";
                next;
            } else { 
                #print "matched comparing $query_day to $day_of_query\n";
            }
        }
        if (/Time:\s+(\d\d)(\d\d)(\d\d)\s+(\d+):(\d\d):(\d\d)$/) {
            if ($4 > 9) { 
                $new_time_stamp = "$1-"."$2"."$3"."$4"."$5"."$6";
                $printable_timestamp = "$1:"."$2:"."$3 "."$4:"."$5:"."$6"
            } else  { 
                $new_time_stamp = "$1-"."$2"."$3"."0"."$4"."$5"."$6";
                $printable_timestamp = "$1:"."$2:"."$3 "."0"."$4:"."$5:"."$6"
            }

            if (!$slow_query_interval) { 
                $time_stamp = $printable_timestamp;
                $query_count = 0;
                $prev_time_stamp = $new_time_stamp;
                $slow_query_interval++;
                next;
            }

            my $time_diff = find_time_diff($prev_time_stamp, $new_time_stamp);
            if ($time_diff < $min_time_diff) { 
                next;
            }
            #print "time diff $prev_time_stamp, $new_time_stamp $time_diff\n";

            $time_query_count{$slow_query_interval} = "$time_stamp,$query_count";
            $query_count = 0;
            $time_stamp = $printable_timestamp;
            $prev_time_stamp = $new_time_stamp;
            $slow_query_interval++;
            next;
        }
        if ( /^\w/) {
            $query_count++;
        }
    }

    my $html_template = <<END;
Content-type:text/html\r\n\r\n
<html>
  <head>
    <script type="text/javascript" src="https://www.google.com/jsapi"></script>
    <script type="text/javascript">
      google.load("visualization", "1", {packages:["corechart"]});
      google.setOnLoadCallback(drawChart);
      function drawChart() {
        var data = new google.visualization.DataTable();
        data.addColumn('string', 'Queries');
        data.addColumn('number', 'Database Stack Foo');

END
    print $html_template;
#now configure number of data points we have
    my $data_points = keys( %time_query_count);
    print "\tdata.addRows($data_points);\n";

    my $data_point_counter = 0;
    foreach my $key (sort { $a <=> $b } keys %time_query_count) {
        my ($time, $queries) = split(/,/, $time_query_count{$key});
        print "\tdata.setValue($data_point_counter, 0, \'$time\');\n";
        print "\tdata.setValue($data_point_counter, 1, $queries);\n";
        $data_point_counter++;
    }

    my $html_template_end = <<TAILEND;
        var chart = new google.visualization.LineChart(document.getElementById('chart_div'));
        chart.draw(data, {width: 1000, height: 600, title: 'Slow Query Results for Database Stack Foo'});
      }
    </script>
  </head>

  <body>
    <div id="chart_div"></div>
  </body>
</html>
TAILEND
    print "$html_template_end";

    close SLOWLOGFILE;
}

sub read_form_data
{
    my ($buffer, @pairs, $pair, $name, $value);
    # Read in text
    $ENV{'REQUEST_METHOD'} =~ tr/a-z/A-Z/;
    if ($ENV{'REQUEST_METHOD'} eq "POST")
    {
        read(STDIN, $buffer, $ENV{'CONTENT_LENGTH'});
    }else {
        $buffer = $ENV{'QUERY_STRING'};
    }
    # Split information into name/value pairs
    @pairs = split(/&/, $buffer);
    foreach $pair (@pairs)
    {
        ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%(..)/pack("C", hex($1))/eg;
        $FORM{$name} = $value;
    }
    $log_file = "$SLOW_LOGS_DIR"."$SLOW_LOGS_BASEFILENAME"."$FORM{'select-database'}";

    my $time_interval = int($FORM{'time-interval'});
    if ($time_interval) { 
        $min_time_diff = $time_interval;
    }
    my $date = $FORM{'date'};
    $date = trim($date);
    if (length($date)) { 
        $query_day = $date;
    }
}

sub trim($)
{
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

sub log_request
{
    open LOGFILE, ">>/tmp/slowlog.log";
    print LOGFILE "Time Interval: $min_time_diff\n";
    print LOGFILE "Query day: $query_day\n";
    print LOGFILE "Log file: $log_file\n";
    close LOGFILE;
}

sub display_error
{
    
    print "Content-type:text/html\r\n\r\n";
    print "<html>";
    print "<head>";
    print "<title>Hello - Second CGI Program</title>";
    print "</head>";
    print "<body>";
    print "Internal error: Could not process request\n";
    print "$log_file\n";
    print "$FORM{'select-database'}";
    print "$_[0]\n";     
    print "</body>";
    print "</html>";
    print "</body>\n";
    print "</html>\n";
}
