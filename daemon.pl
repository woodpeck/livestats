#!/usr/bin/perl

# Written by Frederik Ramm frederik@remote.org, public domain

# This is a mini web server that listens on port 8080 by default, and will 
# server: 
# 1. a HTML index page 
# 2. a combined CSS page
# 3. a combined JS page (with jquery and flot)
# 4. a number of JSON calls for statistics

# The script loads replication diffs from OpenStreetMap, and keeps counters
# for each user name to record how many edits in each minute were made by that
# user. 

use LWP;
use strict;
use Compress::Zlib;
use Time::Local;
use AnyEvent::HTTPD;
use JSON;
use File::Slurp;
use FindBin qw($Bin);

my $ua = LWP::UserAgent->new;
my $httpd = AnyEvent::HTTPD->new (port => 8080);

# This is where we read the Javascript and CSS files so we can deliver them
# later. 
my $indexpage = read_file("$Bin/index.html") or die;
my $js;
foreach (glob("$Bin/js/*js")) { $js .= read_file($_) or die; }
my $css;
foreach (glob("$Bin/js/*css")) { $css .= read_file($_) or die; }

my $minutes = {};
my $hours = {};
my $days = {};
my $id2name = {};

# determine current OSM replication state
my $r = $ua->get('http://planet.openstreetmap.org/replication/minute/state.txt');
my $c = $r->content;
die unless ($c =~ /sequenceNumber=(\d+)/s);
my $end_time = $1;

# load 10 minutes worth of history when starting up.
my $start_time = $end_time - 10;
my $earliest_timestamp;
my $maxmin = 0;
my $last_process_time;

my $last_diff = $start_time;
catchup();
my $w = AnyEvent->timer (after => 60, interval => 60, cb => \&catchup);

# load everything that is new from the OSM server 
sub catchup
{
	my $r = $ua->get('http://planet.openstreetmap.org/replication/minute/state.txt');
	my $c = $r->content;
	die unless ($c =~ /sequenceNumber=(\d+)/s);
    my $end_time = $1;

	while($last_diff <= $end_time)
	{
		print STDERR "fetch $last_diff (end $end_time)\n";
		my $osc = get_osc($last_diff);
		die unless defined($osc);
		process_osc($osc);
		$last_diff++;
	}
}

# configure HTTP server
$httpd->reg_cb (
       '/' => sub {
          my ($httpd, $req) = @_;
          $req->respond ([200, 'ok', { "Content-type" =>  "text/html; charset=utf-8", "Access-control-allow-origin" => "*" }, $indexpage ]);
       },
       '/js.js' => sub {
          my ($httpd, $req) = @_;
          $req->respond ([200, 'ok', { "Content-type" =>  "application/javascript; charset=utf-8", "Access-control-allow-origin" => "*" }, $js ]);
       },
       '/css.css' => sub {
          my ($httpd, $req) = @_;
          $req->respond ([200, 'ok', { "Content-type" =>  "application/css; charset=utf-8", "Access-control-allow-origin" => "*" }, $css ]);
       },
       '/stats' => sub {
          my ($httpd, $req) = @_;
          $req->respond ([200, 'ok', { "Content-type" =>  "application/json; charset=utf-8", "Access-control-allow-origin" => "*" },
             json_message($maxmin, $req->parm('minutes'))
          ]);
       },
       '/prevstats' => sub {
          my ($httpd, $req) = @_;
          $req->respond ([200, 'ok', { "Content-type" =>  "application/json; charset=utf-8", "Access-control-allow-origin" => "*" },
             json_message($maxmin-1, $req->parm('minutes'))
          ]);
       }
    );

$httpd->run;

# generate a JSON response, going back from the given minute for the given 
# window size. Note that similar mechanisms could be employed to go back for
# many hours or days sing the lesser-granularity buckets but that is not 
# implemented.

sub json_message()
{
    my ($whichminute, $window) = @_;
    my $sum = {};
    my $json = JSON->new;
    for (my $i = $whichminute; $i >= $whichminute - $window; $i--)
    {
        add($sum, $minutes->{$i}, $window + 1);
    }

    my $r =  encode_json($sum);
    utf8::decode($r);
    # structure of returned JSON message:
    # { "edits" : { "username" : count, "username" : count, ... }, "earliest" : time, "last" : last }
    # "earliest" is the earliest data loaded from OSM (by default, 10 minutes 
    # before server started), "last" is the epoch timestamp of the most recent
    # object seen by this server.
    return <<EOF
    { "edits" : $r,
      "earliest" : $earliest_timestamp,
      "last" : $last_process_time 
    }
EOF
}

# helper to sum up different buckets
sub add
{
    my ($dest, $src, $div) = @_;
    foreach my $key(keys %$src)
    {
        $dest->{$key}->{"edits"} += $src->{$key}->{"edits"} / $div;
        $dest->{$key}->{"username"} = $id2name->{$key};
    }
}

# parse an OSC file, and increase the user's edit counters in the 
# relevant minute, hour, and day buckets
sub process_osc
{
    my $osc = shift;
    foreach (split(/\n/, $osc))
    {
        next unless (/<(node|way|relation)/);
        next unless (/timestamp="(2\d\d\d)-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/);
        $last_process_time = timegm($6, $5, $4, $3, $2-1, $1-1900);
        $earliest_timestamp = $last_process_time unless defined($earliest_timestamp);
        my $minute_index = int($last_process_time / 60);
        $maxmin = $minute_index if ($minute_index > $maxmin);
        my $hour_index = int($minute_index / 60);
        my $day_index = int($hour_index / 24);
        next unless (/uid="(\d+)"/);
        my $uid = $1;
        next unless (/user="([^"]+)"/);
        my $user = $1;
        next unless (/changeset="(\d+)"/);
        my $changeset = $1;

        $minutes->{$minute_index}->{$uid}->{"edits"}++;
        $hours->{$hour_index}->{$uid}->{"edits"}++;
        $days->{$day_index}->{$uid}->{"edits"}++;

        $id2name->{$uid} = $user;
    }
}

# load OSC from server
sub get_osc
{
    my $n = shift;
    my $p = sprintf("http://planet.openstreetmap.org/replication/minute/%03d/%03d/%03d.osc.gz", $n/1000000, $n/1000 % 1000, $n % 1000);
    my $r = $ua->get($p);
    return undef unless $r->is_success;
    # trick LWP into decoding this for us
    $r->headers->{"content-encoding"} = "x-gzip";
    return $r->decoded_content(charset => 'utf-8');
}
